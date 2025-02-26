// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Interface of WETH9 token contract on Ethereum mainnet.
/// @dev Generated via Foundry `cast interface 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
interface IWETH9 {
  event Approval(address indexed src, address indexed guy, uint256 wad);
  event Deposit(address indexed dst, uint256 wad);
  event Transfer(address indexed src, address indexed dst, uint256 wad);
  event Withdrawal(address indexed src, uint256 wad);

  fallback() external payable;

  function allowance(address, address) external view returns (uint256);
  function approve(address guy, uint256 wad) external returns (bool);
  function balanceOf(address) external view returns (uint256);
  function decimals() external view returns (uint8);
  function deposit() external payable;
  function name() external view returns (string memory);
  function symbol() external view returns (string memory);
  function totalSupply() external view returns (uint256);
  function transfer(address dst, uint256 wad) external returns (bool);
  function transferFrom(address src, address dst, uint256 wad) external returns (bool);
  function withdraw(uint256 wad) external;
}
