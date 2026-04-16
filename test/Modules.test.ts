import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Unit tests for the 3 remaining modules: TokenOpsModule, SwapModule,
 * TaxClaimModule. Each is exercised through MagnetaGateway using the same
 * (OpType prefix + abi.encode(tuple)) calling convention the SDK uses.
 */

// OpType ordinals mirror the Solidity enum in IMagnetaGateway.sol.
const OP_BURN_LP            = 2;
const OP_MINT               = 4;
const OP_UPDATE_METADATA    = 5;
const OP_FREEZE_ACCOUNT     = 6;
const OP_UNFREEZE_ACCOUNT   = 7;
const OP_REVOKE_PERMISSION  = 9;
const OP_CLAIM_TAX_FEES     = 10;
const OP_SWAP_LOCAL         = 11;
const OP_SWAP_OUT           = 12;

const EID = 40245;

async function deployCommon() {
    const [owner, admin, user, feeVault] = await ethers.getSigners();

    const Endpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
    const endpoint = await Endpoint.deploy(EID);

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdc  = await MockERC20.deploy("USDC", "USDC", 6, ethers.parseUnits("1000000", 6));
    const weth  = await MockERC20.deploy("WETH", "WETH", 18, ethers.parseEther("1000000"));

    const Gateway = await ethers.getContractFactory("MagnetaGateway");
    const gateway = await Gateway.deploy(
        await endpoint.getAddress(),
        owner.address,
        feeVault.address
    );

    return { owner, admin, user, feeVault, endpoint, usdc, weth, gateway };
}

describe("TokenOpsModule", function () {
    let owner: SignerWithAddress, admin: SignerWithAddress, user: SignerWithAddress, feeVault: SignerWithAddress;
    let gateway: any, usdc: any, tokenOps: any, token: any;
    const coder = new ethers.AbiCoder();

    beforeEach(async () => {
        ({ owner, admin, user, feeVault, gateway, usdc } = await deployCommon());

        const TokenOps = await ethers.getContractFactory("TokenOpsModule");
        tokenOps = await TokenOps.deploy(await gateway.getAddress(), await usdc.getAddress());

        // Register module for all token-op OpTypes.
        for (const op of [OP_MINT, OP_UPDATE_METADATA, OP_FREEZE_ACCOUNT, OP_UNFREEZE_ACCOUNT, OP_REVOKE_PERMISSION]) {
            await gateway.setModule(op, await tokenOps.getAddress());
        }

        // Deploy managed token and transfer ownership to the module.
        const Managed = await ethers.getContractFactory("MockManagedToken");
        token = await Managed.deploy("Brand", "BR");
        await token.transferOwnership(await tokenOps.getAddress());

        // Admin registers the token. Module.owner() is the deployer (owner),
        // so we register via the deployer path to skip marketingWallet checks.
        await tokenOps.registerToken(await token.getAddress(), admin.address);

        // Fund admin with USDC for flat fees.
        await usdc.mint(admin.address, ethers.parseUnits("100", 6));
        await usdc.connect(admin).approve(await tokenOps.getAddress(), ethers.MaxUint256);
    });

    it("registers the token + admin", async () => {
        expect(await tokenOps.tokenAdmin(await token.getAddress())).to.equal(admin.address);
    });

    it("mints to a recipient and charges the 0.15% fee", async () => {
        const amount = ethers.parseEther("1000");
        const valueUsdc = ethers.parseUnits("10", 6);
        const fee = (valueUsdc * 15n) / 10_000n;

        const encoded = coder.encode(
            ["tuple(address token,address to,uint256 amount,uint256 usdcFee,uint256 deadline)"],
            [[
                await token.getAddress(),
                user.address,
                amount,
                fee,
                (await ethers.provider.getBlock("latest"))!.timestamp + 3600,
            ]]
        );
        const params = ethers.concat(["0x04", encoded]);

        const vaultBefore = await usdc.balanceOf(feeVault.address);

        await expect(gateway.connect(admin).executeOperation(OP_MINT, params))
            .to.emit(tokenOps, "OpForwarded");

        expect(await token.balanceOf(user.address)).to.equal(amount);
        expect(await usdc.balanceOf(feeVault.address) - vaultBefore).to.equal(fee);
    });

    it("rejects MINT from a non-admin caller", async () => {
        const encoded = coder.encode(
            ["tuple(address token,address to,uint256 amount,uint256 usdcFee,uint256 deadline)"],
            [[await token.getAddress(), user.address, 1n, 0n, (await ethers.provider.getBlock("latest"))!.timestamp + 3600]]
        );
        const params = ethers.concat(["0x04", encoded]);

        await expect(gateway.connect(user).executeOperation(OP_MINT, params))
            .to.be.revertedWithCustomError(tokenOps, "NotAuthorized");
    });

    it("freezes and unfreezes an account, charging flat $1 each time", async () => {
        const flat = await tokenOps.flatFeeUsdc();
        const enc = coder.encode(
            ["tuple(address token,address account)"],
            [[await token.getAddress(), user.address]]
        );
        const paramsFreeze   = ethers.concat(["0x06", enc]);
        const paramsUnfreeze = ethers.concat(["0x07", enc]);

        const vaultBefore = await usdc.balanceOf(feeVault.address);

        await gateway.connect(admin).executeOperation(OP_FREEZE_ACCOUNT, paramsFreeze);
        expect(await token.frozen(user.address)).to.equal(true);

        await gateway.connect(admin).executeOperation(OP_UNFREEZE_ACCOUNT, paramsUnfreeze);
        expect(await token.frozen(user.address)).to.equal(false);

        expect(await usdc.balanceOf(feeVault.address) - vaultBefore).to.equal(flat * 2n);
    });

    it("updates metadata and charges flat fee", async () => {
        const encoded = coder.encode(
            ["tuple(address token,string newURI)"],
            [[await token.getAddress(), "ipfs://new"]]
        );
        const params = ethers.concat(["0x05", encoded]);

        await gateway.connect(admin).executeOperation(OP_UPDATE_METADATA, params);
        expect(await token.tokenURI()).to.equal("ipfs://new");
    });

    it("revokes mint permission (one-way)", async () => {
        const encoded = coder.encode(
            ["tuple(address token,uint8 kind)"],
            [[await token.getAddress(), 2]] // 2 = MINT
        );
        const params = ethers.concat(["0x09", encoded]);

        await gateway.connect(admin).executeOperation(OP_REVOKE_PERMISSION, params);
        expect(await token.revokedMint()).to.equal(true);

        // Subsequent mint should revert inside the managed token.
        const mintEncoded = coder.encode(
            ["tuple(address token,address to,uint256 amount,uint256 usdcFee,uint256 deadline)"],
            [[await token.getAddress(), user.address, 1n, 0n, (await ethers.provider.getBlock("latest"))!.timestamp + 3600]]
        );
        await expect(
            gateway.connect(admin).executeOperation(OP_MINT, ethers.concat(["0x04", mintEncoded]))
        ).to.be.reverted;
    });
});

describe("SwapModule", function () {
    let owner: SignerWithAddress, user: SignerWithAddress, feeVault: SignerWithAddress;
    let gateway: any, usdc: any, weth: any, tokenIn: any, tokenOut: any;
    let router: any, swapModule: any;
    const coder = new ethers.AbiCoder();

    beforeEach(async () => {
        const common = await deployCommon();
        owner = common.owner; user = common.user; feeVault = common.feeVault;
        gateway = common.gateway; usdc = common.usdc; weth = common.weth;

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        tokenIn  = await MockERC20.deploy("IN", "IN", 18, ethers.parseEther("1000000"));
        tokenOut = await MockERC20.deploy("OUT", "OUT", 18, ethers.parseEther("1000000"));

        const Router = await ethers.getContractFactory("MockV2Router");
        router = await Router.deploy(await weth.getAddress());

        const SwapModule = await ethers.getContractFactory("SwapModule");
        swapModule = await SwapModule.deploy(
            await gateway.getAddress(),
            await router.getAddress(),
            await usdc.getAddress()
        );

        await gateway.setModule(OP_SWAP_LOCAL, await swapModule.getAddress());
        await gateway.setModule(OP_SWAP_OUT,   await swapModule.getAddress());

        // Fund user and pre-fund the router with output tokens so 1:1 mock swap works.
        await tokenIn.mint(user.address, ethers.parseEther("1000"));
        await tokenOut.mint(await router.getAddress(), ethers.parseEther("1000"));
        await usdc.mint(await router.getAddress(), ethers.parseUnits("1000", 6));
    });

    it("executes SWAP_LOCAL and sends 0.15% of output to feeVault", async () => {
        const amountIn = ethers.parseEther("100");

        await tokenIn.connect(user).approve(await swapModule.getAddress(), amountIn);

        const encoded = coder.encode(
            [
                "tuple(address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,address[] path,address recipient,uint256 deadline)"
            ],
            [[
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                0n,
                [await tokenIn.getAddress(), await tokenOut.getAddress()],
                user.address,
                (await ethers.provider.getBlock("latest"))!.timestamp + 3600,
            ]]
        );
        const params = ethers.concat(["0x0b", encoded]);

        const vaultBefore = await tokenOut.balanceOf(feeVault.address);
        const userBefore  = await tokenOut.balanceOf(user.address);

        await expect(gateway.connect(user).executeOperation(OP_SWAP_LOCAL, params))
            .to.emit(swapModule, "LocalSwap");

        const fee = (amountIn * 15n) / 10_000n;
        expect(await tokenOut.balanceOf(feeVault.address) - vaultBefore).to.equal(fee);
        expect(await tokenOut.balanceOf(user.address) - userBefore).to.equal(amountIn - fee);
    });

    it("SWAP_OUT reverts when CCTP messenger is not configured", async () => {
        const amountIn = ethers.parseEther("50");
        await tokenIn.connect(user).approve(await swapModule.getAddress(), amountIn);

        const encoded = coder.encode(
            [
                "tuple(address tokenIn,uint256 amountIn,uint256 amountOutMin,address[] path,uint32 dstDomain,bytes32 recipient,uint256 deadline)"
            ],
            [[
                await tokenIn.getAddress(),
                amountIn,
                0n,
                [await tokenIn.getAddress(), await usdc.getAddress()],
                6,
                ethers.zeroPadValue(user.address, 32),
                (await ethers.provider.getBlock("latest"))!.timestamp + 3600,
            ]]
        );
        const params = ethers.concat(["0x0c", encoded]);

        await expect(gateway.connect(user).executeOperation(OP_SWAP_OUT, params))
            .to.be.revertedWithCustomError(swapModule, "CctpDisabled");
    });

    it("SWAP_OUT with configured CCTP burns net USDC to treasury and fees to vault", async () => {
        const Messenger = await ethers.getContractFactory("MockCctpMessenger");
        const messenger = await Messenger.deploy();
        await swapModule.setCctpMessenger(await messenger.getAddress());

        // Shift the 1:1 swap output: tokenIn 18d → USDC 6d. Our mock router is
        // 1:1 on units — so amountIn (in tokenIn base units) == USDC wei out.
        // Use small amountIn so we stay under the router's USDC pool.
        const amountIn = ethers.parseUnits("100", 6); // 100 tokenIn units → 100 USDC "units" (wei-equivalent)
        await tokenIn.mint(user.address, amountIn);
        await tokenIn.connect(user).approve(await swapModule.getAddress(), amountIn);

        const encoded = coder.encode(
            [
                "tuple(address tokenIn,uint256 amountIn,uint256 amountOutMin,address[] path,uint32 dstDomain,bytes32 recipient,uint256 deadline)"
            ],
            [[
                await tokenIn.getAddress(),
                amountIn,
                0n,
                [await tokenIn.getAddress(), await usdc.getAddress()],
                6,
                ethers.zeroPadValue(user.address, 32),
                (await ethers.provider.getBlock("latest"))!.timestamp + 3600,
            ]]
        );
        const params = ethers.concat(["0x0c", encoded]);

        await expect(gateway.connect(user).executeOperation(OP_SWAP_OUT, params))
            .to.emit(messenger, "Burned");

        const fee = (amountIn * 15n) / 10_000n;
        expect(await usdc.balanceOf(feeVault.address)).to.equal(fee);
        expect(await usdc.balanceOf(await messenger.getAddress())).to.equal(amountIn - fee);
    });
});

describe("TaxClaimModule", function () {
    let owner: SignerWithAddress, admin: SignerWithAddress, feeVault: SignerWithAddress;
    let gateway: any, usdc: any, weth: any, taxToken: any, router: any, tax: any, messenger: any;
    const coder = new ethers.AbiCoder();

    beforeEach(async () => {
        const common = await deployCommon();
        owner = common.owner; admin = common.admin; feeVault = common.feeVault;
        gateway = common.gateway; usdc = common.usdc; weth = common.weth;

        const Router = await ethers.getContractFactory("MockV2Router");
        router = await Router.deploy(await weth.getAddress());

        const TaxClaim = await ethers.getContractFactory("TaxClaimModule");
        tax = await TaxClaim.deploy(
            await gateway.getAddress(),
            await router.getAddress(),
            await usdc.getAddress()
        );
        await gateway.setModule(OP_CLAIM_TAX_FEES, await tax.getAddress());

        // Tax-bearing token.
        const TaxTok = await ethers.getContractFactory("MockTaxToken");
        taxToken = await TaxTok.deploy("Tax", "TAX");
        await taxToken.setMarketingWallet(await tax.getAddress());

        // Register with deployer path (module owner = test owner).
        await tax.registerToken(await taxToken.getAddress(), admin.address);

        // Pre-fund router USDC pool so swaps can settle. Mock router is 1:1.
        await usdc.mint(await router.getAddress(), ethers.parseUnits("1000000", 6));

        const Messenger = await ethers.getContractFactory("MockCctpMessenger");
        messenger = await Messenger.deploy();
    });

    it("reverts when nothing to claim (no fees accrued)", async () => {
        const encoded = coder.encode(
            ["tuple(address token,uint256 amountOutMin,uint256 deadline,bool bridgeToTreasury)"],
            [[await taxToken.getAddress(), 0n, (await ethers.provider.getBlock("latest"))!.timestamp + 3600, false]]
        );
        await expect(gateway.connect(admin).executeOperation(OP_CLAIM_TAX_FEES, encoded))
            .to.be.revertedWithCustomError(tax, "NothingToClaim");
    });

    it("reverts below the $20 USDC threshold", async () => {
        // Seed 10 units of token → 10 wei of USDC out (1:1 mock). Below $20.
        await taxToken.seedPending(10n);
        const encoded = coder.encode(
            ["tuple(address token,uint256 amountOutMin,uint256 deadline,bool bridgeToTreasury)"],
            [[await taxToken.getAddress(), 0n, (await ethers.provider.getBlock("latest"))!.timestamp + 3600, false]]
        );
        await expect(gateway.connect(admin).executeOperation(OP_CLAIM_TAX_FEES, encoded))
            .to.be.revertedWithCustomError(tax, "BelowThreshold");
    });

    it("claims above threshold and sends adminNet to admin (no bridge)", async () => {
        // $100 USDC equivalent gross.
        const gross = ethers.parseUnits("100", 6);
        await taxToken.seedPending(gross);

        const encoded = coder.encode(
            ["tuple(address token,uint256 amountOutMin,uint256 deadline,bool bridgeToTreasury)"],
            [[await taxToken.getAddress(), 0n, (await ethers.provider.getBlock("latest"))!.timestamp + 3600, false]]
        );

        const fee = (gross * 15n) / 10_000n;
        const net = gross - fee;

        await expect(gateway.connect(admin).executeOperation(OP_CLAIM_TAX_FEES, encoded))
            .to.emit(tax, "TaxClaimed");

        expect(await usdc.balanceOf(feeVault.address)).to.equal(fee);
        expect(await usdc.balanceOf(admin.address)).to.equal(net);
    });

    it("claims and bridges net USDC via CCTP when bridgeToTreasury=true", async () => {
        const gross = ethers.parseUnits("100", 6);
        await taxToken.seedPending(gross);

        await tax.setCctpRoute(
            await messenger.getAddress(),
            6,
            ethers.zeroPadValue(admin.address, 32)
        );

        const encoded = coder.encode(
            ["tuple(address token,uint256 amountOutMin,uint256 deadline,bool bridgeToTreasury)"],
            [[await taxToken.getAddress(), 0n, (await ethers.provider.getBlock("latest"))!.timestamp + 3600, true]]
        );

        const fee = (gross * 15n) / 10_000n;
        const net = gross - fee;

        await expect(gateway.connect(admin).executeOperation(OP_CLAIM_TAX_FEES, encoded))
            .to.emit(messenger, "Burned");

        expect(await usdc.balanceOf(feeVault.address)).to.equal(fee);
        expect(await usdc.balanceOf(await messenger.getAddress())).to.equal(net);
        // Admin does NOT receive USDC locally — it lands at the destination domain.
        expect(await usdc.balanceOf(admin.address)).to.equal(0n);
    });
});
