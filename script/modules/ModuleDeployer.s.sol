// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveGhostBookDeployer, MangroveGhostBook, console} from "../MangroveGhostBookDeployer.s.sol";

abstract contract ModuleDeployer is MangroveGhostBookDeployer {
  address public module;

  error ERROR_DEPLOYMENT_ADDRESS_0();

  function deployModule() public virtual returns (address module);

  function run() public override ghostBookDeployer {
    module = deployModule();
    if (module == address(0)) {
      revert ERROR_DEPLOYMENT_ADDRESS_0();
    }

    vm.broadcast();
    try mangroveGhostBook.whitelistModule(module) {
      console.log("Module whitelisted:", module);
    } catch (bytes memory reason) {
      console.log("Failed to whitelist module:", module);
      console.log("Current broadcaster is probably not the owner");
    }
  }
}
