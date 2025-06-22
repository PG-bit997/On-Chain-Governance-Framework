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

    Counters.Counter private proposalIdCounter;

    uint256 public votingDelay = 1 days;
    uint256 public votingPeriod = 3 days;
    uint256 public proposalThreshold;
    uint256 public quorumPercentage = 10;
    uint256 public executionDelay = 1 days;
    bool public paused;

    enum ProposalState { Pending, Active, Defeated, Succeeded, Queued, Executed, Cancelled }

    struct Vote {
        bool hasVoted;
        uint8 support;
        uint256 votes;
    }

    struct Proposal {
        uint256 id;
        string title;
        address proposer;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 executionTime;
        bool executed;
        bool cancelled;
        address target;
        bytes callData;

        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 snapshotTotalSupply;

        mapping(address => Vote) votesByVoter;
        mapping(address => uint256) snapshotVotingPower;
    }

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => bool) public queuedProposals;
    mapping(address => address) public delegates;
    mapping(address => uint256) public delegatedVotes;

    address[] public allDelegates;

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

        uint256 id = proposalIdCounter.current();
        proposalIdCounter.increment();

        Proposal storage p = proposals[id];
        p.id = id;
        p.title = title;
        p.proposer = msg.sender;
        p.description = description;
        p.startTime = block.timestamp + votingDelay;
        p.endTime = p.startTime + votingPeriod;
        p.target = target;
        p.callData = callData;
        p.snapshotTotalSupply = governanceToken.totalSupply();
        p.snapshotVotingPower[msg.sender] = getVotingPower(msg.sender);

        emit ProposalCreated(id, title, msg.sender, p.startTime, p.endTime);
        return id;
    }

    function castVote(uint256 proposalId, uint8 support) external nonReentrant whenNotPaused {
        require(support <= 2, "Invalid vote option");
        Proposal storage p = proposals[proposalId];
        require(getProposalState(proposalId) == ProposalState.Active, "Voting not active");
        require(!p.votesByVoter[msg.sender].hasVoted, "Already voted");

        uint256 votes = getVotingPower(msg.sender);
        require(votes > 0, "No voting power");

        p.votesByVoter[msg.sender] = Vote(true, support, votes);
        if (support == 0) p.againstVotes += votes;
        else if (support == 1) p.forVotes += votes;
        else p.abstainVotes += votes;

        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    function queueProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(!queuedProposals[proposalId], "Already queued");
        require(!p.executed && !p.cancelled, "Cannot queue");
        require(getProposalState(proposalId) == ProposalState.Succeeded, "Not passed");

        p.executionTime = block.timestamp + executionDelay;
        queuedProposals[proposalId] = true;

        emit ProposalQueued(proposalId);
    }

    function executeProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(queuedProposals[proposalId], "Not queued");
        require(block.timestamp >= p.executionTime, "Too early");
        require(!p.executed, "Already executed");

        p.executed = true;
        queuedProposals[proposalId] = false;

        if (p.target != address(0) && p.callData.length > 0) {
            (bool success, ) = p.target.call(p.callData);
            require(success, "Execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    function cancelProposal(uint256 proposalId) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(msg.sender == p.proposer || msg.sender == owner(), "Unauthorized");
        require(!p.executed && !p.cancelled, "Cannot cancel");

        p.cancelled = true;
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

        if (delegatedVotes[to] == amount) {
            allDelegates.push(to); // track first-time delegates
        }

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

        uint256 quorum = (p.snapshotTotalSupply * quorumPercentage) / 100;
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

    function getProposal(uint256 proposalId) external view returns (
        uint256, string memory, address, string memory, uint256, uint256, uint256, bool, bool, address
    ) {
        Proposal storage p = proposals[proposalId];
        return (
            p.id, p.title, p.proposer, p.description,
            p.startTime, p.endTime, p.executionTime,
            p.executed, p.cancelled, p.target
        );
    }

    function getDelegate(address account) external view returns (address) {
        return delegates[account];
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
        require(_percent <= 100, "Invalid");
        quorumPercentage = _percent;
    }

    function updateGovernanceToken(address _newToken) external onlyOwner {
        require(!tokenLocked, "Already set");
        governanceToken = IERC20(_newToken);
        tokenLocked = true;
        emit GovernanceTokenUpdated(_newToken);
    }

    // ✅ New Additions Below

    function hasVoted(address voter, uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].votesByVoter[voter].hasVoted;
    }

    function getVoteReceipt(uint256 proposalId, address voter) external view returns (uint8 support, uint256 votes) {
        Vote memory v = proposals[proposalId].votesByVoter[voter];
        return (v.support, v.votes);
    }

    function getProposalVoterPower(uint256 proposalId, address voter) external view returns (uint256) {
        return proposals[proposalId].snapshotVotingPower[voter];
    }

    function getAllDelegates() external view returns (address[] memory) {
        return allDelegates;
    }

    function isProposalPassed(uint256 proposalId) external view returns (bool) {
        return getProposalState(proposalId) == ProposalState.Succeeded;
    }

    function getActiveProposals() external view returns (uint256[] memory) {
        uint256 count = proposalIdCounter.current();
        uint256 activeCount;
        for (uint256 i = 0; i < count; i++) {
            if (getProposalState(i) == ProposalState.Active) activeCount++;
        }

        uint256[] memory result = new uint256[](activeCount);
        uint256 idx;
        for (uint256 i = 0; i < count; i++) {
            if (getProposalState(i) == ProposalState.Active) {
                result[idx++] = i;
            }
        }
        return result;
    }

    function withdrawTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(msg.sender, amount);
    }
}
