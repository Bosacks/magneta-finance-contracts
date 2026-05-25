// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockReceiverLP is ERC20 {
    address public immutable minter;
    constructor(address _minter) ERC20("Mock LP", "MLP") { minter = _minter; }
    function mint(address to, uint256 amount) external { require(msg.sender == minter, "not minter"); _mint(to, amount); }
}

/**
 * @dev Configurable V2-router stand-in for MagnetaXChainLpReceiver tests.
 *      Unlike MockV2Router (always 1:1, always full consumption), this lets a
 *      test dial in swap output and partial liquidity consumption so the
 *      receiver's dust-refund and donation-safety paths can be exercised.
 *
 *      - swapExactETHForTokens: pays out `swapOutPerEthBps`% of the native sent,
 *        in pre-funded `token`, to `to`. Must be funded with token first.
 *      - addLiquidityETH: consumes `tokenConsumeBps`% of amountTokenDesired and
 *        `ethConsumeBps`% of msg.value; pulls only the consumed token, refunds
 *        the unused ETH to msg.sender (mirroring real addLiquidityETH), mints LP
 *        to `to`. Leftover token stays with the caller as dust.
 */
contract MockLpReceiverRouter {
    using SafeERC20 for IERC20;

    address public immutable wethAddr;
    MockReceiverLP public lp;

    uint256 public swapOutPerEthBps = 10_000; // 1:1
    uint256 public tokenConsumeBps  = 10_000; // consume all
    uint256 public ethConsumeBps    = 10_000; // consume all

    constructor(address _weth) {
        wethAddr = _weth;
        lp = new MockReceiverLP(address(this));
    }

    function WETH() external view returns (address) { return wethAddr; }

    function setSwapOutPerEthBps(uint256 v) external { swapOutPerEthBps = v; }
    function setTokenConsumeBps(uint256 v) external { tokenConsumeBps = v; }
    function setEthConsumeBps(uint256 v) external { ethConsumeBps = v; }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /*deadline*/
    ) external payable returns (uint256[] memory amounts) {
        uint256 out = (msg.value * swapOutPerEthBps) / 10_000;
        require(out >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT");
        amounts = new uint256[](path.length);
        amounts[0] = msg.value;
        amounts[path.length - 1] = out;
        IERC20(path[path.length - 1]).safeTransfer(to, out);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 /*deadline*/
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        amountToken = (amountTokenDesired * tokenConsumeBps) / 10_000;
        amountETH = (msg.value * ethConsumeBps) / 10_000;
        require(amountToken >= amountTokenMin, "MockRouter: INSUFFICIENT_TOKEN");
        require(amountETH >= amountETHMin, "MockRouter: INSUFFICIENT_ETH");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);

        uint256 ethRefund = msg.value - amountETH;
        if (ethRefund > 0) {
            (bool ok, ) = msg.sender.call{value: ethRefund}("");
            require(ok, "MockRouter: ETH refund failed");
        }

        liquidity = amountToken + amountETH;
        lp.mint(to, liquidity);
    }

    receive() external payable {}
}
