// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest, BaseTest, console} from "../../base/BaseMangroveTest.t.sol";
import {BaseBalancerV1SwapperTest} from "../../base/modules/BaseBalancerV1SwapperTest.t.sol";
import {BalancerV1Swapper, ISwapOperations} from "src/modules/BalancerV1Swapper.sol";
import {MangroveGhostBook, ModuleData} from "src/MangroveGhostBook.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MangroveGhostBookBalancerV1Test is BaseMangroveTest, BaseBalancerV1SwapperTest {
  MangroveGhostBook public ghostBook;
  OLKey public ol;

  function setUp() public override(BaseMangroveTest, BaseBalancerV1SwapperTest) {
    chain = ForkChain.SEI;
    tokens.push(jUSDv1_SEI);
    tokens.push(jTSLAv1_SEI);
    super.setUp();

    // Set up OLKey for the market
    ol = OLKey({outbound_tkn: address(jTSLAv1_SEI), inbound_tkn: address(jUSDv1_SEI), tickSpacing: 1});

    // Deploy GhostBook and BalancerV1Swapper
    ghostBook = new MangroveGhostBook(address(mgv));
    deployBalancerV1Swapper(address(ghostBook));
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

  function _estimateBalancerV1Tick(address inToken, address outToken, uint256 amount) internal view returns (Tick) {
    // Create path for estimation
    address[] memory path = new address[](2);
    path[0] = inToken;
    path[1] = outToken;

    // Get spot price from pool
    (ISwapOperations.SwapAmount[] memory amounts,) =
      ISwapOperations(SWAP_OPERATIONS_JELLYSWAP).getAmountsOut(amount, path);
    uint256 amountOut = amounts[1].amount;

    // Calculate the current tick and add a large buffer
    Tick spotTick = TickLib.tickFromVolumes(amount, amountOut);

    return spotTick;
  }

  function test_GhostBook_only_mangrove_execution_BalancerV1() public {
    uint256 amountToSell = 1 ether;
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

  function test_GhostBook_only_external_execution_BalancerV1() public {
    // Test when Mangrove has no offers, should only execute on BalancerV1
    uint256 amountToSell = 1 ether;

    // Create valid module data
    uint256 deadline = block.timestamp + 3600;
    ModuleData memory data =
      ModuleData({module: IExternalSwapModule(address(swapper)), data: abi.encode(SWAP_OPERATIONS_JELLYSWAP, deadline)});

    // Get current price from BalancerV1
    Tick spotTick = _estimateBalancerV1Tick(ol.inbound_tkn, ol.outbound_tkn, amountToSell);
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

  function test_GhostBook_combined_liquidity_BalancerV1() public {
    // Test using both Mangrove and BalancerV1 liquidity
    uint256 amountToSell = 1 ether;

    uint256 deadline = block.timestamp + 3600;
    ModuleData memory data =
      ModuleData({module: IExternalSwapModule(address(swapper)), data: abi.encode(SWAP_OPERATIONS_JELLYSWAP, deadline)});

    // Get current price from BalancerV1
    Tick spotTick = _estimateBalancerV1Tick(ol.inbound_tkn, ol.outbound_tkn, amountToSell);
    // Set max tick with moderate buffer
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 500);

    // Make market with better price than BalancerV1 but limited liquidity
    setupMarket(ol);
    Tick betterTick = Tick.wrap(Tick.unwrap(spotTick) - 200); // Better price than spot

    // Add limited liquidity to Mangrove at better price
    users.maker1.newOfferByTick(betterTick, 10_000e6, 2 ** 18);

    // Record balances before swap
    uint256 takerTslaBefore = jTSLAv1_SEI.balanceOf(users.taker1);
    uint256 takerJUSDBefore = jUSDv1_SEI.balanceOf(users.taker1);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    // Verify balances after swap
    uint256 takerTslaAfter = jTSLAv1_SEI.balanceOf(users.taker1);
    uint256 takerJUSDAfter = jUSDv1_SEI.balanceOf(users.taker1);

    assertEq(takerJUSDBefore - takerJUSDAfter, takerGave);
    assertEq(takerTslaAfter - takerTslaBefore, takerGot);
  }
}
