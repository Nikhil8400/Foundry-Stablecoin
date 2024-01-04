// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test,console} from "forge-std/Test.sol";
import {DeployDSC} from "../../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStablecoin.sol";
import {DSCEngine} from "../../../src/DSCEngine.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {MockFailedTransferFrom} from "../../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../../mocks/MockFailedMintDsc.sol";
import {MockFailedTransfer} from "../../mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../../mocks/MockMoreDebtDsc.sol";
import {StopOnRevertHandler} from "./StopOnRevertHandler.t.sol";

contract StopOnRevertInvariants is Test{
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    StopOnRevertHandler handler;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
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


    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine,config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        handler = new StopOnRevertHandler(engine,dsc);         
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupplyDollars() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(engine));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, wethDeposted);
        uint256 wbtcValue = engine.getUsdValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);

        assert(wethValue + wbtcValue >= totalSupply);
    }

      function invariant_gettersCantRevert() public view {
        engine.getAdditionalFeedPrecision();
        engine.getCollateralTokens();
        engine.getLiquidationBonus();
        engine.getLiquidationBonus();
        engine.getLiquidationThreshold();
        engine.getMinHealthFactor();
        engine.getPrecision();
        engine.getDsc();
    }
}

