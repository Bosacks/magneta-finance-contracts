import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  CronosCreateTokenReceiver,
  MagnetaTokenFactory,
} from "../typechain-types";

const URI = "ipfs://test-meta";
const SUPPLY = 1_000_000n * 10n ** 18n;

// Match lib/relayer/cronosRelayer.ts EIP-712 schema exactly.
const TYPES = {
  CreateTokenIntent: [
    { name: "creator",            type: "address" },
    { name: "template",           type: "string"  },
    { name: "name",               type: "string"  },
    { name: "symbol",             type: "string"  },
    { name: "tokenURI",           type: "string"  },
    { name: "totalSupply",        type: "uint256" },
    { name: "liquidityToBurn",    type: "uint256" },
    { name: "revokeUpdate",       type: "bool"    },
    { name: "revokeFreeze",       type: "bool"    },
    { name: "revokeMint",         type: "bool"    },
    { name: "destinationChainId", type: "uint256" },
    { name: "nonce",              type: "uint256" },
    { name: "expiry",             type: "uint256" },
  ],
} as const;

function makeIntent(
  creator: string,
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
    nonce: bigint;
    expiry: bigint;
  }> = {},
) {
  return {
    creator,
    template:           overrides.template           ?? "standard",
    name:               overrides.name               ?? "T",
    symbol:             overrides.symbol             ?? "T",
    tokenURI:           overrides.tokenURI           ?? URI,
    totalSupply:        overrides.totalSupply        ?? SUPPLY,
    liquidityToBurn:    overrides.liquidityToBurn    ?? 0n,
    revokeUpdate:       overrides.revokeUpdate       ?? false,
    revokeFreeze:       overrides.revokeFreeze       ?? false,
    revokeMint:         overrides.revokeMint         ?? false,
    destinationChainId: overrides.destinationChainId ?? 1337n, // hardhat default
    nonce:              overrides.nonce              ?? 1n,
    expiry:             overrides.expiry             ?? BigInt(Math.floor(Date.now() / 1000) + 3600),
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

  beforeEach(async function () {
    [owner, treasury, relayer, user, attacker] = await ethers.getSigners();
    // Use any non-zero address as the synthetic source Gateway. The receiver
    // verifies against `trustedSource[sourceChainId]`, so what matters is that
    // the whitelist entry matches what the user signed against.
    sourceGateway = attacker.address; // pick any addr; whitelist below

    const FactoryC = await ethers.getContractFactory("MagnetaTokenFactory");
    factory = await FactoryC.deploy(treasury.address);
    await factory.waitForDeployment();

    const ReceiverC = await ethers.getContractFactory("CronosCreateTokenReceiver");
    receiver = await ReceiverC.deploy(
      await factory.getAddress(),
      relayer.address,
      owner.address,
    );
    await receiver.waitForDeployment();

    // Wire the receiver as the factory's crossChainCreator
    await factory.setCrossChainCreator(await receiver.getAddress());

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
    const intent = makeIntent(user.address);
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
    const intent = makeIntent(user.address, {
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
    const intent = makeIntent(user.address);
    const sig = await signIntent(user, intent);

    await expect(
      receiver.connect(user).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "NotRelayer");
  });

  it("rejects when source is not whitelisted", async function () {
    const intent = makeIntent(user.address);
    const sig = await signIntent(user, intent);

    // Same chainId but a DIFFERENT gateway address from what was whitelisted
    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, user.address, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "UntrustedSource");
  });

  it("rejects when destination chainId mismatches", async function () {
    const intent = makeIntent(user.address, { destinationChainId: 25n }); // signed for Cronos, but hardhat = 31337
    const sig = await signIntent(user, intent);

    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "WrongDestinationChain");
  });

  it("rejects when intent is expired", async function () {
    const intent = makeIntent(user.address, { expiry: 1n });
    const sig = await signIntent(user, intent);

    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "IntentExpired");
  });

  it("rejects replay of the same intent", async function () {
    const intent = makeIntent(user.address);
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
    const intent = makeIntent(user.address);
    const sig = await signIntent(attacker, intent);

    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "BadSignature");
  });

  it("rejects unknown template string", async function () {
    const intent = makeIntent(user.address, { template: "bogus" as never });
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

    const intent = makeIntent(user.address);
    const sig = await signIntent(user, intent);
    await expect(
      receiver.connect(relayer).executeCreate(SOURCE_CHAIN_ID, sourceGateway, intent, sig),
    ).to.be.revertedWithCustomError(receiver, "UntrustedSource");
  });

  it("pause blocks new intents; unpause restores", async function () {
    await receiver.pause();
    const intent = makeIntent(user.address);
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
});
