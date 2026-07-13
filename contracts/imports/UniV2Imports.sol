// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.6.6;

// Force hardhat to compile WETH9 (periphery, 0.6.6) into artifacts.
// Router02 lives in contracts/uniswap/MagnetaV2Router02.sol (vendored fork
// with patched init code hash). Core (Factory/Pair) imported separately.
import "@uniswap/v2-periphery/contracts/test/WETH9.sol";
