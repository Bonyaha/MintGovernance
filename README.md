# ERC20 Governor Project
#### this branch has following additions: faucet-like token claiming system, easy voting power checking, better proposal metadata tracking, proposal titles and descriptions, voter eligibility checking, active proposal listing
This repository contains a governance system built with OpenZeppelin's Governor contracts. Below are instructions for deploying, testing, and interacting with the governance system.

In this repository, you'll find two contracts:
 - MyGovernor - a contract built from the openzeppelin governor wizard. This Governor is configured to have a 1 block voting delay and voting period (for tests only, later I changed it to be 1 week). To make things simpler it does not include a Timelock, although it should be noted that this is standard practice in governance.
 - MyToken - a token which is built to work together with the governor standard. You can re-create it by toggle the Votes checkbox on the openzeppelin erc20 wizard.

The token will have two purposes:
1. It will be the token used for voting weight in our Governor contract.
2. It will have a mint function which can only be called when a proposal from the token holders has been successfully executed.




## Prerequisites

- Node.js and npm installed
- Hardhat environment set up
- Sepolia testnet ETH for deployment and transactions
- `.env` file configured with required environment variables

## Commands

### Testing
Run the unit tests:
```bash
npx hardhat test
```

### Deployment
Deploy the contracts to Sepolia network:
```bash
npx hardhat run scripts/deploy.js --network sepolia
```

### Contract Verification
Verify the deployed contract on Etherscan (replace the address with your deployed contract address):
```bash
npx hardhat verify --network sepolia --constructor-args constructorArgs.js 0xFcf16CBEA0b8A38b5aC1571f53Fb7A6Cbd343030
```

### Governance Actions

1. **Create Proposal**
   Create a new governance proposal:
   ```bash
   npx hardhat run scripts/proposal.js --network sepolia
   ```

2. **Vote on Proposal**
   Cast your vote on an active proposal:
   ```bash
   npx hardhat run scripts/vote.js --network sepolia
   ```

3. **Execute Proposal**
   Execute a successful proposal after the timelock period:
   ```bash
   npx hardhat run scripts/executeProposal.js --network sepolia
   ```

### Checking Status
Check proposal status and token balances:
```bash
npx hardhat run scripts/check.js --network sepolia
```

## Proposal States

The governance system uses the following states for proposals:
- 0: Pending
- 1: Active
- 2: Canceled
- 3: Defeated
- 4: Succeeded
- 5: Queued
- 6: Expired
- 7: Executed

## Important Notes

- Ensure you have sufficient Sepolia ETH before running transactions
- Wait for the appropriate voting and timelock periods between governance actions
- Keep track of proposal IDs for voting and execution
- Make sure your wallet is properly configured in the Hardhat config
- Make sure you have proper address for MyToken address in constructorArgs.js file (**it's important for verification process**)

## Troubleshooting

If you encounter errors:
1. Check your network connection
2. Verify you have sufficient ETH for gas
3. Ensure proposal IDs are correct
4. Confirm the proposal is in the correct state for the action you're attempting




#### MyToken deployed at: 0xD18dbCF7e018c305b5E293FDC4d235C11bf0Cfeb
#### MyGovernor deployed at: 0xFcf16CBEA0b8A38b5aC1571f53Fb7A6Cbd343030
#### Proposal id: 43299094184922297695527759677995549232058675074474518497860330663067653793646


