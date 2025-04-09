// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ModuleDeployer, console} from "./ModuleDeployer.s.sol";
import {SplitStreamSwapper, OLKey, Tick} from "../../src/modules/SplitStreamSwapper.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {ModuleData} from "src/MangroveGhostBook.sol";
import {StdCheats} from "forge-std/src/Test.sol";

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

contract SplitStreamModuleDeployer is ModuleDeployer, StdCheats {
  IERC20 public constant USDC_BASE = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
  IERC20 public constant USDT_BASE = IERC20(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA);
  bool constant IS_STABLE_POOL = false;
  int24 constant TICK_SPACING = 1;
  address public constant SPLITSTREAM_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
  address public constant SPLITSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

  function deployModule() public override returns (address module) {
    console.log("---------------------------------------------");
    console.log("Starting SplitStreamSwapper Module Deployment");
    console.log("---------------------------------------------");
    console.log("MangroveGhostBook address:", address(mangroveGhostBook));
    console.log("SplitStream Router address:", SPLITSTREAM_ROUTER);
    console.log("SplitStream Factory address:", SPLITSTREAM_FACTORY);

    vm.broadcast();
    console.log("Broadcasting deployment transaction...");
    module = address(new SplitStreamSwapper(address(mangroveGhostBook)));

    console.log("SplitStreamSwapper successfully deployed at:", module);
    console.log("Deployment gas used:", gasleft());
    console.log("---------------------------------------------");

    return module;
  }

  function liveTestModule(address module) public override returns (bool) {
    console.log("---------------------------------------------");
    console.log("Starting SplitStreamSwapper Live Test");
    console.log("---------------------------------------------");
    console.log("Test address:", testAddress);
    console.log("Module address:", module);
    console.log("USDC address:", address(USDC_BASE));
    console.log("USDT address:", address(USDT_BASE));

    // Check test address is valid
    if (testAddress == address(0)) {
      console.log("ERROR: Test address is zero. Please set TEST_ADDRESS env variable");
      return false;
    }

    // Deal tokens to test address
    console.log("Dealing 10,000 USDT to test address");
    deal(address(USDT_BASE), testAddress, 10_000e6);
    uint256 usdtBalance = USDT_BASE.balanceOf(testAddress);
    console.log("USDT balance after deal:", usdtBalance);

    console.log("Dealing 10,000 USDC to test address");
    deal(address(USDC_BASE), testAddress, 10_000e6);
    uint256 usdcBalance = USDC_BASE.balanceOf(testAddress);
    console.log("USDC balance after deal:", usdcBalance);

    // Approve tokens
    console.log("Approving USDT for MangroveGhostBook");
    USDT_BASE.approve(address(mangroveGhostBook), type(uint256).max);
    console.log("Approving USDC for MangroveGhostBook");
    USDC_BASE.approve(address(mangroveGhostBook), type(uint256).max);

    // Set up OLKey and ModuleData
    console.log("Setting up order parameters");
    OLKey memory olKey = OLKey({outbound_tkn: address(USDT_BASE), inbound_tkn: address(USDC_BASE), tickSpacing: 1});
    console.log("OLKey - outbound_tkn:", olKey.outbound_tkn);
    console.log("OLKey - inbound_tkn:", olKey.inbound_tkn);
    console.log("OLKey - tickSpacing:", olKey.tickSpacing);

    uint256 deadline = block.timestamp + 3600;
    console.log("Order deadline:", deadline);

    ModuleData memory moduleData = ModuleData({
      module: IExternalSwapModule(address(module)),
      data: abi.encode(SPLITSTREAM_ROUTER, uint24(300), deadline, uint24(TICK_SPACING))
    });
    console.log("ModuleData encoded successfully");

    // Get pool and current spot tick
    address pool = ISplitStreamFactory(SPLITSTREAM_FACTORY).getPool(olKey.inbound_tkn, olKey.outbound_tkn, TICK_SPACING);
    console.log("SplitStream pool address:", pool);

    if (pool == address(0)) {
      console.log("ERROR: Pool not found for token pair with given tick spacing");
      return false;
    }

    (, int24 spotTick,,,,) = ISplitStreamPool(pool).slot0();
    console.log("Current spot tick:", spotTick);

    // Calculate max tick for the order
    Tick maxTick = Tick.wrap(Tick.unwrap(Tick.wrap(int256(spotTick))) + 2000);
    console.log("Max tick for order:", Tick.unwrap(maxTick));
    console.log("Order amount: 1,000,000 (1e6)");

    // Execute test order
    console.log("Executing test market order...");
    try mangroveGhostBook.marketOrderByTick(olKey, maxTick, 1e6, moduleData) returns (
      uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid
    ) {
      console.log("Order execution successful!");
      console.log("takerGot:", takerGot);
      console.log("takerGave:", takerGave);
      console.log("bounty:", bounty);
      console.log("feePaid:", feePaid);

      // Check new balances
      uint256 newUsdtBalance = USDT_BASE.balanceOf(testAddress);
      uint256 newUsdcBalance = USDC_BASE.balanceOf(testAddress);
      console.log("USDT balance after swap:", newUsdtBalance);
      console.log("USDC balance after swap:", newUsdcBalance);
      console.log("USDT change:", int256(newUsdtBalance) - int256(usdtBalance));
      console.log("USDC change:", int256(newUsdcBalance) - int256(usdcBalance));

      assert(takerGot > 0);
      assert(takerGave > 0);
      console.log("---------------------------------------------");
      console.log("Test PASSED (SUCCESS)");
      console.log("---------------------------------------------");
      return true;
    } catch (bytes memory reason) {
      console.log("Order execution failed!");
      console.log("Error reason:", string(reason));
      console.log("---------------------------------------------");
      console.log("Test FAILED (ERROR)");
      console.log("---------------------------------------------");
      return false;
    }
  }
}
