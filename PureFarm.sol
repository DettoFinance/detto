// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../comm/WETHelper.sol";
import "../comm/TransferHelper.sol";
import "../tokens/Token.sol";
import "../comm/Errors.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IVault {
    function deposit(address _addr, uint256 _amount) external payable returns (uint256);

    function withdraw(address _addr, uint256 _amount) external returns (uint256);

    function balance() external view returns (uint256);
}

contract PureFarm is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, TokenErrors {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant BONUS_MULTIPLIER = 2;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 assets;
        uint256 allocPoint;
        uint256 amount;
        uint256 withdrawFee;
        uint256 lastRewardTime;
        uint256 acctPerShare;
        IVault vault;
    }

    struct PoolTvl {
        uint256 pid;
        IERC20 assets;
        uint256 tvl;
    }

    uint256 public startBlock;
    uint256 public startTimestamp;
    uint256 public bonusEndTime;

    // Wrapped ETH token address
    address public weth;

    // Token address
    IERC20 public token;

    // Token amount per block created
    uint256 public tokenPerBlock;

    // Total allocation points
    uint256 public totalAllocPoint;

    // Total user revenue
    uint256 public totalUserRevenue;

    // Pool info
    PoolInfo[] public poolInfoList;

    // Each user stake token
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // User list
    address[] public userList;

    // Admin address
    address public devAddr;

    // ETH Transfer helper
    WETHelper public wethHelper;

    // Paused status
    bool private _paused;

    // Events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    receive() external payable {}

    function initialize(
        IERC20 _token,
        address _weth,
        address _devAddr
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        _paused = false;

        token = _token;
        weth = _weth;
        devAddr = _devAddr;

        totalAllocPoint = 0;
        totalUserRevenue = 0;
        tokenPerBlock = 0;

        wethHelper = new WETHelper();
    }

    function setTokenPerBlock(uint256 _newTokenPerBlock) public onlyOwner {
        require(_newTokenPerBlock > 0, "Farm: invalid new token per block");

        tokenPerBlock = _newTokenPerBlock;

        // update the pool
        updateMassPools();
    }

    function setStartTimestamp(uint256 _startTimestamp) public onlyOwner {
        require(startTimestamp == 0, "Farm: already started");
        startTimestamp = _startTimestamp;
    }

    /**
     * Set the bonus end time, after this time, the bonus reduce to 1/2
     */
    function setBonusEndTime(uint256 _bonusEndTime) public onlyOwner {
        require(startTimestamp > 0, "Farm: not start");
        require(_bonusEndTime > startTimestamp, "Farm: end time must greater than start time");

        bonusEndTime = _bonusEndTime;
    }

    function setDevAddr(address _devAddr) public onlyOwner {
        require(_devAddr != address(0), "Farm: invalid dev address");
        devAddr = _devAddr;
    }

    function setWeth(address _weth) public onlyOwner {
        require(_weth != address(0), "Farm: invalid weth address");
        weth = _weth;
    }

    function setToken(IERC20 _token) public onlyOwner {
        require(address(_token) != address(0), "Farm: invalid token address");
        token = _token;
    }

    function setTotalAllocPoint(uint256 _totalAllocPoint) public onlyOwner {
        totalAllocPoint = _totalAllocPoint;
    }

    function getTotalUserRevenue() public view returns (uint256) {
        return totalUserRevenue;
    }

    function getUserInfo(uint256 _pid, address _user) public view returns (uint256, uint256){
        UserInfo storage user = userInfo[_pid][_user];
        return (user.amount, user.rewardDebt);
    }

    function getPoolInfo(uint256 _pid) public view returns (PoolInfo memory){
        return poolInfoList[_pid];
    }

    function getPoolLength() public view returns (uint256){
        return poolInfoList.length;
    }

    function getActionUserList() external onlyOwner view returns (address[] memory){
        return userList;
    }

    /**
     * Get single pool TVL
     */
    function getPoolTvl(uint256 _pid) public view returns (uint256){
        PoolInfo storage pool = poolInfoList[_pid];
        return pool.vault.balance();
    }

    /**
     * Get all pool total TVL
     */
    function getPoolTotalTvl() public view returns (PoolTvl[] memory){
        uint256 _len = poolInfoList.length;
        PoolTvl[] memory _totalPoolTvl = new PoolTvl[](_len);

        for (uint256 pid = 0; pid < _len; pid++) {
            uint256 _tvl = getPoolTvl(pid);

            PoolTvl memory _pt = PoolTvl({
                pid: pid,
                assets: poolInfoList[pid].assets,
                tvl: _tvl
            });

            _totalPoolTvl[pid] = _pt;
        }
        return _totalPoolTvl;
    }

    /**
     * Start to farm
     */
    function startMining(uint256 _tokenPerBlock) public onlyOwner {
        require(startTimestamp == 0, "Farm: mining already started");
        require(_tokenPerBlock > 0, "Farm: token bonus per block must be over 0");

        startTimestamp = block.timestamp;
        startBlock = block.number;

        tokenPerBlock = _tokenPerBlock;
        bonusEndTime = startTimestamp + 40 days;
    }

    /**
     * Check the pool created or not
     */
    function checkDuplicatePool(IERC20 _token) internal view {
        uint _existed = 0;
        for (uint256 i = 0; i < poolInfoList.length; i++) {
            if (poolInfoList[i].assets == _token) {
                _existed = 1;
                break;
            }
        }

        require(_existed == 0, "Farm: pool already existed");
    }

    /**
     * Add new pool
     */
    function addPool(
        uint256 _allocPoints,
        IERC20 _token,
        bool _withUpdate,
        uint256 _withdrawFee,
        address _vault,
        bool isEth
    ) external onlyOwner {

        checkDuplicatePool(_token);

        if (_withUpdate) {
            updateMassPools();
        }

        uint256 lastRewardTime = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;

        // increase total alloc point
        totalAllocPoint = totalAllocPoint.add(_allocPoints);

        if (isEth == false) {
            IERC20(_token).safeIncreaseAllowance(address(_vault), type(uint256).max);
        }

        poolInfoList.push(PoolInfo({
            assets: _token,
            allocPoint: _allocPoints,
            amount: 0,
            withdrawFee: _withdrawFee,
            lastRewardTime: lastRewardTime,
            acctPerShare: 0,
            vault: IVault(_vault)
        }));
    }

    /**
     * Update the pool info
     */
    function setPool(
        uint256 _pid,
        uint256 _allocPoints,
        bool _withUpdate,
        uint256 _withdrawFee,
        IVault _vault
    ) external onlyOwner {

        if (_withUpdate) {
            updateMassPools();
        }

        totalAllocPoint = totalAllocPoint.sub(poolInfoList[_pid].allocPoint).add(_allocPoints);

        poolInfoList[_pid].allocPoint = _allocPoints;
        poolInfoList[_pid].withdrawFee = _withdrawFee;
        poolInfoList[_pid].vault = _vault;
    }

    function updateMassPools() public {
        for (uint256 i = 0; i < poolInfoList.length; i++) {
            updatePool(i);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfoList[_pid];

        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }

        if (block.timestamp > bonusEndTime) {
            tokenPerBlock = tokenPerBlock.div(BONUS_MULTIPLIER);
        }

        uint256 totalAmount = pool.amount;
        if (totalAmount <= 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        pool.acctPerShare = pool.acctPerShare.add(tokenReward.mul(1e18).div(totalAmount));
        pool.lastRewardTime = block.timestamp;
    }

    /**
     * Return the user pending rewards
     */
    function pendingRewardToken(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfoList[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 acctPerShare = pool.acctPerShare;
        uint256 totalAmount = pool.amount;

        if (block.timestamp > pool.lastRewardTime && totalAmount > 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            acctPerShare = acctPerShare.add(tokenReward.mul(1e18).div(totalAmount));
        }

        uint256 reward = user.amount.mul(acctPerShare).div(1e18);

        uint256 _pendingRewards = reward > user.rewardDebt ? reward.sub(user.rewardDebt) : 0;
        if (pool.withdrawFee == 0) {
            return _pendingRewards;
        } else {
            if (_pendingRewards > 0) {
                uint256 _fee = _pendingRewards.mul(pool.withdrawFee).div(1000);
                return _pendingRewards.sub(_fee);
            } else {
                return 0;
            }

        }
    }

    /**
    * Calculate the rewards and transfer to user
    */
    function harvest(uint256 _pid, address _userAddr) public {
        require(_paused == false, "Farm: Paused");
        require(_userAddr != address(0), "Farm: invalid user address");

        UserInfo storage user = userInfo[_pid][_userAddr];

        uint256 pendingRewards = pendingRewardToken(_pid, _userAddr);
        if (pendingRewards > 0) {
            user.rewardDebt = user.rewardDebt.add(pendingRewards);
            totalUserRevenue = totalUserRevenue.add(pendingRewards);
            safeTokenTransfer(_userAddr, pendingRewards);
        }
    }

    /**
     * Deposit
     */
    function deposit(uint256 _pid, uint256 _amount) external payable nonReentrant returns (uint){
        require(_paused == false, "Farm: Paused");
        require(tokenPerBlock > 0, "Farm: not start yet");

        PoolInfo storage pool = poolInfoList[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        // process rewards
        if (user.amount > 0) {
            harvest(_pid, msg.sender);
        }

        // process WETH
        if (address(pool.assets) == weth) {
            if (_amount > 0) {
                TransferHelper.safeTransferFrom(address(pool.assets), address(msg.sender), address(this), _amount);
                TransferHelper.safeTransfer(weth, address(wethHelper), _amount);
                wethHelper.withdraw(weth, address(this), _amount);
            }

            if (msg.value > 0) {
                _amount = _amount.add(msg.value);
            }
        } else {
            if (_amount > 0) {
                TransferHelper.safeTransferFrom(address(pool.assets), address(msg.sender), address(this), _amount);
            }
        }

        if (_amount > 0) {
            pool.amount = pool.amount.add(_amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.acctPerShare).div(1e18);

        if (_amount > 0) {
            if (address(pool.assets) == weth) {
                _amount = pool.vault.deposit{value: _amount}(msg.sender, 0);
            } else {
                _amount = pool.vault.deposit(msg.sender, _amount);
            }
        }

        userList.push(msg.sender);

        emit Deposit(msg.sender, _pid, _amount);
        return uint(Errors.SUCCESS);
    }

    /**
     * Withdraw
     */
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant returns (uint){
        require(_paused == false, "Farm: Paused");
        require(tokenPerBlock > 0, "Farm: not start yet");

        PoolInfo storage pool = poolInfoList[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "Farm: withdraw amount exceeds balance");

        updatePool(_pid);

        // process rewards
        harvest(_pid, msg.sender);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.amount = pool.amount.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.acctPerShare).div(1e18);

        pool.vault.withdraw(msg.sender, _amount);

        emit Withdraw(msg.sender, _pid, _amount);
        return uint(Errors.SUCCESS);
    }

    function getPoolPid(address _asset) external view returns (uint){
        uint len = poolInfoList.length;

        for (uint i = 0; i < len; i++) {
            if (address(poolInfoList[i].assets) == _asset) {
                return i;
            }
        }

        return 9999;
    }

    function getFarmPause() external view returns (bool){
        return _paused;
    }

    function setFarmPause(bool _pause) external onlyOwner {
        _paused = _pause;
    }

    function safeTokenTransfer(address _user, uint256 _amount) internal {
        uint256 tokenBal = token.balanceOf(address(this));
        if (_amount > tokenBal) {
            token.safeTransfer(_user, tokenBal);
        } else {
            token.safeTransfer(_user, _amount);
        }
    }


    function getMultiplier(uint256 _from, uint256 _to) internal pure returns (uint256){
        return _to.sub(_from);
    }
}


