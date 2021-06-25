// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface ITaxAuction {

    function feeTo() external view returns (address);

    function feeLimit() external view returns (uint256);

    // @dev dest should not be zero address. if dest is contract,
    // it should implement IERC165
    function setFeeTo(address dest) external;

    function setFeeLimit(uint256 percent) external;
}