const { ethers } = require("hardhat");

async function main() {
  /* const transactionCount = await owner.getTransactionCount();

  // gets the address of the token before it is deployed
  const futureAddress = ethers.utils.getContractAddress({
    from: owner.address,
    nonce: transactionCount + 1
  });

  const MyGovernor = await ethers.getContractFactory("MyGovernor");
  const governor = await MyGovernor.deploy(futureAddress);

  const MyToken = await ethers.getContractFactory("MyToken");
  const token = await MyToken.deploy(governor.address);

  console.log(
    `Governor deployed to ${governor.address}`,
    `Token deployed to ${token.address}`
  ); */
  const [owner, otherAccount] = await ethers.getSigners();
    //console.log("Owner:", owner.address);   

   // Deploy MyToken first
    const MyToken = await ethers.getContractFactory("MyToken");
    const token = await MyToken.deploy(ethers.ZeroAddress); // Updated here
    await token.waitForDeployment(); // Ensures deployment completion
    console.log("MyToken deployed at:", token.target);
  
    // Deploy MyGovernor with the actual deployed address of MyToken
    const MyGovernor = await ethers.getContractFactory("MyGovernor");
    const governor = await MyGovernor.deploy(token.target);
    await governor.waitForDeployment(); // Ensures deployment completion
    console.log("MyGovernor deployed at:", governor.target);
  
    // Update the token's governor address after deployment
    await token.setGovernor(governor.target);
    // Delegate tokens to the owner
    await token.delegate(owner.address);
  
    return { governor, token, owner, otherAccount };
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
