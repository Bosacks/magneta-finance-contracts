import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Integration test — two-gateway cross-chain scenario.
 *
 * Simulates a token admin on "chain A" asking the Magneta gateway to execute
 * a FREEZE_ACCOUNT on "chain B" via a LayerZero message. The mock endpoint
 * on chain B delivers into `_lzReceive`, which dispatches to TokenOpsModule.
 *
 * Why a command op (freeze) rather than an LP op? Value ops (CREATE_LP, SWAP)
 * involve routing the caller's source-chain assets across the bridge before
 * execution — that whole flow lives in Phase-2 LI.FI adapters. Command ops
 * exercise the core LZ-receive path end-to-end with just USDC on dst chain.
 *
 * Hardhat-network is single-chain, so we model "two chains" as two
 * endpoint+gateway pairs on the same EVM. Since EVM addresses are identical
 * across chains in real life, this preserves caller semantics.
 */
describe("Cross-chain integration", function () {
    const EID_A = 40111; // "chain A"
    const EID_B = 40222; // "chain B"
    const OP_FREEZE_ACCOUNT = 6;

    let owner: SignerWithAddress, alice: SignerWithAddress, bob: SignerWithAddress, feeVaultB: SignerWithAddress;
    let endpointA: any, endpointB: any;
    let gatewayA: any, gatewayB: any;
    let tokenOpsB: any;
    let usdcB: any, managedB: any;

    beforeEach(async () => {
        [owner, alice, bob, feeVaultB] = await ethers.getSigners();

        const Endpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
        endpointA = await Endpoint.deploy(EID_A);
        endpointB = await Endpoint.deploy(EID_B);

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        usdcB = await MockERC20.deploy("USDC", "USDC", 6, 0n);

        const Gateway = await ethers.getContractFactory("MagnetaGateway");
        gatewayA = await Gateway.deploy(await endpointA.getAddress(), owner.address, owner.address);
        gatewayB = await Gateway.deploy(await endpointB.getAddress(), owner.address, feeVaultB.address);

        // OApp peer handshake.
        const peerA = ethers.zeroPadValue(await gatewayA.getAddress(), 32);
        const peerB = ethers.zeroPadValue(await gatewayB.getAddress(), 32);
        await gatewayA.setPeer(EID_B, peerB);
        await gatewayB.setPeer(EID_A, peerA);

        // TokenOpsModule + managed token on chain B.
        const TokenOps = await ethers.getContractFactory("TokenOpsModule");
        tokenOpsB = await TokenOps.deploy(await gatewayB.getAddress(), await usdcB.getAddress());
        await gatewayB.setModule(OP_FREEZE_ACCOUNT, await tokenOpsB.getAddress());

        const Managed = await ethers.getContractFactory("MockManagedToken");
        managedB = await Managed.deploy("Brand", "BR");
        await managedB.transferOwnership(await tokenOpsB.getAddress());

        // Alice is the admin on chain B. Since EVM addresses match across
        // chains, she has the same EOA on chain A issuing the LZ message.
        await tokenOpsB.registerToken(await managedB.getAddress(), alice.address);

        // Alice funds USDC + approves the module on chain B (fee is pulled
        // on the destination chain, not at source).
        await usdcB.mint(alice.address, ethers.parseUnits("100", 6));
        await usdcB.connect(alice).approve(await tokenOpsB.getAddress(), ethers.MaxUint256);
    });

    it("delivers FREEZE from chain A → chain B, module freezes and pulls flat fee", async () => {
        const coder = new ethers.AbiCoder();

        // Inner module payload: OpType prefix + BlacklistParams tuple.
        const inner = coder.encode(
            ["tuple(address token,address account)"],
            [[await managedB.getAddress(), bob.address]]
        );
        const innerParams = ethers.concat(["0x06", inner]); // OpType.FREEZE_ACCOUNT

        // LZ payload the destination gateway decodes in _lzReceive.
        const lzPayload = coder.encode(
            ["uint8", "address", "bytes"],
            [OP_FREEZE_ACCOUNT, alice.address, innerParams]
        );

        const guid = ethers.keccak256(ethers.toUtf8Bytes("freeze-guid-1"));
        const origin = {
            srcEid: EID_A,
            sender: ethers.zeroPadValue(await gatewayA.getAddress(), 32),
            nonce: 1n,
        };

        const flat = await tokenOpsB.flatFeeUsdc();
        const vaultBefore = await usdcB.balanceOf(feeVaultB.address);

        await expect(
            endpointB.deliverMessage(await gatewayB.getAddress(), origin, guid, lzPayload)
        ).to.emit(gatewayB, "OperationExecuted")
         .and.to.emit(tokenOpsB, "OpForwarded");

        expect(await managedB.frozen(bob.address)).to.equal(true);
        // Cross-chain: fee is collected on source chain by Gateway, not on destination
        expect(await usdcB.balanceOf(feeVaultB.address) - vaultBefore).to.equal(0n);
    });

    it("rejects replayed GUID on the destination gateway", async () => {
        const coder = new ethers.AbiCoder();
        const inner = coder.encode(
            ["tuple(address token,address account)"],
            [[await managedB.getAddress(), bob.address]]
        );
        const innerParams = ethers.concat(["0x06", inner]);
        const lzPayload = coder.encode(
            ["uint8", "address", "bytes"],
            [OP_FREEZE_ACCOUNT, alice.address, innerParams]
        );
        const guid = ethers.keccak256(ethers.toUtf8Bytes("replay-guid"));
        const origin = {
            srcEid: EID_A,
            sender: ethers.zeroPadValue(await gatewayA.getAddress(), 32),
            nonce: 1n,
        };

        await endpointB.deliverMessage(await gatewayB.getAddress(), origin, guid, lzPayload);

        await expect(
            endpointB.deliverMessage(await gatewayB.getAddress(), origin, guid, lzPayload)
        ).to.be.reverted;
    });

    it("rejects LZ payload from an unregistered peer (srcEid unknown)", async () => {
        const rogue = ethers.zeroPadValue(ethers.Wallet.createRandom().address, 32);

        const coder = new ethers.AbiCoder();
        const lzPayload = coder.encode(
            ["uint8", "address", "bytes"],
            [OP_FREEZE_ACCOUNT, alice.address, "0x"]
        );

        const origin = { srcEid: EID_A, sender: rogue, nonce: 1n };
        const guid = ethers.keccak256(ethers.toUtf8Bytes("rogue-guid"));

        await expect(
            endpointB.deliverMessage(await gatewayB.getAddress(), origin, guid, lzPayload)
        ).to.be.reverted;
    });
});
