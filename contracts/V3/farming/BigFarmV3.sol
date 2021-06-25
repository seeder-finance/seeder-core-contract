// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";
import "../../V1/tokens/Leaf.sol";
import "../utils/SafeMathV3.sol";
import "../../V1/farming/Granary.sol";


contract BigFarmV3 is OwnableUpgradeable {
    using SafeMathV3 for uint256;
    using SafeERC20 for IERC20;

    event Deposit(address indexed initiator, address indexed beneficiary, uint256 indexed farmId, uint256 amount);
    event Withdraw(address indexed initiator, address indexed beneficiary, uint256 indexed farmId, uint256 amount);
    event Harvest(address indexed initiator, address indexed beneficiary, uint256 indexed farmId, uint256 amount);
    event UpdateFarm(uint256 indexed pid, uint256 lastUpdateBlock, uint256 lpSupply, uint256 rewardPerStakeWithBuffer);

    struct Farmer {
        uint256 stakeAmount;
        uint256 rewardPerStakeWithBuffer;
        address initiator;
    }

    struct Farm {
        IERC20 stakeToken;
        uint256 allocationPoint;
        uint256 lastUpdateBlock;
        uint256 rewardPerStakeWithBuffer;
    }

    uint256 constant CALCULATE_PRECISION = 1E18;
    uint256 constant REWARD_BLOCK_WIDE = 403200; // 2 weeks

    Leaf private _leaf;
    uint256[] private _rewardPlan;
    uint256 private _startBlock;
    address public devAddress;
    
    Farm[] private _farms;
    mapping (uint256 => mapping (address => Farmer)) private _farmers;
    uint256 public totalAllocationPoint;

    Granary public granary;
    uint256 public lockInPercent;

    function initialize(uint256 startBlock, Leaf rewardToken, uint256[] calldata rewardPlan, address devAddr, Granary initialGranary, uint256 percentLock) external initializer {
        require(rewardPlan.length <= 100, "BigFarm: Cannot add reward more than 100 blocks");
        require(percentLock <= 100, "BigFarm: Cannot lock more than 100 percent");

        __Ownable_init();
        
        devAddress = devAddr;
        _leaf = rewardToken;
        _startBlock = (startBlock > block.number) ? startBlock : block.number; 
        totalAllocationPoint = 0;

        granary = initialGranary;
        lockInPercent = percentLock;

        _addRewardPlan(rewardPlan);
    }

    function getRewardToken() external view returns (address) {
        return address(_leaf);
    }

    function getAllFarms() external view returns (Farm[] memory) {
        return _farms;
    }

    function getFarm(uint256 farmId) external view returns (Farm memory) {
        require(_farms.length > 0 && _farms.length.sub(1) >= farmId, "BigFarm: Farm ID out of length");

        return _farms[farmId];
    }

    function getRewardPlan() external view returns (uint256[] memory rewardPlan, uint256 currentSlot, uint256 startBlock, uint256 currentBlock) {
        uint256 _currentSlot = _getCurrentRewardSlot();

        return (_rewardPlan, _currentSlot, _startBlock, block.number);
    }

    function getFarmer(uint256 farmId, address beneficiary) external view returns (Farmer memory farmer, uint256 totalPendingReward, uint256 currentBlock) {
        require(_farms.length > 0 && _farms.length.sub(1) >= farmId, "BigFarm: Farm ID out of length");

        Farmer storage _farmer = _farmers[farmId][beneficiary];
        if (_farmer.initiator == address(0)) {
            return (_farmer, 0, block.number);
        }

        Farm memory _farm = _farms[farmId];
        uint256 rewardPerShareWithBuffer = _farm.rewardPerStakeWithBuffer;
        if (block.number > _farm.lastUpdateBlock) {
            uint256 additionRewardPerStakeWithBuffer;
            uint256 totalRewardWithBuffer;
            uint256 totalStake;
            (additionRewardPerStakeWithBuffer, totalRewardWithBuffer, totalStake) = _calculateReward(_farm);

            rewardPerShareWithBuffer = rewardPerShareWithBuffer.add(additionRewardPerStakeWithBuffer);
        }

        uint256 pendingRewardPerShareWithBuffer = rewardPerShareWithBuffer.sub(_farmer.rewardPerStakeWithBuffer);
        uint256 _totalPendingReward = pendingRewardPerShareWithBuffer.mul(_farmer.stakeAmount).div(CALCULATE_PRECISION);

        return (_farmer, _totalPendingReward, block.number);
    }

    function deposit(uint256 farmId, address beneficiary, uint256 amount) external {
        require(_farms.length > 0 && _farms.length.sub(1) >= farmId, "BigFarm: Farm ID out of length");
        require(amount >= 1E15, "BigFarm: The deposit amount must be at least 1E15");

        address inititator = msg.sender;
        require(beneficiary != address(0), "BigFarm: Not allow zero address as beneficiary");

        Farmer storage farmer = _farmers[farmId][beneficiary];
        if (farmer.initiator == address(0)) {
            farmer.initiator = inititator;
            _updateFarm(farmId);
        } else {
            require(farmer.initiator == inititator, "BigFarm: Only initiator can do deposit");
            _harvest(farmId, beneficiary);
        }

        Farm memory farm = _farms[farmId];
        farm.stakeToken.safeTransferFrom(inititator, address(this), amount);

        farmer.stakeAmount = farmer.stakeAmount.add(amount);
        farmer.rewardPerStakeWithBuffer = farm.rewardPerStakeWithBuffer;
        emit Deposit(msg.sender, beneficiary, farmId, amount);
    }

    function harvest(uint256 farmId, address beneficiary) external {
        require(_farms.length > 0 && _farms.length.sub(1) >= farmId, "BigFarm: Farm ID out of length");

        Farmer memory farmer = _farmers[farmId][beneficiary];
        require(farmer.initiator == msg.sender, "BigFarm: Only initiator can harvest");
        
        _harvest(farmId, beneficiary);
    }

    function withdraw(uint256 farmId, address beneficiary, uint256 amount) external {
        address requester = msg.sender;

        Farmer storage farmer = _farmers[farmId][beneficiary];
        require(requester == farmer.initiator || requester == beneficiary, "BigFarm: Only initiator or beneficiary can withdraw farming");

        _harvest(farmId, beneficiary);

        farmer.stakeAmount = farmer.stakeAmount.sub(amount);
        _farms[farmId].stakeToken.safeTransfer(farmer.initiator, amount);

        if (farmer.stakeAmount == 0) {
            farmer.initiator = address(0);
        }
        emit Withdraw(msg.sender, beneficiary, farmId, amount);
    }

    function updateAllFarms() public {
        for (uint256 farmId = 0; farmId < _farms.length; farmId++) {
            _updateFarm(farmId);
        }
    }

    function updateFarm(uint256 farmId) external {
        require(_farms.length > 0 && _farms.length.sub(1) >= farmId, "BigFarm: Farm ID out of length");
        _updateFarm(farmId);
    }

    //===============================
    // Owner method
    //===============================
  
    function addFarm(address stakeToken, uint256 allocationPoint, uint256 startBlock) external onlyOwner {
        require(!_doesFarmExist(stakeToken), "BigFarm: This Farm already exist");
        require(stakeToken != address(_leaf), "BigFarm: Not allow using reward token as stake token"); 
        
        updateAllFarms();
        uint256 lastUpdateBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocationPoint = totalAllocationPoint.add(allocationPoint);

        Farm memory farm = Farm({
            stakeToken: IERC20(stakeToken),
            allocationPoint: allocationPoint,
            lastUpdateBlock: lastUpdateBlock,
            rewardPerStakeWithBuffer: 0
        });

        _farms.push(farm);        
    }

    function setFarm(uint256 farmId, uint256 allocationPoint) external onlyOwner {
        require(_farms.length > 0 && _farms.length.sub(1) >= farmId, "BigFarm: Farm ID out of length");

        updateAllFarms();
        totalAllocationPoint = totalAllocationPoint.sub(_farms[farmId].allocationPoint).add(allocationPoint);
        _farms[farmId].allocationPoint = allocationPoint;

    }

    function setDevAddress(address devAddr) external onlyOwner {
        devAddress = devAddr;
    }

    function setPercentLock(uint256 percentLock) external onlyOwner {
        require(percentLock <= 100, "BigFarm: percent lock cannot be more than 100");

        lockInPercent = percentLock;
    }

    //===============================
    // Private method
    //===============================

    function _updateFarm(uint256 farmId) private returns (Farm memory) {
        Farm memory farm = _farms[farmId];

        if (block.number > farm.lastUpdateBlock) {
            uint256 additionRewardPerStakeWithBuffer;
            uint256 totalRewardWithBuffer;
            uint256 totalStake;
            (additionRewardPerStakeWithBuffer, totalRewardWithBuffer, totalStake) = _calculateReward(farm);

            if (totalRewardWithBuffer > 0) {
                uint256 devPortionWithBuffer = totalRewardWithBuffer.mul(3).div(20);
                _leaf.mint(devAddress, devPortionWithBuffer.div(CALCULATE_PRECISION));
                _leaf.mint(address(this), totalRewardWithBuffer.div(CALCULATE_PRECISION));
            }

            farm.rewardPerStakeWithBuffer = farm.rewardPerStakeWithBuffer.add(additionRewardPerStakeWithBuffer);
            farm.lastUpdateBlock = block.number;
            _farms[farmId] = farm;
            emit UpdateFarm(farmId, farm.lastUpdateBlock, totalStake, farm.rewardPerStakeWithBuffer);
        }

        return farm;
    }

    function _calculateReward(Farm memory farm) private view returns (uint256 additionRewardPerStakeWithBuffer, uint256 totalRewardWithBuffer, uint256 stakeTokenSupply) {
        additionRewardPerStakeWithBuffer = 0;
        totalRewardWithBuffer = 0;

        if (farm.allocationPoint > 0) {
            stakeTokenSupply = farm.stakeToken.balanceOf(address(this));

            if (stakeTokenSupply > 0) {
                    uint256 numberOfBlocks = block.number.sub(farm.lastUpdateBlock);
                    uint256 rewardPerBlockPerAllocation = _getRewardPerBlock().mul(farm.allocationPoint).div(totalAllocationPoint);
                    totalRewardWithBuffer = numberOfBlocks.mul(rewardPerBlockPerAllocation).mul(CALCULATE_PRECISION);
                    additionRewardPerStakeWithBuffer = totalRewardWithBuffer.div(stakeTokenSupply);
            }
        }
    }

    function _harvest(uint256 farmId, address beneficiary) private {
        _updateFarm(farmId);

        Farm memory farm = _farms[farmId];
        Farmer storage farmer = _farmers[farmId][beneficiary];

        uint256 rewardPerShareWithBuffer = farm.rewardPerStakeWithBuffer.sub(farmer.rewardPerStakeWithBuffer);
        uint256 reward = farmer.stakeAmount.mul(rewardPerShareWithBuffer).div(CALCULATE_PRECISION);

        require(reward <= _leaf.balanceOf(address(this)), "BigFarm: Insufficient reward");

        farmer.rewardPerStakeWithBuffer = farm.rewardPerStakeWithBuffer;

        uint256 lockBalance = reward.mul(lockInPercent).div(100);
        if (lockBalance > 0) {
            _leaf.approve(address(granary), lockBalance);
            granary.keep(beneficiary, lockBalance);
        }

        uint256 releaseBalance = reward.sub(lockBalance);
        _leaf.transfer(beneficiary, releaseBalance);

        emit Harvest(msg.sender, beneficiary, farmId, releaseBalance);
    }

    function _addRewardPlan(uint256[] memory rewardPerBlock) private {
        if (_rewardPlan.length == 0 && block.number > _startBlock) {
            _startBlock = block.number;
        }

        for (uint256 index = 0; index < rewardPerBlock.length; index++) {
            _rewardPlan.push(rewardPerBlock[index]);
        }
    }

    function _getRewardPerBlock() private view returns (uint256) {
        uint256 rewardPerBlock = 0;

        if (_startBlock < block.number) {
            uint256 currentRewardSlot = _getCurrentRewardSlot();
            if (currentRewardSlot < _rewardPlan.length) {
                rewardPerBlock = _rewardPlan[currentRewardSlot];
            }
        }

        return rewardPerBlock;
    }

    function _getCurrentRewardSlot() private view returns (uint256) {
        uint currentBlock = block.number;
        if (currentBlock > _startBlock) {
            uint256 numberOfBlock = currentBlock.sub(_startBlock);

            return numberOfBlock.div(REWARD_BLOCK_WIDE);
        }
        
        return 0;
    }

    function _doesFarmExist(address stakeToken) private view returns (bool) {
        for (uint256 index = 0; index < _farms.length; index++) {
            if (address(_farms[index].stakeToken) == stakeToken) {
                return true;
            }
        }

        return false;
    }
}