// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest} from "../../base/BaseMangroveTest.t.sol";
import {MultiModuleGhostBook, MultiModuleData, ModuleData} from "src/extensions/MultiModuleGhostBook.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {SlippageAwareMockExternalSwapModule} from "../../helpers/mock/SlippageAwareMockExternalSwapModule.sol";

contract MultiModuleGhostBookTest is BaseMangroveTest {
  MultiModuleGhostBook public multiGhostBook;
  OLKey public olKey;

  // Mock modules
  SlippageAwareMockExternalSwapModule public mockModule1;
  SlippageAwareMockExternalSwapModule public mockModule2;
  SlippageAwareMockExternalSwapModule public mockModule3;

  // Module exchange rates (1 inbound = X outbound, scaled by 1e18)
  uint256 constant RATE_1 = 1e18; // 1:1
  uint256 constant RATE_2 = 1.05e18; // 1:1.05
  uint256 constant RATE_3 = 0.98e18; // 1:0.98

  // Slippage factors (higher = more slippage, scaled by 1e18)
  uint256 constant SLIPPAGE_LOW = 1e16; // Low slippage factor
  uint256 constant SLIPPAGE_MEDIUM = 5e16; // Medium slippage factor
  uint256 constant SLIPPAGE_HIGH = 1e17; // High slippage factor

  uint256 amountToSell;

  function setUp() public override {
    chain = ForkChain.ARBITRUM;
    super.setUp();

    // Set up test market
    olKey = OLKey({outbound_tkn: address(USDC), inbound_tkn: address(USDT), tickSpacing: 1});

    // Deploy MultiModuleGhostBook
    multiGhostBook = new MultiModuleGhostBook(address(mgv));

    // Deploy mock modules with different exchange rates and slippage factors
    mockModule1 = new SlippageAwareMockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_1, SLIPPAGE_LOW);

    mockModule2 =
      new SlippageAwareMockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_2, SLIPPAGE_MEDIUM);

    mockModule3 = new SlippageAwareMockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_3, SLIPPAGE_HIGH);

    // Whitelist the modules
    multiGhostBook.whitelistModule(address(mockModule1));
    multiGhostBook.whitelistModule(address(mockModule2));
    multiGhostBook.whitelistModule(address(mockModule3));

    // Fund modules with outbound tokens for swap
    deal(address(USDC), address(mockModule1), 1_000_000e6);
    deal(address(USDC), address(mockModule2), 1_000_000e6);
    deal(address(USDC), address(mockModule3), 1_000_000e6);

    // Approve MultiModuleGhostBook to spend taker's tokens
    vm.startPrank(users.taker1);
    USDT.approve(address(multiGhostBook), type(uint256).max);
    vm.stopPrank();

    // Set up Mangrove market
    setupMarket(olKey);
    users.maker1.setKey(olKey);
    users.maker1.provisionMgv(1 ether);
    users.maker2.setKey(olKey);
    users.maker2.provisionMgv(1 ether);
  }

  function test_MultiGhostBook_market_order_with_multiple_modules() public {
    // Prepare test parameters
    amountToSell = 1e6;
    Tick maxTick = Tick.wrap(1000); // A reasonable price limit

    // Prepare modules in order of best rate to worst rate
    ModuleData[] memory modules = new ModuleData[](2);
    modules[0] = ModuleData({module: IExternalSwapModule(address(mockModule2)), data: ""}); // Best rate (1.05)
    modules[1] = ModuleData({module: IExternalSwapModule(address(mockModule1)), data: ""}); // Medium rate (1.00)

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules});

    // Execute multi-module market order
    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();

    // Verify results
    assertGt(takerGot, 0, "Should receive tokens");
    assertApproxEq(takerGave, amountToSell, 1);

    // Since we're using prioritized execution, all amount should go to first module (if it can handle it)
    uint256 optimalAmountModule2 = mockModule2.findOptimalAmount(maxTick, amountToSell);

    // If module2 can handle the full amount, then all should go through it
    if (optimalAmountModule2 == amountToSell) {
      uint256 effectiveRate = mockModule2.getEffectiveRate(amountToSell);
      uint256 expectedOutput = (amountToSell * effectiveRate) / 1e18;
      assertApproxEqRel(takerGot, expectedOutput, 0.01e18, "Output should match expected from first module");
    }
    // Otherwise, some should go through module2 and the rest through module1
    else if (optimalAmountModule2 > 0) {
      uint256 effectiveRate2 = mockModule2.getEffectiveRate(optimalAmountModule2);
      uint256 expectedFromModule2 = (optimalAmountModule2 * effectiveRate2) / 1e18;

      uint256 remainingAmount = amountToSell - optimalAmountModule2;
      uint256 optimalAmountModule1 = mockModule1.findOptimalAmount(maxTick, remainingAmount);
      uint256 effectiveRate1 = mockModule1.getEffectiveRate(optimalAmountModule1);
      uint256 expectedFromModule1 = (optimalAmountModule1 * effectiveRate1) / 1e18;

      uint256 expectedTotal = expectedFromModule2 + expectedFromModule1;
      assertApproxEqRel(takerGot, expectedTotal, 0.01e18, "Output should match expected from both modules");
    }
  }

  function test_MultiGhostBook_with_mangrove_fallback() public {
    // Prepare test parameters
    amountToSell = 10e6;
    Tick maxTick = Tick.wrap(1000); // A reasonable price limit

    // Add some offers to Mangrove
    users.maker1.newOfferByTick(Tick.wrap(800), 5_000e6, 2 ** 18);

    // Create a module that can handle only a portion of the order
    // Create a module with low liquidity
    SlippageAwareMockExternalSwapModule limitedModule =
      new SlippageAwareMockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_2, SLIPPAGE_HIGH);
    multiGhostBook.whitelistModule(address(limitedModule));
    // Only fund with limited USDC
    deal(address(USDC), address(limitedModule), 2_000e6);

    // Prepare module data
    ModuleData[] memory modules = new ModuleData[](1);
    modules[0] = ModuleData({module: IExternalSwapModule(address(limitedModule)), data: ""});

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules});

    // Deal USDT to taker
    deal(address(USDT), users.taker1, amountToSell);

    // Execute multi-module market order
    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();

    // Verify results - should have executed through module and Mangrove
    assertGt(takerGot, 0, "Should receive tokens");
    assertGt(takerGave, 0, "Should spend some amount");

    // The module should use what it can, and then the rest should go to Mangrove
    uint256 moduleOptimalAmount = limitedModule.findOptimalAmount(maxTick, amountToSell);
    uint256 effectiveRate = limitedModule.getEffectiveRate(moduleOptimalAmount);
    uint256 expectedModuleOutput = (moduleOptimalAmount * effectiveRate) / 1e18;

    // If module handled everything, taker got should match module output
    // Otherwise, it should be more due to Mangrove
    if (moduleOptimalAmount < amountToSell) {
      assertGe(takerGot, expectedModuleOutput, "Should have used both module and Mangrove");
    }
  }

  function test_MultiGhostBook_combined_module_and_mangrove() public {
    // Prepare test parameters
    amountToSell = 20e6; // Larger amount to test both sources
    Tick maxTick = Tick.wrap(900); // Reasonable price limit

    // Add offers to Mangrove at a slightly worse price than module1
    Tick mangroveOfferTick = Tick.wrap(850);
    users.maker1.newOfferByTick(mangroveOfferTick, 5_000e6, 2 ** 18);
    users.maker2.newOfferByTick(mangroveOfferTick, 5_000e6, 2 ** 18);

    // Create a module with limited capacity
    SlippageAwareMockExternalSwapModule limitedModule =
      new SlippageAwareMockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_2, SLIPPAGE_MEDIUM);
    multiGhostBook.whitelistModule(address(limitedModule));
    // Only fund with limited USDC - enough for about half the swap
    deal(address(USDC), address(limitedModule), 5_000e6);

    // Prepare module data
    ModuleData[] memory modules = new ModuleData[](1);
    modules[0] = ModuleData({module: IExternalSwapModule(address(limitedModule)), data: ""});

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules});

    // Deal USDT to taker
    deal(address(USDT), users.taker1, amountToSell);

    // Record balances before swap
    uint256 takerUsdtBefore = USDT.balanceOf(users.taker1);
    uint256 takerUsdcBefore = USDC.balanceOf(users.taker1);

    // Execute multi-module market order
    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();

    // Record balances after swap
    uint256 takerUsdtAfter = USDT.balanceOf(users.taker1);
    uint256 takerUsdcAfter = USDC.balanceOf(users.taker1);

    // Verify results
    assertEq(takerUsdtBefore - takerUsdtAfter, takerGave, "USDT spent should match takerGave");
    assertEq(takerUsdcAfter - takerUsdcBefore, takerGot, "USDC received should match takerGot");

    // Module should handle its maximum amount, and remaining should go through Mangrove
    uint256 moduleOptimalAmount = limitedModule.findOptimalAmount(maxTick, amountToSell);
    uint256 effectiveRate = limitedModule.getEffectiveRate(moduleOptimalAmount);
    uint256 expectedModuleOutput = (moduleOptimalAmount * effectiveRate) / 1e18;

    assertApproxEq(takerGot, expectedModuleOutput, 1);
  }

  function test_MultiGhostBook_max_tick_reached_in_module() public {
    // Prepare test parameters
    amountToSell = 10e6;

    // Create a very restrictive tick that will affect slippage
    Tick maxTick = Tick.wrap(int256(-50)); // Very restrictive max tick

    // Create a new module with worse rate (high price)
    SlippageAwareMockExternalSwapModule expensiveModule =
      new SlippageAwareMockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, 0.5e18, 5e17); // 1:0.5 rate, high slippage
    multiGhostBook.whitelistModule(address(expensiveModule));
    deal(address(USDC), address(expensiveModule), 1_000_000e6);

    // Add some offers to Mangrove at a good price that fits under max tick
    Tick mangroveOfferTick = Tick.wrap(-100); // Better than maxTick
    users.maker1.newOfferByTick(mangroveOfferTick, 5_000e6, 2 ** 18);

    // Prepare module data - using modules in order of preference (best rates first)
    ModuleData[] memory modules = _createModules(expensiveModule);

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules});

    // Deal USDT to taker
    deal(address(USDT), users.taker1, amountToSell);

    // Execute multi-module market order
    (uint256 takerGot, uint256 takerGave) = _executeMarketOrder(maxTick, amountToSell, multiData);

    // Verify results
    assertGt(takerGot, 0, "Should receive tokens");
    assertEq(takerGave, amountToSell, "Should spend full amount");

    // Calculate expected outputs from each module
    uint256 totalExpectedFromModules = _calculateExpectedOutputs(maxTick, amountToSell, modules);

    // If max tick is very restrictive, modules might not be able to handle any amount
    // In that case, everything should go through Mangrove
    if (totalExpectedFromModules > 0) {
      assertGe(takerGot, totalExpectedFromModules, "Output should include at least module contribution");
    }

    // Verify the overall execution respects max tick
    Tick executedTick = TickLib.tickFromVolumes(takerGave, takerGot);
    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price should not exceed maxTick");
  }

  // Helper function to create modules array
  function _createModules(SlippageAwareMockExternalSwapModule expensiveModule)
    internal
    view
    returns (ModuleData[] memory)
  {
    ModuleData[] memory modules = new ModuleData[](3);
    modules[0] = ModuleData({module: IExternalSwapModule(address(mockModule2)), data: ""}); // Best base rate
    modules[1] = ModuleData({module: IExternalSwapModule(address(mockModule1)), data: ""}); // Medium base rate
    modules[2] = ModuleData({module: IExternalSwapModule(address(expensiveModule)), data: ""}); // Worst rate
    return modules;
  }

  // Helper function to execute market order and extract results
  function _executeMarketOrder(Tick maxTick, uint256 amount, MultiModuleData memory multiData)
    internal
    returns (uint256 takerGot, uint256 takerGave)
  {
    vm.startPrank(users.taker1);
    (takerGot, takerGave,,) = multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amount, multiData);
    vm.stopPrank();
    return (takerGot, takerGave);
  }

  // Helper function to calculate expected outputs from all modules
  function _calculateExpectedOutputs(Tick maxTick, uint256 totalAmount, ModuleData[] memory modules)
    internal
    returns (uint256 totalExpectedOutput)
  {
    // Calculate expected output from mockModule2 (first module)
    (uint256 expectedFromModule2, uint256 remainingForModule1) =
      _calculateModuleOutput(mockModule2, maxTick, totalAmount);

    // Calculate expected output from mockModule1 (second module)
    (uint256 expectedFromModule1, uint256 remainingForExpensive) =
      _calculateModuleOutput(mockModule1, maxTick, remainingForModule1);

    // Calculate expected output from expensiveModule (third module)
    SlippageAwareMockExternalSwapModule expensiveModule =
      SlippageAwareMockExternalSwapModule(address(modules[2].module));

    (uint256 expectedFromExpensive,) = _calculateModuleOutput(expensiveModule, maxTick, remainingForExpensive);

    // Sum up expected outputs
    totalExpectedOutput = expectedFromModule2 + expectedFromModule1 + expectedFromExpensive;

    return totalExpectedOutput;
  }

  // Helper function to calculate output for a single module
  function _calculateModuleOutput(SlippageAwareMockExternalSwapModule module, Tick maxTick, uint256 amount)
    internal
    returns (uint256 expectedOutput, uint256 remainingAmount)
  {
    uint256 optimalAmount = module.findOptimalAmount(maxTick, amount);
    expectedOutput = 0;

    if (optimalAmount > 0) {
      uint256 effectiveRate = module.getEffectiveRate(optimalAmount);
      expectedOutput = (optimalAmount * effectiveRate) / 1e18;
      remainingAmount = amount - optimalAmount;
    } else {
      remainingAmount = amount;
    }

    return (expectedOutput, remainingAmount);
  }

  function test_MultiGhostBook_module_not_whitelisted() public {
    // Create a new module that is not whitelisted
    SlippageAwareMockExternalSwapModule nonWhitelistedModule =
      new SlippageAwareMockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_1, SLIPPAGE_LOW);

    // Prepare test parameters
    amountToSell = 10e6;
    Tick maxTick = Tick.wrap(1000);

    // Prepare module data with non-whitelisted module
    ModuleData[] memory modules = new ModuleData[](1);
    modules[0] = ModuleData({module: IExternalSwapModule(address(nonWhitelistedModule)), data: ""});

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules});

    // Deal USDT to taker
    deal(address(USDT), users.taker1, amountToSell);

    // Expect revert due to non-whitelisted module
    vm.startPrank(users.taker1);
    vm.expectRevert(abi.encodeWithSignature("ModuleNotWhitelisted()"));
    multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();
  }
}
