// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GhostBookEvents Library
/// @notice Events emitted by GhostBook to track active order takers
/// @dev Since reentrancy is prevented, only one taker can be active at a time
library GhostBookEvents {
  /// @notice Emitted when a taker starts executing an order on Mangrove
  /// @param taker The address of the account executing the order
  event MangroveOrderStarted(address taker);

  /// @notice Emitted when the active taker completes their order execution
  event MangroveOrderCompleted();
}
