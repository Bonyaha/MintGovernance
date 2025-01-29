const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers")
const { assert, expect } = require("chai")
const { ethers } = require("hardhat")
const { toUtf8Bytes, keccak256, parseEther } = ethers

describe("MyGovernor", function () {
  // Base deployment fixture
  async function deployFixture() {
    const [owner, otherAccount] = await ethers.getSigners()

    const MyToken = await ethers.getContractFactory("MyToken")
    const token = await MyToken.deploy(ethers.ZeroAddress)
    await token.waitForDeployment()

    const TimelockController = await ethers.getContractFactory("TimelockController")
    const timelock = await TimelockController.deploy(
      10,
      [],
      [],
      owner.address
    )
    await timelock.waitForDeployment()

    const MyGovernor = await ethers.getContractFactory("MyGovernor")
    const governor = await MyGovernor.deploy(token.target, timelock.target)
    await governor.waitForDeployment()

    const proposerRole = await timelock.PROPOSER_ROLE()
    const executorRole = await timelock.EXECUTOR_ROLE()
    const adminRole = await timelock.DEFAULT_ADMIN_ROLE()

    await timelock.grantRole(proposerRole, governor.target)
    await timelock.grantRole(executorRole, ethers.ZeroAddress)
    await timelock.revokeRole(adminRole, owner.address)
    await token.setGovernor(timelock.target)
    await token.delegate(owner.address)

    return { governor, token, timelock, owner, otherAccount }
  }

  // Proposal creation fixture
  async function proposalFixture() {
    const deployValues = await deployFixture()
    const { governor, token, owner, otherAccount } = deployValues

    // Grant owner the proposal reviewer role
    await governor.addProposalReviewer(owner.address)

    // Prepare proposal data (mint to owner)
    const targets = [token.target]
    const values = [0]
    const calldatas = [token.interface.encodeFunctionData("mint", [owner.address, parseEther("25000")])]
    const descriptionText = "Give the owner more tokens!"
    const descriptionHash = keccak256(toUtf8Bytes(descriptionText))

    // Submit proposal for review AS OTHER ACCOUNT
    const submitTx = await governor.connect(otherAccount).submitProposalForReview(
      "Initial Proposal",
      targets,
      values,
      calldatas,
      descriptionText,
      0
    )
    await submitTx.wait()

    // Calculate proposalId (must match contract logic)
    const proposalId = await governor.hashProposal(
      targets,
      values,
      calldatas,
      descriptionHash
    )

    // Approve the proposal AS OWNER (reviewer)
    const approveTx = await governor.approveProposal(proposalId)
    await approveTx.wait()

    // Now propose the approved proposal AS OTHER ACCOUNT
    const proposeTx = await governor.connect(otherAccount).propose(
      targets,
      values,
      calldatas,
      descriptionText
    )
    const receipt = await proposeTx.wait()
    const proposalCreatedEvent = receipt.logs.find(log =>
      log.fragment && log.fragment.name === 'ProposalCreated'
    )
    const actualProposalId = proposalCreatedEvent.args[0].toString()

    await hre.network.provider.send("evm_mine")

    return {
      ...deployValues,
      proposalId: actualProposalId,
      targets,
      values,
      calldatas,
      mintCalldata: calldatas[0],
      descriptionHash,
      descriptionText
    }
  }

  // Voted proposal fixture
  async function votedProposalFixture() {
    const proposalValues = await proposalFixture()
    const { governor, token, proposalId, mintCalldata, descriptionHash } = proposalValues

    const voteTx = await governor.castVote(proposalId, 1)
    const voteReceipt = await voteTx.wait()
    const voteCastEvent = voteReceipt.logs.find(log =>
      log.fragment && log.fragment.name === 'VoteCast'
    )

    await hre.network.provider.send("evm_mine")

    await governor.queue(
      [token.target],
      [0],
      [mintCalldata],
      descriptionHash
    )

    return {
      ...proposalValues,
      voteCastEvent
    }
  }

  // Basic setup tests
  describe("Initial Setup", () => {
    it("should integrate with TimelockController correctly", async () => {
      const { timelock, governor, token, owner } = await loadFixture(deployFixture)

      assert.equal(await timelock.hasRole(timelock.PROPOSER_ROLE(), governor.target), true)
      assert.equal(await timelock.hasRole(timelock.EXECUTOR_ROLE(), ethers.ZeroAddress), true)
      assert.equal(await token.balanceOf(owner.address), parseEther("10000"))
    })

    it("should provide the owner with a starting balance", async () => {
      const { token, owner } = await loadFixture(deployFixture)
      assert.equal(await token.balanceOf(owner.address), parseEther("10000"))
    })
  })

  // Role-based Access Control tests
  describe("Role-based Access Control", () => {
    it("should verify governor contract is the only proposer", async () => {
      const { timelock, governor } = await loadFixture(deployFixture)
      assert.equal(
        await timelock.hasRole(await timelock.PROPOSER_ROLE(), governor.target),
        true,
        "Governor should have proposer role"
      )
    })

    it("should verify anyone can be executor", async () => {
      const { timelock } = await loadFixture(deployFixture)
      assert.equal(
        await timelock.hasRole(await timelock.EXECUTOR_ROLE(), ethers.ZeroAddress),
        true,
        "Anyone should be able to execute"
      )
    })

    it("should only allow proposals through governor contract", async () => {
      const { timelock, token, mintCalldata, descriptionHash } = await loadFixture(votedProposalFixture)
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

    it("should prevent non-admins from adding reviewers", async () => {
      const { governor, otherAccount } = await loadFixture(deployFixture)
      await expect(governor.connect(otherAccount).addProposalReviewer(otherAccount.address))
        .to.be.revertedWithCustomError(governor, "AccessControlUnauthorizedAccount")
    })
  })

  // Proposal Lifecycle tests
  describe("Proposal Lifecycle", () => {
    it("should set the initial state of the proposal", async () => {
      const { governor, proposalId } = await loadFixture(proposalFixture)
      assert.equal(await governor.state(proposalId), 0)
    })

    describe("Voting Process", () => {
      it("should have set the vote correctly", async () => {
        const { voteCastEvent, owner } = await loadFixture(votedProposalFixture)
        assert.equal(voteCastEvent.args.voter, owner.address)
        assert.equal(voteCastEvent.args.weight.toString(), parseEther("10000").toString())
      })

      it("should not allow executing before timelock delay", async () => {
        const { governor, token, mintCalldata, descriptionHash } = await loadFixture(votedProposalFixture)

        await expect(governor.execute(
          [token.target],
          [0],
          [mintCalldata],
          descriptionHash
        )).to.be.reverted
      })

      it("should allow executing after timelock delay", async () => {
        const { governor, token, owner, mintCalldata, descriptionHash } = await loadFixture(votedProposalFixture)

        await hre.network.provider.send("evm_increaseTime", [10])
        await hre.network.provider.send("evm_mine")

        await governor.execute(
          [token.target],
          [0],
          [mintCalldata],
          descriptionHash
        )

        assert.equal(await token.balanceOf(owner.address), parseEther("35000"))
      })

      it("should allow anyone to execute queued proposals", async () => {
        const { governor, token, otherAccount, mintCalldata, descriptionHash } = await loadFixture(votedProposalFixture)

        await hre.network.provider.send("evm_increaseTime", [10])
        await hre.network.provider.send("evm_mine")

        const governorAsOther = governor.connect(otherAccount)
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

  // Proposal Review Process tests
  describe("Proposal Review Process", () => {
    it("should prevent non-reviewers from approving proposals", async () => {
      const { governor, otherAccount } = await loadFixture(deployFixture)
      await expect(governor.connect(otherAccount).approveProposal(123))
        .to.be.revertedWithCustomError(governor, "AccessControlUnauthorizedAccount")
    })

    it("should reject unapproved proposals", async () => {
      const { governor, token, otherAccount } = await loadFixture(deployFixture)
      const calldata = token.interface.encodeFunctionData("mint", [otherAccount.address, 1000])
      await expect(
        governor.connect(otherAccount).propose([token.target], [0], [calldata], "Bad proposal")
      ).to.be.revertedWith("Proposal must be approved by reviewer")
    })

    it("should require re-approval for resubmitted proposals", async function () {
      const {
        governor,
        token,
        owner,
        otherAccount,
        targets,
        values,
        calldatas,
        descriptionText,
        proposalId
      } = await loadFixture(proposalFixture)

      // Cast vote on the proposal
      await governor.castVote(proposalId, 1)

      // Mine some blocks to pass voting period
      await hre.network.provider.send("evm_mine")

      // Queue the proposal
      await governor.queue(
        targets,
        values,
        calldatas,
        keccak256(toUtf8Bytes(descriptionText))
      )

      // Increase time to pass timelock delay
      await hre.network.provider.send("evm_increaseTime", [10])
      await hre.network.provider.send("evm_mine")

      // Execute the first proposal
      await governor.execute(
        targets,
        values,
        calldatas,
        keccak256(toUtf8Bytes(descriptionText))
      )

      // Resubmit with a DIFFERENT description
      const newDescriptionText = "Give the owner more tokens! - Resubmitted"
      const submitTx = await governor.connect(otherAccount).submitProposalForReview(
        "Resubmitted Proposal",
        targets,
        values,
        calldatas,
        newDescriptionText,
        0
      )
      await submitTx.wait()

      // Calculate new proposalId
      const newProposalId = await governor.hashProposal(
        targets,
        values,
        calldatas,
        keccak256(toUtf8Bytes(newDescriptionText))
      )

      // Verify new proposal requires approval
      expect(await governor.approvedProposals(newProposalId)).to.be.false

      // Attempt to propose without approval should fail
      await expect(
        governor.connect(otherAccount).propose(
          targets,
          values,
          calldatas,
          newDescriptionText
        )
      ).to.be.revertedWith("Proposal must be approved by reviewer")

      // Approve and propose should succeed
      await governor.approveProposal(newProposalId)
      await expect(
        governor.connect(otherAccount).propose(
          targets,
          values,
          calldatas,
          newDescriptionText
        )
      ).to.not.be.reverted
    })
  })

  // Token Governance tests
  describe("Token Governance", () => {
    it("should prevent non-governor from minting", async () => {
      const { token, otherAccount } = await loadFixture(deployFixture)
      await expect(token.connect(otherAccount).mint(otherAccount.address, 1000))
        .to.be.revertedWith("Only governor can mint")
    })
  })
})