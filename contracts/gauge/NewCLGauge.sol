// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/ILiquidityPool.sol";
import "../interfaces/IRewardDistributor.sol";
import "../interfaces/IFeeHandler.sol";
import "../libraries/LiquidityMath.sol";
import "../libraries/ProtocolTime.sol";
import "../libraries/SafeERC20.sol";
import "../libraries/PositionSet.sol";

contract LiquidityGauge is ERC721Holder, ReentrancyGuard {
    using PositionSet for PositionSet.Data;
    using SafeERC20 for IERC20;
    using LiquidityMath for uint256;
    
    // Contract references
    INonfungiblePositionManager public positionManager;
    IRewardDistributor public rewardDistributor;
    ILiquidityPool public liquidityPool;
    address public gaugeCreator;
    
    // Token references
    address public rewardAsset;
    address public feeHandler;
    address public immutable WETH;
    
    // Pool configuration
    address public asset0;
    address public asset1;
    int24 public immutable tickInterval;
    bool public isActivePool;
    
    // Reward tracking
    uint256 public rewardPeriodEnd;
    uint256 public rewardPerSecond;
    mapping(uint256 => uint256) public rewardRatesByPeriod;
    
    // Position management
    mapping(address => PositionSet.Data) private _userPositions;
    mapping(uint256 => uint256) public accumulatedRewards;
    mapping(uint256 => uint256) public rewardSnapshot;
    mapping(uint256 => uint256) public lastRewardUpdate;
    
    // Fee tracking
    uint256 public collectedFees0;
    uint256 public collectedFees1;
    
    // Events (renamed from original)
    event LiquidityStaked(address indexed provider, uint256 indexed tokenId, uint128 amount);
    event LiquidityWithdrawn(address indexed provider, uint256 indexed tokenId, uint128 amount);
    event RewardsClaimed(address indexed recipient, uint256 amount);
    case FeesCollected(address indexed collector, uint256 amount0, uint256 amount1);
    case RewardRateUpdated(uint256 newRate, uint256 totalAmount);
    
    constructor() {
        gaugeCreator = msg.sender;
        WETH = INonfungiblePositionManager(positionManager).WETH9();
    }
    
    function setup(
        address poolAddress,
        address feeCollector,
        address rewardsToken,
        address distributor,
        address nftManager,
        address tokenA,
        address tokenB,
        int24 tickspacing,
        bool isPool
    ) external {
        require(address(liquidityPool) == address(0), "Already initialized");
        gaugeCreator = msg.sender;
        
        positionManager = INonfungiblePositionManager(nftManager);
        rewardDistributor = IRewardDistributor(distributor);
        liquidityPool = ILiquidityPool(poolAddress);
        rewardAsset = rewardsToken;
        feeHandler = feeCollector;
        
        asset0 = tokenA;
        asset1 = tokenB;
        tickInterval = tickspacing;
        isActivePool = isPool;
    }
    
    receive() external payable {
        require(msg.sender == address(positionManager), "Only position manager");
    }
    
    // Core staking functions
    
    function stakePosition(uint256 tokenId) external nonReentrant {
        require(positionManager.ownerOf(tokenId) == msg.sender, "Not owner");
        require(rewardDistributor.isGaugeActive(address(this)), "Inactive gauge");
        
        PositionData memory position = _validatePosition(tokenId);
        _collectPositionFees(tokenId);
        
        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        _userPositions[msg.sender].add(tokenId);
        
        _updatePositionRewards(tokenId, position.tickLower, position.tickUpper);
        liquidityPool.addStakedLiquidity(
            int128(position.liquidity), 
            position.tickLower, 
            position.tickUpper, 
            true
        );
        
        emit LiquidityStaked(msg.sender, tokenId, position.liquidity);
    }
    
    function unstakePosition(uint256 tokenId) external nonReentrant {
        require(_userPositions[msg.sender].contains(tokenId), "Not staked");
        
        PositionData memory position = positionManager.positions(tokenId);
        _collectPositionFees(tokenId);
        _processRewards(tokenId, position.tickLower, position.tickUpper, msg.sender);
        
        if (position.liquidity > 0) {
            liquidityPool.removeStakedLiquidity(
                -int128(position.liquidity),
                position.tickLower,
                position.tickUpper,
                true
            );
        }
        
        _userPositions[msg.sender].remove(tokenId);
        positionManager.safeTransferFrom(address(this), msg.sender, tokenId);
        
        emit LiquidityWithdrawn(msg.sender, tokenId, position.liquidity);
    }
    
    // Reward functions
    
    function claimRewards(uint256 tokenId) external nonReentrant {
        require(_userPositions[msg.sender].contains(tokenId), "Not staked");
        PositionData memory position = positionManager.positions(tokenId);
        _processRewards(tokenId, position.tickLower, position.tickUpper, msg.sender);
    }
    
    function claimAllRewards() external nonReentrant {
        require(msg.sender == address(rewardDistributor)), "Unauthorized");
        
        uint256[] memory tokenIds = _userPositions[msg.sender].allTokens();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            PositionData memory position = positionManager.positions(tokenIds[i]);
            _processRewards(tokenIds[i], position.tickLower, position.tickUpper, msg.sender);
        }
    }
    
    function _processRewards(uint256 tokenId, int24 tickLower, int24 tickUpper, address recipient) internal {
        _updatePositionRewards(tokenId, tickLower, tickUpper);
        
        uint256 pending = accumulatedRewards[tokenId];
        if (pending > 0) {
            accumulatedRewards[tokenId] = 0;
            IERC20(rewardAsset).safeTransfer(recipient, pending);
            emit RewardsClaimed(recipient, pending);
        }
    }
    
    function _updatePositionRewards(uint256 tokenId, int24 tickLower, int24 tickUpper) internal {
        if (lastRewardUpdate[tokenId] == block.timestamp) return;
        
        liquidityPool.updateGlobalRewards();
        lastRewardUpdate[tokenId] = block.timestamp;
        
        uint256 earned = _calculateEarnedRewards(tokenId);
        accumulatedRewards[tokenId] += earned;
        rewardSnapshot[tokenId] = liquidityPool.getRewardsInRange(
            tickLower, 
            tickUpper, 
            0
        );
    }
    
    function _calculateEarnedRewards(uint256 tokenId) internal view returns (uint256) {
        uint256 lastUpdate = liquidityPool.lastRewardUpdate();
        uint256 timeElapsed = block.timestamp - lastUpdate;
        
        if (timeElapsed == 0 || liquidityPool.totalStaked() == 0) {
            return 0;
        }
        
        uint256 rewardAvailable = rewardPerSecond * timeElapsed;
        uint256 actualReward = rewardAvailable > liquidityPool.rewardBalance() 
            ? liquidityPool.rewardBalance() 
            : rewardAvailable;
        
        uint256 rewardPerUnit = (actualReward * 1e36) / liquidityPool.totalStaked();
        uint256 totalRewardPerUnit = liquidityPool.globalRewardPerUnit() + rewardPerUnit;
        
        PositionData memory position = positionManager.positions(tokenId);
        uint256 rewardInRange = liquidityPool.getRewardsInRange(
            position.tickLower,
            position.tickUpper,
            totalRewardPerUnit
        );
        
        uint256 rewardDelta = rewardInRange - rewardSnapshot[tokenId];
        return (rewardDelta * position.liquidity) / 1e36;
    }
    
    // Reward distribution
    
    function addRewards(uint256 amount) external nonReentrant {
        require(msg.sender == address(rewardDistributor), "Unauthorized");
        require(amount > 0, "Zero amount");
        
        _collectPoolFees();
        _distributeRewards(msg.sender, amount);
    }
    
    function addRewardsWithoutFeeClaim(uint256 amount) external nonReentrant {
        require(msg.sender == gaugeCreator, "Unauthorized");
        require(amount > 0, "Zero amount");
        _distributeRewards(msg.sender, amount);
    }
    
    function _distributeRewards(address sender, uint256 amount) internal {
        uint256 currentTime = block.timestamp;
        uint256 periodStart = ProtocolTime.currentEpochStart(currentTime);
        uint256 periodEnd = ProtocolTime.nextEpochStart(currentTime);
        uint256 duration = periodEnd - currentTime;
        
        IERC20(rewardAsset).safeTransferFrom(sender, address(this), amount);
        amount += liquidityPool.carryOverRewards();
        
        uint256 newRate;
        if (currentTime >= rewardPeriodEnd) {
            newRate = amount / duration;
        } else {
            uint256 remaining = (rewardPeriodEnd - currentTime) * rewardPerSecond;
            newRate = (amount + remaining) / duration;
        }
        
        require(newRate > 0, "Invalid rate");
        uint256 balance = IERC20(rewardAsset).balanceOf(address(this));
        require(newRate <= balance / duration, "Insufficient balance");
        
        rewardPerSecond = newRate;
        rewardPeriodEnd = periodEnd;
        rewardRatesByPeriod[periodStart] = newRate;
        
        liquidityPool.updateRewardParameters(newRate, amount + remaining, periodEnd);
        emit RewardRateUpdated(newRate, amount);
    }
    
    // Fee collection
    
    function _collectPoolFees() internal {
        if (!isActivePool) return;
        
        (uint256 amount0, uint256 amount1) = liquidityPool.harvestFees();
        if (amount0 > 0 || amount1 > 0) {
            collectedFees0 += amount0;
            collectedFees1 += amount1;
            
            if (collectedFees0 > ProtocolTime.WEEK) {
                uint256 fees0 = collectedFees0;
                collectedFees0 = 0;
                IERC20(asset0).safeApprove(feeHandler, fees0);
                IFeeHandler(feeHandler).distributeFees(asset0, fees0);
            }
            
            if (collectedFees1 > ProtocolTime.WEEK) {
                uint256 fees1 = collectedFees1;
                collectedFees1 = 0;
                IERC20(asset1).safeApprove(feeHandler, fees1);
                IFeeHandler(feeHandler).distributeFees(asset1, fees1);
            }
            
            emit FeesCollected(msg.sender, amount0, amount1);
        }
    }
    
    function _collectPositionFees(uint256 tokenId) internal {
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }
    
    // View functions
    
    function stakedPositions(address user) external view returns (uint256[] memory) {
        return _userPositions[user].allTokens();
    }
    
    function hasStake(address user, uint256 tokenId) external view returns (bool) {
        return _userPositions[user].contains(tokenId);
    }
    
    function stakeCount(address user) external view returns (uint256) {
        return _userPositions[user].length();
    }
    
    function pendingRewards(uint256 tokenId) external view returns (uint256) {
        require(_userPositions[msg.sender].contains(tokenId), "Not staked");
        return _calculateEarnedRewards(tokenId);
    }
    
    function remainingRewards() external view returns (uint256) {
        if (block.timestamp >= rewardPeriodEnd) return 0;
        return (rewardPeriodEnd - block.timestamp) * rewardPerSecond;
    }
    
    // Helper functions
    
    function _validatePosition(uint256 tokenId) internal view returns (PositionData memory) {
        PositionData memory position = positionManager.positions(tokenId);
        require(asset0 == position.token0 && asset1 == position.token1, "Token mismatch");
        require(tickInterval == position.tickSpacing, "Tick mismatch");
        return position;
    }
    
    struct PositionData {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int24 tickSpacing;
    }
}

library PositionSet {
    struct Data {
        uint256[] tokens;
        mapping(uint256 => uint256) indexes;
    }
    
    function add(Data storage self, uint256 tokenId) internal {
        require(!contains(self, tokenId), "Already exists");
        self.tokens.push(tokenId);
        self.indexes[tokenId] = self.tokens.length;
    }
    
    function remove(Data storage self, uint256 tokenId) internal {
        require(contains(self, tokenId), "Not found");
        uint256 index = self.indexes[tokenId] - 1;
        uint256 lastIndex = self.tokens.length - 1;
        
        if (index != lastIndex) {
            uint256 lastToken = self.tokens[lastIndex];
            self.tokens[index] = lastToken;
            self.indexes[lastToken] = index + 1;
        }
        
        self.tokens.pop();
        delete self.indexes[tokenId];
    }
    
    function contains(Data storage self, uint256 tokenId) internal view returns (bool) {
        return self.indexes[tokenId] != 0;
    }
    
    function length(Data storage self) internal view returns (uint256) {
        return self.tokens.length;
    }
    
    function at(Data storage self, uint256 index) internal view returns (uint256) {
        require(index < self.tokens.length, "Out of bounds");
        return self.tokens[index];
    }
    
    function allTokens(Data storage self) internal view returns (uint256[] memory) {
        return self.tokens;
    }
}