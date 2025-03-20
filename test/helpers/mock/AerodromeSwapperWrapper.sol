// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {AerodromeSwapper} from "../../../src/modules/AerodromeSwapper.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A wrapper around AerodromeSwapper for testing purposes
contract AerodromeSwapperWrapper is AerodromeSwapper {
  using SafeERC20 for IERC20;

  constructor(address _ghostBook, address _router) AerodromeSwapper(_ghostBook, _router) {}

  // /// @notice Expose the internal function for testing
  // function calculateMinimumAmountOut(OLKey memory olKey, uint256 amountIn, Tick maxTick)
  //   external
  //   pure
  //   returns (uint256)
  // {
  //   return _calculateMinimumAmountOut(olKey, amountIn, maxTick);
  // }

  /// @notice Allow the test contract to receive tokens
  function transferToken(address token, address to, uint256 amount) external {
    IERC20(token).safeTransfer(to, amount);
  }
}
