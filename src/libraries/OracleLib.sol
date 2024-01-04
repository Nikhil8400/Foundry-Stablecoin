//SPDX-License_Identifier: MIT

pragma solidity ^0.8.18;
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title Oracle
 * @notice The library is used to check the chainling oracle for stale data.
 * If a price is stale, the function will revert, and render the DSCEngine unusable - this is by design
 * We want the DSCEngine to freeze if prices become stale
 */

library  OracleLib {
    error OracleLib__StalePrice();
    uint256 private constant TIMEOUT = 3 hours;  //  3*60*60 = 10800 sec

    function staleCheckLatesRoundData(AggregatorV3Interface priceFeed) public view returns(uint80, int256,uint256, uint256, uint80){
        (uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
        )= priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if(secondsSince > TIMEOUT) revert OracleLib__StalePrice();
        return (roundId,answer,startedAt,updatedAt,answeredInRound);
    }
}