const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { assert } = require("chai");
const { ethers } = require("hardhat");
const { toUtf8Bytes, keccak256, parseEther } = ethers;

describe("MyGovernor", function () {
  async function deployFixture() {
    const [owner, otherAccount] = await ethers.getSigners();
    //console.log("Owner:", owner.address);
  
    const transactionCount = await owner.provider.getTransactionCount(owner.address);
    console.log(transactionCount);
    
     // gets the address of the token before it is deployed
     const futureAddress = ethers.getCreateAddress({
      from: owner.address,
      nonce: transactionCount + 1
    });





console.log(futureAddress);

    // Deploy MyToken first
    /* const MyToken = await ethers.getContractFactory("MyToken");
    const token = await MyToken.deploy(ethers.ZeroAddress); // Updated here
    await token.waitForDeployment(); // Ensures deployment completion */
    //console.log("MyToken deployed at:", token.target);
  
    // Deploy MyGovernor with the actual deployed address of MyToken
    const MyGovernor = await ethers.getContractFactory("MyGovernor");
    const governor = await MyGovernor.deploy(futureAddress);
    await governor.waitForDeployment(); // Ensures deployment completion
    //console.log("MyGovernor deployed at:", governor.target);
  
    //await token.setGovernor(governor.target);

    const MyToken = await ethers.getContractFactory("MyToken");
    const token = await MyToken.deploy(governor.address); // Updated here
    await token.waitForDeployment();


    // Delegate tokens to the owner
    await token.delegate(owner.address);
  
    return { governor, token, owner, otherAccount };
  }
  
  it("should provide the owner with a starting balance", async () => {
    const { token, owner } = await loadFixture(deployFixture);

    const balance = await token.balanceOf(owner.address);
    assert.equal(balance.toString(), ethers.parseEther("10000").toString());
  });

  describe("after proposing", () => {
    async function afterProposingFixture() {
      const deployValues = await deployFixture();
      const { governor, token, owner } = deployValues;

      console.log("Token Address:", token.target);
      console.log("Governor Address:", governor.target);

      console.log(
        "Encoded mint data:",
        token.interface.encodeFunctionData("mint", [owner.address, parseEther("25000")])
      );

      
      const tx = await governor.propose(
        [token.target],
        [0],
        [token.interface.encodeFunctionData("mint", [owner.address, parseEther("25000")])],
        "Give the owner more tokens!"
      );
      //console.log(tx);
      
      const receipt = await tx.wait();
      //console.log("Transaction receipt:", receipt);
      //console.log(receipt.logs);     
      
      const proposalCreatedEvent = receipt.logs.find(log => 
          log.fragment && log.fragment.name === 'ProposalCreated'
        );
        const proposalId = proposalCreatedEvent.args[0].toString();

      // wait for the 1 block voting delay
      await hre.network.provider.send("evm_mine");
      
      return { ...deployValues, proposalId } 
    }
    
    it("should set the initial state of the proposal", async () => {
      const { governor, proposalId } = await loadFixture(afterProposingFixture);
      
      const state = await governor.state(proposalId);
      assert.equal(state, 0);
    });
    
    describe("after voting", () => {
      async function afterVotingFixture() {
        const proposingValues = await afterProposingFixture();
        const { governor, proposalId } = proposingValues;
        
        const tx = await governor.castVote(proposalId, 1);      
        const receipt = await tx.wait();
        const voteCastEvent = receipt.logs.find(log => 
          log.fragment && log.fragment.name ===  'VoteCast');
        
        // wait for the 1 block voting period
        await hre.network.provider.send("evm_mine");

        return { ...proposingValues, voteCastEvent }
      }

      it("should have set the vote", async () => {
        const { voteCastEvent, owner } = await loadFixture(afterVotingFixture);

        assert.equal(voteCastEvent.args.voter, owner.address);
        assert.equal(voteCastEvent.args.weight.toString(), parseEther("10000").toString());
      });

      it("should allow executing the proposal", async () => {
        const { governor, token, owner } = await loadFixture(afterVotingFixture);

        await governor.execute(
          [token.target],
          [0],
          [token.interface.encodeFunctionData("mint", [owner.address, parseEther("25000")])],
          keccak256(toUtf8Bytes("Give the owner more tokens!"))
        );

        const balance = await token.balanceOf(owner.address);
        assert.equal(balance.toString(), parseEther("35000").toString());
      });
    });
  });
});
