import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaERC20OFT } from "../typechain-types";

/**
 * EIP-2612 `permit` on MagnetaERC20OFT.
 *
 * Every signature here is produced by ethers' `signTypedData`, an
 * implementation entirely independent of the contract's own digest
 * construction. That is deliberate: a test that built the digest the same way
 * MagnetaERC20Permit does would pass just as happily against a wrong typehash
 * or a wrong domain, and the whole point of hand-rolling the extension
 * (bytecode budget — see the contract's docstring) is that it must be checked
 * against something external.
 */
describe("MagnetaERC20Permit — EIP-2612", function () {
    let token: MagnetaERC20OFT;
    let owner: HardhatEthersSigner;
    let spender: HardhatEthersSigner;
    let stranger: HardhatEthersSigner;
    let chainId: bigint;

    const SUPPLY = ethers.parseEther("1000000");
    const MAX_DEADLINE = ethers.MaxUint256;

    beforeEach(async function () {
        [owner, spender, stranger] = await ethers.getSigners();

        const EndpointMock = await ethers.getContractFactory("MockLZEndpoint");
        const endpoint = await EndpointMock.deploy();
        await endpoint.waitForDeployment();

        const TokenC = await ethers.getContractFactory("MagnetaERC20OFT");
        token = await TokenC.deploy(
            "Permit Token", "PMT", "ipfs://x", SUPPLY, owner.address,
            false, false, false, await endpoint.getAddress(), ethers.ZeroAddress,
        );
        await token.waitForDeployment();

        chainId = (await ethers.provider.getNetwork()).chainId;
    });

    /** Builds the EIP-712 payload from the standard, not from the contract. */
    async function signPermit(
        signer: HardhatEthersSigner,
        spenderAddr: string,
        value: bigint,
        deadline: bigint,
        nonce?: bigint,
    ) {
        const domain = {
            name: "Permit Token",
            version: "1",
            chainId,
            verifyingContract: await token.getAddress(),
        };
        const types = {
            Permit: [
                { name: "owner", type: "address" },
                { name: "spender", type: "address" },
                { name: "value", type: "uint256" },
                { name: "nonce", type: "uint256" },
                { name: "deadline", type: "uint256" },
            ],
        };
        const message = {
            owner: signer.address,
            spender: spenderAddr,
            value,
            nonce: nonce ?? (await token.nonces(signer.address)),
            deadline,
        };
        const sig = await signer.signTypedData(domain, types, message);
        return ethers.Signature.from(sig);
    }

    it("grants the allowance from a signature, with no transaction from the owner", async function () {
        const value = ethers.parseEther("2000000");
        const { v, r, s } = await signPermit(owner, spender.address, value, MAX_DEADLINE);

        expect(await token.allowance(owner.address, spender.address)).to.equal(0n);

        // Submitted by `stranger`: the owner never sends a transaction, which
        // is the entire point — the approve step stops costing gas and stops
        // being a second wallet confirmation.
        await token.connect(stranger).permit(
            owner.address, spender.address, value, MAX_DEADLINE, v, r, s,
        );

        expect(await token.allowance(owner.address, spender.address)).to.equal(value);
        expect(await token.nonces(owner.address)).to.equal(1n);
    });

    it("lets the spender actually move the tokens afterwards", async function () {
        const value = ethers.parseEther("500");
        const { v, r, s } = await signPermit(owner, spender.address, value, MAX_DEADLINE);
        await token.permit(owner.address, spender.address, value, MAX_DEADLINE, v, r, s);

        await token.connect(spender).transferFrom(owner.address, spender.address, value);
        expect(await token.balanceOf(spender.address)).to.equal(value);
    });

    it("rejects a replay of the same signature", async function () {
        const value = ethers.parseEther("1");
        const { v, r, s } = await signPermit(owner, spender.address, value, MAX_DEADLINE);

        await token.permit(owner.address, spender.address, value, MAX_DEADLINE, v, r, s);
        await expect(
            token.permit(owner.address, spender.address, value, MAX_DEADLINE, v, r, s),
        ).to.be.revertedWithCustomError(token, "InvalidSigner");
    });

    it("rejects an expired deadline", async function () {
        const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
        const past = now - 1n;
        const { v, r, s } = await signPermit(owner, spender.address, 1n, past);

        await expect(
            token.permit(owner.address, spender.address, 1n, past, v, r, s),
        ).to.be.revertedWithCustomError(token, "PermitExpired");
    });

    it("rejects a signature from someone other than the stated owner", async function () {
        const value = ethers.parseEther("1");
        // `stranger` signs, but the call claims `owner` granted it.
        const { v, r, s } = await signPermit(stranger, spender.address, value, MAX_DEADLINE);

        await expect(
            token.permit(owner.address, spender.address, value, MAX_DEADLINE, v, r, s),
        ).to.be.revertedWithCustomError(token, "InvalidSigner");
    });

    it("rejects a signature bound to a different spender", async function () {
        const value = ethers.parseEther("1");
        const { v, r, s } = await signPermit(owner, stranger.address, value, MAX_DEADLINE);

        await expect(
            token.permit(owner.address, spender.address, value, MAX_DEADLINE, v, r, s),
        ).to.be.revertedWithCustomError(token, "InvalidSigner");
    });

    it("rejects a signature bound to a different amount", async function () {
        const { v, r, s } = await signPermit(owner, spender.address, ethers.parseEther("1"), MAX_DEADLINE);

        await expect(
            token.permit(owner.address, spender.address, ethers.parseEther("2"), MAX_DEADLINE, v, r, s),
        ).to.be.revertedWithCustomError(token, "InvalidSigner");
    });

    it("rejects a signature built on the wrong nonce", async function () {
        const value = ethers.parseEther("1");
        const { v, r, s } = await signPermit(owner, spender.address, value, MAX_DEADLINE, 7n);

        await expect(
            token.permit(owner.address, spender.address, value, MAX_DEADLINE, v, r, s),
        ).to.be.revertedWithCustomError(token, "InvalidSigner");
    });

    it("rejects the malleable variant of a valid signature", async function () {
        const value = ethers.parseEther("1");
        const { v, r, s } = await signPermit(owner, spender.address, value, MAX_DEADLINE);

        // (r, s, v) and (r, n - s, v ^ 1) both recover the same key. ecrecover
        // accepts both; the contract must not.
        const N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141n;
        const flippedS = ethers.toBeHex(N - BigInt(s), 32);
        const flippedV = v === 27 ? 28 : 27;

        await expect(
            token.permit(owner.address, spender.address, value, MAX_DEADLINE, flippedV, r, flippedS),
        ).to.be.revertedWithCustomError(token, "InvalidSigner");
    });

    it("exposes a DOMAIN_SEPARATOR matching the EIP-712 definition", async function () {
        const expected = ethers.TypedDataEncoder.hashDomain({
            name: "Permit Token",
            version: "1",
            chainId,
            verifyingContract: await token.getAddress(),
        });
        expect(await token.DOMAIN_SEPARATOR()).to.equal(expected);
    });

    it("binds the signature to this chain, so it cannot be replayed on another", async function () {
        const value = ethers.parseEther("1");
        const domain = {
            name: "Permit Token",
            version: "1",
            chainId: chainId + 1n, // signed for a different chain
            verifyingContract: await token.getAddress(),
        };
        const types = {
            Permit: [
                { name: "owner", type: "address" },
                { name: "spender", type: "address" },
                { name: "value", type: "uint256" },
                { name: "nonce", type: "uint256" },
                { name: "deadline", type: "uint256" },
            ],
        };
        const sig = ethers.Signature.from(
            await owner.signTypedData(domain, types, {
                owner: owner.address,
                spender: spender.address,
                value,
                nonce: 0n,
                deadline: MAX_DEADLINE,
            }),
        );

        await expect(
            token.permit(owner.address, spender.address, value, MAX_DEADLINE, sig.v, sig.r, sig.s),
        ).to.be.revertedWithCustomError(token, "InvalidSigner");
    });

    it("keeps nonces independent per owner", async function () {
        const value = ethers.parseEther("1");
        await token.transfer(stranger.address, value);

        const a = await signPermit(owner, spender.address, value, MAX_DEADLINE);
        await token.permit(owner.address, spender.address, value, MAX_DEADLINE, a.v, a.r, a.s);

        expect(await token.nonces(owner.address)).to.equal(1n);
        expect(await token.nonces(stranger.address)).to.equal(0n);

        const b = await signPermit(stranger, spender.address, value, MAX_DEADLINE);
        await token.permit(stranger.address, spender.address, value, MAX_DEADLINE, b.v, b.r, b.s);
        expect(await token.nonces(stranger.address)).to.equal(1n);
    });
});
