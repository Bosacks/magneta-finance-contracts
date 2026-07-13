import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Gas profiling for TokenOpsModule.registerToken (selector 0xbb6f82b8).
 *
 * Sentinelle F-10 follow-up: in the tokens repo, MagnetaOFTStandardFactory makes
 * a best-effort registerToken(...) call to the deployed TokenOpsModule, bounded
 * to 200_000 gas so a malicious/buggy module cannot grief token creation. If the
 * happy-path registration exceeds that cap, legitimate registrations would
 * silently emit RegistrationFailed. This test measures the ACTUAL gasUsed of the
 * happy path (and a worst-case-ish variant) to confirm comfortable headroom.
 *
 * Repo uses ethers v6 (receipt.gasUsed is a bigint).
 *
 * registerToken happy path (contracts/modules/TokenOpsModule.sol:103-117):
 *   - 3 require checks (zero-addr, not-already-registered, auth gate)
 *   - 1 cold SSTORE: tokenAdmin[token] = admin
 *   - emit TokenRegistered(token, admin)
 *   No external calls.
 */

const EID = 40245;

async function deployStack() {
    const [owner, admin, registrar, feeVault] = await ethers.getSigners();

    const Endpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
    const endpoint = await Endpoint.deploy(EID);

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20.deploy("USDC", "USDC", 6, ethers.parseUnits("1000000", 6));

    const Gateway = await ethers.getContractFactory("MagnetaGateway");
    const gateway = await Gateway.deploy(
        await endpoint.getAddress(),
        owner.address,
        feeVault.address
    );
    // Modules require the gateway's attested DVN floor to be >= 2 in their ctor.
    await gateway.connect(owner).setRequiredDVNCount(2);

    const TokenOps = await ethers.getContractFactory("TokenOpsModule");
    const tokenOps = await TokenOps.deploy(
        await gateway.getAddress(),
        await usdc.getAddress()
    );

    return { owner, admin, registrar, feeVault, gateway, usdc, tokenOps };
}

describe("TokenOpsModule.registerToken — gas profiling (Sentinelle F-10)", function () {
    let owner: SignerWithAddress, admin: SignerWithAddress, registrar: SignerWithAddress;
    let tokenOps: any;

    const GAS_CAP = 200_000n;
    const TARGET = 120_000n; // comfortable-headroom target

    beforeEach(async () => {
        ({ owner, admin, registrar, tokenOps } = await deployStack());
    });

    async function deployManagedTokenOwnedByModule(name: string) {
        const Managed = await ethers.getContractFactory("MockManagedToken");
        const token = await Managed.deploy(name, name);
        // Typical factory flow: token deployed with initialOwner = module.
        await token.transferOwnership(await tokenOps.getAddress());
        return token;
    }

    it("measures gasUsed for the happy path via owner() (first registration, cold SSTORE)", async () => {
        const token = await deployManagedTokenOwnedByModule("BR1");

        // selector sanity: registerToken(address,address) == 0x4739f7e5
        // (NOTE: the F-10 brief quoted 0xbb6f82b8, but the actual ABI selector
        // for registerToken(address,address) on this contract is 0x4739f7e5 —
        // verified via keccak256. The gas bound is what matters, not the byte.)
        const selector = tokenOps.interface.getFunction("registerToken").selector;
        expect(selector).to.equal("0x4739f7e5");

        const tx = await tokenOps
            .connect(owner)
            .registerToken(await token.getAddress(), admin.address);
        const receipt = await tx.wait();
        const gasUsed: bigint = receipt!.gasUsed;

        // eslint-disable-next-line no-console
        console.log(`    registerToken (owner path, cold SSTORE) gasUsed = ${gasUsed}`);

        expect(await tokenOps.tokenAdmin(await token.getAddress())).to.equal(admin.address);
        expect(gasUsed).to.be.lessThan(GAS_CAP);
        expect(gasUsed).to.be.lessThan(TARGET);
    });

    it("measures gasUsed via trusted-registrar path (extra SLOAD on the trustedRegistrars map)", async () => {
        // This is the path the cross-chain dispatcher / factory would actually
        // take in production (msg.sender != owner, but allow-listed). It adds a
        // warm/cold SLOAD on trustedRegistrars[msg.sender] vs the owner() path.
        await tokenOps.connect(owner).setTrustedRegistrar(registrar.address, true);

        const token = await deployManagedTokenOwnedByModule("BR2");

        const tx = await tokenOps
            .connect(registrar)
            .registerToken(await token.getAddress(), admin.address);
        const receipt = await tx.wait();
        const gasUsed: bigint = receipt!.gasUsed;

        // eslint-disable-next-line no-console
        console.log(`    registerToken (trusted-registrar path) gasUsed = ${gasUsed}`);

        expect(await tokenOps.tokenAdmin(await token.getAddress())).to.equal(admin.address);
        expect(gasUsed).to.be.lessThan(GAS_CAP);
        expect(gasUsed).to.be.lessThan(TARGET);
    });

    it("worst-case framing: even the heavier registerByTokenOwner (external owner() call) stays under cap", async () => {
        // registerByTokenOwner reads token.owner() (an external STATICCALL) in
        // addition to the cold SSTORE — strictly heavier than registerToken's
        // happy path. If THIS fits under 200k, registerToken certainly does.
        const Managed = await ethers.getContractFactory("MockManagedToken");
        const token = await Managed.deploy("WC", "WC");
        await token.transferOwnership(admin.address);

        const tx = await tokenOps.connect(registrar).registerByTokenOwner(await token.getAddress());
        const receipt = await tx.wait();
        const gasUsed: bigint = receipt!.gasUsed;

        // eslint-disable-next-line no-console
        console.log(`    registerByTokenOwner (external owner() call) gasUsed = ${gasUsed}`);

        expect(gasUsed).to.be.lessThan(GAS_CAP);
    });
});
