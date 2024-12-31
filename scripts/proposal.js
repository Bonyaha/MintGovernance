const { ethers } = require("hardhat");

async function createProposal() {
  const [owner] = await ethers.getSigners();
  
  // Replace with deployed contract addresses
  const governorAddress = "0xFcf16CBEA0b8A38b5aC1571f53Fb7A6Cbd343030";
  const tokenAddress = "0xD18dbCF7e018c305b5E293FDC4d235C11bf0Cfeb";

  const MyGovernor = await ethers.getContractAt("MyGovernor", governorAddress);
  const MyToken = await ethers.getContractAt("MyToken", tokenAddress);

  const mintAmount = ethers.parseEther("10000");
  const proposalDescription = "Give the owner more tokens!";

  console.log("Encoding proposal data...");
  const encodedFunctionData = MyToken.interface.encodeFunctionData("mint", [owner.address, mintAmount]);

  console.log("Creating proposal...");
  const tx = await MyGovernor.propose(
    [tokenAddress],
    [0],
    [encodedFunctionData],
    proposalDescription
  );
  const receipt = await tx.wait();

  const proposalCreatedEvent = receipt.logs.find(log => 
    log.fragment && log.fragment.name === 'ProposalCreated'
  );
  
  const proposalId = proposalCreatedEvent.args[0].toString();
  console.log("Proposal created with ID:", proposalId);
}

createProposal().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
