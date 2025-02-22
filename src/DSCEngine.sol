// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

contract DSCEngine {
    /**
     * @dev Deposit Collateral And Mint Dsc
     * @notice This function allows users to deposit collateral and mint DSC tokens.
     * @notice 用户抵押资产并铸造Dsc(例如抵押eth铸造dsc)
     */
    function depositCollateralAndMintDsc() external {}

    function depositCollateral() external {}

    /***
     * @notice This function allows users to redeem collateral for DSC.
     * @notice 用户可以赎回Dsc并换取抵押资产
     */
    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    /**
     * @notice This function allows users to liquidate other users' collateral.
     * @notice 用户可以清算其他用户的抵押资产
     */
    function liquidate() external {}

    /**
     * @notice This function calculates the health factor of a user.
     * @notice 用户可以查看自己的健康因子
     */
    function getHealthFactor() external view {}
}
