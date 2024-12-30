require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.22",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    sepolia: {
      url: process.env.ALCHEMY_SEPOLIA_URL, // Alchemy or Infura URL for Sepolia
      accounts: [process.env.SEPOLIA_PRIVATE_KEY], // Private key of your funded Sepolia account
    },
  },
};
