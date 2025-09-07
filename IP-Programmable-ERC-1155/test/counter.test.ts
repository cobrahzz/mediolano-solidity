import { expect } from "chai";
import { ethers } from "hardhat";

describe("ERC1155CairoPort (port fidèle du Cairo)", () => {
  it("déploiement + mint initial via constructor + uri", async () => {
    const [deployer, alice] = await ethers.getSigners();

    const C = await ethers.getContractFactory("ERC1155CairoPort");
    const erc = await C.deploy(
      "ipfs://base",                 // token_uri commun
      alice.address,                 // recipient
      [1n, 2n],                      // token_ids
      [10n, 5n]                      // values
    );
    await erc.waitForDeployment();

    expect(await erc.owner()).to.equal(deployer.address);
    expect(await erc.balance_of(alice.address, 1n)).to.equal(10n);
    expect(await erc.balance_of(alice.address, 2n)).to.equal(5n);

    const batch = await erc.balance_of_batch(
      [alice.address, alice.address],
      [1n, 2n]
    );
    expect(batch[0]).to.equal(10n);
    expect(batch[1]).to.equal(5n);

    expect(await erc.uri(1n)).to.equal("ipfs://base");
    expect(await erc.uri(2n)).to.equal("ipfs://base");

    const listed = await erc.list_tokens(alice.address);
    expect(listed.length).to.equal(2);
    expect(listed[0]).to.equal(1n);
    expect(listed[1]).to.equal(2n);
  });

  it("safe_transfer_from (même sémantique Cairo : décrémente owned_tokens[from] d'1)", async () => {
    const [_, alice, bob] = await ethers.getSigners();

    const C = await ethers.getContractFactory("ERC1155CairoPort");
    const erc = await C.deploy("u", alice.address, [1n, 2n], [10n, 5n]);
    await erc.waitForDeployment();

    // Alice -> Bob : transfère 3 du token #1
    await erc.connect(alice).safe_transfer_from(
      alice.address,
      bob.address,
      1n,
      3n,
      "0x"
    );

    expect(await erc.balance_of(alice.address, 1n)).to.equal(7n);
    expect(await erc.balance_of(bob.address, 1n)).to.equal(3n);

    // En Cairo, on décrémente le "owned_tokens" d'UNE unité (même si transfert partiel)
    // => list_tokens() lit jusqu'à ce compteur.
    const listedAliceAfter = await erc.list_tokens(alice.address);
    // Était 2 (1,2) → passe à 1 → ne renvoie plus que index 0 (tokenId 1)
    expect(listedAliceAfter.length).to.equal(1);
    expect(listedAliceAfter[0]).to.equal(1n);

    // Bob a reçu un item → compteur +1 et un append du tokenId #1
    const listedBob = await erc.list_tokens(bob.address);
    expect(listedBob.length).to.equal(1);
    expect(listedBob[0]).to.equal(1n);
  });

  it("set_approval_for_all + safe_batch_transfer_from par l'opérateur", async () => {
    const [_, alice, operator, charlie] = await ethers.getSigners();

    const C = await ethers.getContractFactory("ERC1155CairoPort");
    const erc = await C.deploy("u", alice.address, [1n, 2n], [10n, 5n]);
    await erc.waitForDeployment();

    await erc.connect(alice).set_approval_for_all(operator.address, true);
    expect(await erc.is_approved_for_all(alice.address, operator.address)).to.equal(true);

    // L'opérateur déplace 2 unités du #1 et 1 unité du #2 de Alice -> Charlie
    await erc.connect(operator).safe_batch_transfer_from(
      alice.address,
      charlie.address,
      [1n, 2n],
      [2n, 1n],
      "0x"
    );

    expect(await erc.balance_of(alice.address, 1n)).to.equal(8n);
    expect(await erc.balance_of(alice.address, 2n)).to.equal(4n);
    expect(await erc.balance_of(charlie.address, 1n)).to.equal(2n);
    expect(await erc.balance_of(charlie.address, 2n)).to.equal(1n);

    // Effet Cairo : chaque item transféré décrémente le compteur de Alice d'1
    // Après le test précédent, Alice avait count = 1 ; ici on transfère 2 items → clamp à 0
    const listedAlice = await erc.list_tokens(alice.address);
    expect(listedAlice.length).to.equal(0);

    // Charlie a reçu 2 items → count = 2, [#1, #2] (ordre d'append)
    const listedCharlie = await erc.list_tokens(charlie.address);
    expect(listedCharlie.length).to.equal(2);
    expect(listedCharlie[0]).to.equal(1n);
    expect(listedCharlie[1]).to.equal(2n);
  });

  it("balance_of_batch errors", async () => {
    const [_, alice] = await ethers.getSigners();
    const C = await ethers.getContractFactory("ERC1155CairoPort");
    const erc = await C.deploy("u", alice.address, [1n], [1n]);
    await erc.waitForDeployment();

    await expect(
      erc.balance_of_batch([alice.address, alice.address], [1n])
    ).to.be.revertedWith("Arrays length mismatch");
  });
});
