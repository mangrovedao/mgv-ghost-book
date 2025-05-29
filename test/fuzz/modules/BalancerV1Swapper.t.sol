// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseBalancerV1SwapperTest} from "../../base/modules/BaseBalancerV1SwapperTest.t.sol";
import {BalancerV1SwapperWrapper} from "../../helpers/mock/BalancerV1SwapperWrapper.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {ISwapOperations} from "src/interface/vendors/ISwapOperations.sol";

contract BalancerV1SwapperTest is BaseBalancerV1SwapperTest {
  address ghostBook = makeAddr("mgv-ghostbook");

  function setUp() public override {
    super.setUp();
    deployBalancerV1Swapper(address(ghostBook));
  }

  function testFuzz_BalancerV1Swapper_swap_external_limit_price(uint256 mgvTickDepeg) public {
    vm.assume(mgvTickDepeg < 10_000);
    uint256 amountToSell = 1 ether;

    deal(address(jUSDv1_SEI), address(swapper), amountToSell);

    OLKey memory ol = OLKey({
      outbound_tkn: address(jTSLAv1_SEI),
      inbound_tkn: address(jUSDv1_SEI),
      tickSpacing: 0 // irrelevant for the test
    });
    address[] memory path = new address[](2);
    path[0] = address(jUSDv1_SEI);
    path[1] = address(jTSLAv1_SEI);

    // Get the current spot price from Balancer pool
    (ISwapOperations.SwapAmount[] memory amounts,) = ISwapOperations(SWAP_OPERATIONS).getAmountsOut(amountToSell, path);
    Tick realSpotTick = TickLib.tickFromVolumes(amountToSell, amounts[1].amount);

    // Then set max tick based on this real execution price
    Tick maxTick = Tick.wrap(Tick.unwrap(realSpotTick) + int256(mgvTickDepeg));

    uint256 tokenInBalanceBefore = IERC20(jUSDv1_SEI).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(jTSLAv1_SEI).balanceOf(address(ghostBook));

    vm.prank(ghostBook);
    swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(SWAP_OPERATIONS, block.timestamp));

    uint256 tokenInBalanceAfter = IERC20(jUSDv1_SEI).balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = IERC20(jTSLAv1_SEI).balanceOf(address(ghostBook));

    assertGt(tokenOutBalanceAfter - tokenOutBalanceBefore, 0, "No tokens received");
    assertGt(tokenInBalanceBefore - tokenInBalanceAfter, 0, "No tokens spent");

    Tick executedTick =
      TickLib.tickFromVolumes(tokenInBalanceBefore - tokenInBalanceAfter, tokenOutBalanceAfter - tokenOutBalanceBefore);

    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }

  function testFuzz_BalancerV1Swapper_swap_varying_amounts(uint256 amountToSell) public {
    // Bound amount between 0.01 ETH and 10 ETH
    amountToSell = bound(amountToSell, 0.01 ether, 10 ether);

    deal(address(jUSDv1_SEI), address(swapper), amountToSell);

    OLKey memory ol = OLKey({outbound_tkn: address(jTSLAv1_SEI), inbound_tkn: address(jUSDv1_SEI), tickSpacing: 0});

    address[] memory path = new address[](2);
    path[0] = address(jUSDv1_SEI);
    path[1] = address(jTSLAv1_SEI);

    // Get spot price from pool
    (ISwapOperations.SwapAmount[] memory amounts,) = ISwapOperations(SWAP_OPERATIONS).getAmountsOut(amountToSell, path);
    uint256 spotPrice = amounts[1].amount;

    // Calculate the current tick and add a large buffer
    Tick spotTick = TickLib.tickFromVolumes(amountToSell, spotPrice);
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 2000); // Large buffer to ensure trade goes through

    uint256 tokenInBalanceBefore = IERC20(jUSDv1_SEI).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(jTSLAv1_SEI).balanceOf(address(ghostBook));

    vm.prank(ghostBook);
    swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(SWAP_OPERATIONS, block.timestamp));

    uint256 tokenInBalanceAfter = IERC20(jUSDv1_SEI).balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = IERC20(jTSLAv1_SEI).balanceOf(address(ghostBook));

    uint256 amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
    uint256 amountIn = tokenInBalanceBefore - tokenInBalanceAfter;

    assertGt(amountOut, 0, "No tokens received");
    assertGt(amountIn, 0, "No tokens spent");

    // Test that the executed price is within bounds
    Tick executedTick = TickLib.tickFromVolumes(amountIn, amountOut);
    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }
}
