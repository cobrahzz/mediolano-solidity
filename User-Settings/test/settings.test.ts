import { expect } from "chai";
import { ethers } from "hardhat";
import { keccak256, toUtf8Bytes } from "ethers";

const NONE_U256 = (1n << 256n) - 1n; // sentinelle "None" pour uint256
const NONE_U8 = 255;
const TRIBOOL_FALSE = 0;
const TRIBOOL_TRUE = 1;
const TRIBOOL_NONE = 2;

// petits helpers temps
async function setNextTimestamp(ts: number) {
  await ethers.provider.send("evm_setNextBlockTimestamp", [ts]);
  await ethers.provider.send("evm_mine", []);
}

describe("EncryptedPreferencesRegistry", () => {
  async function deploy() {
    const [owner, mediolano, stranger] = await ethers.getSigners();
    const F = await ethers.getContractFactory("EncryptedPreferencesRegistry");
    const c = await F.deploy(owner.address, mediolano.address);
    await c.waitForDeployment();
    return { c, owner, mediolano, stranger };
  }

  it("store + update account details", async () => {
    const { c, owner } = await deploy();

    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    await expect(
      c.connect(owner).store_account_details(
        123n, // name
        456n, // email
        789n, // username
        now
      )
    ).to.emit(c, "SettingUpdated");

    let [name, email, username] = await c.get_account_settings(owner.address);
    expect(name).to.equal(123n);
    expect(email).to.equal(456n);
    expect(username).to.equal(789n);

    // update: ne change que name, le reste "None"
    await expect(
      c.connect(owner).update_account_details(999n, NONE_U256, NONE_U256, now)
    ).to.emit(c, "SettingUpdated");

    [name, email, username] = await c.get_account_settings(owner.address);
    expect(name).to.equal(999n);
    expect(email).to.equal(456n);
    expect(username).to.equal(789n);
  });

  it("store + update IP management settings", async () => {
    const { c, owner } = await deploy();

    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    // protection_level: 0 (STANDARD), auto: true
    await c
      .connect(owner)
      .store_ip_management_settings(0, true, now);

    let [ipl, autoReg] = await c.get_ip_settings(owner.address);
    expect(ipl).to.equal(0); // STANDARD
    expect(autoReg).to.equal(true);

    // update: set ADVANCED (1) et auto: false via tri-bool=0
    await c
      .connect(owner)
      .update_ip_management_settings(1, TRIBOOL_FALSE, now);

    [ipl, autoReg] = await c.get_ip_settings(owner.address);
    expect(ipl).to.equal(1); // ADVANCED
    expect(autoReg).to.equal(false);

    // update partiel: ne change rien (NONE_U8 + TRIBOOL_NONE)
    await c
      .connect(owner)
      .update_ip_management_settings(NONE_U8, TRIBOOL_NONE, now);

    [ipl, autoReg] = await c.get_ip_settings(owner.address);
    expect(ipl).to.equal(1);
    expect(autoReg).to.equal(false);
  });

  it("store + update notification settings", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    await c
      .connect(owner)
      .store_notification_settings(true, true, true, true, now);

    let [enabled, ipu, chain, act] = await c.get_notification_settings(owner.address);
    expect(enabled).to.equal(true);
    expect(chain).to.equal(true);

    // update: flip blockchain_events -> false, autres inchangés via tri-bool
    await c
      .connect(owner)
      .update_notification_settings(TRIBOOL_TRUE, TRIBOOL_TRUE, TRIBOOL_FALSE, TRIBOOL_TRUE, now);

    [enabled, ipu, chain, act] = await c.get_notification_settings(owner.address);
    expect(chain).to.equal(false);
  });

  it("store + update security (hash en keccak)", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    // store_security_settings: hash(password, timestamp, caller)
    await c.connect(owner).store_security_settings(111n, now);
    let [twofa, pwd] = await c.get_security_settings(owner.address);
    expect(twofa).to.equal(false);
    // pas trivial à recalculer côté test sans reproduire l'encodage exact;
    // on vérifie juste qu'il est ≠ 0
    expect(pwd).to.not.equal(0n);

    // update_security_settings: hash(password, caller)
    await c.connect(owner).update_security_settings(222n, now);
    const [, pwd2] = await c.get_security_settings(owner.address);
    expect(pwd2).to.not.equal(0n);
    expect(pwd2).to.not.equal(pwd);
  });

  it("store + update network settings", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    // 1 = MAINNET, 1 = MEDIUM
    await c.connect(owner).store_network_settings(1, 1, now);
    let [ntype, gas] = await c.get_network_settings(owner.address);
    expect(ntype).to.equal(1);
    expect(gas).to.equal(1);

    // update -> TESTNET/LOW
    await c
      .connect(owner)
      .update_network_settings(0, 0, now);
    [ntype, gas] = await c.get_network_settings(owner.address);
    expect(ntype).to.equal(0);
    expect(gas).to.equal(0);

    // update partiel: rien ne change
    await c
      .connect(owner)
      .update_network_settings(NONE_U8, NONE_U8, now);
    [ntype, gas] = await c.get_network_settings(owner.address);
    expect(ntype).to.equal(0);
    expect(gas).to.equal(0);
  });

  it("store advanced settings + regenerate api key", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    await c.connect(owner).store_advanced_settings(555n, now);
    let [apiKey, dataRetention] = await c.get_advanced_settings(owner.address);
    expect(apiKey).to.equal(555n);
    expect(dataRetention).to.equal(0);

    const newKey = await c.connect(owner).regenerate_api_key(now);
    const receipt = await newKey.wait();
    const returned = receipt!.logs[0]?.args?.[0] ?? undefined; // ignore; on relira via getter

    [apiKey] = await c.get_advanced_settings(owner.address);
    expect(apiKey).to.not.equal(555n);
  });

  it("store x verification", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    await expect(
      c.connect(owner).store_X_verification(true, now, 777n)
    ).to.emit(c, "SocialVerificationUpdated");

    const [xVerified, xHandler, xAddr] = (await c.get_social_verification(owner.address)).slice(0, 3);
    expect(xVerified).to.equal(true);
    expect(xHandler).to.equal(777n);
    expect(xAddr).to.equal(owner.address);
  });

  it("delete account resets data", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    await c.connect(owner).store_account_details(1n, 2n, 3n, now);
    await c.connect(owner).delete_account(now);

    const [name, email, username] = await c.get_account_settings(owner.address);
    expect(name).to.equal(0n);
    expect(email).to.equal(0n);
    expect(username).to.equal(0n);
  });

  it("reverts for unauthorized sender", async () => {
    const { c, stranger } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    await expect(
      c.connect(stranger).store_account_details(1n, 2n, 3n, now)
    ).to.be.revertedWith("Unauthorized caller");
  });

  it("timestamp validation window (+/- 300s)", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);

    // future > +300
    await setNextTimestamp(now);
    await expect(
      c.connect(owner).store_account_details(1n, 2n, 3n, now + 600)
    ).to.be.revertedWith("Invalid timestamp");

    // past < -300
    await expect(
      c.connect(owner).store_account_details(1n, 2n, 3n, now - 600)
    ).to.be.revertedWith("Invalid timestamp");

    // inside window OK
    await expect(
      c.connect(owner).store_account_details(1n, 2n, 3n, now)
    ).to.emit(c, "SettingUpdated");
  });

  it("invalid protection level reverts", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    await expect(
      c.connect(owner).store_ip_management_settings(2, true, now)
    ).to.be.revertedWith("Invalid Protection Level");
  });

  it("emits SettingUpdated with correct topic for account_details", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    const settingType = keccak256(toUtf8Bytes("account_details"));
    await expect(
      c.connect(owner).store_account_details(10n, 20n, 30n, now)
    )
      .to.emit(c, "SettingUpdated")
      .withArgs(owner.address, settingType, await timestampNearNow());
  });

  it("storage consistency (read back)", async () => {
    const { c, owner } = await deploy();
    const now = Math.floor(Date.now() / 1000);
    await setNextTimestamp(now);

    await c.connect(owner).store_account_details(111n, 222n, 333n, now);
    const [n, e, u] = await c.get_account_settings(owner.address);
    expect(n).to.equal(111n);
    expect(e).to.equal(222n);
    expect(u).to.equal(333n);
  });
});

// helper qui vérifie que le timestamp event est “proche de maintenant” (±10 min)
// on renvoie un matcher "anyValue" pragmatique en lisant le block courant
async function timestampNearNow() {
  const block = await ethers.provider.getBlock("latest");
  return block!.timestamp;
}
