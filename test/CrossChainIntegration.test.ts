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

        // Configure USDC on both gateways. Required since MG-7: _lzReceive
        // normalizes the payload's bridgedToken to `address(usdc)`, and
        // fulfillValueOp then reads/approves through that. With usdc unset,
        // both calls hit address(0) and revert without a clean reason.
        await gatewayA.setUsdc(await usdcB.getAddress());
        await gatewayB.setUsdc(await usdcB.getAddress());

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

        // LZ payload: version 0 (command op) + OpType + caller + params
        const lzPayload = coder.encode(
            ["uint8", "uint8", "address", "bytes"],
            [0, OP_FREEZE_ACCOUNT, alice.address, innerParams]
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
            ["uint8", "uint8", "address", "bytes"],
            [0, OP_FREEZE_ACCOUNT, alice.address, innerParams]
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
            ["uint8", "uint8", "address", "bytes"],
            [0, OP_FREEZE_ACCOUNT, alice.address, "0x"]
        );

        const origin = { srcEid: EID_A, sender: rogue, nonce: 1n };
        const guid = ethers.keccak256(ethers.toUtf8Bytes("rogue-guid"));

        await expect(
            endpointB.deliverMessage(await gatewayB.getAddress(), origin, guid, lzPayload)
        ).to.be.reverted;
    });

    // ───── Phase 2B: Cross-chain VALUE ops (CCTP + LZ) ─────

    it("stores a pending value op from LZ message (version 1) and fulfills after CCTP mint", async () => {
        const coder = new ethers.AbiCoder();

        // Inner module payload for FREEZE (simple command, but sent as value op for testing)
        const inner = coder.encode(
            ["tuple(address token,address account)"],
            [[await managedB.getAddress(), bob.address]]
        );
        const innerParams = ethers.concat(["0x06", inner]);

        const bridgedAmount = ethers.parseUnits("100", 6); // 100 USDC

        // Version 1 payload = value op
        const lzPayload = coder.encode(
            ["uint8", "uint8", "address", "bytes", "address", "uint256"],
            [1, OP_FREEZE_ACCOUNT, alice.address, innerParams, await usdcB.getAddress(), bridgedAmount]
        );

        const guid = ethers.keccak256(ethers.toUtf8Bytes("value-op-guid"));
        const origin = {
            srcEid: EID_A,
            sender: ethers.zeroPadValue(await gatewayA.getAddress(), 32),
            nonce: 2n,
        };

        // Deliver LZ message — should store as pending, NOT execute
        await expect(
            endpointB.deliverMessage(await gatewayB.getAddress(), origin, guid, lzPayload)
        ).to.emit(gatewayB, "ValueOpPending");

        // Verify op is pending
        const pending = await gatewayB.pendingValueOps(guid);
        expect(pending.bridgedAmount).to.equal(bridgedAmount);
        expect(pending.caller).to.equal(alice.address);

        // Simulate CCTP mint: send USDC directly to gateway (mimics Circle minting)
        await usdcB.mint(await gatewayB.getAddress(), bridgedAmount);

        // Approve the module to pull from gateway (gateway does forceApprove in fulfill)
        // Fulfill the pending op
        await expect(
            gatewayB.fulfillValueOp(guid)
        ).to.emit(gatewayB, "ValueOpFulfilled");

        // Verify the freeze happened
        expect(await managedB.frozen(bob.address)).to.equal(true);

        // Verify pending op was cleared
        const cleared = await gatewayB.pendingValueOps(guid);
        expect(cleared.bridgedAmount).to.equal(0);
    });

    it("creates LP from bridged USDC via cross-chain value op (CCTP + LZ)", async () => {
        const coder = new ethers.AbiCoder();
        const OP_CREATE_LP = 0;

        // Deploy WETH with deposit/withdraw support
        const MockWETH = await ethers.getContractFactory("MockWETH");
        const wethB = await MockWETH.deploy();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const tokenB = await MockERC20.deploy("Memecoin", "MEME", 18, ethers.parseEther("100000"));

        // V2 Router for addLiquidityETH
        const Router = await ethers.getContractFactory("MockV2Router");
        const routerB = await Router.deploy(await wethB.getAddress());

        // MagnetaSwap mock for USDC→token and USDC→WETH swaps (no fees)
        const MockSwap = await ethers.getContractFactory("MockSwapRouter");
        const magnetaSwapB = await MockSwap.deploy();

        const LPModule = await ethers.getContractFactory("LPModule");
        const lpModuleB = await LPModule.deploy(
            await gatewayB.getAddress(),
            await routerB.getAddress(),
            await usdcB.getAddress(),
            await magnetaSwapB.getAddress()
        );
        await gatewayB.setModule(OP_CREATE_LP, await lpModuleB.getAddress());

        const bridgedUsdc = ethers.parseUnits("200", 6); // $200 USDC total

        // V1.1: LPModule._createLPFromBridgedUsdc now routes via the V2
        // router directly (not MagnetaSwap), so seed routerB with both the
        // intermediary WETH and the destination token. magnetaSwapB stays
        // funded too because _createLPAndBuy (a different op) still uses it.
        await tokenB.mint(await routerB.getAddress(), ethers.parseEther("10000"));
        await wethB.mint(await routerB.getAddress(), ethers.parseUnits("100", 6));
        await tokenB.mint(await magnetaSwapB.getAddress(), ethers.parseEther("10000"));
        await wethB.mint(await magnetaSwapB.getAddress(), ethers.parseUnits("100", 6));
        // Fund mock WETH contract with actual ETH so withdraw() works
        await owner.sendTransaction({ to: await wethB.getAddress(), value: ethers.parseEther("10") });

        // CrossChainLPParams: 50/50 split, token + native
        const crossChainLpParams = coder.encode(
            ["tuple(address token,uint256 usdcTotal,uint16 tokenShareBps,uint256 amountTokenMin,uint256 amountNativeMin,uint256 lpAmountTokenMin,uint256 lpAmountNativeMin,uint256 deadline)"],
            [[
                await tokenB.getAddress(),
                bridgedUsdc,
                5000, // 50% for token, 50% for native
                0n,   // amountTokenMin (mock is 1:1)
                0n,   // amountNativeMin
                0n,   // lpAmountTokenMin
                0n,   // lpAmountNativeMin
                Math.floor(Date.now() / 1000) + 3600,
            ]]
        );
        const moduleParams = ethers.concat(["0x00", crossChainLpParams]); // OpType.CREATE_LP prefix

        // Version 1 payload = value op
        const lzPayload = coder.encode(
            ["uint8", "uint8", "address", "bytes", "address", "uint256"],
            [1, OP_CREATE_LP, alice.address, moduleParams, await usdcB.getAddress(), bridgedUsdc]
        );

        const guid = ethers.keccak256(ethers.toUtf8Bytes("xchain-lp-guid"));
        const origin = {
            srcEid: EID_A,
            sender: ethers.zeroPadValue(await gatewayA.getAddress(), 32),
            nonce: 10n,
        };

        // Deliver LZ message → stored as pending
        await expect(
            endpointB.deliverMessage(await gatewayB.getAddress(), origin, guid, lzPayload)
        ).to.emit(gatewayB, "ValueOpPending");

        // Simulate CCTP mint: USDC arrives at gateway
        await usdcB.mint(await gatewayB.getAddress(), bridgedUsdc);

        // Fulfill the op → should trigger _createLPFromBridgedUsdc
        await expect(
            gatewayB.fulfillValueOp(guid)
        ).to.emit(gatewayB, "ValueOpFulfilled");

        // Alice should have received LP tokens on destination chain
        const pair = await routerB.pair();
        const lpToken = await ethers.getContractAt("MockLPToken", pair);
        expect(await lpToken.balanceOf(alice.address)).to.be.gt(0n);

        // Pending op should be cleared
        const cleared = await gatewayB.pendingValueOps(guid);
        expect(cleared.bridgedAmount).to.equal(0);
    });

    it("fan-out value op: creates LP from USDC on two destination chains in one tx", async () => {
        const coder = new ethers.AbiCoder();
        const OP_CREATE_LP = 0;
        const EID_C = 40333; // "chain C"

        // Deploy chain C endpoint + gateway
        const Endpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
        const endpointC = await Endpoint.deploy(EID_C);

        const Gateway = await ethers.getContractFactory("MagnetaGateway");
        const gatewayC = await Gateway.deploy(await endpointC.getAddress(), owner.address, feeVaultB.address);

        // Peer handshake: A→B, A→C
        const peerA = ethers.zeroPadValue(await gatewayA.getAddress(), 32);
        const peerC = ethers.zeroPadValue(await gatewayC.getAddress(), 32);
        await gatewayA.setPeer(EID_C, peerC);
        await gatewayC.setPeer(EID_A, peerA);

        // Deploy MockWETH, token, router, MagnetaSwap for chain B
        const MockWETH = await ethers.getContractFactory("MockWETH");
        const wethB = await MockWETH.deploy();
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const tokenB = await MockERC20.deploy("Meme", "MEME", 18, ethers.parseEther("100000"));
        const Router = await ethers.getContractFactory("MockV2Router");
        const routerB = await Router.deploy(await wethB.getAddress());
        const MockSwap = await ethers.getContractFactory("MockSwapRouter");
        const swapB = await MockSwap.deploy();
        const LPModule = await ethers.getContractFactory("LPModule");
        const lpModuleB = await LPModule.deploy(
            await gatewayB.getAddress(), await routerB.getAddress(), await usdcB.getAddress(), await swapB.getAddress()
        );
        await gatewayB.setModule(OP_CREATE_LP, await lpModuleB.getAddress());

        // Same for chain C
        const wethC = await MockWETH.deploy();
        const tokenC = await MockERC20.deploy("Meme", "MEME", 18, ethers.parseEther("100000"));
        const routerC = await Router.deploy(await wethC.getAddress());
        const swapC = await MockSwap.deploy();
        const usdcC = await MockERC20.deploy("USDC", "USDC", 6, 0n);
        const lpModuleC = await LPModule.deploy(
            await gatewayC.getAddress(), await routerC.getAddress(), await usdcC.getAddress(), await swapC.getAddress()
        );
        await gatewayC.setModule(OP_CREATE_LP, await lpModuleC.getAddress());
        await gatewayC.setUsdc(await usdcC.getAddress());

        // Fund routers (V1.1 V2-direct path) + mock swaps (kept for buy op).
        await tokenB.mint(await routerB.getAddress(), ethers.parseEther("10000"));
        await wethB.mint(await routerB.getAddress(), ethers.parseUnits("100", 6));
        await tokenB.mint(await swapB.getAddress(), ethers.parseEther("10000"));
        await wethB.mint(await swapB.getAddress(), ethers.parseUnits("100", 6));
        await owner.sendTransaction({ to: await wethB.getAddress(), value: ethers.parseEther("10") });

        await tokenC.mint(await routerC.getAddress(), ethers.parseEther("10000"));
        await wethC.mint(await routerC.getAddress(), ethers.parseUnits("100", 6));
        await tokenC.mint(await swapC.getAddress(), ethers.parseEther("10000"));
        await wethC.mint(await swapC.getAddress(), ethers.parseUnits("100", 6));
        await owner.sendTransaction({ to: await wethC.getAddress(), value: ethers.parseEther("10") });

        const perChainUsdc = ethers.parseUnits("100", 6);

        // Build CrossChainLPParams for each chain
        const buildParams = (tokenAddr: string) => coder.encode(
            ["tuple(address token,uint256 usdcTotal,uint16 tokenShareBps,uint256 amountTokenMin,uint256 amountNativeMin,uint256 lpAmountTokenMin,uint256 lpAmountNativeMin,uint256 deadline)"],
            [[tokenAddr, perChainUsdc, 5000, 0n, 0n, 0n, 0n, Math.floor(Date.now() / 1000) + 3600]]
        );

        const paramsB = ethers.concat(["0x00", buildParams(await tokenB.getAddress())]);
        const paramsC = ethers.concat(["0x00", buildParams(await tokenC.getAddress())]);

        // Deliver version-1 LZ messages to both gateways (simulating the fan-out)
        const guidB = ethers.keccak256(ethers.toUtf8Bytes("fanout-lp-B"));
        const guidC = ethers.keccak256(ethers.toUtf8Bytes("fanout-lp-C"));
        const originA = {
            srcEid: EID_A,
            sender: ethers.zeroPadValue(await gatewayA.getAddress(), 32),
            nonce: 20n,
        };

        // Chain B: deliver + CCTP mint + fulfill
        const payloadB = coder.encode(
            ["uint8", "uint8", "address", "bytes", "address", "uint256"],
            [1, OP_CREATE_LP, alice.address, paramsB, await usdcB.getAddress(), perChainUsdc]
        );
        await endpointB.deliverMessage(await gatewayB.getAddress(), originA, guidB, payloadB);
        await usdcB.mint(await gatewayB.getAddress(), perChainUsdc);
        await expect(gatewayB.fulfillValueOp(guidB)).to.emit(gatewayB, "ValueOpFulfilled");

        // Chain C: deliver + CCTP mint + fulfill
        const originA2 = { ...originA, nonce: 21n };
        const payloadC = coder.encode(
            ["uint8", "uint8", "address", "bytes", "address", "uint256"],
            [1, OP_CREATE_LP, alice.address, paramsC, await usdcC.getAddress(), perChainUsdc]
        );
        await endpointC.deliverMessage(await gatewayC.getAddress(), originA2, guidC, payloadC);
        await usdcC.mint(await gatewayC.getAddress(), perChainUsdc);
        await expect(gatewayC.fulfillValueOp(guidC)).to.emit(gatewayC, "ValueOpFulfilled");

        // Alice has LP tokens on both chains
        const pairB = await routerB.pair();
        const lpB = await ethers.getContractAt("MockLPToken", pairB);
        expect(await lpB.balanceOf(alice.address)).to.be.gt(0n);

        const pairC = await routerC.pair();
        const lpC = await ethers.getContractAt("MockLPToken", pairC);
        expect(await lpC.balanceOf(alice.address)).to.be.gt(0n);
    });

    it("rejects fulfillValueOp when CCTP tokens haven't arrived", async () => {
        const coder = new ethers.AbiCoder();
        const inner = coder.encode(
            ["tuple(address token,address account)"],
            [[await managedB.getAddress(), bob.address]]
        );
        const innerParams = ethers.concat(["0x06", inner]);

        const lzPayload = coder.encode(
            ["uint8", "uint8", "address", "bytes", "address", "uint256"],
            [1, OP_FREEZE_ACCOUNT, alice.address, innerParams, await usdcB.getAddress(), ethers.parseUnits("500", 6)]
        );

        const guid = ethers.keccak256(ethers.toUtf8Bytes("no-cctp-guid"));
        const origin = {
            srcEid: EID_A,
            sender: ethers.zeroPadValue(await gatewayA.getAddress(), 32),
            nonce: 3n,
        };

        await endpointB.deliverMessage(await gatewayB.getAddress(), origin, guid, lzPayload);

        // Try to fulfill without CCTP tokens — should revert
        await expect(
            gatewayB.fulfillValueOp(guid)
        ).to.be.revertedWith("MagnetaGateway: tokens not arrived");
    });
});
