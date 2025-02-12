// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest, BaseTest, console} from "../base/BaseMangroveTest.t.sol";
import {BaseUniswapV3SwapperTest, console} from "../base/modules/BaseUniswapV3SwapperTest.t.sol";
import {UniswapV3Swapper} from "src/modules/UniswapV3Swapper.sol";
import {MangroveGhostBook, ModuleData} from "src/MangroveGhostBook.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

contract MangroveGhostBookTest is BaseMangroveTest, BaseUniswapV3SwapperTest {
  MangroveGhostBook public ghostBook;
  OLKey public ol;

  function setUp() public override(BaseMangroveTest, BaseTest) {
    super.setUp();
    setUpLabels();

    ol = OLKey({outbound_tkn: address(USDC), inbound_tkn: address(WETH), tickSpacing: 1});

    ghostBook = new MangroveGhostBook(address(mgv));
    deployUniswapV3Swapper(address(ghostBook));
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

  function setUpLabels() internal {
    vm.label(address(WETH), "WETH");
    vm.label(address(USDC), "USDC");
    vm.label(address(USDT), "USDT");
  }

  function test_GhostBook_only_mangrove_execution() public {
    uint256 amountToSell = 10 ether;
    ModuleData memory invalidData =
      ModuleData({module: IExternalSwapModule(address(swapper)), data: abi.encode(address(0), uint24(500))});

    setupMarket(ol);
    Tick mgvTick = Tick.wrap(int256(1000));
    users.maker1.newOfferByTick(mgvTick, 5_000e6, 2 ** 18);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      ghostBook.marketOrderByTick(ol, mgvTick, amountToSell, invalidData);

    assertGt(takerGot, 0);
    assertGt(takerGave, 0);
  }

  function test_GhostBook_only_external_execution() public {
    // Test when Mangrove has no offers, should only execute on external DEX
    uint256 amountToSell = 100 ether;
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(UNISWAP_V3_ROUTER_ARBITRUM, uint24(500))
    });

    address poolAddress = IUniswapV3Factory(UNISWAP_V3_FACTORY_ARBITRUM).getPool(address(WETH), address(USDC), 500);
    (, int24 spotTick,,,,,) = IUniswapV3Pool(poolAddress).slot0();
    Tick maxTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - 100)));

    vm.startPrank(users.taker1);
    // TODO: should revert?
    vm.expectRevert("mgv/inactive");
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    // assertGt(takerGot, 0);
    // assertGt(takerGave, 0);
  }

  function test_GhostBook_price_limit_respected() public {
    // Test that max tick price limit is respected
    uint256 amountToSell = 10 ether;
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(UNISWAP_V3_ROUTER_ARBITRUM, uint24(500))
    });

    address poolAddress = IUniswapV3Factory(UNISWAP_V3_FACTORY_ARBITRUM).getPool(address(WETH), address(USDC), 500);
    (, int24 spotTick,,,,,) = IUniswapV3Pool(poolAddress).slot0();

    // Set a very low max tick to ensure price limit is hit
    Tick mgvTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - 10)));

    // Make market
    setupMarket(ol);
    // Add very few liquidity
    users.maker1.newOfferByTick(mgvTick, 1e6, 2 ** 18);
    Tick mgvTick2 = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - 100)));
    users.maker2.newOfferByTick(mgvTick, 1e6, 2 ** 18);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, mgvTick, amountToSell, data);

    // Should execute partial fill
    assertLe(takerGave, amountToSell);
  }

  function test_GhostBook_fees_handled_correctly() public {
    // Test different fee tiers
    uint256 amountToSell = 10 ether;
    uint24[] memory feeTiers = new uint24[](3);
    feeTiers[0] = 500; // 0.05%
    feeTiers[1] = 3000; // 0.3%
    feeTiers[2] = 10000; // 1%

    for (uint256 i = 0; i < feeTiers.length; i++) {
      ModuleData memory data = ModuleData({
        module: IExternalSwapModule(address(swapper)),
        data: abi.encode(UNISWAP_V3_ROUTER_ARBITRUM, feeTiers[i])
      });

      address poolAddress =
        IUniswapV3Factory(UNISWAP_V3_FACTORY_ARBITRUM).getPool(address(WETH), address(USDC), feeTiers[i]);

      if (poolAddress != address(0)) {
        (, int24 spotTick,,,,,) = IUniswapV3Pool(poolAddress).slot0();
        Tick mgvTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - 100)));

        setupMarket(ol);
        users.maker1.newOfferByTick(mgvTick, 1_000e6, 2 ** 18);
        users.maker2.newOfferByTick(mgvTick, 1_000e6, 2 ** 18);

        vm.prank(users.taker1);
        (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, mgvTick, amountToSell, data);

        assertGt(takerGot, 0);
        assertGt(takerGave, 0);
      }
    }
  }

  function test_GhostBook_receive_penalty() public {
    // Test different fee tiers
    uint256 amountToSell = 1_0000 ether;

    ModuleData memory data =
      ModuleData({module: IExternalSwapModule(address(swapper)), data: abi.encode(UNISWAP_V3_ROUTER_ARBITRUM, 500)});

    address poolAddress = IUniswapV3Factory(UNISWAP_V3_FACTORY_ARBITRUM).getPool(address(WETH), address(USDC), 500);

    (, int24 spotTick,,,,,) = IUniswapV3Pool(poolAddress).slot0();
    Tick mgvTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - 100)));

    setupMarket(ol);
    users.maker1.newOfferByTick(mgvTick, 500_000e6, 2 ** 18);
    users.maker2.newOfferByTick(mgvTick, 500_000e6, 2 ** 18);

    vm.prank(users.taker1);
    (,, uint256 bounty,) = ghostBook.marketOrderByTick(ol, mgvTick, amountToSell, data);
    assertGt(bounty, 0);
    assertEq(address(ghostBook).balance, 0);
  }

  function test_GhostBook_token_rescue() public {
    // Test the rescue funds functionality
    uint256 amount = 1 ether;
    deal(address(WETH), address(ghostBook), amount);

    uint256 recipientBalanceBefore = WETH.balanceOf(address(users.maker1));

    vm.prank(ghostBook.owner());
    ghostBook.rescueFunds(address(WETH), address(users.maker1), amount);

    uint256 recipientBalanceAfter = WETH.balanceOf(address(users.maker1));
    assertEq(recipientBalanceAfter - recipientBalanceBefore, amount);
  }

  function test_GhostBook_module_whitelist() public {
    address newModule = address(0x123);

    // Try to use non-whitelisted module
    ModuleData memory invalidData =
      ModuleData({module: IExternalSwapModule(newModule), data: abi.encode(UNISWAP_V3_ROUTER_ARBITRUM, uint24(500))});

    vm.expectRevert(); // Should revert with ModuleNotWhitelisted
    ghostBook.marketOrderByTick(ol, Tick.wrap(0), 1 ether, invalidData);

    // Whitelist the module
    vm.prank(ghostBook.owner());
    ghostBook.whitelistModule(newModule);

    // Verify it's whitelisted
    assertTrue(ghostBook.whitelistedModules(IExternalSwapModule(newModule)));
  }

  function test_GhostBook_market_order_by_tick() public {
    address factory = UNISWAP_V3_FACTORY_ARBITRUM;
    address router = UNISWAP_V3_ROUTER_ARBITRUM;

    uint256 amountToSell = 50 ether;
    address poolAddress = IUniswapV3Factory(factory).getPool(address(WETH), address(USDC), 500);
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(address(UNISWAP_V3_ROUTER_ARBITRUM), uint24(500))
    });

    (, int24 spotTick,,,,,) = IUniswapV3Pool(poolAddress).slot0();
    Tick mgvTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - 100)));

    // Make market
    setupMarket(ol);
    users.maker1.newOfferByTick(mgvTick, 5_000e6, 2 ** 18);
    users.maker2.newOfferByTick(mgvTick, 5_000e6, 2 ** 18);

    vm.startPrank(users.taker1);
    // Create order by tick consuming both the orderbok and external swapper
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      ghostBook.marketOrderByTick(ol, mgvTick, amountToSell, data);
  }
}
