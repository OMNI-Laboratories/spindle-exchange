// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Math, LogExpMath} from "./LogExpMath.sol";

library FixedPoint {
    uint256 internal constant ONE = 1e18;

    function mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / ONE;
    }

    function mulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a * b;
        if (product == 0) return 0;
        else return ((product - 1) / ONE) + 1;
    }

    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        // _require(b != 0, Errors.ZERO_DIVISION);
        if (a == 0) return 0;
        else return (a * ONE) / b;
    }

    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        // _require(b != 0, Errors.ZERO_DIVISION);
        if (a == 0) return 0;
        else return ((a * ONE - 1) / b) + 1;
    }

    // /**
    //  * @dev Returns x^y, assuming both are fixed point numbers, rounding down. The result is guaranteed to not be above
    //  * the true value (that is, the error function expected - actual is always positive).
    //  */
    function powDown(uint256 x, uint256 y) internal pure returns (uint256) {
        // Optimize for when y equals 1.0, 2.0 or 4.0, as those are very simple to implement and occur often in 50/50
        // and 80/20 Weighted Pools
        if (y == ONE) return x;
        else if (y == (ONE * 2)) return mulDown(x, x);
        else if (y == ONE * 4) return mulDown(mulDown(x, x), mulDown(x, x));
        else {
            uint256 raw = LogExpMath.pow(x, y);
            uint256 maxError = mulUp(raw, 10000) + 1;

            if (raw < maxError) return 0;
            else return raw - maxError;
        }
    }

    // /**
    //  * @dev Returns x^y, assuming both are fixed point numbers, rounding up. The result is guaranteed to not be below
    //  * the true value (that is, the error function expected - actual is always negative).
    //  */
    function powUp(uint256 x, uint256 y) internal pure returns (uint256) {
        // Optimize for when y equals 1.0, 2.0 or 4.0, as those are very simple to implement and occur often in 50/50
        // and 80/20 Weighted Pools
        if (y == ONE) return x;
        else if (y == ONE * 2) return mulUp(x, x);
        else if (y == ONE * 4) return mulUp(mulUp(x, x), mulUp(x, x));
        else {
            uint256 raw = LogExpMath.pow(x, y);
            uint256 maxError = mulUp(raw, 10000) + 1;

            return raw + maxError;
        }
    }

    /**
     * @dev Returns the complement of a value (1 - x), capped to 0 if x is larger than 1.
     *
     * Useful when computing the complement for values with some level of relative error, as it strips this error and
     * prevents intermediate negative values.
     */
    function complement(uint256 x) internal pure returns (uint256) {
        return (x < ONE) ? (ONE - x) : 0;
    }
}
