import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";

/**
 * Integration tests for MagnetaBridgeOApp.
 *
 * Architecture:
 *   - Two MockLayerZeroEndpoint instances simulate "Chain A" (Base, eid=40245)
 *     and "Chain B" (Arbitrum, eid=40231).
 *   - Two MagnetaBridgeOApp contracts are deployed (one per chain).
 *   - Peers are cross-registered so each bridge knows the other.
 *   - endpointB.deliverMessage() simulates a LayerZero relayer delivering
 *     a message to bridgeB._lzReceive().
 */
describe("MagnetaBridgeOApp", function () {
    // LayerZero endpoint IDs (same as mainnet LZ V2 IDs)
    const EID_A = 40245; // Base
    const EID_B = 40231; // Arbitrum

    let owner: SignerWithAddress;
    let alice: SignerWithAddress;
    let bob: SignerWithAddress;
    let feeRecipient: SignerWithAddress;

    // Contracts
    let endpointA: any;
    let endpointB: any;
    let bridgeA: any;
    let bridgeB: any;
    let token: any;

    const BRIDGE_AMOUNT = ethers.parseEther("100");
    const LIQUIDITY = ethers.parseEther("1000");
    const LZ_FEE = ethers.parseEther("0.001"); // matches MockLayerZeroEndpoint.QUOTE_NATIVE_FEE
    const FEE_BPS = 10n; // 0.1% — matches MagnetaBridgeOApp.BRIDGE_FEE_BPS

    beforeEach(async function () {
        [owner, alice, bob, feeRecipient] = await ethers.getSigners();

        // ── Mock endpoints (simulate two separate chains) ──────────────────────
        const MockEndpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
        endpointA = await MockEndpoint.deploy(EID_A);
        endpointB = await MockEndpoint.deploy(EID_B);

        // ── Bridge A (Chain A / Base) ──────────────────────────────────────────
        const Bridge = await ethers.getContractFactory("MagnetaBridgeOApp");
        bridgeA = await Bridge.deploy(
            await endpointA.getAddress(),
            owner.address,   // delegate → also becomes Ownable owner
            feeRecipient.address,
            EID_A
        );

        // ── Bridge B (Chain B / Arbitrum) ──────────────────────────────────────
        bridgeB = await Bridge.deploy(
            await endpointB.getAddress(),
            owner.address,
            feeRecipient.address,
            EID_B
        );

        // ── Cross-register peers ───────────────────────────────────────────────
        // OApp uses bytes32 peer addresses (left-padded to 32 bytes)
        const bridgeABytes32 = ethers.zeroPadValue(await bridgeA.getAddress(), 32);
        const bridgeBBytes32 = ethers.zeroPadValue(await bridgeB.getAddress(), 32);
        await bridgeA.setPeer(EID_B, bridgeBBytes32);
        await bridgeB.setPeer(EID_A, bridgeABytes32);

        // ── ERC20 test token ───────────────────────────────────────────────────
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        token = await MockERC20.deploy("USD Mock", "USDC", 18, ethers.parseEther("1000000"));

        // ── Enable token on both bridges ───────────────────────────────────────
        // bridgeA: can send to chain B
        await bridgeA.setSupportedToken(EID_B, await token.getAddress(), true);
        await bridgeA.setBridgeableToken(EID_B, await token.getAddress(), true);
        // bridgeB: can receive from chain A, and tracks liquidity on its local eid
        await bridgeB.setSupportedToken(EID_A, await token.getAddress(), true);
        await bridgeB.setBridgeableToken(EID_A, await token.getAddress(), true);
        await bridgeB.setSupportedToken(EID_B, await token.getAddress(), true);

        // ── Seed liquidity on bridgeB for receiving ────────────────────────────
        await token.approve(await bridgeB.getAddress(), LIQUIDITY);
        await bridgeB.addBridgeLiquidity(EID_B, await token.getAddress(), LIQUIDITY);

        // ── Fund alice for bridge tests ────────────────────────────────────────
        await token.transfer(alice.address, ethers.parseEther("10000"));
    });

    // ─── Deployment ────────────────────────────────────────────────────────────

    describe("Deployment", function () {
        it("stores the correct local endpoint IDs", async function () {
            expect(await bridgeA.localEid()).to.equal(EID_A);
            expect(await bridgeB.localEid()).to.equal(EID_B);
        });

        it("sets the fee recipient", async function () {
            expect(await bridgeA.feeRecipient()).to.equal(feeRecipient.address);
            expect(await bridgeB.feeRecipient()).to.equal(feeRecipient.address);
        });

        it("sets peers correctly", async function () {
            const bridgeBBytes32 = ethers.zeroPadValue(await bridgeB.getAddress(), 32);
            expect(await bridgeA.peers(EID_B)).to.equal(bridgeBBytes32);
        });

        it("reverts construction with zero endpoint", async function () {
            const Bridge = await ethers.getContractFactory("MagnetaBridgeOApp");
            // OApp parent constructor calls setDelegate on address(0) before our check,
            // causing a low-level revert without a message string.
            await expect(
                Bridge.deploy(ethers.ZeroAddress, owner.address, feeRecipient.address, EID_A)
            ).to.be.reverted;
        });

        it("reverts construction with zero localEid", async function () {
            const Bridge = await ethers.getContractFactory("MagnetaBridgeOApp");
            await expect(
                Bridge.deploy(await endpointA.getAddress(), owner.address, feeRecipient.address, 0)
            ).to.be.revertedWith("MagnetaBridgeOApp: invalid local endpoint ID");
        });
    });

    // ─── Liquidity management ──────────────────────────────────────────────────

    describe("Liquidity Management", function () {
        it("allows owner to add liquidity and emits event", async function () {
            const amount = ethers.parseEther("500");
            await token.approve(await bridgeA.getAddress(), amount);
            await bridgeA.setSupportedToken(EID_A, await token.getAddress(), true);

            await expect(bridgeA.addBridgeLiquidity(EID_A, await token.getAddress(), amount))
                .to.emit(bridgeA, "BridgeLiquidityAdded")
                .withArgs(EID_A, await token.getAddress(), amount);

            expect(await bridgeA.getBridgeLiquidity(EID_A, await token.getAddress())).to.equal(amount);
        });

        it("reverts addBridgeLiquidity for unsupported token", async function () {
            const stranger = ethers.Wallet.createRandom().address;
            await expect(
                bridgeA.addBridgeLiquidity(EID_A, stranger, 100)
            ).to.be.revertedWith("MagnetaBridgeOApp: token not supported");
        });

        it("reverts addBridgeLiquidity for zero amount", async function () {
            await bridgeA.setSupportedToken(EID_A, await token.getAddress(), true);
            await expect(
                bridgeA.addBridgeLiquidity(EID_A, await token.getAddress(), 0)
            ).to.be.revertedWith("MagnetaBridgeOApp: invalid amount");
        });

        it("allows owner to remove liquidity and emits event", async function () {
            const amount = ethers.parseEther("200");
            await expect(bridgeB.removeBridgeLiquidity(EID_B, await token.getAddress(), amount))
                .to.emit(bridgeB, "BridgeLiquidityRemoved")
                .withArgs(EID_B, await token.getAddress(), amount);

            expect(await bridgeB.getBridgeLiquidity(EID_B, await token.getAddress())).to.equal(
                LIQUIDITY - amount
            );
        });

        it("reverts removeBridgeLiquidity when insufficient", async function () {
            await expect(
                bridgeB.removeBridgeLiquidity(EID_B, await token.getAddress(), LIQUIDITY + 1n)
            ).to.be.revertedWith("MagnetaBridgeOApp: insufficient liquidity");
        });

        it("reverts addBridgeLiquidity for non-owner", async function () {
            await bridgeB.setSupportedToken(EID_B, await token.getAddress(), true);
            await token.connect(alice).approve(await bridgeB.getAddress(), 100);
            await expect(
                bridgeB.connect(alice).addBridgeLiquidity(EID_B, await token.getAddress(), 100)
            ).to.be.revertedWith("MagnetaBridgeOApp: not owner");
        });
    });

    // ─── Bridge token send ─────────────────────────────────────────────────────

    describe("bridgeTokens() — send side", function () {
        it("emits TokenBridged with amount after fee", async function () {
            const fee = (BRIDGE_AMOUNT * FEE_BPS) / 10000n;
            const amountAfterFee = BRIDGE_AMOUNT - fee;
            await token.connect(alice).approve(await bridgeA.getAddress(), BRIDGE_AMOUNT);

            await expect(
                bridgeA.connect(alice).bridgeTokens(
                    await token.getAddress(),
                    BRIDGE_AMOUNT,
                    EID_B,
                    bob.address,
                    "0x",
                    false,
                    { value: LZ_FEE }
                )
            )
                .to.emit(bridgeA, "TokenBridged")
                .withArgs(
                    await token.getAddress(),
                    alice.address,
                    bob.address,
                    amountAfterFee,
                    EID_B,
                    anyValue // guid — bytes32 determined at runtime
                );
        });

        it("sends 0.1% fee to feeRecipient", async function () {
            await token.connect(alice).approve(await bridgeA.getAddress(), BRIDGE_AMOUNT);
            const before = await token.balanceOf(feeRecipient.address);

            await bridgeA.connect(alice).bridgeTokens(
                await token.getAddress(), BRIDGE_AMOUNT, EID_B, bob.address, "0x", false,
                { value: LZ_FEE }
            );

            const expectedFee = (BRIDGE_AMOUNT * FEE_BPS) / 10000n;
            expect(await token.balanceOf(feeRecipient.address)).to.equal(before + expectedFee);
        });

        it("records the bridge transaction after send", async function () {
            await token.connect(alice).approve(await bridgeA.getAddress(), BRIDGE_AMOUNT);

            const tx = await bridgeA.connect(alice).bridgeTokens(
                await token.getAddress(), BRIDGE_AMOUNT, EID_B, bob.address, "0x", false,
                { value: LZ_FEE }
            );
            const receipt = await tx.wait();

            // Extract guid from TokenBridged event
            const event = receipt.logs
                .map((l: any) => { try { return bridgeA.interface.parseLog(l); } catch { return null; } })
                .find((e: any) => e?.name === "TokenBridged");
            expect(event).to.not.be.undefined;

            const guid = event.args.guid;
            const stored = await bridgeA.getBridgeTransaction(guid);
            expect(stored.token).to.equal(await token.getAddress());
            expect(stored.from).to.equal(alice.address);
            expect(stored.to).to.equal(bob.address);
            expect(stored.dstEid).to.equal(EID_B);
            expect(stored.completed).to.be.false;
        });

        it("reverts when token not supported on destination", async function () {
            const stranger = ethers.Wallet.createRandom().address;
            await expect(
                bridgeA.connect(alice).bridgeTokens(
                    stranger, BRIDGE_AMOUNT, EID_B, bob.address, "0x", false, { value: LZ_FEE }
                )
            ).to.be.revertedWith("MagnetaBridgeOApp: token not supported on destination");
        });

        it("reverts when token not bridgeable", async function () {
            await bridgeA.setBridgeableToken(EID_B, await token.getAddress(), false);
            await token.connect(alice).approve(await bridgeA.getAddress(), BRIDGE_AMOUNT);
            await expect(
                bridgeA.connect(alice).bridgeTokens(
                    await token.getAddress(), BRIDGE_AMOUNT, EID_B, bob.address, "0x", false,
                    { value: LZ_FEE }
                )
            ).to.be.revertedWith("MagnetaBridgeOApp: token not bridgeable");
        });

        it("reverts with zero amount", async function () {
            await expect(
                bridgeA.connect(alice).bridgeTokens(
                    await token.getAddress(), 0, EID_B, bob.address, "0x", false, { value: LZ_FEE }
                )
            ).to.be.revertedWith("MagnetaBridgeOApp: invalid amount");
        });

        it("reverts with zero recipient", async function () {
            await token.connect(alice).approve(await bridgeA.getAddress(), BRIDGE_AMOUNT);
            await expect(
                bridgeA.connect(alice).bridgeTokens(
                    await token.getAddress(), BRIDGE_AMOUNT, EID_B, ethers.ZeroAddress,
                    "0x", false, { value: LZ_FEE }
                )
            ).to.be.revertedWith("MagnetaBridgeOApp: invalid recipient");
        });

        it("reverts with insufficient native fee", async function () {
            await token.connect(alice).approve(await bridgeA.getAddress(), BRIDGE_AMOUNT);
            await expect(
                bridgeA.connect(alice).bridgeTokens(
                    await token.getAddress(), BRIDGE_AMOUNT, EID_B, bob.address, "0x", false,
                    { value: 0 }
                )
            ).to.be.revertedWith("MagnetaBridgeOApp: insufficient native fee");
        });

        it("reverts when paused", async function () {
            await bridgeA.pause();
            await token.connect(alice).approve(await bridgeA.getAddress(), BRIDGE_AMOUNT);
            await expect(
                bridgeA.connect(alice).bridgeTokens(
                    await token.getAddress(), BRIDGE_AMOUNT, EID_B, bob.address, "0x", false,
                    { value: LZ_FEE }
                )
            ).to.be.revertedWith("MagnetaBridgeOApp: paused");
        });
    });

    // ─── Bridge token receive (simulated delivery) ─────────────────────────────

    describe("_lzReceive() — simulated delivery", function () {
        async function deliverToBridgeB(to: string, amount: bigint, nonce = 1n) {
            const bridgeABytes32 = ethers.zeroPadValue(await bridgeA.getAddress(), 32);
            const guid = ethers.hexlify(ethers.randomBytes(32));
            const payload = ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "address", "uint256"],
                [await token.getAddress(), to, amount]
            );
            await endpointB.deliverMessage(
                await bridgeB.getAddress(),
                { srcEid: EID_A, sender: bridgeABytes32, nonce },
                guid,
                payload
            );
            return guid;
        }

        it("transfers tokens to recipient", async function () {
            const amount = ethers.parseEther("50");
            const before = await token.balanceOf(bob.address);
            await deliverToBridgeB(bob.address, amount);
            expect(await token.balanceOf(bob.address)).to.equal(before + amount);
        });

        it("emits TokenReceived event", async function () {
            const bridgeABytes32 = ethers.zeroPadValue(await bridgeA.getAddress(), 32);
            const amount = ethers.parseEther("30");
            const guid = ethers.hexlify(ethers.randomBytes(32));
            const payload = ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "address", "uint256"],
                [await token.getAddress(), bob.address, amount]
            );

            await expect(
                endpointB.deliverMessage(
                    await bridgeB.getAddress(),
                    { srcEid: EID_A, sender: bridgeABytes32, nonce: 1n },
                    guid,
                    payload
                )
            )
                .to.emit(bridgeB, "TokenReceived")
                .withArgs(await token.getAddress(), bob.address, amount, EID_A, guid);
        });

        it("decrements bridge liquidity after receive", async function () {
            const amount = ethers.parseEther("50");
            const before = await bridgeB.getBridgeLiquidity(EID_B, await token.getAddress());
            await deliverToBridgeB(bob.address, amount);
            expect(await bridgeB.getBridgeLiquidity(EID_B, await token.getAddress())).to.equal(
                before - amount
            );
        });

        it("marks transaction as completed after receive", async function () {
            const bridgeABytes32 = ethers.zeroPadValue(await bridgeA.getAddress(), 32);
            const amount = ethers.parseEther("20");
            const guid = ethers.hexlify(ethers.randomBytes(32));
            const payload = ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "address", "uint256"],
                [await token.getAddress(), bob.address, amount]
            );

            await endpointB.deliverMessage(
                await bridgeB.getAddress(),
                { srcEid: EID_A, sender: bridgeABytes32, nonce: 1n },
                guid,
                payload
            );

            const tx = await bridgeB.getBridgeTransaction(guid);
            expect(tx.completed).to.be.true;
        });

        it("reverts when bridge liquidity is insufficient", async function () {
            const tooMuch = LIQUIDITY + ethers.parseEther("1");
            await expect(deliverToBridgeB(bob.address, tooMuch)).to.be.reverted;
        });

        it("reverts when token not supported from source chain", async function () {
            // Remove support from chain A on bridgeB
            await bridgeB.setSupportedToken(EID_A, await token.getAddress(), false);
            await expect(deliverToBridgeB(bob.address, ethers.parseEther("10"))).to.be.reverted;
        });

        it("reverts when called by non-endpoint address", async function () {
            const bridgeABytes32 = ethers.zeroPadValue(await bridgeA.getAddress(), 32);
            const payload = ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "address", "uint256"],
                [await token.getAddress(), bob.address, ethers.parseEther("10")]
            );
            const guid = ethers.hexlify(ethers.randomBytes(32));

            // Calling lzReceive directly (not from endpoint) must revert
            await expect(
                bridgeB.lzReceive(
                    { srcEid: EID_A, sender: bridgeABytes32, nonce: 1n },
                    guid,
                    payload,
                    ethers.ZeroAddress,
                    "0x"
                )
            ).to.be.reverted;
        });
    });

    // ─── End-to-end flow ───────────────────────────────────────────────────────

    describe("End-to-end: bridgeTokens → deliverMessage", function () {
        it("completes a full cross-chain transfer", async function () {
            const amount = BRIDGE_AMOUNT;
            const fee = (amount * FEE_BPS) / 10000n;
            const amountAfterFee = amount - fee;

            // Alice approves and initiates the bridge
            await token.connect(alice).approve(await bridgeA.getAddress(), amount);
            const bridgeTx = await bridgeA.connect(alice).bridgeTokens(
                await token.getAddress(), amount, EID_B, bob.address, "0x", false,
                { value: LZ_FEE }
            );
            const bridgeReceipt = await bridgeTx.wait();

            // Extract guid from TokenBridged event
            const event = bridgeReceipt.logs
                .map((l: any) => { try { return bridgeA.interface.parseLog(l); } catch { return null; } })
                .find((e: any) => e?.name === "TokenBridged");
            const guid = event.args.guid;

            // Simulate relayer delivery on chain B
            const bridgeABytes32 = ethers.zeroPadValue(await bridgeA.getAddress(), 32);
            const payload = ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "address", "uint256"],
                [await token.getAddress(), bob.address, amountAfterFee]
            );

            const bobBalanceBefore = await token.balanceOf(bob.address);
            await endpointB.deliverMessage(
                await bridgeB.getAddress(),
                { srcEid: EID_A, sender: bridgeABytes32, nonce: 1n },
                guid,
                payload
            );

            // Bob receives the tokens
            expect(await token.balanceOf(bob.address)).to.equal(bobBalanceBefore + amountAfterFee);
            // Bridge transaction marked complete
            const stored = await bridgeB.getBridgeTransaction(guid);
            expect(stored.completed).to.be.true;
        });
    });

    // ─── Admin functions ───────────────────────────────────────────────────────

    describe("Admin", function () {
        it("owner can pause and unpause", async function () {
            await expect(bridgeA.pause()).to.emit(bridgeA, "Paused").withArgs(owner.address);
            expect(await bridgeA.paused()).to.be.true;
            await expect(bridgeA.unpause()).to.emit(bridgeA, "Unpaused").withArgs(owner.address);
            expect(await bridgeA.paused()).to.be.false;
        });

        it("owner can update fee recipient", async function () {
            await expect(bridgeA.setFeeRecipient(alice.address))
                .to.emit(bridgeA, "FeeRecipientUpdated")
                .withArgs(feeRecipient.address, alice.address);
            expect(await bridgeA.feeRecipient()).to.equal(alice.address);
        });

        it("reverts setFeeRecipient for zero address", async function () {
            await expect(bridgeA.setFeeRecipient(ethers.ZeroAddress))
                .to.be.revertedWith("MagnetaBridgeOApp: invalid fee recipient");
        });

        it("owner can emergency withdraw tokens", async function () {
            await token.transfer(await bridgeA.getAddress(), ethers.parseEther("10"));
            const before = await token.balanceOf(owner.address);
            await bridgeA.emergencyWithdraw(await token.getAddress(), ethers.parseEther("10"));
            expect(await token.balanceOf(owner.address)).to.equal(before + ethers.parseEther("10"));
        });

        it("non-owner cannot call admin functions", async function () {
            await expect(bridgeA.connect(alice).pause())
                .to.be.reverted;
            await expect(
                bridgeA.connect(alice).setSupportedToken(EID_B, await token.getAddress(), false)
            ).to.be.revertedWith("MagnetaBridgeOApp: not owner");
            await expect(
                bridgeA.connect(alice).setFeeRecipient(alice.address)
            ).to.be.revertedWith("MagnetaBridgeOApp: not owner");
        });
    });

    // ─── Fee estimation ────────────────────────────────────────────────────────

    describe("Fee estimation", function () {
        it("returns the mock endpoint quote fee", async function () {
            const [nativeFee, lzTokenFee] = await bridgeA.estimateBridgeFee(EID_B, "0x", false);
            expect(nativeFee).to.equal(LZ_FEE);
            expect(lzTokenFee).to.equal(0);
        });
    });
});
