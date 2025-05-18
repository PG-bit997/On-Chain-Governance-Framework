// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
 * @title OnChainGovernanceFramework
 * @dev A comprehensive governance framework for decentralized decision making
 */
contract OnChainGovernanceFramework is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;

    // Governance token interface
    IERC20 public governanceToken;
    
    // Proposal counter
    Counters.Counter private _proposalIds;

    // Governance parameters
    uint256 public votingDelay = 1 days;      // Delay before voting starts
    uint256 public votingPeriod = 3 days;    // Duration of voting period
    uint256 public proposalThreshold = 1000 * 10**18; // Minimum tokens to create proposal
    uint256 public quorumPercentage = 10;    // Minimum percentage of total supply needed
    uint256 public executionDelay = 1 days;  // Delay before execution

    // Proposal states
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Executed,
        Cancelled
    }

    // Proposal structure
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 executionTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool cancelled;
        bytes callData;
        address target;
    }

    // Vote structure
    struct Vote {
        bool hasVoted;
        uint8 support; // 0=against, 1=for, 2=abstain
        uint256 votes;
    }

    // Mappings
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Vote)) public proposalVotes;
    mapping(address => uint256) public votingPower;
    
    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 startTime,
        uint256 endTime
    );
    
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support,
        uint256 votes
    );
    
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);

    /**
     * @dev Constructor
     * @param _governanceToken Address of the governance token
     */
    constructor(address _governanceToken) {
        governanceToken = IERC20(_governanceToken);
    }

    /**
     * @dev Core Function 1: Create a new governance proposal
     * @param description Description of the proposal
     * @param target Target contract address for execution
     * @param callData Encoded function call data
     * @return proposalId The ID of the created proposal
     */
    function createProposal(
        string memory description,
        address target,
        bytes memory callData
    ) external nonReentrant returns (uint256) {
        require(
            governanceToken.balanceOf(msg.sender) >= proposalThreshold,
            "Insufficient tokens to create proposal"
        );

        _proposalIds.increment();
        uint256 proposalId = _proposalIds.current();

        uint256 startTime = block.timestamp + votingDelay;
        uint256 endTime = startTime + votingPeriod;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            startTime: startTime,
            endTime: endTime,
            executionTime: endTime + executionDelay,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            executed: false,
            cancelled: false,
            callData: callData,
            target: target
        });

        emit ProposalCreated(proposalId, msg.sender, description, startTime, endTime);
        return proposalId;
    }

    /**
     * @dev Core Function 2: Cast a vote on a proposal
     * @param proposalId The ID of the proposal
     * @param support The vote direction (0=against, 1=for, 2=abstain)
     */
    function castVote(uint256 proposalId, uint8 support) external nonReentrant {
        require(support <= 2, "Invalid vote type");
        require(getProposalState(proposalId) == ProposalState.Active, "Voting is not active");
        require(!proposalVotes[proposalId][msg.sender].hasVoted, "Already voted");

        uint256 votes = getVotingPower(msg.sender);
        require(votes > 0, "No voting power");

        // Record the vote
        proposalVotes[proposalId][msg.sender] = Vote({
            hasVoted: true,
            support: support,
            votes: votes
        });

        // Update proposal vote tallies
        Proposal storage proposal = proposals[proposalId];
        if (support == 0) {
            proposal.againstVotes += votes;
        } else if (support == 1) {
            proposal.forVotes += votes;
        } else {
            proposal.abstainVotes += votes;
        }

        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    /**
     * @dev Core Function 3: Execute a successful proposal
     * @param proposalId The ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        require(getProposalState(proposalId) == ProposalState.Succeeded, "Proposal not ready for execution");
        
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.executionTime, "Execution delay not met");
        require(!proposal.executed, "Proposal already executed");

        proposal.executed = true;

        // Execute the proposal call
        if (proposal.target != address(0) && proposal.callData.length > 0) {
            (bool success, ) = proposal.target.call(proposal.callData);
            require(success, "Proposal execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @dev Get the current state of a proposal
     * @param proposalId The ID of the proposal
     * @return The current state of the proposal
     */
    function getProposalState(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.cancelled) {
            return ProposalState.Cancelled;
        }
        
        if (proposal.executed) {
            return ProposalState.Executed;
        }
        
        if (block.timestamp < proposal.startTime) {
            return ProposalState.Pending;
        }
        
        if (block.timestamp <= proposal.endTime) {
            return ProposalState.Active;
        }
        
        // Check if proposal succeeded
        uint256 totalSupply = governanceToken.totalSupply();
        uint256 quorum = (totalSupply * quorumPercentage) / 100;
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        
        if (totalVotes >= quorum && proposal.forVotes > proposal.againstVotes) {
            return ProposalState.Succeeded;
        } else {
            return ProposalState.Defeated;
        }
    }

    /**
     * @dev Get voting power of an address
     * @param account The address to check
     * @return The voting power (token balance)
     */
    function getVotingPower(address account) public view returns (uint256) {
        return governanceToken.balanceOf(account);
    }

    /**
     * @dev Get proposal details
     * @param proposalId The ID of the proposal
     * @return Proposal structure
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @dev Get the total number of proposals
     * @return The total count of proposals
     */
    function getProposalCount() external view returns (uint256) {
        return _proposalIds.current();
    }

    /**
     * @dev Update governance parameters (only owner)
     * @param _votingDelay New voting delay
     * @param _votingPeriod New voting period
     * @param _proposalThreshold New proposal threshold
     * @param _quorumPercentage New quorum percentage
     */
    function updateGovernanceParameters(
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumPercentage
    ) external onlyOwner {
        require(_quorumPercentage <= 100, "Quorum percentage cannot exceed 100");
        
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        proposalThreshold = _proposalThreshold;
        quorumPercentage = _quorumPercentage;
    }

    /**
     * @dev Cancel a proposal (only proposer or owner)
     * @param proposalId The ID of the proposal to cancel
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer || msg.sender == owner(),
            "Only proposer or owner can cancel"
        );
        require(!proposal.executed, "Cannot cancel executed proposal");
        
        proposal.cancelled = true;
        emit ProposalCancelled(proposalId);
    }
}
