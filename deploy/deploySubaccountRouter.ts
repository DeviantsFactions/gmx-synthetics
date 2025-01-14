import { grantRoleIfNotGranted } from "../utils/role";
import { createDeployFunction } from "../utils/deploy";

const constructorContracts = ["Router", "RoleStore", "DataStore", "EventEmitter", "OrderHandler", "OrderVault"];

const func = createDeployFunction({
  contractName: "SubaccountRouter",
  dependencyNames: constructorContracts,
  getDeployArgs: async ({ dependencyContracts }) => {
    return constructorContracts.map((dependencyName) => dependencyContracts[dependencyName].address);
  },
  libraryNames: ["OrderStoreUtils"],
  afterDeploy: async ({ deployedContract, network, deployments }) => {
    if (!["avalancheFuji", "arbitrumGoerli", "hardhat"].includes(network.name)) {
      deployments.log("skip granting roles to SubaccountRouter");
      return;
    }
    await grantRoleIfNotGranted(deployedContract.address, "CONTROLLER");
    await grantRoleIfNotGranted(deployedContract.address, "ROUTER_PLUGIN");
  },
  id: "SubaccountRouter_1",
});

export default func;
