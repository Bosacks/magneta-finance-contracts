// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { ERC20 }          from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable }  from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title MagnetaCurveToken
 * @notice ERC20 token deployed by `MagnetaCurveFactory` for the bonding curve
 *         launchpad. The full supply is minted at construction to the curve
 *         pool (passed as `initialHolder`). Trading happens exclusively on the
 *         curve until graduation, at which point the pool itself moves the
 *         remaining inventory + accumulated native to a Uniswap-V2 pair.
 *
 *         Kept deliberately minimal: no taxes, no blacklist, no auto-freeze,
 *         no operator role. The whole point of the curve launchpad is "fair
 *         launch with no founder controls", so adding back those features
 *         would defeat the purpose. If a creator wants the full Magneta
 *         feature set, they pay for `MagnetaERC20OFT` instead.
 *
 *         Cross-chain bridging is V1.5 — ships as an OFT adapter wrapper
 *         that locks this token on the launch chain and mints a wrapped
 *         OFT representation on remote chains. Until then a curve token
 *         lives on the chain where it was launched.
 */
contract MagnetaCurveToken is ERC20, ERC20Burnable {
    /// @notice Off-chain metadata pointer (image, description, social links).
    string private _tokenURI;

    /// @notice The curve creator (informational — no admin powers attached).
    address public immutable creator;

    event MetadataSet(string uri);

    /**
     * @param name_         ERC20 name
     * @param symbol_       ERC20 symbol
     * @param uri_          Off-chain metadata URI (IPFS / Arweave / https)
     * @param totalSupply_  Full supply, all minted to `initialHolder`
     * @param initialHolder Address that receives 100% of the supply (the
     *                      curve pool — set by the factory)
     * @param creator_      The wallet that paid for the token creation; the
     *                      factory passes `msg.sender` here. Stored for UI
     *                      attribution only.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        uint256 totalSupply_,
        address initialHolder,
        address creator_
    ) ERC20(name_, symbol_) {
        require(initialHolder != address(0), "zero holder");
        require(totalSupply_ > 0,             "zero supply");
        require(creator_ != address(0),        "zero creator");

        _tokenURI = uri_;
        creator   = creator_;
        _mint(initialHolder, totalSupply_);
        emit MetadataSet(uri_);
    }

    /// @notice Off-chain metadata URI.
    function tokenURI() external view returns (string memory) {
        return _tokenURI;
    }
}
