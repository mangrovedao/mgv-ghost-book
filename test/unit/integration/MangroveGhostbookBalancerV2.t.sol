// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest, BaseTest, console} from "../../base/BaseMangroveTest.t.sol";
import {BaseBalancerV2SwapperTest} from "../../base/modules/BaseBalancerV2SwapperTest.t.sol";
import {BalancerV2Swapper} from "src/modules/BalancerV2Swapper.sol";
import {IBalancerV2Vault} from "src/interface/vendors/IBalancerV2Vault.sol";
import {BalancerV2SwapperWrapper} from "../../helpers/mock/BalancerV2SwapperWrapper.sol";
import {MangroveGhostBook, ModuleData} from "src/MangroveGhostBook.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MangroveGhostBookBalancerV2Test is BaseMangroveTest, BaseBalancerV2SwapperTest {
  MangroveGhostBook public ghostBook;
  OLKey public ol;

  function setUp() public override(BaseMangroveTest, BaseBalancerV2SwapperTest) {
    chain = ForkChain.SEI;
    super.setUp();

    // Set up OLKey for the market
    ol = OLKey({outbound_tkn: address(STETH), inbound_tkn: address(WETH), tickSpacing: 1});

    // Deploy GhostBook and BalancerV2Swapper
    ghostBook = new MangroveGhostBook(address(mgv));
    deployBalancerV2Swapper(address(ghostBook));
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

  function _estimateBalancerV2Tick(address inToken, address outToken, uint256 smallAmount) internal returns (Tick) {
    // Create sorted assets array
    address[] memory assets = _createSortedAssets(inToken, outToken);
    (uint256 assetInIndex, uint256 assetOutIndex) = _getAssetIndices(assets, inToken, outToken);

    // Prepare SwapParams for calculateAmountOut
    BalancerV2Swapper.SwapParams memory swapParams = BalancerV2Swapper.SwapParams({
      vault: JELLYSWAP_VAULT,
      poolId: WETH_STETH_POOL_ID,
      deadline: block.timestamp + 3600,
      inToken: inToken,
      outToken: outToken,
      actualAmountToSell: smallAmount,
      maxTick: Tick.wrap(type(int24).max) // Not used in calculation
    });

    // Prepare AssetConfig for calculateAmountOut
    BalancerV2Swapper.AssetConfig memory assetConfig =
      BalancerV2Swapper.AssetConfig({assets: assets, assetInIndex: assetInIndex, assetOutIndex: assetOutIndex});

    // Get expected output using wrapper
    uint256 expectedOutput = BalancerV2SwapperWrapper(address(swapper)).calculateAmountOut(swapParams, assetConfig);

    // Calculate tick from the amounts
    return TickLib.tickFromVolumes(smallAmount, expectedOutput);
  }

  function _createSortedAssets(address token0, address token1) internal pure returns (address[] memory assets) {
    assets = new address[](2);
    if (token0 < token1) {
      assets[0] = token0;
      assets[1] = token1;
    } else {
      assets[0] = token1;
      assets[1] = token0;
    }
  }

  function _getAssetIndices(address[] memory assets, address inToken, address outToken)
    internal
    pure
    returns (uint256 assetInIndex, uint256 assetOutIndex)
  {
    for (uint256 i = 0; i < assets.length; i++) {
      if (assets[i] == inToken) {
        assetInIndex = i;
      } else if (assets[i] == outToken) {
        assetOutIndex = i;
      }
    }
  }

  function test_GhostBook_only_mangrove_execution_BalancerV2() public {
    uint256 amountToSell = 0.1 ether;
    
    // Get current price from BalancerV2 to set a very restrictive max tick
    Tick spotTick = _estimateBalancerV2Tick(ol.inbound_tkn, ol.outbound_tkn, 0.001 ether);
    // Set max tick much worse than current spot price to make external swap fail
    Tick restrictiveMaxTick = Tick.wrap(Tick.unwrap(spotTick) - 5000); // Much worse price
    
    // Create valid module data but with restrictive price that will cause external swap to fail
    ModuleData memory restrictiveData = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(JELLYSWAP_VAULT, WETH_STETH_POOL_ID, block.timestamp + 3600)
    });

    setupMarket(ol);
    // Set Mangrove offer at better price than the restrictive max tick
    Tick mgvTick = Tick.wrap(Tick.unwrap(restrictiveMaxTick) - 100); // Better than restrictive price
    users.maker1.newOfferByTick(mgvTick, 5_000e6, 2 ** 18);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      ghostBook.marketOrderByTick(ol, restrictiveMaxTick, amountToSell, restrictiveData);

    assertGt(takerGot, 0);
    assertGt(takerGave, 0);

  }

  function test_GhostBook_only_external_execution_BalancerV2() public {
    // Test when Mangrove has no offers, should only execute on BalancerV2
    uint256 amountToSell = 0.1 ether;

    // Create valid module data
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(JELLYSWAP_VAULT, WETH_STETH_POOL_ID, block.timestamp + 3600)
    });

    // Get current price from BalancerV2 using wrapper
    Tick spotTick = _estimateBalancerV2Tick(ol.inbound_tkn, ol.outbound_tkn, 0.001 ether);
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

  function test_GhostBook_combined_liquidity_BalancerV2() public {
    // Test using both Mangrove and BalancerV2 liquidity
    uint256 amountToSell = 1 ether;

    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(JELLYSWAP_VAULT, WETH_STETH_POOL_ID, block.timestamp + 3600)
    });

    // Get current price from BalancerV2 using wrapper
    Tick spotTick = _estimateBalancerV2Tick(ol.inbound_tkn, ol.outbound_tkn, 0.001 ether);
    // Set max tick with moderate buffer
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 500);

    // Make market with better price than BalancerV2 but limited liquidity
    setupMarket(ol);
    Tick betterTick = Tick.wrap(Tick.unwrap(spotTick) - 200); // Better price than spot

    // Add limited liquidity to Mangrove at better price
    users.maker1.newOfferByTick(betterTick, 10_000e6, 2 ** 18);

    // Record balances before swap
    uint256 takerWETHBefore = WETH.balanceOf(users.taker1);
    uint256 takerSTETHBefore = STETH.balanceOf(users.taker1);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    // Verify balances after swap
    uint256 takerWETHAfter = WETH.balanceOf(users.taker1);
    uint256 takerSTETHAfter = STETH.balanceOf(users.taker1);

    assertEq(takerWETHBefore - takerWETHAfter, takerGave);
    assertEq(takerSTETHAfter - takerSTETHBefore, takerGot);
  }
}
