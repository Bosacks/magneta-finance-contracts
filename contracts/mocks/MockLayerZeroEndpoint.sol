// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { MessagingParams, MessagingFee, MessagingReceipt, Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/**
 * @title MockLayerZeroEndpoint
 * @dev Minimal LayerZero V2 endpoint mock for unit/integration testing.
 *
 *      Implements only the three functions called by OApp:
 *        - setDelegate()  → called in OApp constructor
 *        - quote()        → called in OApp._quote
 *        - send()         → called in OApp._lzSend
 *
 *      Also exposes deliverMessage() so tests can simulate cross-chain
 *      message delivery without a real relayer.
 */
contract MockLayerZeroEndpoint {
    uint32 private immutable _eid;
    uint64 private _nonce;

    /// Fixed native fee returned by quote(). Tests must send at least this value.
    uint256 public constant QUOTE_NATIVE_FEE = 0.001 ether;

    event MessageSent(uint32 indexed dstEid, bytes32 guid, bytes payload);

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    // ─── Functions called by OApp ─────────────────────────────────────────────

    function eid() external view returns (uint32) {
        return _eid;
    }

    /// @dev Called by OApp constructor to register the delegate with the endpoint.
    function setDelegate(address) external {}

    /// @dev Called by OApp._quote to estimate messaging fees.
    function quote(
        MessagingParams calldata,
        address
    ) external pure returns (MessagingFee memory) {
        return MessagingFee({ nativeFee: QUOTE_NATIVE_FEE, lzTokenFee: 0 });
    }

    /// @dev Called by OApp._lzSend to transmit the cross-chain message.
    function send(
        MessagingParams calldata _params,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory) {
        _nonce++;
        bytes32 guid = keccak256(
            abi.encodePacked(block.chainid, _eid, _params.dstEid, _nonce)
        );

        emit MessageSent(_params.dstEid, guid, _params.message);

        // Refund any native value above the quoted fee
        if (msg.value > QUOTE_NATIVE_FEE && _refundAddress != address(0)) {
            (bool ok, ) = _refundAddress.call{value: msg.value - QUOTE_NATIVE_FEE}("");
            require(ok, "MockEndpoint: refund failed");
        }

        return MessagingReceipt({
            guid: guid,
            nonce: uint64(_nonce),
            fee: MessagingFee({ nativeFee: QUOTE_NATIVE_FEE, lzTokenFee: 0 })
        });
    }

    // ─── Test helper ──────────────────────────────────────────────────────────

    /**
     * @dev Simulate LayerZero message delivery to a destination OApp.
     *
     *      This contract (the endpoint) is msg.sender, satisfying:
     *        `require(address(endpoint) == msg.sender)` inside OApp.lzReceive().
     *
     *      The caller must ensure _origin.sender matches the peer registered
     *      on dstBridge for _origin.srcEid (via setPeer).
     */
    function deliverMessage(
        address dstBridge,
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload
    ) external {
        (bool success, bytes memory result) = dstBridge.call(
            abi.encodeWithSignature(
                "lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)",
                _origin,
                _guid,
                _payload,
                address(0),
                bytes("")
            )
        );
        if (!success) {
            if (result.length > 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert("MockEndpoint: delivery failed");
        }
    }
}
