import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.26",
    settings: {
      evmVersion: "paris",
      optimizer: { enabled: true, runs: 200 }
    }
  },
  paths: {
    sources: "src",
    tests: "test",
    artifacts: "artifacts",
    cache: "cache"
  },
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6"
  }
};

export default config;
