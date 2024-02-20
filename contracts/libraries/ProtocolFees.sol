// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Math, LogExpMath, FixedPoint} from "./FixedPoint.sol";

library ProtocolFees {
    using FixedPoint for uint256;

    function bptForPoolOwnershipPercentage(
        uint256 totalSupply,
        uint256 poolOwnershipPercentage
    ) external pure returns (uint256) {
        return
            Math.mulDiv(
                totalSupply,
                poolOwnershipPercentage,
                poolOwnershipPercentage.complement()
            );
    }
}
