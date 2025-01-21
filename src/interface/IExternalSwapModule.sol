// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Tick} from "@mgv/lib/core/TickLib.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";

/// @title External Swap Module Interface
/// @notice Interface for modules that enable swapping tokens through external liquidity pools
interface IExternalSwapModule {
  /// @notice Executes a swap through an external liquidity pool
  /// @param olKey The offer list key containing outbound_tkn, inbound_tkn and tickSpacing
  /// @param amountToSell The amount of input tokens to sell. The module has already received this amount of inbound tokens before the call
  /// @param maxTick The maximum price (as a tick) willing to pay for the swap. The ratio of used inbound tokens to received outbound tokens must result in a tick less than or equal to maxTick
  /// @param data Additional data required for the swap - could be routing paths, proofs for RFQ order matching, or any other protocol-specific data
  /// @dev At the end of this call, the caller expects:
  /// @dev - Any unused inbound tokens to be returned
  /// @dev - All outbound tokens from the swap to be transferred
  /// @dev - The effective swap price (used inbound / received outbound) to be within maxTick, otherwise it will revert
  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, bytes memory data)
    external;
}
