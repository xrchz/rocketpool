pragma solidity 0.7.6;
pragma abicoder v2;

// SPDX-License-Identifier: GPL-3.0-only

import "../RocketBase.sol";
import "../../interface/token/RocketTokenRPLInterface.sol";
import "../../interface/rewards/RocketRewardsPoolInterface.sol";
import "../../interface/dao/protocol/settings/RocketDAOProtocolSettingsNetworkInterface.sol";
import "../../interface/dao/node/RocketDAONodeTrustedInterface.sol";
import "../../interface/network/RocketNetworkBalancesInterface.sol";
import "../../interface/RocketVaultInterface.sol";
import "../../interface/dao/protocol/settings/RocketDAOProtocolSettingsRewardsInterface.sol";
import "../../interface/rewards/RocketRewardsRelayInterface.sol";
import "../../interface/rewards/RocketSmoothingPoolInterface.sol";
import "../../types/RewardSubmission.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


// Holds RPL generated by the network for claiming from stakers (node operators etc)

contract RocketRewardsPool is RocketBase, RocketRewardsPoolInterface {

    // Libs
    using SafeMath for uint256;

    // Events
    event RewardSnapshotSubmitted(address indexed from, uint256 indexed rewardIndex, RewardSubmission submission, uint256 time);
    event RewardSnapshot(uint256 indexed rewardIndex, RewardSubmission submission, uint256 intervalStartTime, uint256 intervalEndTime, uint256 time);

    // Construct
    constructor(RocketStorageInterface _rocketStorageAddress) RocketBase(_rocketStorageAddress) {
        // Version
        version = 2;
    }

    function getRewardIndex() override public view returns(uint256) {
        return getUint(keccak256("rewards.snapshot.index"));
    }
    function incrementRewardIndex() private {
        addUint(keccak256("rewards.snapshot.index"), 1);
    }

    /**
    * Get how much RPL the Rewards Pool contract currently has assigned to it as a whole
    * @return uint256 Returns rpl balance of rocket rewards contract
    */
    function getRPLBalance() override public view returns(uint256) {
        // Get the vault contract instance
        RocketVaultInterface rocketVault = RocketVaultInterface(getContractAddress("rocketVault"));
        // Check contract RPL balance
        return rocketVault.balanceOfToken("rocketRewardsPool", IERC20(getContractAddress("rocketTokenRPL")));
    }

    // Returns the total amount of RPL that needs to be distributed to claimers at the current block
    function getPendingRPLRewards() override public view returns (uint256) {
        RocketTokenRPLInterface rplContract = RocketTokenRPLInterface(getContractAddress("rocketTokenRPL"));
        uint256 pendingInflation = rplContract.inflationCalculate();
        // Any inflation that has accrued so far plus any amount that would be minted if we called it now
        return getRPLBalance().add(pendingInflation);
    }

    // Returns the total amount of ETH in the smoothing pool ready to be distributed
    function getPendingETHRewards() override public view returns (uint256) {
        address rocketSmoothingPoolAddress = getContractAddress("rocketSmoothingPool");
        return rocketSmoothingPoolAddress.balance;
    }

    /**
    * Get the last set interval start time
    * @return uint256 Last set start timestamp for a claim interval
    */
    function getClaimIntervalTimeStart() override public view returns(uint256) {
        return getUint(keccak256("rewards.pool.claim.interval.time.start"));
    }

    /**
    * Get how many seconds in a claim interval
    * @return uint256 Number of seconds in a claim interval
    */
    function getClaimIntervalTime() override public view returns(uint256) {
        // Get from the DAO settings
        RocketDAOProtocolSettingsRewardsInterface daoSettingsRewards = RocketDAOProtocolSettingsRewardsInterface(getContractAddress("rocketDAOProtocolSettingsRewards"));
        return daoSettingsRewards.getRewardsClaimIntervalTime();
    }

    /**
    * Compute intervals since last claim period
    * @return uint256 Time intervals since last update
    */
    function getClaimIntervalsPassed() override public view returns(uint256) {
        return block.timestamp.sub(getClaimIntervalTimeStart()).div(getClaimIntervalTime());
    }

    /**
    * Get the percentage this contract can claim in this interval
    * @return uint256 Rewards percentage this contract can claim in this interval
    */
    function getClaimingContractPerc(string memory _claimingContract) override public view returns (uint256) {
        // Load contract
        RocketDAOProtocolSettingsRewardsInterface daoSettingsRewards = RocketDAOProtocolSettingsRewardsInterface(getContractAddress("rocketDAOProtocolSettingsRewards"));
        // Get the % amount allocated to this claim contract
        return daoSettingsRewards.getRewardsClaimerPerc(_claimingContract);
    }

    /**
    * Get an array of percentages that the given contracts can claim in this interval
    * @return uint256[] Array of percentages in the order of the supplied contract names
    */
    function getClaimingContractsPerc(string[] memory _claimingContracts) override external view returns (uint256[] memory) {
        // Load contract
        RocketDAOProtocolSettingsRewardsInterface daoSettingsRewards = RocketDAOProtocolSettingsRewardsInterface(getContractAddress("rocketDAOProtocolSettingsRewards"));
        // Get the % amount allocated to this claim contract
        uint256[] memory percentages = new uint256[](_claimingContracts.length);
        for (uint256 i = 0; i < _claimingContracts.length; i++){
            percentages[i] = daoSettingsRewards.getRewardsClaimerPerc(_claimingContracts[i]);
        }
        return percentages;
    }

    // Returns whether a trusted node has submitted for a given reward index
    function getTrustedNodeSubmitted(address _trustedNodeAddress, uint256 _rewardIndex) override external view returns (bool) {
        return getBool(keccak256(abi.encode("rewards.snapshot.submitted.node", _trustedNodeAddress, _rewardIndex)));
    }

    // Returns the number of trusted nodes who have agreed to the given submission
    function getSubmissionCount(RewardSubmission calldata _submission) override external view returns (uint256) {
        return getUint(keccak256(abi.encode("rewards.snapshot.submitted.count", _submission)));
    }

    // Submit a reward snapshot
    // Only accepts calls from trusted (oracle) nodes
    function submitRewardSnapshot(RewardSubmission calldata _submission) override external onlyLatestContract("rocketRewardsPool", address(this)) onlyTrustedNode(msg.sender) {
        // Get contracts
        RocketDAOProtocolSettingsNetworkInterface rocketDAOProtocolSettingsNetwork = RocketDAOProtocolSettingsNetworkInterface(getContractAddress("rocketDAOProtocolSettingsNetwork"));
        // Check submission is currently enabled
        require(rocketDAOProtocolSettingsNetwork.getSubmitRewardsEnabled(), "Submitting rewards is currently disabled");
        // Validate inputs
        require(_submission.rewardIndex == getRewardIndex(), "Can only submit snapshot for next period");
        require(_submission.intervalsPassed > 0, "Invalid number of intervals passed");
        require(_submission.nodeRPL.length == _submission.trustedNodeRPL.length && _submission.trustedNodeRPL.length == _submission.nodeETH.length, "Invalid array length");
        // Calculate RPL reward total and validate
        { // Scope to prevent stake too deep
            uint256 totalRewardsRPL = _submission.treasuryRPL;
            for (uint256 i = 0; i < _submission.nodeRPL.length; i++){
                totalRewardsRPL = totalRewardsRPL.add(_submission.nodeRPL[i]);
            }
            for (uint256 i = 0; i < _submission.trustedNodeRPL.length; i++){
                totalRewardsRPL = totalRewardsRPL.add(_submission.trustedNodeRPL[i]);
            }
            require(totalRewardsRPL <= getPendingRPLRewards(), "Invalid RPL rewards");
        }
        // Calculate ETH reward total and validate
        { // Scope to prevent stack too deep
            uint256 totalRewardsETH = 0;
            for (uint256 i = 0; i < _submission.nodeETH.length; i++){
                totalRewardsETH = totalRewardsETH.add(_submission.nodeETH[i]);
            }
            require(totalRewardsETH <= getPendingETHRewards(), "Invalid ETH rewards");
        }
        // Store and increment vote
        uint256 submissionCount;
        { // Scope to prevent stack too deep
            // Check & update node submission status
            bytes32 nodeSubmissionKey = keccak256(abi.encode("rewards.snapshot.submitted.node.key", msg.sender, _submission));
            require(!getBool(nodeSubmissionKey), "Duplicate submission from node");
            setBool(nodeSubmissionKey, true);
            setBool(keccak256(abi.encode("rewards.snapshot.submitted.node", msg.sender, _submission.rewardIndex)), true);
        }
        { // Scope to prevent stack too deep
            // Increment submission count
            bytes32 submissionCountKey = keccak256(abi.encode("rewards.snapshot.submitted.count", _submission));
            submissionCount = getUint(submissionCountKey).add(1);
            setUint(submissionCountKey, submissionCount);
        }
        // Emit snapshot submitted event
        emit RewardSnapshotSubmitted(msg.sender, _submission.rewardIndex, _submission, block.timestamp);
        // If consensus is reached, execute the snapshot
        RocketDAONodeTrustedInterface rocketDAONodeTrusted = RocketDAONodeTrustedInterface(getContractAddress("rocketDAONodeTrusted"));
        if (calcBase.mul(submissionCount).div(rocketDAONodeTrusted.getMemberCount()) >= rocketDAOProtocolSettingsNetwork.getNodeConsensusThreshold()) {
            _executeRewardSnapshot(_submission);
        }
    }

    // Executes reward snapshot if consensus threshold is reached
    function executeRewardSnapshot(RewardSubmission calldata _submission) override external onlyLatestContract("rocketRewardsPool", address(this)) {
        // Validate reward index of submission
        require(_submission.rewardIndex == getRewardIndex(), "Can only execute snapshot for next period");
        // Get submission count
        bytes32 submissionCountKey = keccak256(abi.encode("rewards.snapshot.submitted.count", _submission));
        uint256 submissionCount = getUint(submissionCountKey);
        // Confirm consensus and execute
        RocketDAONodeTrustedInterface rocketDAONodeTrusted = RocketDAONodeTrustedInterface(getContractAddress("rocketDAONodeTrusted"));
        RocketDAOProtocolSettingsNetworkInterface rocketDAOProtocolSettingsNetwork = RocketDAOProtocolSettingsNetworkInterface(getContractAddress("rocketDAOProtocolSettingsNetwork"));
        require(calcBase.mul(submissionCount).div(rocketDAONodeTrusted.getMemberCount()) >= rocketDAOProtocolSettingsNetwork.getNodeConsensusThreshold(), "Consensus has not been reached");
        _executeRewardSnapshot(_submission);
    }

    // Executes reward snapshot and sends assets to the relays for distribution to reward recipients
    function _executeRewardSnapshot(RewardSubmission calldata _submission) private {
        // Get contract
        RocketTokenRPLInterface rplContract = RocketTokenRPLInterface(getContractAddress("rocketTokenRPL"));
        RocketVaultInterface rocketVault = RocketVaultInterface(getContractAddress("rocketVault"));
        // Execute inflation if required
        rplContract.inflationMintTokens();
        // Increment the reward index and update the claim interval timestamp
        incrementRewardIndex();
        uint256 claimIntervalTimeStart = getClaimIntervalTimeStart();
        uint256 claimIntervalTimeEnd = claimIntervalTimeStart.add(getClaimIntervalTime().mul(_submission.intervalsPassed));
        // Emit reward snapshot event
        emit RewardSnapshot(_submission.rewardIndex, _submission, claimIntervalTimeStart, claimIntervalTimeEnd, block.timestamp);
        setUint(keccak256("rewards.pool.claim.interval.time.start"), claimIntervalTimeEnd);
        // Send out the treasury rewards
        if (_submission.treasuryRPL > 0) {
            rocketVault.transferToken("rocketClaimDAO", rplContract, _submission.treasuryRPL);
        }
        // Loop over each network and distribute rewards
        for (uint i = 0; i < _submission.nodeRPL.length; i++) {
            // Quick out if no rewards for this network
            uint256 rewardsRPL = _submission.nodeRPL[i].add(_submission.trustedNodeRPL[i]);
            uint256 rewardsETH = _submission.nodeETH[i];
            if (rewardsRPL == 0 && rewardsETH == 0) {
                continue;
            }
            // Grab the relay address
            RocketRewardsRelayInterface relay;
            { // Scope to prevent stack too deep
                address networkRelayAddress;
                bytes32 networkRelayKey = keccak256(abi.encodePacked("rewards.relay.address", i));
                networkRelayAddress = getAddress(networkRelayKey);
                // Validate network is valid
                require (networkRelayAddress != address(0), "Snapshot contains rewards for invalid network");
                relay = RocketRewardsRelayInterface(networkRelayAddress);
            }
            // Transfer rewards
            if (rewardsRPL > 0) {
                // RPL rewards are withdrawn from the vault
                rocketVault.withdrawToken(address(relay), rplContract, rewardsRPL);
            }
            if (rewardsETH > 0) {
                // ETH rewards are withdrawn from the smoothing pool
                RocketSmoothingPoolInterface rocketSmoothingPool = RocketSmoothingPoolInterface(getContractAddress("rocketSmoothingPool"));
                rocketSmoothingPool.withdrawEther(address(relay), rewardsETH);
            }
            // Call into relay contract to handle distribution of rewards
            relay.relayRewards(_submission.rewardIndex, _submission.merkleRoot, rewardsRPL, rewardsETH);
        }
    }
}
