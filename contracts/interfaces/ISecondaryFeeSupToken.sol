// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface ISecondaryFeeSupToken is IERC1155 {
//    mapping (uint256 => address) public creators;
    function getFeeRecipients(uint256 id) external view returns (address payable[] memory);
    function getFeeBps(uint256 id) external view returns (uint256[] memory);
}
