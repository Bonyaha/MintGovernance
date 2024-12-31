const { ethers } = require("hardhat");

async function executeProposal() {
  const [owner] = await ethers.getSigners();
  
  // Replace with deployed contract addresses
  const governorAddress = "0xFcf16CBEA0b8A38b5aC1571f53Fb7A6Cbd343030";
  const tokenAddress = "0xD18dbCF7e018c305b5E293FDC4d235C11bf0Cfeb";

  const MyGovernor = await ethers.getContractAt("MyGovernor", governorAddress);
  const MyToken = await ethers.getContractAt("MyToken", tokenAddress);

  const mintAmount = ethers.parseEther("10000");
  const proposalDescription = "Give the owner more tokens!";
  const descriptionHash = ethers.keccak256(ethers.toUtf8Bytes(proposalDescription));

  console.log("Executing proposal...");
  const tx = await MyGovernor.execute(
    [tokenAddress],
    [0],
    [MyToken.interface.encodeFunctionData("mint", [owner.address, mintAmount])],
    descriptionHash
  );
  await tx.wait();

  console.log("Proposal executed successfully!");
}

executeProposal().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
