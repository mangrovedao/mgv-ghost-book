// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseUniswapV2SwapperTest, console} from "../../base/modules/BaseUniswapV2SwapperTest.t.sol";
import {UniswapV2SwapperWrapper, UniswapV2Swapper} from "../../helpers/mock/UniswapV2SwapperWrapper.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IUniswapV2Router02} from "src/interface/vendors/IUniswapV2Router02.sol";

contract UniswapV2SwapperTest is BaseUniswapV2SwapperTest {
  address ghostBook = makeAddr("mgv-ghostbook");

  function setUp() public override {
    super.setUp();
    deployUniswapV2Swapper(address(ghostBook));
  }

  function testFuzz_UniswapV2Swapper_swap_external_limit_price(uint256 mgvTickDepeg) public {
    vm.assume(mgvTickDepeg < 10_000);
    uint256 amountToSell = 1 ether;

    deal(address(WETH), address(swapper), amountToSell);

    OLKey memory ol = OLKey({
      outbound_tkn: address(USDT),
      inbound_tkn: address(WETH),
      tickSpacing: 0 // irrelevant for the test
    });

    // First check what tick the router would give for a small amount
    address[] memory testPath = new address[](2);
    testPath[0] = address(WETH);
    testPath[1] = address(USDT);

    uint256 testAmount = amountToSell / 10; // calculate execution price for a smaller amount, depending on the max tick gap it will swap it all or not
    uint256[] memory testAmounts = IUniswapV2Router02(DRAGONSWAP_ROUTER).getAmountsOut(testAmount, testPath);
    Tick realSpotTick = TickLib.tickFromVolumes(testAmount, testAmounts[1]);

    // Then set max tick based on this real execution price
    Tick maxTick = Tick.wrap(Tick.unwrap(realSpotTick) + int256(mgvTickDepeg));

    uint256 tokenInBalanceBefore = IERC20(WETH).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(USDT).balanceOf(address(ghostBook));

    uint256 deadline = block.timestamp + 3600; // 1 hour from now

    vm.prank(ghostBook);
    swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(DRAGONSWAP_ROUTER, deadline));

    uint256 tokenInBalanceAfter = IERC20(WETH).balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = IERC20(USDT).balanceOf(address(ghostBook));

    assertNotEq(tokenOutBalanceAfter - tokenOutBalanceBefore, 0, "No tokens received");
    assertNotEq(tokenInBalanceBefore - tokenInBalanceAfter, 0, "No tokens spent");

    Tick executedTick =
      TickLib.tickFromVolumes(tokenInBalanceBefore - tokenInBalanceAfter, tokenOutBalanceAfter - tokenOutBalanceBefore);

    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }

  function testFuzz_UniswapV2Swapper_swap_varying_amounts(uint256 amountToSell) public {
    // Bound amount between 0.01 ETH and 10 ETH
    amountToSell = bound(amountToSell, 0.01 ether, 10 ether);

    deal(address(WETH), address(swapper), amountToSell);

    OLKey memory ol = OLKey({outbound_tkn: address(USDT), inbound_tkn: address(WETH), tickSpacing: 0});

    // Get path for swap
    address[] memory path = new address[](2);
    path[0] = address(WETH);
    path[1] = address(USDT);

    // Get amounts out to calculate current price
    uint256[] memory amounts = IUniswapV2Router02(DRAGONSWAP_ROUTER).getAmountsOut(amountToSell / 10, path);

    // Calculate the current tick and add a large buffer
    Tick spotTick = TickLib.tickFromVolumes(amountToSell, amounts[1]);
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 2000); // Large buffer to ensure trade goes through

    uint256 tokenInBalanceBefore = IERC20(WETH).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(USDT).balanceOf(address(ghostBook));

    uint256 deadline = block.timestamp + 3600;

    vm.prank(ghostBook);
    swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(DRAGONSWAP_ROUTER, deadline));

    uint256 tokenInBalanceAfter = IERC20(WETH).balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = IERC20(USDT).balanceOf(address(ghostBook));

    uint256 amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
    uint256 amountIn = tokenInBalanceBefore - tokenInBalanceAfter;

    assertGt(amountOut, 0, "No tokens received");
    assertGt(amountIn, 0, "No tokens spent");

    // Test that the executed price is within bounds
    Tick executedTick = TickLib.tickFromVolumes(amountIn, amountOut);
    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }
}
