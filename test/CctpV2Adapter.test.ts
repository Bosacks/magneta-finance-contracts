import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("CctpV2Adapter — V1 ABI → V2 forwarding", function () {
  let adapter: any;
  let v2Mock: any;
  let usdc: any;
  let gateway: HardhatEthersSigner;   // simulates the MagnetaGateway caller
  let recipient: HardhatEthersSigner;
  let other: HardhatEthersSigner;

  const USDC_AMOUNT = 1_000_000n; // 1 USDC (6 decimals)

  beforeEach(async function () {
    [, gateway, recipient, other] = await ethers.getSigners();

    // V2 messenger mock — captures the 7-arg call so we can assert on
    // the exact V2 signature being forwarded.
    const V2Mock = await ethers.getContractFactory("TokenMessengerV2Mock");
    v2Mock = await V2Mock.deploy();
    await v2Mock.waitForDeployment();

    // USDC mock (any 6-decimal ERC20 will do)
    const USDC = await ethers.getContractFactory("MockERC20");
    usdc = await USDC.deploy("USD Coin", "USDC", 6, 0n);
    await usdc.waitForDeployment();
    await usdc.mint(gateway.address, USDC_AMOUNT * 10n);

    const Adapter = await ethers.getContractFactory("CctpV2Adapter");
    adapter = await Adapter.deploy(await v2Mock.getAddress());
    await adapter.waitForDeployment();
  });

  it("constructor rejects zero V2 messenger", async function () {
    const Adapter = await ethers.getContractFactory("CctpV2Adapter");
    await expect(Adapter.deploy(ethers.ZeroAddress))
      .to.be.revertedWithCustomError(Adapter, "ZeroAddress");
  });

  it("forwards a V1-style depositForBurn → V2 with the documented defaults", async function () {
    const dstDomain = 11;
    const mintRecipient = ethers.zeroPadValue(recipient.address, 32);

    // Gateway approves the adapter, then calls depositForBurn (V1 ABI).
    await usdc.connect(gateway).approve(await adapter.getAddress(), USDC_AMOUNT);
    await expect(
      adapter.connect(gateway).depositForBurn(
        USDC_AMOUNT, dstDomain, mintRecipient, await usdc.getAddress(),
      ),
    ).to.emit(adapter, "V2BurnForwarded");

    // Inspect the V2 mock's last-call snapshot
    const last = await v2Mock.last();
    expect(last.amount).to.equal(USDC_AMOUNT);
    expect(last.destinationDomain).to.equal(dstDomain);
    expect(last.mintRecipient).to.equal(mintRecipient);
    expect(last.burnToken).to.equal(await usdc.getAddress());
    expect(last.destinationCaller).to.equal(ethers.ZeroHash);            // anyone can fulfil
    expect(last.maxFee).to.equal(0n);                                    // no fast-finality fee
    expect(last.minFinalityThreshold).to.equal(2000n);                   // standard finality
  });

  it("transfers USDC from caller and approves V2 messenger before burn", async function () {
    const mintRecipient = ethers.zeroPadValue(recipient.address, 32);
    await usdc.connect(gateway).approve(await adapter.getAddress(), USDC_AMOUNT);

    const gatewayBefore = await usdc.balanceOf(gateway.address);
    const adapterBefore = await usdc.balanceOf(await adapter.getAddress());
    const v2Before      = await usdc.balanceOf(await v2Mock.getAddress());

    await adapter.connect(gateway).depositForBurn(
      USDC_AMOUNT, 11, mintRecipient, await usdc.getAddress(),
    );

    // The mock V2 pulls the USDC via transferFrom on the approval the
    // adapter granted. End state: adapter holds zero, v2 mock holds the
    // burned amount, gateway is down USDC_AMOUNT.
    expect(await usdc.balanceOf(gateway.address)).to.equal(gatewayBefore - USDC_AMOUNT);
    expect(await usdc.balanceOf(await adapter.getAddress())).to.equal(adapterBefore);
    expect(await usdc.balanceOf(await v2Mock.getAddress())).to.equal(v2Before + USDC_AMOUNT);
  });

  it("rejects zero amount", async function () {
    const mintRecipient = ethers.zeroPadValue(recipient.address, 32);
    await expect(
      adapter.connect(gateway).depositForBurn(0n, 11, mintRecipient, await usdc.getAddress()),
    ).to.be.revertedWithCustomError(adapter, "ZeroAmount");
  });

  it("rejects zero burnToken", async function () {
    const mintRecipient = ethers.zeroPadValue(recipient.address, 32);
    await expect(
      adapter.connect(gateway).depositForBurn(USDC_AMOUNT, 11, mintRecipient, ethers.ZeroAddress),
    ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
  });

  it("rejects zero mintRecipient", async function () {
    await expect(
      adapter.connect(gateway).depositForBurn(USDC_AMOUNT, 11, ethers.ZeroHash, await usdc.getAddress()),
    ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
  });

  it("returns nonce == 0 (V2 dropped per-burn nonces)", async function () {
    const mintRecipient = ethers.zeroPadValue(recipient.address, 32);
    await usdc.connect(gateway).approve(await adapter.getAddress(), USDC_AMOUNT);

    const result = await adapter.connect(gateway).depositForBurn.staticCall(
      USDC_AMOUNT, 11, mintRecipient, await usdc.getAddress(),
    );
    expect(result).to.equal(0n);
  });

  it("does not pre-grant USDC allowance to V2 messenger (one-shot per call)", async function () {
    // Before any call, the adapter shouldn't hold a standing allowance to
    // V2 — each call grants exactly the burn amount. Verifies the adapter
    // isn't accidentally configured with infinite approval.
    expect(await usdc.allowance(await adapter.getAddress(), await v2Mock.getAddress()))
      .to.equal(0n);
  });
});
