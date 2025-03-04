// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved(); // 清算失败

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // chainlink eth喂价精度为8位，需要再同步的精度值为1e10
    uint256 private constant PRECISION = 1e18; // 换算精度
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //清算阈值
    uint256 private constant LIQUIDATION_PRECISION = 100; //清算精度
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; //最小健康因子
    uint256 private constant LIQUIDATION_BONUS = 10; //清算人奖励
    // 代币和喂价映射
    mapping(address token => address priceFeed) private s_priceFeeds;
    // 用户和代币和数量映射
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSC) private s_DSCMinted;
    // 存储符合erc20的代币作为抵押物的数组
    address[] private s_collateralTokens;
    // 稳定币dsb对象
    DecentralizedStableCoin private immutable i_dsc;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    /**
     * @dev Modifier to ensure that the amount is greater than zero.
     * @notice This modifier is used to ensure that the amount is greater than zero.
     */

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    // 验证抵押物是否为系统规定的抵押物
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    constructor(
        address[] memory tokenAddresses, // token代币地址数组
        address[] memory priceFeedAddresses, // 喂价地址数组
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // Loop through the token addresses and price feed addresses and store them in the mapping.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; // 抵押物地址对应的喂价地址
            s_collateralTokens.push(tokenAddresses[i]); // 将抵押物地址添加到数组中
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * @dev Deposit Collateral And Mint Dsc
     * @notice This function allows users to deposit collateral and mint DSC tokens.
     * @notice 用户抵押资产并铸造Dsc(例如抵押eth铸造dsc)
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        //
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @notice This function allows users to redeem collateral for DSC.
     * @notice 用户可以赎回Dsc并换取抵押资产
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param amountDscToMint The amount of decentralized stablecoin to mint.
     * @notice This function allows users to mint DSC with collateral.
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender, msg.sender, amount);
        // 判断用户是否健康
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function allows users to liquidate other users' collateral.
     * @notice 用户可以清算其他用户的抵押资产
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // 获取当前债务的抵押物价值
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // 获取清算奖励,以被清算者的抵押资产作为数量
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // 计算清算人所获取的总收益
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        //将抵押资产转给清算人
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // 清算人的dsc数量
        _burnDsc(user, msg.sender, debtToCover);
        // 判断被清算的用户是否健康
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        // 判断清算人的健康因子是否正常
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function calculates the health factor of a user.
     * @notice 用户可以查看自己的健康因子
     */
    function getHealthFactor() external view {}

    ////////////////////////////////////
    //       Helper Functions         //
    ////////////////////////////////////
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // 获取抵押物对应的usd价格
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 获取债务目前值多少个抵押物
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function _burnDsc(address burnFromUser, address dscFrom, uint256 amountDscToBurn) private {
        //扣除用户的dsc数量
        s_DSCMinted[burnFromUser] -= amountDscToBurn;
        // 将用户地址的dsc数量转移到合约地址
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        // 燃烧掉已经铸造的dsc
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        // 减少用户抵押的代币数量
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        //出发赎回抵押物事件，记录用户地址，用户抵押的代币地址和数量
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInfomation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        // 获取用户抵押的代币数量和代币对应的usd价格
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /*
     * @param user The user whose health factor needs to be calculated.
     * @notice This function calculates the health factor of a user.
     * @dev This function is called by other functions to ensure that the health factor of a user remains within a safe range. 
     */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInfomation(user);
        //健康因子 = (抵押物价值 * 清算阈值) / 债务总量(已经mint的dsc);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     *
     * @param _user The user whose health factor needs to be checked.
     * @notice This function reverts if the health factor of a user is below the minimum allowed value.
     * @dev This function is called by other functions to ensure that the health factor of a user remains within a safe range.
     */
    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            // 获取系统规定的可以抵押的某个代币
            address token = s_collateralTokens[i];
            //获取用户抵押的token数量
            uint256 amount = s_collateralDeposited[user][token];
            // 获取token对应的usd价格
            totalCollateralValue += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //price 1*1e8 amount 2  2
    }
}
