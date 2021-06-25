import * as BN from "bn.js";

// @ts-ignore
import { ethers, waffle } from "hardhat";
import { Signer, Contract } from "ethers";
import { use, assert, expect } from "chai";
import { solidity } from "ethereum-waffle";

use(solidity);

const {
    time,
    expectRevert, // Assertions for transactions that should fail
} = require('@openzeppelin/tests-helpers');

const FEE_TO_ADDRESS: String = '0x0000000000000000000000000000000000000FEE'

interface Status<Number> {
    AWAITING,
    INITIATED,
    IN_PROGRESS,
    ENDED,
    CLOSED,
    CANCELLED
}

const status: Status<Number> = Object.freeze({
    AWAITING: 0,
    INITIATED: 1,
    IN_PROGRESS: 2, // after first bid
    ENDED: 3, // after 24h
    CLOSED: 4, // after withdraw
    CANCELLED: 5
})

describe("CatharsisAuction", function () {
    let accounts: Signer[];

    let OWNER: string
    let SELLER: string
    let BUYER1: string
    let BUYER2: string
    let BUYER3: string
    let SECOND_OWNER: string

    let OWNER_SIGNER: Signer
    let SELLER_SIGNER: Signer
    let BUYER1_SIGNER: Signer
    let BUYER2_SIGNER: Signer
    let BUYER3_SIGNER: Signer
    let SECOND_OWNER_SIGNER: Signer

    let helper: Contract
    let stacker: Contract

    let auction: Contract
    let base1155Token: Contract

    const DEFAULT_FEE_DECIMAL = 10000

    const createAuction = async (contract = auction, singer = OWNER_SIGNER) => {
        return contract.connect(singer).createNew(
            base1155Token.address,
            1,
            1,
            DEFAULT_FEE_DECIMAL,
            0
        );
    }

    before('Configuration',async function () {
        accounts = await ethers.getSigners();

        OWNER_SIGNER = accounts[0];
        SELLER_SIGNER = accounts[1];
        BUYER1_SIGNER = accounts[2];
        BUYER2_SIGNER = accounts[3];
        BUYER3_SIGNER = accounts[4];
        SECOND_OWNER_SIGNER = accounts[5];

        OWNER = await OWNER_SIGNER.getAddress()
        SELLER = await SELLER_SIGNER.getAddress()
        BUYER1 = await BUYER1_SIGNER.getAddress()
        BUYER2 = await BUYER2_SIGNER.getAddress()
        BUYER3 = await BUYER3_SIGNER.getAddress()
        SECOND_OWNER = await SECOND_OWNER_SIGNER.getAddress()

        const CatharsisAuction = await ethers.getContractFactory("CatharsisAuction");
        auction = await CatharsisAuction.deploy();

        const CollectionMock = await ethers.getContractFactory("CollectionMock");

        // string memory name,
        // string memory symbol,
        // string memory contractURI,
        // string memory tokenURIPrefix,
        // address signer
        base1155Token = await CollectionMock.deploy('Token Erc1155', 'XXX', '', '', SECOND_OWNER);

        const Helper = await ethers.getContractFactory("Helper");
        helper = await Helper.deploy();

        const StackSellAttacker = await ethers.getContractFactory("StackSellAttacker");
        stacker = await StackSellAttacker.deploy(auction.address);

    });

    describe("Auction base usage", function () {

        let feeAbsolutePercent = 8 // 8 from 10000

        before(async () => {

            // uint256 id, Fee[] memory fees, uint256 supply, string memory uri
            await base1155Token.connect(OWNER_SIGNER).mint(1, [{recipient: OWNER, value: feeAbsolutePercent}], 200, "example.com")
            await base1155Token.connect(OWNER_SIGNER).setApprovalForAll(auction.address, true)
            await base1155Token.connect(OWNER_SIGNER).setApprovalForAll(SELLER, true)
            await base1155Token.connect(SELLER_SIGNER).safeTransferFrom(OWNER, SELLER, 1, 100, "0x")
            await base1155Token.connect(SELLER_SIGNER).setApprovalForAll(auction.address, true)

            // IERC1155 _token,
            // uint256 _tokenType,
            // uint256 _tokenAmount,
            // uint256 _initialPrice,
            // uint256 _initialDate
            // await auction.connect(OWNER_SIGNER).createNew(
            //     base1155Token.address,
            //     1,
            //     1,
            //     100,
            //     0
            // );
            await createAuction()
        })

        beforeEach(async () => {
            await createAuction()
        })

        it('should create new auction', async () => {
            let result = await createAuction()

            const expectedAuctionId = Number(await auction.index());

            assert.equal((await auction.index()), expectedAuctionId, "Bed index")
            assert.equal((await auction.totalAuctions(OWNER)), expectedAuctionId, "Total auctions")
        })

        it('should success bid', async () => {
            assert.include(
                [
                    status.INITIATED,
                    status.IN_PROGRESS,
                ],
                Number(await auction.getStatus(1))
            )

            let nextBid = (await auction.countNextMinBidPrice(1)).toString()

            await auction.connect(BUYER1_SIGNER).placeBid(1, { value: nextBid });

            assert.include(
                [
                    status.IN_PROGRESS,
                ],
                Number(await auction.getStatus(1))
            )
        })

        it('should success overbid', async () => {
            const expectedAuctionId = Number(await auction.index());

            let nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()
            await auction.connect(BUYER1_SIGNER).placeBid(expectedAuctionId, { value: nextBid });
            nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()
            await auction.connect(BUYER2_SIGNER).placeBid(expectedAuctionId, { value: nextBid });
            nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()
            await auction.connect(BUYER3_SIGNER).placeBid(expectedAuctionId, { value: nextBid });

            assert.equal(Number(await auction.totalBids(expectedAuctionId)), 3, "Wrong bids")
        })

        it('should success place bid and withdraw on close call', async () => {
            const expectedAuctionId = Number(await auction.index());
            let nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()
            await auction.connect(BUYER1_SIGNER).placeBid(expectedAuctionId, { value: nextBid });

            let closedAt = Number(await auction.biddingEnd(expectedAuctionId))
            await time.increaseTo(closedAt + 100);
            await auction.connect(BUYER1_SIGNER).close(expectedAuctionId);
        })

        it('should success place bid and withdraw on close call, if fee on', async () => {
            const expectedAuctionId = Number(await auction.index());

            await auction.connect(OWNER_SIGNER).setFeeTo(FEE_TO_ADDRESS);
            await auction.connect(OWNER_SIGNER).setFeeLimit(50);

            const bidValue = 1000000
            const feePercent = Number(await auction.feeLimit())

            let expectedBalanceChange = (bidValue / 100) * feePercent
            await auction.connect(BUYER1_SIGNER).placeBid(expectedAuctionId, { value: bidValue });

            let closedAt = Number(await auction.biddingEnd(expectedAuctionId))
            await time.increaseTo(closedAt + 100);

            let feeBalanceBefore = Number(await helper.getBalance(FEE_TO_ADDRESS))
            await auction.connect(BUYER1_SIGNER).close(expectedAuctionId);

            let feeBalanceAfter = Number(await helper.getBalance(FEE_TO_ADDRESS))

            assert.equal(feeBalanceAfter - feeBalanceBefore, expectedBalanceChange, "Not properly changes")
        })

        it('about how stacker will not stack current action', async () => {
            const expectedAuctionId = Number(await auction.index());

            let nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()
            // bed caller
            await stacker.connect(BUYER1_SIGNER).placeBid(expectedAuctionId, { value: nextBid })

            let secondBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()
            // next bidder
            await auction.connect(BUYER2_SIGNER).placeBid(expectedAuctionId, { value: secondBid });

            assert.equal(Number(await auction.getPendingWithdrawal(stacker.address)), nextBid, "Not equal to deposit")
        })

        it('should fail on bid if user try overbid itself bid', async () => {
            const expectedAuctionId = Number(await auction.index());

            let nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()

            await auction.connect(BUYER1_SIGNER).placeBid(expectedAuctionId, { value: nextBid })

            nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()

            await expectRevert(
                auction.connect(BUYER1_SIGNER).placeBid(expectedAuctionId, { value: nextBid }),
                'Auction: attempt to outbid your bet'
            )
        })

        it('should fail on bid if user try send value less then last bid or less then init bid value', async () => {
            const expectedAuctionId = Number(await auction.index());

            let nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()

            auction.connect(BUYER1_SIGNER).placeBid(expectedAuctionId, { value: nextBid })

            let theSameBid = nextBid

            await expectRevert(
                auction.connect(BUYER2_SIGNER).placeBid(expectedAuctionId, { value: theSameBid }),
                'Auction: not enough to outbid'
            )
        })

        it('should fail on bid if wrong status', async () => {
            let blockTimestamp = Number(await helper.getBlockTimestamp())

            await auction.connect(OWNER_SIGNER).createNew(
                base1155Token.address,
                1,
                1,
                DEFAULT_FEE_DECIMAL,
                blockTimestamp + 1000
            );

            const expectedAuctionId = Number(await auction.index());

            assert.include(
                [
                    status.AWAITING,
                ],
                Number(await auction.getStatus(expectedAuctionId))
            )

            let nextBid = (await auction.countNextMinBidPrice(expectedAuctionId)).toString()

            await expectRevert(
                auction.connect(BUYER1_SIGNER).placeBid(expectedAuctionId, { value: nextBid }),
                'Auction: bet not available'
            )
        })

        it('should success cancel bid by seller', async () => {
            let blockTimestamp = Number(await helper.getBlockTimestamp())

            await auction.connect(SELLER_SIGNER).createNew(
                base1155Token.address,
                1,
                1,
                DEFAULT_FEE_DECIMAL,
                blockTimestamp + 1000
            );

            const expectedAuctionId = Number(await auction.index());

            assert.include(
                [
                    status.AWAITING,
                    status.INITIATED
                ],
                Number(await auction.getStatus(expectedAuctionId))
            )

            await auction.connect(SELLER_SIGNER).cancel(expectedAuctionId);
        })

        it('should fail on cancel bid, if caller not seller', async () => {
            let blockTimestamp = Number(await helper.getBlockTimestamp())

            await auction.connect(SELLER_SIGNER).createNew(
                base1155Token.address,
                1,
                1,
                DEFAULT_FEE_DECIMAL,
                blockTimestamp + 1000
            );

            const expectedAuctionId = Number(await auction.index());

            assert.include(
                [
                    status.AWAITING,
                    status.INITIATED
                ],
                Number(await auction.getStatus(expectedAuctionId))
            )

            await expectRevert(
                auction.connect(BUYER1_SIGNER).cancel(expectedAuctionId),
                'Auction: not seller'
            )
        })
    })

})