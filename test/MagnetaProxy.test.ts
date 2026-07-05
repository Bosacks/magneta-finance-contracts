import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaProxy, MockERC20, MockSimpleRouter } from "../typechain-types";

/**
 * MagnetaProxy.sol — test suite.
 *
 * Originally covered three "happy path" cases (executeSwap + executeSwapToETH).
 * Expanded 2026-05-22 after a Sentinelleai Multi-AI audit surfaced 3 HIGH
 * findings: unrestricted swapTarget (SC06), donation-attack surface (SC02),
 * and CEI violation (SC08). The fix introduced an owner-managed whitelist of
 * swap targets + spenders plus rescue functions for the LOW SC09 finding.
 *
 * The original tests were updated to populate the whitelist before each swap;
 * new describe blocks pin the whitelist + rescue behaviour so regressions
 * surface immediately on `pnpm test`.
 */
describe("MagnetaProxy", function () {
    let magnetaProxy: MagnetaProxy;
    let mockRouter: MockSimpleRouter;
    let tokenIn: MockERC20;
    let tokenOut: MockERC20;
    let owner: SignerWithAddress;
    let user: SignerWithAddress;
    let feeRecipient: SignerWithAddress;
    let stranger: SignerWithAddress;

    const FEE_BPS = 30n; // 0.3%

    beforeEach(async function () {
        [owner, user, feeRecipient, stranger] = await ethers.getSigners();

        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        tokenIn = await MockERC20Factory.deploy("TokenIn", "TKNIN", 18, ethers.parseEther("1000000"));
        tokenOut = await MockERC20Factory.deploy("TokenOut", "TKNOUT", 18, ethers.parseEther("1000000"));

        const MockSimpleRouterFactory = await ethers.getContractFactory("MockSimpleRouter");
        mockRouter = await MockSimpleRouterFactory.deploy();

        const MagnetaProxyFactory = await ethers.getContractFactory("MagnetaProxy");
        magnetaProxy = await MagnetaProxyFactory.deploy(feeRecipient.address);

        await tokenIn.transfer(user.address, ethers.parseEther("1000"));
        await tokenOut.transfer(await mockRouter.getAddress(), ethers.parseEther("1000"));
    });

    // Convenience: allow the mock router as both swap target and spender.
    async function whitelistRouter() {
        const addr = await mockRouter.getAddress();
        await magnetaProxy.setAllowedSwapTarget(addr, true);
        await magnetaProxy.setAllowedSpender(addr, true);
    }

    // ─── Original happy-path tests (updated for whitelist) ──────────────────
    describe("ERC20 Swaps", function () {
        it("Should execute swap and withdraw fee", async function () {
            await whitelistRouter();

            const amountIn = ethers.parseEther("100");
            const amountOutMin = ethers.parseEther("90");
            const fee = (amountIn * FEE_BPS) / 10000n;

            const swapData = mockRouter.interface.encodeFunctionData("swap", [
                await tokenOut.getAddress(),
                amountOutMin,
                await magnetaProxy.getAddress(),
            ]);
            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), amountIn);

            await expect(
                magnetaProxy.connect(user).executeSwap(
                    await tokenIn.getAddress(),
                    await tokenOut.getAddress(),
                    amountIn,
                    amountOutMin,
                    await mockRouter.getAddress(),
                    await mockRouter.getAddress(),
                    swapData,
                ),
            )
                .to.emit(magnetaProxy, "Swapped")
                .withArgs(user.address, await tokenIn.getAddress(), await tokenOut.getAddress(), amountIn, amountOutMin, fee);

            expect(await tokenIn.balanceOf(feeRecipient.address)).to.equal(fee);
            expect(await tokenOut.balanceOf(user.address)).to.equal(amountOutMin);
        });
    });

    describe("executeSwapToETH (ERC20 → native, V2 addition)", function () {
        it("Swaps ERC20 → native, deducts fee in input token, sends native to user", async function () {
            await whitelistRouter();

            const amountIn = ethers.parseEther("100");
            const fee = (amountIn * FEE_BPS) / 10000n;
            const expectedNativeOut = ethers.parseEther("0.5");

            await owner.sendTransaction({
                to: await mockRouter.getAddress(),
                value: ethers.parseEther("10"),
            });

            const swapData = mockRouter.interface.encodeFunctionData("swap", [
                ethers.ZeroAddress,
                expectedNativeOut,
                await magnetaProxy.getAddress(),
            ]);
            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), amountIn);

            const userNativeBefore = await ethers.provider.getBalance(user.address);
            const feeRecipientTokenBefore = await tokenIn.balanceOf(feeRecipient.address);

            const tx = await magnetaProxy.connect(user).executeSwapToETH(
                await tokenIn.getAddress(),
                amountIn,
                expectedNativeOut,
                await mockRouter.getAddress(),
                await mockRouter.getAddress(),
                swapData,
            );
            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

            expect(await tokenIn.balanceOf(feeRecipient.address)).to.equal(feeRecipientTokenBefore + fee);

            const userNativeAfter = await ethers.provider.getBalance(user.address);
            expect(userNativeAfter).to.equal(userNativeBefore - gasUsed + expectedNativeOut);

            expect(await ethers.provider.getBalance(await magnetaProxy.getAddress())).to.equal(0n);
        });

        it("Reverts if native received < minAmountOut", async function () {
            await whitelistRouter();

            const amountIn = ethers.parseEther("100");
            const expectedNativeOut = ethers.parseEther("1");

            await owner.sendTransaction({
                to: await mockRouter.getAddress(),
                value: ethers.parseEther("10"),
            });

            const swapData = mockRouter.interface.encodeFunctionData("swap", [
                ethers.ZeroAddress,
                ethers.parseEther("0.5"),
                await magnetaProxy.getAddress(),
            ]);
            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), amountIn);

            await expect(
                magnetaProxy.connect(user).executeSwapToETH(
                    await tokenIn.getAddress(),
                    amountIn,
                    expectedNativeOut,
                    await mockRouter.getAddress(),
                    await mockRouter.getAddress(),
                    swapData,
                ),
            ).to.be.revertedWith("Insufficient output amount");
        });

        it("Reverts on zero amountIn (parameter validation runs before whitelist check)", async function () {
            // Note: the previous version of this test also asserted the
            // 'Invalid spender' / 'Invalid target' strings, but those are now
            // replaced by the whitelist-not-allowed errors. See
            // 'whitelist enforcement' describe block below for that coverage.
            await expect(
                magnetaProxy.connect(user).executeSwapToETH(
                    await tokenIn.getAddress(),
                    0,
                    1n,
                    await mockRouter.getAddress(),
                    await mockRouter.getAddress(),
                    "0x",
                ),
            ).to.be.revertedWith("Invalid amount");
        });
    });

    // ─── New whitelist + rescue coverage (added 2026-05-22) ─────────────────
    describe("constructor", function () {
        it("starts with empty whitelists", async function () {
            const r = await mockRouter.getAddress();
            expect(await magnetaProxy.allowedSwapTargets(r)).to.equal(false);
            expect(await magnetaProxy.allowedSpenders(r)).to.equal(false);
        });

        it("reverts on zero fee recipient", async function () {
            const Factory = await ethers.getContractFactory("MagnetaProxy");
            await expect(Factory.deploy(ethers.ZeroAddress)).to.be.revertedWith("Invalid fee recipient");
        });
    });

    describe("setAllowedSwapTarget / setAllowedSpender", function () {
        it("rejects zero address", async function () {
            await expect(magnetaProxy.setAllowedSwapTarget(ethers.ZeroAddress, true))
                .to.be.revertedWith("MagnetaProxy: zero target");
            await expect(magnetaProxy.setAllowedSpender(ethers.ZeroAddress, true))
                .to.be.revertedWith("MagnetaProxy: zero spender");
        });

        it("is owner-only", async function () {
            const r = await mockRouter.getAddress();
            await expect(magnetaProxy.connect(stranger).setAllowedSwapTarget(r, true)).to.be.reverted;
            await expect(magnetaProxy.connect(stranger).setAllowedSpender(r, true)).to.be.reverted;
        });

        it("emits the right events", async function () {
            const r = await mockRouter.getAddress();
            await expect(magnetaProxy.setAllowedSwapTarget(r, true))
                .to.emit(magnetaProxy, "SwapTargetAllowed").withArgs(r, true);
            await expect(magnetaProxy.setAllowedSpender(r, true))
                .to.emit(magnetaProxy, "SpenderAllowed").withArgs(r, true);
        });

        it("bulk setters apply to many addresses", async function () {
            const r = await mockRouter.getAddress();
            await magnetaProxy.setAllowedSwapTargets([r, stranger.address], true);
            expect(await magnetaProxy.allowedSwapTargets(r)).to.equal(true);
            expect(await magnetaProxy.allowedSwapTargets(stranger.address)).to.equal(true);

            await magnetaProxy.setAllowedSpenders([r, stranger.address], true);
            expect(await magnetaProxy.allowedSpenders(r)).to.equal(true);
            expect(await magnetaProxy.allowedSpenders(stranger.address)).to.equal(true);
        });

        it("can de-whitelist a previously allowed target", async function () {
            const r = await mockRouter.getAddress();
            await magnetaProxy.setAllowedSwapTarget(r, true);
            await magnetaProxy.setAllowedSwapTarget(r, false);
            expect(await magnetaProxy.allowedSwapTargets(r)).to.equal(false);
        });
    });

    describe("whitelist enforcement on the three swap paths", function () {
        async function emptyCallData() {
            // Trivial swap payload — the call won't execute because the
            // whitelist check reverts first.
            return mockRouter.interface.encodeFunctionData("swap", [
                await tokenOut.getAddress(),
                1n,
                await magnetaProxy.getAddress(),
            ]);
        }

        it("executeSwap reverts when target not whitelisted", async function () {
            const r = await mockRouter.getAddress();
            // Only spender whitelisted, target absent.
            await magnetaProxy.setAllowedSpender(r, true);
            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), 1n);

            await expect(
                magnetaProxy.connect(user).executeSwap(
                    await tokenIn.getAddress(),
                    await tokenOut.getAddress(),
                    1n, 1n, r, r,
                    await emptyCallData(),
                ),
            ).to.be.revertedWith("MagnetaProxy: target not allowed");
        });

        it("executeSwap reverts when spender not whitelisted", async function () {
            const r = await mockRouter.getAddress();
            await magnetaProxy.setAllowedSwapTarget(r, true);
            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), 1n);

            await expect(
                magnetaProxy.connect(user).executeSwap(
                    await tokenIn.getAddress(),
                    await tokenOut.getAddress(),
                    1n, 1n, r, r,
                    await emptyCallData(),
                ),
            ).to.be.revertedWith("MagnetaProxy: spender not allowed");
        });

        it("executeSwapETH reverts when target not whitelisted", async function () {
            const r = await mockRouter.getAddress();
            await magnetaProxy.setAllowedSpender(r, true);

            await expect(
                magnetaProxy.connect(user).executeSwapETH(
                    await tokenOut.getAddress(),
                    1n, r, r,
                    await emptyCallData(),
                    { value: ethers.parseEther("1") },
                ),
            ).to.be.revertedWith("MagnetaProxy: target not allowed");
        });

        it("executeSwapToETH reverts when target not whitelisted", async function () {
            const r = await mockRouter.getAddress();
            await magnetaProxy.setAllowedSpender(r, true);
            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), 1n);

            await expect(
                magnetaProxy.connect(user).executeSwapToETH(
                    await tokenIn.getAddress(),
                    1n, 1n, r, r,
                    await emptyCallData(),
                ),
            ).to.be.revertedWith("MagnetaProxy: target not allowed");
        });
    });

    describe("rescueERC20 / rescueETH", function () {
        it("rescueERC20 is owner-only and validates inputs", async function () {
            // Send some tokens directly to the proxy
            await tokenOut.transfer(await magnetaProxy.getAddress(), ethers.parseEther("100"));

            await expect(
                magnetaProxy.connect(stranger).rescueERC20(await tokenOut.getAddress(), stranger.address, 1n),
            ).to.be.reverted;

            await expect(
                magnetaProxy.rescueERC20(ethers.ZeroAddress, owner.address, 1n),
            ).to.be.revertedWith("MagnetaProxy: zero token");

            await expect(
                magnetaProxy.rescueERC20(await tokenOut.getAddress(), ethers.ZeroAddress, 1n),
            ).to.be.revertedWith("MagnetaProxy: zero recipient");

            await expect(
                magnetaProxy.rescueERC20(await tokenOut.getAddress(), owner.address, ethers.parseEther("100")),
            )
                .to.emit(magnetaProxy, "Rescued")
                .withArgs(await tokenOut.getAddress(), owner.address, ethers.parseEther("100"));
        });

        it("rescueETH is owner-only and pays out", async function () {
            await owner.sendTransaction({ to: await magnetaProxy.getAddress(), value: ethers.parseEther("2") });

            await expect(
                magnetaProxy.connect(stranger).rescueETH(stranger.address, 1n),
            ).to.be.reverted;

            await expect(
                magnetaProxy.rescueETH(ethers.ZeroAddress, 1n),
            ).to.be.revertedWith("MagnetaProxy: zero recipient");

            const before = await ethers.provider.getBalance(stranger.address);
            await magnetaProxy.rescueETH(stranger.address, ethers.parseEther("2"));
            expect(await ethers.provider.getBalance(stranger.address)).to.equal(before + ethers.parseEther("2"));
        });
    });

    describe("admin: backward-compat invariants still hold", function () {
        it("setFeeRecipient zero-check still works", async function () {
            await expect(magnetaProxy.setFeeRecipient(ethers.ZeroAddress)).to.be.revertedWith("Invalid recipient");
        });

        it("setFeeBps cap still enforced", async function () {
            await expect(magnetaProxy.setFeeBps(1001)).to.be.revertedWith("Fee too high");
            await magnetaProxy.setFeeBps(50);
            expect(await magnetaProxy.feeBps()).to.equal(50);
        });
    });

    // ─── Emergency pause (defense-in-depth kill-switch, added 2026-07-05) ──
    describe("emergency pause", function () {
        async function emptyCallData() {
            return mockRouter.interface.encodeFunctionData("swap", [
                await tokenOut.getAddress(),
                1n,
                await magnetaProxy.getAddress(),
            ]);
        }

        it("executeSwap reverts when paused", async function () {
            await whitelistRouter();
            await magnetaProxy.pause();

            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), ethers.parseEther("1"));

            await expect(
                magnetaProxy.connect(user).executeSwap(
                    await tokenIn.getAddress(),
                    await tokenOut.getAddress(),
                    ethers.parseEther("1"),
                    1n,
                    await mockRouter.getAddress(),
                    await mockRouter.getAddress(),
                    await emptyCallData(),
                ),
            ).to.be.revertedWith("Pausable: paused");
        });

        it("executeSwapETH reverts when paused", async function () {
            await whitelistRouter();
            await magnetaProxy.pause();

            await expect(
                magnetaProxy.connect(user).executeSwapETH(
                    await tokenOut.getAddress(),
                    1n,
                    await mockRouter.getAddress(),
                    await mockRouter.getAddress(),
                    await emptyCallData(),
                    { value: ethers.parseEther("1") },
                ),
            ).to.be.revertedWith("Pausable: paused");
        });

        it("executeSwapToETH reverts when paused", async function () {
            await whitelistRouter();
            await magnetaProxy.pause();

            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), ethers.parseEther("1"));

            await expect(
                magnetaProxy.connect(user).executeSwapToETH(
                    await tokenIn.getAddress(),
                    ethers.parseEther("1"),
                    1n,
                    await mockRouter.getAddress(),
                    await mockRouter.getAddress(),
                    await emptyCallData(),
                ),
            ).to.be.revertedWith("Pausable: paused");
        });

        it("a designated pauser can pause, but not unpause", async function () {
            await magnetaProxy.addPauser(stranger.address);

            await expect(magnetaProxy.connect(stranger).pause())
                .to.emit(magnetaProxy, "Paused")
                .withArgs(stranger.address);
            expect(await magnetaProxy.paused()).to.equal(true);

            await expect(magnetaProxy.connect(stranger).unpause()).to.be.reverted;

            // Owner can still unpause.
            await magnetaProxy.unpause();
            expect(await magnetaProxy.paused()).to.equal(false);
        });

        it("non-owner/non-pauser cannot pause", async function () {
            await expect(magnetaProxy.connect(stranger).pause())
                .to.be.revertedWith("MagnetaProxy: not owner or pauser");
        });

        it("removePauser revokes pause rights", async function () {
            await magnetaProxy.addPauser(stranger.address);
            await magnetaProxy.removePauser(stranger.address);

            await expect(magnetaProxy.connect(stranger).pause())
                .to.be.revertedWith("MagnetaProxy: not owner or pauser");
        });

        it("addPauser/removePauser are owner-only and reject zero address", async function () {
            await expect(magnetaProxy.connect(stranger).addPauser(stranger.address)).to.be.reverted;
            await expect(magnetaProxy.connect(stranger).removePauser(owner.address)).to.be.reverted;

            await expect(magnetaProxy.addPauser(ethers.ZeroAddress))
                .to.be.revertedWith("MagnetaProxy: zero pauser");
            await expect(magnetaProxy.removePauser(ethers.ZeroAddress))
                .to.be.revertedWith("MagnetaProxy: zero pauser");
        });

        it("rescueERC20 and rescueETH remain callable while paused", async function () {
            await magnetaProxy.pause();

            await tokenOut.transfer(await magnetaProxy.getAddress(), ethers.parseEther("10"));
            await expect(
                magnetaProxy.rescueERC20(await tokenOut.getAddress(), owner.address, ethers.parseEther("10")),
            ).to.emit(magnetaProxy, "Rescued");

            await owner.sendTransaction({ to: await magnetaProxy.getAddress(), value: ethers.parseEther("1") });
            await expect(
                magnetaProxy.rescueETH(stranger.address, ethers.parseEther("1")),
            ).to.emit(magnetaProxy, "Rescued");
        });
    });
});
