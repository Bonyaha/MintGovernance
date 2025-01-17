const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers")
const { assert, expect } = require("chai")
const { ethers } = require("hardhat")
const { toUtf8Bytes, keccak256, parseEther } = ethers

describe("MyGovernor", function () {
  async function deployFixture() {
    const [owner, otherAccount] = await ethers.getSigners()
    //console.log("Owner:", owner.address);   

    // Deploy MyToken first
    const MyToken = await ethers.getContractFactory("MyToken")
    const token = await MyToken.deploy(ethers.ZeroAddress)
    await token.waitForDeployment() // Ensures deployment completion
    //console.log("MyToken deployed at:", token.target);

    // Create proposer and executor arrays for timelock
    const proposers = [owner.address]
    const executors = [ethers.ZeroAddress] // Allow anyone to execute

    // Deploy TimelockController first
    const TimelockController = await ethers.getContractFactory("TimelockController")
    const timelock = await TimelockController.deploy(
      10, // minDelay
      [], // proposers (empty)
      [], // executors (empty)
      owner.address // admin
    )
    await timelock.waitForDeployment()

    // Deploy MyGovernor with the actual deployed address of MyToken
    const MyGovernor = await ethers.getContractFactory("MyGovernor")
    const governor = await MyGovernor.deploy(token.target, timelock.target)
    await governor.waitForDeployment() // Ensures deployment completion
    //console.log("MyGovernor deployed at:", governor.target);

    // Setup roles
    const proposerRole = await timelock.PROPOSER_ROLE()
    const executorRole = await timelock.EXECUTOR_ROLE()
    const adminRole = await timelock.DEFAULT_ADMIN_ROLE()

    await timelock.grantRole(proposerRole, governor.target)
    await timelock.grantRole(executorRole, ethers.ZeroAddress) // anyone can execute
    await timelock.revokeRole(adminRole, owner.address) //TimelockController automatically retains administrative control because it is designed to be its own admin by default.

    // Update the token's governor address after deployment
    await token.setGovernor(timelock.target)

    // Delegate tokens to the owner
    await token.delegate(owner.address)

    return { governor, token, timelock, owner, otherAccount }
  }

  it("should integrate with TimelockController correctly", async () => {
    const { timelock, governor, token, owner } = await loadFixture(deployFixture)

    // Check initial setup
    assert.equal(await timelock.hasRole(timelock.PROPOSER_ROLE(), governor.target), true)
    assert.equal(await timelock.hasRole(timelock.EXECUTOR_ROLE(), ethers.ZeroAddress), true)
    assert.equal(await token.balanceOf(owner.address), parseEther("10000"))
    // Verify configurations
    console.log("Governor is proposer:", await timelock.hasRole(timelock.PROPOSER_ROLE(), governor.target)) // true
    console.log("Anyone is executor:", await timelock.hasRole(timelock.EXECUTOR_ROLE(), ethers.ZeroAddress))
    console.log("Admin is timelock:", await timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), timelock.target))

  })

  it("should provide the owner with a starting balance", async () => {
    const { token, owner } = await loadFixture(deployFixture)

    const balance = await token.balanceOf(owner.address)
    assert.equal(balance.toString(), ethers.parseEther("10000").toString())
  })

  describe("after proposing", () => {
    async function afterProposingFixture() {
      const deployValues = await deployFixture()
      const { governor, token, owner } = deployValues

      console.log("Token Address:", token.target)
      console.log("Governor Address:", governor.target)

      // Encode the mint calldata for queueing and execution
      const mintCalldata = token.interface.encodeFunctionData("mint", [owner.address, parseEther("25000")])

      console.log(
        "Encoded mint data:",
        mintCalldata
      )


      const tx = await governor.propose(
        [token.target],
        [0],
        [mintCalldata],
        "Give the owner more tokens!"
      )
      //console.log(tx);

      const receipt = await tx.wait()
      //console.log("Transaction receipt:", receipt);
      //console.log(receipt.logs);     

      const proposalCreatedEvent = receipt.logs.find(log =>
        log.fragment && log.fragment.name === 'ProposalCreated'
      )
      const proposalId = proposalCreatedEvent.args[0].toString()

      // wait for the 1 block voting delay
      await hre.network.provider.send("evm_mine")

      return { ...deployValues, proposalId, mintCalldata }
    }

    it("should set the initial state of the proposal", async () => {
      const { governor, proposalId } = await loadFixture(afterProposingFixture)

      const state = await governor.state(proposalId)
      assert.equal(state, 0)
    })



    describe("after voting", () => {
      async function afterVotingFixture() {
        const proposingValues = await afterProposingFixture()
        const { governor, proposalId, mintCalldata, token } = proposingValues

        const tx = await governor.castVote(proposalId, 1)
        const receipt = await tx.wait()
        const voteCastEvent = receipt.logs.find(log =>
          log.fragment && log.fragment.name === 'VoteCast')

        // wait for the 1 block voting period
        //await hre.network.provider.send("evm_increaseTime", [10]); // Timelock delay
        await hre.network.provider.send("evm_mine")

        // Queue the proposal in the timelock
        await governor.queue(
          [token.target],
          [0],
          [mintCalldata],
          keccak256(toUtf8Bytes("Give the owner more tokens!"))
        )


        return { ...proposingValues, voteCastEvent, mintCalldata }
      }

      it("should have set the vote", async () => {
        const { voteCastEvent, owner } = await loadFixture(afterVotingFixture)

        assert.equal(voteCastEvent.args.voter, owner.address)
        assert.equal(voteCastEvent.args.weight.toString(), parseEther("10000").toString())
      })

      it("should not allow executing a proposal before the timelock delay expires", async () => {
        const { governor, token, mintCalldata } = await loadFixture(afterVotingFixture)

        // Attempt to execute immediately after queuing
        await expect(governor.execute(
          [token.target],
          [0],
          [mintCalldata],
          keccak256(toUtf8Bytes("Give the owner more tokens!"))
        )).to.be.reverted
      })

      it("should allow executing the proposal", async () => {
        const { governor, token, owner, mintCalldata } = await loadFixture(afterVotingFixture)

        // Simulate the timelock delay
        await hre.network.provider.send("evm_increaseTime", [10]) // Matches the 10 seconds in MyGovernor.sol
        await hre.network.provider.send("evm_mine")

        await governor.execute(
          [token.target],
          [0],
          [mintCalldata],
          keccak256(toUtf8Bytes("Give the owner more tokens!"))
        )

        const balance = await token.balanceOf(owner.address)
        assert.equal(balance.toString(), parseEther("35000").toString())
      })
    })
  })

  describe("Role-based Access Control", () => {
    async function afterVotingFixture() {
      const { governor, token, timelock, owner, otherAccount } = await deployFixture()

      // Create and pass a proposal first
      const mintCalldata = token.interface.encodeFunctionData("mint", [owner.address, parseEther("25000")])

      const proposeTx = await governor.propose(
        [token.target],
        [0],
        [mintCalldata],
        "Give the owner more tokens!"
      )

      const receipt = await proposeTx.wait()
      const proposalCreatedEvent = receipt.logs.find(log =>
        log.fragment && log.fragment.name === 'ProposalCreated'
      )
      const proposalId = proposalCreatedEvent.args[0].toString()

      // Wait for voting delay
      await hre.network.provider.send("evm_mine")

      // Cast vote
      await governor.castVote(proposalId, 1)

      // Wait for voting period
      await hre.network.provider.send("evm_mine")

      const descriptionHash = keccak256(toUtf8Bytes("Give the owner more tokens!"))

      return {
        governor,
        token,
        timelock,
        owner,
        otherAccount,
        proposalId,
        mintCalldata,
        descriptionHash
      }
    }

    it("should verify governor contract is the only proposer", async () => {
      const { timelock, governor } = await loadFixture(afterVotingFixture)

      const proposerRole = await timelock.PROPOSER_ROLE()

      // Verify governor is proposer
      assert.equal(
        await timelock.hasRole(proposerRole, governor.target),
        true,
        "Governor should have proposer role"
      )
    })

    it("should verify anyone can be executor", async () => {
      const { timelock } = await loadFixture(afterVotingFixture)

      const executorRole = await timelock.EXECUTOR_ROLE()

      // Verify zero address (anyone) has executor role
      assert.equal(
        await timelock.hasRole(executorRole, ethers.ZeroAddress),
        true,
        "Anyone should be able to execute"
      )
    })

    it("should only allow proposals through governor contract", async () => {
      const {
        timelock,
        token,
        owner,
        mintCalldata,
        descriptionHash
      } = await loadFixture(afterVotingFixture)

      // Try to directly schedule through timelock (should fail)
      const delay = await timelock.getMinDelay()

      await expect(
        timelock.schedule(
          token.target,         
          0,                    
          mintCalldata,         
          ethers.ZeroHash,   
          descriptionHash,      
          delay                 
        )
      ).to.be.reverted
    })

    it("should allow anyone to execute queued proposals", async () => {
      const {
        governor,
        token,
        otherAccount,
        mintCalldata,
        descriptionHash
      } = await loadFixture(afterVotingFixture)

      // Queue the proposal first using governor
      await governor.queue(
        [token.target],
        [0],
        [mintCalldata],
        descriptionHash
      )

      // Wait for timelock
      await hre.network.provider.send("evm_increaseTime", [10])
      await hre.network.provider.send("evm_mine")

      // Connect as other account
      const governorAsOther = governor.connect(otherAccount)

      // Should succeed since anyone can execute
      await expect(
        governorAsOther.execute(
          [token.target],
          [0],
          [mintCalldata],
          descriptionHash
        )
      ).to.not.be.reverted
    })
  })
})


