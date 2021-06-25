// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ITaxAuction.sol";
import "./interfaces/ISecondaryFeeSupToken.sol";
import "./SendValueWithFallbackWithdraw.sol";
import "./ERC1155AcceptanceChecker.sol";

/**
 * @title CatharsisAuction main contract.
 */
contract CatharsisAuction is
    ITaxAuction,
    Ownable,
    ERC1155Holder,
    SendValueWithFallbackWithdraw,
    ERC1155AcceptanceChecker
{

    enum Status {
        AWAITING,
        INITIATED,
        IN_PROGRESS, // after first bid
        ENDED, // after 24h
        CLOSED, // after withdraw
        CANCELLED
    }

    // NFT details
    struct Token {
        IERC1155 addr;
        uint256 id;
        uint256 amount;
        // True if has secondary fee interface
        bool withSecondaryFee;
    }

    struct Auction {
        // auction initial data
        uint256 initialDate;
        uint256 biddingStart;
        uint256 initialPrice;
        address seller;

        bool canceled;
        bool ended;

        address highestBidder;
        uint256 highestBid;

        Token token;

        uint bids;

        address previousBidder;
        uint256 previousBid;
    }

    address public override feeTo;
    uint256 public override feeLimit;

    uint256 constant DEFAULT_FEE_DECIMAL = 10000;
    uint256 constant TIMEFRAME = 1 days; // i.e. 24h

    uint256 public index;

    mapping (uint256 => Auction) public auctions;
    mapping (address => uint256[]) public userAuctions;

    event AuctionCreated(uint256 auctionId);
    event AuctionStarted(uint auctionId, uint timestamp);
    event AuctionEnded(uint auctionId, address winner, uint highestBid);
    event AuctionClosed(uint auctionId, address winner, uint highestBid);
    event AuctionCanceled(uint auctionId);
    event BidPlaced(
        uint auctionId,
        IERC1155 indexed token,
        uint256 id,
        address bidder,
        uint256 bidPrice
    );
    event Received(address from, uint256 amount);
    event FeeToSet(address dest);
    event FeeLimitSet(uint256 percent);

    receive() external payable {
        revert("Auction: don't accept direct ether bid");
    }

    fallback() external payable {
        if (msg.value != 0) {
            emit Received(_msgSender(), msg.value);
        }
    }

    /**
     * @dev Creates new auction, and sets out
     * the details of the deal, like a {_token}, {_tokenId}, {_tokenAmount},
     * {_initialPrice} and {_initialDate}
     */
    function createNew(
        IERC1155 _token,
        uint256 _tokenId,
        uint256 _tokenAmount,
        uint256 _initialPrice,
        uint256 _initialDate
    ) external returns (uint256 auctionId) {
        require(_token.isApprovedForAll(_msgSender(), address(this)), "Token not approved");
        require(_initialPrice != 0, "Initial price zero?");
        require(
            _token.balanceOf(_msgSender(), _tokenId) >= _tokenAmount,
            "Auction: deposit NFT not enough balance"
        );
        require(_initialPrice >= DEFAULT_FEE_DECIMAL, "Very low initial price DEFAULT_FEE_DECIMAL");

        // check if seller can get back his ntf
        _doSafeTransferAcceptanceCheck(
            address(this),
            address(this),
            _msgSender(),
            _tokenId,
            _tokenAmount,
            ""
        );

        _token.safeTransferFrom(_msgSender(), address(this), _tokenId, _tokenAmount, "");

        index++;
        auctionId = index;

        Auction storage a = auctions[auctionId];

        a.token.addr = _token;
        a.token.id = _tokenId;
        a.token.amount = _tokenAmount;

        /*
         * bytes4(keccak256('getFeeBps(uint256)')) == 0x0ebd4c7f
         * bytes4(keccak256('getFeeRecipients(uint256)')) == 0xb9c4d9fb
         *
         * => 0x0ebd4c7f ^ 0xb9c4d9fb == 0xb7799584
         */
        try IERC165(_token).supportsInterface(bytes4(0xb7799584)) returns (bool supported) {
            a.token.withSecondaryFee = supported;

            // check if anything is ok with math
            countSecondaryFees(address(_token), _tokenId, _initialPrice);

        } catch {
            // nothing to do :(
        }

        a.initialPrice = _initialPrice;
        a.highestBid = _initialPrice;

        if (_initialDate != 0) {
            if (_initialDate <= block.timestamp) {
                _initialDate = block.timestamp;
            }
        } else {
            _initialDate = block.timestamp;
        }

        a.initialDate = _initialDate;
        a.seller = _msgSender();

        userAuctions[_msgSender()].push(auctionId);

        emit AuctionCreated(auctionId);
    }

    function totalBids(uint _auctionId) public view returns (uint256 bids) {
        return auctions[_auctionId].bids;
    }

    function totalAuctions(address _user) public view returns (uint256) {
        return userAuctions[_user].length;
    }

    /**
     * @dev Returns bidding end date. If zero, auction is not started.
     */
    function biddingEnd(uint256 auctionId) public view returns (uint256) {
        return auctions[auctionId].biddingStart + TIMEFRAME;
    }

    /**
     * @dev Returns current auction status.
     */
    function getStatus(uint256 auctionId) public view returns (Status status) {
        require(auctionId <= index && auctionId != 0, "Auction: auction not exist");

        Auction memory a = auctions[auctionId];

        if (block.timestamp < a.initialDate) {
            return Status.AWAITING;
        }

        if (totalBids(auctionId) == 0) {
            if (a.canceled) {
                status = Status.CANCELLED;
            } else {
                status = Status.INITIATED;
            }
        } else {
            if (block.timestamp > biddingEnd(auctionId)) {
                if (a.ended) {
                    status = Status.CLOSED;
                } else {
                    status = Status.ENDED;
                }
            } else {
                status = Status.IN_PROGRESS;
            }
        }
    }

    /**
     * @dev Make bid {msg.value} to contract.
     */
    function placeBid(uint256 auctionId) external payable nonReentrant {
        Status status = getStatus(auctionId);

        require(
            status == Status.IN_PROGRESS ||
            status == Status.INITIATED,
            "Auction: bet not available"
        );

        Auction storage a = auctions[auctionId];

        require(_msgSender() != a.highestBidder, "Auction: attempt to outbid your bet");
        require(msg.value >= a.initialPrice, "Auction: lower then initial price bid");
        if (a.highestBid != a.initialPrice) {
            require(msg.value > a.highestBid, "Auction: not enough to outbid");
        }

        // check if buyer can get his ntf
        _doSafeTransferAcceptanceCheck(
            address(this),
            address(this),
            _msgSender(),
            a.token.id,
            a.token.amount,
            ""
        );

        if (a.bids == 0) {
            a.biddingStart = block.timestamp;
            emit AuctionStarted(auctionId, a.biddingStart);
        }

        a.previousBid = a.highestBid;
        a.previousBidder = a.highestBidder;

        // update bid
        a.highestBid = msg.value;
        a.highestBidder = _msgSender();

        a.bids += 1;

        if (a.previousBidder != address(0)) {
            _withdrawEther(a.previousBidder, a.previousBid);
        }

        emit BidPlaced(auctionId, a.token.addr, a.token.id, _msgSender(), msg.value);
    }

    /**
     * @dev End the auction and send the highest bid
     * to the beneficiary.
     */
    function close(uint256 auctionId) external nonReentrant {
        require(getStatus(auctionId) == Status.ENDED, "Auction: close impossible");

        Auction storage a = auctions[auctionId];
        a.ended = true;

        uint fees = 0;
        if (feeTo != address(0)) {
            unchecked {
                fees = feeLimit * (a.highestBid / 1000); // 1000 - 100%
            }
            _withdrawEther(feeTo, fees); // fee to service
        }

        if (a.token.withSecondaryFee) {
            fees += _transferSecondaryFees(address(a.token.addr), a.token.id, a.highestBid - fees);
        }

        if (fees <= a.highestBid) {
            _withdrawEther(a.seller, a.highestBid - fees); // income to seller
        }

        _withdrawNFT(a.token.addr, a.highestBidder, a.token.id, a.token.amount); // nft to winner
        emit AuctionEnded(auctionId, a.highestBidder, a.highestBid);
    }

    /**
     * @dev Cancel current auction, at any time before {Status.IN_PROGRESS}.
     */
    function cancel(uint256 auctionId) external {
        require(getStatus(auctionId) <= Status.INITIATED, "Auction: cancel impossible");

        Auction storage a = auctions[auctionId];

        require(_msgSender() == a.seller, "Auction: not seller");

        a.canceled = true;
        _withdrawNFT(a.token.addr, a.seller, a.token.id, a.token.amount); // return NFT back to beneficiary (user)
        emit AuctionCanceled(auctionId);
    }

    /**
     * @dev Helps to count next minimum bid price by {auctionId}.
     */
    function countNextMinBidPrice(uint256 auctionId) external view returns (uint256 price) {
        price = auctions[auctionId].highestBid + 1;
    }

    function setFeeTo(address _dest) external override onlyOwner {
        require(_dest != address(0), "Not fee to zero");
        feeTo = _dest;
        emit FeeToSet(_dest);
    }

    function setFeeLimit(uint256 _percent) external override onlyOwner {
        require(_percent <= 50, "No more then 50%");
        feeLimit = _percent;
        emit FeeLimitSet(_percent);
    }

    /**
     * @dev Withdraw {_amount} ETH to {_beneficiary}.
     */
    function _withdrawEther(address _beneficiary, uint256 _amount) internal {
        require(address(this).balance >= _amount, "Auction: not enough balance");

        _sendValueWithFallbackWithdraw(payable(_beneficiary), _amount);
    }

    /**
     * @dev Withdraw NFT to {_beneficiary}.
     */
    function _withdrawNFT(IERC1155 _token, address _beneficiary, uint _tokenId, uint _tokenAmount) internal {
        _token.safeTransferFrom(address(this), _beneficiary, _tokenId, _tokenAmount, "");
    }

    /**
     * @dev Transfer secondary fees, SHOULD be executed only if token support 0xb7799584 interface.
     */
    function _transferSecondaryFees(address _token, uint256 _tokenId, uint256 _price) internal returns (uint256 result) {
        uint[] memory fees = ISecondaryFeeSupToken(_token).getFeeBps(_tokenId);
        address payable[] memory recipients = ISecondaryFeeSupToken(_token).getFeeRecipients(_tokenId);
        uint256 fee;
        uint256 i = 0;
        uint feeLen = fees.length;
        for (i; i < feeLen; i++) {
            fee = _getFee(_price, fees[i]);
            result += fee;

            require(result <= _price, "FEE_X2_OVERFLOW");

            _withdrawEther(recipients[i], fee);
        }
    }

    /**
     * @dev Count secondary fees for token.
     * Throw: if token dont support interface
     * Throw: if token has very high fee decimal
     */
    function countSecondaryFees(address _token, uint256 _tokenId, uint256 _price) public view returns (uint256 result) {
        uint[] memory fees = ISecondaryFeeSupToken(_token).getFeeBps(_tokenId);
        uint256 i = 0;
        uint256 feeLen = fees.length;
        for (i; i < feeLen; i++) {
            result += _getFee(_price, fees[i]);
        }

        require(result <= _price, "FEE_X2_OVERFLOW");
    }

    function _getFee(uint256 _amount, uint256 _fee) internal pure returns(uint256) {
        unchecked {
            return _amount * _fee / DEFAULT_FEE_DECIMAL;
        }
    }
}