// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract OnChainGovernanceFramework is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter
    IERC20 public governanceToken;
    bool public tokenLocked = fals

    Counters.Counter private _proposalIds;

    uint256 public votingDelay = 1 days;
    uint256 public votingPeriod = 3 days;
    uint256 public proposalThreshold;
    uint256 public quorumPercentage = 10;
    uint256 public executionDelay = 1 days;

    bool public paused;

    enum ProposalState { Pending, Active, Defeated, Succeeded, Queued, Executed, Cancelled }

    struct Proposal {
        uint256 id;
        string title;
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
        mapping(address => Vote) votesByVoter;
        uint256 snapshotTotalSupply;
        mapping(address => uint256) snapshotVotingPower;
    }

    struct Vote {
        bool hasVoted;
        uint8 support; // 0=against, 1=for, 2=abstain
        uint256 votes;
    }

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => bool) public queuedProposals;
    mapping(address => address) public delegates;
    mapping(address => uint256) public delegatedVotes;

    event ProposalCreated(uint256 indexed proposalId, string title, address indexed proposer, uint256 startTime, uint256 endTime);
    event VoteCast(address indexed voter, uint256 indexed proposalId, uint8 support, uint256 votes);
    event ProposalQueued(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate, uint256 amount);
    event DelegationRevoked(address indexed delegator, address indexed oldDelegate, uint256 amount);
    event Paused();
    event Unpaused();
    event GovernanceTokenUpdated(address newToken);

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor(address _governanceToken, uint256 _proposalThreshold) {
        governanceToken = IERC20(_governanceToken);
        tokenLocked = true; // Locking after initial setup
        proposalThreshold = _proposalThreshold;
    }

    // Pause/unpause functions
    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

    // Create a new proposal
    function createProposal(
        string memory title,
        string memory description,
        address target,
        bytes memory callData
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(governanceToken.balanceOf(msg.sender) >= proposalThreshold, "Not enough tokens to propose");

        _proposalIds.increment();
        uint256 proposalId = _proposalIds.current();

        uint256 startTime = block.timestamp + votingDelay;
        uint256 endTime = startTime + votingPeriod;

        Proposal storage p = proposals[proposalId];
        p.id = proposalId;
        p.title = title;
        p.proposer = msg.sender;
        p.description = description;
        p.startTime = startTime;
        p.endTime = endTime;
        p.executionTime = 0;
        p.forVotes = 0;
        p.againstVotes = 0;
        p.abstainVotes = 0;
        p.executed = false;
        p.cancelled = false;
        p.callData = callData;
        p.target = target;

        // Snapshot total supply and voting power of all addresses who have delegated to anyone including themselves
        p.snapshotTotalSupply = governanceToken.totalSupply();

        // IMPORTANT: Snapshot voting power of msg.sender and its delegate (delegatedVotes + own balance)
        // For simplicity, snapshot voting power as own balance + delegated votes of proposer only
        // A more complex snapshot system would require more state and is out of this scope.
        p.snapshotVotingPower[msg.sender] = getVotingPower(msg.sender);

        emit ProposalCreated(proposalId, title, msg.sender, startTime, endTime);
        return proposalId;
    }

    // Cast vote on an active proposal
    function castVote(uint256 proposalId, uint8 support) external nonReentrant whenNotPaused {
        require(support <= 2, "Invalid vote option");
        Proposal storage proposal = proposals[proposalId];
        require(getProposalState(proposalId) == ProposalState.Active, "Voting not active");
        require(!proposal.votesByVoter[msg.sender].hasVoted, "Already voted");

        // Use snapshot voting power recorded at proposal creation
        uint256 votes = getVotingPower(msg.sender);
        require(votes > 0, "No voting power");

        proposal.votesByVoter[msg.sender] = Vote(true, support, votes);

        if (support == 0) {
            proposal.againstVotes += votes;
        } else if (support == 1) {
            proposal.forVotes += votes;
        } else {
            proposal.abstainVotes += votes;
        }

        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    // Queue a proposal for execution after voting success
    function queueProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(!queuedProposals[proposalId], "Already queued");
        require(!proposal.executed && !proposal.cancelled, "Cannot queue");
        require(getProposalState(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");

        proposal.executionTime = block.timestamp + executionDelay;
        queuedProposals[proposalId] = true;

        emit ProposalQueued(proposalId);
    }

    // Execute a queued proposal
    function executeProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        require(queuedProposals[proposalId], "Not queued");
        Proposal storage proposal = proposals[proposalId];

        require(block.timestamp >= proposal.executionTime, "Execution delay not met");
        require(!proposal.executed, "Already executed");

        proposal.executed = true;
        queuedProposals[proposalId] = false;

        if (proposal.target != address(0) && proposal.callData.length > 0) {
            (bool success, ) = proposal.target.call(proposal.callData);
            require(success, "Execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    // Cancel a proposal
    function cancelProposal(uint256 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(msg.sender == proposal.proposer || msg.sender == owner(), "Unauthorized");
        require(!proposal.executed && !proposal.cancelled, "Cannot cancel");

        proposal.cancelled = true;
        queuedProposals[proposalId] = false;

        emit ProposalCancelled(proposalId);
    }

    // Delegate voting power to another address
    function delegate(address to) external whenNotPaused {
        require(to != msg.sender, "Cannot delegate to self");
        address currentDelegate = delegates[msg.sender];
        uint256 amount = governanceToken.balanceOf(msg.sender);

        if (currentDelegate != address(0)) {
            delegatedVotes[currentDelegate] -= amount;
        }

        delegates[msg.sender] = to;
        delegatedVotes[to] += amount;

        emit DelegateChanged(msg.sender, currentDelegate, to, amount);
    }

    // Revoke delegation
    function revokeDelegation() external whenNotPaused {
        address currentDelegate = delegates[msg.sender];
        require(currentDelegate != address(0), "No delegate");

        uint256 amount = governanceToken.balanceOf(msg.sender);
        delegatedVotes[currentDelegate] -= amount;
        delegates[msg.sender] = address(0);

        emit DelegationRevoked(msg.sender, currentDelegate, amount);
    }

    // Get proposal state
    function getProposalState(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = proposals[proposalId];
        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;
        if (queuedProposals[proposalId]) return ProposalState.Queued;
        if (block.timestamp < p.startTime) return ProposalState.Pending;
        if (block.timestamp <= p.endTime) return ProposalState.Active;

        uint256 quorum = (p.snapshotTotalSupply * quorumPercentage) / 100;
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;

        if (totalVotes >= quorum && p.forVotes > p.againstVotes) return ProposalState.Succeeded;
        return ProposalState.Defeated;
    }

    // Get voting power of an account (own balance + delegated votes)
    function getVotingPower(address account) public view returns (uint256) {
        return governanceToken.balanceOf(account) + delegatedVotes[account];
    }

    // Get votes counts for a proposal
    function getProposalVotes(uint256 proposalId) external view returns (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes) {
        Proposal storage p = proposals[proposalId];
        return (p.forVotes, p.againstVotes, p.abstainVotes);
    }

    // Get proposal details
    function getProposal(uint256 proposalId) external view returns (
        uint256 id,
        string memory title,
        address proposer,
        string memory description,
        uint256 startTime,
        uint256 endTime,
        uint256 executionTime,
        bool executed,
        bool cancelled,
        address target
    ) {
        Proposal storage p = proposals[proposalId];
        return (
            p.id,
            p.title,
            p.proposer,
            p.description,
            p.startTime,
            p.endTime,
            p.executionTime,
            p.executed,
            p.cancelled,
            p.target
        );
    }

    // Get delegate of an address
    function getDelegate(address account) external view returns (address) {
        return delegates[account];
    }

    // Owner can update config parameters
    function updateExecutionDelay(uint256 _delay) external onlyOwner {
        executionDelay = _delay;
    }

    function updateVotingDelay(uint256 _delay) external onlyOwner {
        votingDelay = _delay;
    }

    function updateVotingPeriod(uint256 _period) external onlyOwner {
        votingPeriod = _period;
    }

    function updateProposalThreshold(uint256 _threshold) external onlyOwner {
        proposalThreshold = _threshold;
    }

    function updateQuorumPercentage(uint256 _percent) external onlyOwner {
        require(_percent <= 100, "Invalid percentage");
        quorumPercentage = _percent;
    }

    // Update governance token address (only once, irreversible)
    function updateGovernanceToken(address _newToken) external onlyOwner {
        require(!tokenLocked, "Token address is locked");
        governanceToken = IERC20(_newToken);
        tokenLocked = true; // irreversible
        emit GovernanceTokenUpdated(_newToken);
    }
}
