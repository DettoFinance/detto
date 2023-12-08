// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../comm/TransferHelper.sol";


contract Vault is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct UserInfo {
        uint256 amount;
    }

    IERC20 public assets;

    uint256 public totalAssets;

    address public WETH;

    address public farm;

    mapping(address => UserInfo) public userInfoMap;

    address[] public userList;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    receive() external payable {}

    function initialize(IERC20 _assets, address _weth, address _farm) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        assets = _assets;
        WETH = _weth;
        farm = _farm;
    }

    function setFarm(address _farm) external onlyOwner {
        farm = _farm;
    }

    function setWETH(address _weth) external onlyOwner {
        WETH = _weth;
    }

    function setAssets(IERC20 _assets) external onlyOwner {
        assets = _assets;
    }

    
    function balance() public view returns (uint256) {
        if (address(assets) == WETH) {
            return address(this).balance;
        } else {
            return assets.balanceOf(address(this));
        }
    }

    /**
     * Deposit to vault
     */
    function deposit(address _addr, uint256 _amount) public payable nonReentrant returns (uint256){
        require(msg.sender == farm, "Vault: Not farm caller");
        require(_addr != address(0), "Vault: User address cannot be zero address");

        uint256 _depositAmount;
        if (address(assets) == WETH) {
            _depositAmount = _depositETH(_addr, msg.value);
        } else {
            _depositAmount = _deposit(_addr, farm, _amount);
        }

        return _depositAmount;
    }

    function _depositETH(address _addr, uint256 _amount) private returns (uint256) {
        UserInfo storage _userInfo = userInfoMap[_addr];

        _userInfo.amount = _userInfo.amount.add(_amount);
        totalAssets = totalAssets.add(_amount);

        userList.push(_addr);

        return _amount;
    }

    function _deposit(address _addr, address _farm, uint256 _amount) private returns (uint256) {
        UserInfo storage _userInfo = userInfoMap[_addr];

        uint256 _vaultBalance = balance();
        
        TransferHelper.safeTransferFrom(address(assets), _farm, address(this), _amount);

        uint256 _afterVaultBalance = balance();
    
        uint256 _depositAmount = _afterVaultBalance.sub(_vaultBalance);

        _userInfo.amount = _userInfo.amount.add(_depositAmount);
        totalAssets = totalAssets.add(_depositAmount);

        userList.push(_addr);

        return _depositAmount;
    }

    /**
     * Withdraw from vault
     */
    function withdraw(address _addr, uint256 _amount) public nonReentrant returns (uint256) {
        require(msg.sender == farm, "Not farm caller");
        require(_addr != address(0), "User address cannot be zero address");

        UserInfo storage _userInfo = userInfoMap[_addr];
        require(_userInfo.amount >= _amount, "Insufficient balance");

        _userInfo.amount = _userInfo.amount.sub(_amount);
        totalAssets = totalAssets.sub(_amount);

        if (address(assets) == WETH) {
            TransferHelper.safeTransferETH(_addr, _amount);
        } else {
            TransferHelper.safeTransfer(address(assets), _addr, _amount);
        }

        return _amount;
    }

}
