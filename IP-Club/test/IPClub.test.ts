import { expect } from "chai";
import { ethers } from "hardhat";

//
// Helpers — adresses “rôles” (on réutilise les signers Hardhat)
//

type DeployResult = {
  club: any;
  erc20: any;
  admin: any;
  creator: any;
  user1: any;
  user2: any;
};

async function initialize_contracts(): Promise<DeployResult> {
  const [admin, creator, user1, user2] = await ethers.getSigners();

  // Deploy MockERC20
  const ERC = await ethers.getContractFactory("MockERC20", admin);
  const erc20 = await ERC.deploy("DummyERC20", "DUMMY");

  // Deploy IPClub
  const Club = await ethers.getContractFactory("IPClub", admin);
  const club = await Club.deploy();

  return { club, erc20, admin, creator, user1, user2 };
}

async function mint_erc20(token: any, recipient: string, amount: bigint) {
  await token.mint(recipient, amount);
}


async function createClub(
  club: any,
  signer: any,
  {
    name = "Vipers",
    symbol = "VPs",
    metadata = "http:://localhost:3000",
    maxMembers = 0, // 0 => None
    entryFee = 0n, // 0 => None
    paymentToken = ethers.ZeroAddress, // 0 => None
  }: {
    name?: string;
    symbol?: string;
    metadata?: string;
    maxMembers?: number;
    entryFee?: bigint;
    paymentToken?: string;
  } = {}
) {
  return club
    .connect(signer)
    .create_club(name, symbol, metadata, maxMembers, entryFee, paymentToken);
}

describe("IPClub – conversion des tests Cairo (fichier unique)", () => {
  it("test_create_club_successfully", async () => {
    const { club, creator } = await initialize_contracts();

    await createClub(club, creator, {
      maxMembers: 0,
      entryFee: 0n,
      paymentToken: ethers.ZeroAddress,
    });

    const clubId: bigint = await club.get_last_club_id();
    const rec = await club.get_club_record(clubId);

    expect(rec.name).to.eq("Vipers");
    expect(rec.symbol).to.eq("VPs");
    expect(rec.metadataURI).to.eq("http:://localhost:3000");
    expect(rec.maxMembers).to.eq(0);
    expect(rec.entryFee).to.eq(0);
    expect(rec.paymentToken).to.eq(ethers.ZeroAddress);
    expect(rec.status).to.eq(1); // ClubStatus.Open
  });

  it("test_create_club_with_invalid_max_members", async () => {
    const { club, creator } = await initialize_contracts();

    // Test Cairo : Option::Some(0) doit revert 'Max members cannot be zero'
    // En Solidity simplifiée, 0 représente "None". On garde la même attente
    // de revert pour rester fidèle au test d’origine.
    await expect(
      createClub(club, creator, {
        maxMembers: 0, // Some(0) en Cairo => invalid
        entryFee: 0n,
        paymentToken: ethers.ZeroAddress,
      })
    ).to.be.revertedWith("Max members cannot be zero");
  });

  it("test_create_club_with_invalid_fee_configuration_type1", async () => {
    // Payment Token sans Fee
    const { club, creator, erc20 } = await initialize_contracts();

    await expect(
      createClub(club, creator, {
        maxMembers: 0,
        entryFee: 0n, // None
        paymentToken: await erc20.getAddress(), // Some(token)
      })
    ).to.be.revertedWith("Invalid fee configuration");
  });

  it("test_create_club_with_invalid_fee_configuration_type2", async () => {
    // Fee sans Payment Token
    const { club, creator } = await initialize_contracts();

    await expect(
      createClub(club, creator, {
        maxMembers: 0,
        entryFee: 1000n, // Some(fee)
        paymentToken: ethers.ZeroAddress, // None
      })
    ).to.be.revertedWith("Invalid fee configuration");
  });

  it("test_create_club_with_zero_entry_fee", async () => {
    // Cairo: entry_fee = Some(0) + token = Some(addr) => 'Entry fee cannot be zero'
    const { club, creator, erc20 } = await initialize_contracts();

    await expect(
      createClub(club, creator, {
        maxMembers: 0,
        entryFee: 0n, // Some(0)
        paymentToken: await erc20.getAddress(), // Some(token)
      })
    ).to.be.revertedWith("Entry fee cannot be zero");
  });

  it("test_create_club_with_invalid_payment_token", async () => {
    const { club, creator } = await initialize_contracts();

    await expect(
      createClub(club, creator, {
        maxMembers: 0,
        entryFee: 1000n, // Some(fee)
        paymentToken: ethers.ZeroAddress, // Some(0) => invalid
      })
    ).to.be.revertedWith("Payment token cannot be null");
  });

  it("test_ip_club_nft_deployed_on_club_creation", async () => {
    const { club, creator } = await initialize_contracts();

    await createClub(club, creator, {
      maxMembers: 0,
      entryFee: 0n,
      paymentToken: ethers.ZeroAddress,
    });

    const clubId: bigint = await club.get_last_club_id();
    const rec = await club.get_club_record(clubId);

    const nft = await ethers.getContractAt("IPClubNFT", rec.clubNFT);
    const assocId: bigint = await nft.get_associated_club_id();
    const manager: string = await nft.get_ip_club_manager();

    expect(assocId).to.eq(clubId);
    expect(manager).to.eq(await club.getAddress());
  });

  it("test_close_club_successfully", async () => {
    const { club, creator } = await initialize_contracts();

    await createClub(club, creator, {});
    const clubId: bigint = await club.get_last_club_id();

    await club.connect(creator).close_club(clubId);
    const rec = await club.get_club_record(clubId);
    expect(rec.status).to.eq(2); // ClubStatus.Closed
  });

  it("test_close_club_close_only_once", async () => {
    const { club, creator } = await initialize_contracts();

    await createClub(club, creator, {});
    const clubId: bigint = await club.get_last_club_id();

    await club.connect(creator).close_club(clubId);

    await expect(club.connect(creator).close_club(clubId)).to.be.revertedWith(
      "Club not open"
    );
  });

  it("test_only_club_creator_can_close_club", async () => {
    const { club, creator, user1 } = await initialize_contracts();

    await createClub(club, creator, {});
    const clubId: bigint = await club.get_last_club_id();

    await expect(club.connect(user1).close_club(clubId)).to.be.revertedWith(
      "Not Authorized"
    );
  });

  it("test_join_club_successfully", async () => {
    const { club, creator, user1, user2 } = await initialize_contracts();

    await createClub(club, creator, {});
    const clubId: bigint = await club.get_last_club_id();

    await club.connect(user1).join_club(clubId);
    let rec = await club.get_club_record(clubId);
    expect(rec.numMembers).to.eq(1);

    let isMember1 = await club.is_member(clubId, user1.address);
    expect(isMember1).to.eq(true);

    await club.connect(user2).join_club(clubId);
    rec = await club.get_club_record(clubId);
    expect(rec.numMembers).to.eq(2);

    let isMember2 = await club.is_member(clubId, user2.address);
    expect(isMember2).to.eq(true);
  });

  it("test_join_club_mints_nft", async () => {
    const { club, creator, user1 } = await initialize_contracts();

    await createClub(club, creator, {});
    const clubId: bigint = await club.get_last_club_id();

    await club.connect(user1).join_club(clubId);

    const rec = await club.get_club_record(clubId);
    const nft = await ethers.getContractAt("IPClubNFT", rec.clubNFT);

    const lastId: bigint = await nft.get_last_minted_id();
    expect(lastId).to.eq(1n);

    const has = await nft.has_nft(user1.address);
    expect(has).to.eq(true);
  });

  it("test_join_club_with_entry_fee", async () => {
    const { club, creator, erc20, user1 } = await initialize_contracts();

    const fee = 1000n;
    const tokenAddr = await erc20.getAddress();

    await createClub(club, creator, {
      maxMembers: 0,
      entryFee: fee,
      paymentToken: tokenAddr,
    });

    const clubId: bigint = await club.get_last_club_id();

    // Mint à user1 et approve le club
    await mint_erc20(erc20, user1.address, 3000n);
    const balBefore = await erc20.balanceOf(user1.address);
    expect(balBefore).to.eq(3000n);

    await erc20.connect(user1).approve(await club.getAddress(), fee);

    await club.connect(user1).join_club(clubId);

    const user1Bal = await erc20.balanceOf(user1.address);
    const rec = await club.get_club_record(clubId);
    const creatorBal = await erc20.balanceOf(rec.creator);

    expect(creatorBal).to.eq(1000n);
    expect(user1Bal).to.eq(balBefore - fee);

    const isMember = await club.is_member(clubId, user1.address);
    expect(isMember).to.eq(true);
  });

  it("test_cannot_join_club_twice", async () => {
    const { club, creator, user1 } = await initialize_contracts();

    await createClub(club, creator, {});
    const clubId: bigint = await club.get_last_club_id();

    await club.connect(user1).join_club(clubId);
    await expect(club.connect(user1).join_club(clubId)).to.be.revertedWith(
      "Already has nft"
    );
  });

  it("test_cannot_join_club_when_max_members_reached", async () => {
    const { club, creator, user1, user2 } = await initialize_contracts();

    await createClub(club, creator, { maxMembers: 1 });
    const clubId: bigint = await club.get_last_club_id();

    await club.connect(user1).join_club(clubId);
    await expect(club.connect(user2).join_club(clubId)).to.be.revertedWith(
      "Club full"
    );
  });

  it("test_cannot_join_when_club_is_closed", async () => {
    const { club, creator, user1 } = await initialize_contracts();

    await createClub(club, creator, { maxMembers: 1 });
    const clubId: bigint = await club.get_last_club_id();

    await club.connect(creator).close_club(clubId);
    await expect(club.connect(user1).join_club(clubId)).to.be.revertedWith(
      "Club not open"
    );
  });

  it("test_only_ip_club_can_mint", async () => {
    const { club, creator, user1 } = await initialize_contracts();

    await createClub(club, creator, { maxMembers: 1 });
    const clubId: bigint = await club.get_last_club_id();
    const rec = await club.get_club_record(clubId);

    const nft = await ethers.getContractAt("IPClubNFT", rec.clubNFT);

    // Appel direct par un autre compte => AccessControl revert “is missing role”
    await expect(nft.connect(creator).mint(user1.address)).to.be.revertedWith(
      /is missing role/
    );
  });
});
