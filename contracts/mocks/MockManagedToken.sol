// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// Mirror of the surface TokenOpsModule expects from a Magneta-managed token:
/// an ERC20 whose owner is the module and which exposes mint/blacklist/meta +
/// three one-way revoke flags. Enough for unit tests; no transfer taxes.
contract MockManagedToken is ERC20, Ownable {
    string public tokenURI;
    mapping(address => bool) public frozen;
    bool public revokedUpdate;
    bool public revokedFreeze;
    bool public revokedMint;

    event MetadataUpdated(string uri);
    event Blacklisted(address indexed account, bool value);
    event RevokeEnabled(string kind);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external onlyOwner {
        require(!revokedMint, "mint revoked");
        _mint(to, amount);
    }

    function updateMetadata(string memory newURI) external onlyOwner {
        require(!revokedUpdate, "update revoked");
        tokenURI = newURI;
        emit MetadataUpdated(newURI);
    }

    function blacklist(address account, bool value) external onlyOwner {
        require(!revokedFreeze, "freeze revoked");
        frozen[account] = value;
        emit Blacklisted(account, value);
    }

    function enableRevokeUpdate() external onlyOwner { revokedUpdate = true; emit RevokeEnabled("UPDATE"); }
    function enableRevokeFreeze() external onlyOwner { revokedFreeze = true; emit RevokeEnabled("FREEZE"); }
    function enableRevokeMint()   external onlyOwner { revokedMint   = true; emit RevokeEnabled("MINT"); }
}
