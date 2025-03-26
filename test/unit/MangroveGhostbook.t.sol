  // SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseMangroveTest, BaseTest, console} from "../base/BaseMangroveTest.t.sol";
import {UniswapV3Swapper} from "src/modules/UniswapV3Swapper.sol";
import {MangroveGhostBook} from "src/MangroveGhostBook.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

contract MangroveGhostBookTest is BaseMangroveTest {
  MangroveGhostBook public ghostBook;
  OLKey public ol;
  address module = makeAddr("MangroveModule");
  address recipient = makeAddr("Recipient");

  function setUp() public override {
    chain = ForkChain.ARBITRUM;
    super.setUp();

    ol = OLKey({outbound_tkn: address(USDC), inbound_tkn: address(WETH), tickSpacing: 1});

    ghostBook = new MangroveGhostBook(address(mgv));
  }

  function test_rescueFunds() public {
    uint256 amountToRescue = 1 ether;
    // Assume the contract has some USDC to rescue
    deal(address(USDC), address(ghostBook), amountToRescue);

    // Rescue funds
    ghostBook.rescueFunds(address(USDC), recipient, amountToRescue);

    // Check the recipient's balance
    uint256 recipientBalance = USDC.balanceOf(recipient);
    assertEq(recipientBalance, amountToRescue, "Recipient should have received the rescued funds");
  }

  function test_whitelistModule() public {
    // Whitelist the module
    ghostBook.whitelistModule(module);

    // Check if the module is whitelisted
    bool isWhitelisted = ghostBook.whitelistedModules(IExternalSwapModule(module));
    assertTrue(isWhitelisted, "Module should be whitelisted");
  }
}
