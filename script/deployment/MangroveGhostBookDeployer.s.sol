// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/src/Script.sol";
import {MangroveGhostBook} from "src/MangroveGhostBook.sol";

contract MangroveGhostBookDeployer is Script {
  MangroveGhostBook public mangroveGhostBook;
  address public mgv;
  address public wantedAdmin;

  modifier ghostBookDeployer() {
    deployMangroveGhostBook();
    _;
    setAdmin();
  }

  function setUp() public {
    mgv = vm.envAddress("MGV");
    mangroveGhostBook = MangroveGhostBook(payable(vm.envOr("GHOST_BOOK", address(0))));
    wantedAdmin = vm.envOr("ADMIN", address(0));
  }

  function deployMangroveGhostBook() public {
    if (address(mangroveGhostBook) != address(0)) {
      return;
    }
    vm.startBroadcast();
    mangroveGhostBook = new MangroveGhostBook(mgv);
    vm.stopBroadcast();
    console.log("MangroveGhostBook deployed at:", address(mangroveGhostBook));
  }

  function setAdmin() public {
    if (wantedAdmin == address(0)) {
      return;
    }
    address inferredOwner = mangroveGhostBook.owner();
    if (inferredOwner != wantedAdmin) {
      vm.broadcast();
      try mangroveGhostBook.transferOwnership(wantedAdmin) {
        console.log("Admin set to:", wantedAdmin);
      } catch (bytes memory reason) {
        console.log("Failed to set admin:", wantedAdmin);
        console.log("Current broadcaster is probably not the owner");
      }
    }
  }

  function run() public virtual ghostBookDeployer {}
}
