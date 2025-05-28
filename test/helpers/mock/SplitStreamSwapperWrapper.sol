// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {SplitStreamSwapper} from "../../../src/modules/SplitStreamSwapper.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A wrapper around SplitStreamSwapper for testing purposes
contract SplitStreamSwapperWrapper is SplitStreamSwapper {
  using SafeERC20 for IERC20;

  constructor(address _ghostBook) SplitStreamSwapper(_ghostBook) {}

  /// @notice Allow the test contract to receive tokens
  function transferToken(address token, address to, uint256 amount) external {
    IERC20(token).safeTransfer(to, amount);
  }
}
