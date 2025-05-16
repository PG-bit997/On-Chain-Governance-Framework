const hre = require("hardhat");

async function main() {
  console.log("Deploying On-Chain Governance Framework contracts...");

  // Deploy the GovernanceFactory contract
  const GovernanceFactory = await hre.ethers.getContractFactory("GovernanceFactory");
  const governanceFactory = await GovernanceFactory.deploy(await hre.ethers.provider.getSigner(0).getAddress());

  await governanceFactory.waitForDeployment();
  const governanceFactoryAddress = await governanceFactory.getAddress();
  
  console.log(`GovernanceFactory deployed to: ${governanceFactoryAddress}`);
  
  // Now let's create a governance system through the factory
  console.log("Creating a governance system through the factory...");
  
  // Define governance parameters
  const tokenName = "Governance Token";
  const tokenSymbol = "GOV";
  const initialSupply = 1000000; // 1 million tokens (before decimals)
  const proposalThreshold = hre.ethers.parseEther("10000"); // 10,000 tokens to create proposal
  const votingDelay = 60 * 60; // 1 hour before voting starts
  const votingPeriod = 7 * 24 * 60 * 60; // 1 week voting period
  const quorumVotes = hre.ethers.parseEther("100000"); // 100,000 tokens required for quorum
  const executionDelay = 2 * 24 * 60 * 60; // 2 days delay before execution
  
  // Create governance system
  const tx = await governanceFactory.createGovernanceSystem(
    tokenName,
    tokenSymbol,
    initialSupply,
    proposalThreshold,
    votingDelay,
    votingPeriod,
    quorumVotes,
    executionDelay
  );
  
  // Wait for transaction confirmation
  const receipt = await tx.wait();
  
  // Extract the event data to get the deployed contract addresses
  const event = receipt.logs.find(log => 
    log.topics[0] === hre.ethers.id("GovernanceSystemCreated(address,address,address)")
  );
  
  if (event) {
    const decodedEvent = hre.ethers.AbiCoder.defaultAbiCoder().decode(
      ["address", "address", "address"],
      hre.ethers.dataSlice(event.data, 0)
    );
    
    console.log(`Governance Token deployed to: ${decodedEvent[0]}`);
    console.log(`Governance Contract deployed to: ${decodedEvent[1]}`);
    console.log(`System deployed by: ${decodedEvent[2]}`);
  } else {
    console.log("Could not find the GovernanceSystemCreated event in the transaction logs.");
  }
  
  console.log("Deployment completed successfully!");
}

// We recommend this pattern to be able to use async/await everywhere
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
