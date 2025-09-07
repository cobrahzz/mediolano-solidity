import { expect } from "chai";
import { ethers } from "hardhat";

describe("PublicProfileMarketplace", () => {
  async function deploy() {
    const [owner, user1, user2, unauthorized] = await ethers.getSigners();
    const initialSellerCount = 0;

    const Marketplace = await ethers.getContractFactory("PublicProfileMarketplace");
    const market = await Marketplace.deploy(initialSellerCount, owner.address);
    await market.waitForDeployment();

    return { market, owner, user1, user2, unauthorized };
  }

  it("create_seller_profile: 2 users ok + tentative doublon ignorée", async () => {
    const { market, user1, user2 } = await deploy();

    expect(await market.get_seller_count()).to.equal(0);

    // user1 crée son profil
    await market
      .connect(user1)
      .create_seller_profile(
        "user",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );
    expect(await market.get_seller_count()).to.equal(1);

    // user2 crée son profil
    await market
      .connect(user2)
      .create_seller_profile(
        "user2",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );
    expect(await market.get_seller_count()).to.equal(2);

    // doublon pour user2 → doit « réussir » la tx mais ne rien changer
    // (la fonction retourne false ; on vérifie que le compteur n’a pas bougé)
    const duplicate = await market
      .connect(user2)
      .callStatic.create_seller_profile(
        "user2",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );
    expect(duplicate).to.equal(false);

    // envoi réel (pas nécessaire, mais montre que ça ne casse rien)
    await market
      .connect(user2)
      .create_seller_profile(
        "user2",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );

    expect(await market.get_seller_count()).to.equal(2);
  });

  it("update_profile: succès par le propriétaire", async () => {
    const { market, user1 } = await deploy();

    await market
      .connect(user1)
      .create_seller_profile(
        "user",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );

    const id = await market.sellerIdOf(user1.address); // sellerId = 1 ici
    await market
      .connect(user1)
      .update_profile(
        id,
        "My new name",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );

    const seller = await market.get_specific_seller(id);
    expect(seller.seller_address).to.equal(user1.address);
    expect(seller.seller_name).to.equal("My new name");
  });

  it("update_profile: revert si non-propriétaire", async () => {
    const { market, user1, unauthorized } = await deploy();

    await market
      .connect(user1)
      .create_seller_profile(
        "user",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );
    const id = await market.sellerIdOf(user1.address);

    await expect(
      market
        .connect(unauthorized)
        .update_profile(
          id,
          "My unauthorized name",
          "mystore",
          "Where I am",
          "We just do us",
          "me@gmail.com",
          "080686452",
          "myemail@gmail.com"
        )
    ).to.be.revertedWith("Unauthorized caller");
  });

  it("get_all_sellers: retourne bien la liste et le premier est user1", async () => {
    const { market, user1, user2 } = await deploy();

    await market
      .connect(user1)
      .create_seller_profile(
        "user",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );
    await market
      .connect(user2)
      .create_seller_profile(
        "user2",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );

    const sellers = await market.get_all_sellers();
    expect(sellers.length).to.equal(2);
    expect(sellers[0].seller_address).to.equal(user1.address);
    expect(sellers[1].seller_address).to.equal(user2.address);
  });

  it("get_private_info: autorisé (owner) OK, non autorisé revert", async () => {
    const { market, user1, unauthorized } = await deploy();

    await market
      .connect(user1)
      .create_seller_profile(
        "user",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );
    const id = await market.sellerIdOf(user1.address);

    // autorisé
    const priv = await market.connect(user1).get_private_info(id);
    expect(priv.seller_address).to.equal(user1.address);
    expect(priv.phone_number).to.equal("080686452");

    // non autorisé
    await expect(market.connect(unauthorized).get_private_info(id)).to.be.revertedWith(
      "Unauthorized Caller"
    );
  });

  it("add_social_link: propriétaire OK + non propriétaire revert", async () => {
    const { market, user1, unauthorized } = await deploy();

    await market
      .connect(user1)
      .create_seller_profile(
        "user",
        "mystore",
        "Where I am",
        "We just do us",
        "me@gmail.com",
        "080686452",
        "myemail@gmail.com"
      );
    const id = await market.sellerIdOf(user1.address);

    await market.connect(user1).add_social_link(id, "https://x.com", "X");
    await market.connect(user1).add_social_link(id, "https://facebook.com", "Facebook");
    await market.connect(user1).add_social_link(id, "https://tg.com", "Telegram");

    const links = await market.get_social_links(id);
    expect(links.length).to.equal(3);
    expect(links[0].platform).to.equal("X");
    expect(links[0].link).to.equal("https://x.com");
    expect(links[1].platform).to.equal("Facebook");
    expect(links[1].link).to.equal("https://facebook.com");
    expect(links[2].platform).to.equal("Telegram");
    expect(links[2].link).to.equal("https://tg.com");

    await expect(
      market.connect(unauthorized).add_social_link(id, "https://evil.com", "Bad")
    ).to.be.revertedWith("Unauthorized Caller");
  });
});
