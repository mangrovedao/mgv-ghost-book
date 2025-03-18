// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseAerodromeSwapperTest, console} from "../../base/modules/BaseAerodromeSwapperTest.t.sol";
import {AerodromeSwapperWrapper, AerodromeSwapper} from "../../helpers/mock/AerodromeSwapperWrapper.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IAerodromeRouter} from "src/interface/vendors/IAerodromeRouter.sol";

contract AerodromeSwapperTest is BaseAerodromeSwapperTest {
  address ghostBook = makeAddr("mgv-ghostbook");

  // Base chain constants
  bool constant IS_STABLE_POOL = false;

  function setUp() public override {
    super.setUp();
    deployAerodromeSwapper(ghostBook, AERODROME_ROUTER);
    // deal(address(WETH), ghostBook, 10_000 ether);
  }

  function extractCalldata(bytes memory calldataWithSelector) internal pure returns (bytes memory) {
    bytes memory calldataWithoutSelector;

    require(calldataWithSelector.length >= 4);

    assembly {
      let totalLength := mload(calldataWithSelector)
      let targetLength := sub(totalLength, 4)
      calldataWithoutSelector := mload(0x40)

      // Set the length of callDataWithoutSelector (initial length - 4)
      mstore(calldataWithoutSelector, targetLength)

      // Mark the memory space taken for callDataWithoutSelector as allocated
      mstore(0x40, add(calldataWithoutSelector, add(0x20, targetLength)))

      // Process first 32 bytes (we only take the last 28 bytes)
      mstore(add(calldataWithoutSelector, 0x20), shl(0x20, mload(add(calldataWithSelector, 0x20))))

      // Process all other data by chunks of 32 bytes
      for { let i := 0x1C } lt(i, targetLength) { i := add(i, 0x20) } {
        mstore(add(add(calldataWithoutSelector, 0x20), i), mload(add(add(calldataWithSelector, 0x20), add(i, 0x04))))
      }
    }

    return calldataWithoutSelector;
  }

  // Helper to calculate a price tick from pool reserves
  function _calculateTickFromReserves(uint256 reserveIn, uint256 reserveOut) internal pure returns (Tick) {
    // For Aerodrome/Uniswap V2 style pools, price is reserveOut/reserveIn
    return TickLib.tickFromVolumes(reserveIn, reserveOut);
  }

  function testFuzz_AerodromeSwapper_swap_external_limit_price(uint24 mgvTickDepeg) public {
    vm.assume(mgvTickDepeg < 10_000);
    uint256 amountToSell = 1 ether;

    deal(address(WETH), address(swapper), amountToSell);

    OLKey memory ol = OLKey({
      outbound_tkn: address(USDC),
      inbound_tkn: address(WETH),
      tickSpacing: 0 // irrelevant for the test
    });

    // Get current reserves from Aerodrome pool
    (uint256 reserveWETH, uint256 reserveUSDC) =
      IAerodromeRouter(AERODROME_ROUTER).getReserves(address(WETH), address(USDC), IS_STABLE_POOL, AERODROME_FACTORY);

    // Calculate the current tick from reserves
    Tick spotTick = _calculateTickFromReserves(reserveWETH, reserveUSDC);

    // Apply depeg to create a max tick
    Tick maxTick = Tick.wrap(Tick.unwrap(spotTick) - int256(uint256(mgvTickDepeg)));

    console.log("Spot tick:", Tick.unwrap(spotTick));
    console.log("Max tick:", Tick.unwrap(maxTick));

    uint256 tokenInBalanceBefore = IERC20(WETH).balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = IERC20(USDC).balanceOf(address(ghostBook));

    uint256 deadline = block.timestamp + 3600; // 1 hour from now

    vm.prank(ghostBook);
    try swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(IS_STABLE_POOL, AERODROME_FACTORY, deadline)) {}
    catch (bytes memory _res) {
      string memory str = abi.decode(extractCalldata(_res), (string));
      if (mgvTickDepeg < 100) {
        // For small depeg values, expect price exceeds limit error
        assertEq(str, "PriceExceedsLimit");
        return;
      }
    }

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

    console.log("Amount in:", amountIn);
    console.log("Amount out:", amountOut);

    assertGt(amountOut, 0, "No tokens received");
    assertGt(amountIn, 0, "No tokens spent");

    // Test that the executed price is within bounds
    Tick executedTick = TickLib.tickFromVolumes(amountIn, amountOut);
    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }
}
