import { expect } from "chai";
import { ethers } from "hardhat";
import {
  deployAll,
  approveNFTToMarket,
  STARTING_PRICE,
  BID_ALICE,
  BID_BOB,
  SALT,
  fastForwardDays,
  AUCTION_DURATION_DAYS,
  REVEAL_DURATION_DAYS
} from "./utils";

describe("MarketPlace (commit–reveal auctions)", () => {
  it("create_auction: non-owner reverts", async () => {
    const d = await deployAll();
    await expect(
      d.market.connect(d.bob).create_auction(
        await d.erc721.getAddress(),
        d.tokenId,
        STARTING_PRICE,
        await d.erc20.getAddress()
      )
    ).to.be.revertedWith("Caller is not owner");
  });

  it("create_auction: start price is zero reverts", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);

    await expect(
      d.market.connect(d.owner).create_auction(
        await d.erc721.getAddress(),
        d.tokenId,
        0,
        await d.erc20.getAddress()
      )
    ).to.be.revertedWith("Start price is zero");
  });

  it("create_auction: currency address zero reverts", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);

    await expect(
      d.market.connect(d.owner).create_auction(
        await d.erc721.getAddress(),
        d.tokenId,
        STARTING_PRICE,
        ethers.ZeroAddress
      )
    ).to.be.revertedWith("Currency address is zero");
  });

  it("create_auction: ok", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);

    const tx = await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );
    const rc = await tx.wait();
    const ev = rc!.logs.find((l: any) => l.fragment?.name === "AuctionCreated");
    expect(ev).to.not.be.undefined;

    // read auction
    const auctionId = 1n;
    const a = await d.market.get_auction(auctionId);
    expect(a.owner).to.equal(d.ownerAddr);
    expect(a.token_address).to.equal(await d.erc721.getAddress());
    expect(a.token_id).to.equal(d.tokenId);
    expect(a.start_price).to.equal(STARTING_PRICE);
    expect(a.highest_bid).to.equal(0n);
    expect(a.highest_bidder).to.equal(ethers.ZeroAddress);
    expect(a.is_open).to.equal(true);
    expect(a.is_finalized).to.equal(false);

    // NFT should be custody of marketplace
    expect(await d.erc721.ownerOf(d.tokenId)).to.equal(await d.market.getAddress());
  });

  it("commit_bid: invalid auction reverts", async () => {
    const d = await deployAll();
    await expect(
      d.market.connect(d.bob).commit_bid(2, 200n, SALT)
    ).to.be.revertedWith("Invalid auction");
  });

  it("commit_bid: owner cannot bid", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await expect(
      d.market.connect(d.owner).commit_bid(1, 200n, SALT)
    ).to.be.revertedWith("Bidder is owner");
  });

  it("commit_bid: auction closed reverts", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await fastForwardDays(AUCTION_DURATION_DAYS); // close auction
    await expect(
      d.market.connect(d.bob).commit_bid(1, 200n, SALT)
    ).to.be.revertedWith("Auction closed");
  });

  it("commit_bid: less than start price reverts", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await expect(
      d.market.connect(d.bob).commit_bid(1, 0n, SALT)
    ).to.be.revertedWith("Amount less than start price");
  });

  it("commit_bid: salt is zero reverts", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await expect(
      d.market.connect(d.bob).commit_bid(1, STARTING_PRICE, ethers.ZeroHash)
    ).to.be.revertedWith("Salt is zero");
  });

  it("commit_bid: insufficient funds reverts", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    // drain Bob then try to commit huge
    await d.erc20.connect(d.bob).transfer(d.ownerAddr, await d.erc20.balanceOf(d.bobAddr));

    await expect(
      d.market.connect(d.bob).commit_bid(1, STARTING_PRICE, SALT)
    ).to.be.revertedWith("Insufficient funds");
  });

  it("commit_bid: ok (count increments and escrow balance rises)", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    const mktAddr = await d.market.getAddress();
    const before = await d.erc20.balanceOf(mktAddr);

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    const c1 = await d.market.get_auction_bid_count(1);
    expect(c1).to.equal(1n);

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    const c2 = await d.market.get_auction_bid_count(1);
    expect(c2).to.equal(2n);

    const after = await d.erc20.balanceOf(mktAddr);
    expect(after - before).to.equal(BID_BOB * 2n);
  });

  it("reveal_bid: when no bid committed -> revert", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await fastForwardDays(AUCTION_DURATION_DAYS); // auction closed
    await expect(
      d.market.connect(d.bob).reveal_bid(1, BID_BOB, SALT)
    ).to.be.revertedWith("No bid found");
  });

  it("reveal_bid: auction still open -> revert", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await expect(
      d.market.connect(d.bob).reveal_bid(1, BID_BOB, SALT)
    ).to.be.revertedWith("Auction is still open");
  });

  it("reveal_bid: wrong amount reverts", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await fastForwardDays(AUCTION_DURATION_DAYS);
    await expect(
      d.market.connect(d.bob).reveal_bid(1, BID_ALICE /* wrong */, SALT)
    ).to.be.revertedWith("Wrong amount or salt");
  });

  it("reveal_bid: wrong salt reverts", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await fastForwardDays(AUCTION_DURATION_DAYS);
    await expect(
      d.market.connect(d.bob).reveal_bid(1, BID_BOB, ethers.id("wrong_salt"))
    ).to.be.revertedWith("Wrong amount or salt");
  });

  it("reveal_bid: ok (event)", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await fastForwardDays(AUCTION_DURATION_DAYS);

    await expect(d.market.connect(d.bob).reveal_bid(1, BID_BOB, SALT))
      .to.emit(d.market, "BidRevealed")
      .withArgs(await d.bob.getAddress(), 1, BID_BOB);
  });

  it("finalize: while auction open -> revert", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );
    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);

    await expect(d.market.finalize_auction(1)).to.be.revertedWith("Auction is still open");
  });

  it("finalize: during reveal window -> revert", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );
    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await fastForwardDays(AUCTION_DURATION_DAYS); // auction closed
    await d.market.connect(d.bob).reveal_bid(1, BID_BOB, SALT);

    await expect(d.market.finalize_auction(1)).to.be.revertedWith("Reveal time not over");
  });

  it("finalize: cannot double finalize", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await fastForwardDays(AUCTION_DURATION_DAYS);
    await d.market.connect(d.bob).reveal_bid(1, BID_BOB, SALT);
    await fastForwardDays(REVEAL_DURATION_DAYS);

    await d.market.finalize_auction(1);
    await expect(d.market.finalize_auction(1)).to.be.revertedWith("Auction already finalized");
  });

  it("finalize: ok (Alice wins, Bob refunded, owner paid)", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    // commits
    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await d.market.connect(d.alice).commit_bid(1, BID_ALICE, SALT);

    await fastForwardDays(AUCTION_DURATION_DAYS);

    // reveals
    await d.market.connect(d.bob).reveal_bid(1, BID_BOB, SALT);
    await d.market.connect(d.alice).reveal_bid(1, BID_ALICE, SALT);

    // balances before finalize
    const bobBefore = await d.erc20.balanceOf(d.bobAddr);
    const aliceBefore = await d.erc20.balanceOf(d.aliceAddr);
    const ownerBefore = await d.erc20.balanceOf(d.ownerAddr);
    const marketBefore = await d.erc20.balanceOf(await d.market.getAddress());

    await fastForwardDays(REVEAL_DURATION_DAYS);

    await d.market.finalize_auction(1);

    // Alice wins (highest)
    expect(await d.erc721.ownerOf(d.tokenId)).to.equal(d.aliceAddr);

    // Bob refunded
    expect(await d.erc20.balanceOf(d.bobAddr)).to.equal(bobBefore + BID_BOB);

    // Alice's external balance unchanged at finalize time (son dépôt a déjà été pris en escrow)
    expect(await d.erc20.balanceOf(d.aliceAddr)).to.equal(aliceBefore);

    // Owner paid highest bid
    expect(await d.erc20.balanceOf(d.ownerAddr)).to.equal(ownerBefore + BID_ALICE);

    // Market holds no ERC20 after finalize
    expect(await d.erc20.balanceOf(await d.market.getAddress())).to.equal(0n);
  });

  it("withdraw: loser already refunded -> revert", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await d.market.connect(d.alice).commit_bid(1, BID_ALICE, SALT);
    await fastForwardDays(AUCTION_DURATION_DAYS);
    await d.market.connect(d.bob).reveal_bid(1, BID_BOB, SALT);
    await d.market.connect(d.alice).reveal_bid(1, BID_ALICE, SALT);
    await fastForwardDays(REVEAL_DURATION_DAYS);
    await d.market.finalize_auction(1);

    await expect(
      d.market.connect(d.bob).withdraw_unrevealed_bid(1, BID_BOB, SALT)
    ).to.be.revertedWith("Bid refunded");
  });

  it("withdraw: winner cannot withdraw -> revert", async () => {
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await d.market.connect(d.alice).commit_bid(1, BID_ALICE, SALT);
    await fastForwardDays(AUCTION_DURATION_DAYS);
    await d.market.connect(d.bob).reveal_bid(1, BID_BOB, SALT);
    await d.market.connect(d.alice).reveal_bid(1, BID_ALICE, SALT);
    await fastForwardDays(REVEAL_DURATION_DAYS);
    await d.market.finalize_auction(1);

    await expect(
      d.market.connect(d.alice).withdraw_unrevealed_bid(1, BID_ALICE, SALT)
    ).to.be.revertedWith("Caller already won auction");
  });

  it("withdraw: ok (pendant la période de reveal, avant finalize)", async () => {
    // scénario : 1 seul bidder (Bob) commit, auction close, Bob retire pendant reveal avant finalize
    const d = await deployAll();
    await approveNFTToMarket(d.erc721, d.market, d.owner, d.tokenId);
    await d.market.connect(d.owner).create_auction(
      await d.erc721.getAddress(),
      d.tokenId,
      STARTING_PRICE,
      await d.erc20.getAddress()
    );

    await d.market.connect(d.bob).commit_bid(1, BID_BOB, SALT);
    await fastForwardDays(AUCTION_DURATION_DAYS); // auction closed

    const before = await d.erc20.balanceOf(d.bobAddr);
    await d.market.connect(d.bob).withdraw_unrevealed_bid(1, BID_BOB, SALT);
    const after = await d.erc20.balanceOf(d.bobAddr);

    expect(after).to.equal(before + BID_BOB);
  });
});
