// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MagnetaERC20Permit
/// @notice Compact EIP-2612 (`permit`) for MagnetaERC20OFT.
///
/// @dev Why not `@openzeppelin/contracts/.../ERC20Permit.sol`?
///
///      Purely a bytecode-budget decision, not a disagreement with OZ. The
///      token's creation code is carried whole inside MagnetaOFTTokenDeployer,
///      whose own deployed size is therefore capped by EIP-170. OZ's
///      ERC20Permit pulls in EIP712 -> ShortStrings -> Strings -> Bytes to
///      support runtime-length domain names, costing 1619 bytes and leaving the
///      deployer 550 bytes OVER the 24576 limit. This version stores the name
///      hash directly and drops that dependency chain.
///
///      The scheme itself is unchanged from OZ's: same typehashes, same digest
///      construction, same domain, same malleability rejection. The
///      MagnetaERC20Permit test suite checks signatures produced by an
///      independent implementation (ethers' signTypedData) rather than by this
///      contract's own logic, so a mistake here cannot validate itself.
abstract contract MagnetaERC20Permit is ERC20 {
    /// keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 private constant _PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    /// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant _DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    /// keccak256("1") — the EIP712 domain `version` field.
    bytes32 private constant _HASHED_VERSION =
        0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    bytes32 private immutable _hashedName;
    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;
    address private immutable _cachedThis;

    /// @notice EIP-2612 nonce, incremented on every successful `permit`.
    mapping(address => uint256) public nonces;

    error PermitExpired();
    error InvalidSigner();

    constructor(string memory name_) {
        _hashedName = keccak256(bytes(name_));
        _cachedChainId = block.chainid;
        _cachedThis = address(this);
        _cachedDomainSeparator = _buildDomainSeparator(keccak256(bytes(name_)));
    }

    function _buildDomainSeparator(bytes32 hashedName_) private view returns (bytes32) {
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, hashedName_, _HASHED_VERSION, block.chainid, address(this))
        );
    }

    /// @notice EIP-712 domain separator.
    /// @dev Recomputed rather than read from cache after a chain fork or a
    ///      redeploy at a different address, so signatures can never be
    ///      replayed across chains.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _cachedChainId && address(this) == _cachedThis) {
            return _cachedDomainSeparator;
        }
        return _buildDomainSeparator(_hashedName);
    }

    /// @notice Approve `spender` for `value` from a signature instead of a
    ///         transaction, so an approve + action flow becomes one on-chain
    ///         call.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        if (block.timestamp > deadline) revert PermitExpired();

        bytes32 structHash = keccak256(
            abi.encode(_PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        // Reject the upper half of the curve order and v outside {27,28}:
        // ecrecover accepts both malleable forms, which would let a third
        // party rebroadcast a variant of a pending permit. The nonce makes
        // replay harmless, but rejecting keeps signature equality meaningful
        // for anything indexing these calls.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSigner();
        }
        if (v != 27 && v != 28) revert InvalidSigner();

        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != owner) revert InvalidSigner();

        _approve(owner, spender, value);
    }
}
