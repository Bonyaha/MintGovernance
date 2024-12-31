const { ethers } = require("hardhat");

async function main() {
  const [owner] = await ethers.getSigners();

  // Replace with the actual deployed token address
  const tokenAddress = "0xD18dbCF7e018c305b5E293FDC4d235C11bf0Cfeb";

  // Get the contract instance for MyToken
  const MyToken = await ethers.getContractAt("MyToken", tokenAddress);

  const balance = await MyToken.balanceOf(owner.address);
  const readableBalance = ethers.formatUnits(balance, 18);
  console.log("Governance Token Balance:", readableBalance);
  

  // Check delegatee and voting power
  const delegatee = await MyToken.delegates(owner.address);
  console.log("Delegatee for owner:", delegatee);

  const votes = await MyToken.getVotes(owner.address);
  console.log("Voting power for owner:", ethers.formatUnits(votes, 18));
 
  //Check proposal state
  const governorAddress = "0xFcf16CBEA0b8A38b5aC1571f53Fb7A6Cbd343030";
  const MyGovernor = await ethers.getContractAt("MyGovernor", governorAddress);
  const proposalId = "43299094184922297695527759677995549232058675074474518497860330663067653793646";
  const state = await MyGovernor.state(proposalId);
  console.log("Proposal state:", state);
// States: 0=Pending, 1=Active, 2=Canceled, 3=Defeated, 4=Succeeded, 5=Queued, 6=Expired, 7=Executed
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
