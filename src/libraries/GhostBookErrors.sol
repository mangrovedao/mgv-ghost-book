// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Tick} from "@mgv/lib/core/TickLib.sol";

/// @title GhostBookErrors - Error definitions for MangroveGhostBook
/// @notice Contains custom errors used throughout the MangroveGhostBook contract
library GhostBookErrors {
  /// @notice Thrown when a function restricted to the contract itself is called externally
  error OnlyThisContractCanCallThisFunction();

  /// @notice Thrown when a zero address is provided as a spender
  error AddressZeroSpender();

  /// @notice Thrown when the price (tick) inferred from swap amounts exceeds the maximum allowed
  /// @param inferredTick The tick calculated from the swap amounts
  /// @param maxTick The maximum tick that was allowed
  error InferredTickHigherThanMaxTick(Tick inferredTick, Tick maxTick);

  /// @notice Thrown when more tokens were spent than authorized
  /// @param gave The amount of tokens actually spent
  /// @param amountToSell The maximum amount that was authorized to spend
  error GaveMoreThanAmountToSell(uint256 gave, uint256 amountToSell);

  /// @notice Thrown when trying to use an external swap module that is not whitelisted
  error ModuleNotWhitelisted();
}
