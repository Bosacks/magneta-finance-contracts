// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IModule.sol";

/// @dev Minimal IModule for MagnetaGateway value-op tests. On execute it pulls a
///      caller-encoded `amount` of `token` from `ctx.tokenSource` (the gateway,
///      which has forceApprove'd this module) and forwards it to `caller`,
///      exactly mirroring how a real module consumes bridged CCTP funds. This
///      lets the F38 per-op fulfillment test prove that fulfilling one op drains
///      the gateway balance and blocks double-spend of a second pending op.
contract MockValueOpModule is IModule {
    event Pulled(address indexed token, uint256 amount, address indexed to);

    function execute(Context calldata ctx, bytes calldata params)
        external
        payable
        override
        returns (bytes memory result)
    {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));
        if (amount > 0) {
            IERC20(token).transferFrom(ctx.tokenSource, ctx.caller, amount);
            emit Pulled(token, amount, ctx.caller);
        }
        return abi.encode(amount);
    }
}
