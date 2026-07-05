// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MockV2Router.sol"; // reuse MockLPToken

/// @notice Shared UniV2-style router+factory mock for the "renamed native
///         entrypoint" adapters (DragonSwapSeiAdapter, MoeRouterAdapter,
///         TraderJoeAvaxAdapter) and the plain-UniV2 surface used by
///         UbeswapCeloAdapter. Each fork only renames the native-token
///         functions (SEI / Native / AVAX); this mock implements all three
///         naming schemes against one shared internal implementation so a
///         single deployment can back any of the four adapters under test.
///
///         Not a real AMM — configurable swap rate + partial-fill knobs
///         exist purely to exercise adapter revert paths (slippage) and
///         dust-refund plumbing.
contract MockUniV2NativeRouter {
    using SafeERC20 for IERC20;

    address public immutable weth;

    /// @notice output = input * rateNum / rateDen for all swap directions.
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;

    /// @notice If > 0, addLiquidity{SEI,Native,AVAX} only "uses" up to this much
    ///         native value (rest is refunded to caller), simulating a partial-fill.
    uint256 public nativeCap;

    /// @notice If > 0, the plain (token/token) addLiquidity only "uses" up to this
    ///         much of amountBDesired (rest is refunded as tokenB to the caller).
    ///         Lets UbeswapCeloAdapter's addLiquidityETH (which forwards CELO as a
    ///         plain ERC20 "tokenB") exercise its dust-refund path.
    uint256 public amountBCap;

    /// @notice When true, factory() returns address(0) (constructor "bad router" test).
    bool public zeroFactory;

    MockLPToken public pair;
    bool private _pairInit;

    constructor(address _weth) {
        weth = _weth;
    }

    // ─── test knobs ───────────────────────────────────────────────────────

    function setRate(uint256 _num, uint256 _den) external {
        rateNum = _num;
        rateDen = _den;
    }

    function setNativeCap(uint256 _cap) external {
        nativeCap = _cap;
    }

    function setAmountBCap(uint256 _cap) external {
        amountBCap = _cap;
    }

    function setZeroFactory(bool _zero) external {
        zeroFactory = _zero;
    }

    // ─── UniV2 surface ────────────────────────────────────────────────────

    function factory() external view returns (address) {
        return zeroFactory ? address(0) : address(this);
    }

    function WSEI() external view returns (address) { return weth; }
    function wNative() external view returns (address) { return weth; }
    function WAVAX() external view returns (address) { return weth; }

    function getPair(address, address) external view returns (address) {
        return address(pair);
    }

    function _ensurePair() internal {
        if (!_pairInit) {
            pair = new MockLPToken(address(this));
            _pairInit = true;
        }
    }

    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(deadline >= block.timestamp, "MockRouter: expired");
        _ensurePair();
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountBDesired);
        amountA = amountADesired;
        amountB = (amountBCap > 0 && amountBCap < amountBDesired) ? amountBCap : amountBDesired;
        require(amountA >= amountAMin && amountB >= amountBMin, "MockRouter: slippage");
        liquidity = amountA + amountB;
        pair.mint(to, liquidity);
        if (amountBDesired > amountB) {
            IERC20(tokenB).safeTransfer(msg.sender, amountBDesired - amountB);
        }
    }

    function _addLiquidityNative(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountNativeMin,
        address to, uint256 deadline
    ) internal returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        require(deadline >= block.timestamp, "MockRouter: expired");
        _ensurePair();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountTokenDesired);
        amountToken = amountTokenDesired;
        amountNative = (nativeCap > 0 && nativeCap < msg.value) ? nativeCap : msg.value;
        require(amountToken >= amountTokenMin && amountNative >= amountNativeMin, "MockRouter: slippage");
        liquidity = amountToken + amountNative;
        pair.mint(to, liquidity);

        // Real UniV2Router02 behaviour: refund any unused native value to the
        // immediate caller (the adapter), which then relays its own refund to
        // the end user.
        if (msg.value > amountNative) {
            (bool ok, ) = msg.sender.call{value: msg.value - amountNative}("");
            require(ok, "MockRouter: native refund failed");
        }
    }

    function addLiquiditySEI(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountSEIMin,
        address to, uint256 deadline
    ) external payable returns (uint256, uint256, uint256) {
        return _addLiquidityNative(token, amountTokenDesired, amountTokenMin, amountSEIMin, to, deadline);
    }

    function addLiquidityNative(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountNativeMin,
        address to, uint256 deadline
    ) external payable returns (uint256, uint256, uint256) {
        return _addLiquidityNative(token, amountTokenDesired, amountTokenMin, amountNativeMin, to, deadline);
    }

    function addLiquidityAVAX(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountAVAXMin,
        address to, uint256 deadline
    ) external payable returns (uint256, uint256, uint256) {
        return _addLiquidityNative(token, amountTokenDesired, amountTokenMin, amountAVAXMin, to, deadline);
    }

    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB) {
        require(deadline >= block.timestamp, "MockRouter: expired");
        pair.burn(msg.sender, liquidity);
        amountA = liquidity / 2;
        amountB = liquidity / 2;
        require(amountA >= amountAMin && amountB >= amountBMin, "MockRouter: slippage");
        IERC20(tokenA).safeTransfer(to, amountA);
        IERC20(tokenB).safeTransfer(to, amountB);
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "MockRouter: expired");
        uint256 amountOut = amountIn * rateNum / rateDen;
        require(amountOut >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
    }

    function _swapExactNativeForTokens(
        uint256 amountOutMin, address[] calldata path, address to
    ) internal returns (uint256[] memory amounts) {
        uint256 amountOut = msg.value * rateNum / rateDen;
        require(amountOut >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);
        amounts = new uint256[](path.length);
        amounts[0] = msg.value;
        amounts[path.length - 1] = amountOut;
    }

    function swapExactSEIForTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 /*deadline*/
    ) external payable returns (uint256[] memory amounts) {
        return _swapExactNativeForTokens(amountOutMin, path, to);
    }

    function swapExactNativeForTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 /*deadline*/
    ) external payable returns (uint256[] memory amounts) {
        return _swapExactNativeForTokens(amountOutMin, path, to);
    }

    function swapExactAVAXForTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 /*deadline*/
    ) external payable returns (uint256[] memory amounts) {
        return _swapExactNativeForTokens(amountOutMin, path, to);
    }

    function _swapExactTokensForNative(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to
    ) internal returns (uint256[] memory amounts) {
        uint256 amountOut = amountIn * rateNum / rateDen;
        require(amountOut >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        (bool ok, ) = to.call{value: amountOut}("");
        require(ok, "MockRouter: native send failed");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
    }

    function swapExactTokensForSEI(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        return _swapExactTokensForNative(amountIn, amountOutMin, path, to);
    }

    function swapExactTokensForNative(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        return _swapExactTokensForNative(amountIn, amountOutMin, path, to);
    }

    function swapExactTokensForAVAX(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        return _swapExactTokensForNative(amountIn, amountOutMin, path, to);
    }

    /// @dev funds the router with native so swapExactTokensFor{SEI,Native,AVAX} can pay out.
    receive() external payable {}
}
