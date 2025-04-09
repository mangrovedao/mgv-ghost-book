// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ModuleDeployer, console} from "./ModuleDeployer.s.sol";
import {AerodromeSwapper, OLKey, Tick, TickLib} from "../../src/modules/AerodromeSwapper.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {ModuleData} from "src/MangroveGhostBook.sol";
import {StdCheats} from "forge-std/src/Test.sol";
import {IAerodromeRouter} from "src/interface/vendors/IAerodromeRouter.sol";

/// NOTE: Code has been refactored to avoid stack too deep
contract AerodromeModuleDeployer is ModuleDeployer, StdCheats {
  IERC20 public constant USDC_BASE = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
  IERC20 public constant USDT_BASE = IERC20(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA);
  bool constant IS_STABLE_POOL = true;
  address public constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
  address public constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
  
  // Storage for balance tracking across functions
  uint256 private initialUsdtBalance;
  uint256 private initialUsdcBalance;

  function deployModule() public override returns (address module) {
    _logDeploymentStart();
    
    vm.broadcast();
    console.log("Broadcasting deployment transaction...");
    module = address(new AerodromeSwapper(address(mangroveGhostBook), AERODROME_ROUTER));

    _logDeploymentSuccess(module);
    return module;
  }

  function _logDeploymentStart() internal {
    console.log("---------------------------------------------");
    console.log("Starting AerodromeSwapper Module Deployment");
    console.log("---------------------------------------------");
    console.log("MangroveGhostBook address:", address(mangroveGhostBook));
    console.log("Aerodrome Router address:", AERODROME_ROUTER);
    console.log("Aerodrome Factory address:", AERODROME_FACTORY);
  }

  function _logDeploymentSuccess(address module) internal {
    console.log("AerodromeSwapper successfully deployed at:", module);
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
    console.log("Starting AerodromeSwapper Live Test");
    console.log("---------------------------------------------");
    console.log("Test address:", testAddress);
    console.log("Module address:", module);
    console.log("USDC address:", address(USDC_BASE));
    console.log("USDT address:", address(USDT_BASE));
  }

  function _setupTokensAndApprovals() internal {
    // Deal USDT
    console.log("Dealing 10,000 USDT to test address");
    deal(address(USDT_BASE), testAddress, 10_000e6);
    initialUsdtBalance = USDT_BASE.balanceOf(testAddress);
    console.log("USDT balance after deal:", initialUsdtBalance);
    
    // Deal USDC
    console.log("Dealing 10,000 USDC to test address");
    deal(address(USDC_BASE), testAddress, 10_000e6);
    initialUsdcBalance = USDC_BASE.balanceOf(testAddress);
    console.log("USDC balance after deal:", initialUsdcBalance);
    
    // Approve tokens
    console.log("Approving USDT for MangroveGhostBook");
    USDT_BASE.approve(address(mangroveGhostBook), type(uint256).max);
    console.log("Approving USDC for MangroveGhostBook");
    USDC_BASE.approve(address(mangroveGhostBook), type(uint256).max);
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
    OLKey memory olKey = OLKey({
      outbound_tkn: address(USDT_BASE), 
      inbound_tkn: address(USDC_BASE), 
      tickSpacing: 1
    });
    
    console.log("OLKey - outbound_tkn:", olKey.outbound_tkn);
    console.log("OLKey - inbound_tkn:", olKey.inbound_tkn);
    console.log("OLKey - tickSpacing:", olKey.tickSpacing);
    
    return olKey;
  }

  function _setupModuleData(address module) internal returns (ModuleData memory) {
    uint256 deadline = block.timestamp + 3600;
    console.log("Order deadline:", deadline);
    
    ModuleData memory moduleData = ModuleData({
      module: IExternalSwapModule(address(module)),
      data: abi.encode(IS_STABLE_POOL, AERODROME_FACTORY, deadline)
    });
    
    console.log("ModuleData encoded successfully");
    return moduleData;
  }

  function _calculateTicks() internal returns (Tick, Tick) {
    // Get current reserves from Aerodrome pool
    (uint256 reserveUsdt, uint256 reserveUSDC) =
      IAerodromeRouter(AERODROME_ROUTER).getReserves(
        address(USDC_BASE), 
        address(USDT_BASE), 
        IS_STABLE_POOL, 
        AERODROME_FACTORY
      );
    
    // Calculate the current tick from reserves
    Tick spotTick = _calculateTickFromReserves(reserveUsdt, reserveUSDC);
    
    // Add buffer to ensure trade goes through
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 2000);
    
    return (spotTick, maxTick);
  }

  function _logOrderParameters(Tick spotTick, Tick maxTick) internal {
    console.log("Current spot tick:", Tick.unwrap(spotTick));
    console.log("Max tick for order:", Tick.unwrap(maxTick));
    console.log("Order amount: 1,000,000 (1e6)");
    console.log("Is stable pool:", IS_STABLE_POOL);
  }

  function _performMarketOrder(
    OLKey memory olKey, 
    Tick maxTick, 
    ModuleData memory moduleData
  ) internal returns (bool) {
    console.log("Executing test market order...");
    
    try mangroveGhostBook.marketOrderByTick(
      olKey, 
      maxTick, 
      1e6, 
      moduleData
    ) returns (
      uint256 takerGot, 
      uint256 takerGave, 
      uint256 bounty, 
      uint256 feePaid
    ) {
      _logOrderSuccess(takerGot, takerGave, bounty, feePaid);
      _logBalanceChanges();
      
      return takerGot > 0 && takerGave > 0;
    } catch (bytes memory reason) {
      _logOrderFailure(reason);
      return false;
    }
  }

  function _logOrderSuccess(
    uint256 takerGot, 
    uint256 takerGave, 
    uint256 bounty, 
    uint256 feePaid
  ) internal {
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
    uint256 finalUsdtBalance = USDT_BASE.balanceOf(testAddress);
    uint256 finalUsdcBalance = USDC_BASE.balanceOf(testAddress);
    
    console.log("USDT balance after swap:", finalUsdtBalance);
    console.log("USDC balance after swap:", finalUsdcBalance);
    
    int256 usdtChange = int256(finalUsdtBalance) - int256(initialUsdtBalance);
    int256 usdcChange = int256(finalUsdcBalance) - int256(initialUsdcBalance);
    
    console.log("USDT change:", usdtChange);
    console.log("USDC change:", usdcChange);
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
    // For Aerodrome/Uniswap V2 style pools, price is reserveOut/reserveIn
    return TickLib.tickFromVolumes(reserveIn, reserveOut);
  }
}