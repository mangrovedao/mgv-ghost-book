// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest, BaseTest, console} from "../base/BaseMangroveTest.t.sol";
import {BaseUniswapV3SwapperTest, console} from "../base/modules/BaseUniswapV3SwapperTest.t.sol";
import {UniswapV3Swapper} from "src/modules/UniswapV3Swapper.sol";
import {MangroveGhostBook, Pool} from "src/MangroveGhostBook.sol";
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

    deployUniswapV3Swapper();
    ghostBook = new MangroveGhostBook(address(mgv));
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

  function test_GhostBook_market_order_by_tick() public {
    address factory = UNISWAP_V3_FACTORY_ARBITRUM;
    address router = UNISWAP_V3_ROUTER_ARBITRUM;

    swapper.setRouterForFactory(factory, router);

    uint256 amountToSell = 5 ether;
    address poolAddress = IUniswapV3Factory(factory).getPool(address(WETH), address(USDC), 500);
    Pool memory pool = Pool({pool: poolAddress, externalSwapModule: IExternalSwapModule(address(swapper)), data: ""});

    (, int24 spotTick,,,,,) = IUniswapV3Pool(poolAddress).slot0();
    Tick maxTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick)));

    // Make market
    setupMarket(ol);
    users.maker1.newOfferByTick(maxTick, amountToSell / 2, 100);
    maxTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick + 2)));
    users.maker2.newOfferByTick(maxTick, amountToSell / 2, 100);

    vm.startPrank(users.taker1);
    // Create order by tick consuming both the orderbok and external swapper
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      ghostBook.marketOrderByTick(ol, maxTick, amountToSell, pool);
    console.log("takerGot :", takerGot);
    console.log("takerGave:", takerGave);
    console.log("bounty:", bounty);
    console.log("feePaid:", feePaid);
  }
}
