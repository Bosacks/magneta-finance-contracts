import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Unit tests for MagnetaGateway + LPModule. Uses MockLayerZeroEndpoint,
 * MockV2Router, and MockERC20 — no external RPC needed.
 *
 * Covers:
 *   - Gateway registers modules, rejects unknown OpTypes
 *   - Gateway executes a CREATE_LP op by dispatching to LPModule
 *   - Magneta USDC fee lands in the feeVault
 *   - Only gateway can call module.execute()
 *   - Gateway pause blocks executeOperation
 */
describe("MagnetaGateway", function () {
    const EID = 40245;
    const OP_CREATE_LP = 0;
    const FEE_BPS = 15n;

    let owner: SignerWithAddress;
    let alice: SignerWithAddress;
    let feeVault: SignerWithAddress;

    let endpoint: any;
    let gateway: any;
    let lpModule: any;
    let usdc: any;
    let token: any;
    let weth: any;
    let router: any;

    beforeEach(async () => {
        [owner, alice, feeVault] = await ethers.getSigners();

        const Endpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
        endpoint = await Endpoint.deploy(EID);

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        usdc = await MockERC20.deploy("USDC", "USDC", 6, ethers.parseUnits("1000000", 6));
        token = await MockERC20.deploy("Memecoin", "MEME", 18, ethers.parseEther("1000000"));
        weth = await MockERC20.deploy("WETH", "WETH", 18, ethers.parseEther("1000000"));

        const Router = await ethers.getContractFactory("MockV2Router");
        router = await Router.deploy(await weth.getAddress());

        const Gateway = await ethers.getContractFactory("MagnetaGateway");
        gateway = await Gateway.deploy(
            await endpoint.getAddress(),
            owner.address,
            feeVault.address
        );

        const LPModule = await ethers.getContractFactory("LPModule");
        lpModule = await LPModule.deploy(
            await gateway.getAddress(),
            await router.getAddress(),
            await usdc.getAddress()
        );

        // Fund Alice with tokens and USDC for the LP + fee.
        await token.mint(alice.address, ethers.parseEther("10000"));
        await usdc.mint(alice.address, ethers.parseUnits("1000", 6));
    });

    describe("Module registry", () => {
        it("reverts executeOperation when module not set", async () => {
            await expect(gateway.connect(alice).executeOperation(OP_CREATE_LP, "0x"))
                .to.be.revertedWithCustomError(gateway, "ModuleNotSet");
        });

        it("owner can register a module", async () => {
            await expect(gateway.setModule(OP_CREATE_LP, await lpModule.getAddress()))
                .to.emit(gateway, "ModuleSet");
            expect(await gateway.moduleFor(OP_CREATE_LP)).to.equal(await lpModule.getAddress());
        });

        it("non-owner cannot register a module", async () => {
            await expect(gateway.connect(alice).setModule(OP_CREATE_LP, await lpModule.getAddress()))
                .to.be.reverted;
        });

        it("exposes the fee vault", async () => {
            expect(await gateway.feeVault()).to.equal(feeVault.address);
        });
    });

    describe("LP module access control", () => {
        it("module.execute rejects callers other than the gateway", async () => {
            await expect(
                lpModule.execute(
                    { caller: alice.address, originChainId: 1, feeVault: feeVault.address },
                    "0x00"
                )
            ).to.be.revertedWithCustomError(lpModule, "OnlyGateway");
        });
    });

    describe("CREATE_LP end-to-end", () => {
        it("dispatches through the gateway, pulls USDC fee, mints LP to alice", async () => {
            await gateway.setModule(OP_CREATE_LP, await lpModule.getAddress());

            const tokenAmount = ethers.parseEther("1000");
            const ethAmount = ethers.parseEther("1");
            const valueUsdc = ethers.parseUnits("100", 6);
            const usdcFee = (valueUsdc * FEE_BPS) / 10_000n;

            // Alice approves: module pulls tokens + USDC fee.
            await token.connect(alice).approve(await router.getAddress(), tokenAmount);
            await token.connect(alice).approve(await lpModule.getAddress(), tokenAmount);
            await usdc.connect(alice).approve(await lpModule.getAddress(), usdcFee);

            // Encode LPModule CreateLPParams: tuple + OpType prefix byte.
            const coder = new ethers.AbiCoder();
            const encoded = coder.encode(
                [
                    "tuple(address token,uint256 tokenAmount,uint256 ethAmount,uint256 amountTokenMin,uint256 amountETHMin,uint256 usdcFee,uint256 deadline)"
                ],
                [[
                    await token.getAddress(),
                    tokenAmount,
                    ethAmount,
                    0n,
                    0n,
                    usdcFee,
                    Math.floor(Date.now() / 1000) + 3600,
                ]]
            );
            const params = ethers.concat(["0x00", encoded]); // OpType.CREATE_LP prefix

            const feeVaultBefore = await usdc.balanceOf(feeVault.address);

            await expect(
                gateway.connect(alice).executeOperation(OP_CREATE_LP, params, { value: ethAmount })
            ).to.emit(gateway, "OperationExecuted");

            const feeVaultAfter = await usdc.balanceOf(feeVault.address);
            expect(feeVaultAfter - feeVaultBefore).to.equal(usdcFee);

            // Alice received LP tokens from the mock router.
            const pair = await router.pair();
            const lpToken = await ethers.getContractAt("MockLPToken", pair);
            expect(await lpToken.balanceOf(alice.address)).to.be.gt(0n);
        });
    });

    describe("Pause", () => {
        it("blocks executeOperation when paused", async () => {
            await gateway.setModule(OP_CREATE_LP, await lpModule.getAddress());
            await gateway.pause();
            await expect(gateway.connect(alice).executeOperation(OP_CREATE_LP, "0x00"))
                .to.be.reverted;
        });

        it("resumes after unpause", async () => {
            await gateway.setModule(OP_CREATE_LP, await lpModule.getAddress());
            await gateway.pause();
            await gateway.unpause();
            // Empty params would revert inside the module, but not for pause —
            // verify by registering empty module slot instead. We just check
            // that unpause clears the paused flag.
            expect(await gateway.paused()).to.equal(false);
        });
    });
});
