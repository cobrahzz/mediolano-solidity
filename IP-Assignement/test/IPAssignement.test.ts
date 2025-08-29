import { expect } from "chai";
import { ethers } from "hardhat";

/** Helpers **/
const toBytes32 = (x: string) => ethers.keccak256(ethers.toUtf8Bytes(x));
const ip1 = toBytes32("my_first_ip");
const ip2 = toBytes32("another_ip");

// matcher util pour timestamp uint64
const anyUint64 = () => (v: any) =>
  typeof v === "bigint" && v >= 0n && v <= 18446744073709551615n;

const now = async () => (await ethers.provider.getBlock("latest"))!.timestamp;

// avance le temps à un timestamp futur (par rapport au dernier bloc)
async function setTime(ts: number | bigint) {
  const cur = await now();
  const target = Number(ts);
  const safe = target <= cur ? cur + 1 : target;
  await ethers.provider.send("evm_setNextBlockTimestamp", [safe]);
  await ethers.provider.send("evm_mine", []);
}

function cond(
  start: number,
  end: number,
  royaltyBps: number,
  rightsPct: number,
  isExclusive: boolean
) {
  return {
    start_time: start,
    end_time: end,
    royalty_rate: royaltyBps,
    rights_percentage: rightsPct,
    is_exclusive: isExclusive,
  };
}

describe("IPAssignment – tests portés de Cairo (timestamps relatifs)", () => {
  it("constructor -> get_contract_owner", async () => {
    const [contractOwner] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    expect(await c.get_contract_owner()).to.eq(contractOwner.address);
  });

    it("create_ip : owner + event", async () => {
    const [contractOwner, ipOwner] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    const base = await now();
    const ts = base + 1000;
    await setTime(ts); // mine 1 bloc à ts

    // 👉 la tx sera minée dans le bloc SUIVANT => timestamp attendu = (timestamp courant) + 1
    const expectedTs = (await now()) + 1;

    await expect(c.connect(ipOwner).create_ip(ip1))
        .to.emit(c, "IPCreated")
        .withArgs(ip1, ipOwner.address, BigInt(expectedTs));

    expect(await c.get_ip_owner(ip1)).to.eq(ipOwner.address);
    });


  it("create_ip déjà existant -> revert", async () => {
    const [contractOwner, ipOwner] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);
    await expect(c.connect(ipOwner).create_ip(ip1)).to.be.revertedWith(
      "IP: Already exists"
    );
  });

  it("transfer_ip_ownership ok + event", async () => {
    const [contractOwner, ipOwner, newOwner] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);
    await expect(
      c.connect(ipOwner).transfer_ip_ownership(ip1, newOwner.address)
    )
      .to.emit(c, "IPOwnershipTransferred")
      .withArgs(ip1, ipOwner.address, newOwner.address);

    expect(await c.get_ip_owner(ip1)).to.eq(newOwner.address);
  });

  it("transfer_ip_ownership not owner -> revert", async () => {
    const [contractOwner, ipOwner, other] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);
    await expect(
      c.connect(other).transfer_ip_ownership(ip1, other.address)
    ).to.be.revertedWith("IP: Caller not owner");
  });

  it("assign_ip OK + event + lecture conditions", async () => {
    const [contractOwner, ipOwner, assignee1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);

    const base = await now();
    const start = base + 100;
    const end = start + 1000;
    const conditions = cond(start, end, 500, 20, false);

    await expect(c.connect(ipOwner).assign_ip(ip1, assignee1.address, conditions))
      .to.emit(c, "IPAssigned")
      .withArgs(
        ip1,
        assignee1.address,
        conditions.start_time,
        conditions.end_time,
        conditions.royalty_rate,
        conditions.rights_percentage,
        conditions.is_exclusive
      );

    const stored = await c.get_assignment_data(ip1, assignee1.address);
    expect(stored.start_time).to.eq(conditions.start_time);
    expect(stored.end_time).to.eq(conditions.end_time);
    expect(stored.royalty_rate).to.eq(conditions.royalty_rate);
    expect(stored.rights_percentage).to.eq(conditions.rights_percentage);
    expect(stored.is_exclusive).to.eq(conditions.is_exclusive);
  });

  it("assign_ip not owner -> revert", async () => {
    const [contractOwner, ipOwner, other, assignee1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);
    const base = await now();
    const start = base + 100;
    const end = start + 1000;
    const conditions = cond(start, end, 500, 20, false);

    await expect(
      c.connect(other).assign_ip(ip1, assignee1.address, conditions)
    ).to.be.revertedWith("IP: Caller not owner");
  });

  it("assign_ip invalid time range -> revert", async () => {
    const [contractOwner, ipOwner, assignee1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);
    const base = await now();
    const start = base + 2000;
    const end = base + 1000; // end <= start
    const conditions = cond(start, end, 500, 20, false);

    await expect(
      c.connect(ipOwner).assign_ip(ip1, assignee1.address, conditions)
    ).to.be.revertedWith("IP: Invalid time range");
  });

  it("assign_ip rights_percentage > 100 -> revert", async () => {
    const [contractOwner, ipOwner, assignee1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);
    const base = await now();
    const conditions = cond(base + 100, base + 2000, 500, 101, false);

    await expect(
      c.connect(ipOwner).assign_ip(ip1, assignee1.address, conditions)
    ).to.be.revertedWith("IP: Rights exceed 100%");
  });

  it("assign_ip exclusif déjà présent -> revert", async () => {
    const [contractOwner, ipOwner, a1, a2] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);

    const base = await now();
    const c1 = cond(base + 100, base + 3000, 500, 50, true);
    await c.connect(ipOwner).assign_ip(ip1, a1.address, c1);

    const c2 = cond(base + 150, base + 2500, 600, 40, true);
    await expect(
      c.connect(ipOwner).assign_ip(ip1, a2.address, c2)
    ).to.be.revertedWith("IP: Exclusive exists");
  });

  it("assign_ip total rights > 100 -> revert", async () => {
    const [contractOwner, ipOwner, a1, a2] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);

    const base = await now();
    await c
      .connect(ipOwner)
      .assign_ip(ip1, a1.address, cond(base + 100, base + 3000, 500, 60, false));

    await expect(
      c
        .connect(ipOwner)
        .assign_ip(ip1, a2.address, cond(base + 150, base + 2500, 600, 50, false))
    ).to.be.revertedWith("IP: Rights exceeded");
  });

  it("get_assignment_data", async () => {
    const [contractOwner, ipOwner, a1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);
    const base = await now();
    const cc = cond(base + 100, base + 2000, 500, 20, false);
    await c.connect(ipOwner).assign_ip(ip1, a1.address, cc);

    const r = await c.get_assignment_data(ip1, a1.address);
    expect(r.start_time).to.eq(cc.start_time);
    expect(r.end_time).to.eq(cc.end_time);
    expect(r.royalty_rate).to.eq(cc.royalty_rate);
    expect(r.rights_percentage).to.eq(cc.rights_percentage);
    expect(r.is_exclusive).to.eq(cc.is_exclusive);
  });

  it("check_assignment_condition valid (non-exclusif)", async () => {
    const [contractOwner, ipOwner, a1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);

    const base = await now();
    const start = base + 100;
    const end = start + 1000;
    await c
      .connect(ipOwner)
      .assign_ip(ip1, a1.address, cond(start, end, 500, 20, false));

    await setTime(start + 1);
    expect(await c.check_assignment_condition(ip1, a1.address)).to.eq(true);
  });

  it("check_assignment_condition valid (exclusif)", async () => {
    const [contractOwner, ipOwner, a1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);

    const base = await now();
    const start = base + 100;
    const end = start + 1000;
    await c
      .connect(ipOwner)
      .assign_ip(ip1, a1.address, cond(start, end, 500, 20, true));

    await setTime(start + 1);
    expect(await c.check_assignment_condition(ip1, a1.address)).to.eq(true);
  });

  it("check_assignment_condition invalid time (avant/après)", async () => {
    const [contractOwner, ipOwner, a1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);

    const base = await now();
    const start = base + 100;
    const end = start + 1000;
    await c
      .connect(ipOwner)
      .assign_ip(ip1, a1.address, cond(start, end, 500, 20, false));

    await setTime(start - 1); // avant la fenêtre
    expect(await c.check_assignment_condition(ip1, a1.address)).to.eq(false);

    await setTime(end + 1); // après la fenêtre
    expect(await c.check_assignment_condition(ip1, a1.address)).to.eq(false);
  });

  it("check_assignment_condition invalid exclusivity (autre que l’exclusif)", async () => {
    const [contractOwner, ipOwner, a1, other] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);

    const base = await now();
    const start = base + 100;
    const end = start + 1000;
    await c
      .connect(ipOwner)
      .assign_ip(ip1, a1.address, cond(start, end, 500, 20, true));

    await setTime(start + 1);
    // l’assignee exclusif est a1 → true pour a1, false pour other
    expect(await c.check_assignment_condition(ip1, a1.address)).to.eq(true);
    expect(await c.check_assignment_condition(ip1, other.address)).to.eq(false);
  });

  it("receive_royalty – un assignee actif", async () => {
    const [contractOwner, ipOwner, a1, caller] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip1);

    const base = await now();
    const start = base + 100;
    const end = start + 1000;
    await c
      .connect(ipOwner)
      .assign_ip(ip1, a1.address, cond(start, end, 500, 20, false));

    await setTime(start + 1);
    const amount = 10_000n; // 5% = 500 à a1 ; owner = 9500
    await expect(c.connect(caller).receive_royalty(ip1, amount))
      .to.emit(c, "RoyaltyReceived")
      .withArgs(ip1, amount, caller.address);

    expect(await c.get_royalty_balance(ip1, a1.address)).to.eq(500n);
    expect(await c.get_royalty_balance(ip1, ipOwner.address)).to.eq(9500n);
    expect(await c.total_royalty_reserve(ip1)).to.eq(0n);
  });

  it("receive_royalty – plusieurs assignees actifs", async () => {
    const [contractOwner, ipOwner, a1, a2, caller] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await c.connect(ipOwner).create_ip(ip2);

    const base = await now();
    const s1 = base + 100;
    const e1 = s1 + 2000;
    await c.connect(ipOwner).assign_ip(ip2, a1.address, cond(s1, e1, 500, 20, false));
    await c.connect(ipOwner).assign_ip(ip2, a2.address, cond(s1, e1, 1000, 30, false));

    await setTime(s1 + 1);
    const amount = 20_000n; // a1=1000, a2=2000, owner=17000
    await c.connect(caller).receive_royalty(ip2, amount);

    expect(await c.get_royalty_balance(ip2, a1.address)).to.eq(1000n);
    expect(await c.get_royalty_balance(ip2, a2.address)).to.eq(2000n);
    expect(await c.get_royalty_balance(ip2, ipOwner.address)).to.eq(17000n);
    expect(await c.total_royalty_reserve(ip2)).to.eq(0n);
  });

  it("withdraw_royalties sans balance -> revert", async () => {
    const [contractOwner, assignee1] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    await expect(c.connect(assignee1).withdraw_royalties(ip1)).to.be.revertedWith(
      "IP: No balance"
    );
  });

  it("get_contract_owner / get_ip_owner", async () => {
    const [contractOwner, ipOwner] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPAssignment");
    const c = await F.deploy(contractOwner.address);
    await c.waitForDeployment();

    expect(await c.get_contract_owner()).to.eq(contractOwner.address);

    await c.connect(ipOwner).create_ip(ip1);
    expect(await c.get_ip_owner(ip1)).to.eq(ipOwner.address);
  });
});
