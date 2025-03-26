// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest, BaseTest, console} from "../../base/BaseMangroveTest.t.sol";
import {BaseAerodromeSwapperTest} from "../../base/modules/BaseAerodromeSwapperTest.t.sol";
import {AerodromeSwapper, IAerodromeRouter} from "src/modules/AerodromeSwapper.sol";
import {MangroveGhostBook, ModuleData} from "src/MangroveGhostBook.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MangroveGhostBookAerodromeTest is BaseMangroveTest, BaseAerodromeSwapperTest {
  MangroveGhostBook public ghostBook;

  OLKey public ol;

  bool constant IS_STABLE_POOL = false;

  function setUp() public override(BaseMangroveTest, BaseAerodromeSwapperTest) {
    chain = ForkChain.BASE;
    super.setUp();
    // Set up OLKey for the market
    ol = OLKey({outbound_tkn: address(USDC), inbound_tkn: address(WETH), tickSpacing: 1});

    // Deploy GhostBook and AerodromeSwapper
    ghostBook = new MangroveGhostBook(address(mgv));
    deployAerodromeSwapper(address(ghostBook), AERODROME_ROUTER);
    ghostBook.whitelistModule(address(swapper));

    // Approve tokens
    approveTokens(users.taker1, address(ghostBook), tokens, type(uint256).max);
    approveTokens(users.taker2, address(ghostBook), tokens, type(uint256).max);

    // Set up makers
    users.maker1.setKey(ol);
    users.maker1.provisionMgv(1 ether);
    users.maker2.setKey(ol);
    users.maker2.provisionMgv(1 ether);
  }

  function _estimateAerodromeTick(address inToken, address outToken, uint256 smallAmount) internal view returns (Tick) {
    // Create route for estimation
    IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
    routes[0] =
      IAerodromeRouter.Route({from: inToken, to: outToken, stable: IS_STABLE_POOL, factory: AERODROME_FACTORY});

    // Get expected output for a small amount to estimate current price
    uint256[] memory amounts = IAerodromeRouter(AERODROME_ROUTER).getAmountsOut(smallAmount, routes);

    // Calculate tick from the amounts
    return TickLib.tickFromVolumes(smallAmount, amounts[1]);
  }

  function test_GhostBook_only_mangrove_execution_aerodrome() public {
    uint256 amountToSell = 0.1 ether;
    // Create invalid module data (with zero address as factory)
    ModuleData memory invalidData = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(IS_STABLE_POOL, address(0), block.timestamp + 3600)
    });

    setupMarket(ol);
    Tick mgvTick = Tick.wrap(int256(1000));
    users.maker1.newOfferByTick(mgvTick, 5_000e6, 2 ** 18);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      ghostBook.marketOrderByTick(ol, mgvTick, amountToSell, invalidData);

    assertGt(takerGot, 0);
    assertGt(takerGave, 0);
  }

  function test_GhostBook_only_external_execution_aerodrome() public {
    // Test when Mangrove has no offers, should only execute on Aerodrome
    uint256 amountToSell = 0.1 ether;

    // Create valid module data
    uint256 deadline = block.timestamp + 3600;
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(IS_STABLE_POOL, AERODROME_FACTORY, deadline)
    });

    // Get current price from Aerodrome
    Tick spotTick = _estimateAerodromeTick(ol.inbound_tkn, ol.outbound_tkn, 0.001 ether);
    // Set max tick with some buffer to ensure execution
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 2000);

    console.log("Spot tick:", Tick.unwrap(spotTick));
    console.log("Max tick:", Tick.unwrap(maxTick));

    // Create empty market to make sure it's active
    setupMarket(ol);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    // Verify some tokens were swapped
    assertGt(takerGot, 0, "Should have received output tokens");
    assertGt(takerGave, 0, "Should have spent input tokens");
  }

  function test_GhostBook_price_limit_respected_aerodrome() public {
    // Test that max tick price limit is respected with Aerodrome
    uint256 amountToSell = 0.5 ether;

    uint256 deadline = block.timestamp + 3600;
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(IS_STABLE_POOL, AERODROME_FACTORY, deadline)
    });

    // Get current price from Aerodrome
    Tick spotTick = _estimateAerodromeTick(ol.inbound_tkn, ol.outbound_tkn, 0.001 ether);

    // Make market
    setupMarket(ol);
    // Add a small amount of liquidity to Mangrove for partial fill
    users.maker1.newOfferByTick(spotTick, 1e6, 2 ** 18);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, spotTick, amountToSell, data);

    // Should execute partial fill or small amount on Aerodrome
    assertLe(takerGave, amountToSell, "Should only partially fill the order");

    // If some tokens were traded, verify price was respected
    if (takerGot > 0 && takerGave > 0) {
      Tick executedTick = TickLib.tickFromVolumes(takerGave, takerGot);
      assertLe(Tick.unwrap(executedTick), Tick.unwrap(spotTick), "Executed price should respect max tick");
    }
  }

  function test_GhostBook_combined_liquidity_aerodrome() public {
    // Test using both Mangrove and Aerodrome liquidity
    uint256 amountToSell = 1 ether;

    uint256 deadline = block.timestamp + 3600;
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(IS_STABLE_POOL, AERODROME_FACTORY, deadline)
    });

    // Get current price from Aerodrome
    Tick spotTick = _estimateAerodromeTick(ol.inbound_tkn, ol.outbound_tkn, 0.001 ether);
    // Set max tick with moderate buffer
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 500);

    // Make market with better price than Aerodrome but limited liquidity
    setupMarket(ol);
    Tick betterTick = Tick.wrap(Tick.unwrap(spotTick) - 200); // Better price than spot

    // Add limited liquidity to Mangrove at better price
    users.maker1.newOfferByTick(betterTick, 10_000e6, 2 ** 18);

    // Record balances before swap
    uint256 takerWethBefore = WETH.balanceOf(users.taker1);
    uint256 takerUsdcBefore = USDC.balanceOf(users.taker1);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    // Verify balances after swap
    uint256 takerWethAfter = WETH.balanceOf(users.taker1);
    uint256 takerUsdcAfter = USDC.balanceOf(users.taker1);

    assertEq(takerWethBefore - takerWethAfter, takerGave, "WETH spent should match takerGave");
    assertEq(takerUsdcAfter - takerUsdcBefore, takerGot, "USDC received should match takerGot");

    // Should use all offered amount
    assertEq(takerGave, amountToSell, "Should use entire sell amount");
    assertGt(takerGot, 0, "Should receive tokens");
  }

  function test_GhostBook_module_whitelist_aerodrome() public {
    address newModule = address(0x123);

    // Try to use non-whitelisted module
    ModuleData memory invalidData = ModuleData({
      module: IExternalSwapModule(newModule),
      data: abi.encode(IS_STABLE_POOL, AERODROME_FACTORY, block.timestamp + 3600)
    });

    vm.expectRevert(); // Should revert with ModuleNotWhitelisted
    ghostBook.marketOrderByTick(ol, Tick.wrap(0), 1 ether, invalidData);

    // Whitelist the module
    vm.prank(ghostBook.owner());
    ghostBook.whitelistModule(newModule);

    // Verify it's whitelisted
    assertTrue(ghostBook.whitelistedModules(IExternalSwapModule(newModule)));
  }
}
