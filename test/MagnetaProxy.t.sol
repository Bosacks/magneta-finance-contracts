// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaProxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 10_000_000e18);
    }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Simulates a DEX router: pulls tokenIn from msg.sender, sends tokenOut to msg.sender
contract MockSwapRouter {
    uint256 public outputAmount;

    function setOutputAmount(uint256 amount) external { outputAmount = amount; }

    /// Called by MagnetaProxy with approval already set. Pulls tokenIn, sends tokenOut.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockToken(tokenOut).mint(recipient, outputAmount);
    }
}

/// @dev Router that fails (simulates reverted swap)
contract FailingSwapRouter {
    function swap(address, address, uint256, address) external pure {
        revert("Router: swap failed");
    }
}

// ─── Test Suite ───────────────────────────────────────────────────────────────

contract MagnetaProxyTest is Test {
    MagnetaProxy proxy;
    MockToken tokenIn;
    MockToken tokenOut;
    MockSwapRouter router;
    FailingSwapRouter failRouter;

    address owner     = address(this);
    address alice     = makeAddr("alice");
    address bob       = makeAddr("bob");
    address feeWallet = makeAddr("feeWallet");

    function setUp() public {
        proxy      = new MagnetaProxy(feeWallet);
        tokenIn    = new MockToken("Token In",  "TIN");
        tokenOut   = new MockToken("Token Out", "TOUT");
        router     = new MockSwapRouter();
        failRouter = new FailingSwapRouter();

        // Fund alice
        tokenIn.mint(alice, 10_000e18);
    }

    // ─── Helper: build calldata for MockSwapRouter.swap ───────────────────────

    function _buildSwapCalldata(uint256 amountIn) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            MockSwapRouter.swap.selector,
            address(tokenIn),
            address(tokenOut),
            amountIn,
            address(proxy) // tokens land at proxy, proxy forwards to user
        );
    }

    // ── constructor ───────────────────────────────────────────────────────────

    function test_constructor_zeroFeeRecipient_reverts() public {
        vm.expectRevert("Invalid fee recipient");
        new MagnetaProxy(address(0));
    }

    function test_constructor_setsFeeRecipient() public {
        assertEq(proxy.feeRecipient(), feeWallet);
    }

    // ── executeSwap ───────────────────────────────────────────────────────────

    function test_executeSwap_basic() public {
        uint256 amountIn = 1000e18;
        uint256 expectedOut = 950e18;
        router.setOutputAmount(expectedOut);

        uint256 fee = (amountIn * proxy.feeBps()) / 10_000;
        uint256 amountToSwap = amountIn - fee;

        vm.startPrank(alice);
        tokenIn.approve(address(proxy), amountIn);
        proxy.executeSwap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            expectedOut,
            address(router),
            address(router),
            _buildSwapCalldata(amountToSwap)
        );
        vm.stopPrank();

        assertEq(tokenOut.balanceOf(alice), expectedOut);
        assertEq(tokenIn.balanceOf(feeWallet), fee);
    }

    function test_executeSwap_sameToken_reverts() public {
        vm.startPrank(alice);
        tokenIn.approve(address(proxy), 1000e18);
        vm.expectRevert("Same token");
        proxy.executeSwap(
            address(tokenIn),
            address(tokenIn), // same token
            1000e18,
            0,
            address(router),
            address(router),
            ""
        );
        vm.stopPrank();
    }

    function test_executeSwap_zeroAmount_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert("Invalid amount");
        proxy.executeSwap(address(tokenIn), address(tokenOut), 0, 0, address(router), address(router), "");
        vm.stopPrank();
    }

    function test_executeSwap_zeroSpender_reverts() public {
        vm.startPrank(alice);
        tokenIn.approve(address(proxy), 1000e18);
        vm.expectRevert("Invalid spender");
        proxy.executeSwap(address(tokenIn), address(tokenOut), 1000e18, 0, address(0), address(router), "");
        vm.stopPrank();
    }

    function test_executeSwap_zeroTarget_reverts() public {
        vm.startPrank(alice);
        tokenIn.approve(address(proxy), 1000e18);
        vm.expectRevert("Invalid target");
        proxy.executeSwap(address(tokenIn), address(tokenOut), 1000e18, 0, address(router), address(0), "");
        vm.stopPrank();
    }

    function test_executeSwap_insufficientOutput_reverts() public {
        uint256 amountIn = 1000e18;
        router.setOutputAmount(100e18); // only 100 out
        uint256 fee = (amountIn * proxy.feeBps()) / 10_000;
        uint256 amountToSwap = amountIn - fee;

        vm.startPrank(alice);
        tokenIn.approve(address(proxy), amountIn);
        vm.expectRevert("Insufficient output amount");
        proxy.executeSwap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            500e18, // expect 500 but only get 100
            address(router),
            address(router),
            _buildSwapCalldata(amountToSwap)
        );
        vm.stopPrank();
    }

    function test_executeSwap_routerFails_reverts() public {
        vm.startPrank(alice);
        tokenIn.approve(address(proxy), 1000e18);
        vm.expectRevert("Swap failed");
        proxy.executeSwap(
            address(tokenIn),
            address(tokenOut),
            1000e18,
            0,
            address(failRouter),
            address(failRouter),
            abi.encodeWithSelector(FailingSwapRouter.swap.selector, address(0), address(0), 0, address(0))
        );
        vm.stopPrank();
    }

    function test_executeSwap_feeCalculation() public {
        uint256 amountIn  = 10_000e18;
        uint256 expectedFee = (amountIn * 30) / 10_000; // 0.3%
        router.setOutputAmount(1e18);

        uint256 amountToSwap = amountIn - expectedFee;

        vm.startPrank(alice);
        tokenIn.approve(address(proxy), amountIn);
        proxy.executeSwap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            1e18,
            address(router),
            address(router),
            _buildSwapCalldata(amountToSwap)
        );
        vm.stopPrank();

        assertEq(tokenIn.balanceOf(feeWallet), expectedFee);
    }

    function testFuzz_executeSwap_fee(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 1_000_000e18);
        router.setOutputAmount(1e18);
        tokenIn.mint(alice, amountIn);

        uint256 fee = (amountIn * proxy.feeBps()) / 10_000;
        uint256 amountToSwap = amountIn - fee;

        vm.startPrank(alice);
        tokenIn.approve(address(proxy), amountIn);
        proxy.executeSwap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            1e18,
            address(router),
            address(router),
            _buildSwapCalldata(amountToSwap)
        );
        vm.stopPrank();

        assertEq(tokenIn.balanceOf(feeWallet), fee);
    }

    // ── setFeeRecipient ───────────────────────────────────────────────────────

    function test_setFeeRecipient_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        proxy.setFeeRecipient(alice);
    }

    function test_setFeeRecipient_zeroAddress_reverts() public {
        vm.expectRevert("Invalid recipient");
        proxy.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_updatesValue() public {
        proxy.setFeeRecipient(alice);
        assertEq(proxy.feeRecipient(), alice);
    }

    // ── setFeeBps ─────────────────────────────────────────────────────────────

    function test_setFeeBps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        proxy.setFeeBps(50);
    }

    function test_setFeeBps_tooHigh_reverts() public {
        vm.expectRevert("Fee too high");
        proxy.setFeeBps(1001); // > 10%
    }

    function test_setFeeBps_maxAllowed() public {
        proxy.setFeeBps(1000); // 10% exact
        assertEq(proxy.feeBps(), 1000);
    }

    function test_setFeeBps_zero_noFee() public {
        proxy.setFeeBps(0);

        uint256 amountIn = 1000e18;
        router.setOutputAmount(500e18);

        vm.startPrank(alice);
        tokenIn.approve(address(proxy), amountIn);
        proxy.executeSwap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            500e18,
            address(router),
            address(router),
            _buildSwapCalldata(amountIn) // no fee deducted
        );
        vm.stopPrank();

        assertEq(tokenIn.balanceOf(feeWallet), 0); // no fee collected
    }

    // ── ownable2step ──────────────────────────────────────────────────────────

    function test_ownable2step_transferRequiresAccept() public {
        proxy.transferOwnership(alice);
        assertEq(proxy.owner(), address(this)); // still current owner

        vm.prank(alice);
        proxy.acceptOwnership();
        assertEq(proxy.owner(), alice);
    }

    function test_ownable2step_onlyPendingOwnerCanAccept() public {
        proxy.transferOwnership(alice);

        vm.prank(bob);
        vm.expectRevert();
        proxy.acceptOwnership();
    }
}
