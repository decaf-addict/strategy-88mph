// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IBancorRegistry {
    function getAddress(bytes32 _network) external returns (address _router);
}

interface IBancorRouter {
    function conversionPath(address _sourceToken, address _targetToken)
        external
        returns (address[] memory);

    function claimAndConvert(
        address[] memory _path,
        uint256 _amount,
        uint256 _minReturn
    ) external returns (uint256 _out);

    // for eth
    function convert(
        address[] memory _path,
        uint256 _amount,
        uint256 _minReturn
    ) external payable returns (uint256 _out);
}
