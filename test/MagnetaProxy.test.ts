import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaProxy, MockERC20, MockSwapRouter } from "../typechain-types";

describe("MagnetaProxy", function () {
    let magnetaProxy: MagnetaProxy;
    let mockRouter: MockSwapRouter;
    let tokenIn: MockERC20;
    let tokenOut: MockERC20;
    let owner: SignerWithAddress;
    let user: SignerWithAddress;
    let feeRecipient: SignerWithAddress;

    const FEE_BPS = 30n; // 0.3%

    beforeEach(async function () {
        [owner, user, feeRecipient] = await ethers.getSigners();

        // Deploy Mock Tokens
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        tokenIn = await MockERC20Factory.deploy("TokenIn", "TKNIN", 18, ethers.parseEther("1000000"));
        tokenOut = await MockERC20Factory.deploy("TokenOut", "TKNOUT", 18, ethers.parseEther("1000000"));

        // Deploy Mock Router
        const MockSwapRouterFactory = await ethers.getContractFactory("MockSwapRouter");
        mockRouter = await MockSwapRouterFactory.deploy();

        // Deploy MagnetaProxy
        const MagnetaProxyFactory = await ethers.getContractFactory("MagnetaProxy");
        magnetaProxy = await MagnetaProxyFactory.deploy(feeRecipient.address);

        // Setup: Fund User and Router
        await tokenIn.transfer(user.address, ethers.parseEther("1000"));
        await tokenOut.transfer(await mockRouter.getAddress(), ethers.parseEther("1000"));
    });

    describe("ERC20 Swaps", function () {
        it("Should execute swap and withdraw fee", async function () {
            const amountIn = ethers.parseEther("100");
            const amountOutMin = ethers.parseEther("90");
            // Logic: Proxy takes fee, then swaps remaining.
            // Fee = 100 * 0.003 = 0.3
            // SwapAmount = 99.7
            const fee = (amountIn * FEE_BPS) / 10000n;
            const amountToSwap = amountIn - fee;

            // Encode mock router call
            // We want the router to send `amountOutMin` back to the proxy (for simplicity of test)
            // In reality, 0x router sends to msg.sender (the proxy) usually.
            // Our MockRouter.swap(tokenOut, amountOut, recipient)
            const swapData = mockRouter.interface.encodeFunctionData("swap", [
                await tokenOut.getAddress(),
                amountOutMin,
                await magnetaProxy.getAddress() // Router sends to Proxy
            ]);

            // Approve Proxy
            await tokenIn.connect(user).approve(await magnetaProxy.getAddress(), amountIn);

            // Execute Swap
            await expect(magnetaProxy.connect(user).executeSwap(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                amountOutMin,
                await mockRouter.getAddress(), // spender
                await mockRouter.getAddress(), // target
                swapData
            ))
                .to.emit(magnetaProxy, "Swapped")
                .withArgs(user.address, await tokenIn.getAddress(), await tokenOut.getAddress(), amountIn, amountOutMin, fee);

            // Verify Balances
            expect(await tokenIn.balanceOf(feeRecipient.address)).to.equal(fee);
            expect(await tokenOut.balanceOf(user.address)).to.equal(amountOutMin);
        });
    });

    describe("ETH Swaps", function () {
        // Similar test for ETH if needed, but ERC20 is the priority for implementation verification
    });
});
