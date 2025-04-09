// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest} from "../../base/BaseMangroveTest.t.sol";
import {MultiModuleGhostBook, MultiModuleData, ModuleData} from "src/extensions/MultiModuleGhostBook.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

contract MockExternalSwapModule is IExternalSwapModule {
  IERC20 public immutable inboundToken;
  IERC20 public immutable outboundToken;
  uint256 public immutable exchangeRate; // 1 inbound = exchangeRate outbound (scaled by 1e18)

  constructor(address _inbound, address _outbound, uint256 _exchangeRate) {
    inboundToken = IERC20(_inbound);
    outboundToken = IERC20(_outbound);
    exchangeRate = _exchangeRate;
  }

  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, bytes memory data) external override {
    // Check that tokens match expected tokens
    require(olKey.inbound_tkn == address(inboundToken), "Inbound token mismatch");
    require(olKey.outbound_tkn == address(outboundToken), "Outbound token mismatch");

    // Receive tokens from sender (already transferred to this contract)
    uint256 amountReceived = inboundToken.balanceOf(address(this));

    // Calculate amount out based on exchange rate
    uint256 amountOut = (amountReceived * exchangeRate) / 1e18;

    // Check price is within limit
    Tick inferredTick = TickLib.tickFromVolumes(amountReceived, amountOut);
    require(Tick.unwrap(inferredTick) <= Tick.unwrap(maxTick), "Price exceeds limit");

    // Transfer tokens back to sender
    outboundToken.transfer(msg.sender, amountOut);
  }
}

contract MultiModuleGhostBookTest is BaseMangroveTest {
  MultiModuleGhostBook public multiGhostBook;
  OLKey public olKey;

  // Mock modules
  MockExternalSwapModule public mockModule1;
  MockExternalSwapModule public mockModule2;
  MockExternalSwapModule public mockModule3;

  // Module exchange rates (1 inbound = X outbound, scaled by 1e18)
  uint256 constant RATE_1 = 1e18; // 1:1
  uint256 constant RATE_2 = 1.05e18; // 1:1.05
  uint256 constant RATE_3 = 0.98e18; // 1:0.98

  uint256 amountToSell;

  function setUp() public override {
    chain = ForkChain.ARBITRUM;
    super.setUp();

    // Set up test market
    olKey = OLKey({outbound_tkn: address(USDC), inbound_tkn: address(USDT), tickSpacing: 1});

    // Deploy MultiModuleGhostBook
    multiGhostBook = new MultiModuleGhostBook(address(mgv));

    // Deploy mock modules with different exchange rates
    mockModule1 = new MockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_1);
    mockModule2 = new MockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_2);
    mockModule3 = new MockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_3);

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
    amountToSell = 10e6;
    Tick maxTick = Tick.wrap(1000); // A reasonable price limit

    // Prepare module data
    ModuleData[] memory modules = new ModuleData[](2);
    modules[0] = ModuleData({module: IExternalSwapModule(address(mockModule1)), data: ""});
    modules[1] = ModuleData({module: IExternalSwapModule(address(mockModule2)), data: ""});

    // Prepare percentages (50/50 split)
    uint16[] memory percentages = new uint16[](2);
    percentages[0] = 5000; // 50%
    percentages[1] = 5000; // 50%

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules, percentages: percentages});

    // Execute multi-module market order
    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();

    // Verify results
    assertGt(takerGot, 0, "Should receive tokens");
    assertEq(takerGave, amountToSell, "Should spend full amount");

    // Calculate expected output based on exchange rates and percentages
    uint256 expectedOutput = ((amountToSell / 2) * RATE_1) / 1e18 + ((amountToSell / 2) * RATE_2) / 1e18;

    assertApproxEqRel(takerGot, expectedOutput, 0.01e18, "Output should match expected amount");
  }

  function test_MultiGhostBook_with_mangrove_fallback() public {
    // Prepare test parameters
    amountToSell = 10e6;
    Tick maxTick = Tick.wrap(1000); // A reasonable price limit

    // Add some offers to Mangrove
    users.maker1.newOfferByTick(Tick.wrap(800), 5_000e6, 2 ** 18);

    // Prepare module data with an invalid module that will cause fallback to Mangrove
    ModuleData[] memory modules = new ModuleData[](1);
    modules[0] = ModuleData({module: IExternalSwapModule(address(mockModule3)), data: ""});

    // Prepare percentages
    uint16[] memory percentages = new uint16[](1);
    percentages[0] = 10000; // 100%

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules, percentages: percentages});

    // Deal USDT to taker
    deal(address(USDT), users.taker1, amountToSell);

    // Execute multi-module market order
    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();

    // Verify results - should have executed through Mangrove as well
    assertGt(takerGot, 0, "Should receive tokens");
    assertGt(takerGave, 0, "Should spend some amount");
  }

  function test_MultiGhostBook_combined_module_and_mangrove() public {
    // Prepare test parameters
    amountToSell = 20e6; // Larger amount to test both sources
    Tick maxTick = Tick.wrap(900); // Reasonable price limit

    // Add offers to Mangrove at a slightly worse price than module1
    Tick mangroveOfferTick = Tick.wrap(850);
    users.maker1.newOfferByTick(mangroveOfferTick, 5_000e6, 2 ** 18);
    users.maker2.newOfferByTick(mangroveOfferTick, 5_000e6, 2 ** 18);

    // Set up modules to use only half of the amount, so remaining goes to Mangrove
    ModuleData[] memory modules = new ModuleData[](1);
    modules[0] = ModuleData({module: IExternalSwapModule(address(mockModule1)), data: ""});

    // Set percentage to 50% so half goes through module, half through Mangrove
    uint16[] memory percentages = new uint16[](1);
    percentages[0] = 5000; // 50%

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules, percentages: percentages});

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

    {
    uint256 expectedModuleOutput = (amountToSell / 2 * RATE_1) / 1e18;
        

    assertGt(takerGot, expectedModuleOutput, "Should have used both module and Mangrove");
    }
  }

  function test_MultiGhostBook_invalid_percentages() public {
    // Prepare test parameters
    amountToSell = 10e6;
    Tick maxTick = Tick.wrap(1000);

    // Prepare module data
    ModuleData[] memory modules = new ModuleData[](2);
    modules[0] = ModuleData({module: IExternalSwapModule(address(mockModule1)), data: ""});
    modules[1] = ModuleData({module: IExternalSwapModule(address(mockModule2)), data: ""});

    // Prepare invalid percentages (not adding up to 100%)
    uint16[] memory percentages = new uint16[](2);
    percentages[0] = 5000; // 50%
    percentages[1] = 4000; // 40%

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules, percentages: percentages});

    // Deal USDT to taker
    deal(address(USDT), users.taker1, amountToSell);

    // Expect revert due to invalid percentages
    vm.startPrank(users.taker1);
    vm.expectRevert(MultiModuleGhostBook.InvalidPercentages.selector);
    multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();
  }

  function test_MultiGhostBook_array_length_mismatch() public {
    // Prepare test parameters
    amountToSell = 10e6;
    Tick maxTick = Tick.wrap(1000);

    // Prepare module data
    ModuleData[] memory modules = new ModuleData[](2);
    modules[0] = ModuleData({module: IExternalSwapModule(address(mockModule1)), data: ""});
    modules[1] = ModuleData({module: IExternalSwapModule(address(mockModule2)), data: ""});

    // Prepare percentages with mismatched length
    uint16[] memory percentages = new uint16[](1);
    percentages[0] = 10000; // 100%

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules, percentages: percentages});

    // Deal USDT to taker
    deal(address(USDT), users.taker1, amountToSell);

    // Expect revert due to array length mismatch
    vm.startPrank(users.taker1);
    vm.expectRevert(MultiModuleGhostBook.ArrayLengthMismatch.selector);
    multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();
  }

  function test_MultiGhostBook_module_not_whitelisted() public {
    // Create a new module that is not whitelisted
    MockExternalSwapModule nonWhitelistedModule =
      new MockExternalSwapModule(olKey.inbound_tkn, olKey.outbound_tkn, RATE_1);

    // Prepare test parameters
    amountToSell = 10e6;
    Tick maxTick = Tick.wrap(1000);

    // Prepare module data with non-whitelisted module
    ModuleData[] memory modules = new ModuleData[](1);
    modules[0] = ModuleData({module: IExternalSwapModule(address(nonWhitelistedModule)), data: ""});

    // Prepare percentages
    uint16[] memory percentages = new uint16[](1);
    percentages[0] = 10000; // 100%

    // Create MultiModuleData
    MultiModuleData memory multiData = MultiModuleData({modules: modules, percentages: percentages});

    // Deal USDT to taker
    deal(address(USDT), users.taker1, amountToSell);

    // Expect revert due to non-whitelisted module
    vm.startPrank(users.taker1);
    vm.expectRevert(abi.encodeWithSignature("ModuleNotWhitelisted()"));
    multiGhostBook.marketOrderByTickMultiModule(olKey, maxTick, amountToSell, multiData);
    vm.stopPrank();
  }
}
