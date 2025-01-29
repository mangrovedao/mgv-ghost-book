// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMangrove} from "@mgv/src/IMangrove.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {IExternalSwapModule} from "./interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "./libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

/// @title ModuleData - Data structure for external swap module information
/// @notice Holds the necessary data to interact with an external swap module
struct ModuleData {
  /// @notice The module that handles swapping
  IExternalSwapModule module;
  /// @notice Additional data required for swapping (e.g., pool addresses, routing paths)
  bytes data;
}

/// @title MangroveGhostBook - A contract that enables atomic swaps between Mangrove and external liquidity pools
/// @notice This contract allows users to execute trades by sourcing liquidity from both Mangrove and external pools
/// @dev Inherits ReentrancyGuard to prevent reentrancy attacks and Ownable for privileged operations
contract MangroveGhostBook is ReentrancyGuard, Ownable {
  using SafeERC20 for IERC20;

  /// @notice The Mangrove contract instance
  IMangrove public immutable MGV;

  /// @notice Mapping to track which external swap modules are whitelisted
  /// @dev Only whitelisted modules can be used for external swaps
  /// @return bool True if the module is whitelisted, false otherwise
  mapping(IExternalSwapModule => bool) public whitelistedModules;

  /// @notice Initializes the contract with Mangrove address
  /// @param _mgv The address of the Mangrove contract
  /// @dev Sets up Ownable with msg.sender as owner and stores Mangrove instance
  constructor(address _mgv) Ownable(msg.sender) {
    MGV = IMangrove(payable(_mgv));
  }

  /// @notice Public interface for executing a market order with a maximum tick price
  /// @param olKey The offer list key containing token pair and tick spacing
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param amountToSell Amount of input tokens to sell
  /// @param moduleData External swap module information
  /// @return takerGot Amount of output tokens received
  /// @return takerGave Amount of input tokens spent
  /// @return bounty Bounty received from failed offers
  /// @return feePaid Fees paid to Mangrove
  function marketOrderByTick(OLKey memory olKey, Tick maxTick, uint256 amountToSell, ModuleData calldata moduleData)
    public
    returns (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid)
  {
    return generalMarketOrder(olKey, maxTick, amountToSell, msg.sender, moduleData);
  }

  /// @notice Allows owner to rescue stuck tokens
  /// @param token Token address to rescue
  /// @param to Recipient address
  /// @param amount Amount to rescue
  function rescueFunds(address token, address to, uint256 amount) external onlyOwner {
    IERC20(token).safeTransfer(to, amount);
  }

  function whitelistModule(address _module) external onlyOwner {
    whitelistedModules[IExternalSwapModule(_module)] = true;
  }

  /// @notice Determines the maximum tick price for external swap based on Mangrove's best offer
  /// @dev If no offers exist on Mangrove, uses the provided maxTick. Otherwise uses the lower of maxTick and best offer's tick
  /// @param olKey The offer list key
  /// @param maxTick User's maximum acceptable tick
  /// @return externalMaxTick The tick price limit for external swap
  function _getExternalSwapTick(OLKey memory olKey, Tick maxTick) internal view returns (Tick externalMaxTick) {
    uint256 bestOfferId = MGV.best(olKey);

    if (bestOfferId == 0) {
      externalMaxTick = maxTick;
    } else {
      Tick offerTick = MGV.offers(olKey, bestOfferId).tick();
      externalMaxTick = Tick.unwrap(offerTick) < Tick.unwrap(maxTick) ? offerTick : maxTick;
    }
  }

  /// @notice Executes swap through external module and verifies results
  /// @dev Uses before/after balance comparison to determine actual amounts swapped
  /// @param olKey The offer list key
  /// @param amountToSell Maximum amount to sell
  /// @param maxTick Maximum acceptable price
  /// @param moduleData External swap module information
  /// @return gave Amount of input tokens spent
  /// @return got Amount of output tokens received
  function _executeExternalSwapModule(
    OLKey memory olKey,
    uint256 amountToSell,
    Tick maxTick,
    ModuleData calldata moduleData,
    address taker
  ) internal returns (uint256 gave, uint256 got) {
    // Store initial balances to compare after swap
    gave = IERC20(olKey.inbound_tkn).balanceOf(address(this)) + amountToSell;
    got = IERC20(olKey.outbound_tkn).balanceOf(address(this));

    // Transfer tokens to the module to be swapped
    IERC20(olKey.inbound_tkn).safeTransferFrom(taker, address(moduleData.module), amountToSell);

    moduleData.module.externalSwap(olKey, amountToSell, maxTick, moduleData.data);

    // Calculate actual amounts from balance differences
    gave = gave - IERC20(olKey.inbound_tkn).balanceOf(address(this));
    got = IERC20(olKey.outbound_tkn).balanceOf(address(this)) - got;

    // Verify price is within limits
    Tick inferredTick = TickLib.tickFromVolumes(gave, got);
    if (Tick.unwrap(inferredTick) > Tick.unwrap(maxTick)) {
      revert GhostBookErrors.InferredTickHigherThanMaxTick(inferredTick, maxTick);
    }
  }

  /// @notice Executes swap through external liquidity pool
  /// @dev Only callable by this contract to prevent unauthorized external swaps
  /// @param olKey The offer list key
  /// @param amountToSell Amount to sell
  /// @param maxTick Maximum acceptable price
  /// @param moduleData External swap module information
  /// @return gave Amount spent
  /// @return got Amount received
  function externalSwap(
    OLKey memory olKey,
    uint256 amountToSell,
    Tick maxTick,
    ModuleData calldata moduleData,
    address taker
  ) public returns (uint256 gave, uint256 got) {
    if (msg.sender != address(this)) revert GhostBookErrors.OnlyThisContractCanCallThisFunction();
    if (!whitelistedModules[moduleData.module]) revert GhostBookErrors.ModuleNotWhitelisted();

    Tick externalMaxTick = _getExternalSwapTick(olKey, maxTick);
    (gave, got) = _executeExternalSwapModule(olKey, amountToSell, externalMaxTick, moduleData, taker);
  }

  /// @notice Core market order function that combines external and Mangrove liquidity
  /// @dev Uses try-catch pattern to handle potential external swap failures gracefully
  /// @param olKey The offer list key
  /// @param maxTick Maximum acceptable price
  /// @param amountToSell Amount to sell
  /// @param taker Address receiving the swap results
  /// @param moduleData External swap module information
  /// @return takerGot Total amount received
  /// @return takerGave Total amount spent
  /// @return bounty Bounty from failed offers
  /// @return feePaid Fees paid to Mangrove
  function generalMarketOrder(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amountToSell,
    address taker,
    ModuleData calldata moduleData
  ) internal nonReentrant returns (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) {
    // Try external swap first, continue if it fails

    try MangroveGhostBook(payable(address(this))).externalSwap(olKey, amountToSell, maxTick, moduleData, taker)
    returns (uint256 gave, uint256 got) {
      takerGot = got;
      takerGave = gave;
    } catch {
      // Transfer tokens from taker since they are not transferred during the external swap
      IERC20(olKey.inbound_tkn).safeTransferFrom(taker, address(this), amountToSell);
    }

    IERC20(olKey.inbound_tkn).forceApprove(address(moduleData.module), 0);

    // If external swap didn't use full amount, try Mangrove
    if (takerGave < amountToSell) {
      uint256 takerGotFromMgv;
      uint256 takerGaveToMgv;
      // Force approval to MGV
      IERC20(olKey.inbound_tkn).forceApprove(address(MGV), amountToSell - takerGave);

      (takerGotFromMgv, takerGaveToMgv, bounty, feePaid) =
        MGV.marketOrderByTick(olKey, maxTick, amountToSell - takerGave, false);

      IERC20(olKey.inbound_tkn).forceApprove(address(MGV), 0);
      takerGot += takerGotFromMgv;
      takerGave += takerGaveToMgv;
    }

    // Return unused tokens and results to taker
    uint256 inboundToReturn = amountToSell - takerGave;
    if (inboundToReturn > 0) IERC20(olKey.inbound_tkn).safeTransfer(taker, inboundToReturn);
    if (takerGot > 0) IERC20(olKey.outbound_tkn).safeTransfer(taker, takerGot);

    if (bounty > 0) payable(taker).transfer(bounty);
  }

  receive() external payable {}
}
