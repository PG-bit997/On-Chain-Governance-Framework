// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract OnChainGovernanceFramework is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;

    IERC20 public governanceToken;
    bool public tokenLocked = false;

    Counters.Counter private _proposalIds

    uint256 public votingDelay = 1 days;
    uint256 public votingPeriod = 3 days;
    uint256 public proposalThreshold = 1000 * 10**18;
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
    }

    struct Vote {
        bool hasVoted;
        uint8 support; // 0=against, 1=for, 2=abstain
        uint256 votes;
    }

    

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

    constructor(address _governanceToken) {
        governanceToken = IERC20(_governanceToken);
        tokenLocked = true; // Locking after setting initially
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

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

        proposals[proposalId] = Proposal({
            id: proposalId,
            title: title,
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

        emit ProposalCreated(proposalId, title, msg.sender, startTime, endTime);
        return proposalId;
    }

    function castVote(uint256 proposalId, uint8 support) external nonReentrant whenNotPaused {
        require(support <= 2, "Invalid vote option");
        require(getProposalState(proposalId) == ProposalState.Active, "Voting not active");
        require(!proposalVotes[proposalId][msg.sender].hasVoted, "Already voted");

        uint256 votes = getVotingPower(msg.sender);
        require(votes > 0, "No voting power");

        proposalVotes[proposalId][msg.sender] = Vote(true, support, votes);

        Proposal storage proposal = proposals[proposalId];
        if (support == 0) proposal.againstVotes += votes;
        else if (support == 1) proposal.forVotes += votes;
        else proposal.abstainVotes += votes;

        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    function queueProposal(uint256 proposalId) external whenNotPaused {
        require(getProposalState(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");
        Proposal storage proposal = proposals[proposalId];

        require(!queuedProposals[proposalId], "Already queued");
        require(!proposal.executed && !proposal.cancelled, "Cannot queue");

        proposal.executionTime = block.timestamp + executionDelay;
        queuedProposals[proposalId] = true;

        emit ProposalQueued(proposalId);
    }

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

    function cancelProposal(uint256 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(msg.sender == proposal.proposer || msg.sender == owner(), "Unauthorized");
        require(!proposal.executed && !proposal.cancelled, "Cannot cancel");

        proposal.cancelled = true;
        queuedProposals[proposalId] = false;

        emit ProposalCancelled(proposalId);
    }

    function delegate(address to) external whenNotPaused {
        require(to != msg.sender, "Cannot delegate to self");
        address current = delegates[msg.sender];
        uint256 amount = governanceToken.balanceOf(msg.sender);

        if (current != address(0)) {
            delegatedVotes[current] -= amount;
        }

        delegates[msg.sender] = to;
        delegatedVotes[to] += amount;

        emit DelegateChanged(msg.sender, current, to, amount);
    }

    function revokeDelegation() external whenNotPaused {
        address current = delegates[msg.sender];
        require(current != address(0), "No delegate");

        uint256 amount = governanceToken.balanceOf(msg.sender);
        delegatedVotes[current] -= amount;
        delegates[msg.sender] = address(0);

        emit DelegationRevoked(msg.sender, current, amount);
    }

    function getProposalState(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = proposals[proposalId];
        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;
        if (queuedProposals[proposalId]) return ProposalState.Queued;
        if (block.timestamp < p.startTime) return ProposalState.Pending;
        if (block.timestamp <= p.endTime) return ProposalState.Active;

        uint256 quorum = (governanceToken.totalSupply() * quorumPercentage) / 100;
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;

        if (totalVotes >= quorum && p.forVotes > p.againstVotes) return ProposalState.Succeeded;
        return ProposalState.Defeated;
    }

    function getVotingPower(address account) public view returns (uint256) {
        return governanceToken.balanceOf(account) + delegatedVotes[account];
    }

    function getProposalVotes(uint256 proposalId) external view returns (uint256, uint256, uint256) {
        Proposal storage p = proposals[proposalId];
        return (p.forVotes, p.againstVotes, p.abstainVotes);
    }

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
        require(_percent <= 100, "Invalid %");
        quorumPercentage = _percent;
    }

    function updateGovernanceToken(address _newToken) external onlyOwner {
        require(!tokenLocked, "Token address is locked");
        governanceToken = IERC20(_newToken);
        tokenLocked = true; // irreversible
        emit GovernanceTokenUpdated(_newToken);
    }
}
