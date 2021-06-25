// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "../interfaces/ICatharsisAuction.sol";

contract StackSellAttacker is ERC1155Holder {

    ICatharsisAuction public auction;

    constructor(ICatharsisAuction _auction) {
        auction = _auction;
    }

    function placeBid(uint256 auctionId) external payable virtual {
        auction.placeBid{value: msg.value}(auctionId);
    }

    receive() external payable {
        if (msg.sender == address(auction)) {
            revert("Stacker: I'm a bad boy on receive");
        }
    }

//    fallback() external payable {
//        if (msg.sender == address(auction)) {
//            revert("Stacker: I'm a bad boy on fallback");
//        }
//    }
}