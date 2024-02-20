// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {FixedPoint} from "./FixedPoint.sol";
import {Constants} from "../constants/Constants.sol";

library WeightedMath {
    using FixedPoint for uint256;

    // About swap fees on joins and exits:
    // Any join or exit that is not perfectly balanced (e.g. all single token joins or exits) is mathematically
    // equivalent to a perfectly balanced join or exit followed by a series of swaps. Since these swaps would charge
    // swap fees, it follows that (some) joins and exits should as well.
    // On these operations, we split the token amounts in 'taxable' and 'non-taxable' portions, where the 'taxable' part
    // is the one to which swap fees are applied.

    // Invariant is used to collect protocol swap fees by comparing its value between two times.
    // So we can round always to the same direction. It is also used to initiate the BPT amount
    // and, because there is a minimum BPT, we round down the invariant.
    function _calculateInvariant(
        uint256[] memory normalizedWeights,
        uint256[] memory balances
    ) internal pure returns (uint256 invariant) {
        /**********************************************************************************************
        // invariant               _____                                                             //
        // wi = weight index i      | |      wi                                                      //
        // bi = balance index i     | |  bi ^   = i                                                  //
        // i = invariant                                                                             //
        **********************************************************************************************/

        invariant = FixedPoint.ONE;
        for (uint256 i = 0; i < normalizedWeights.length; i++) {
            invariant = invariant.mulDown(
                balances[i].powDown(normalizedWeights[i])
            );
        }

        // _require(invariant > 0, Errors.ZERO_INVARIANT);
    }

    // Computes how many tokens can be taken out of a pool if `amountIn` are sent, given the
    // current balances and weights.
    function _calcOutGivenIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // outGivenIn                                                                                //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /      /            bI             \    (wI / wO) \           //
        // aI = amountIn    aO = bO * |  1 - | --------------------------  | ^            |          //
        // wI = weightIn               \      \       ( bI + aI )         /              /           //
        // wO = weightOut                                                                            //
        **********************************************************************************************/

        // Amount out, so we round down overall.

        // The multiplication rounds down, and the subtrahend (power) rounds up (so the base rounds up too).
        // Because bI / (bI + aI) <= 1, the exponent rounds down.

        // Cannot exceed maximum in ratio
        // _require(
        //     amountIn <= balanceIn.mulDown(_MAX_IN_RATIO),
        //     Errors.MAX_IN_RATIO
        // );

        uint256 denominator = balanceIn + amountIn;
        uint256 base = balanceIn.divUp(denominator);
        uint256 exponent = weightIn.divDown(weightOut);
        uint256 power = base.powUp(exponent);

        return balanceOut.mulDown(power.complement());
    }

    // Computes how many tokens must be sent to a pool in order to take `amountOut`, given the
    // current balances and weights.
    function _calcInGivenOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // inGivenOut                                                                                //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /  /            bO             \    (wO / wI)      \          //
        // aI = amountIn    aI = bI * |  | --------------------------  | ^            - 1  |         //
        // wI = weightIn               \  \       ( bO - aO )         /                   /          //
        // wO = weightOut                                                                            //
        **********************************************************************************************/

        // Amount in, so we round up overall.

        // The multiplication rounds up, and the power rounds up (so the base rounds up too).
        // Because b0 / (b0 - a0) >= 1, the exponent rounds up.

        // Cannot exceed maximum out ratio
        // _require(
        //     amountOut <= balanceOut.mulDown(_MAX_OUT_RATIO),
        //     Errors.MAX_OUT_RATIO
        // );

        uint256 base = balanceOut.divUp(balanceOut - amountOut);
        uint256 exponent = weightOut.divUp(weightIn);
        uint256 power = base.powUp(exponent);

        // Because the base is larger than one (and the power rounds up), the power should always be larger than one, so
        // the following subtraction should never revert.
        uint256 ratio = power - FixedPoint.ONE;

        return balanceIn.mulUp(ratio);
    }

    function _calcBptOutGivenExactTokensIn(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT out, so we round down overall.

        uint256[] memory balanceRatiosWithFee = new uint256[](amountsIn.length);

        uint256 invariantRatioWithFees = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            balanceRatiosWithFee[i] = (balances[i] + amountsIn[i]).divDown(
                balances[i]
            );
            invariantRatioWithFees = (invariantRatioWithFees +
                balanceRatiosWithFee[i].mulDown(normalizedWeights[i]));
        }

        uint256 invariantRatio = _computeJoinExactTokensInInvariantRatio(
            balances,
            normalizedWeights,
            amountsIn,
            balanceRatiosWithFee,
            invariantRatioWithFees,
            swapFeePercentage
        );

        uint256 bptOut = (invariantRatio > FixedPoint.ONE)
            ? bptTotalSupply.mulDown(invariantRatio - FixedPoint.ONE)
            : 0;
        return bptOut;
    }

    /**
     * @dev Intermediate function to avoid stack-too-deep errors.
     */
    function _computeJoinExactTokensInInvariantRatio(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256[] memory balanceRatiosWithFee,
        uint256 invariantRatioWithFees,
        uint256 swapFeePercentage
    ) private pure returns (uint256 invariantRatio) {
        // Swap fees are charged on all tokens that are being added in a larger proportion than the overall invariant
        // increase.
        invariantRatio = FixedPoint.ONE;

        for (uint256 i = 0; i < balances.length; i++) {
            uint256 amountInWithoutFee;

            if (balanceRatiosWithFee[i] > invariantRatioWithFees) {
                uint256 nonTaxableAmount = balances[i].mulDown(
                    invariantRatioWithFees - FixedPoint.ONE
                );
                uint256 taxableAmount = amountsIn[i] - nonTaxableAmount;
                uint256 swapFee = taxableAmount.mulUp(swapFeePercentage);

                amountInWithoutFee = nonTaxableAmount + taxableAmount - swapFee;
            } else amountInWithoutFee = amountsIn[i];

            uint256 balanceRatio = (balances[i] + amountInWithoutFee).divDown(
                balances[i]
            );

            invariantRatio = invariantRatio.mulDown(
                balanceRatio.powDown(normalizedWeights[i])
            );
        }
    }

    function _calcTokenInGivenExactBptOut(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        /******************************************************************************************
        // tokenInForExactBPTOut                                                                 //
        // a = amountIn                                                                          //
        // b = balance                      /  /    totalBPT + bptOut      \    (1 / w)       \  //
        // bptOut = bptAmountOut   a = b * |  | --------------------------  | ^          - 1  |  //
        // bpt = totalBPT                   \  \       totalBPT            /                  /  //
        // w = weight                                                                            //
        ******************************************************************************************/

        // Token in, so we round up overall.

        // Calculate the factor by which the invariant will increase after minting BPTAmountOut
        uint256 invariantRatio = (bptTotalSupply + bptAmountOut).divUp(
            bptTotalSupply
        );
        // _require(
        //     invariantRatio <= _MAX_INVARIANT_RATIO,
        //     Errors.MAX_OUT_BPT_FOR_TOKEN_IN
        // );

        // Calculate by how much the token balance has to increase to match the invariantRatio
        uint256 balanceRatio = invariantRatio.powUp(
            FixedPoint.ONE.divUp(normalizedWeight)
        );

        uint256 amountInWithoutFee = balance.mulUp(
            (balanceRatio - FixedPoint.ONE)
        );

        // We can now compute how much extra balance is being deposited and used in virtual swaps, and charge swap fees
        // accordingly.
        uint256 taxableAmount = amountInWithoutFee.mulUp(
            normalizedWeight.complement()
        );
        uint256 nonTaxableAmount = amountInWithoutFee - taxableAmount;

        uint256 taxableAmountPlusFees = taxableAmount.divUp(
            swapFeePercentage.complement()
        );

        return nonTaxableAmount + taxableAmountPlusFees;
    }

    function _calcAllTokensInGivenExactBptOut(
        uint256[] memory balances,
        uint256 bptAmountOut,
        uint256 totalBPT
    ) internal pure returns (uint256[] memory) {
        /************************************************************************************
        // tokensInForExactBptOut                                                          //
        // (per token)                                                                     //
        // aI = amountIn                   /   bptOut   \                                  //
        // b = balance           aI = b * | ------------ |                                 //
        // bptOut = bptAmountOut           \  totalBPT  /                                  //
        // bpt = totalBPT                                                                  //
        ************************************************************************************/

        // Tokens in, so we round up overall.
        uint256 bptRatio = bptAmountOut.divUp(totalBPT);

        uint256[] memory amountsIn = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; i++) {
            amountsIn[i] = balances[i].mulUp(bptRatio);
        }

        return amountsIn;
    }

    function _calcBptInGivenExactTokensOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT in, so we round up overall.

        uint256[] memory balanceRatiosWithoutFee = new uint256[](
            amountsOut.length
        );
        uint256 invariantRatioWithoutFees = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            balanceRatiosWithoutFee[i] = (balances[i] - amountsOut[i]).divUp(
                balances[i]
            );
            invariantRatioWithoutFees = (invariantRatioWithoutFees +
                balanceRatiosWithoutFee[i].mulUp(normalizedWeights[i]));
        }

        uint256 invariantRatio = _computeExitExactTokensOutInvariantRatio(
            balances,
            normalizedWeights,
            amountsOut,
            balanceRatiosWithoutFee,
            invariantRatioWithoutFees,
            swapFeePercentage
        );

        return bptTotalSupply.mulUp(invariantRatio.complement());
    }

    /**
     * @dev Intermediate function to avoid stack-too-deep errors.
     */
    function _computeExitExactTokensOutInvariantRatio(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256[] memory balanceRatiosWithoutFee,
        uint256 invariantRatioWithoutFees,
        uint256 swapFeePercentage
    ) private pure returns (uint256 invariantRatio) {
        invariantRatio = FixedPoint.ONE;

        for (uint256 i = 0; i < balances.length; i++) {
            // Swap fees are typically charged on 'token in', but there is no 'token in' here, so we apply it to
            // 'token out'. This results in slightly larger price impact.

            uint256 amountOutWithFee;
            if (invariantRatioWithoutFees > balanceRatiosWithoutFee[i]) {
                uint256 nonTaxableAmount = balances[i].mulDown(
                    invariantRatioWithoutFees.complement()
                );
                uint256 taxableAmount = amountsOut[i] - nonTaxableAmount;
                uint256 taxableAmountPlusFees = taxableAmount.divUp(
                    swapFeePercentage.complement()
                );

                amountOutWithFee = nonTaxableAmount + taxableAmountPlusFees;
            } else amountOutWithFee = amountsOut[i];

            uint256 balanceRatio = (balances[i] - amountOutWithFee).divDown(
                balances[i]
            );

            invariantRatio = invariantRatio.mulDown(
                balanceRatio.powDown(normalizedWeights[i])
            );
        }
    }

    function _calcTokenOutGivenExactBptIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        /*****************************************************************************************
        // exactBPTInForTokenOut                                                                //
        // a = amountOut                                                                        //
        // b = balance                     /      /    totalBPT - bptIn       \    (1 / w)  \   //
        // bptIn = bptAmountIn    a = b * |  1 - | --------------------------  | ^           |  //
        // bpt = totalBPT                  \      \       totalBPT            /             /   //
        // w = weight                                                                           //
        *****************************************************************************************/

        // Token out, so we round down overall. The multiplication rounds down, but the power rounds up (so the base
        // rounds up). Because (totalBPT - bptIn) / totalBPT <= 1, the exponent rounds down.

        // Calculate the factor by which the invariant will decrease after burning BPTAmountIn
        uint256 invariantRatio = (bptTotalSupply - bptAmountIn).divUp(
            bptTotalSupply
        );
        // _require(
        //     invariantRatio >= _MIN_INVARIANT_RATIO,
        //     Errors.MIN_BPT_IN_FOR_TOKEN_OUT
        // );

        // Calculate by how much the token balance has to decrease to match invariantRatio
        uint256 balanceRatio = invariantRatio.powUp(
            FixedPoint.ONE.divDown(normalizedWeight)
        );

        // Because of rounding up, balanceRatio can be greater than one. Using complement prevents reverts.
        uint256 amountOutWithoutFee = balance.mulDown(
            balanceRatio.complement()
        );

        // We can now compute how much excess balance is being withdrawn as a result of the virtual swaps, which result
        // in swap fees.

        // Swap fees are typically charged on 'token in', but there is no 'token in' here, so we apply it
        // to 'token out'. This results in slightly larger price impact. Fees are rounded up.
        uint256 taxableAmount = amountOutWithoutFee.mulUp(
            normalizedWeight.complement()
        );
        uint256 nonTaxableAmount = amountOutWithoutFee - taxableAmount;
        uint256 taxableAmountMinusFees = taxableAmount.mulUp(
            swapFeePercentage.complement()
        );

        return nonTaxableAmount + taxableAmountMinusFees;
    }

    function _calcTokensOutGivenExactBptIn(
        uint256[] memory balances,
        uint256 bptAmountIn,
        uint256 totalBPT
    ) internal pure returns (uint256[] memory) {
        /**********************************************************************************************
        // exactBPTInForTokensOut                                                                    //
        // (per token)                                                                               //
        // aO = amountOut                  /        bptIn         \                                  //
        // b = balance           a0 = b * | ---------------------  |                                 //
        // bptIn = bptAmountIn             \       totalBPT       /                                  //
        // bpt = totalBPT                                                                            //
        **********************************************************************************************/

        // Since we're computing an amount out, we round down overall. This means rounding down on both the
        // multiplication and division.

        uint256 bptRatio = bptAmountIn.divDown(totalBPT);

        uint256[] memory amountsOut = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; i++) {
            amountsOut[i] = balances[i].mulDown(bptRatio);
        }

        return amountsOut;
    }

    /**
     * @dev Calculate the amount of BPT which should be minted when adding a new token to the Pool.
     *
     * Note that normalizedWeight is set that it corresponds to the desired weight of this token *after* adding it.
     * i.e. For a two token 50:50 pool which we want to turn into a 33:33:33 pool, we use a normalized weight of 33%
     * @param totalSupply - the total supply of the Pool's BPT.
     * @param normalizedWeight - the normalized weight of the token to be added (normalized relative to final weights)
     */
    function _calcBptOutAddToken(
        uint256 totalSupply,
        uint256 normalizedWeight
    ) internal pure returns (uint256) {
        // The amount of BPT which is equivalent to the token being added may be calculated by the growth in the
        // sum of the token weights, i.e. if we add a token which will make up 50% of the pool then we should receive
        // 50% of the new supply of BPT.
        //
        // The growth in the total weight of the pool can be easily calculated by:
        //
        // weightSumRatio = totalWeight / (totalWeight - newTokenWeight)
        //
        // As we're working with normalized weights `totalWeight` is equal to 1.

        uint256 weightSumRatio = FixedPoint.ONE.divDown(
            FixedPoint.ONE - normalizedWeight
        );

        // The amount of BPT to mint is then simply:
        //
        // toMint = totalSupply * (weightSumRatio - 1)

        return totalSupply.mulDown(weightSumRatio - FixedPoint.ONE);
    }
}
