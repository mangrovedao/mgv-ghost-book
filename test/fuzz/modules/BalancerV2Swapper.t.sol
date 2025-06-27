// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseBalancerV2SwapperTest, console} from "../../base/modules/BaseBalancerV2SwapperTest.t.sol";
import {BalancerV2SwapperWrapper, BalancerV2Swapper} from "../../helpers/mock/BalancerV2SwapperWrapper.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";

contract BalancerV2SwapperTest is BaseBalancerV2SwapperTest {
  address ghostBook = makeAddr("mgv-ghostbook");

  function setUp() public override {
    super.setUp();
    deployBalancerV2Swapper(address(ghostBook));
  }

  function testFuzz_BalancerV2Swapper_swap_external_limit_price(uint256 mgvTickDepeg) public {
    vm.assume(mgvTickDepeg < 10_000);

    deal(address(WETH), address(swapper), 1 ether);

    // Calculate expected output and derive maxTick
    Tick maxTick = _calculateMaxTick(1 ether / 10, mgvTickDepeg);

    // Record initial balances
    uint256 tokenInBalanceBefore = IERC20(WETH).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(STETH).balanceOf(address(ghostBook));

    // Execute swap
    vm.prank(ghostBook);
    swapper.externalSwap(
      OLKey({outbound_tkn: address(STETH), inbound_tkn: address(WETH), tickSpacing: 0}),
      1 ether,
      maxTick,
      abi.encode(JELLYSWAP_VAULT, WETH_STETH_POOL_ID, block.timestamp + 3600)
    );

    // Verify results
    _verifySwapResults(tokenInBalanceBefore, tokenOutBalanceBefore, maxTick);
  }

  function testFuzz_BalancerV2Swapper_swap_varying_amounts(uint256 amountToSell) public {
    amountToSell = bound(amountToSell, 0.01 ether, 10 ether);

    deal(address(WETH), address(swapper), amountToSell);

    // Calculate maxTick with large buffer
    Tick maxTick = _calculateMaxTickWithBuffer(amountToSell / 10);

    // Record initial balances
    uint256 tokenInBalanceBefore = IERC20(WETH).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(STETH).balanceOf(address(ghostBook));

    // Execute swap
    vm.prank(ghostBook);
    swapper.externalSwap(
      OLKey({outbound_tkn: address(STETH), inbound_tkn: address(WETH), tickSpacing: 0}),
      amountToSell,
      maxTick,
      abi.encode(JELLYSWAP_VAULT, WETH_STETH_POOL_ID, block.timestamp + 3600)
    );

    // Verify results
    _verifyVaryingAmountResults(tokenInBalanceBefore, tokenOutBalanceBefore, maxTick);
  }

  function _calculateMaxTick(uint256 testAmount, uint256 mgvTickDepeg) internal returns (Tick maxTick) {
    uint256 expectedOutput = BalancerV2SwapperWrapper(address(swapper)).calculateAmountOut(
      BalancerV2Swapper.SwapParams({
        vault: JELLYSWAP_VAULT,
        poolId: WETH_STETH_POOL_ID,
        deadline: block.timestamp + 3600,
        inToken: address(WETH),
        outToken: address(STETH),
        actualAmountToSell: testAmount,
        maxTick: Tick.wrap(type(int24).max)
      }),
      BalancerV2Swapper.AssetConfig({assets: _createAssetArray(), assetInIndex: 0, assetOutIndex: 1})
    );

    Tick realSpotTick = TickLib.tickFromVolumes(testAmount, expectedOutput);
    maxTick = Tick.wrap(Tick.unwrap(realSpotTick) + int256(mgvTickDepeg));
  }

  function _calculateMaxTickWithBuffer(uint256 testAmount) internal returns (Tick maxTick) {
    uint256 expectedOutput = BalancerV2SwapperWrapper(address(swapper)).calculateAmountOut(
      BalancerV2Swapper.SwapParams({
        vault: JELLYSWAP_VAULT,
        poolId: WETH_STETH_POOL_ID,
        deadline: block.timestamp + 3600,
        inToken: address(WETH),
        outToken: address(STETH),
        actualAmountToSell: testAmount,
        maxTick: Tick.wrap(type(int24).max)
      }),
      BalancerV2Swapper.AssetConfig({
        assets: _createSortedAssetArray(),
        assetInIndex: address(WETH) < address(STETH) ? 0 : 1,
        assetOutIndex: address(WETH) < address(STETH) ? 1 : 0
      })
    );

    Tick spotTick = TickLib.tickFromVolumes(testAmount, expectedOutput);
    maxTick = Tick.wrap(Tick.unwrap(spotTick) + 2000);
  }

  function _createAssetArray() internal view returns (address[] memory assets) {
    assets = new address[](2);
    assets[0] = address(WETH);
    assets[1] = address(STETH);
  }

  function _createSortedAssetArray() internal view returns (address[] memory assets) {
    assets = new address[](2);
    if (address(WETH) < address(STETH)) {
      assets[0] = address(WETH);
      assets[1] = address(STETH);
    } else {
      assets[0] = address(STETH);
      assets[1] = address(WETH);
    }
  }

  function _verifySwapResults(uint256 tokenInBalanceBefore, uint256 tokenOutBalanceBefore, Tick maxTick) internal {
    uint256 tokenInBalanceAfter = IERC20(WETH).balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = IERC20(STETH).balanceOf(address(ghostBook));

    assertNotEq(tokenOutBalanceAfter - tokenOutBalanceBefore, 0, "No tokens received");
    assertNotEq(tokenInBalanceBefore - tokenInBalanceAfter, 0, "No tokens spent");

    Tick executedTick =
      TickLib.tickFromVolumes(tokenInBalanceBefore - tokenInBalanceAfter, tokenOutBalanceAfter - tokenOutBalanceBefore);

    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }

  function _verifyVaryingAmountResults(uint256 tokenInBalanceBefore, uint256 tokenOutBalanceBefore, Tick maxTick)
    internal
  {
    uint256 tokenInBalanceAfter = IERC20(WETH).balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = IERC20(STETH).balanceOf(address(ghostBook));

    uint256 amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
    uint256 amountIn = tokenInBalanceBefore - tokenInBalanceAfter;

    assertGt(amountOut, 0, "No tokens received");
    assertGt(amountIn, 0, "No tokens spent");

    Tick executedTick = TickLib.tickFromVolumes(amountIn, amountOut);
    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }
}
