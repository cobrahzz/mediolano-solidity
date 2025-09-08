// hardhat.config.cjs
// Wrapper CJS pour laisser Hardhat charger la config TypeScript dans un projet ESM.
require("ts-node/register/transpile-only");
module.exports = require("./hardhat.config.ts").default;
