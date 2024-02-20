// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

library Constants {
    // All fixed point multiplications and divisions are inlined. This means we need to divide by ONE when multiplying
    // two numbers, and multiply by ONE when dividing them.

    // All arguments and return values are 18 decimal fixed point numbers.
    int256 public constant ONE = 1e18;

    // Internally, intermediate values are computed with higher precision as 20 decimal fixed point numbers, and in the
    // case of ln36, 36 decimals.
    int256 public constant HUNDRED = 1e20;
    int256 public constant WUMBO = 1e36;

    // The domain of natural exponentiation is bound by the word size and number of decimals used.
    //
    // Because internally the result will be stored using 20 decimals, the largest possible result is
    // (2^255 - 1) / 10^20, which makes the largest exponent ln((2^255 - 1) / 10^20) = 130.700829182905140221.
    // The smallest possible result is 10^(-18), which makes largest negative argument
    // ln(10^(-18)) = -41.446531673892822312.
    // We use 130.0 and -41.0 to have some safety margin.
    int256 public constant MAX_NATURAL_EXPONENT = 130e18;
    int256 public constant MIN_NATURAL_EXPONENT = -41e18;

    // Bounds for ln_36's argument. Both ln(0.9) and ln(1.1) can be represented with 36 decimal places in a fixed point
    // 256 bit integer.
    int256 public constant LN_LOWER_BOUND = 9e17; // 1e18 - 1e17;
    int256 public constant LN_UPPER_BOUND = 11e18; // ONE + 1e17;

    uint256 public constant MILD_EXPONENT_BOUND = 2 ** 254 / uint256(HUNDRED);

    // 18 decimal constants
    int256 public constant X0 = 128000000000000000000; // 2ˆ7
    int256 public constant A0 =
        38877084059945950922200000000000000000000000000000000000; // eˆ(x0) (no decimals)
    int256 public constant X1 = 64000000000000000000; // 2ˆ6
    int256 public constant A1 = 6235149080811616882910000000; // eˆ(x1) (no decimals)
    // 20 decimal constants
    int256 public constant X2 = 3200000000000000000000; // 2ˆ5
    int256 public constant A2 = 7896296018268069516100000000000000; // eˆ(x2)
    int256 public constant X3 = 1600000000000000000000; // 2ˆ4
    int256 public constant A3 = 888611052050787263676000000; // eˆ(x3)
    int256 public constant X4 = 800000000000000000000; // 2ˆ3
    int256 public constant A4 = 298095798704172827474000; // eˆ(x4)
    int256 public constant X5 = 400000000000000000000; // 2ˆ2
    int256 public constant A5 = 5459815003314423907810; // eˆ(x5)
    int256 public constant X6 = 200000000000000000000; // 2ˆ1
    int256 public constant A6 = 738905609893065022723; // eˆ(x6)
    int256 public constant X7 = 100000000000000000000; // 2ˆ0
    int256 public constant A7 = 271828182845904523536; // eˆ(x7)
    int256 public constant X8 = 50000000000000000000; // 2ˆ-1
    int256 public constant A8 = 164872127070012814685; // eˆ(x8)
    int256 public constant X9 = 25000000000000000000; // 2ˆ-2
    int256 public constant A9 = 128402541668774148407; // eˆ(x9)
    int256 public constant X10 = 12500000000000000000; // 2ˆ-3
    int256 public constant A10 = 113314845306682631683; // eˆ(x10)
    int256 public constant X11 = 6250000000000000000; // 2ˆ-4
    int256 public constant A11 = 106449445891785942956; // eˆ(x11)

    // A minimum normalized weight imposes a maximum weight ratio. We need this due to limitations in the
    // implementation of the power function, as these ratios are often exponents.
    uint256 internal constant _MIN_WEIGHT = 1e16;
    // Having a minimum normalized weight imposes a limit on the maximum number of tokens;
    // i.e., the largest possible pool is one where all tokens have exactly the minimum weight.
    uint256 internal constant _MAX_WEIGHTED_TOKENS = 100;

    // Pool limits that arise from limitations in the fixed point power function (and the imposed 1:100 maximum weight
    // ratio).

    // Swap limits: amounts swapped may not be larger than this percentage of total balance.
    uint256 internal constant _MAX_IN_RATIO = 3e17;
    uint256 internal constant _MAX_OUT_RATIO = 3e17;

    // Invariant growth limit: non-proportional joins cannot cause the invariant to increase by more than this ratio.
    uint256 internal constant _MAX_INVARIANT_RATIO = 3e18;
    // Invariant shrink limit: non-proportional exits cannot cause the invariant to decrease by less than this ratio.
    uint256 internal constant _MIN_INVARIANT_RATIO = 7e17;

    function getValueArrray()
        external
        pure
        returns (int256[8] memory, int256[8] memory)
    {
        return (
            [X2, X3, X4, X5, X6, X7, X8, X9],
            [A2, A3, A4, A5, A6, A7, A8, A9]
        );
    }

    function getValueArrrayLong()
        external
        pure
        returns (int256[10] memory, int256[10] memory)
    {
        return (
            [X2, X3, X4, X5, X6, X7, X8, X9, X10, X11],
            [A2, A3, A4, A5, A6, A7, A8, A9, A10, A11]
        );
    }
}
