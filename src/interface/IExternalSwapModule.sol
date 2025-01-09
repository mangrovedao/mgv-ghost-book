// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Tick} from "@mgv/lib/core/TickLib.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";

/// @title External Swap Module Interface
/// @notice Interface for modules that enable swapping tokens through external liquidity pools
interface IExternalSwapModule {
  /// @notice Executes a swap through an external liquidity pool
  /// @param olKey The offer list key containing outbound_tkn, inbound_tkn and tickSpacing
  /// @param amountToSell The amount of input tokens to sell
  /// @param maxTick The maximum price (as a tick) willing to pay for the swap
  /// @param pool The address of the external liquidity pool to use
  /// @param data Additional data required for the swap - could be routing paths, proofs for RFQ order matching, or any other protocol-specific data
  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, address pool, bytes memory data)
    external;

  /// @notice Gets the address that needs token approval for a given pool
  /// @param pool The address of the external liquidity pool
  /// @return The address that needs to be approved to spend tokens
  /// @dev For uniswap v3 pools, it could be the router address
  function spenderFor(address pool) external view returns (address);
}
