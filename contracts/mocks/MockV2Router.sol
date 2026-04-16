// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Minimal LP receipt used by MockV2Router for addLiquidity/removeLiquidity.
contract MockLPToken is ERC20 {
    address public immutable minter;
    constructor(address _minter) ERC20("Mock LP", "MLP") { minter = _minter; }
    function mint(address to, uint256 amount) external { require(msg.sender == minter, "not minter"); _mint(to, amount); }
    function burn(address from, uint256 amount) external { require(msg.sender == minter, "not minter"); _burn(from, amount); }
}

/// Tiny stand-in for a Uniswap-V2-compatible router. Only the surface the
/// LPModule / SwapModule touches is implemented, with a single (token, WETH)
/// pair. Good enough for unit tests — not a real AMM.
contract MockV2Router {
    using SafeERC20 for IERC20;

    address public immutable override_WETH;
    MockLPToken public pair;
    address public pairToken;

    constructor(address _weth) { override_WETH = _weth; }

    function WETH() external view returns (address) { return override_WETH; }
    function factory() external view returns (address) { return address(this); }
    function getPair(address, address) external view returns (address) { return address(pair); }

    function _ensurePair(address token) internal {
        if (address(pair) == address(0)) {
            pair = new MockLPToken(address(this));
            pairToken = token;
        }
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint /*amountTokenMin*/,
        uint /*amountETHMin*/,
        address to,
        uint /*deadline*/
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        _ensurePair(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountTokenDesired);
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = amountTokenDesired + msg.value; // arbitrary formula for the mock
        pair.mint(to, liquidity);
    }

    function removeLiquidity(
        address token,
        address /*weth*/,
        uint liquidity,
        uint /*amountTokenMin*/,
        uint /*amountETHMin*/,
        address to,
        uint /*deadline*/
    ) external returns (uint amountToken, uint amountETH) {
        pair.burn(msg.sender, liquidity);
        amountToken = liquidity / 2;
        amountETH = liquidity / 2;
        IERC20(token).safeTransfer(to, amountToken);
        (bool ok, ) = to.call{value: amountETH}("");
        require(ok, "send failed");
    }

    function swapExactETHForTokens(
        uint /*amountOutMin*/,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external payable returns (uint[] memory amounts) {
        amounts = new uint[](path.length);
        amounts[0] = msg.value;
        amounts[path.length - 1] = msg.value; // 1:1 for tests
        IERC20(path[path.length - 1]).safeTransfer(to, msg.value);
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint /*amountOutMin*/,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external returns (uint[] memory amounts) {
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn; // 1:1
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).safeTransfer(to, amountIn);
    }

    receive() external payable {}
}
