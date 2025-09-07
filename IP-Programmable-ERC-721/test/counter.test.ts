import { expect } from "chai";
import { ethers } from "hardhat";

describe("Monolith: Counter + ERC721EnumerableMinimal", function () {
  describe("Counter", function () {
    it("current() = 0 au départ, puis ++/-- et wrap-around identique à Cairo", async () => {
      const Counter = await ethers.getContractFactory("Counter");
      const counter = await Counter.deploy();
      await counter.waitForDeployment();

      // current == 0
      expect(await counter.current()).to.equal(0n);

      // increment -> 1
      await counter.increment();
      expect(await counter.current()).to.equal(1n);

      // decrement -> 0
      await counter.decrement();
      expect(await counter.current()).to.equal(0n);

      // underflow wrap-around (u256 Cairo) : 0 - 1 = 2^256 - 1
      const MAX = (1n << 256n) - 1n;
      await counter.decrement();
      expect(await counter.current()).to.equal(MAX);

      // re-increment -> revient à 0
      await counter.increment();
      expect(await counter.current()).to.equal(0n);
    });
  });

  describe("ERC721EnumerableMinimal", function () {
    it("mint, total_supply, token_of_owner_by_index, transferts et énumération", async () => {
      const [deployer, alice, bob] = await ethers.getSigners();

      const ERC721 = await ethers.getContractFactory("ERC721EnumerableMinimal");
      const erc721 = await ERC721.deploy("Test", "TST");
      await erc721.waitForDeployment();

      // supply initial
      expect(await erc721.total_supply()).to.equal(0n);

      // mint 2 tokens à Alice : 1 et 2
      await erc721.demo_mint(alice.address, 1n);
      await erc721.demo_mint(alice.address, 2n);

      expect(await erc721.total_supply()).to.equal(2n);
      expect(await erc721.balanceOf(alice.address)).to.equal(2n);

      // indexation propriétaire
      expect(await erc721.token_of_owner_by_index(alice.address, 0n)).to.equal(1n);
      expect(await erc721.token_of_owner_by_index(alice.address, 1n)).to.equal(2n);
      await expect(
        erc721.token_of_owner_by_index(alice.address, 2n)
      ).to.be.revertedWith("Owner index out of bounds");

      // transfert du token #1 de Alice -> Bob
      await erc721.connect(alice).transferFrom(alice.address, bob.address, 1n);

      expect(await erc721.balanceOf(alice.address)).to.equal(1n);
      expect(await erc721.balanceOf(bob.address)).to.equal(1n);
      // la liste d’Alice a été compactée : à l’index 0 on attend le token #2
      expect(await erc721.token_of_owner_by_index(alice.address, 0n)).to.equal(2n);
      // Bob possède #1 à l’index 0
      expect(await erc721.token_of_owner_by_index(bob.address, 0n)).to.equal(1n);
      // supply inchangé
      expect(await erc721.total_supply()).to.equal(2n);

      // burn du token #1 par Bob (proprio) → supply décrémente
      await erc721.connect(bob).demo_burn(1n);
      expect(await erc721.total_supply()).to.equal(1n);
      expect(await erc721.balanceOf(bob.address)).to.equal(0n);
      expect(await erc721.balanceOf(alice.address)).to.equal(1n);
    });
  });
});
