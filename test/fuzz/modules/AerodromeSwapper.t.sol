// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseAerodromeSwapperTest, console} from "../../base/modules/BaseAerodromeSwapperTest.t.sol";
import {AerodromeSwapperWrapper, AerodromeSwapper} from "../../helpers/mock/AerodromeSwapperWrapper.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IAerodromeRouter} from "src/interface/vendors/IAerodrome.sol";

contract AerodromeSwapperTest is BaseAerodromeSwapperTest {
  address ghostBook = makeAddr("mgv-ghostbook");

  // Base chain constants
  bool constant IS_STABLE_POOL = false;

  function setUp() public override {
    super.setUp();
    deployAerodromeSwapper(ghostBook, AERODROME_ROUTER);
    // deal(address(WETH), ghostBook, 10_000 ether);
  }

  function testFuzz_AerodromeSwapper_swap_external_limit_price(uint256 mgvTickDepeg) public {
    vm.assume(mgvTickDepeg < 10_000);
    uint256 amountToSell = 1 ether;

    deal(address(WETH), address(swapper), amountToSell);

    OLKey memory ol = OLKey({
      outbound_tkn: address(USDC),
      inbound_tkn: address(WETH),
      tickSpacing: 0 // irrelevant for the test
    });

    // First check what tick the router would give for a small amount
    IAerodromeRouter.Route[] memory testRoutes = new IAerodromeRouter.Route[](1);
    testRoutes[0] = IAerodromeRouter.Route({
      from: address(WETH),
      to: address(USDC),
      stable: IS_STABLE_POOL,
      factory: AERODROME_FACTORY
    });

    uint256 testAmount = amountToSell / 10; // calculate execution price for a smaller amount, depending on the max tick gap it will swap it all or not
    uint256[] memory testAmounts = IAerodromeRouter(AERODROME_ROUTER).getAmountsOut(testAmount, testRoutes);
    Tick realSpotTick = TickLib.tickFromVolumes(testAmount, testAmounts[1]);

    // Then set max tick based on this real execution price
    Tick maxTick = Tick.wrap(Tick.unwrap(realSpotTick) + int256(mgvTickDepeg));

    uint256 tokenInBalanceBefore = IERC20(WETH).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(USDC).balanceOf(address(ghostBook));

    uint256 deadline = block.timestamp + 3600; // 1 hour from now

    vm.prank(ghostBook);
    swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(IS_STABLE_POOL, AERODROME_FACTORY, deadline));

    uint256 tokenInBalanceAfter = IERC20(WETH).balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = IERC20(USDC).balanceOf(address(ghostBook));

    assertNotEq(tokenOutBalanceAfter - tokenOutBalanceBefore, 0, "No tokens received");
    assertNotEq(tokenInBalanceBefore - tokenInBalanceAfter, 0, "No tokens spent");

    Tick executedTick =
      TickLib.tickFromVolumes(tokenInBalanceBefore - tokenInBalanceAfter, tokenOutBalanceAfter - tokenOutBalanceBefore);

    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }

  function testFuzz_AerodromeSwapper_swap_varying_amounts(uint256 amountToSell) public {
    // Bound amount between 0.01 ETH and 10 ETH
    amountToSell = bound(amountToSell, 0.01 ether, 10 ether);

    deal(address(WETH), address(swapper), amountToSell);

    OLKey memory ol = OLKey({outbound_tkn: address(USDC), inbound_tkn: address(WETH), tickSpacing: 0});

    // Get current reserves from Aerodrome pool
    (uint256 reserveWETH, uint256 reserveUSDC) =
      IAerodromeRouter(AERODROME_ROUTER).getReserves(address(WETH), address(USDC), IS_STABLE_POOL, AERODROME_FACTORY);

    // Calculate the current tick from reserves and add a large buffer
    Tick spotTick = _calculateTickFromReserves(reserveWETH, reserveUSDC);
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) + 2000); // Large buffer to ensure trade goes through

    uint256 tokenInBalanceBefore = IERC20(WETH).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(USDC).balanceOf(address(ghostBook));

    uint256 deadline = block.timestamp + 3600;

    vm.prank(ghostBook);
    swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(IS_STABLE_POOL, AERODROME_FACTORY, deadline));

    uint256 tokenInBalanceAfter = IERC20(WETH).balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = IERC20(USDC).balanceOf(address(ghostBook));

    uint256 amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
    uint256 amountIn = tokenInBalanceBefore - tokenInBalanceAfter;

    assertGt(amountOut, 0, "No tokens received");
    assertGt(amountIn, 0, "No tokens spent");

    // Test that the executed price is within bounds
    Tick executedTick = TickLib.tickFromVolumes(amountIn, amountOut);
    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }
}
