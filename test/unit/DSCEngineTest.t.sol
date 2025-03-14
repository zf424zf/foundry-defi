// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 100 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dscEngine, dsc, helperConfig) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; //转换15个以太坊
        uint256 expectedUsd = 30000e18; //假设现在eth对美元汇率是3000
        uint256 actUsd = dscEngine.getUsdValue(weth, ethAmount); // 获取15个以太坊对应的美元价值
        assertEq(expectedUsd, actUsd); // 断言15个以太坊对应的美元价值等于3000dollar
    }

    function testRevertIfTokenLengthIsNotEqualPriceFeedLength() public {
        address[] memory tokens = new address[](2);
        address[] memory prices = new address[](1);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokens, prices, address(dscEngine));
    }

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether; // 1000美元
        uint256 expectedAmount = 0.05 ether; // 1000美元对应的weth数量
        uint256 actAmount = dscEngine.getTokenAmountFromUsd(weth, usdAmount); // 获取1000美元对应的weth数量
        assertEq(expectedAmount, actAmount); // 断言1000美元对应的weth数量等于333333333333333333333333333
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock fanToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(fanToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER); // 伪造用户
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL); // 授权weth给dscEngine
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL); // 抵押10个以太坊
        vm.stopPrank();
        _;
    }

    modifier mintedDsc() {
        vm.startPrank(USER); // 伪造用户
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL); // 授权weth给dscEngine
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL); // 抵押10个以太坊
        uint256 amountDscMint = 10000 ether; // 铸造10000个dsc
        dscEngine.mintDsc(amountDscMint); // 铸造10000个dsc
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateral() public depositedCollateral {
        //获取用户总铸造的dsc数量和抵押物价值(美元)
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInfomation(USER); // 获取用户信息
        uint256 expectedDscMinted = 0; // 假设判断用户铸造0 dsc
        //获取用户抵押物的价值(美元)
        uint256 expectedCollateralValueInUsd = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd); // 10个以太坊对应的美元价值
        assertEq(totalDscMinted, expectedDscMinted); // 断言用户铸造的dsc数量等于0
        assertEq(AMOUNT_COLLATERAL, expectedCollateralValueInUsd); // 断言用户抵押物的价值(美元)等于10个以太坊
    }

    function testRevertIfUserHealthNotOK() public depositedCollateral {
        vm.startPrank(USER);
        uint256 amountDscMint = 25000 ether; // 铸造20000个dsc
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.mintDsc(amountDscMint);
        vm.stopPrank();
    }

    function testTotalDSCMintedWhenUserFirstDeposite() public depositedCollateral {
        (uint256 totalDscMinted,) = dscEngine.getAccountInfomation(USER);
        assertEq(totalDscMinted, 0);
    }

    function testUserHealthFactorCalculateRight() public mintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInfomation(USER);
        uint256 collateralAdjustedForThreshold =
            (collateralValueInUsd * (dscEngine.getLiquidationThreshold())) / (dscEngine.getLiquidationPrecision());
        uint256 healthFactor = (collateralAdjustedForThreshold * (dscEngine.getPrecision())) / totalDscMinted;
        uint256 expectedHealthFactor = dscEngine.getUserHealthFactor(USER);
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testUserCanMintedDsc() public depositedCollateral {
        vm.startPrank(USER);
        uint256 amountDscMint = 5000 ether; // 铸造5000个dsc
        dscEngine.mintDsc(amountDscMint); // 铸造5000个dsc
        vm.stopPrank();
        (uint256 totalDscMinted,) = dscEngine.getAccountInfomation(USER); // 获取用户信息
        assertEq(totalDscMinted, amountDscMint); // 断言用户铸造的dsc数量等于10000
    }
}
