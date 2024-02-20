// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Constants} from "../constants/Constants.sol";

/**
 * @dev Exponentiation and logarithm functions for 18 decimal fixed point numbers (both base and exponent/argument).
 *
 * Exponentiation and logarithm with arbitrary bases (x^y and log_x(y)) are implemented by conversion to natural
 * exponentiation and logarithm (where the base is Euler's number).
 */
library LogExpMath {
    /**
     * @dev Exponentiation (x^y) with unsigned 18 decimal fixed point base and exponent.
     *
     * Reverts if ln(x) * y is smaller than `MIN_NATURAL_EXPONENT`, or larger than `MAX_NATURAL_EXPONENT`.
     */
    function pow(
        uint256 base,
        uint256 exponent
    ) internal pure returns (uint256) {
        if (exponent == 0) return uint256(Constants.ONE);
        if (base == 0) return 0;

        // Instead of computing x^y directly, we instead rely on the properties of logarithms and exponentiation to
        // arrive at that result. In particular, exp(ln(x)) = x, and ln(x^y) = y * ln(x). This means
        // x^y = exp(y * ln(x)).

        // The ln function takes a signed value, so we need to make sure x fits in the signed 256 bit range.
        int256 baseCast = SafeCast.toInt256(base);

        // We will compute y * ln(x) in a single step. Depending on the value of x, we can either use ln or ln_36. In
        // both cases, we leave the division by ONE (due to fixed point multiplication) to the end.

        // This prevents y * ln(x) from overflowing, and at the same time guarantees y fits in the signed 256 bit range.
        int256 exponentCast = SafeCast.toInt256(exponent);

        int256 logx_times_y;
        if (
            Constants.LN_LOWER_BOUND < baseCast &&
            baseCast < Constants.LN_UPPER_BOUND
        ) {
            int256 ln_36_x = _ln_36(baseCast);

            // ln_36_x has 36 decimal places, so multiplying by y_int256 isn't as straightforward, since we can't just
            // bring y_int256 to 36 decimal places, as it might overflow. Instead, we perform two 18 decimal
            // multiplications and add the results: one with the first 18 decimals of ln_36_x, and one with the
            // (downscaled) last 18 decimals.
            logx_times_y = ((ln_36_x / Constants.ONE) *
                exponentCast +
                ((ln_36_x % Constants.ONE) * exponentCast) /
                Constants.ONE);
        } else logx_times_y = _ln(baseCast) * exponentCast;

        logx_times_y /= Constants.ONE;

        // Finally, we compute exp(y * ln(x)) to arrive at x^y
        // _require(
        //     MIN_NATURAL_EXPONENT <= logx_times_y &&
        //         logx_times_y <= MAX_NATURAL_EXPONENT,
        //     Errors.PRODUCT_OUT_OF_BOUNDS
        // );

        return uint256(exp(logx_times_y));
    }

    /**
     * @dev Natural exponentiation (e^x) with signed 18 decimal fixed point exponent.
     *
     * Reverts if `x` is smaller than MIN_NATURAL_EXPONENT, or larger than `MAX_NATURAL_EXPONENT`.
     */
    function exp(int256 x) internal pure returns (int256) {
        // _require(
        //     x >= MIN_NATURAL_EXPONENT && x <= MAX_NATURAL_EXPONENT,
        //     Errors.INVALID_EXPONENT
        // );

        // We only handle positive exponents: e^(-x) is computed as 1 / e^x. We can safely make x positive since it
        // fits in the signed 256 bit range (as it is larger than MIN_NATURAL_EXPONENT).
        // Fixed point division requires multiplying by ONE.
        if (x < 0) return ((Constants.ONE * Constants.ONE) / exp(-x));

        // First, we use the fact that e^(x+y) = e^x * e^y to decompose x into a sum of powers of two, which we call x_n,
        // where x_n == 2^(7 - n), and e^x_n = a_n has been precomputed. We choose the first x_n, x0, to equal 2^7
        // because all larger powers are larger than MAX_NATURAL_EXPONENT, and therefore not present in the
        // decomposition.
        // At the end of this process we will have the product of all e^x_n = a_n that apply, and the remainder of this
        // decomposition, which will be lower than the smallest x_n.
        // exp(x) = k_0 * a_0 * k_1 * a_1 * ... + k_n * a_n * exp(remainder), where each k_n equals either 0 or 1.
        // We mutate x by subtracting x_n, making it the remainder of the decomposition.

        // The first two a_n (e^(2^7) and e^(2^6)) are too large if stored as 18 decimal numbers, and could cause
        // intermediate overflows. Instead we store them as plain integers, with 0 decimals.
        // Additionally, x0 + x1 is larger than MAX_NATURAL_EXPONENT, which means they will not both be present in the
        // decomposition.

        // For each x_n, we test if that term is present in the decomposition (if x is larger than it), and if so deduct
        // it and compute the accumulated product.

        int256 firstAN;
        if (x >= Constants.X0) {
            x -= Constants.X0;
            firstAN = Constants.A0;
        } else if (x >= Constants.X1) {
            x -= Constants.X1;
            firstAN = Constants.A1;
        } else firstAN = 1; // One with no decimal places

        // We now transform x into a 20 decimal fixed point number, to have enhanced precision when computing the
        // smaller terms.
        x *= 100;

        // `product` is the accumulated product of all a_n (except a0 and a1), which starts at 20 decimal fixed point
        // one. Recall that fixed point multiplication requires dividing by HUNDRED.
        int256 product = Constants.HUNDRED;

        (int256[8] memory xValues, int256[8] memory aValues) = Constants
            .getValueArrray();

        for (uint i = 0; i < xValues.length; i++) {
            if (x >= xValues[i]) {
                x -= xValues[i];
                product = (product * aValues[i]) / Constants.HUNDRED;
            }
        }

        // x10 and x11 are unnecessary here since we have high enough precision already.

        // Now we need to compute e^x, where x is small (in particular, it is smaller than x9). We use the Taylor series
        // expansion for e^x: 1 + x + (x^2 / 2!) + (x^3 / 3!) + ... + (x^n / n!).

        int256 seriesSum = Constants.HUNDRED; // The initial one in the sum, with 20 decimal places.
        int256 term; // Each term in the sum, where the nth term is (x^n / n!).

        // The first term is simply x.
        term = x;
        seriesSum += term;

        // Each term (x^n / n!) equals the previous one times x, divided by n. Since x is a fixed point number,
        // multiplying by it requires dividing by HUNDRED, but dividing by the non-fixed point n values does not.

        for (int256 i = 2; i <= 12; i++) {
            term = ((term * x) / Constants.HUNDRED) / i;
            seriesSum += term;
        }

        // 12 Taylor terms are sufficient for 18 decimal precision.

        // We now have the first a_n (with no decimals), and the product of all other a_n present, and the Taylor
        // approximation of the exponentiation of the remainder (both with 20 decimals). All that remains is to multiply
        // all three (one 20 decimal fixed point multiplication, dividing by HUNDRED, and one integer multiplication),
        // and then drop two digits to return an 18 decimal value.

        return (((product * seriesSum) / Constants.HUNDRED) * firstAN) / 100;
    }

    /**
     * @dev Logarithm (log(arg, base), with signed 18 decimal fixed point base and argument.
     */
    function log(int256 arg, int256 base) internal pure returns (int256) {
        // This performs a simple base change: log(arg, base) = ln(arg) / ln(base).

        // Both logBase and logArg are computed as 36 decimal fixed point numbers, either by using ln_36, or by
        // upscaling.

        int256 logBase;
        if (Constants.LN_LOWER_BOUND < base && base < Constants.LN_UPPER_BOUND)
            logBase = _ln_36(base);
        else logBase = _ln(base) * Constants.ONE;

        int256 logArg;
        if (Constants.LN_LOWER_BOUND < arg && arg < Constants.LN_UPPER_BOUND)
            logArg = _ln_36(arg);
        else logArg = _ln(arg) * Constants.ONE;

        // When dividing, we multiply by ONE to arrive at a result with 18 decimal places
        return (logArg * Constants.ONE) / logBase;
    }

    /**
     * @dev Natural logarithm (ln(a)) with signed 18 decimal fixed point argument.
     */
    function ln(int256 a) internal pure returns (int256) {
        // The real natural logarithm is not defined for negative numbers or zero.
        // _require(a > 0, Errors.OUT_OF_BOUNDS);
        if (Constants.LN_LOWER_BOUND < a && a < Constants.LN_UPPER_BOUND)
            return _ln_36(a) / Constants.ONE;
        else return _ln(a);
    }

    /**
     * @dev Internal natural logarithm (ln(a)) with signed 18 decimal fixed point argument.
     */
    function _ln(int256 a) private pure returns (int256) {
        // Since ln(a^k) = k * ln(a), we can compute ln(a) as ln(a) = ln((1/a)^(-1)) = - ln((1/a)). If a is less
        // than one, 1/a will be greater than one, and this if statement will not be entered in the recursive call.
        // Fixed point division requires multiplying by ONE.
        if (a < Constants.ONE)
            return (-_ln((Constants.ONE * Constants.ONE) / a));

        // First, we use the fact that ln^(a * b) = ln(a) + ln(b) to decompose ln(a) into a sum of powers of two, which
        // we call x_n, where x_n == 2^(7 - n), which are the natural logarithm of precomputed quantities a_n (that is,
        // ln(a_n) = x_n). We choose the first x_n, x0, to equal 2^7 because the exponential of all larger powers cannot
        // be represented as 18 fixed point decimal numbers in 256 bits, and are therefore larger than a.
        // At the end of this process we will have the sum of all x_n = ln(a_n) that apply, and the remainder of this
        // decomposition, which will be lower than the smallest a_n.
        // ln(a) = k_0 * x_0 + k_1 * x_1 + ... + k_n * x_n + ln(remainder), where each k_n equals either 0 or 1.
        // We mutate a by subtracting a_n, making it the remainder of the decomposition.

        // For reasons related to how `exp` works, the first two a_n (e^(2^7) and e^(2^6)) are not stored as fixed point
        // numbers with 18 decimals, but instead as plain integers with 0 decimals, so we need to multiply them by
        // ONE to convert them to fixed point.
        // For each a_n, we test if that term is present in the decomposition (if a is larger than it), and if so divide
        // by it and compute the accumulated sum.

        int256 sum = 0;
        if (a >= Constants.A0 * Constants.ONE) {
            a /= Constants.A0; // Integer, not fixed point division
            sum += Constants.X0;
        }

        if (a >= Constants.A1 * Constants.ONE) {
            a /= Constants.A1; // Integer, not fixed point division
            sum += Constants.X1;
        }

        // All other a_n and x_n are stored as 20 digit fixed point numbers, so we convert the sum and a to this format.
        sum *= 100;
        a *= 100;

        (int256[10] memory x_nValues, int256[10] memory a_nValues) = Constants
            .getValueArrrayLong();

        for (uint256 i = 0; i < a_nValues.length; i++) {
            if (a >= a_nValues[i]) {
                a = (a * Constants.HUNDRED) / a_nValues[i];
                sum += x_nValues[i];
            }
        }

        // a is now a small number (smaller than a_11, which roughly equals 1.06). This means we can use a Taylor series
        // that converges rapidly for values of `a` close to one - the same one used in ln_36.
        // Let z = (a - 1) / (a + 1).
        // ln(a) = 2 * (z + z^3 / 3 + z^5 / 5 + z^7 / 7 + ... + z^(2 * n + 1) / (2 * n + 1))

        // Recall that 20 digit fixed point division requires multiplying by HUNDRED, and multiplication requires
        // division by HUNDRED.
        int256 z = ((a - Constants.HUNDRED) * Constants.HUNDRED) /
            (a + Constants.HUNDRED);
        int256 z_squared = (z * z) / Constants.HUNDRED;

        // num is the numerator of the series: the z^(2 * n + 1) term
        int256 num = z;

        // seriesSum holds the accumulated sum of each term in the series, starting with the initial z
        int256 seriesSum = num;

        // In each step, the numerator is multiplied by z^2
        for (int256 i = 3; i <= 11; i += 2) {
            num = (num * z_squared) / Constants.HUNDRED;
            seriesSum += num / i;
        }

        // 6 Taylor terms are sufficient for 36 decimal precision.

        // Finally, we multiply by 2 (non fixed point) to compute ln(remainder)
        seriesSum *= 2;

        // We now have the sum of all x_n present, and the Taylor approximation of the logarithm of the remainder (both
        // with 20 decimals). All that remains is to sum these two, and then drop two digits to return a 18 decimal
        // value.

        return (sum + seriesSum) / 100;
    }

    /**
     * @dev Intrnal high precision (36 decimal places) natural logarithm (ln(argument)) with signed 18 decimal fixed point argument,
     * for argument close to one.
     *
     * Should only be used if argument is between LN_LOWER_BOUND and LN_UPPER_BOUND.
     */
    function _ln_36(int256 argument) private pure returns (int256) {
        // Since ln(1) = 0, a value of argument close to one will yield a very small result, which makes using 36 digits
        // worthwhile.

        // First, we transform argument to a 36 digit fixed point value.
        argument *= Constants.ONE;

        // We will use the following Taylor expansion, which converges very rapidly. Let z = (argument - 1) / (argument + 1).
        // ln(argument) = 2 * (z + z^3 / 3 + z^5 / 5 + z^7 / 7 + ... + z^(2 * n + 1) / (2 * n + 1))

        // Recall that 36 digit fixed point division requires multiplying by ONE_36, and multiplication requires
        // division by ONE_36.
        int256 value = ((argument - Constants.WUMBO) * Constants.WUMBO) /
            (argument + Constants.WUMBO);
        int256 value_squared = (value * value) / Constants.WUMBO;

        // num is the numerator of the series: the z^(2 * n + 1) term
        int256 num = value;

        // seriesSum holds the accumulated sum of each term in the series, starting with the initial z
        int256 seriesSum = num;

        // Loop to calculate each term of the series up to the 8th term for sufficient precision
        for (int256 i = 3; i <= 15; i += 2) {
            num = (num * value_squared) / Constants.WUMBO; // z^(2*n + 1)
            seriesSum += num / i;
        }

        // 8 Taylor terms are sufficient for 36 decimal precision.

        // All that remains is multiplying by 2 (non fixed point).
        return seriesSum * 2;
    }
}
