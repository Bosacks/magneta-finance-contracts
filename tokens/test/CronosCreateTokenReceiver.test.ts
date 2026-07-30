import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  CronosCreateTokenReceiver,
  MagnetaTokenFactory,
} from "../typechain-types";

const URI = "ipfs://test-meta";
const SUPPLY = 1_000_000n * 10n ** 18n;

// Match lib/relayer/cronosRelayer.ts EIP-712 schema exactly.
//
// BREAKING CHANGE (Sentinelle audit #14, F-2): `destinationReceiver` and
// `destinationFactory` were added to bind a signed intent to a specific
// receiver instance (see CronosCreateTokenReceiver.sol doc comment). This
// changed CREATE_INTENT_TYPEHASH — any pre-existing off-chain signer
// (lib/relayer/cronosRelayer.ts, magneta-finance-tokens repo) MUST add the
// same two fields in the same position or its signatures will stop
// verifying against this contract.
const TYPES = {
  CreateTokenIntent: [
    { name: "creator",             type: "address" },
    { name: "template",            type: "string"  },
    { name: "name",                type: "string"  },
    { name: "symbol",              type: "string"  },
    { name: "tokenURI",            type: "string"  },
    { name: "totalSupply",         type: "uint256" },
    { name: "liquidityToBurn",     type: "uint256" },
    { name: "revokeUpdate",        type: "bool"    },
    { name: "revokeFreeze",        type: "bool"    },
    { name: "revokeMint",          type: "bool"    },
    { name: "destinationChainId",  type: "uint256" },
    { name: "destinationReceiver", type: "address" },
    { name: "destinationFactory",  type: "address" },
    { name: "nonce",               type: "uint256" },
    { name: "expiry",              type: "uint256" },
  ],
} as const;

function makeIntent(
  creator: string,
  receiverAddress: string,
  factoryAddress: string,
  overrides: Partial<{
    template: "standard" | "autoLiquidity";
    name: string;
    symbol: string;
    tokenURI: string;
    totalSupply: bigint;
    liquidityToBurn: bigint;
    revokeUpdate: boolean;
    revokeFreeze: boolean;
    revokeMint: boolean;
    destinationChainId: bigint;
    destinationReceiver: string;
    destinationFactory: string;
    nonce: bigint;
    expiry: bigint;
  }> = {},
) {
  return {
    creator,
    template:            overrides.template            ?? "standard",
    name:                overrides.name                ?? "T",
    symbol:              overrides.symbol              ?? "T",
    tokenURI:            overrides.tokenURI            ?? URI,
    totalSupply:         overrides.totalSupply         ?? SUPPLY,
    liquidityToBurn:     overrides.liquidityToBurn     ?? 0n,
    revokeUpdate:        overrides.revokeUpdate        ?? false,
    revokeFreeze:        overrides.revokeFreeze        ?? false,
    revokeMint:          overrides.revokeMint          ?? false,
    destinationChainId:  overrides.destinationChainId  ?? 1337n, // hardhat default
    destinationReceiver: overrides.destinationReceiver ?? receiverAddress,
    destinationFactory:  overrides.destinationFactory  ?? factoryAddress,
    nonce:               overrides.nonce               ?? 1n,
    expiry:              overrides.expiry              ?? BigInt(Math.floor(Date.now() / 1000) + 3600),
  };
}

describe("CronosCreateTokenReceiver — EIP-712 verified relayer pattern", function () {
  let receiver: CronosCreateTokenReceiver;
  let factory:  MagnetaTokenFactory;
  let owner:    HardhatEthersSigner;
  let treasury: HardhatEthersSigner;
  let relayer:  HardhatEthersSigner;
  let user:     HardhatEthersSigner;
  let attacker: HardhatEthersSigner;

  // EIP-712 domain bound to a synthetic source chain.
  const SOURCE_CHAIN_ID = 137n; // Polygon, as if user signed there
  let sourceGateway: string;
  let receiverAddr: string;
  let factoryAddr: string;

  beforeEach(async function () {
    [owner, treasury, relayer, user, attacker] = await ethers.getSigners();
    // Use any non-zero address as the synthetic source Gateway. The receiver
    // verifies against `trustedSource[sourceChainId]`, so what matters is that
    // the whitelist entry matches what the user signed against.
    sourceGateway = attacker.address; // pick any addr; whitelist below

    const FactoryC = await ethers.getContractFactory("MagnetaTokenFactory");
    factory = await FactoryC.deploy(treasury.address);
    await factory.waitForDeployment();
    factoryAddr = await factory.getAddress();

    const ReceiverC = await ethers.getContractFactory("CronosCreateTokenReceiver");
    receiver = await ReceiverC.deploy(
      factoryAddr,
      relayer.address,
      owner.address,
    );
    await receiver.waitForDeployment();
    receiverAddr = await receiver.getAddress();

    // Wire the receiver as the factory's crossChainCreator
    await factory.setCrossChainCreator(receiverAddr);

    // Whitelist the synthetic source so intents signed against it are accepted
    await receiver.setTrustedSource(SOURCE_CHAIN_ID, sourceGateway);
  });

  async function signIntent(
    signer: HardhatEthersSigner,
    intent: ReturnType<typeof makeIntent>,
  ): Promise<string> {
    return await signer.signTypedData(
      {
        name: "MagnetaCronosRelayer",
        version: "1",
        chainId: SOURCE_CHAIN_ID,
        verifyingContract: sourceGateway,
      },
      TYPES,
      intent,
    );
  }

  // Happy paths ────────────────────────────────────────────────────────────

  it("standard template: relayer submits valid signed intent → token created with creator = signer", async function () {
    const intent = makeIntent(user.address, receiverAddr, factoryAddr);
    const sig = await signIntent(user, intent);

    const tx = await receiver
      .connect(relayer)
      .executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig);
    const receipt = await tx.wait();

    const event = receipt!.logs
      .map((l) => { try { return receiver.interface.parseLog(l); } catch { return null; } })
      .find((e) => e?.name === "IntentExecuted");
    expect(event).to.not.be.undefined;
    expect(event!.args.creator).to.equal(user.address);

    const tokenAddr = event!.args.token as string;
    const Token = await ethers.getContractAt("ERC20Token", tokenAddr);
    expect(await Token.balanceOf(user.address)).to.equal(SUPPLY);
    expect(await Token.owner()).to.equal(user.address);
  });

  it("autoLiquidity template: signed intent deploys auto-liquidity token", async function () {
    const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
      template: "autoLiquidity",
      liquidityToBurn: SUPPLY / 10n,
    });
    const sig = await signIntent(user, intent);

    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.emit(receiver, "IntentExecuted");
  });

  // Negative paths ─────────────────────────────────────────────────────────

  it("rejects when caller is not the relayer", async function () {
    const intent = makeIntent(user.address, receiverAddr, factoryAddr);
    const sig = await signIntent(user, intent);

    await expect(
      receiver.connect(user).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "NotRelayer");
  });

  it("rejects when source is not whitelisted", async function () {
    const intent = makeIntent(user.address, receiverAddr, factoryAddr);
    const sig = await signIntent(user, intent);

    // Same chainId but a DIFFERENT gateway address from what was whitelisted
    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, user.address, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "UntrustedSource");
  });

  it("rejects when destination chainId mismatches", async function () {
    const intent = makeIntent(user.address, receiverAddr, factoryAddr, { destinationChainId: 25n }); // signed for Cronos, but hardhat = 31337
    const sig = await signIntent(user, intent);

    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "WrongDestinationChain");
  });

  it("rejects when intent is expired", async function () {
    const intent = makeIntent(user.address, receiverAddr, factoryAddr, { expiry: 1n });
    const sig = await signIntent(user, intent);

    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "IntentExpired");
  });

  it("rejects replay of the same intent", async function () {
    const intent = makeIntent(user.address, receiverAddr, factoryAddr);
    const sig = await signIntent(user, intent);

    await receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig);
    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "IntentReplay");
  });

  it("rejects when signer != intent.creator (compromised relayer can't forge)", async function () {
    // Intent claims user.address is the creator, but it's signed by attacker.
    // Attacker is trying to make the receiver mint a token to themselves while
    // displaying user.address as the official creator — must fail.
    const intent = makeIntent(user.address, receiverAddr, factoryAddr);
    const sig = await signIntent(attacker, intent);

    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "BadSignature");
  });

  it("rejects unknown template string", async function () {
    const intent = makeIntent(user.address, receiverAddr, factoryAddr, { template: "bogus" as never });
    const sig = await signIntent(user, intent);

    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "UnknownTemplate");
  });

  // Admin ──────────────────────────────────────────────────────────────────

  it("owner can rotate the relayer", async function () {
    const [, , , , , newRelayer] = await ethers.getSigners();
    await expect(receiver.setRelayer(newRelayer.address))
      .to.emit(receiver, "RelayerUpdated").withArgs(relayer.address, newRelayer.address);
    expect(await receiver.relayer()).to.equal(newRelayer.address);
  });

  it("owner can revoke a trusted source by setting it to zero", async function () {
    await receiver.setTrustedSource(SOURCE_CHAIN_ID, ethers.ZeroAddress);
    expect(await receiver.trustedSource(SOURCE_CHAIN_ID)).to.equal(ethers.ZeroAddress);

    const intent = makeIntent(user.address, receiverAddr, factoryAddr);
    const sig = await signIntent(user, intent);
    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "UntrustedSource");
  });

  it("pause blocks new intents; unpause restores", async function () {
    await receiver.pause();
    const intent = makeIntent(user.address, receiverAddr, factoryAddr);
    const sig = await signIntent(user, intent);
    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "EnforcedPause");

    await receiver.unpause();
    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.emit(receiver, "IntentExecuted");
  });

  it("non-owner cannot rotate relayer or whitelist sources", async function () {
    await expect(
      receiver.connect(user).setRelayer(user.address),
    ).to.be.revertedWithCustomError(receiver, "OwnableUnauthorizedAccount");
    await expect(
      receiver.connect(user).setTrustedSource(1n, user.address),
    ).to.be.revertedWithCustomError(receiver, "OwnableUnauthorizedAccount");
  });

  // ── Sentinelle audit #14 regression tests ─────────────────────────────

  describe("F-1: revocation flags must be honoured or rejected, per template", function () {
    it("rejects an autoLiquidity intent that signs a non-neutral revokeUpdate", async function () {
      // ERC20TokenAutoLiquidity has no revokeUpdate concept — setTokenURI is
      // always callable by the owner. Before the fix this flag was silently
      // dropped: the user signed "update is revoked" but got a token where
      // it wasn't. Must now revert instead of minting a mismatched token.
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        template: "autoLiquidity",
        revokeUpdate: true,
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.be.revertedWithCustomError(receiver, "AutoLiquidityRevokeFlagsUnsupported");
    });

    it("rejects an autoLiquidity intent that signs a non-neutral revokeFreeze", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        template: "autoLiquidity",
        revokeFreeze: true,
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.be.revertedWithCustomError(receiver, "AutoLiquidityRevokeFlagsUnsupported");
    });

    it("rejects an autoLiquidity intent that signs a non-neutral revokeMint", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        template: "autoLiquidity",
        revokeMint: true,
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.be.revertedWithCustomError(receiver, "AutoLiquidityRevokeFlagsUnsupported");
    });

    it("accepts an autoLiquidity intent when all three revoke flags stay neutral (false)", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        template: "autoLiquidity",
        liquidityToBurn: SUPPLY / 10n,
        revokeUpdate: false,
        revokeFreeze: false,
        revokeMint: false,
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.emit(receiver, "IntentExecuted");
    });

    it("rejects a standard intent that signs a non-zero liquidityToBurn", async function () {
      // ERC20Token (standard) has no liquidity-burn step at all — the field
      // was previously accepted and silently ignored.
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        template: "standard",
        liquidityToBurn: 1n,
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.be.revertedWithCustomError(receiver, "StandardLiquidityToBurnUnsupported");
    });

    it("standard intent honours revokeUpdate/revokeFreeze/revokeMint on the created token", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        template: "standard",
        revokeUpdate: true,
        revokeFreeze: true,
        revokeMint: true,
      });
      const sig = await signIntent(user, intent);

      const tx = await receiver
        .connect(relayer)
        .executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig);
      const receipt = await tx.wait();
      const event = receipt!.logs
        .map((l) => { try { return receiver.interface.parseLog(l); } catch { return null; } })
        .find((e) => e?.name === "IntentExecuted");
      const tokenAddr = event!.args.token as string;

      const Token = await ethers.getContractAt("ERC20Token", tokenAddr);
      expect(await Token.revokeUpdateEnabled()).to.equal(true);
      expect(await Token.revokeFreezeEnabled()).to.equal(true);
      expect(await Token.revokeMintEnabled()).to.equal(true);
    });
  });

  describe("F-2: intent must be bound to this specific receiver + factory", function () {
    it("rejects when destinationReceiver points at a different address", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        destinationReceiver: attacker.address, // some other, non-receiver address
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.be.revertedWithCustomError(receiver, "WrongDestinationReceiver");
    });

    it("rejects when destinationFactory points at a different address", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        destinationFactory: attacker.address, // some other, non-factory address
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.be.revertedWithCustomError(receiver, "WrongDestinationFactory");
    });

    it("a signature valid for receiver A cannot be replayed against receiver B on the same factory", async function () {
      // Simulates the exact migration scenario from the audit: a second
      // receiver instance is deployed against the SAME factory and
      // authorized as crossChainCreator. Before the fix, an intent executed
      // (and consumed) on receiver A would still recover a valid signature
      // against receiver B, whose `processedIntents` starts empty — a
      // duplicate token mint. Binding destinationReceiver into the signed
      // struct makes the digest itself receiver-specific, so it now reverts
      // with BadSignature (the signature doesn't recover intent.creator for
      // receiver B's own digest) rather than silently succeeding.
      const intentForA = makeIntent(user.address, receiverAddr, factoryAddr);
      const sigForA = await signIntent(user, intentForA);

      // Execute once against the real (A) receiver — succeeds.
      await receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intentForA, sigForA);

      // Deploy a second receiver instance (B) against the same factory and
      // authorize it (as would happen mid-migration).
      const ReceiverC = await ethers.getContractFactory("CronosCreateTokenReceiver");
      const receiverB = await ReceiverC.deploy(factoryAddr, relayer.address, owner.address);
      await receiverB.waitForDeployment();
      await factory.setCrossChainCreator(await receiverB.getAddress());
      await receiverB.setTrustedSource(SOURCE_CHAIN_ID, sourceGateway);

      // Replay the SAME (sourceChainId, sourceGateway, intentForA, sigForA)
      // against receiver B. intentForA.destinationReceiver is receiver A's
      // address, not B's, so B's own address(this) check fails the digest
      // match and the recovered signer will not equal intent.creator.
      await expect(
        receiverB.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intentForA, sigForA),
      ).to.be.revertedWithCustomError(receiverB, "WrongDestinationReceiver");
    });
  });

  describe("F-3: ownership transfer is two-step (Ownable2Step)", function () {
    it("transferOwnership alone does NOT change owner() — pendingOwner must acceptOwnership", async function () {
      const [, , , , , candidate] = await ethers.getSigners();

      await receiver.transferOwnership(candidate.address);
      expect(await receiver.owner()).to.equal(owner.address); // unchanged
      expect(await receiver.pendingOwner()).to.equal(candidate.address);

      // Owner is unaffected until the candidate explicitly accepts.
      await expect(
        receiver.connect(candidate).acceptOwnership(),
      ).to.emit(receiver, "OwnershipTransferred").withArgs(owner.address, candidate.address);
      expect(await receiver.owner()).to.equal(candidate.address);
    });

    it("a typo'd/inaccessible pending owner cannot brick admin functions — old owner keeps control until accepted", async function () {
      const inaccessible = "0x000000000000000000000000000000000000dead";
      await receiver.transferOwnership(inaccessible);

      // Old owner can still act (e.g. rotate the pending transfer, or any
      // other onlyOwner call) because ownership never actually moved.
      const [, , , , , newRelayer] = await ethers.getSigners();
      await expect(receiver.setRelayer(newRelayer.address)).to.not.be.reverted;
      expect(await receiver.owner()).to.equal(owner.address);
    });

    it("only the pending owner can accept", async function () {
      const [, , , , , candidate] = await ethers.getSigners();
      await receiver.transferOwnership(candidate.address);

      await expect(
        receiver.connect(attacker).acceptOwnership(),
      ).to.be.revertedWithCustomError(receiver, "OwnableUnauthorizedAccount");
    });
  });

  // ── Sentinelle re-scan #16 regression tests ───────────────────────────

  describe("Report #16 F-3: CREATE_INTENT_TYPEHASH is a verifiable keccak256(...) constant", function () {
    it("matches the exact value the old opaque literal held (no breaking change)", async function () {
      const expected = ethers.keccak256(
        ethers.toUtf8Bytes(
          "CreateTokenIntent(address creator,string template,string name,string symbol,string tokenURI,uint256 totalSupply,uint256 liquidityToBurn,bool revokeUpdate,bool revokeFreeze,bool revokeMint,uint256 destinationChainId,address destinationReceiver,address destinationFactory,uint256 nonce,uint256 expiry)",
        ),
      );
      expect(expected).to.equal(
        "0x3a18bf21af8814f022a2d9158fca22f47530fba5c97ac36f8478847033f431eb",
      );
      expect(await receiver.CREATE_INTENT_TYPEHASH()).to.equal(expected);
    });
  });

  describe("Report #16 F-1: bounded intent lifetime + creator-initiated cancellation", function () {
    it("rejects an intent whose expiry is further out than MAX_INTENT_TTL", async function () {
      const ttl = await receiver.MAX_INTENT_TTL();
      const now = await time.latest();
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        expiry: BigInt(now) + ttl + 3600n, // 1h past the max allowed TTL
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.be.revertedWithCustomError(receiver, "IntentExpiryTooFarInFuture");
    });

    it("accepts an intent whose expiry sits exactly at the MAX_INTENT_TTL boundary", async function () {
      const ttl = await receiver.MAX_INTENT_TTL();
      const now = await time.latest();
      const intent = makeIntent(user.address, receiverAddr, factoryAddr, {
        expiry: BigInt(now) + ttl, // right at the limit, not past it
      });
      const sig = await signIntent(user, intent);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.emit(receiver, "IntentExecuted");
    });

    it("creator can cancel their own signed intent; a subsequent executeCreate then reverts with IntentReplay", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr);
      const sig = await signIntent(user, intent);

      const expectedDigest = await receiver.digestOf(SOURCE_CHAIN_ID, sourceGateway, intent);

      await expect(
        receiver.connect(user).cancelIntent(SOURCE_CHAIN_ID, sourceGateway, intent),
      ).to.emit(receiver, "IntentCancelled").withArgs(expectedDigest, user.address);

      expect(await receiver.processedIntents(expectedDigest)).to.equal(true);

      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.be.revertedWithCustomError(receiver, "IntentReplay");
    });

    it("a third party cannot cancel someone else's intent", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr);

      await expect(
        receiver.connect(attacker).cancelIntent(SOURCE_CHAIN_ID, sourceGateway, intent),
      ).to.be.revertedWithCustomError(receiver, "NotIntentCreator");

      // Confirm it genuinely wasn't cancelled: the intent still executes fine.
      const sig = await signIntent(user, intent);
      await expect(
        receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
      ).to.emit(receiver, "IntentExecuted");
    });

    it("cancelling an already-executed intent reverts with IntentReplay (can't double-mark)", async function () {
      const intent = makeIntent(user.address, receiverAddr, factoryAddr);
      const sig = await signIntent(user, intent);

      await receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig);

      await expect(
        receiver.connect(user).cancelIntent(SOURCE_CHAIN_ID, sourceGateway, intent),
      ).to.be.revertedWithCustomError(receiver, "IntentReplay");
    });
  });
});
