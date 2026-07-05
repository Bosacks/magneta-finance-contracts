import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Sprint 2 tests — verify CREATE_TOKEN op dispatches correctly through
 * MagnetaGateway → TokenCreationModule → mock OFT factories.
 *
 * Real cross-chain (LZ-relayed) dispatch is covered by the existing
 * `CrossChainIntegration.test.ts`; this file focuses on the local op flow
 * (gateway.executeOperation) and the module's own logic.
 */
describe("TokenCreationModule", function () {
    const OP_CREATE_TOKEN = 13;     // 14th entry in OpType enum (0-indexed)
    const TEMPLATE_STANDARD = 0;
    const TEMPLATE_AUTO_LIQUIDITY = 1;

    let owner: SignerWithAddress;
    let alice: SignerWithAddress;
    let feeVault: SignerWithAddress;

    let endpoint: any;
    let usdc: any;
    let gateway: any;
    let module: any;
    let standardFactory: any;
    let autoLiquidityFactory: any;

    beforeEach(async () => {
        [owner, alice, feeVault] = await ethers.getSigners();

        // Mock LZ endpoint + USDC (Gateway expects USDC for fee collection)
        const Endpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
        endpoint = await Endpoint.deploy(40245);

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        usdc = await MockERC20.deploy("USDC", "USDC", 6, ethers.parseUnits("1000000", 6));

        // Gateway — owner is the delegate, feeVault gets the USDC markup
        const Gateway = await ethers.getContractFactory("MagnetaGateway");
        gateway = await Gateway.deploy(
            await endpoint.getAddress(),
            owner.address,            // delegate (becomes owner)
            feeVault.address,
        );
        await gateway.setUsdc(await usdc.getAddress());
        // Chantier #3 — attest DVN floor so modules accept this gateway.
        await gateway.setRequiredDVNCount(2);

        // Mock OFT factories
        const StdFactory = await ethers.getContractFactory("MockOFTStandardFactory");
        standardFactory = await StdFactory.deploy();

        const AlFactory = await ethers.getContractFactory("MockOFTAutoLiquidityFactory");
        autoLiquidityFactory = await AlFactory.deploy();

        // Module
        const Module = await ethers.getContractFactory("TokenCreationModule");
        module = await Module.deploy(
            await gateway.getAddress(),
            await standardFactory.getAddress(),
            await autoLiquidityFactory.getAddress(),
        );

        // Wire factories ↔ module
        await standardFactory.setCrossChainCreator(await module.getAddress());
        await autoLiquidityFactory.setCrossChainCreator(await module.getAddress());

        // Register module on the Gateway for OpType.CREATE_TOKEN
        await gateway.setModule(OP_CREATE_TOKEN, await module.getAddress());

        // Set zero cross-chain fee for these tests (we test dispatch, not fee collection)
        await gateway.setCrossChainFees(0, 0);
    });

    describe("Standard template", function () {
        it("dispatches via Gateway → Module → MockStandardFactory", async function () {
            const standardParams = {
                name: "Multi Memecoin",
                symbol: "MEME",
                tokenURI: "ipfs://meme",
                totalSupply: ethers.parseEther("1000000"),
                revokeUpdate: false,
                revokeFreeze: false,
                revokeMint: false,
            };

            const innerEncoded = ethers.AbiCoder.defaultAbiCoder().encode(
                ["tuple(string,string,string,uint256,bool,bool,bool)"],
                [[
                    standardParams.name,
                    standardParams.symbol,
                    standardParams.tokenURI,
                    standardParams.totalSupply,
                    standardParams.revokeUpdate,
                    standardParams.revokeFreeze,
                    standardParams.revokeMint,
                ]],
            );
            // Prepend the 1-byte template selector
            const params =
                ethers.concat([new Uint8Array([TEMPLATE_STANDARD]), innerEncoded]);

            await gateway.connect(alice).executeOperation(OP_CREATE_TOKEN, params);

            const deployed = await standardFactory.lastDeployed();
            const recordedCreator = await standardFactory.lastCreator();
            expect(deployed).to.not.equal(ethers.ZeroAddress);
            expect(recordedCreator).to.equal(alice.address);

            // Verify the dummy token contract recorded the constructor args
            const Token = await ethers.getContractAt("MockOFTToken", deployed);
            expect(await Token.creator()).to.equal(alice.address);
            expect(await Token.name()).to.equal(standardParams.name);
            expect(await Token.symbol()).to.equal(standardParams.symbol);
            expect(await Token.totalSupply()).to.equal(standardParams.totalSupply);
        });

        it("emits TokenSpawned event with correct args", async function () {
            const innerEncoded = ethers.AbiCoder.defaultAbiCoder().encode(
                ["tuple(string,string,string,uint256,bool,bool,bool)"],
                [["X", "X", "uri", 1n, false, false, false]],
            );
            const params =
                ethers.concat([new Uint8Array([TEMPLATE_STANDARD]), innerEncoded]);

            await expect(gateway.connect(alice).executeOperation(OP_CREATE_TOKEN, params))
                .to.emit(module, "TokenSpawned");
        });
    });

    describe("AutoLiquidity template", function () {
        it("dispatches via Gateway → Module → MockAutoLiquidityFactory", async function () {
            const burnAmount = ethers.parseEther("50000");
            const innerEncoded = ethers.AbiCoder.defaultAbiCoder().encode(
                ["tuple(string,string,string,uint256,uint256)"],
                [["AL Token", "AL", "ipfs://al", ethers.parseEther("1000000"), burnAmount]],
            );
            const params =
                ethers.concat([new Uint8Array([TEMPLATE_AUTO_LIQUIDITY]), innerEncoded]);

            await gateway.connect(alice).executeOperation(OP_CREATE_TOKEN, params);

            const deployed = await autoLiquidityFactory.lastDeployed();
            expect(deployed).to.not.equal(ethers.ZeroAddress);
            expect(await autoLiquidityFactory.lastCreator()).to.equal(alice.address);
            expect(await autoLiquidityFactory.lastBurn()).to.equal(burnAmount);
        });
    });

    describe("Access control", function () {
        it("rejects direct execute() call (not via Gateway)", async function () {
            const ctx = {
                caller: alice.address,
                originChainId: 1n,
                feeVault: feeVault.address,
                tokenSource: ethers.ZeroAddress,
            };
            const innerEncoded = ethers.AbiCoder.defaultAbiCoder().encode(
                ["tuple(string,string,string,uint256,bool,bool,bool)"],
                [["X", "X", "u", 1n, false, false, false]],
            );
            const params =
                ethers.concat([new Uint8Array([TEMPLATE_STANDARD]), innerEncoded]);

            await expect(module.connect(alice).execute(ctx, params))
                .to.be.revertedWithCustomError(module, "OnlyGateway");
        });

        it("rejects unknown template kind", async function () {
            const params =
                ethers.concat([new Uint8Array([99]), new Uint8Array([0x00])]);
            await expect(
                gateway.connect(alice).executeOperation(OP_CREATE_TOKEN, params),
            ).to.be.reverted;
        });

        it("rejects empty payload", async function () {
            await expect(
                gateway.connect(alice).executeOperation(OP_CREATE_TOKEN, "0x"),
            ).to.be.reverted;
        });

        it("reverts if factory not set", async function () {
            // Deploy a fresh module without factories wired
            const Module = await ethers.getContractFactory("TokenCreationModule");
            const bareModule = await Module.deploy(
                await gateway.getAddress(),
                ethers.ZeroAddress,
                ethers.ZeroAddress,
            );
            await gateway.setModule(OP_CREATE_TOKEN, await bareModule.getAddress());

            const innerEncoded = ethers.AbiCoder.defaultAbiCoder().encode(
                ["tuple(string,string,string,uint256,bool,bool,bool)"],
                [["X", "X", "u", 1n, false, false, false]],
            );
            const params =
                ethers.concat([new Uint8Array([TEMPLATE_STANDARD]), innerEncoded]);

            await expect(
                gateway.connect(alice).executeOperation(OP_CREATE_TOKEN, params),
            ).to.be.revertedWithCustomError(bareModule, "FactoryNotSet");
        });
    });

    describe("Admin", function () {
        it("owner can rebind factories", async function () {
            const StdFactory = await ethers.getContractFactory("MockOFTStandardFactory");
            const newFactory = await StdFactory.deploy();
            await module.connect(owner).setStandardFactory(await newFactory.getAddress());
            expect(await module.standardFactory()).to.equal(await newFactory.getAddress());
        });

        it("non-owner cannot rebind factories", async function () {
            await expect(
                module.connect(alice).setStandardFactory(ethers.ZeroAddress),
            ).to.be.reverted;
        });

        // ─── Sprint 9.5 — tokenOpsModule auto-registration ────────────────
        it("owner sets tokenOpsModule and emits event", async function () {
            // Use any deployed contract address (the gateway here) — the
            // setter requires `code.length > 0` (SSP_127138_376 fix). EOAs
            // and zero pad addresses are rejected.
            const contractAddr = await gateway.getAddress();
            await expect(module.connect(owner).setTokenOpsModule(contractAddr))
                .to.emit(module, "TokenOpsModuleUpdated")
                .withArgs(ethers.ZeroAddress, contractAddr);
            expect(await module.tokenOpsModule()).to.equal(contractAddr);
        });

        it("setTokenOpsModule rejects EOAs (code-existence guard)", async function () {
            await expect(
                module.connect(owner).setTokenOpsModule(alice.address),
            ).to.be.revertedWith("TokenCreation: not a contract");
        });

        it("setTokenOpsModule allows zero (intentional disable)", async function () {
            await expect(module.connect(owner).setTokenOpsModule(ethers.ZeroAddress))
                .to.emit(module, "TokenOpsModuleUpdated")
                .withArgs(ethers.ZeroAddress, ethers.ZeroAddress);
        });

        it("non-owner cannot set tokenOpsModule", async function () {
            await expect(
                module.connect(alice).setTokenOpsModule(alice.address),
            ).to.be.reverted;
        });

        it("creation succeeds with tokenOpsModule unset (try/catch swallows)", async function () {
            // tokenOpsModule == 0 by default — _maybeRegisterToken short-circuits.
            const standardParams = {
                name: "NoOps", symbol: "NO", tokenURI: "u",
                totalSupply: ethers.parseEther("1"),
                revokeUpdate: false, revokeFreeze: false, revokeMint: false,
            };
            const innerEncoded = ethers.AbiCoder.defaultAbiCoder().encode(
                ["tuple(string,string,string,uint256,bool,bool,bool)"],
                [[
                    standardParams.name, standardParams.symbol, standardParams.tokenURI,
                    standardParams.totalSupply,
                    standardParams.revokeUpdate, standardParams.revokeFreeze, standardParams.revokeMint,
                ]],
            );
            const params = ethers.concat([
                ethers.toBeHex(TEMPLATE_STANDARD, 1),
                innerEncoded,
            ]);
            await expect(
                gateway.connect(alice).executeOperation(OP_CREATE_TOKEN, params),
            ).to.emit(module, "TokenSpawned");
        });
    });

    describe("Encoding helpers", function () {
        it("encodeStandardParams produces a valid round-trippable payload", async function () {
            const p = {
                name: "T", symbol: "T", tokenURI: "u",
                totalSupply: ethers.parseEther("1"),
                revokeUpdate: true, revokeFreeze: false, revokeMint: true,
            };
            const encoded = await module.encodeStandardParams(p);
            expect(encoded.length).to.be.greaterThan(2); // at least the prefix byte
            // First byte should be 0 (Standard)
            expect(parseInt(encoded.slice(2, 4), 16)).to.equal(TEMPLATE_STANDARD);
        });

        it("encodeAutoLiquidityParams produces a valid round-trippable payload", async function () {
            const p = {
                name: "T", symbol: "T", tokenURI: "u",
                totalSupply: ethers.parseEther("1"),
                liquidityToBurn: 0n,
            };
            const encoded = await module.encodeAutoLiquidityParams(p);
            expect(parseInt(encoded.slice(2, 4), 16)).to.equal(TEMPLATE_AUTO_LIQUIDITY);
        });
    });
});
