import { expect } from "chai";
import { ethers } from "hardhat";

const FQN = "src/Subscription.sol:Subscription";

/** Récupère le plan_id depuis l'événement PlanCreated du bloc de la tx */
async function getPlanIdFromTx(contract: any, receipt: any): Promise<bigint> {
  const events = await contract.queryFilter(
    contract.filters.PlanCreated(),
    receipt.blockNumber,
    receipt.blockNumber
  );
  if (!events.length) throw new Error("PlanCreated not found");
  // ethers v6: args est array-like + noms
  const args: any = events[0].args;
  return (args?.plan_id ?? args?.[0]) as bigint;
}

describe("Subscription (Cairo → Solidity port tests)", () => {
  async function deployWithOwner(ownerAddr?: string) {
    const [deployer, s1, s2, s3] = await ethers.getSigners();
    const owner = ownerAddr ?? deployer.address;
    const C = await ethers.getContractFactory(FQN);
    const c = await C.deploy(owner);
    await c.waitForDeployment();
    return { c, deployer, owner, s1, s2, s3 };
  }

  it("test_create_plan (emit + details)", async () => {
    const { c, s1 } = await deployWithOwner(s1.address);

    const price = 1000n;
    const duration = 3600; // 1h
    const tier = 1n;

    const tx = await c.connect(s1).create_plan(price, duration, tier);
    const receipt = await tx.wait();

    // Vérifie l'event (au moins une émission)
    await expect(tx).to.emit(c, "PlanCreated");

    // Récupère le plan_id exact émis
    const plan_id = await getPlanIdFromTx(c, receipt);

    // Vérifie les détails persistés
    const [retPrice, retDuration, retTier] = await c.get_plan_details(plan_id);
    expect(retPrice).to.equal(price);
    expect(retDuration).to.equal(duration);
    expect(retTier).to.equal(tier);
  });

  it("test_subscribe (status + event)", async () => {
    const { c, s1, s2 } = await deployWithOwner(s1.address);

    const txCreate = await c.connect(s1).create_plan(1000n, 3600, 1n);
    const planId = await getPlanIdFromTx(c, await txCreate.wait());

    const tx = await c.connect(s2).subscribe(planId);
    await expect(tx).to.emit(c, "Subscribed").withArgs(s2.address, planId);

    const isSub = await c.connect(s2).get_subscription_status();
    expect(isSub).to.equal(true);
  });

  it("test_unsubscribe (status + event)", async () => {
    const { c, s1, s2 } = await deployWithOwner(s1.address);

    const txCreate = await c.connect(s1).create_plan(1000n, 3600, 1n);
    const planId = await getPlanIdFromTx(c, await txCreate.wait());

    await c.connect(s2).subscribe(planId);

    const tx = await c.connect(s2).unsubscribe(planId);
    await expect(tx).to.emit(c, "Unsubscribed").withArgs(s2.address, planId);

    const isSub = await c.connect(s2).get_subscription_status();
    expect(isSub).to.equal(false);
  });

  it("test_renew_subscription (event)", async () => {
    const { c, s1, s2 } = await deployWithOwner(s1.address);

    const txCreate = await c.connect(s1).create_plan(1000n, 3600, 1n);
    const planId = await getPlanIdFromTx(c, await txCreate.wait());

    await c.connect(s2).subscribe(planId);

    const tx = await c.connect(s2).renew_subscription();
    await expect(tx).to.emit(c, "SubscriptionRenewed").withArgs(s2.address);
  });

  it("test_upgrade_subscription (event)", async () => {
    const { c, s1, s2 } = await deployWithOwner(s1.address);

    const tx1 = await c.connect(s1).create_plan(1000n, 3600, 1n);
    const plan1 = await getPlanIdFromTx(c, await tx1.wait());

    const tx2 = await c.connect(s1).create_plan(2000n, 3600, 2n);
    const plan2 = await getPlanIdFromTx(c, await tx2.wait());

    await c.connect(s2).subscribe(plan1);

    const tx = await c.connect(s2).upgrade_subscription(plan2);
    await expect(tx).to.emit(c, "SubscriptionUpgraded").withArgs(s2.address, plan2);

    // Optionnel : vérifie que seul le nouveau plan est listé
    const ids = await c.connect(s2).get_user_plan_ids();
    expect(ids.length).to.equal(1);
    expect(ids[0]).to.equal(plan2);
  });

  it("test_create_plan_not_owner (revert)", async () => {
    const { c, s1, s2 } = await deployWithOwner(s1.address);

    await expect(
      c.connect(s2).create_plan(1000n, 3600, 1n)
    ).to.be.revertedWith("Only owner can create plans");
  });

  it("test_subscribe_nonexistent_plan (revert)", async () => {
    const { c, s1, s2 } = await deployWithOwner(s1.address);

    const nonExistingPlan = 100n;
    await expect(
      c.connect(s2).subscribe(nonExistingPlan)
    ).to.be.revertedWith("Plan does not exist");
  });

  it("test_unsubscribe_not_subscribed (revert)", async () => {
    const { c, s1, s2 } = await deployWithOwner(s1.address);

    const txCreate = await c.connect(s1).create_plan(1000n, 3600, 1n);
    const planId = await getPlanIdFromTx(c, await txCreate.wait());

    await expect(
      c.connect(s2).unsubscribe(planId)
    ).to.be.revertedWith("Not subscribed to this plan");
  });
});
