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
    uint256 public votingDelay = 1 days;         // Delay before voting starts
    uint256 public votingPeriod = 3 days;        // Duration of voting period
    uint256 public proposalThreshold = 1000 * 10**18; // Minimum tokens to create proposal
    uint256 public quorumPercentage = 10;        // Minimum percentage of total supply needed
    uint256 public executionDelay = 1 days;      // Delay before execution

    // Emergency pause flag
    bool public paused;

    // Proposal states
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
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
    mapping(uint256 => bool) public queuedProposals;

    // Delegation mappings
    mapping(address => address) public delegates;
    mapping(address => uint256) public delegatedVotes;
    
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

    event ProposalQueued(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event Paused();
    event Unpaused();

    // Modifiers
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    /**
     * @dev Constructor
     * @param _governanceToken Address of the governance token
     */
    constructor(address _governanceToken) {
        governanceToken = IERC20(_governanceToken);
    }

    /**
     * @dev Emergency pause contract operations
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    /**
     * @dev Unpause contract operations
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

    /**
     * @dev Create a new governance proposal
     */
    function createProposal(
        string memory description,
        address target,
        bytes memory callData
    ) external nonReentrant whenNotPaused returns (uint256) {
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
            executionTime: 0,
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
     * @dev Cast a vote on a proposal
     */
    function castVote(uint256 proposalId, uint8 support) external nonReentrant whenNotPaused {
        require(support <= 2, "Invalid vote type");
        require(getProposalState(proposalId) == ProposalState.Active, "Voting is not active");
        require(!proposalVotes[proposalId][msg.sender].hasVoted, "Already voted");

        uint256 votes = getVotingPower(msg.sender);
        require(votes > 0, "No voting power");

        proposalVotes[proposalId][msg.sender] = Vote({
            hasVoted: true,
            support: support,
            votes: votes
        });

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
     * @dev Queue a proposal for execution after success
     */
    function queueProposal(uint256 proposalId) external whenNotPaused {
        require(getProposalState(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");
        Proposal storage proposal = proposals[proposalId];
        require(!queuedProposals[proposalId], "Already queued");
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Proposal cancelled");

        queuedProposals[proposalId] = true;
        proposal.executionTime = block.timestamp + executionDelay;

        emit ProposalQueued(proposalId);
    }

    /**
     * @dev Execute a successful proposal after queue and delay
     */
    function executeProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        require(queuedProposals[proposalId], "Proposal not queued");
        require(getProposalState(proposalId) == ProposalState.Succeeded, "Proposal not ready for execution");

        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.executionTime, "Execution delay not met");
        require(!proposal.executed, "Proposal already executed");

        proposal.executed = true;
        queuedProposals[proposalId] = false;

        if (proposal.target != address(0) && proposal.callData.length > 0) {
            (bool success, ) = proposal.target.call(proposal.callData);
            require(success, "Proposal execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @dev Cancel a proposal
     */
    function cancelProposal(uint256 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer || msg.sender == owner(),
            "Only proposer or owner can cancel"
        );
        require(!proposal.executed, "Cannot cancel executed proposal");
        require(!proposal.cancelled, "Proposal already cancelled");

        proposal.cancelled = true;
        if (queuedProposals[proposalId]) {
            queuedProposals[proposalId] = false;
        }

        emit ProposalCancelled(proposalId);
    }

    /**
     * @dev Get the current state of a proposal
     */
    function getProposalState(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.cancelled) {
            return ProposalState.Cancelled;
        }

        if (proposal.executed) {
            return ProposalState.Executed;
        }

        if (queuedProposals[proposalId]) {
            return ProposalState.Queued;
        }

        if (block.timestamp < proposal.startTime) {
            return ProposalState.Pending;
        }

        if (block.timestamp <= proposal.endTime) {
            return ProposalState.Active;
        }

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
     * @dev Get voting power of an address including delegated votes
     */
    function getVotingPower(address account) public view returns (uint256) {
        return governanceToken.balanceOf(account) + delegatedVotes[account];
    }

    /**
     * @dev Delegate voting power to another address
     */
    function delegate(address delegatee) external whenNotPaused {
        address currentDelegate = delegates[msg.sender];
        uint256 delegatorBalance = governanceToken.balanceOf(msg.sender);

        delegates[msg.sender] = delegatee;

        if (currentDelegate != address(0)) {
            delegatedVotes[currentDelegate] -= delegatorBalance;
        }
        delegatedVotes[delegatee] += delegatorBalance;

        emit DelegateChanged(msg.sender, currentDelegate, delegatee);
    }

    /**
     * @dev Get votes breakdown for a proposal
     */
    function getProposalVotes(uint256 proposalId) external view returns (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes) {
        Proposal storage proposal = proposals[proposalId];
        return (proposal.forVotes, proposal.againstVotes, proposal.abstainVotes);
    }

    /**
     * @dev Update execution delay (only owner)
     */
    function updateExecutionDelay(uint256 _executionDelay) external onlyOwner {
        executionDelay = _executionDelay;
    }

    /**
     * @dev Update voting delay (only owner)
     */
    function updateVotingDelay(uint256 _votingDelay) external onlyOwner {
        votingDelay = _votingDelay;
    }

    /**
     * @dev Update voting period (only owner)
     */
    function updateVotingPeriod(uint256 _votingPeriod) external onlyOwner {
        votingPeriod = _votingPeriod;
    }

    /**
     * @dev Update proposal threshold (only owner)
     */
    function updateProposalThreshold(uint256 _proposalThreshold) external onlyOwner {
        proposalThreshold = _proposalThreshold;
    }

    /**
     * @dev Update quorum percentage (only owner)
     */
    function updateQuorumPercentage(uint256 _quorumPercentage) external onlyOwner {
        require(_quorumPercentage <= 100, "Invalid quorum percentage");
        quorumPercentage = _quorumPercentage;
    }
}
