// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ModuleDeployer, console} from "./ModuleDeployer.s.sol";
import {BalancerV1Swapper, OLKey, Tick, TickLib} from "src/modules/BalancerV1Swapper.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {ModuleData} from "src/MangroveGhostBook.sol";
import {StdCheats} from "forge-std/src/Test.sol";
import {ISwapOperations} from "src/interface/vendors/ISwapOperations.sol";

/// NOTE: Code has been refactored to avoid stack too deep
contract BalancerV1ModuleDeployer is ModuleDeployer, StdCheats {
  IERC20 public constant jUSDv1_SEI = IERC20(0xBE574b6219C6D985d08712e90C21A88fd55f1ae8);
  IERC20 public constant jTSLAv1_SEI = IERC20(0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1);
  address public constant SWAP_OPERATIONS_JELLYSWAP = 0x64Da11e4436F107A2bFc4f19505c277728C0F3F0;

  // Storage for balance tracking across functions
  uint256 private initialJTSLABalance;
  uint256 private initialJUSDBalance;

  function deployModule() public override returns (address module) {
    _logDeploymentStart();

    vm.broadcast();
    console.log("Broadcasting deployment transaction...");
    module = address(new BalancerV1Swapper(address(mangroveGhostBook)));

    _logDeploymentSuccess(module);
    return module;
  }

  function _logDeploymentStart() internal {
    console.log("---------------------------------------------");
    console.log("Starting BalancerV1Swapper Module Deployment");
    console.log("---------------------------------------------");
    console.log("MangroveGhostBook address:", address(mangroveGhostBook));
  }

  function _logDeploymentSuccess(address module) internal {
    console.log("BalancerV1Swapper successfully deployed at:", module);
    console.log("Deployment gas used:", gasleft());
    console.log("---------------------------------------------");
  }

  function liveTestModule(address module) public override returns (bool) {
    _logTestStart(module);

    // Check test address is valid
    if (testAddress == address(0)) {
      console.log("ERROR: Test address is zero. Please set TEST_ADDRESS env variable");
      return false;
    }

    // Initialize token balances and approvals
    _setupTokensAndApprovals();

    // Execute market order
    bool success = _executeMarketOrder(module);

    if (success) {
      _logTestSuccess();
      return true;
    } else {
      _logTestFailure();
      return false;
    }
  }

  function _logTestStart(address module) internal {
    console.log("---------------------------------------------");
    console.log("Starting BalancerV1Swapper Live Test");
    console.log("---------------------------------------------");
    console.log("Test address:", testAddress);
    console.log("Module address:", module);
    console.log("jUSD address:", address(jUSDv1_SEI));
    console.log("jTSLA address:", address(jTSLAv1_SEI));
  }

  function _setupTokensAndApprovals() internal {
    // Deal jTSLA
    console.log("Dealing 10,000 jTSLA to test address");
    deal(address(jTSLAv1_SEI), testAddress, 10_000e6);
    initialJTSLABalance = jTSLAv1_SEI.balanceOf(testAddress);
    console.log("jTSLA balance after deal:", initialJTSLABalance);

    // Deal jUSD
    console.log("Dealing 10,000 jUSD to test address");
    deal(address(jUSDv1_SEI), testAddress, 10_000e6);
    initialJUSDBalance = jUSDv1_SEI.balanceOf(testAddress);
    console.log("jUSD balance after deal:", initialJUSDBalance);

    // Approve tokens
    console.log("Approving jTSLA for MangroveGhostBook");
    jTSLAv1_SEI.approve(address(mangroveGhostBook), type(uint256).max);
    console.log("Approving jUSD for MangroveGhostBook");
    jUSDv1_SEI.approve(address(mangroveGhostBook), type(uint256).max);
  }

  function _executeMarketOrder(address module) internal returns (bool) {
    // Set up OLKey
    OLKey memory olKey = _setupOLKey();

    // Set up ModuleData
    ModuleData memory moduleData = _setupModuleData(module);

    // Calculate ticks
    (Tick spotTick, Tick maxTick) = _calculateTicks();

    // Log order parameters
    _logOrderParameters(spotTick, maxTick);

    // Execute the order
    return _performMarketOrder(olKey, maxTick, moduleData);
  }

  function _setupOLKey() internal pure returns (OLKey memory) {
    OLKey memory olKey = OLKey({outbound_tkn: address(jTSLAv1_SEI), inbound_tkn: address(jUSDv1_SEI), tickSpacing: 1});

    console.log("OLKey - outbound_tkn:", olKey.outbound_tkn);
    console.log("OLKey - inbound_tkn:", olKey.inbound_tkn);
    console.log("OLKey - tickSpacing:", olKey.tickSpacing);

    return olKey;
  }

  function _setupModuleData(address module) internal returns (ModuleData memory) {
    uint256 deadline = block.timestamp + 3600;
    console.log("Order deadline:", deadline);

    ModuleData memory moduleData =
      ModuleData({module: IExternalSwapModule(address(module)), data: abi.encode(SWAP_OPERATIONS_JELLYSWAP, deadline)});

    console.log("ModuleData encoded successfully");
    return moduleData;
  }

  function _calculateTicks() internal returns (Tick, Tick) {
    // Use a small amount to estimate the current price
    uint256 smallAmount = 1 ether;

    // Create path for estimation
    address[] memory path = new address[](2);
    path[0] = address(jUSDv1_SEI);
    path[1] = address(jTSLAv1_SEI);

    // Get spot price from pool
    (ISwapOperations.SwapAmount[] memory amounts,) =
      ISwapOperations(SWAP_OPERATIONS_JELLYSWAP).getAmountsOut(smallAmount, path);
    uint256 spotPrice = amounts[1].amount;

    // Calculate the current tick and add a large buffer
    Tick spotTick = TickLib.tickFromVolumes(smallAmount, spotPrice);

    // Add buffer to ensure trade goes through
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 2000);

    return (spotTick, maxTick);
  }

  function _logOrderParameters(Tick spotTick, Tick maxTick) internal {
    console.log("Current spot tick:", Tick.unwrap(spotTick));
    console.log("Max tick for order:", Tick.unwrap(maxTick));
    console.log("Order amount: 1,000,000 (1e6)");
  }

  function _performMarketOrder(OLKey memory olKey, Tick maxTick, ModuleData memory moduleData) internal returns (bool) {
    console.log("Executing test market order...");
    try mangroveGhostBook.marketOrderByTick(olKey, maxTick, 1e6, moduleData) returns (
      uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid
    ) {
      _logOrderSuccess(takerGot, takerGave, bounty, feePaid);
      _logBalanceChanges();
      return takerGot > 0 && takerGave > 0;
    } catch (bytes memory reason) {
      _logOrderFailure(reason);
      return false;
    }
  }

  function _logOrderSuccess(uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) internal {
    console.log("Order execution successful!");
    console.log("takerGot:", takerGot);
    console.log("takerGave:", takerGave);
    console.log("bounty:", bounty);
    console.log("feePaid:", feePaid);
  }

  function _logOrderFailure(bytes memory reason) internal {
    console.log("Order execution failed!");
    console.log("Error reason:", string(reason));
  }

  function _logBalanceChanges() internal {
    uint256 finaljTSLABalance = jTSLAv1_SEI.balanceOf(testAddress);
    uint256 finaljUSDBalance = jUSDv1_SEI.balanceOf(testAddress);

    console.log("jTSLA balance after swap:", finaljTSLABalance);
    console.log("jUSD balance after swap:", finaljUSDBalance);

    int256 jTSLAChange = int256(finaljTSLABalance) - int256(initialJTSLABalance);
    int256 jjTSLAhange = int256(finaljUSDBalance) - int256(initialJUSDBalance);

    console.log("jTSLA change:", jTSLAChange);
    console.log("jUSD change:", jjTSLAhange);
  }

  function _logTestSuccess() internal {
    console.log("---------------------------------------------");
    console.log("Test PASSED (SUCCESS)");
    console.log("---------------------------------------------");
  }

  function _logTestFailure() internal {
    console.log("---------------------------------------------");
    console.log("Test FAILED (ERROR)");
    console.log("---------------------------------------------");
  }

  // Helper to calculate a price tick from pool reserves
  function _calculateTickFromReserves(uint256 reserveIn, uint256 reserveOut) internal pure returns (Tick) {
    // For BalancerV1 style pools, price is reserveOut/reserveIn
    return TickLib.tickFromVolumes(reserveIn, reserveOut);
  }
}
