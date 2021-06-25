// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract Helper {
    function getBlockTimestamp() public view returns (uint256) {
        return block.timestamp;
    }

    function getBalance(address _dest) public view returns (uint256) {
        return address(_dest).balance;
    }
}