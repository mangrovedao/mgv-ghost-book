// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest, BaseTest, console} from "../../base/BaseMangroveTest.t.sol";
import {BaseUniswapV2SwapperTest} from "../../base/modules/BaseUniswapV2SwapperTest.t.sol";
import {UniswapV2Swapper, IUniswapV2Router02} from "src/modules/UniswapV2Swapper.sol";
import {MangroveGhostBook, ModuleData} from "src/MangroveGhostBook.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MangroveGhostBookUniswapV2Test is BaseMangroveTest, BaseUniswapV2SwapperTest {
  MangroveGhostBook public ghostBook;
  OLKey public ol;

  function setUp() public override(BaseMangroveTest, BaseUniswapV2SwapperTest) {
    chain = ForkChain.SEI;
    super.setUp();

    // Set up OLKey for the market
    ol = OLKey({outbound_tkn: address(USDT), inbound_tkn: address(WETH), tickSpacing: 1});

    // Deploy GhostBook and UniswapV2Swapper
    ghostBook = new MangroveGhostBook(address(mgv));
    deployUniswapV2Swapper(address(ghostBook));
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

  function _estimateUniswapV2Tick(address inToken, address outToken, uint256 smallAmount) internal view returns (Tick) {
    // Create path for estimation
    address[] memory path = new address[](2);
    path[0] = inToken;
    path[1] = outToken;

    // Get expected output for a small amount to estimate current price
    uint256[] memory amounts = IUniswapV2Router02(DRAGONSWAP_ROUTER).getAmountsOut(smallAmount, path);

    // Calculate tick from the amounts
    return TickLib.tickFromVolumes(smallAmount, amounts[1]);
  }

  function test_GhostBook_only_mangrove_execution_uniswapv2() public {
    uint256 amountToSell = 0.1 ether;
    // Create invalid module data (with empty router)
    ModuleData memory invalidData =
      ModuleData({module: IExternalSwapModule(address(swapper)), data: abi.encode(address(0), block.timestamp + 3600)});

    setupMarket(ol);
    Tick mgvTick = Tick.wrap(int256(1000));
    users.maker1.newOfferByTick(mgvTick, 5_000e6, 2 ** 18);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      ghostBook.marketOrderByTick(ol, mgvTick, amountToSell, invalidData);

    assertGt(takerGot, 0);
    assertGt(takerGave, 0);
  }

  function test_GhostBook_only_external_execution_uniswapv2() public {
    // Test when Mangrove has no offers, should only execute on UniswapV2
    uint256 amountToSell = 0.1 ether;

    // Create valid module data
    uint256 deadline = block.timestamp + 3600;
    ModuleData memory data =
      ModuleData({module: IExternalSwapModule(address(swapper)), data: abi.encode(DRAGONSWAP_ROUTER, deadline)});

    // Get current price from UniswapV2
    Tick spotTick = _estimateUniswapV2Tick(ol.inbound_tkn, ol.outbound_tkn, 0.001 ether);
    // Set max tick with some buffer to ensure execution
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 2000);

    // Create empty market to make sure it's active
    setupMarket(ol);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    // Verify some tokens were swapped
    assertGt(takerGot, 0);
    assertGt(takerGave, 0);
  }

  function test_GhostBook_combined_liquidity_uniswapv2() public {
    // Test using both Mangrove and UniswapV2 liquidity
    uint256 amountToSell = 1 ether;

    uint256 deadline = block.timestamp + 3600;
    ModuleData memory data =
      ModuleData({module: IExternalSwapModule(address(swapper)), data: abi.encode(DRAGONSWAP_ROUTER, deadline)});

    // Get current price from UniswapV2
    Tick spotTick = _estimateUniswapV2Tick(ol.inbound_tkn, ol.outbound_tkn, 0.001 ether);
    // Set max tick with moderate buffer
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 500);

    // Make market with better price than UniswapV2 but limited liquidity
    setupMarket(ol);
    Tick betterTick = Tick.wrap(Tick.unwrap(spotTick) - 200); // Better price than spot

    // Add limited liquidity to Mangrove at better price
    users.maker1.newOfferByTick(betterTick, 10_000e6, 2 ** 18);

    // Record balances before swap
    uint256 takerWethBefore = WETH.balanceOf(users.taker1);
    uint256 takerUSDTBefore = USDT.balanceOf(users.taker1);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    // Verify balances after swap
    uint256 takerWethAfter = WETH.balanceOf(users.taker1);
    uint256 takerUSDTAfter = USDT.balanceOf(users.taker1);

    assertEq(takerWethBefore - takerWethAfter, takerGave);
    assertEq(takerUSDTAfter - takerUSDTBefore, takerGot);
  }
}
