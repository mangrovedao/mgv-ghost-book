// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/src/Script.sol";
import {MangroveGhostBook} from "src/MangroveGhostBook.sol";

contract BlacklistModuleFromGhostbook is Script {
  function run(address module) external {
    address payable ghostbook = payable(vm.envOr("GHOST_BOOK", address(0)));
    require(ghostbook != address(0), "GhostBook address cannot be zero");
    require(module != address(0), "Module address cannot be zero");

    vm.startBroadcast();

    MangroveGhostBook book = MangroveGhostBook(ghostbook);
    book.blacklistModule(module);

    vm.stopBroadcast();
  }
}
