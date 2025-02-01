require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.22",
    settings: {
      optimizer: {
        enabled: true,
        runs: 50,
      },
      viaIR: true,
      metadata: {
        bytecodeHash: "none",
      },
      debug: {
        revertStrings: "strip"
      }
    },
  },
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545/",
    }
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_KEY
  }
};
