import { createDeployFunction } from "../utils/deploy";

const func = createDeployFunction({
  contractName: "ProtocolGovernor",
  id: "ProtocolGovernor_1",
  dependencyNames: ["GovToken", "GovTimelockController"],
  getDeployArgs: async ({ dependencyContracts }) => {
    return [
      dependencyContracts.GovToken.address, // token
      dependencyContracts.GovTimelockController.address, // timelock
      "GMX Governor", // name
      "v2.0", // version
      24 * 60 * 60, // votingDelay
      5 * 24 * 60 * 60, // votingPeriod
      30_000, // proposalThreshold
      4, // quorumNumeratorValue
    ];
  },
});

export default func;
