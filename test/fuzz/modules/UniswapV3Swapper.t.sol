// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseUniswapV3SwapperTest, console} from "../../base/modules/BaseUniswapV3SwapperTest.t.sol";
import {UniswapV3SwapperWrapper, UniswapV3Swapper} from "../../helpers/mock/UniswapV3SwapperWrapper.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";

contract UniswapV3SwapperTest is BaseUniswapV3SwapperTest {
  address ghostBook = makeAddr("mgv-ghostbook");

  function setUp() public override {
    super.setUp();
    deployUniswapV3Swapper(ghostBook);
    // deal(address(WETH), ghostBook, 10_000 ether);
  }

  function testFuzz_UniswapV3Swapper_swap_external_limit_price(uint24 mgvTickDepeg) public {
    vm.assume(mgvTickDepeg < 10_000);
    uint256 amountToSell = 100 ether;
    address factory = UNISWAP_V3_FACTORY_ARBITRUM;
    address router = UNISWAP_V3_ROUTER_ARBITRUM;

    deal(address(WETH), address(swapper), amountToSell);
    OLKey memory ol = OLKey({
      outbound_tkn: address(USDC),
      inbound_tkn: address(WETH),
      tickSpacing: 0 // irrelevant for the test
    });
    address pool = IUniswapV3Factory(factory).getPool(address(WETH), address(USDC), 500);

    (, int24 spotTick,,,,,) = IUniswapV3Pool(pool).slot0();

    Tick maxTick =
      Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - int24(uint24(mgvTickDepeg))))); // negative change since its not zero for one

    console.log("Spot tick:", spotTick);
    console.log("Max tick:", Tick.unwrap(maxTick));

    uint256 tokenInBalanceBefore = WETH.balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = USDC.balanceOf(address(ghostBook));

    vm.prank(ghostBook);
    try swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(router, uint24(500))) {}
    catch (bytes memory _res) {
      string memory str = abi.decode(extractCalldata(_res), (string));
      if (mgvTickDepeg < 100) {
        assertEq(str, "SPL");
        return;
      }
    }

    uint256 tokenInBalanceAfter = WETH.balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = USDC.balanceOf(address(ghostBook));

    assertNotEq(tokenOutBalanceAfter - tokenOutBalanceBefore, 0);
    assertNotEq(tokenInBalanceBefore - tokenInBalanceAfter, 0);

    Tick tick =
      TickLib.tickFromVolumes(tokenInBalanceBefore - tokenInBalanceAfter, tokenOutBalanceAfter - tokenOutBalanceBefore);

    assertLt(Tick.unwrap(tick), Tick.unwrap(maxTick));
  }

  function testFuzz_UniswapV3Swapper_swap_varying_amounts(uint256 amountToSell) public {
    // Bound amount between 0.01 ETH and 10 ETH
    amountToSell = bound(amountToSell, 0.01 ether, 10 ether);

    address factory = UNISWAP_V3_FACTORY_ARBITRUM;
    address router = UNISWAP_V3_ROUTER_ARBITRUM;
    uint24 fee = 500; // 0.05% fee tier

    deal(address(WETH), address(swapper), amountToSell);

    OLKey memory ol = OLKey({
      outbound_tkn: address(USDC),
      inbound_tkn: address(WETH),
      tickSpacing: 0 // irrelevant for the test
    });

    address pool = IUniswapV3Factory(factory).getPool(address(WETH), address(USDC), fee);

    // Get current price from pool
    (, int24 spotTick,,,,,) = IUniswapV3Pool(pool).slot0();

    // Set a max tick with large buffer to ensure trade goes through
    // Adding buffer here since we want the test to succeed for all amounts
    Tick maxTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - 100)));

    console.log("Spot tick:", spotTick);
    console.log("Max tick:", Tick.unwrap(maxTick));
    console.log("Amount to sell:", amountToSell);

    uint256 tokenInBalanceBefore = WETH.balanceOf(address(swapper));
    uint256 tokenOutBalanceBefore = USDC.balanceOf(address(ghostBook));

    vm.prank(ghostBook);
    swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(router, fee));

    uint256 tokenInBalanceAfter = WETH.balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = USDC.balanceOf(address(ghostBook));

    uint256 amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
    uint256 amountIn = tokenInBalanceBefore - tokenInBalanceAfter;

    console.log("Amount spent:", amountIn);
    console.log("Amount received:", amountOut);

    assertGt(amountOut, 0, "No tokens received");
    assertGt(amountIn, 0, "No tokens spent");

    // Test that the executed price is within bounds
    Tick executedTick = TickLib.tickFromVolumes(amountIn, amountOut);
    assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick), "Executed price exceeds max tick");
  }
}
