import { expect } from "chai";
import { ethers } from "hardhat";

describe("IPCollection (Solidity port from Cairo)", function () {
  async function deploy() {
    const [deployer, owner, alice, bob] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("IPCollection");
    const contract = await Factory.deploy(
      "IPCollection",
      "IPC",
      "https://example.com/metadata/",
      await owner.getAddress()
    );
    await contract.waitForDeployment();
    return { contract, deployer, owner, alice, bob };
  }

  it("owner peut mint; balance et listUserTokens OK", async () => {
    const { contract, owner } = await deploy();
    const ownerAddr = await owner.getAddress();

    // on effectue un mint (retourne un uint256 mais la valeur retournée
    // d'une tx ne s'attrape pas directement, c'est normal côté EVM)
    await contract.connect(owner).mint(ownerAddr);

    expect(await contract.balanceOf(ownerAddr)).to.equal(1n);

    const tokens = await contract.listUserTokens(ownerAddr);
    expect(tokens.length).to.equal(1);
    expect(tokens[0]).to.equal(1n);

    const tokenURI = await contract.tokenURI(1);
    expect(tokenURI).to.equal("https://example.com/metadata/1");
  });

  it("non-owner ne peut pas mint", async () => {
    const { contract, alice } = await deploy();
    await expect(
      contract.connect(alice).mint(await alice.getAddress())
    ).to.be.revertedWith("Ownable: caller is not the owner");
  });

  it("transferToken exige l'approbation du contrat d'abord", async () => {
    const { contract, owner, alice } = await deploy();
    const ownerAddr = await owner.getAddress();
    const aliceAddr = await alice.getAddress();

    await contract.connect(owner).mint(ownerAddr); // tokenId = 1

    await expect(
      contract.connect(owner).transferToken(ownerAddr, aliceAddr, 1)
    ).to.be.revertedWith("Contract not approved");

    // On approuve le contrat lui-même pour déplacer le tokenId 1
    await contract.connect(owner).approve(await contract.getAddress(), 1);
    await contract.connect(owner).transferToken(ownerAddr, aliceAddr, 1);

    expect(await contract.ownerOf(1)).to.equal(aliceAddr);

    const aliceTokens = await contract.listUserTokens(aliceAddr);
    expect(aliceTokens.length).to.equal(1);
    expect(aliceTokens[0]).to.equal(1n);
  });

  it("burn fonctionne pour owner ou approuvé (ERC721Burnable)", async () => {
    const { contract, owner } = await deploy();
    const ownerAddr = await owner.getAddress();

    await contract.connect(owner).mint(ownerAddr); // id=1
    expect(await contract.ownerOf(1)).to.equal(ownerAddr);

    await contract.connect(owner).burn(1);
    await expect(contract.ownerOf(1)).to.be.reverted; // le token n'existe plus
  });

  it("upgrade est un stub qui revert sur EVM", async () => {
    const { contract, owner } = await deploy();
    await expect(
      contract.connect(owner).upgrade(ethers.ZeroHash)
    ).to.be.revertedWith("Upgrade not supported directly; use a proxy pattern");
  });
});
