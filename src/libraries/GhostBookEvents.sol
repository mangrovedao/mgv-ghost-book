// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Tick} from "@mgv/lib/core/TickLib.sol";

/// @title GhostBookEvents Library
/// @notice Events emitted by MangroveGhostBook to track market order execution
/// @dev Events are emitted at the start and completion of market orders
library GhostBookEvents {
  /// @notice Emitted when a market order starts execution
  /// @param taker The address of the account executing the market order
  /// @param olKeyHash Hash of the offer list key identifying the trading pair
  /// @param module Address of the module that executed the market order
  /// @param maxTick Maximum acceptable price
  /// @param fillVolume Volume of tokens to fill
  /// @param fillWants if true, the fillVolume is the amount of tokens the taker wants to buy
  /// @dev if false, the fillVolume is the amount of tokens the taker wants to sell
  event OrderStarted(
    address indexed taker, bytes32 indexed olKeyHash, address module, Tick maxTick, uint256 fillVolume, bool fillWants
  );

  /// @notice Emitted when a market order completes execution
  /// @param taker The address of the account that executed the market order
  /// @param olKeyHash Hash of the offer list key identifying the trading pair
  /// @param got Amount of outbound tokens received by the taker
  /// @param gave Amount of inbound tokens spent by the taker
  /// @param fee Total fees paid to Mangrove
  /// @param bounty Total bounty received from failed offers
  event OrderCompleted(
    address indexed taker, bytes32 indexed olKeyHash, uint256 got, uint256 gave, uint256 fee, uint256 bounty
  );
}
