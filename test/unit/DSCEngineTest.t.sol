// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test,console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStablecoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDsc.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDsc.sol";

contract DSCEngineTest is Test{
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcPriceFeed;
    address wbtc;
    address weth;
    uint256 deployerKey;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 AMOUNT_DSC_TO_MINT = 3 ether;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 AMOUNT_DSC_TO_BREAK_HEALTH_FACTOR = 15000 ether;
    uint256 LIQUIDATION_THRESHOLD = 50 ;

    uint256 expectedHealthFactor = 0;

    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, uint256 token, address indexed tokenAddress);

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine,config) = deployer.run();
        (ethUsdPriceFeed, btcPriceFeed,weth, wbtc ,deployerKey) =  config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    ////////////////////////
    //Constructor Tests////
    //////////////////////

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses,address(dsc));
    }

    ///////////////////////
    //// PRICE TESTS//////
    /////////////////////
    function testGetTokenAmountFromUsd() public{
        uint256 expectedWeth = 0.05 ether;
        uint256 amountToFund = engine.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountToFund, expectedWeth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd,expectedUsd);
    }

    ///////////////////////////////////
    //// Deposit Collateral TESTS//////
    ///////////////////////////////////
    
    //For this test we have to setup a mock.. Where the transfer from always returns false
    function testRevertsIfTransferFromFails() public{
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses,priceFeedAddresses,address(mockDsc));
        mockDsc.mint(USER,AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        vm.prank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    
    function tesRevertIfCollateralZero() public{
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine),AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth,0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public{
        ERC20Mock ranToken = new ERC20Mock("RAN","RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__DSCEngineTokenNotAllowed.selector);
        engine.depositCollateral(address(ranToken),AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral(){
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral{
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance,0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral{
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted,expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL,expectedDepositAmount);
    }

    modifier depositedAndMinted(){
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralMintDsc(weth, AMOUNT_COLLATERAL,AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////


    function testRevertsIfMintedDscBreaksHealthFactor() public{
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        AMOUNT_DSC_TO_MINT = (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(address(engine)), AMOUNT_COLLATERAL);

        uint256 probableHealthFactor = engine.calculateHealthFactor(AMOUNT_DSC_TO_MINT, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, probableHealthFactor));
        engine.depositCollateralMintDsc(weth,AMOUNT_COLLATERAL,AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    ////////////////////////////////////////
    ////// mintDsc Tests //////////////////
    //////////////////////////////////////

    function testRevertsIfMintFails() public {
        MockFailedMintDSC mockdsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockdsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockdsc));
        mockdsc.transferOwnership(address(mockdsce));
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockdsce),AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockdsce.depositCollateralMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralMintDsc(weth,AMOUNT_COLLATERAL,AMOUNT_DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral{
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        AMOUNT_DSC_TO_MINT = (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();

        vm.startPrank(USER);
        uint256 probableHealthFactor = engine.calculateHealthFactor(AMOUNT_DSC_TO_MINT, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, probableHealthFactor));
        engine.mintDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // burnDsc Tests /////////////////
    /////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public{
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine),AMOUNT_COLLATERAL);
        engine.depositCollateralMintDsc(weth,AMOUNT_COLLATERAL,AMOUNT_DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function testCanBurnDsc() public depositedAndMinted{
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        engine.burnDsc(AMOUNT_DSC_TO_MINT);
        
        vm.stopPrank();
        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(userBalance,0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests ////////
    /////////////////////////////////

    function testRevertsIfTransferFails() public{
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockToken = new MockFailedTransfer();
        tokenAddresses = [address(mockToken)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockdsce = new DSCEngine(tokenAddresses, priceFeedAddresses,address(mockToken));
        mockToken.mint(USER,AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockToken.transferOwnership(address(mockdsce));
        
        vm.startPrank(USER);
        mockToken.approve(address(mockdsce),AMOUNT_COLLATERAL);
        mockdsce.depositCollateral(address(mockToken),AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockdsce.redeemCollateral(address(mockToken),AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertIfRedeemAmountIsZero() public{
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth,AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral{
        vm.startPrank(USER);
        uint256 balanceBeforeRedeem = ERC20Mock(weth).balanceOf(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 balanceAfterRedeem = ERC20Mock(weth).balanceOf(USER);
        uint256 collateralRedeemedBalance = balanceAfterRedeem - balanceBeforeRedeem;
        assertEq(collateralRedeemedBalance,AMOUNT_COLLATERAL);
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral{
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(USER, USER, AMOUNT_COLLATERAL, weth);
        vm.startPrank(USER);
        engine.redeemCollateral(weth,AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedAndMinted{
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateralForDsc(weth,0,AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public{
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedAndMinted{
        //Amount_Collateral = 10 ether = $10*2000 = $20000
        //Amount_DSC_TO_MINT = 3 ether
        //LiquidationThreshold = 50
        //LiquidationPrecision = 100
        //20000*50/100 = 10000 => 10000 * 1e18 / 3  = 3333333333333333333333


        expectedHealthFactor = 3333333333333333333333;
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(expectedHealthFactor, healthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedAndMinted{
        int256 ethUsdUpdatedPrice = 5e7;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        //0.5 * 10 = 5 ==> 5* 50 / 100 = 2.5 ==>  2.5 * 1e18 / 3 = 833333333333333333

        uint256 userHeathFactor = engine.getHealthFactor(USER);
        assertEq(userHeathFactor, 833333333333333333);
    }


    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    function testMustImproveHealthFactorOnLiquidation() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockMoreDebtDSC mockdsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        priceFeedAddresses = [ethUsdPriceFeed];
        tokenAddresses = [weth];
        vm.startPrank(owner);
        DSCEngine mockdsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockdsc));
        mockdsc.transferOwnership(address(mockdsce));
        vm.stopPrank();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockdsce),AMOUNT_COLLATERAL);
        mockdsce.depositCollateralMintDsc(weth,AMOUNT_COLLATERAL,AMOUNT_DSC_TO_MINT);
        vm.stopPrank();

        uint256 COLLATERAL_TO_COVER = 30 ether; 
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(mockdsce),COLLATERAL_TO_COVER);
        uint256 DEBT_TO_COVER = 2 ether;
        mockdsce.depositCollateralMintDsc(weth,COLLATERAL_TO_COVER,DEBT_TO_COVER);
        ERC20Mock(address(mockdsc)).approve(address(mockdsce),DEBT_TO_COVER);

        int256 ethUsdUpdatedPrice = 5e7;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockdsce.liquidate(weth,USER,DEBT_TO_COVER);
        vm.stopPrank();
    }

    function testcantliquidategoodhealthfactor() public {
        ERC20Mock(weth).mint(USER,AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralMintDsc(weth,AMOUNT_COLLATERAL,AMOUNT_DSC_TO_MINT);
        dsc.approve(address(engine),AMOUNT_DSC_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth,USER,AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 5e7; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);

        uint256 AMOUNT_COLLATERAL_LIQUIDATOR = 100 ether;

        ERC20Mock(weth).mint(LIQUIDATOR, AMOUNT_COLLATERAL_LIQUIDATOR);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL_LIQUIDATOR);
        engine.depositCollateralMintDsc(weth, AMOUNT_COLLATERAL_LIQUIDATOR, AMOUNT_DSC_TO_MINT);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        engine.liquidate(weth, USER, AMOUNT_DSC_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testliquidatedPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(weth,AMOUNT_DSC_TO_MINT) +
            (engine.getTokenAmountFromUsd(weth,AMOUNT_DSC_TO_MINT) / engine.getLiquidationBonus());
        uint256 liquidator_weth_balance_hardcoded = 6600000000000000000;
        assertEq(liquidatorWethBalance, liquidator_weth_balance_hardcoded);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_TO_MINT)
            + (engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_TO_MINT) / engine.getLiquidationBonus());

        uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);
        console.log(userCollateralValueInUsd);
        uint256 hardCodedExpectedValue = 1700000000000000000;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, AMOUNT_DSC_TO_MINT);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

     ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

}



