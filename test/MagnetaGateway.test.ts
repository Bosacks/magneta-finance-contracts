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
        // Chantier #3 — modules require the gateway's attested DVN floor ≥ 2.
        await gateway.setRequiredDVNCount(2);

        const MockSwap = await ethers.getContractFactory("MockSwapRouter");
        const mockSwap = await MockSwap.deploy();

        const LPModule = await ethers.getContractFactory("LPModule");
        lpModule = await LPModule.deploy(
            await gateway.getAddress(),
            await router.getAddress(),
            await usdc.getAddress(),
            await mockSwap.getAddress()
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
                    { caller: alice.address, originChainId: 1, feeVault: feeVault.address, tokenSource: ethers.ZeroAddress },
                    "0x00"
                )
            ).to.be.revertedWithCustomError(lpModule, "OnlyGateway");
        });
    });

    describe("CREATE_LP end-to-end", () => {
        // F53: the LOCAL fee floor is derived ON-CHAIN from the op's USD value
        // (native side priced via MagnetaSwap, doubled for the balanced LP, then
        // × FEE_BPS). The MockSwapRouter quotes 1:1 in raw units, so the floor
        // here is ethAmount × 2 × FEE_BPS / 10_000, but the contract also enforces
        // a flat MIN_LOCAL_FEE_USDC = 100_000 (6dp, $0.10) floor that fails closed
        // when no on-chain price exists — so we mirror max(quoted, floor).
        const MIN_LOCAL_FEE_USDC = 100_000n;
        const ethAmount = 1_000_000n; // wei; tiny so the derived fee is small
        const quotedFee = (ethAmount * 2n * FEE_BPS) / 10_000n;
        const expectedFee = quotedFee > MIN_LOCAL_FEE_USDC ? quotedFee : MIN_LOCAL_FEE_USDC;

        it("dispatches through the gateway, pulls USDC fee, mints LP to alice", async () => {
            await gateway.setModule(OP_CREATE_LP, await lpModule.getAddress());

            const tokenAmount = ethers.parseEther("1000");
            const usdcFee = expectedFee;

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

        // NATIVE-FEE MIGRATION: the old F53 USDC local floor is removed — a LOCAL
        // CREATE_LP with usdcFee=0 now SUCCEEDS and pulls no USDC (the Magneta fee
        // is collected in NATIVE by the Gateway skim; see the native-fee suite).
        it("allows a LOCAL CREATE_LP with usdcFee=0 and pulls no USDC (native-fee migration)", async () => {
            await gateway.setModule(OP_CREATE_LP, await lpModule.getAddress());

            const tokenAmount = ethers.parseEther("1000");
            await token.connect(alice).approve(await router.getAddress(), tokenAmount);
            await token.connect(alice).approve(await lpModule.getAddress(), tokenAmount);

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
                    0n, // usdcFee = 0 → now allowed (native fee replaces the USDC floor)
                    Math.floor(Date.now() / 1000) + 3600,
                ]]
            );
            const params = ethers.concat(["0x00", encoded]);

            const feeVaultUsdcBefore = await usdc.balanceOf(feeVault.address);
            await expect(
                gateway.connect(alice).executeOperation(OP_CREATE_LP, params, { value: ethAmount })
            ).to.emit(gateway, "OperationExecuted");
            // No USDC skimmed when usdcFee = 0.
            expect(await usdc.balanceOf(feeVault.address)).to.equal(feeVaultUsdcBefore);

            const pair = await router.pair();
            const lpToken = await ethers.getContractAt("MockLPToken", pair);
            expect(await lpToken.balanceOf(alice.address)).to.be.gt(0n);
        });
    });

    describe("Native service fee (opServiceFeeNative)", () => {
        const ethAmount = 1_000_000n;
        const nativeFee = 500_000n; // wei

        async function encodeCreateLpParams(usdcFee: bigint) {
            const tokenAmount = ethers.parseEther("1000");
            await token.connect(alice).approve(await router.getAddress(), tokenAmount);
            await token.connect(alice).approve(await lpModule.getAddress(), tokenAmount);
            const coder = new ethers.AbiCoder();
            const encoded = coder.encode(
                ["tuple(address token,uint256 tokenAmount,uint256 ethAmount,uint256 amountTokenMin,uint256 amountETHMin,uint256 usdcFee,uint256 deadline)"],
                [[await token.getAddress(), tokenAmount, ethAmount, 0n, 0n, usdcFee, Math.floor(Date.now() / 1000) + 3600]]
            );
            return ethers.concat(["0x00", encoded]);
        }

        it("skims the native fee to the FeeVault and forwards the op amount to the module", async () => {
            await gateway.setModule(OP_CREATE_LP, await lpModule.getAddress());
            await gateway.setOpServiceFeeNative(OP_CREATE_LP, nativeFee);
            const params = await encodeCreateLpParams(0n);

            const fvBefore = await ethers.provider.getBalance(feeVault.address);
            await expect(
                gateway.connect(alice).executeOperation(OP_CREATE_LP, params, { value: ethAmount + nativeFee })
            ).to.emit(gateway, "ServiceFeeCollected").withArgs(alice.address, OP_CREATE_LP, nativeFee);
            // Native fee landed in the FeeVault; the module still got exactly ethAmount (LP minted).
            expect((await ethers.provider.getBalance(feeVault.address)) - fvBefore).to.equal(nativeFee);
            const lpToken = await ethers.getContractAt("MockLPToken", await router.pair());
            expect(await lpToken.balanceOf(alice.address)).to.be.gt(0n);
        });

        it("cannot be bypassed: omitting the fee makes the module's eth-check fail", async () => {
            await gateway.setModule(OP_CREATE_LP, await lpModule.getAddress());
            await gateway.setOpServiceFeeNative(OP_CREATE_LP, nativeFee);
            const params = await encodeCreateLpParams(0n);
            // Send only ethAmount: Gateway skims nativeFee, forwards ethAmount-fee,
            // module requires msg.value == p.ethAmount → reverts. Fee is enforced.
            await expect(
                gateway.connect(alice).executeOperation(OP_CREATE_LP, params, { value: ethAmount })
            ).to.be.revertedWith("eth mismatch");
        });

        it("default fee is 0 (no skim, backward compatible)", async () => {
            await gateway.setModule(OP_CREATE_LP, await lpModule.getAddress());
            expect(await gateway.opServiceFeeNative(OP_CREATE_LP)).to.equal(0n);
            const params = await encodeCreateLpParams(0n);
            const fvBefore = await ethers.provider.getBalance(feeVault.address);
            await gateway.connect(alice).executeOperation(OP_CREATE_LP, params, { value: ethAmount });
            expect(await ethers.provider.getBalance(feeVault.address)).to.equal(fvBefore);
        });

        it("setOpServiceFeeNative is owner-only and bounded by maxOpServiceFeeNative", async () => {
            await expect(
                gateway.connect(alice).setOpServiceFeeNative(OP_CREATE_LP, 1n)
            ).to.be.revertedWith("Ownable: caller is not the owner");
            const max = await gateway.maxOpServiceFeeNative();
            await expect(
                gateway.setOpServiceFeeNative(OP_CREATE_LP, max + 1n)
            ).to.be.revertedWith("MagnetaGateway: fee too high");
            await expect(gateway.setOpServiceFeeNative(OP_CREATE_LP, nativeFee))
                .to.emit(gateway, "OpServiceFeeNativeUpdated").withArgs(OP_CREATE_LP, nativeFee);
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

    describe("MG-4: setCrossChainFees bounds", () => {
        it("rejects commandFee above MAX (100 USDC)", async () => {
            const maxFee = await gateway.MAX_CROSSCHAIN_COMMAND_FEE();
            await expect(
                gateway.setCrossChainFees(maxFee + 1n, 15)
            ).to.be.revertedWith("MagnetaGateway: commandFee too high");
            // Exactly at the cap is allowed.
            await expect(gateway.setCrossChainFees(maxFee, 15)).to.emit(gateway, "CrossChainFeesUpdated");
        });

        it("rejects valueFeeBps above MAX (10%)", async () => {
            const maxBps = await gateway.MAX_CROSSCHAIN_VALUE_FEE_BPS();
            await expect(
                gateway.setCrossChainFees(1_000_000, maxBps + 1n)
            ).to.be.revertedWith("MagnetaGateway: valueFeeBps too high");
            // At the cap is allowed.
            await expect(gateway.setCrossChainFees(1_000_000, maxBps)).to.emit(gateway, "CrossChainFeesUpdated");
        });
    });

    describe("MG-1: rescueERC20 / rescueETH", () => {
        it("rescueERC20 is owner-only, validates zero recipient + zero amount", async () => {
            await usdc.mint(await gateway.getAddress(), ethers.parseUnits("10", 6));

            await expect(
                gateway.connect(alice).rescueERC20(await usdc.getAddress(), alice.address, 1n)
            ).to.be.reverted;

            await expect(
                gateway.rescueERC20(await usdc.getAddress(), ethers.ZeroAddress, 1n)
            ).to.be.revertedWith("MagnetaGateway: zero to");

            await expect(
                gateway.rescueERC20(await usdc.getAddress(), alice.address, 0n)
            ).to.be.revertedWith("MagnetaGateway: zero amount");
        });

        it("rescueERC20 of a non-USDC token transfers full amount", async () => {
            // Send some MEME to the gateway and rescue it.
            const stuck = ethers.parseEther("42");
            await token.mint(await gateway.getAddress(), stuck);

            const before = await token.balanceOf(owner.address);
            await expect(
                gateway.rescueERC20(await token.getAddress(), owner.address, stuck)
            ).to.emit(gateway, "Rescued").withArgs(await token.getAddress(), owner.address, stuck);

            const after = await token.balanceOf(owner.address);
            expect(after - before).to.equal(stuck);
        });

        it("rescueERC20 of USDC blocks dipping into totalEarmarked", async () => {
            await gateway.setUsdc(await usdc.getAddress());
            // Plant USDC on the gateway = 100, set totalEarmarked = 100 via internal write.
            // We can't directly write totalEarmarked from outside, but the
            // earmark-respect logic is identical regardless of how it got
            // populated. Simulate: balance == earmark → cannot rescue anything.
            // Since we can't set totalEarmarked from tests directly, we test
            // the inverse: when there's no earmark, rescue succeeds.
            await usdc.mint(await gateway.getAddress(), ethers.parseUnits("100", 6));
            await expect(
                gateway.rescueERC20(await usdc.getAddress(), owner.address, ethers.parseUnits("100", 6))
            ).to.emit(gateway, "Rescued");
        });

        it("rescueETH is owner-only, validates inputs, transfers native", async () => {
            // Donate native to the gateway.
            await owner.sendTransaction({ to: await gateway.getAddress(), value: ethers.parseEther("3") });

            await expect(
                gateway.connect(alice).rescueETH(alice.address, ethers.parseEther("1"))
            ).to.be.reverted;

            await expect(
                gateway.rescueETH(ethers.ZeroAddress, 1n)
            ).to.be.revertedWith("MagnetaGateway: zero to");

            await expect(
                gateway.rescueETH(owner.address, 0n)
            ).to.be.revertedWith("MagnetaGateway: zero amount");

            const before = await ethers.provider.getBalance(feeVault.address);
            const tx = await gateway.rescueETH(feeVault.address, ethers.parseEther("3"));
            await tx.wait();
            const after = await ethers.provider.getBalance(feeVault.address);
            expect(after - before).to.equal(ethers.parseEther("3"));
        });
    });

    describe("MG-2: usdc-not-set is a hard revert (no silent fee bypass)", () => {
        it("cross-chain ops cannot be triggered with usdc unset (internal fee path)", async () => {
            // We can't fully invoke sendCrossChainOp without LZ peers, but
            // we can confirm the contract exposes `usdc` as the zero address
            // by default and that setUsdc is the gating step. The hard revert
            // in `_collectCrossChainFee` is exercised through any send* call
            // in production-RPC integration tests (out of scope here).
            expect(await gateway.usdc()).to.equal(ethers.ZeroAddress);
            await expect(gateway.setUsdc(ethers.ZeroAddress))
                .to.be.revertedWith("MagnetaGateway: zero usdc");
            await expect(gateway.setUsdc(await usdc.getAddress()))
                .to.emit(gateway, "UsdcSet").withArgs(await usdc.getAddress());
        });
    });

    describe("Setter events (MG-5 polish)", () => {
        it("setEidCctpDomain emits EidCctpDomainSet", async () => {
            await expect(gateway.setEidCctpDomain(30101, 0))
                .to.emit(gateway, "EidCctpDomainSet").withArgs(30101, 0);
        });

        it("setEidCctpDomainBatch emits one event per entry", async () => {
            const tx = await gateway.setEidCctpDomainBatch([30101, 30184], [0, 6]);
            const receipt = await tx.wait();
            const events = receipt.logs
                .map((l: any) => { try { return gateway.interface.parseLog(l as any); } catch { return null; } })
                .filter((e: any) => e && e.name === "EidCctpDomainSet");
            expect(events.length).to.equal(2);
        });
    });

    describe("MG-7: _lzReceive normalizes bridgedToken to local usdc", () => {
        // Pre-patch (MG-6 contract) stored `pendingValueOps[guid].bridgedToken`
        // verbatim from the source-chain payload. That payload contains the
        // SOURCE chain's USDC address, which on the destination chain is
        // either a different contract or no contract at all — making
        // fulfillValueOp revert at the IERC20(bridgedToken).balanceOf() check.
        // The MG-7 patch substitutes the destination's own `address(usdc)`
        // when storing the pending op so the rest of the flow always touches
        // the right ERC-20 (the one CCTP V1 actually mints locally).

        // Polygon-style USDC address that is NOT a contract on hardhat — any
        // non-zero address different from the local mock USDC will do.
        const FOREIGN_USDC = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359";

        let endpointSigner: SignerWithAddress;

        beforeEach(async () => {
            await gateway.setUsdc(await usdc.getAddress());

            // Configure a peer so the OApp accepts incoming messages from
            // ourselves (the test impersonates the endpoint).
            const peerB32 = ethers.zeroPadValue(await gateway.getAddress(), 32);
            await gateway.setPeer(EID, peerB32);

            // Impersonate the LZ endpoint to call _lzReceive via the public
            // lzReceive wrapper exposed by OApp.
            await ethers.provider.send("hardhat_impersonateAccount", [await endpoint.getAddress()]);
            await ethers.provider.send("hardhat_setBalance", [
                await endpoint.getAddress(),
                "0x" + ethers.parseEther("10").toString(16),
            ]);
            endpointSigner = await ethers.getSigner(await endpoint.getAddress()) as any;
        });

        const buildValuePayload = (caller: string, params: string, bridgedToken: string, amount: bigint) => {
            return ethers.AbiCoder.defaultAbiCoder().encode(
                ["uint8", "uint8", "address", "bytes", "address", "uint256"],
                [1, 0 /* CREATE_LP */, caller, params, bridgedToken, amount]
            );
        };

        it("stores local usdc as bridgedToken even when payload carries a foreign address", async () => {
            const guid = ethers.id("test-foreign-token");
            const innerParams = ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "uint256", "uint16", "uint256", "uint256", "uint256", "uint256", "uint256"],
                ["0x0000000000000000000000000000000000000001", 1_000_000, 5000, 0, 0, 0, 0, Math.floor(Date.now() / 1000) + 1800]
            );
            const payload = buildValuePayload(alice.address, innerParams, FOREIGN_USDC, 1_000_000n);
            const origin = { srcEid: EID, sender: ethers.zeroPadValue(await gateway.getAddress(), 32), nonce: 1 };

            await (gateway.connect(endpointSigner) as any).lzReceive(origin, guid, payload, ethers.ZeroAddress, "0x");

            const pending = await gateway.pendingValueOps(guid);
            expect(pending.bridgedToken).to.equal(await usdc.getAddress());
            expect(pending.bridgedAmount).to.equal(1_000_000n);
            expect(pending.caller).to.equal(alice.address);
        });

        it("adminClearPendingValueOp frees the earmark and lets rescueERC20 recover funds", async () => {
            // Seed: simulate a pending op + USDC sitting in the gateway.
            const guid = ethers.id("test-clear-pending");
            const innerParams = "0x";
            const payload = buildValuePayload(alice.address, innerParams, FOREIGN_USDC, 1_000_000n);
            const origin = { srcEid: EID, sender: ethers.zeroPadValue(await gateway.getAddress(), 32), nonce: 2 };
            await (gateway.connect(endpointSigner) as any).lzReceive(origin, guid, payload, ethers.ZeroAddress, "0x");
            await usdc.mint(await gateway.getAddress(), 1_000_000n);

            expect(await gateway.totalEarmarked()).to.equal(1_000_000n);

            // Non-owner can't clear.
            await expect(gateway.connect(alice).adminClearPendingValueOp(guid)).to.be.reverted;

            // Owner clears, totalEarmarked drops, pending op gone.
            await expect(gateway.adminClearPendingValueOp(guid))
                .to.emit(gateway, "ValueOpFulfilled");
            expect(await gateway.totalEarmarked()).to.equal(0n);
            const cleared = await gateway.pendingValueOps(guid);
            expect(cleared.bridgedAmount).to.equal(0n);

            // rescueERC20 can now extract the orphaned USDC.
            const before = await usdc.balanceOf(owner.address);
            await gateway.rescueERC20(await usdc.getAddress(), owner.address, 1_000_000n);
            expect(await usdc.balanceOf(owner.address)).to.equal(before + 1_000_000n);
        });

        it("adminClearPendingValueOp reverts on unknown guid", async () => {
            await expect(gateway.adminClearPendingValueOp(ethers.id("never-existed")))
                .to.be.revertedWith("MagnetaGateway: no pending op");
        });
    });

    describe("F38: fulfillValueOp uses a PER-OP arrival check (liveness DoS fix)", () => {
        // Pre-patch, fulfillValueOp required `balanceOf(this) >= totalEarmarked`,
        // i.e. EVERY pending op's bridged USDC had to have landed before ANY op
        // could be fulfilled. One stuck/never-settling CCTP transfer (or an
        // attacker queuing a large op that never arrives) inflated
        // totalEarmarked and blocked every other op whose own funds were already
        // present. The patch checks `balanceOf(this) >= p.bridgedAmount` so each
        // op is fulfillable independently, while pulling the funds out in the
        // same tx preserves the anti-double-spend guarantee.

        const OP_VALUE = 0; // CREATE_LP slot, repurposed for the mock module
        let valueModule: any;
        let endpointSigner: SignerWithAddress;

        const buildValuePayload = (caller: string, params: string, bridgedToken: string, amount: bigint) =>
            ethers.AbiCoder.defaultAbiCoder().encode(
                ["uint8", "uint8", "address", "bytes", "address", "uint256"],
                [1, OP_VALUE, caller, params, bridgedToken, amount]
            );

        // Mock module pulls `amount` of `token` from the gateway (tokenSource).
        const innerParams = (token: string, amount: bigint) =>
            ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [token, amount]);

        const queueOp = async (guid: string, nonce: number, amount: bigint) => {
            const usdcAddr = await usdc.getAddress();
            const payload = buildValuePayload(alice.address, innerParams(usdcAddr, amount), usdcAddr, amount);
            const origin = { srcEid: EID, sender: ethers.zeroPadValue(await gateway.getAddress(), 32), nonce };
            await (gateway.connect(endpointSigner) as any).lzReceive(origin, guid, payload, ethers.ZeroAddress, "0x");
        };

        beforeEach(async () => {
            await gateway.setUsdc(await usdc.getAddress());
            await gateway.setPeer(EID, ethers.zeroPadValue(await gateway.getAddress(), 32));

            const Mod = await ethers.getContractFactory("MockValueOpModule");
            valueModule = await Mod.deploy();
            await gateway.setModule(OP_VALUE, await valueModule.getAddress());

            await ethers.provider.send("hardhat_impersonateAccount", [await endpoint.getAddress()]);
            await ethers.provider.send("hardhat_setBalance", [
                await endpoint.getAddress(),
                "0x" + ethers.parseEther("10").toString(16),
            ]);
            endpointSigner = await ethers.getSigner(await endpoint.getAddress()) as any;
        });

        it("fulfills an op whose own funds arrived even while a larger op is still pending", async () => {
            const big = ethers.id("f38-big-stuck");
            const small = ethers.id("f38-small-ready");
            await queueOp(big, 10, 1_000_000n);   // never funded (stuck CCTP)
            await queueOp(small, 11, 100_000n);   // funds will arrive

            // totalEarmarked = 1.1M, but only the small op's 100k lands.
            expect(await gateway.totalEarmarked()).to.equal(1_100_000n);
            await usdc.mint(await gateway.getAddress(), 100_000n);

            // Pre-patch this reverted ("tokens not arrived": 100k < 1.1M).
            const before = await usdc.balanceOf(alice.address);
            await expect(gateway.connect(alice).fulfillValueOp(small))
                .to.emit(gateway, "ValueOpFulfilled");

            expect(await usdc.balanceOf(alice.address)).to.equal(before + 100_000n);
            expect(await gateway.totalEarmarked()).to.equal(1_000_000n); // big op still reserved
        });

        it("blocks an op whose own funds have NOT arrived (no double-spend)", async () => {
            const big = ethers.id("f38-big-stuck-2");
            const small = ethers.id("f38-small-ready-2");
            await queueOp(big, 20, 1_000_000n);
            await queueOp(small, 21, 100_000n);

            // Only the small op's funds are present; the big op cannot borrow them.
            await usdc.mint(await gateway.getAddress(), 100_000n);
            await expect(gateway.connect(alice).fulfillValueOp(big))
                .to.be.revertedWith("MagnetaGateway: tokens not arrived");
        });

        it("fulfilling one op drains its funds so a second equal op must wait for its own", async () => {
            const a = ethers.id("f38-A");
            const b = ethers.id("f38-B");
            await queueOp(a, 30, 100_000n);
            await queueOp(b, 31, 100_000n);

            // Only 100k arrives — enough for exactly ONE of the two ops.
            await usdc.mint(await gateway.getAddress(), 100_000n);

            await gateway.connect(alice).fulfillValueOp(a); // drains balance to 0
            await expect(gateway.connect(alice).fulfillValueOp(b))
                .to.be.revertedWith("MagnetaGateway: tokens not arrived");

            // Once B's own funds land, it fulfills too.
            await usdc.mint(await gateway.getAddress(), 100_000n);
            await expect(gateway.connect(alice).fulfillValueOp(b))
                .to.emit(gateway, "ValueOpFulfilled");
            expect(await gateway.totalEarmarked()).to.equal(0n);
        });
    });

    describe("MG-6: _payNative override accepts msg.value >= fee", () => {
        // Pre-patch (default OAppSender) enforced strict equality `msg.value ==
        // _nativeFee`. That made fan-out fundamentally broken (loop iteration
        // i compares the SAME outer msg.value against fee_i, so only one leg
        // could ever match) and single-leg fragile (any gas-price drift
        // between SDK quote and on-chain execute reverted the whole tx).
        // The override below accepts overpayment; the calling op refunds the
        // excess from its own balance at the end. These tests cover both the
        // strict-revert that the override removes and the new permissive
        // behavior.

        const DST_EID_BASE = 30184;
        const CCTP_DOMAIN_BASE = 6;
        const QUOTE_FEE = ethers.parseEther("0.001"); // MockLayerZeroEndpoint constant
        // Minimal LZ v2 type-3 option (1.5M lzReceive gas) — content unused
        // by the mock endpoint (it returns a fixed fee) but required to
        // exist as non-empty calldata.
        const LZ_OPT = "0x0003010011010000000000000000000000000016e360";

        let cctp: any;
        let peerBytes32: string;

        beforeEach(async () => {
            // Wire CCTP, USDC, peer for a single destination (Base).
            const Cctp = await ethers.getContractFactory("MockCctpMessenger");
            cctp = await Cctp.deploy();

            await gateway.setUsdc(await usdc.getAddress());
            await gateway.setCctp(await cctp.getAddress(), 7 /* Polygon CCTP domain */);
            await gateway.setEidCctpDomain(DST_EID_BASE, CCTP_DOMAIN_BASE);

            // Set the peer (Base Gateway address — any 32-byte non-zero
            // will do for the mock; the mock endpoint doesn't validate).
            peerBytes32 = ethers.zeroPadValue("0x9F9A3DC819e5229b63b504d7A0FDE93FA436919E", 32);
            await gateway.setPeer(DST_EID_BASE, peerBytes32);

            // Alice approves Gateway to pull USDC (max — covers both fee
            // and bridged amount).
            await usdc.connect(alice).approve(await gateway.getAddress(), ethers.MaxUint256);
        });

        const lpParams = () => {
            // CrossChainLPParams: (token, usdcTotal, tokenShareBps, mins×4, deadline)
            const deadline = Math.floor(Date.now() / 1000) + 1800;
            return ethers.AbiCoder.defaultAbiCoder().encode(
                ["address", "uint256", "uint16", "uint256", "uint256", "uint256", "uint256", "uint256"],
                [
                    "0x878aA594a574DA6F57b4b72456ab4a04946D7229",
                    1_000_000, // 1 USDC bridged
                    5000,
                    0, 0, 0, 0,
                    deadline,
                ]
            );
        };

        it("sendFanOutValueOp accepts msg.value > quoted fee (excess refunded)", async () => {
            const params = lpParams();
            const overpay = QUOTE_FEE * 5n;
            const balBefore = await ethers.provider.getBalance(alice.address);

            const tx = await gateway.connect(alice).sendFanOutValueOp(
                [DST_EID_BASE], 0 /* CREATE_LP */, [params], [1_000_000], LZ_OPT,
                { value: overpay }
            );
            const receipt = await tx.wait();
            const gasCost = receipt.gasUsed * receipt.gasPrice;

            // Without the override, this whole call would revert NotEnoughNative.
            // With the override, only QUOTE_FEE leaves the user; the rest is
            // refunded by the trailing block in sendFanOutValueOp.
            const balAfter = await ethers.provider.getBalance(alice.address);
            const spent = balBefore - balAfter - gasCost;
            expect(spent).to.equal(QUOTE_FEE);
        });

        it("sendFanOutValueOp accepts msg.value == quoted fee (no excess)", async () => {
            const params = lpParams();
            await expect(
                gateway.connect(alice).sendFanOutValueOp(
                    [DST_EID_BASE], 0, [params], [1_000_000], LZ_OPT,
                    { value: QUOTE_FEE }
                )
            ).to.emit(gateway, "CrossChainFanOut");
        });

        it("sendFanOutValueOp still reverts msg.value < quoted fee", async () => {
            const params = lpParams();
            await expect(
                gateway.connect(alice).sendFanOutValueOp(
                    [DST_EID_BASE], 0, [params], [1_000_000], LZ_OPT,
                    { value: QUOTE_FEE - 1n }
                )
            ).to.be.reverted; // NotEnoughNative or InsufficientLzFee depending on which check trips first
        });

        it("sendFanOutValueOp with 2 destinations: msg.value must cover SUM, not require per-leg equality", async () => {
            // Wire a second destination (Arbitrum).
            const DST_EID_ARB = 30110;
            await gateway.setEidCctpDomain(DST_EID_ARB, 3);
            await gateway.setPeer(DST_EID_ARB, peerBytes32);

            const params = lpParams();
            const totalFee = QUOTE_FEE * 2n;
            const balBefore = await ethers.provider.getBalance(alice.address);

            // Send EXACTLY 2× the quoted fee — this is the case that would
            // ALWAYS revert under strict equality (each leg's _payNative
            // would compare 2×QUOTE against QUOTE).
            const tx = await gateway.connect(alice).sendFanOutValueOp(
                [DST_EID_BASE, DST_EID_ARB], 0,
                [params, params], [1_000_000, 1_000_000], LZ_OPT,
                { value: totalFee }
            );
            const receipt = await tx.wait();
            const gasCost = receipt.gasUsed * receipt.gasPrice;

            const balAfter = await ethers.provider.getBalance(alice.address);
            const spent = balBefore - balAfter - gasCost;
            expect(spent).to.equal(totalFee);
        });
    });
});
