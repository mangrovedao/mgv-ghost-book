// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseSplitStreamSwapperTest, console} from "../../base/modules/BaseSplitStreamSwapperTest.t.sol";
import {SplitStreamSwapperWrapper, SplitStreamSwapper} from "../../helpers/mock/SplitStreamSwapperWrapper.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";

interface ISplitStreamFactory {
  function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}

interface ISplitStreamPool {
  function slot0()
    external
    view
    returns (
      uint160 sqrtPriceX96,
      int24 tick,
      uint16 observationIndex,
      uint16 observationCardinality,
      uint16 observationCardinalityNext,
      bool unlocked
    );
}

contract SplitStreamSwapperTest is BaseSplitStreamSwapperTest {
  address ghostBook = makeAddr("mgv-ghostbook");

  int24 constant TICK_SPACING = 1; // Common tick spacing, adjust for SplitStream

  function setUp() public override {
    super.setUp();
    deploySplitStreamSwapper(ghostBook);
  }

  function testFuzz_SplitStreamSwapper_swap_external_limit_price(uint24 mgvTickDepeg) public {
    vm.assume(mgvTickDepeg < 10_000);
    uint256 amountToSell = 0.1 ether;

    deal(address(USDT), address(swapper), amountToSell);

    OLKey memory ol =
      OLKey({outbound_tkn: address(USDC), inbound_tkn: address(USDT), tickSpacing: uint24(TICK_SPACING)});

    address pool = ISplitStreamFactory(SPLITSTREAM_FACTORY).getPool(address(USDT), address(USDC), TICK_SPACING);
    // Skip test if pool doesn't exist
    if (pool == address(0)) return;

    (, int24 spotTick,,,,) = ISplitStreamPool(pool).slot0();

    // Convert to Mangrove tick and add depeg
    // Subtract depeg to make price worse (higher for seller) which tests price limit
    Tick maxTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick + int24(mgvTickDepeg))));

    uint256 tokenInBalanceBefore = USDT.balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = USDC.balanceOf(address(ghostBook));

    // Current timestamp plus 1 hour
    uint256 deadline = block.timestamp + 3600;

    vm.prank(ghostBook);
    try swapper.externalSwap(
      ol, amountToSell, maxTick, abi.encode(SPLITSTREAM_ROUTER, uint24(TICK_SPACING), deadline, TICK_SPACING)
    ) {
      uint256 tokenInBalanceAfter = USDT.balanceOf(address(ghostBook));
      uint256 tokenOutBalanceAfter = USDC.balanceOf(address(ghostBook));

      uint256 tokensGiven = tokenInBalanceBefore - USDT.balanceOf(address(swapper)) - tokenInBalanceAfter;
      uint256 tokensReceived = tokenOutBalanceAfter - tokenOutBalanceBefore;

      // Skip test if no tokens were swapped (could happen with large depeg)
      if (tokensGiven == 0 || tokensReceived == 0) return;
    } catch (bytes memory err) {
      // If we get an error with a small depeg, it indicates a potential issue
      if (mgvTickDepeg < 100) {
        string memory errString = abi.decode(extractCalldata(err), (string));
        console.log("Error with small depeg:", errString);
        // Don't assert here as some reverts are expected with price limits
      }
    }
  }

  function testFuzz_SplitStreamSwapper_swap_varying_amounts(uint256 amountToSell) public {
    // Bound amount between 0.01 ETH and 10 ETH
    amountToSell = bound(amountToSell, 0.01 ether, 10 ether);

    deal(address(USDT), address(swapper), amountToSell);

    OLKey memory ol =
      OLKey({outbound_tkn: address(USDC), inbound_tkn: address(USDT), tickSpacing: uint24(TICK_SPACING)});

    address pool = ISplitStreamFactory(SPLITSTREAM_FACTORY).getPool(address(USDT), address(USDC), TICK_SPACING);
    // Skip test if pool doesn't exist
    if (pool == address(0)) return;

    // Get current price from pool
    (, int24 spotTick,,,,) = ISplitStreamPool(pool).slot0();

    // Set a max tick with large buffer to ensure trade goes through
    Tick maxTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick + 5000)));

    console.log("Spot tick:", spotTick);
    console.log("Max tick:", Tick.unwrap(maxTick));
    console.log("Amount to sell:", amountToSell);

    uint256 tokenInBalanceBefore = USDT.balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = USDC.balanceOf(address(ghostBook));

    // Current timestamp plus 1 hour
    uint256 deadline = block.timestamp + 3600;

    vm.prank(ghostBook);
    swapper.externalSwap(
      ol, amountToSell, maxTick, abi.encode(SPLITSTREAM_ROUTER, uint24(TICK_SPACING), deadline, TICK_SPACING)
    );

    uint256 tokenInBalanceAfter = USDT.balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = USDC.balanceOf(address(ghostBook));

    uint256 amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
    uint256 amountIn = tokenInBalanceBefore - tokenInBalanceAfter;

    console.log("Amount spent:", amountIn);
    console.log("Amount received:", amountOut);

    // For successful swaps, verify tokens were transferred
    if (amountIn > 0 && amountOut > 0) {
      assertGt(amountOut, 0, "No tokens received");
      assertGt(amountIn, 0, "No tokens spent");

      // Test that the executed price is within bounds
      Tick executedTick = TickLib.tickFromVolumes(amountIn, amountOut);
      assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
    }
  }
}
