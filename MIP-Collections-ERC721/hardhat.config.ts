import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@typechain/hardhat";

const config: HardhatUserConfig = {
  solidity: {
    // on déclare plusieurs versions pour matcher les pragmas des fichiers
    compilers: [
      { version: "0.8.24", settings: { optimizer: { enabled: true, runs: 200 } } },
      { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 } } },
    ],
    // (optionnel) si tout ce qui est dans src doit forcer 0.8.24 :
    overrides: {
      "src/**/*.sol": {
        version: "0.8.24",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
    },
  },
  paths: {
    sources: "src",
    tests: "test",
    cache: "cache",
    artifacts: "artifacts",
  },
  mocha: { timeout: 120000 },
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
  },
};

export default config;
