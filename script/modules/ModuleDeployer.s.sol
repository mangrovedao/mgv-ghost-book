// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveGhostBookDeployer, MangroveGhostBook, console} from "../MangroveGhostBookDeployer.s.sol";

abstract contract ModuleDeployer is MangroveGhostBookDeployer {
  address public module;
  address public testAddress;

  error ERROR_DEPLOYMENT_ADDRESS_0();

  function deployModule() public virtual returns (address module);

  function liveTestModule(address module) public virtual returns (bool) {
    return true;
  }

  function run(bool testMode, bool whitelistModule) public ghostBookDeployer {
    module = deployModule();
    testAddress = vm.envOr("TEST_ADDRESS", address(0));
    if (module == address(0)) {
      revert ERROR_DEPLOYMENT_ADDRESS_0();
    }
    if (testMode) {
      vm.startPrank(testAddress);
    } else {
      vm.startBroadcast();
    }
    if(whitelistModule) {
      try mangroveGhostBook.whitelistModule(module) {
        console.log("Module whitelisted:", module);
      } catch (bytes memory reason) {
        console.log("Failed to whitelist module:", module);
        console.log("Current broadcaster is probably not the owner");
      }
    }
    if (testMode) {
      bool success = liveTestModule(module);
      console.log("Live test succeeded : ", success);
      vm.stopPrank();
    } else {
      vm.stopBroadcast();
    }
  }
}
