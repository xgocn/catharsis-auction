// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface ICatharsisAuction {
    function createNew(
        IERC1155 _token,
        uint256 _tokenType,
        uint256 _tokenAmount,
        uint256 _initialPrice,
        uint256 _initialDate
    ) external returns (uint256 auctionId);

    function placeBid(uint256 auctionId) external payable;

    function getStatus(uint256 auctionId) external view returns (uint256);

    function biddingEnd(uint256 auctionId) external view returns (uint256);

    function totalAuctions(address _user) external view returns (uint256);

    function totalBids(uint _auctionId) external view returns (uint256 bids);

    // Returns last auction id
    function index() external view returns (uint256 bids);
}