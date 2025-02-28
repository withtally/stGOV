// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FixedGovLst} from "../FixedGovLst.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title FixedGovLstPermitAndStake
/// @author [ScopeLift](https://scopelift.co)
/// @notice This contract extension adds permit-based staking functionality to the FixedGovLst base contract,
/// allowing token approvals to happen via signatures rather than requiring a separate transaction.
/// The permit functionality is used in conjunction with the stake operation, improving UX by
/// enabling users to approve and stake tokens in a single transaction. Note that this extension
/// requires the stake token to support EIP-2612 permit functionality.
abstract contract FixedGovLstPermitAndStake is FixedGovLst {
  /// @notice Stake tokens to receive fixed liquid stake tokens. Before the staking operation occurs, a signature is
  /// passed to the token contract's permit method to spend the would-be staked amount of the token.
  /// @param _amount The quantity of fixed tokens that will be staked.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _v ECDSA signature component: Parity of the `y` coordinate of point `R`
  /// @param _r ECDSA signature component: x-coordinate of `R`
  /// @param _s ECDSA signature component: `s` value of the signature
  /// @return The number of fixed tokens after staking.
  function permitAndStake(uint256 _amount, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
    public
    returns (uint256)
  {
    try IERC20Permit(address(STAKE_TOKEN)).permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s) {} catch {}
    return stake(_amount);
  }
}
