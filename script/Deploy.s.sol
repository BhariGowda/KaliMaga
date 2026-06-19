// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {KaliMagaFactory} from "../src/core/KaliMagaFactory.sol";
import {KaliMagaRouter} from "../src/core/KaliMagaRouter.sol";
import {KaliMagaPriceOracle} from "../src/lending/KaliMagaPriceOracle.sol";
import {KaliMagaInterestRateModel} from "../src/lending/KaliMagaInterestRateModel.sol";
import {KaliMagaLendingPool} from "../src/lending/KaliMagaLendingPool.sol";
import {KaliMagaLiquidator} from "../src/lending/KaliMagaLiquidator.sol";

/// @title Deploy
/// @notice Deploys the full KaliMaga protocol suite in dependency order:
/// Factory -> Router -> Oracle -> InterestRateModel -> LendingPool -> Liquidator
/// @dev Run with:
///   forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
contract Deploy is Script {
    // Default interest rate model parameters: 2% base, 10% slope1, 300% slope2, 80% kink
    uint256 constant BASE_RATE_BPS = 200;
    uint256 constant SLOPE1_BPS = 1000;
    uint256 constant SLOPE2_BPS = 30000;
    uint256 constant KINK_BPS = 8000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. AMM core
        KaliMagaFactory factory = new KaliMagaFactory();
        console.log("KaliMagaFactory deployed at:", address(factory));

        KaliMagaRouter router = new KaliMagaRouter(address(factory));
        console.log("KaliMagaRouter deployed at:", address(router));

        // 2. Lending infrastructure
        KaliMagaPriceOracle oracle = new KaliMagaPriceOracle();
        console.log("KaliMagaPriceOracle deployed at:", address(oracle));

        KaliMagaInterestRateModel irm =
            new KaliMagaInterestRateModel(BASE_RATE_BPS, SLOPE1_BPS, SLOPE2_BPS, KINK_BPS);
        console.log("KaliMagaInterestRateModel deployed at:", address(irm));

        KaliMagaLendingPool pool = new KaliMagaLendingPool(address(oracle));
        console.log("KaliMagaLendingPool deployed at:", address(pool));

        // 3. Liquidation engine, wired to the pool, oracle, and router
        KaliMagaLiquidator liquidator = new KaliMagaLiquidator(address(pool), address(oracle), address(router));
        console.log("KaliMagaLiquidator deployed at:", address(liquidator));

        vm.stopBroadcast();

        console.log("\n--- Deployment Summary ---");
        console.log("Factory:    ", address(factory));
        console.log("Router:     ", address(router));
        console.log("Oracle:     ", address(oracle));
        console.log("IRM:        ", address(irm));
        console.log("LendingPool:", address(pool));
        console.log("Liquidator: ", address(liquidator));
    }
}
