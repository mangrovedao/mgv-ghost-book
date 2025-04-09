// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveGhostBook, ModuleData} from "../MangroveGhostBook.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {GhostBookEvents} from "../libraries/GhostBookEvents.sol";

/// @title MultiModuleData - Extension of module data for multi-module routing
/// @notice Structure to define multiple modules and their respective swap percentages
struct MultiModuleData {
  /// @notice Array of modules to use for the swap
  ModuleData[] modules;
  /// @notice Percentages of the total amount to route through each module (in basis points, 100 = 1%)
  uint16[] percentages;
}

/// @title OrderResults - Struct for storing the results of order execution
/// @notice Used to avoid stack too deep errors by grouping related values
struct OrderResults {
  uint256[] amountsGot;
  uint256[] amountsGave;
  address[] moduleAddresses;
  uint256 takerGot;
  uint256 takerGave;
  uint256 bounty;
  uint256 feePaid;
  uint256 unusedAmount;
}

/// @title MultiModuleGhostBook - GhostBook extension that routes swaps through multiple external modules
/// @notice Extends MangroveGhostBook to provide multi-module routing capabilities
/// @dev All modules must be whitelisted in the parent contract
contract MultiModuleGhostBook is MangroveGhostBook {
  using SafeERC20 for IERC20;

  /// @notice Maximum basis points (100%)
  uint16 public constant MAX_BPS = 10000;

  /// @notice Emitted when a multi-module order is executed
  event MultiModuleOrderExecuted(
    address indexed taker,
    bytes32 indexed olKeyHash,
    address[] modules,
    uint16[] percentages,
    uint256[] amountsGot,
    uint256[] amountsGave
  );

  /// @notice Constructor inherits from MangroveGhostBook
  /// @param _mgv The address of the Mangrove contract
  constructor(address _mgv) MangroveGhostBook(_mgv) {}

  /// @notice Error thrown when module percentages don't add up to 100%
  error InvalidPercentages();

  /// @notice Error thrown when modules and percentages arrays have different lengths
  error ArrayLengthMismatch();

  /// @notice Error thrown when empty module array is provided
  error EmptyModuleArray();

  /// @notice Public interface for executing a market order with multiple modules
  /// @param olKey The offer list key containing token pair and tick spacing
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param amountToSell Amount of input tokens to sell
  /// @param multiModuleData Data structure containing multiple modules and their allocation percentages
  /// @return takerGot Total amount of output tokens received
  /// @return takerGave Total amount of input tokens spent
  /// @return bounty Bounty received from failed offers
  /// @return feePaid Fees paid to Mangrove
  function marketOrderByTickMultiModule(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amountToSell,
    MultiModuleData calldata multiModuleData
  ) public nonReentrant returns (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) {
    // Validate multi-module data
    _validateMultiModuleData(multiModuleData);

    // Start order execution
    emit GhostBookEvents.OrderStarted(
      msg.sender,
      olKey.hash(),
      address(0), // No single module
      maxTick,
      amountToSell,
      false
    );

    // Transfer tokens from taker to this contract
    IERC20(olKey.inbound_tkn).safeTransferFrom(msg.sender, address(this), amountToSell);

    // Create struct to store all results and avoid stack too deep errors
    OrderResults memory results = _createOrderResults(multiModuleData.modules.length);

    // Execute the order and populate results
    _executeOrder(olKey, maxTick, amountToSell, multiModuleData, results);

    // Return unused tokens and results to taker
    _returnTokensToTaker(
      olKey.inbound_tkn, olKey.outbound_tkn, amountToSell, results.takerGot, results.takerGave, results.bounty
    );

    // Emit events for order completion
    _emitOrderEvents(
      olKey.hash(),
      results.moduleAddresses,
      multiModuleData.percentages,
      results.amountsGot,
      results.amountsGave,
      results.takerGot,
      results.takerGave,
      results.bounty,
      results.feePaid
    );

    return (results.takerGot, results.takerGave, results.bounty, results.feePaid);
  }

  /// @notice Initialize an OrderResults struct with the right array lengths
  /// @param numModules Number of modules to allocate arrays for
  /// @return results Initialized OrderResults struct
  function _createOrderResults(uint256 numModules) internal pure returns (OrderResults memory results) {
    results.amountsGot = new uint256[](numModules);
    results.amountsGave = new uint256[](numModules);
    results.moduleAddresses = new address[](numModules);

    // Other fields default to 0
    return results;
  }

  /// @notice Main order execution logic
  /// @param olKey The offer list key
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param amountToSell Amount of input tokens to sell
  /// @param multiModuleData Data structure with modules and percentages
  /// @param results Struct to store all order execution results
  function _executeOrder(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amountToSell,
    MultiModuleData calldata multiModuleData,
    OrderResults memory results
  ) internal {
    // Execute swaps via external modules
    _executeExternalSwaps(olKey, maxTick, amountToSell, multiModuleData, results);

    // Calculate unused amount after external swaps
    results.unusedAmount = _calculateUnusedAmount(amountToSell, results.amountsGave);

    // If there's any amount left, route through Mangrove
    if (results.unusedAmount > 0) {
      _executeMangroveSwap(olKey, maxTick, results.unusedAmount, results);
    }

    // Sum up total amounts got and gave from modules
    (results.takerGot, results.takerGave) =
      _aggregateResults(results.takerGot, results.takerGave, results.amountsGot, results.amountsGave);
  }

  /// @notice Executes swaps through external modules
  /// @param olKey The offer list key
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param amountToSell Total amount to sell
  /// @param multiModuleData Data structure with modules and percentages
  /// @param results Struct to store order execution results
  function _executeExternalSwaps(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amountToSell,
    MultiModuleData calldata multiModuleData,
    OrderResults memory results
  ) internal {
    ModuleData[] memory modules = multiModuleData.modules;
    uint16[] memory percentages = multiModuleData.percentages;

    // Handle special case of single module
    if (modules.length == 1) {
      _executeModuleSwap(olKey, maxTick, amountToSell, modules[0], 0, results);
      return;
    }

    // Multiple modules case - distribute according to percentages
    uint256 remainingAmount = amountToSell;

    for (uint256 i = 0; i < modules.length; i++) {
      uint256 moduleAmount;

      if (i == modules.length - 1) {
        // Last module gets remaining amount
        moduleAmount = remainingAmount;
      } else {
        // Calculate amount for this module
        moduleAmount = (amountToSell * percentages[i]) / MAX_BPS;
        remainingAmount -= moduleAmount;
      }

      // Execute swap through this module if amount > 0
      if (moduleAmount > 0) {
        _executeModuleSwap(olKey, maxTick, moduleAmount, modules[i], i, results);
      }
    }
  }

  /// @notice Calculates the amount not used by external modules
  /// @param amountToSell Total amount to sell
  /// @param amountsGave Array of amounts spent through each module
  /// @return unusedAmount Amount not used by external modules
  function _calculateUnusedAmount(uint256 amountToSell, uint256[] memory amountsGave)
    internal
    pure
    returns (uint256 unusedAmount)
  {
    unusedAmount = amountToSell;
    for (uint256 i = 0; i < amountsGave.length; i++) {
      unusedAmount -= amountsGave[i];
    }
    return unusedAmount;
  }

  /// @notice Executes a swap through Mangrove
  /// @param olKey The offer list key
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param unusedAmount Amount to swap
  /// @param results Struct to store order execution results
  function _executeMangroveSwap(OLKey memory olKey, Tick maxTick, uint256 unusedAmount, OrderResults memory results)
    internal
  {
    // Approve MGV to spend the remaining tokens
    IERC20(olKey.inbound_tkn).forceApprove(address(MGV), unusedAmount);

    // Execute Mangrove order
    (uint256 takerGotFromMgv, uint256 takerGaveToMgv, uint256 bounty, uint256 feePaid) =
      MGV.marketOrderByTick(olKey, maxTick, unusedAmount, false);

    // Update results struct with Mangrove values
    results.bounty = bounty;
    results.feePaid = feePaid;
    results.takerGot += takerGotFromMgv;
    results.takerGave += takerGaveToMgv;

    // Revoke approval
    IERC20(olKey.inbound_tkn).forceApprove(address(MGV), 0);
  }

  /// @notice Aggregates results from all modules
  /// @param initialGot Initial amount received (from Mangrove)
  /// @param initialGave Initial amount spent (through Mangrove)
  /// @param amountsGot Array of amounts received from external modules
  /// @param amountsGave Array of amounts spent through external modules
  /// @return totalGot Total amount received
  /// @return totalGave Total amount spent
  function _aggregateResults(
    uint256 initialGot,
    uint256 initialGave,
    uint256[] memory amountsGot,
    uint256[] memory amountsGave
  ) internal pure returns (uint256 totalGot, uint256 totalGave) {
    totalGot = initialGot;
    totalGave = initialGave;

    for (uint256 i = 0; i < amountsGot.length; i++) {
      totalGot += amountsGot[i];
      totalGave += amountsGave[i];
    }

    return (totalGot, totalGave);
  }

  /// @notice Returns tokens to the taker after execution
  /// @param inboundToken Inbound token address
  /// @param outboundToken Outbound token address
  /// @param amountToSell Original amount intended to sell
  /// @param takerGot Total amount received
  /// @param takerGave Total amount spent
  /// @param bounty Bounty received from failed offers
  function _returnTokensToTaker(
    address inboundToken,
    address outboundToken,
    uint256 amountToSell,
    uint256 takerGot,
    uint256 takerGave,
    uint256 bounty
  ) internal {
    // Return unused tokens
    uint256 inboundToReturn = amountToSell - takerGave;
    if (inboundToReturn > 0) {
      IERC20(inboundToken).safeTransfer(msg.sender, inboundToReturn);
    }

    if (takerGot > 0) {
      IERC20(outboundToken).safeTransfer(msg.sender, takerGot);
    }

    if (bounty > 0) {
      (bool success,) = payable(msg.sender).call{value: bounty}("");
      if (!success) revert GhostBookErrors.TransferFailed();
    }
  }

  /// @notice Emits events for order completion
  /// @param olKeyHash Hash of the offer list key
  /// @param moduleAddresses Array of module addresses used
  /// @param percentages Array of percentages for each module
  /// @param amountsGot Array of amounts received from each module
  /// @param amountsGave Array of amounts spent through each module
  /// @param takerGot Total amount received
  /// @param takerGave Total amount spent
  /// @param bounty Bounty received from failed offers
  /// @param feePaid Fees paid to Mangrove
  function _emitOrderEvents(
    bytes32 olKeyHash,
    address[] memory moduleAddresses,
    uint16[] memory percentages,
    uint256[] memory amountsGot,
    uint256[] memory amountsGave,
    uint256 takerGot,
    uint256 takerGave,
    uint256 bounty,
    uint256 feePaid
  ) internal {
    // Emit detailed breakdown event
    emit MultiModuleOrderExecuted(msg.sender, olKeyHash, moduleAddresses, percentages, amountsGot, amountsGave);

    // Emit standard order completion event
    emit GhostBookEvents.OrderCompleted(msg.sender, olKeyHash, takerGot, takerGave, bounty, feePaid);
  }

  /// @notice Validates the multi-module data structure
  /// @param multiModuleData The multi-module data to validate
  function _validateMultiModuleData(MultiModuleData calldata multiModuleData) internal view {
    // Ensure modules array is not empty
    if (multiModuleData.modules.length == 0) {
      revert EmptyModuleArray();
    }

    // Ensure modules and percentages arrays have the same length
    if (multiModuleData.modules.length != multiModuleData.percentages.length) {
      revert ArrayLengthMismatch();
    }

    // Only check percentages if more than one module is provided
    if (multiModuleData.modules.length > 1) {
      // Ensure percentages add up to 100%
      uint16 totalPercentage = 0;
      for (uint256 i = 0; i < multiModuleData.percentages.length; i++) {
        totalPercentage += multiModuleData.percentages[i];

        // Verify each module is whitelisted
        if (!whitelistedModules[multiModuleData.modules[i].module]) {
          revert GhostBookErrors.ModuleNotWhitelisted();
        }
      }

      // Validate total percentage
      if (totalPercentage != MAX_BPS) {
        revert InvalidPercentages();
      }
    } else {
      // If only one module, verify it's whitelisted
      if (!whitelistedModules[multiModuleData.modules[0].module]) {
        revert GhostBookErrors.ModuleNotWhitelisted();
      }
    }
  }

  /// @notice Executes a swap through a single module
  /// @param olKey The offer list key containing token pair and tick spacing
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param amount Amount of input tokens to sell through this module
  /// @param moduleData Data for the module to execute
  /// @param index Index of the module in the arrays
  /// @param results Struct to store order execution results
  function _executeModuleSwap(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amount,
    ModuleData memory moduleData,
    uint256 index,
    OrderResults memory results
  ) internal {
    // Store module address
    results.moduleAddresses[index] = address(moduleData.module);

    try this.externalSwap(olKey, amount, maxTick, moduleData, msg.sender) returns (uint256 gave, uint256 got) {
      // Record amounts got and gave
      results.amountsGot[index] = got;
      results.amountsGave[index] = gave;
    } catch {
      // On failure, record zero amounts
      results.amountsGot[index] = 0;
      results.amountsGave[index] = 0;
    }

    // Reset token approvals
    IERC20(olKey.inbound_tkn).forceApprove(address(moduleData.module), 0);
  }
}
