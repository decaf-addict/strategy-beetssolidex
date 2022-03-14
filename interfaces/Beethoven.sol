// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IBeetsBar is IERC20 {
    function vestingToken() external view returns (address);

    function enter(uint256 _amount) external;

    function leave(uint256 _shareOfFreshBeets) external;

    function shareRevenue(uint256 _amount) external;

    function transfer(uint256 _amount, address _to) external;
}
