// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {UnitTestBase} from "../UnitTestBase.sol";
import {GovLst} from "../../src/GovLst.sol";
import {FixedGovLst} from "../../src/FixedGovLst.sol";
import {FixedGovLstHandler} from "./FixedGovLst.handler.sol";
import {GovLstHandler} from "./GovLst.handler.sol";
import {GovLstHarness} from "../harnesses/GovLstHarness.sol";
import {FixedGovLstHarness} from "../harnesses/FixedGovLstHarness.sol";
import {FakeStaker} from "../fakes/FakeStaker.sol";
import {PercentAssertions} from "../helpers/PercentAssertions.sol";
import {MockFullEarningPowerCalculator} from "test/mocks/MockFullEarningPowerCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Staking} from "staker/interfaces/IERC20Staking.sol";
import {Staker} from "staker/Staker.sol";
import {WrappedGovLst} from "../../src/WrappedGovLst.sol";
import {WrappedGovLstHandler} from "./WrappedGovLst.handler.sol";

contract GovStakerInvariants is Test, UnitTestBase, PercentAssertions {
  GovLstHandler govLstHandler;
  GovLst govLst;
  FixedGovLst fixedGovLst;
  FixedGovLstHandler fixedGovLstHandler;
  WrappedGovLst wrappedGovLst;
  WrappedGovLstHandler wrappedGovLstHandler;
  MockFullEarningPowerCalculator earningPowerCalculator;
  Staker staker;
  address lstOwner;
  uint80 initialPayoutAmount = 2500e18;
  uint256 initialAmount = 1e1;

  address defaultDelegatee = makeAddr("Default Delegatee");
  address delegateeGuardian = makeAddr("Delegatee Guardian");

  function setUp() public override {
    super.setUp();
    lstOwner = makeAddr("LST Owner");

    // Staker contracts from bytecode to avoid compiler conflicts.
    earningPowerCalculator = new MockFullEarningPowerCalculator();

    staker = new FakeStaker(
      IERC20(address(rewardToken)),
      IERC20Staking(address(stakeToken)),
      earningPowerCalculator,
      1e18,
      stakerAdmin,
      "Gov staker"
    );

    // We do the 0th deposit because the LST includes an assumption that deposit Id 0 is not held by it.
    vm.startPrank(stakeMinter);
    stakeToken.approve(address(staker), 0);
    staker.stake(0, stakeMinter);
    vm.stopPrank();

    vm.prank(stakerAdmin);
    staker.setRewardNotifier(stakerAdmin, true);

    // Finally, deploy the lst for tests.
    // No withdrawal delay
    govLst = new GovLstHarness(
      GovLst.ConstructorParams({
        fixedLstName: "Gov Lst",
        fixedLstSymbol: "stGov",
        rebasingLstName: "Rebased Gov Lst",
        rebasingLstSymbol: "rstGov",
        version: "2",
        staker: staker,
        initialDefaultDelegatee: defaultDelegatee,
        initialOwner: lstOwner,
        initialPayoutAmount: initialPayoutAmount,
        initialDelegateeGuardian: delegateeGuardian,
        stakeToBurn: 0,
        minQualifyingEarningPowerBips: 0
      })
    );

    fixedGovLst = govLst.FIXED_LST();
    govLstHandler = new GovLstHandler(govLst);

    bytes4[] memory govLstSelectors = new bytes4[](8);
    govLstSelectors[0] = GovLstHandler.stake.selector;
    govLstSelectors[1] = GovLstHandler.unstake.selector;
    govLstSelectors[2] = GovLstHandler.validTransfer.selector;
    govLstSelectors[3] = GovLstHandler.fetchOrInitializeDepositForDelegatee.selector;
    govLstSelectors[4] = GovLstHandler.updateDeposit.selector;
    govLstSelectors[5] = GovLstHandler.claimAndDistributeReward.selector;
    govLstSelectors[6] = GovLstHandler.notifyRewardAmount.selector;
    govLstSelectors[7] = GovLstHandler.warpAhead.selector;

    targetSelector(FuzzSelector({addr: address(govLstHandler), selectors: govLstSelectors}));

    targetContract(address(govLstHandler));

    fixedGovLstHandler = new FixedGovLstHandler(fixedGovLst);
    bytes4[] memory fixedGovLstSelectors = new bytes4[](2);
    fixedGovLstSelectors[0] = FixedGovLstHandler.stake.selector;
    fixedGovLstSelectors[1] = FixedGovLstHandler.unstake.selector;

    targetSelector(FuzzSelector({addr: address(fixedGovLstHandler), selectors: fixedGovLstSelectors}));

    targetContract(address(fixedGovLstHandler));

    address _wrappedLstAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    // Mint to this contract
    deal(address(stakeToken), address(this), initialAmount, true);
    stakeToken.approve(address(fixedGovLst), initialAmount);
    fixedGovLst.stake(initialAmount);
    // approve to compted create address
    fixedGovLst.approve(_wrappedLstAddress, initialAmount);

    wrappedGovLst = new WrappedGovLst("Wrapped Gov Lst", "wGovLst", govLst, defaultDelegatee, lstOwner, initialAmount);
    wrappedGovLstHandler = new WrappedGovLstHandler(wrappedGovLst);

    bytes4[] memory wrappedGovLstSelectors = new bytes4[](5);
    wrappedGovLstSelectors[0] = WrappedGovLstHandler.wrapRebasing.selector;
    wrappedGovLstSelectors[1] = WrappedGovLstHandler.wrapUnderlying.selector;
    wrappedGovLstSelectors[2] = WrappedGovLstHandler.wrapFixed.selector;
    wrappedGovLstSelectors[3] = WrappedGovLstHandler.unwrapToRebasing.selector;
    wrappedGovLstSelectors[4] = WrappedGovLstHandler.unwrapToFixed.selector;

    targetSelector(FuzzSelector({addr: address(wrappedGovLstHandler), selectors: wrappedGovLstSelectors}));

    targetContract(address(wrappedGovLstHandler));
  }

  /// @notice Sum of all user balances equals total supply
  function invariant_sumOfBalancesEqualsTheTotalSupply() public {
    uint256 _totalSupply = wrappedGovLst.totalSupply();
    uint256 _sumOfBalances = wrappedGovLstHandler.reduceHolders(0, this.accumulateBalance);
    assertEq(_sumOfBalances, _totalSupply);
  }

  /// @notice Sum of all user balances Is less than the underlying fixed lst supply
  function invariant_sumOfBalancesIsLessThanTheUnderlyingFixedLst() public {
    uint256 _sumOfBalances = wrappedGovLstHandler.reduceHolders(0, this.accumulateBalance);
    assertLe(_sumOfBalances, wrappedGovLstHandler.ghost_fixedWrapped() + initialAmount);
  }

  function invariant_fixedLstBalanceIsGreaterOrEqualToThanWrappedTotalSupply() public view {
    uint256 _fixedGovBalance = fixedGovLst.balanceOf(address(wrappedGovLst));
    assertGe(_fixedGovBalance, wrappedGovLst.totalSupply());
  }

  function invariant_totalSupplyIsLessThanOrEqualToTheWrappedMinusUnwrapped() public view {
    assertLe(
      wrappedGovLst.totalSupply(),
      wrappedGovLstHandler.ghost_fixedWrapped() - wrappedGovLstHandler.ghost_fixedUnwrapped() + initialAmount
    );
  }

  function invariant_fixedBalanceIsGreaterThanOrEqualToWrappingMinusUnwrapping() public view {
    uint256 _fixedGovBalance = fixedGovLst.balanceOf(address(wrappedGovLst));
    assertGe(
      _fixedGovBalance,
      wrappedGovLstHandler.ghost_fixedWrapped() - wrappedGovLstHandler.ghost_fixedUnwrapped() + initialAmount
    );
  }

  function accumulateBalance(uint256 _balance, address _holder) external view returns (uint256) {
    console2.logUint(wrappedGovLst.balanceOf(_holder));
    console2.logUint(fixedGovLst.balanceOf(address(wrappedGovLst)));
    return _balance + wrappedGovLst.balanceOf(_holder);
  }
}
