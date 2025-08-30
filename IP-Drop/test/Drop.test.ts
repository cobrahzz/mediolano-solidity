import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

type ClaimConditions = {
  startTime: bigint;
  endTime: bigint;
  price: bigint;
  maxQuantityPerWallet: bigint;
  paymentToken: string; // address
};

const NAME = "IP Drop Collection";
const SYMBOL = "IPDC";
const BASE_URI = "https://api.example.com/metadata/";

async function deployIPDrop(
  owner: string,
  initial: ClaimConditions,
  allowlistEnabled = true,
  maxSupply = 1000n
) {
  const F = await ethers.getContractFactory("IPDrop");
  const c = await F.deploy(
    NAME,
    SYMBOL,
    BASE_URI,
    maxSupply,
    owner,
    initial,
    allowlistEnabled
  );
  await c.waitForDeployment();
  return c;
}

describe("IPDrop", () => {
  const START = 1000n;
  const END = 2000n;
  const ZERO = ethers.ZeroAddress;

  async function setup() {
    const [owner, user, ...rest] = await ethers.getSigners();

    const initial: ClaimConditions = {
      startTime: START,
      endTime: END,
      price: 0n,
      maxQuantityPerWallet: 5n,
      paymentToken: ZERO,
    };

    const contract = await deployIPDrop(await owner.getAddress(), initial, true, 1000n);
    return { contract, owner, user, rest };
  }

  async function setTime(ts: bigint) {
    await time.setNextBlockTimestamp(Number(ts));
  }

  it("deployment_and_initialization", async () => {
    const { contract } = await setup();

    expect(await contract.name()).to.equal(NAME);
    expect(await contract.symbol()).to.equal(SYMBOL);
    expect(await contract.max_supply()).to.equal(1000n);
    expect(await contract.total_supply()).to.equal(0n);
    expect(await contract.is_allowlist_enabled()).to.equal(true);

    const cond = await contract.get_claim_conditions();
    expect(cond.startTime).to.equal(START);
    expect(cond.endTime).to.equal(END);
    expect(cond.price).to.equal(0n);
    expect(cond.maxQuantityPerWallet).to.equal(5n);
  });

  it("allowlist_management", async () => {
    const { contract, owner, user } = await setup();

    expect(await contract.is_allowlisted(await user.getAddress())).to.equal(false);

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    expect(await contract.is_allowlisted(await user.getAddress())).to.equal(true);

    await contract.connect(owner).remove_from_allowlist(await user.getAddress());
    expect(await contract.is_allowlisted(await user.getAddress())).to.equal(false);
  });

  it("batch_allowlist_operations", async () => {
    const { contract, owner, rest } = await setup();
    const [u1, u2, u3] = rest;

    await contract.connect(owner).add_batch_to_allowlist([
      await u1.getAddress(),
      await u2.getAddress(),
      await u3.getAddress(),
    ]);

    expect(await contract.is_allowlisted(await u1.getAddress())).to.equal(true);
    expect(await contract.is_allowlisted(await u2.getAddress())).to.equal(true);
    expect(await contract.is_allowlisted(await u3.getAddress())).to.equal(true);
  });

  it("successful_free_claim", async () => {
    const { contract, owner, user } = await setup();

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);

    await contract.connect(user).claim(3n);

    expect(await contract.total_supply()).to.equal(3n);
    expect(await contract.balance_of(await user.getAddress())).to.equal(3n);
    expect(await contract.claimed_by_wallet(await user.getAddress())).to.equal(3n);
    expect(await contract.owner_of(1n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(3n)).to.equal(await user.getAddress());
  });

  it("claim_with_payment_setup", async () => {
    const { contract, owner, user, rest } = await setup();
    const erc20 = rest[0];

    await contract.connect(owner).add_to_allowlist(await user.getAddress());

    const paid: ClaimConditions = {
      startTime: START,
      endTime: END,
      price: 1_000_000_000_000_000_000n,
      maxQuantityPerWallet: 5n,
      paymentToken: await erc20.getAddress(), // just some address, not used to transfer here
    };
    await contract.connect(owner).set_claim_conditions(paid);

    const cond = await contract.get_claim_conditions();
    expect(cond.price).to.equal(paid.price);
    expect(cond.paymentToken).to.equal(paid.paymentToken);
  });

  it("claim_fails_when_not_allowlisted", async () => {
    const { contract, user } = await setup();
    await setTime(1500n);
    await expect(contract.connect(user).claim(1n)).to.be.revertedWith("Not on allowlist");
  });

  it("claim_fails_before_start_time", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(500n);
    await expect(contract.connect(user).claim(1n)).to.be.revertedWith("Claim not started");
  });

  it("claim_fails_after_end_time", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(2500n);
    await expect(contract.connect(user).claim(1n)).to.be.revertedWith("Claim ended");
  });

  it("claim_fails_exceeding_wallet_limit", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await expect(contract.connect(user).claim(6n)).to.be.revertedWith("Exceeds wallet limit");
  });

  it("multiple_claims_within_limit", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);

    await contract.connect(user).claim(2n);
    expect(await contract.balance_of(await user.getAddress())).to.equal(2n);
    expect(await contract.claimed_by_wallet(await user.getAddress())).to.equal(2n);

    await contract.connect(user).claim(2n);
    expect(await contract.balance_of(await user.getAddress())).to.equal(4n);
    expect(await contract.claimed_by_wallet(await user.getAddress())).to.equal(4n);

    await contract.connect(user).claim(1n);
    expect(await contract.balance_of(await user.getAddress())).to.equal(5n);
    expect(await contract.claimed_by_wallet(await user.getAddress())).to.equal(5n);
  });

  it("cumulative_claims_exceed_limit", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);

    await contract.connect(user).claim(3n);
    await contract.connect(user).claim(2n);
    await expect(contract.connect(user).claim(1n)).to.be.revertedWith("Exceeds wallet limit");
  });

  it("claim_fails_exceeding_max_supply", async () => {
    const { contract, owner, user } = await setup();

    await contract.connect(owner).set_claim_conditions({
      startTime: START,
      endTime: END,
      price: 0n,
      maxQuantityPerWallet: 2000n,
      paymentToken: ZERO,
    });

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);

    await expect(contract.connect(user).claim(1001n)).to.be.revertedWith("Exceeds max supply");
  });

  it("public_mint_when_allowlist_disabled", async () => {
    const { contract, owner, user } = await setup();

    await contract.connect(owner).set_allowlist_enabled(false);
    expect(await contract.is_allowlist_enabled()).to.equal(false);

    await setTime(1500n);
    await contract.connect(user).claim(2n);

    expect(await contract.balance_of(await user.getAddress())).to.equal(2n);
  });

  it("token_uri_generation", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await contract.connect(user).claim(1n);

    expect(await contract.token_uri(1n)).to.equal(`${BASE_URI}1`);
  });

  it("base_uri_update", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await contract.connect(user).claim(1n);

    await contract.connect(owner).set_base_uri("https://newapi.com/nft/");
    expect(await contract.token_uri(1n)).to.equal("https://newapi.com/nft/1");
  });

  it("transfer_functionality", async () => {
    const { contract, owner, user, rest } = await setup();
    const receiver = rest[0];

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await contract.connect(user).claim(2n);

    expect(await contract.owner_of(1n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await user.getAddress());
    expect(await contract.balance_of(await user.getAddress())).to.equal(2n);

    await contract.connect(user).transfer_from(await user.getAddress(), await receiver.getAddress(), 1n);

    expect(await contract.owner_of(1n)).to.equal(await receiver.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await user.getAddress());
    expect(await contract.balance_of(await user.getAddress())).to.equal(1n);
    expect(await contract.balance_of(await receiver.getAddress())).to.equal(1n);

    await contract.connect(user).transfer_from(await user.getAddress(), await receiver.getAddress(), 2n);

    expect(await contract.owner_of(1n)).to.equal(await receiver.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await receiver.getAddress());
    expect(await contract.balance_of(await user.getAddress())).to.equal(0n);
    expect(await contract.balance_of(await receiver.getAddress())).to.equal(2n);
  });

  it("erc721a_like_ownership_resolution_after_transfers", async () => {
    const { contract, owner, user, rest } = await setup();
    const user2 = rest[0];
    const user3 = rest[1];

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await contract.connect(user).claim(5n);

    expect(await contract.owner_of(1n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(5n)).to.equal(await user.getAddress());

    await contract.connect(user).transfer_from(await user.getAddress(), await user2.getAddress(), 1n);

    expect(await contract.owner_of(1n)).to.equal(await user2.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(5n)).to.equal(await user.getAddress());

    await contract.connect(user).transfer_from(await user.getAddress(), await user3.getAddress(), 3n);

    expect(await contract.owner_of(1n)).to.equal(await user2.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(3n)).to.equal(await user3.getAddress());
    expect(await contract.owner_of(4n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(5n)).to.equal(await user.getAddress());

    expect(await contract.balance_of(await user.getAddress())).to.equal(3n);
    expect(await contract.balance_of(await user2.getAddress())).to.equal(1n);
    expect(await contract.balance_of(await user3.getAddress())).to.equal(1n);
  });

  it("multiple_batch_transfers", async () => {
    const { contract, owner, rest } = await setup();
    const user1 = rest[0];
    const user2 = rest[1];
    const receiver = rest[2];

    await contract.connect(owner).add_to_allowlist(await user1.getAddress());
    await contract.connect(owner).add_to_allowlist(await user2.getAddress());
    await setTime(1500n);

    await contract.connect(user1).claim(3n); // tokens 1-3
    await contract.connect(user2).claim(3n); // tokens 4-6

    expect(await contract.owner_of(1n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(3n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(4n)).to.equal(await user2.getAddress());
    expect(await contract.owner_of(6n)).to.equal(await user2.getAddress());

    await contract.connect(user1).transfer_from(await user1.getAddress(), await receiver.getAddress(), 2n);
    await contract.connect(user2).transfer_from(await user2.getAddress(), await receiver.getAddress(), 5n);

    expect(await contract.owner_of(1n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await receiver.getAddress());
    expect(await contract.owner_of(3n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(4n)).to.equal(await user2.getAddress());
    expect(await contract.owner_of(5n)).to.equal(await receiver.getAddress());
    expect(await contract.owner_of(6n)).to.equal(await user2.getAddress());

    expect(await contract.balance_of(await user1.getAddress())).to.equal(2n);
    expect(await contract.balance_of(await user2.getAddress())).to.equal(2n);
    expect(await contract.balance_of(await receiver.getAddress())).to.equal(2n);
  });

  it("approval_and_transfer", async () => {
    const { contract, owner, user, rest } = await setup();
    const approved = rest[0];
    const receiver = rest[1];

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await contract.connect(user).claim(1n);

    await contract.connect(user).approve(await approved.getAddress(), 1n);
    expect(await contract.get_approved(1n)).to.equal(await approved.getAddress());

    await contract
      .connect(approved)
      .transfer_from(await user.getAddress(), await receiver.getAddress(), 1n);

    expect(await contract.owner_of(1n)).to.equal(await receiver.getAddress());
  });

  it("approval_for_all", async () => {
    const { contract, owner, user, rest } = await setup();
    const operator = rest[0];

    await contract.connect(owner).add_to_allowlist(await user.getAddress());

    await contract.connect(user).set_approval_for_all(await operator.getAddress(), true);
    expect(
      await contract.is_approved_for_all(await user.getAddress(), await operator.getAddress())
    ).to.equal(true);

    await contract.connect(user).set_approval_for_all(await operator.getAddress(), false);
    expect(
      await contract.is_approved_for_all(await user.getAddress(), await operator.getAddress())
    ).to.equal(false);
  });

  it("claim_conditions_update", async () => {
    const { contract, owner, rest } = await setup();
    const tokenAddr = await rest[0].getAddress();

    await contract.connect(owner).set_claim_conditions({
      startTime: 3000n,
      endTime: 4000n,
      price: 500_000_000_000_000_000n,
      maxQuantityPerWallet: 10n,
      paymentToken: tokenAddr,
    });

    const u = await contract.get_claim_conditions();
    expect(u.startTime).to.equal(3000n);
    expect(u.endTime).to.equal(4000n);
    expect(u.price).to.equal(500_000_000_000_000_000n);
    expect(u.maxQuantityPerWallet).to.equal(10n);
    expect(u.paymentToken).to.equal(tokenAddr);
  });

  it("multiple_users_claiming", async () => {
    const { contract, owner, rest } = await setup();
    const user1 = rest[0];
    const user2 = rest[1];
    const user3 = rest[2];

    await contract.connect(owner).add_to_allowlist(await user1.getAddress());
    await contract.connect(owner).add_to_allowlist(await user2.getAddress());
    await contract.connect(owner).add_to_allowlist(await user3.getAddress());
    await setTime(1500n);

    await contract.connect(user1).claim(2n);
    await contract.connect(user2).claim(3n);
    await contract.connect(user3).claim(1n);

    expect(await contract.balance_of(await user1.getAddress())).to.equal(2n);
    expect(await contract.balance_of(await user2.getAddress())).to.equal(3n);
    expect(await contract.balance_of(await user3.getAddress())).to.equal(1n);
    expect(await contract.total_supply()).to.equal(6n);

    expect(await contract.owner_of(1n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(3n)).to.equal(await user2.getAddress());
    expect(await contract.owner_of(4n)).to.equal(await user2.getAddress());
    expect(await contract.owner_of(5n)).to.equal(await user2.getAddress());
    expect(await contract.owner_of(6n)).to.equal(await user3.getAddress());
  });

  it("edge_case_timing", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());

    await setTime(START);
    await contract.connect(user).claim(1n);

    await setTime(END);
    await contract.connect(user).claim(1n);

    expect(await contract.balance_of(await user.getAddress())).to.equal(2n);
  });

  it("unauthorized_approval", async () => {
    const { contract, owner, user, rest } = await setup();
    const unauthorized = rest[0];
    const spender = rest[1];

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await contract.connect(user).claim(1n);

    await expect(
      contract.connect(unauthorized).approve(await spender.getAddress(), 1n)
    ).to.be.revertedWith("ERC721: approve caller is not token owner or approved for all");
  });

  it("unauthorized_transfer", async () => {
    const { contract, owner, user, rest } = await setup();
    const unauthorized = rest[0];
    const receiver = rest[1];

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await contract.connect(user).claim(1n);

    await expect(
      contract.connect(unauthorized).transfer_from(await user.getAddress(), await receiver.getAddress(), 1n)
    ).to.be.revertedWith("ERC721: caller is not token owner or approved");
  });

  it("paid_mint_using_wrong_function", async () => {
    const { contract, owner, user } = await setup();

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await contract.connect(owner).set_claim_conditions({
      startTime: START,
      endTime: END,
      price: 1_000_000_000_000_000_000n,
      maxQuantityPerWallet: 5n,
      paymentToken: ZERO,
    });

    await setTime(1500n);
    await expect(contract.connect(user).claim(1n)).to.be.revertedWith("Payment required");
  });

  it("free_mint_using_payment_function", async () => {
    const { contract, owner, user } = await setup();

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);

    await expect(contract.connect(user).claim_with_payment(1n)).to.be.revertedWith(
      "No payment required - use claim"
    );
  });

  it("large_batch_minting_efficiency", async () => {
    const { contract, owner, user } = await setup();

    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await contract.connect(owner).set_claim_conditions({
      startTime: START,
      endTime: END,
      price: 0n,
      maxQuantityPerWallet: 50n,
      paymentToken: ZERO,
    });

    await setTime(1500n);
    await contract.connect(user).claim(20n);

    expect(await contract.balance_of(await user.getAddress())).to.equal(20n);
    expect(await contract.total_supply()).to.equal(20n);
    expect(await contract.owner_of(1n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(10n)).to.equal(await user.getAddress());
    expect(await contract.owner_of(20n)).to.equal(await user.getAddress());
  });

  it("add_zero_address_to_allowlist", async () => {
    const { contract, owner } = await setup();
    await expect(contract.connect(owner).add_to_allowlist(ethers.ZeroAddress)).to.be.revertedWith(
      "Invalid address"
    );
  });

  it("batch_add_with_zero_address", async () => {
    const { contract, owner, rest } = await setup();
    const user1 = rest[0];
    const user2 = rest[1];
    await expect(
      contract.connect(owner).add_batch_to_allowlist([await user1.getAddress(), ethers.ZeroAddress, await user2.getAddress()])
    ).to.be.revertedWith("Invalid address in batch");
  });

  it("invalid_claim_conditions_time_range", async () => {
    const { contract, owner } = await setup();
    await expect(
      contract.connect(owner).set_claim_conditions({
        startTime: 2000n,
        endTime: 1000n,
        price: 0n,
        maxQuantityPerWallet: 5n,
        paymentToken: ZERO,
      })
    ).to.be.revertedWith("Invalid time range");
  });

  it("invalid_claim_conditions_zero_quantity", async () => {
    const { contract, owner } = await setup();
    await expect(
      contract.connect(owner).set_claim_conditions({
        startTime: START,
        endTime: END,
        price: 0n,
        maxQuantityPerWallet: 0n,
        paymentToken: ZERO,
      })
    ).to.be.revertedWith("Invalid max quantity");
  });

  it("claim_zero_quantity", async () => {
    const { contract, owner, user } = await setup();
    await contract.connect(owner).add_to_allowlist(await user.getAddress());
    await setTime(1500n);
    await expect(contract.connect(user).claim(0n)).to.be.revertedWith("Invalid quantity");
  });

  it("token_uri_nonexistent_token", async () => {
    const { contract } = await setup();
    await expect(contract.token_uri(999n)).to.be.revertedWith("Token does not exist");
  });

  it("get_approved_nonexistent_token", async () => {
    const { contract } = await setup();
    await expect(contract.get_approved(999n)).to.be.revertedWith(
      "ERC721: approved query for nonexistent token"
    );
  });

  it("owner_of_nonexistent_token", async () => {
    const { contract } = await setup();
    await expect(contract.owner_of(999n)).to.be.revertedWith("ERC721: invalid token ID");
  });

  it("erc721a_gas_optimization_verification (sequential owners)", async () => {
    const { contract, owner, rest } = await setup();
    const user1 = rest[0];
    const user2 = rest[1];

    await contract.connect(owner).add_to_allowlist(await user1.getAddress());
    await contract.connect(owner).add_to_allowlist(await user2.getAddress());
    await setTime(1500n);

    await contract.connect(user1).claim(3n);
    await contract.connect(user2).claim(1n);

    expect(await contract.owner_of(1n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(2n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(3n)).to.equal(await user1.getAddress());
    expect(await contract.owner_of(4n)).to.equal(await user2.getAddress());
  });
});
