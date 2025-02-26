// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

contract PercentAssertions is Test {
  function _toPercentage(uint256 x, uint256 y) public pure returns (uint256) {
    require(y > 0, "Cannot divide by zero");
    // multiply first, then divide to avoid truncation
    return (x * 100) / y;
  }
  // Because there will be (expected) rounding errors in the amount of rewards earned, this helper
  // checks that the truncated number is lesser and within 1% of the expected number.

  function assertLteWithinOnePercent(uint256 a, uint256 b) public {
    if (a > b) {
      emit log("Error: a <= b not satisfied");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);

      fail();
    }

    uint256 minBound = (b * 9900) / 10_000;

    if (a < minBound) {
      emit log("Error: a >= 0.99 * b not satisfied");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);
      emit log_named_uint("  minBound", minBound);

      fail();
    }
  }

  // This function of the helper allows either number to be greater but ensures the two lesser number is within 1
  // percent
  // of the greater.
  function assertWithinOnePercent(uint256 a, uint256 b) public {
    uint256 _gt;
    uint256 _lt;

    if (a == b) {
      return;
    } else if (a > b) {
      _gt = a;
      _lt = b;
    } else {
      _gt = b;
      _lt = a;
    }

    uint256 _minBound = (_gt * 9900) / 10_000;
    if (_lt < _minBound) {
      emit log("Error: a >= 0.99 * b || b >= 0.99 * a not satisfied");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);
      emit log_named_uint("  minBound", _minBound);

      fail();
    }
  }

  // Because there will be (expected) rounding errors in the amount of rewards earned, this helper
  // checks that the truncated number is lesser and within 0.01% of the expected number.
  function assertLteWithinOneBip(uint256 a, uint256 b) public {
    if (a > b) {
      emit log("Error: a <= b not satisfied");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);

      fail();
    }

    uint256 minBound = (b * 9999) / 10_000;

    if (a < minBound) {
      emit log("Error: a >= 0.9999 * b not satisfied");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);
      emit log_named_uint("  minBound", minBound);

      fail();
    }
  }

  // This function of the helper allows either number to be greater but ensures the two lesser number is within 1 bip
  // of the greater.
  function assertWithinOneBip(uint256 a, uint256 b) public {
    uint256 _gt;
    uint256 _lt;

    if (a == b) {
      return;
    } else if (a > b) {
      _gt = a;
      _lt = b;
    } else {
      _gt = b;
      _lt = a;
    }

    uint256 _minBound = (_gt * 9999) / 10_000;
    if (_lt < _minBound) {
      emit log("Error: a >= 0.9999 * b || b >= 0.9999 * a not satisfied");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);
      emit log_named_uint("  minBound", _minBound);

      fail();
    }
  }

  function _percentOf(uint256 _amount, uint256 _percent) public pure returns (uint256) {
    // For cases where the percentage is less than 100, we calculate the percentage by
    // taking the inverse percentage and subtracting it. This effectively rounds _up_ the
    // value by putting the truncation on the opposite side. For example, 92% of 555 is 510.6.
    // Calculating it in this way would yield (555 - 44) = 511, instead of 510.
    if (_percent < 100) {
      return _amount - ((100 - _percent) * _amount) / 100;
    } else {
      return (_percent * _amount) / 100;
    }
  }

  // This helper is for normal rounding errors, i.e. if the number might be truncated down by 1
  function assertLteWithinOneUnit(uint256 a, uint256 b) public {
    if (a > b) {
      emit log("Error: a <= b not satisfied");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);

      fail();
    }

    if (a == b) {
      // Early return avoids underflow when a == b == 0
      return;
    }

    uint256 minBound = b - 1;

    if (a != minBound) {
      emit log("Error: a == b || a  == b-1");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);

      fail();
    }
  }

  // This helper is for normal rounding errors, i.e. if the number might be truncated up _or_ down by 1
  function assertWithinOneUnit(uint256 a, uint256 b) public {
    uint256 _gt;
    uint256 _lt;

    if (a == b) {
      return;
    } else if (a > b) {
      _gt = a;
      _lt = b;
    } else {
      _gt = b;
      _lt = a;
    }

    uint256 minBound = _gt - 1;

    if (!((a == b) || (_lt == minBound))) {
      emit log("Error: a == b || a  == b-1 || a == b+1");
      emit log_named_uint("  Expected", b);
      emit log_named_uint("    Actual", a);

      fail();
    }
  }
}
