// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.5.16;

// Force hardhat to compile UniswapV2Factory (which embeds Pair bytecode)
// into artifacts. Core package is solc 0.5.16 with optimizer runs=999999
// so the resulting Pair init code hash matches the canonical
// 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f
// hardcoded in UniswapV2Library.
import "@uniswap/v2-core/contracts/UniswapV2Factory.sol";
