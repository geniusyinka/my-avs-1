// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@eigenlayer/contracts/permissions/PauserRegistry.sol";
import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IAVSDirectory} from "@eigenlayer/contracts/interfaces/IAVSDirectory.sol";
import {IStrategyManager, IStrategy} from "@eigenlayer/contracts/interfaces/IStrategyManager.sol";
import {ISlasher} from "@eigenlayer/contracts/interfaces/ISlasher.sol";
import {StrategyBaseTVLLimits} from "@eigenlayer/contracts/strategies/StrategyBaseTVLLimits.sol";
import "@eigenlayer/test/mocks/EmptyContract.sol";
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {Quorum, StrategyParams} from "@eigenlayer-middleware/src/interfaces/IECDSAStakeRegistryEventsAndErrors.sol";
import "@eigenlayer-middleware/src/OperatorStateRetriever.sol";

import {VotingServiceManager, IServiceManager } from "../src/VotingServiceManager.sol";
import "../src/ERC20Mock.sol";
import {Utils} from "./utils/Utils.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";

// # To deploy and verify our contract
// forge script script/VotingServiceManagerDeployer.sol:VotingServiceManagerDeployer --rpc-url $RPC_URL  --private-key $PRIVATE_KEY --broadcast -vvvv
contract VotingServiceManagerDeployer is Script, Utils {
    ERC20Mock public erc20Mock;
    StrategyBaseTVLLimits public erc20MockStrategy;

    // VotingServiceManager contracts
    ProxyAdmin public votingServiceManagerProxyAdmin;
    PauserRegistry public votingServiceManagerPauserReg;
    
    ECDSAStakeRegistry public stakeRegistryProxy;
    ECDSAStakeRegistry public stakeRegistryImplementation;

    VotingServiceManager public votingServiceManagerProxy;
    VotingServiceManager public votingServiceManagerImplementation;

    function run() external {
        // Eigenlayer contracts
        string memory eigenlayerDeployedContracts = readOutput(
            "eigenlayer_deployment_output"
        );
        IStrategyManager strategyManager = IStrategyManager(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.strategyManager"
            )
        );
        IDelegationManager delegationManager = IDelegationManager(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.delegation"
            )
        );
        IAVSDirectory avsDirectory = IAVSDirectory(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.avsDirectory"
            )
        );
        ProxyAdmin eigenLayerProxyAdmin = ProxyAdmin(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.eigenLayerProxyAdmin"
            )
        );
        PauserRegistry eigenLayerPauserReg = PauserRegistry(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.eigenLayerPauserReg"
            )
        );
        StrategyBaseTVLLimits baseStrategyImplementation = StrategyBaseTVLLimits(
                stdJson.readAddress(
                    eigenlayerDeployedContracts,
                    ".addresses.baseStrategyImplementation"
                )
            );

        address votingServiceCommunityMultisig = msg.sender;
        address votingServicePauser = msg.sender;

        vm.startBroadcast();
        _deployErc20AndStrategyAndWhitelistStrategy(
            eigenLayerProxyAdmin,
            eigenLayerPauserReg,
            baseStrategyImplementation,
            strategyManager
        );
        _deployVotingServiceManagerContracts(
            delegationManager,
            avsDirectory,
            erc20MockStrategy,
            votingServiceCommunityMultisig,
            votingServicePauser
        );
        vm.stopBroadcast();
    }

    function _deployErc20AndStrategyAndWhitelistStrategy(
        ProxyAdmin eigenLayerProxyAdmin,
        PauserRegistry eigenLayerPauserReg,
        StrategyBaseTVLLimits baseStrategyImplementation,
        IStrategyManager strategyManager
    ) internal {
        erc20Mock = new ERC20Mock();
        erc20MockStrategy = StrategyBaseTVLLimits(
            address(
                new TransparentUpgradeableProxy(
                    address(baseStrategyImplementation),
                    address(eigenLayerProxyAdmin),
                    abi.encodeWithSelector(
                        StrategyBaseTVLLimits.initialize.selector,
                        1 ether, // maxPerDeposit
                        100 ether, // maxDeposits
                        IERC20(erc20Mock),
                        eigenLayerPauserReg
                    )
                )
            )
        );
        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = erc20MockStrategy;
        bool[] memory thirdPartyTransfersForbiddenValues = new bool[](1);
        thirdPartyTransfersForbiddenValues[0] = false;
        strategyManager.addStrategiesToDepositWhitelist(
            strats,
            thirdPartyTransfersForbiddenValues
        );
    }

    function _deployVotingServiceManagerContracts(
        IDelegationManager delegationManager,
        IAVSDirectory avsDirectory,
        IStrategy strat,
        address votingServiceCommunityMultisig,
        address votingServicePauser
    ) internal {
        IStrategy[1] memory deployedStrategyArray = [strat];
        uint numStrategies = deployedStrategyArray.length;

        // deploy proxy admin for ability to upgrade proxy contracts
        votingServiceManagerProxyAdmin = new ProxyAdmin();

        // deploy pauser registry
        {
            address[] memory pausers = new address[](2);
            pausers[0] = votingServicePauser;
            pausers[1] = votingServiceCommunityMultisig;
            votingServiceManagerPauserReg = new PauserRegistry(
                pausers,
                votingServiceCommunityMultisig
            );
        }

        EmptyContract emptyContract = new EmptyContract();

        // deploy proxy contracts
        votingServiceManagerProxy = VotingServiceManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(votingServiceManagerProxyAdmin),
                    ""
                )
            )
        );
        stakeRegistryProxy = ECDSAStakeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(votingServiceManagerProxyAdmin),
                    ""
                )
            )
        );

        // deploy implementation contracts
        {
            stakeRegistryImplementation = new ECDSAStakeRegistry(
                delegationManager
            );

            votingServiceManagerProxyAdmin.upgrade(
                TransparentUpgradeableProxy(payable(address(stakeRegistryProxy))),
                address(stakeRegistryImplementation)
            );
        }

        {   
            StrategyParams[]
                memory quorumsStrategyParams = new StrategyParams[](
                    numStrategies
            );
            
            for (uint j = 0; j < numStrategies; j++) {
                quorumsStrategyParams[j] = StrategyParams({
                        strategy: deployedStrategyArray[j],
                        multiplier: 10_000
                    });
            }
        
            Quorum memory quorum = Quorum(
                quorumsStrategyParams
            );

            votingServiceManagerProxyAdmin.upgradeAndCall(
                TransparentUpgradeableProxy(
                    payable(address(stakeRegistryProxy))
                ),
                address(stakeRegistryImplementation),
                abi.encodeWithSelector(
                    ECDSAStakeRegistry.initialize.selector,
                    address(votingServiceManagerImplementation),
                    1,
                    quorum
                )
            );
        }

        votingServiceManagerImplementation = new VotingServiceManager(
            address(avsDirectory),
            address(stakeRegistryProxy),
            address(delegationManager)
        );
        votingServiceManagerProxyAdmin.upgrade(
            TransparentUpgradeableProxy(
                payable(address(votingServiceManagerProxy))
            ),
            address(votingServiceManagerImplementation)
        );

        // WRITE JSON DATA
        string memory parent_object = "parent object";

        string memory deployed_addresses = "addresses";
        vm.serializeAddress(
            deployed_addresses,
            "erc20Mock",
            address(erc20Mock)
        );
        vm.serializeAddress(
            deployed_addresses,
            "erc20MockStrategy",
            address(erc20MockStrategy)
        );
        vm.serializeAddress(
            deployed_addresses,
            "VotingServiceManagerProxy",
            address(votingServiceManagerProxy)
        );
        vm.serializeAddress(
            deployed_addresses,
            "VotingServiceManagerImplementation",
            address(votingServiceManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "ECDSAStakeRegistry",
            address(stakeRegistryProxy)
        );
        
        string memory deployed_addresses_output = vm.serializeAddress(
            deployed_addresses,
            "ECDSAStakeRegistryImplementation",
            address(stakeRegistryImplementation)
        );

        // serialize all the data
        string memory finalJson = vm.serializeString(
            parent_object,
            deployed_addresses,
            deployed_addresses_output
        );

        writeOutput(finalJson, "voting_service_manager_deployment_output");
    }
}
