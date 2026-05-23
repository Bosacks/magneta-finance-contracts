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

    it("mints to a recipient and charges at least the flat fee", async () => {
        // Sprint 9.5 SSP_127138_373 fix: usdcFee must be >= flatFeeUsdc on
        // local-origin mints. We pass exactly the flat fee (V1 minimum); V1.1
        // will compute the percentage value-based fee via price oracle.
        const amount = ethers.parseEther("1000");
        const fee = await tokenOps.flatFeeUsdc();

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

    it("rejects MINT with usdcFee below the flat-fee minimum (Sprint 9.5)", async () => {
        const encoded = coder.encode(
            ["tuple(address token,address to,uint256 amount,uint256 usdcFee,uint256 deadline)"],
            [[
                await token.getAddress(),
                user.address,
                ethers.parseEther("1000"),
                0n,                                                            // bypass attempt
                (await ethers.provider.getBlock("latest"))!.timestamp + 3600,
            ]]
        );
        const params = ethers.concat(["0x04", encoded]);

        await expect(
            gateway.connect(admin).executeOperation(OP_MINT, params),
        ).to.be.revertedWith("MagnetaOps: fee below minimum");
    });

    it("rejects MINT from a non-admin caller", async () => {
        const fee = await tokenOps.flatFeeUsdc();
        const encoded = coder.encode(
            ["tuple(address token,address to,uint256 amount,uint256 usdcFee,uint256 deadline)"],
            [[await token.getAddress(), user.address, 1n, fee, (await ethers.provider.getBlock("latest"))!.timestamp + 3600]]
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

    // ─── Sprint 9.5 — permissionless registerByTokenOwner ──────────────────
    //
    // Critical fix: under the OFT pattern (Sprint 1+) the token's owner is the
    // creator, not the TokenOpsModule. The original `registerToken` paths
    // (owner/admin self-attestation when token is owned by module) don't
    // apply, so a fresh token can never be registered without this fallback.
    //
    // `registerByTokenOwner` is permissionless — anyone calls it, the module
    // reads `token.owner()` on-chain and registers that address. Used by:
    //   1. TokenCreationModule._maybeRegisterToken (auto-on-create)
    //   2. Magneta listener as a retroactive backstop
    //   3. The user themselves if both above paths fail

    describe("registerByTokenOwner (Sprint 9.5)", function () {
        it("registers the on-chain owner as admin without any auth check", async () => {
            // Deploy a fresh managed token owned by `user` (not by tokenOps).
            const Managed = await ethers.getContractFactory("MockManagedToken");
            const freshToken = await Managed.deploy("Solo", "SOLO");
            await freshToken.transferOwnership(user.address);

            expect(await tokenOps.tokenAdmin(await freshToken.getAddress())).to.equal(ethers.ZeroAddress);

            // Anyone (admin signer here, but truly any EOA) can call this.
            await expect(
                tokenOps.connect(admin).registerByTokenOwner(await freshToken.getAddress())
            )
                .to.emit(tokenOps, "TokenRegistered")
                .withArgs(await freshToken.getAddress(), user.address);

            expect(await tokenOps.tokenAdmin(await freshToken.getAddress())).to.equal(user.address);
        });

        it("reverts if already registered (idempotent guard)", async () => {
            // `token` was already registered with `admin` in the outer beforeEach.
            await expect(
                tokenOps.connect(user).registerByTokenOwner(await token.getAddress())
            ).to.be.revertedWith("already registered");
        });

        it("emits PermissionlessTokenRegistered for off-chain monitoring (Sentinelle MED SC01)", async () => {
            const Managed = await ethers.getContractFactory("MockManagedToken");
            const freshToken = await Managed.deploy("Solo2", "SOLO2");
            await freshToken.transferOwnership(user.address);
            await expect(
                tokenOps.connect(admin).registerByTokenOwner(await freshToken.getAddress())
            )
                .to.emit(tokenOps, "PermissionlessTokenRegistered")
                .withArgs(await freshToken.getAddress(), user.address, admin.address);
        });
    });

    describe("Sentinelle HIGH SC01 — registerToken trusted-registrar gate", function () {
        it("removed self-registration branch: admin cannot self-register even when module owns the token", async () => {
            const Managed = await ethers.getContractFactory("MockManagedToken");
            const t = await Managed.deploy("X", "X");
            // Token's owner == module — the OLD self-reg attack precondition.
            await t.transferOwnership(await tokenOps.getAddress());
            // `user` (not owner, not trusted) tries to register themselves
            // as admin. Pre-patch this would have succeeded.
            await expect(
                tokenOps.connect(user).registerToken(await t.getAddress(), user.address)
            ).to.be.revertedWith("not authorized");
        });

        it("owner-set trusted registrar can call registerToken", async () => {
            const Managed = await ethers.getContractFactory("MockManagedToken");
            const t = await Managed.deploy("Y", "Y");
            await t.transferOwnership(await tokenOps.getAddress());

            // user is not trusted yet
            await expect(
                tokenOps.connect(user).registerToken(await t.getAddress(), admin.address)
            ).to.be.revertedWith("not authorized");

            // Owner whitelists user
            await expect(tokenOps.setTrustedRegistrar(user.address, true))
                .to.emit(tokenOps, "TrustedRegistrarUpdated")
                .withArgs(user.address, true);

            // Now user can call
            await expect(
                tokenOps.connect(user).registerToken(await t.getAddress(), admin.address)
            ).to.emit(tokenOps, "TokenRegistered");

            // Revoke and re-confirm closed
            await tokenOps.setTrustedRegistrar(user.address, false);
            const Managed2 = await ethers.getContractFactory("MockManagedToken");
            const t2 = await Managed2.deploy("Z", "Z");
            await t2.transferOwnership(await tokenOps.getAddress());
            await expect(
                tokenOps.connect(user).registerToken(await t2.getAddress(), admin.address)
            ).to.be.revertedWith("not authorized");
        });

        it("non-owner cannot set trusted registrars", async () => {
            await expect(
                tokenOps.connect(user).setTrustedRegistrar(user.address, true)
            ).to.be.reverted;
        });

        it("setTrustedRegistrar rejects zero address", async () => {
            await expect(
                tokenOps.setTrustedRegistrar(ethers.ZeroAddress, true)
            ).to.be.revertedWith("zero registrar");
        });
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

    it("Sentinelle HIGH SC02 — pre-call USDC donation does NOT inflate fee/burn (uses router return value)", async () => {
        const Messenger = await ethers.getContractFactory("MockCctpMessenger");
        const messenger = await Messenger.deploy();
        await swapModule.setCctpMessenger(await messenger.getAddress());

        const amountIn = ethers.parseUnits("100", 6);
        await tokenIn.mint(user.address, amountIn);
        await tokenIn.connect(user).approve(await swapModule.getAddress(), amountIn);

        // Attacker donates 1000 USDC directly to the module BEFORE the swap.
        // Pre-patch this would have inflated usdcOut from 100 → 1100 and
        // exploded the fee (15bps × 1100) + burn (1100 - fee).
        const donation = ethers.parseUnits("1000", 6);
        await usdc.mint(await swapModule.getAddress(), donation);

        const encoded = coder.encode(
            [
                "tuple(address tokenIn,uint256 amountIn,uint256 amountOutMin,address[] path,uint32 dstDomain,bytes32 recipient,uint256 deadline)"
            ],
            [[
                await tokenIn.getAddress(), amountIn, 0n,
                [await tokenIn.getAddress(), await usdc.getAddress()],
                6, ethers.zeroPadValue(user.address, 32),
                (await ethers.provider.getBlock("latest"))!.timestamp + 3600,
            ]]
        );
        const params = ethers.concat(["0x0c", encoded]);

        const vaultBefore = await usdc.balanceOf(feeVault.address);
        const messengerBefore = await usdc.balanceOf(await messenger.getAddress());

        await gateway.connect(user).executeOperation(OP_SWAP_OUT, params);

        const fee = (amountIn * 15n) / 10_000n;
        // Fee and burn reflect ONLY the router output, not the donation.
        expect((await usdc.balanceOf(feeVault.address)) - vaultBefore).to.equal(fee);
        expect((await usdc.balanceOf(await messenger.getAddress())) - messengerBefore).to.equal(amountIn - fee);
        // The donation stays on the module (rescuable separately).
        expect(await usdc.balanceOf(await swapModule.getAddress())).to.equal(donation);
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

    describe("Sentinelle hardening (audit 2026-05-22)", function () {
        it("MEDIUM SC01 — non-owner non-registrar cannot register", async () => {
            const TaxToken = await ethers.getContractFactory("MockTaxToken");
            const t = await TaxToken.deploy("X", "X");
            await expect(
                tax.connect(admin).registerToken(await t.getAddress(), admin.address)
            ).to.be.revertedWith("not authorized");
        });

        it("MEDIUM SC01 — trusted registrar can register, revoke works", async () => {
            const TaxToken = await ethers.getContractFactory("MockTaxToken");
            const t = await TaxToken.deploy("Y", "Y");

            await expect(tax.setTrustedRegistrar(admin.address, true))
                .to.emit(tax, "TrustedRegistrarUpdated")
                .withArgs(admin.address, true);

            await expect(
                tax.connect(admin).registerToken(await t.getAddress(), admin.address)
            ).to.emit(tax, "TokenRegistered");

            await tax.setTrustedRegistrar(admin.address, false);
            const t2 = await TaxToken.deploy("Z", "Z");
            await expect(
                tax.connect(admin).registerToken(await t2.getAddress(), admin.address)
            ).to.be.revertedWith("not authorized");
        });

        it("setTrustedRegistrar rejects zero, owner-only", async () => {
            await expect(tax.setTrustedRegistrar(ethers.ZeroAddress, true))
                .to.be.revertedWith("zero registrar");
            await expect(tax.connect(admin).setTrustedRegistrar(admin.address, true))
                .to.be.reverted;
        });
    });
});
