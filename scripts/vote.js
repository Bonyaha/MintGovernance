const { ethers } = require("hardhat");

async function voteOnProposal() {
  const [owner] = await ethers.getSigners();
  
  // Replace with deployed contract addresses
  const governorAddress = "0xFcf16CBEA0b8A38b5aC1571f53Fb7A6Cbd343030";

  const MyGovernor = await ethers.getContractAt("MyGovernor", governorAddress);

  const proposalId = "43299094184922297695527759677995549232058675074474518497860330663067653793646"; // Replace with actual proposal ID
  const voteType = 1; // 0 = Against, 1 = For, 2 = Abstain

  console.log("Casting vote...");
  const tx = await MyGovernor.castVote(proposalId, voteType);
  const receipt = await tx.wait();

  console.log("Vote cast successfully:", receipt);
}

voteOnProposal().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
