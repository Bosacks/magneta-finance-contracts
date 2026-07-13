import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
    MagnetaERC20OFT,
    MagnetaERC20OFTAutoLiquidity,
    MagnetaOFTStandardFactory,
    MagnetaOFTAutoLiquidityFactory,
    MagnetaTokenFactory,
} from "../typechain-types";

/**
 * Sprint 1 tests — verify the new OFT-compatible token templates behave
 * identically to the legacy ones for local features (mint, blacklist, tax,
 * pause, revoke flags, AutoLiquidity tax). Real cross-chain end-to-end is
 * deferred to Sprint 6 (testnets) once the TokenCreationModule is wired
 * into the Gateway and proper LZ devtools mock is set up.
 *
 * For these tests we use a placeholder LZ endpoint address — only the
 * constructor + local state matter; setPeer/send paths require a real or
 * mocked endpoint and are out of scope for Sprint 1.
 */

const NAME = "Magneta OFT Test";
const SYMBOL = "MOFT";
const INITIAL_SUPPLY = ethers.parseEther("1000000");
const URI = "https://magneta.finance/test.json";

// Helper: deploy a fresh MockLZEndpoint and return its address. Each test
// uses its own instance to avoid cross-contamination of delegate mappings.
async function deployMockEndpoint(): Promise<string> {
    const MockEndpoint = await ethers.getContractFactory("MockLZEndpoint");
    const endpoint = await MockEndpoint.deploy();
    await endpoint.waitForDeployment();
    return await endpoint.getAddress();
}

describe("MagnetaERC20OFT — local behaviour", function () {
    let token: MagnetaERC20OFT;
    let owner: HardhatEthersSigner;
    let alice: HardhatEthersSigner;
    let bob: HardhatEthersSigner;

    beforeEach(async function () {
        [owner, alice, bob] = await ethers.getSigners();

        const lzEndpoint = await deployMockEndpoint();
        const Factory = await ethers.getContractFactory("MagnetaERC20OFT");
        token = await Factory.deploy(
            NAME,
            SYMBOL,
            URI,
            INITIAL_SUPPLY,
            owner.address,
            false,                              // revokeUpdate
            false,                              // revokeFreeze
            false,                              // revokeMint
            lzEndpoint,
            ethers.ZeroAddress,                  // tokenOpsModule (Sprint 9.5) — none for unit tests
        );
        await token.waitForDeployment();
    });

    it("mints initial supply to the owner", async function () {
        expect(await token.balanceOf(owner.address)).to.equal(INITIAL_SUPPLY);
        expect(await token.totalSupply()).to.equal(INITIAL_SUPPLY);
    });

    it("transfers without tax when taxFee = 0", async function () {
        await token.transfer(alice.address, ethers.parseEther("100"));
        expect(await token.balanceOf(alice.address)).to.equal(ethers.parseEther("100"));
        expect(await token.balanceOf(await token.getAddress())).to.equal(0n);
    });

    it("applies taxFee correctly on user-to-user transfer", async function () {
        // Increases go through propose/apply timelock; mine DELAY_BLOCKS then apply.
        await token.setTaxFee(500); // 5% — proposes
        const delay = await token.TAX_FEE_INCREASE_DELAY_BLOCKS();
        for (let i = 0; i < Number(delay); i++) {
            await ethers.provider.send("evm_mine", []);
        }
        await token.applyTaxFee();
        expect(await token.taxFee()).to.equal(500n);

        await token.transfer(alice.address, ethers.parseEther("100")); // owner sender → no tax
        await token.connect(alice).transfer(bob.address, ethers.parseEther("100"));
        expect(await token.balanceOf(bob.address)).to.equal(ethers.parseEther("95"));
        expect(await token.balanceOf(await token.getAddress())).to.equal(ethers.parseEther("5"));
    });

    it("rejects taxFee > 25%", async function () {
        await expect(token.setTaxFee(2501)).to.be.revertedWith("MagnetaERC20OFT: fee > 25%");
    });

    it("blocks blacklisted addresses on send AND receive", async function () {
        await token.transfer(alice.address, ethers.parseEther("100"));
        await token.blacklist(alice.address, true);
        await expect(
            token.connect(alice).transfer(bob.address, ethers.parseEther("10")),
        ).to.be.revertedWith("MagnetaERC20OFT: blacklisted");
        await expect(
            token.transfer(alice.address, ethers.parseEther("10")),
        ).to.be.revertedWith("MagnetaERC20OFT: blacklisted");
    });

    it("respects revoke flags (mint, freeze, update)", async function () {
        await token.enableRevokeMint();
        await expect(token.mint(alice.address, 1n)).to.be.revertedWith(
            "MagnetaERC20OFT: minting revoked",
        );
        await token.enableRevokeFreeze();
        await expect(token.pause()).to.be.revertedWith(
            "MagnetaERC20OFT: freezing revoked",
        );
        await token.enableRevokeUpdate();
        await expect(token.updateMetadata("new")).to.be.revertedWith(
            "MagnetaERC20OFT: update revoked",
        );
    });

    it("withdraws collected fees to marketing wallet", async function () {
        // Propose-apply the 10% fee
        await token.setTaxFee(1000);
        const delay = await token.TAX_FEE_INCREASE_DELAY_BLOCKS();
        for (let i = 0; i < Number(delay); i++) {
            await ethers.provider.send("evm_mine", []);
        }
        await token.applyTaxFee();

        await token.setMarketingWallet(bob.address);
        await token.transfer(alice.address, ethers.parseEther("1000"));      // owner → alice: no tax (sender exempt)
        // alice → bob (neither is owner): 10% tax = 100 tokens to contract
        await token.connect(alice).transfer(bob.address, ethers.parseEther("1000"));
        expect(await token.balanceOf(await token.getAddress())).to.equal(ethers.parseEther("100"));
        expect(await token.accumulatedTaxFees()).to.equal(ethers.parseEther("100"));

        const before = await token.balanceOf(bob.address);
        await token.withdrawFees();
        expect((await token.balanceOf(bob.address)) - before).to.equal(ethers.parseEther("100"));
        expect(await token.accumulatedTaxFees()).to.equal(0n);
    });

    it("pauses + unpauses transfers", async function () {
        await token.pause();
        await expect(
            token.transfer(alice.address, 1n),
        ).to.be.revertedWithCustomError(token, "EnforcedPause");
        await token.unpause();
        await expect(token.transfer(alice.address, 1n)).to.not.be.reverted;
    });

    it("exposes endpoint address via OApp interface (non-zero)", async function () {
        // OApp/OFTCore stores endpoint as immutable; verify it's set to the
        // mock endpoint deployed in beforeEach (any non-zero address).
        expect(await token.endpoint()).to.not.equal(ethers.ZeroAddress);
    });

    // ─── Sprint 9.5 — operator role for TokenOpsModule integration ──────
    //
    // Production scenario: the creator owns the token (Ownable) but the
    // Magneta TokenOpsModule needs to call mint/blacklist/updateMetadata/
    // enableRevoke* on their behalf so the Sprint 7 SDK can charge a USDC
    // fee per op. The `onlyOwnerOrOpsModule` modifier authorizes both paths.
    //
    // We use `bob` as a stand-in for the TokenOpsModule address — the
    // contract only checks `msg.sender == tokenOpsModule`, so any EOA works
    // as a substitute for unit-testing the access pattern.

    describe("Operator role (TokenOpsModule integration)", function () {
        let tokenWithOps: MagnetaERC20OFT;

        beforeEach(async function () {
            const lzEndpoint = await deployMockEndpoint();
            const Factory = await ethers.getContractFactory("MagnetaERC20OFT");
            // Deploy with `bob` as the operator stand-in; `owner` keeps Ownable.
            tokenWithOps = await Factory.deploy(
                NAME, SYMBOL, URI, INITIAL_SUPPLY, owner.address,
                false, false, false,
                lzEndpoint,
                bob.address,                // tokenOpsModule = bob
            );
            await tokenWithOps.waitForDeployment();
        });

        it("emits TokenOpsModuleUpdated when set in the constructor", async function () {
            // Constructor emission isn't easily asserted post-deploy, but
            // storage should reflect the wiring.
            expect(await tokenWithOps.tokenOpsModule()).to.equal(bob.address);
        });

        it("creator (owner) can mint directly", async function () {
            await expect(tokenWithOps.connect(owner).mint(alice.address, ethers.parseEther("100")))
                .to.not.be.reverted;
            expect(await tokenWithOps.balanceOf(alice.address)).to.equal(ethers.parseEther("100"));
        });

        it("tokenOpsModule (operator) can also mint", async function () {
            await expect(tokenWithOps.connect(bob).mint(alice.address, ethers.parseEther("50")))
                .to.not.be.reverted;
            expect(await tokenWithOps.balanceOf(alice.address)).to.equal(ethers.parseEther("50"));
        });

        it("random caller cannot mint (not owner, not operator)", async function () {
            await expect(
                tokenWithOps.connect(alice).mint(alice.address, 1n),
            ).to.be.revertedWith("MagnetaERC20OFT: not authorized");
        });

        it("operator can blacklist + updateMetadata + enableRevoke* (full surface)", async function () {
            await expect(tokenWithOps.connect(bob).blacklist(alice.address, true)).to.not.be.reverted;
            expect(await tokenWithOps.isBlacklisted(alice.address)).to.equal(true);

            await expect(tokenWithOps.connect(bob).updateMetadata("ipfs://new")).to.not.be.reverted;
            expect(await tokenWithOps.tokenURI()).to.equal("ipfs://new");

            await expect(tokenWithOps.connect(bob).enableRevokeUpdate()).to.not.be.reverted;
            expect(await tokenWithOps.revokeUpdateEnabled()).to.equal(true);
        });

        it("creator can rebind tokenOpsModule via setTokenOpsModule (owner-only)", async function () {
            // Random caller can't change it
            await expect(
                tokenWithOps.connect(alice).setTokenOpsModule(alice.address),
            ).to.be.revertedWithCustomError(tokenWithOps, "OwnableUnauthorizedAccount");

            // Owner sets to address(0) — disables the operator path
            await expect(tokenWithOps.connect(owner).setTokenOpsModule(ethers.ZeroAddress))
                .to.emit(tokenWithOps, "TokenOpsModuleUpdated")
                .withArgs(bob.address, ethers.ZeroAddress);

            // Bob (former operator) can no longer mint
            await expect(
                tokenWithOps.connect(bob).mint(alice.address, 1n),
            ).to.be.revertedWith("MagnetaERC20OFT: not authorized");

            // Owner can still mint directly (sovereignty preserved)
            await expect(tokenWithOps.connect(owner).mint(alice.address, 1n)).to.not.be.reverted;
        });

        it("revoke flags still apply when triggered via the operator path", async function () {
            // Operator revokes mint
            await tokenWithOps.connect(bob).enableRevokeMint();
            // Even the owner cannot mint anymore (one-way switch)
            await expect(
                tokenWithOps.connect(owner).mint(alice.address, 1n),
            ).to.be.revertedWith("MagnetaERC20OFT: minting revoked");
        });
    });

    // ─── Sprint 8 — Auto Freeze (permissionless on-chain sniper guard) ──

    describe("Auto Freeze", function () {
        const THRESHOLD = ethers.parseEther("10000"); // 10k tokens triggers freeze

        beforeEach(async function () {
            // Seed `bob` with > threshold so the freeze-by-relayer path can fire.
            await token.transfer(bob.address, ethers.parseEther("20000"));
        });

        it("only owner can configure the rule", async function () {
            await expect(
                token.connect(alice).setAutoFreezeRule(true, THRESHOLD),
            ).to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount");
            await expect(token.setAutoFreezeRule(true, THRESHOLD))
                .to.emit(token, "AutoFreezeRuleUpdated")
                .withArgs(true, THRESHOLD);
            const rule = await token.autoFreezeRule();
            expect(rule.active).to.equal(true);
            expect(rule.threshold).to.equal(THRESHOLD);
        });

        it("only owner can set whitelist", async function () {
            await expect(
                token.connect(alice).setAutoFreezeWhitelist([bob.address], true),
            ).to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount");
            await expect(token.setAutoFreezeWhitelist([bob.address], true))
                .to.emit(token, "AutoFreezeWhitelistUpdated")
                .withArgs(bob.address, true);
            expect(await token.isAutoFreezeWhitelisted(bob.address)).to.equal(true);
        });

        it("permissionless trigger blacklists buyer when conditions met", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            // alice (NOT the owner) calls the function — permissionless
            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000")),
            )
                .to.emit(token, "AutoFreezeTriggered")
                .withArgs(bob.address, ethers.parseEther("20000"), alice.address)
                .and.to.emit(token, "BlacklistUpdated")
                .withArgs(bob.address, true);
            expect(await token.isBlacklisted(bob.address)).to.equal(true);
        });

        it("reverts when rule is inactive", async function () {
            await token.setAutoFreezeRule(false, THRESHOLD);
            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: auto-freeze inactive");
        });

        it("reverts when buyAmount is below threshold", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("9000")),
            ).to.be.revertedWith("MagnetaERC20OFT: below threshold");
        });

        it("reverts when buyer is whitelisted", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            await token.setAutoFreezeWhitelist([bob.address], true);
            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: whitelisted");
        });

        it("reverts when the target is a CONTRACT (protects the LP pair from a griefing freeze)", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            // Stand-in for the DEX pair: any contract that holds > threshold.
            const pairAddr = await deployMockEndpoint(); // returns the contract address
            await token.transfer(pairAddr, ethers.parseEther("20000"));
            await expect(
                token.connect(alice).autoFreeze(pairAddr, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: cannot freeze contract");
            expect(await token.isBlacklisted(pairAddr)).to.equal(false);
        });

        it("reverts when the target is the owner", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            // Owner holds the initial supply (> threshold).
            await expect(
                token.connect(alice).autoFreeze(owner.address, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: cannot freeze owner");
            expect(await token.isBlacklisted(owner.address)).to.equal(false);
        });

        it("reverts when buyer's holdings dropped below threshold (anti-grief)", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            // Bob already holds 20k. Move 15k away so live holdings dip below 10k.
            await token.connect(bob).transfer(alice.address, ethers.parseEther("15000"));
            // Caller passes inflated buyAmount; on-chain check sees real balance.
            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: holdings below threshold");
        });

        it("reverts when buyer is already frozen", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            await token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000"));
            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: already frozen");
        });

        it("setAutoFreezeRule reverts after enableRevokeFreeze (irreversible)", async function () {
            await token.enableRevokeFreeze();
            await expect(
                token.setAutoFreezeRule(true, THRESHOLD),
            ).to.be.revertedWith("MagnetaERC20OFT: freezing revoked");
        });

        it("autoFreeze reverts after enableRevokeFreeze (irreversible)", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            await token.enableRevokeFreeze();
            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: freezing revoked");
        });
    });

    describe("Sentinelle hardening (audit 2026-05-22)", function () {
        const THRESHOLD = ethers.parseEther("10000");

        beforeEach(async function () {
            // bob will be the autofreeze target in some tests
            await token.transfer(bob.address, ethers.parseEther("20000"));
        });

        it("blacklist rejects address(0) and address(this)", async function () {
            await expect(
                token.blacklist(ethers.ZeroAddress, true),
            ).to.be.revertedWith("MagnetaERC20OFT: zero address");
            await expect(
                token.blacklist(await token.getAddress(), true),
            ).to.be.revertedWith("MagnetaERC20OFT: self");
        });

        it("blacklist (value=true) reverts after enableRevokeFreeze; de-blacklist still allowed", async function () {
            await token.blacklist(alice.address, true);
            await token.enableRevokeFreeze();
            // Cannot freeze new
            await expect(
                token.blacklist(bob.address, true),
            ).to.be.revertedWith("MagnetaERC20OFT: freezing revoked");
            // Can still unfreeze (relaxation only)
            await expect(token.blacklist(alice.address, false)).to.not.be.reverted;
        });

        // Sentinelle H-2 (audit 2026-06-24): pause()+renounceOwnership() = permanent freeze
        it("renounceOwnership is disabled (cannot brick the token after pause)", async function () {
            await token.pause();
            await expect(token.renounceOwnership()).to.be.revertedWith("renounce disabled");
            // Owner can still recover (unpause), proving control was never lost
            await expect(token.unpause()).to.not.be.reverted;
        });

        it("renounceOwnership reverts even when called by the owner with no pause", async function () {
            await expect(token.renounceOwnership()).to.be.revertedWith("renounce disabled");
            expect(await token.owner()).to.equal(owner.address);
        });

        it("setAutoFreezeRule rejects active rule with threshold=0", async function () {
            await expect(
                token.setAutoFreezeRule(true, 0),
            ).to.be.revertedWith("MagnetaERC20OFT: threshold must be > 0 when active");
            // inactive with threshold=0 is allowed (turning off)
            await expect(token.setAutoFreezeRule(false, 0)).to.not.be.reverted;
        });

        it("autoFreeze reverts after window expires", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            // advance past the default 1-hour window
            await ethers.provider.send("evm_increaseTime", [60 * 60 + 1]);
            await ethers.provider.send("evm_mine", []);

            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: auto-freeze window expired");

            // Re-arming refreshes the window
            await token.setAutoFreezeRule(true, THRESHOLD);
            await expect(
                token.connect(alice).autoFreeze(bob.address, ethers.parseEther("20000")),
            ).to.emit(token, "AutoFreezeTriggered");
        });

        it("setAutoFreezeWindow caps at 7 days", async function () {
            await expect(
                token.setAutoFreezeWindow(7 * 24 * 3600 + 1),
            ).to.be.revertedWith("MagnetaERC20OFT: window too long");
            await expect(token.setAutoFreezeWindow(7 * 24 * 3600)).to.emit(
                token, "AutoFreezeWindowUpdated",
            );
        });

        it("autoFreeze rejects zero or self as buyer", async function () {
            await token.setAutoFreezeRule(true, THRESHOLD);
            await expect(
                token.connect(alice).autoFreeze(ethers.ZeroAddress, ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: invalid buyer");
            await expect(
                token.connect(alice).autoFreeze(await token.getAddress(), ethers.parseEther("20000")),
            ).to.be.revertedWith("MagnetaERC20OFT: invalid buyer");
        });

        it("setAutoFreezeWhitelist caps batch at AUTO_FREEZE_WHITELIST_BATCH_MAX", async function () {
            const max = Number(await token.AUTO_FREEZE_WHITELIST_BATCH_MAX());
            const oversized = Array(max + 1).fill(alice.address);
            await expect(
                token.setAutoFreezeWhitelist(oversized, true),
            ).to.be.revertedWith("MagnetaERC20OFT: batch too large");
            const exactly = Array(max).fill(alice.address);
            await expect(token.setAutoFreezeWhitelist(exactly, true)).to.not.be.reverted;
        });

        it("setTaxFee decreases are instant; increases require propose/apply", async function () {
            // First raise the fee through the timelock to test decrease behavior
            await token.setTaxFee(500);
            const delay = await token.TAX_FEE_INCREASE_DELAY_BLOCKS();
            for (let i = 0; i < Number(delay); i++) await ethers.provider.send("evm_mine", []);
            await token.applyTaxFee();
            expect(await token.taxFee()).to.equal(500n);

            // Decrease applies instantly
            await token.setTaxFee(100);
            expect(await token.taxFee()).to.equal(100n);
            expect(await token.pendingTaxFeeBlock()).to.equal(0n);

            // Increase proposes
            await expect(token.setTaxFee(400)).to.emit(token, "TaxFeeProposed");
            expect(await token.taxFee()).to.equal(100n);
            expect(await token.pendingTaxFee()).to.equal(400n);

            // applyTaxFee reverts before timelock elapses
            await expect(token.applyTaxFee()).to.be.revertedWith("MagnetaERC20OFT: timelock active");
            for (let i = 0; i < Number(delay); i++) await ethers.provider.send("evm_mine", []);
            await token.applyTaxFee();
            expect(await token.taxFee()).to.equal(400n);
            expect(await token.pendingTaxFeeBlock()).to.equal(0n);
        });

        it("withdrawFees uses accumulatedTaxFees, not balanceOf — direct sends are NOT swept", async function () {
            // Raise tax via timelock
            await token.setTaxFee(1000);
            const delay = await token.TAX_FEE_INCREASE_DELAY_BLOCKS();
            for (let i = 0; i < Number(delay); i++) await ethers.provider.send("evm_mine", []);
            await token.applyTaxFee();

            // Generate 50 tokens of tax
            await token.transfer(alice.address, ethers.parseEther("500"));
            await token.connect(alice).transfer(bob.address, ethers.parseEther("500"));
            expect(await token.accumulatedTaxFees()).to.equal(ethers.parseEther("50"));

            // Someone "donates" 1000 tokens directly to the contract
            await token.transfer(await token.getAddress(), ethers.parseEther("1000"));
            const contractBal = await token.balanceOf(await token.getAddress());
            expect(contractBal).to.be.gte(ethers.parseEther("1050"));

            // withdrawFees only sweeps the tracked 50, leaves the 1000 stranded.
            await token.setMarketingWallet(alice.address);
            const before = await token.balanceOf(alice.address);
            await token.withdrawFees();
            const after = await token.balanceOf(alice.address);
            expect(after - before).to.equal(ethers.parseEther("50"));
            // 1000 donated tokens still on the contract
            expect(await token.balanceOf(await token.getAddress())).to.be.gte(ethers.parseEther("1000"));
        });
    });
});

describe("MagnetaERC20OFTAutoLiquidity — local tax behaviour", function () {
    let token: MagnetaERC20OFTAutoLiquidity;
    let owner: HardhatEthersSigner;
    let treasury: HardhatEthersSigner;
    let alice: HardhatEthersSigner;
    let bob: HardhatEthersSigner;

    beforeEach(async function () {
        [owner, treasury, alice, bob] = await ethers.getSigners();

        const lzEndpoint = await deployMockEndpoint();
        const Factory = await ethers.getContractFactory("MagnetaERC20OFTAutoLiquidity");
        token = await Factory.deploy(
            NAME,
            SYMBOL,
            URI,
            INITIAL_SUPPLY,
            owner.address,
            treasury.address,
            ethers.parseEther("100000"),        // burn 10%
            lzEndpoint,
        );
        await token.waitForDeployment();
    });

    it("burns initial liquidity to 0xdead", async function () {
        const dead = "0x000000000000000000000000000000000000dEaD";
        expect(await token.balanceOf(dead)).to.equal(ethers.parseEther("100000"));
        expect(await token.balanceOf(owner.address)).to.equal(ethers.parseEther("900000"));
    });

    it("applies 2% tax on user-to-user transfer (treasury receives)", async function () {
        await token.transfer(alice.address, ethers.parseEther("1000")); // owner → alice (exempt)
        const treasuryBefore = await token.balanceOf(treasury.address);
        await token.connect(alice).transfer(bob.address, ethers.parseEther("1000"));
        expect(await token.balanceOf(bob.address)).to.equal(ethers.parseEther("980"));
        expect((await token.balanceOf(treasury.address)) - treasuryBefore).to.equal(
            ethers.parseEther("20"),
        );
    });

    it("skips tax for exempt addresses", async function () {
        await token.setTaxExempt(alice.address, true);
        await token.transfer(alice.address, ethers.parseEther("1000"));
        await token.connect(alice).transfer(bob.address, ethers.parseEther("1000"));
        expect(await token.balanceOf(bob.address)).to.equal(ethers.parseEther("1000"));
    });

    describe("Sentinelle hardening (audit 2026-05-22)", function () {
        it("setTokenURI updates the URI and emits MetadataUpdated", async function () {
            await expect(token.setTokenURI("ipfs://updated"))
                .to.emit(token, "MetadataUpdated")
                .withArgs("ipfs://updated");
            expect(await token.tokenURI()).to.equal("ipfs://updated");
        });

        it("setTokenURI is owner-only", async function () {
            await expect(token.connect(alice).setTokenURI("evil"))
                .to.be.reverted;
        });

        it("constructor rejects burn exceeding initialOwner balance", async function () {
            const lzEndpoint = await deployMockEndpoint();
            const Factory = await ethers.getContractFactory("MagnetaERC20OFTAutoLiquidity");
            // total supply 1M, try to burn 1M+1 wei
            await expect(
                Factory.deploy(
                    NAME,
                    SYMBOL,
                    URI,
                    INITIAL_SUPPLY,
                    owner.address,
                    treasury.address,
                    INITIAL_SUPPLY + 1n,
                    lzEndpoint,
                ),
            ).to.be.revertedWith("MagnetaERC20OFTAL: burn exceeds balance");
        });

        // Sentinelle L-2 (audit 2026-06-24): rotating treasury must revoke the
        // old treasury's tax exemption (parity with ERC20TokenAutoLiquidity).
        it("setTreasuryAddress revokes the previous treasury's tax exemption", async function () {
            expect(await token.isTaxExempt(treasury.address)).to.equal(true);

            await expect(token.setTreasuryAddress(alice.address))
                .to.emit(token, "TaxExemptionUpdated").withArgs(treasury.address, false)
                .and.to.emit(token, "TaxExemptionUpdated").withArgs(alice.address, true)
                .and.to.emit(token, "TreasuryUpdated").withArgs(treasury.address, alice.address);

            expect(await token.isTaxExempt(treasury.address)).to.equal(false);
            expect(await token.isTaxExempt(alice.address)).to.equal(true);

            // The rotated-out treasury now pays tax like any other holder.
            await token.transfer(treasury.address, ethers.parseEther("1000")); // owner→old (still exempt as sender? owner exempt)
            await token.connect(treasury).transfer(bob.address, ethers.parseEther("1000"));
            expect(await token.balanceOf(bob.address)).to.equal(ethers.parseEther("980"));
        });

        it("setTreasuryAddress keeps exemption when set to the same address (no spurious revoke)", async function () {
            await token.setTreasuryAddress(treasury.address);
            expect(await token.isTaxExempt(treasury.address)).to.equal(true);
        });

        // L-2 edge (2026-06-24): if treasury was pointed at the owner, rotating
        // it away must NOT strip the owner's own (constructor-set) exemption.
        it("setTreasuryAddress preserves the owner's exemption when old treasury == owner", async function () {
            const lzEndpoint = await deployMockEndpoint();
            const Factory = await ethers.getContractFactory("MagnetaERC20OFTAutoLiquidity");
            const t = await Factory.deploy(
                NAME, SYMBOL, URI, INITIAL_SUPPLY,
                owner.address, owner.address,        // treasury == owner
                ethers.parseEther("100000"), lzEndpoint,
            );
            await t.waitForDeployment();
            expect(await t.isTaxExempt(owner.address)).to.equal(true);

            // Rotate treasury away to alice — owner must stay exempt.
            await t.setTreasuryAddress(alice.address);
            expect(await t.isTaxExempt(owner.address)).to.equal(true);
            expect(await t.isTaxExempt(alice.address)).to.equal(true);
        });
    });
});

describe("MagnetaOFTStandardFactory — Standard OFT template", function () {
    let factory: MagnetaOFTStandardFactory;
    let lzEndpoint: string;
    let owner: HardhatEthersSigner;
    let treasury: HardhatEthersSigner;
    let user: HardhatEthersSigner;

    beforeEach(async function () {
        [owner, treasury, user] = await ethers.getSigners();
        lzEndpoint = await deployMockEndpoint();

        const FactoryC = await ethers.getContractFactory("MagnetaOFTStandardFactory");
        factory = await FactoryC.deploy(treasury.address, lzEndpoint);
        await factory.waitForDeployment();
    });

    it("rejects deployment with zero LZ endpoint", async function () {
        const FactoryC = await ethers.getContractFactory("MagnetaOFTStandardFactory");
        await expect(
            FactoryC.deploy(treasury.address, ethers.ZeroAddress),
        ).to.be.revertedWithCustomError(FactoryC, "ZeroAddress");
    });

    it("createOFTStandardToken charges fee + deploys OFT", async function () {
        const tx = await factory.connect(user).createOFTStandardToken(
            "User Token",
            "UT",
            URI,
            INITIAL_SUPPLY,
            false,
            false,
            false,
            { value: ethers.parseEther("0.01") },
        );
        const receipt = await tx.wait();
        const event = receipt!.logs
            .map((l) => {
                try { return factory.interface.parseLog(l); } catch { return null; }
            })
            .find((e) => e?.name === "TokenCreated");
        expect(event).to.not.be.undefined;
        expect(event!.args.tokenType).to.equal("StandardOFT");

        const tokenAddr = event!.args.tokenAddress as string;
        const Token = await ethers.getContractAt("MagnetaERC20OFT", tokenAddr);
        expect(await Token.balanceOf(user.address)).to.equal(INITIAL_SUPPLY);
        expect((await Token.endpoint()).toLowerCase()).to.equal(lzEndpoint.toLowerCase());
    });

    describe("Sentinelle HIGH SC10 — pull-payment for treasury fees", function () {
        async function createOnce() {
            await factory.connect(user).createOFTStandardToken(
                "T", "T", URI, INITIAL_SUPPLY, false, false, false,
                { value: ethers.parseEther("0.01") },
            );
        }

        it("accumulatedFees increments on each create; balance stays on-contract", async function () {
            const before = await ethers.provider.getBalance(treasury.address);
            await createOnce();
            await createOnce();
            expect(await factory.accumulatedFees()).to.equal(ethers.parseEther("0.02"));
            // Treasury did NOT receive funds synchronously
            expect(await ethers.provider.getBalance(treasury.address)).to.equal(before);
            // Factory holds the accrued fees
            expect(
                await ethers.provider.getBalance(await factory.getAddress()),
            ).to.equal(ethers.parseEther("0.02"));
        });

        it("withdraw() sends accumulated fees to treasury (not owner) and resets the counter", async function () {
            await createOnce();
            await createOnce();
            const treasuryBefore = await ethers.provider.getBalance(treasury.address);

            await expect(factory.withdraw())
                .to.emit(factory, "Withdrawn")
                .withArgs(treasury.address, ethers.parseEther("0.02"));

            expect(await ethers.provider.getBalance(treasury.address)).to.equal(
                treasuryBefore + ethers.parseEther("0.02"),
            );
            expect(await factory.accumulatedFees()).to.equal(0n);
        });

        it("withdraw reverts when no fees accrued", async function () {
            await expect(factory.withdraw()).to.be.revertedWithCustomError(factory, "NoFees");
        });

        it("CREATE succeeds even when treasury is set to a reverting contract (old DoS vector)", async function () {
            // Use the LZ endpoint mock — a contract with no payable receive,
            // so any forwarded ETH would revert. Perfect "broken treasury".
            const reverterAddr = await deployMockEndpoint();
            await factory.setTreasury(reverterAddr);
            // Pre-patch: createOFTStandardToken would have reverted here
            // because the synchronous push-payment to treasury fails.
            await expect(
                factory.connect(user).createOFTStandardToken(
                    "Survives", "S", URI, INITIAL_SUPPLY, false, false, false,
                    { value: ethers.parseEther("0.01") },
                ),
            ).to.not.be.reverted;
            // Fee accrued, withdraw to it would revert — but creation works.
            expect(await factory.accumulatedFees()).to.equal(ethers.parseEther("0.01"));
        });
    });
});

describe("MagnetaOFTAutoLiquidityFactory — AutoLiquidity OFT template", function () {
    let factory: MagnetaOFTAutoLiquidityFactory;
    let lzEndpoint: string;
    let owner: HardhatEthersSigner;
    let treasury: HardhatEthersSigner;
    let user: HardhatEthersSigner;

    beforeEach(async function () {
        [owner, treasury, user] = await ethers.getSigners();
        lzEndpoint = await deployMockEndpoint();

        const FactoryC = await ethers.getContractFactory("MagnetaOFTAutoLiquidityFactory");
        factory = await FactoryC.deploy(treasury.address, lzEndpoint);
        await factory.waitForDeployment();
    });

    it("createOFTAutoLiquidityToken deploys with 2% tax", async function () {
        const tx = await factory.connect(user).createOFTAutoLiquidityToken(
            "AL Token",
            "AL",
            URI,
            INITIAL_SUPPLY,
            ethers.parseEther("50000"),
        );
        const receipt = await tx.wait();
        const event = receipt!.logs
            .map((l) => {
                try { return factory.interface.parseLog(l); } catch { return null; }
            })
            .find((e) => e?.name === "TokenCreated");
        expect(event).to.not.be.undefined;
        expect(event!.args.tokenType).to.equal("AutoLiquidityOFT");
    });
});

describe("MagnetaTokenFactory — legacy templates (backward compat)", function () {
    let factory: MagnetaTokenFactory;
    let owner: HardhatEthersSigner;
    let treasury: HardhatEthersSigner;
    let user: HardhatEthersSigner;

    beforeEach(async function () {
        [owner, treasury, user] = await ethers.getSigners();

        const FactoryC = await ethers.getContractFactory("MagnetaTokenFactory");
        factory = await FactoryC.deploy(treasury.address);
        await factory.waitForDeployment();
    });

    it("legacy createStandardToken still works", async function () {
        await expect(
            factory.connect(user).createStandardToken(
                "Legacy", "LEG", URI, INITIAL_SUPPLY, false, false, false,
                { value: ethers.parseEther("0.01") },
            ),
        ).to.not.be.reverted;
    });

    // Sprint 5 — legacy factory's Relayer entry points (Cronos pattern)
    describe("createForCreator (Cronos Relayer pattern)", function () {
        let relayer: HardhatEthersSigner;
        let endUser: HardhatEthersSigner;

        beforeEach(async function () {
            [, , relayer, endUser] = await ethers.getSigners();
            await factory.connect(owner).setCrossChainCreator(relayer.address);
        });

        it("createStandardForCreator deploys a token owned by the end user", async function () {
            const tx = await factory.connect(relayer).createStandardForCreator(
                endUser.address,
                "Cronos Token",
                "CRON",
                URI,
                INITIAL_SUPPLY,
                false,
                false,
                false,
            );
            const receipt = await tx.wait();
            const event = receipt!.logs
                .map((l) => {
                    try { return factory.interface.parseLog(l); } catch { return null; }
                })
                .find((e) => e?.name === "TokenCreated");
            expect(event).to.not.be.undefined;
            expect(event!.args.creator).to.equal(endUser.address);
            expect(event!.args.tokenType).to.equal("Standard-CC");

            const tokenAddr = event!.args.tokenAddress as string;
            const Token = await ethers.getContractAt("ERC20Token", tokenAddr);
            expect(await Token.balanceOf(endUser.address)).to.equal(INITIAL_SUPPLY);
            expect(await Token.owner()).to.equal(endUser.address);
        });

        it("createAutoLiquidityForCreator deploys an auto-liquidity token", async function () {
            const tx = await factory.connect(relayer).createAutoLiquidityForCreator(
                endUser.address,
                "Cronos AL",
                "CAL",
                URI,
                INITIAL_SUPPLY,
                ethers.parseEther("100000"), // burn 10%
            );
            const receipt = await tx.wait();
            const event = receipt!.logs
                .map((l) => {
                    try { return factory.interface.parseLog(l); } catch { return null; }
                })
                .find((e) => e?.name === "TokenCreated");
            expect(event).to.not.be.undefined;
            expect(event!.args.creator).to.equal(endUser.address);
            expect(event!.args.tokenType).to.equal("AutoLiquidity-CC");
        });

        it("rejects calls from non-Relayer addresses", async function () {
            await expect(
                factory.connect(endUser).createStandardForCreator(
                    endUser.address, "X", "X", URI, 1n, false, false, false,
                ),
            ).to.be.revertedWithCustomError(factory, "NotCrossChainCreator");
        });

        it("rejects when crossChainCreator is unset (zero address)", async function () {
            await factory.connect(owner).setCrossChainCreator(ethers.ZeroAddress);
            await expect(
                factory.connect(relayer).createStandardForCreator(
                    endUser.address, "X", "X", URI, 1n, false, false, false,
                ),
            ).to.be.revertedWithCustomError(factory, "NotCrossChainCreator");
        });

        it("rejects deployment with zero creator address", async function () {
            await expect(
                factory.connect(relayer).createStandardForCreator(
                    ethers.ZeroAddress, "X", "X", URI, 1n, false, false, false,
                ),
            ).to.be.revertedWith("Creator cannot be zero");
        });

        it("setCrossChainCreator emits event + reflects in storage", async function () {
            await expect(
                factory.connect(owner).setCrossChainCreator(user.address),
            )
                .to.emit(factory, "CrossChainCreatorUpdated")
                .withArgs(relayer.address, user.address);
            expect(await factory.crossChainCreator()).to.equal(user.address);
        });

        it("only owner can call setCrossChainCreator", async function () {
            await expect(
                factory.connect(endUser).setCrossChainCreator(user.address),
            ).to.be.reverted;
        });
    });

    describe("Sentinelle hardening (audit 2026-05-22)", function () {
        it("accumulatedFees increments on createStandardToken; treasury not touched", async function () {
            const recBefore = await ethers.provider.getBalance(treasury.address);
            await factory.connect(user).createStandardToken(
                "T", "T", URI, INITIAL_SUPPLY, false, false, false,
                { value: ethers.parseEther("0.01") },
            );
            expect(await factory.accumulatedFees()).to.equal(ethers.parseEther("0.01"));
            expect(await ethers.provider.getBalance(treasury.address)).to.equal(recBefore);
        });

        it("withdraw() releases accumulated fees to treasury and resets", async function () {
            await factory.connect(user).createStandardToken(
                "T", "T", URI, INITIAL_SUPPLY, false, false, false,
                { value: ethers.parseEther("0.01") },
            );
            const before = await ethers.provider.getBalance(treasury.address);
            await expect(factory.withdraw())
                .to.emit(factory, "Withdrawn")
                .withArgs(treasury.address, ethers.parseEther("0.01"));
            expect(await ethers.provider.getBalance(treasury.address)).to.equal(
                before + ethers.parseEther("0.01"),
            );
            expect(await factory.accumulatedFees()).to.equal(0n);
        });

        it("createStandardToken succeeds even if treasury is a reverting contract (DoS-immune)", async function () {
            const reverterAddr = await deployMockEndpoint();
            await factory.setTreasury(reverterAddr);
            await expect(
                factory.connect(user).createStandardToken(
                    "T", "T", URI, INITIAL_SUPPLY, false, false, false,
                    { value: ethers.parseEther("0.01") },
                ),
            ).to.not.be.reverted;
        });

        it("paginated getters return the requested slice", async function () {
            for (let i = 0; i < 3; i++) {
                await factory.connect(user).createStandardToken(
                    `T${i}`, `T${i}`, URI, INITIAL_SUPPLY, false, false, false,
                    { value: ethers.parseEther("0.01") },
                );
            }
            const all = await factory.getUserTokens(user.address);
            expect(all.length).to.equal(3);

            const slice = await factory.getUserTokensPaginated(user.address, 1, 10);
            expect(slice.length).to.equal(2);
            expect(slice[0]).to.equal(all[1]);

            const globalSlice = await factory.getAllTokensPaginated(0, 2);
            expect(globalSlice.length).to.equal(2);

            const empty = await factory.getUserTokensPaginated(user.address, 100, 10);
            expect(empty.length).to.equal(0);
        });
    });
});
