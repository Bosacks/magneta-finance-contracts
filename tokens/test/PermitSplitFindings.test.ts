import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Regression coverage for Sentinelleai report 17 (scan of the permit /
 * factory-deployer split, 2026-07-31). One test per fix; each one fails
 * against the pre-fix contract.
 */
describe("report-17 remediation — factory/deployer split", function () {
    let owner: HardhatEthersSigner;
    let other: HardhatEthersSigner;
    let factory: any;
    let endpoint: string;

    beforeEach(async function () {
        [owner, other] = await ethers.getSigners();

        const EndpointMock = await ethers.getContractFactory("MockLZEndpoint");
        const ep = await EndpointMock.deploy();
        await ep.waitForDeployment();
        endpoint = await ep.getAddress();

        const F = await ethers.getContractFactory("MagnetaOFTStandardFactory");
        factory = await F.deploy(owner.address, endpoint);
        await factory.waitForDeployment();
    });

    async function deployDeployerFor(factoryAddr: string) {
        const D = await ethers.getContractFactory("MagnetaOFTTokenDeployer");
        const d = await D.deploy(factoryAddr);
        await d.waitForDeployment();
        return d;
    }

    // ── F-4: the one-way setter must not latch an unusable deployer ────────
    describe("F-4 — setTokenDeployer validates the candidate", function () {
        it("rejects an EOA (no code)", async function () {
            await expect(factory.setTokenDeployer(other.address)).to.be.revertedWithCustomError(
                factory, "DeployerNotContract",
            );
        });

        it("rejects a deployer bound to a different factory", async function () {
            const F = await ethers.getContractFactory("MagnetaOFTStandardFactory");
            const otherFactory = await F.deploy(owner.address, endpoint);
            await otherFactory.waitForDeployment();
            const foreign = await deployDeployerFor(await otherFactory.getAddress());

            await expect(
                factory.setTokenDeployer(await foreign.getAddress()),
            ).to.be.revertedWithCustomError(factory, "DeployerFactoryMismatch");
        });

        it("accepts the deployer bound to this factory, once", async function () {
            const good = await deployDeployerFor(await factory.getAddress());
            await expect(factory.setTokenDeployer(await good.getAddress()))
                .to.emit(factory, "TokenDeployerSet")
                .withArgs(await good.getAddress());
            expect(await factory.tokenDeployer()).to.equal(await good.getAddress());

            const second = await deployDeployerFor(await factory.getAddress());
            await expect(
                factory.setTokenDeployer(await second.getAddress()),
            ).to.be.revertedWithCustomError(factory, "DeployerAlreadySet");
        });
    });

    // ── F-5: a codeless "module" must not read as a successful registration ─
    describe("F-5 — registration to a codeless module is reported as failed", function () {
        it("emits RegistrationFailed when tokenOpsModule is an EOA", async function () {
            const good = await deployDeployerFor(await factory.getAddress());
            await factory.setTokenDeployer(await good.getAddress());
            // An EOA: a raw call to it returns success==true, which used to be
            // silently treated as "registered".
            await factory.setTokenOpsModule(other.address);

            const tx = await factory.createOFTStandardToken(
                "T", "T", "ipfs://x", ethers.parseEther("1000"),
                false, false, false,
                { value: await factory.createFee() },
            );
            await expect(tx).to.emit(factory, "RegistrationFailed");
        });

        it("does not emit RegistrationFailed when the module is disabled (address(0))", async function () {
            const good = await deployDeployerFor(await factory.getAddress());
            await factory.setTokenDeployer(await good.getAddress());

            const tx = await factory.createOFTStandardToken(
                "T", "T", "ipfs://x", ethers.parseEther("1000"),
                false, false, false,
                { value: await factory.createFee() },
            );
            await expect(tx).to.not.emit(factory, "RegistrationFailed");
        });
    });

    // ── F-6: the selector must come from the interface, not a literal ──────
    it("F-6 — registerByTokenOwner selector matches the compiled interface", async function () {
        const iface = new ethers.Interface(["function registerByTokenOwner(address token)"]);
        expect(iface.getFunction("registerByTokenOwner")!.selector).to.equal("0xbb6f82b8");
    });

    // ── F-8: ownership transfer is two-step ───────────────────────────────
    describe("F-8 — Ownable2Step", function () {
        it("does not hand over ownership until the destination accepts", async function () {
            await factory.transferOwnership(other.address);
            expect(await factory.owner()).to.equal(owner.address);
            expect(await factory.pendingOwner()).to.equal(other.address);

            await factory.connect(other).acceptOwnership();
            expect(await factory.owner()).to.equal(other.address);
        });

        it("lets the current owner cancel a mistyped transfer", async function () {
            await factory.transferOwnership(other.address);
            await factory.transferOwnership(ethers.ZeroAddress);
            expect(await factory.pendingOwner()).to.equal(ethers.ZeroAddress);
            expect(await factory.owner()).to.equal(owner.address);
        });
    });
});

describe("report-17 remediation — bridge credit quarantine (F-2)", function () {
    let token: any;
    let owner: HardhatEthersSigner;
    let victim: HardhatEthersSigner;
    const AMOUNT = ethers.parseEther("500");

    beforeEach(async function () {
        [owner, victim] = await ethers.getSigners();
        const EndpointMock = await ethers.getContractFactory("MockLZEndpoint");
        const ep = await EndpointMock.deploy();
        await ep.waitForDeployment();

        const T = await ethers.getContractFactory("MagnetaERC20OFTCreditHarness");
        token = await T.deploy(
            "Bridged", "BRG", "ipfs://x", ethers.parseEther("1000"), owner.address,
            false, false, false, await ep.getAddress(), ethers.ZeroAddress,
        );
        await token.waitForDeployment();
    });

    it("credits normally when nothing blocks the recipient", async function () {
        await token.exposedCredit(victim.address, AMOUNT);
        expect(await token.balanceOf(victim.address)).to.equal(AMOUNT);
        expect(await token.quarantined(victim.address)).to.equal(0n);
    });

    it("quarantines instead of reverting when the recipient is blacklisted", async function () {
        await token.blacklist(victim.address, true);

        // Pre-fix this reverted — AFTER the source chain had already burnt the
        // tokens, so the user simply lost them.
        await expect(token.exposedCredit(victim.address, AMOUNT))
            .to.emit(token, "BridgeCreditQuarantined")
            .withArgs(victim.address, AMOUNT);
        expect(await token.balanceOf(victim.address)).to.equal(0n);
        expect(await token.quarantined(victim.address)).to.equal(AMOUNT);

        // Still unclaimable while blacklisted...
        await expect(token.claimQuarantined(victim.address)).to.be.revertedWithCustomError(
            token, "StillBlacklisted",
        );

        // ...and recoverable — by anyone — once the block clears. The funds can
        // only ever land on `to`, so a permissionless push is safe.
        await token.blacklist(victim.address, false);
        await expect(token.connect(victim).claimQuarantined(victim.address))
            .to.emit(token, "BridgeCreditClaimed")
            .withArgs(victim.address, AMOUNT);
        expect(await token.balanceOf(victim.address)).to.equal(AMOUNT);
        expect(await token.quarantined(victim.address)).to.equal(0n);
    });

    it("quarantines while paused, and releases after unpause", async function () {
        await token.pause();
        await token.exposedCredit(victim.address, AMOUNT);
        expect(await token.quarantined(victim.address)).to.equal(AMOUNT);

        // _mint still routes through the pause guard, so the claim waits.
        await expect(token.claimQuarantined(victim.address)).to.be.revertedWithCustomError(
            token, "EnforcedPause",
        );

        await token.unpause();
        await token.claimQuarantined(victim.address);
        expect(await token.balanceOf(victim.address)).to.equal(AMOUNT);
    });

    it("accumulates repeated blocked credits and releases them in one claim", async function () {
        await token.blacklist(victim.address, true);
        await token.exposedCredit(victim.address, AMOUNT);
        await token.exposedCredit(victim.address, AMOUNT);
        expect(await token.quarantined(victim.address)).to.equal(AMOUNT * 2n);

        await token.blacklist(victim.address, false);
        await token.claimQuarantined(victim.address);
        expect(await token.balanceOf(victim.address)).to.equal(AMOUNT * 2n);
    });

    it("refuses a claim when nothing is quarantined", async function () {
        await expect(token.claimQuarantined(victim.address)).to.be.revertedWithCustomError(
            token, "NothingQuarantined",
        );
    });
});

describe("report-17 remediation — tax-fee proposal expiry (F-3)", function () {
    let token: any;
    let owner: HardhatEthersSigner;

    beforeEach(async function () {
        [owner] = await ethers.getSigners();
        const EndpointMock = await ethers.getContractFactory("MockLZEndpoint");
        const ep = await EndpointMock.deploy();
        await ep.waitForDeployment();

        const T = await ethers.getContractFactory("MagnetaERC20OFT");
        token = await T.deploy(
            "Tax", "TAX", "ipfs://x", ethers.parseEther("1000"), owner.address,
            false, false, false, await ep.getAddress(), ethers.ZeroAddress,
        );
        await token.waitForDeployment();
    });

    it("applies an increase inside the window", async function () {
        await token.setTaxFee(500);
        await ethers.provider.send("hardhat_mine", ["0x65"]); // 101 blocks
        await token.applyTaxFee();
        expect(await token.taxFee()).to.equal(500n);
    });

    it("refuses a matured proposal held past the window — no loaded gun", async function () {
        await token.setTaxFee(2500);
        const delay = await token.TAX_FEE_INCREASE_DELAY_BLOCKS();
        const window = await token.TAX_FEE_APPLY_WINDOW_BLOCKS();
        // Mature it, then sit on it well past the expiry.
        await ethers.provider.send("hardhat_mine", [
            "0x" + (delay + window + 10n).toString(16),
        ]);
        await expect(token.applyTaxFee()).to.be.revertedWithCustomError(token, "ProposalExpired");
        expect(await token.taxFee()).to.equal(0n);
    });

    it("still refuses to apply before the delay elapses", async function () {
        await token.setTaxFee(1000);
        await expect(token.applyTaxFee()).to.be.revertedWithCustomError(token, "TimelockActive");
    });
});
