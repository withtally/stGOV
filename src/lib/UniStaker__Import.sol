// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniStaker} from "unistaker/UniStaker.sol";

// This file & import are needed to force UniStaker to build and to be available as an artifact for use in
// tests via the `deployCode` cheat code. Included in src/lib/ even though it is only needed in tests. This is because
// attempts to include it in test/lib/ resulted in a "artifact not found" error when attempting to deploy in tests via
//  `deployCode` cheat code. This might be a Foundry bug and should be investigated further.
