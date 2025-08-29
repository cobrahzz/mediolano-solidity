import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@typechain/hardhat";

const config: HardhatUserConfig = {
  solidity: "0.8.20",
  paths: {
    sources: "src",   // tes .sol sont dans src/
    tests: "test",
    cache: "cache",
    artifacts: "artifacts"
  },
  mocha: { timeout: 120000 },
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6"
  }
};

export default config;
