import { setTimeout } from "timers/promises";
import { exec } from "child_process";

import hre from "hardhat";
import got from "got";

const { apiUrl, apiKey } = hre.network.config.verify.etherscan;

// a custom argument file may be needed for complex arguments
// https://hardhat.org/hardhat-runner/plugins/nomicfoundation-hardhat-verify#complex-arguments
//
// example:
// ARBISCAN_API_KEY=<api key> npx hardhat --network arbitrum verify --constructor-args ./verification/gov/govTimelockController.js --contract contracts/gov/GovTimelockController.sol:GovTimelockController 0x99Ff4D52e97813A1784bC4A1b37554DC3499D67e
async function getIsContractVerified(address: string) {
  const res: any = await got
    .get(`${apiUrl}api`, {
      searchParams: {
        module: "contract",
        action: "getabi",
        address,
        apikey: apiKey,
      },
    })
    .json();

  if (res.status !== "1") {
    if (res.result?.includes("rate limit reached")) {
      throw new Error("Rate limit reached");
    }
    if (res.result?.includes("Invalid API URL endpoint")) {
      throw new Error("Invalid API URL endpoint");
    }

    if (!res.result?.includes("Contract source code not verified")) {
      console.warn("%s: %s", res.message, res.result);
    }
  }

  return res.status === "1";
}

function encodeArg(arg) {
  if (Array.isArray(arg)) {
    return `[${arg.map((item) => encodeArg(item))}]`;
  }

  if (typeof arg !== "string") {
    return arg;
  }

  return `"${arg}"`;
}

async function main() {
  const allDeployments = await hre.deployments.all();
  console.log("Verifying %s contracts", Object.keys(allDeployments).length);

  for (const [name, deployment] of Object.entries(allDeployments)) {
    const start = Date.now();
    const { address, args } = deployment;
    const argStr = args.map((arg) => encodeArg(arg)).join(" ");

    try {
      await setTimeout(200);
      const isContractVerified = await getIsContractVerified(address);

      if (isContractVerified) {
        console.log("Contract %s %s is already verified", name, address);
        continue;
      }

      console.log("Verifying contract %s %s %s", name, address, argStr);
      const metadata = JSON.parse(deployment.metadata);
      const contractFQN = `${Object.keys(metadata.settings.compilationTarget)[0]}:${name}`;
      const contractArg = `--contract ${contractFQN}`;

      console.log("command", `npx hardhat verify ${contractArg} --network ${hre.network.name} ${address} ${argStr}`);
      await new Promise((resolve, reject) => {
        exec(
          `npx hardhat verify ${contractArg} --network ${hre.network.name} ${address} ${argStr}`,
          (ex, stdout, stderr) => {
            if (ex) {
              reject(ex);
              return;
            }
            if (stderr) {
              reject(stderr);
              return;
            }
            resolve(stdout);
          }
        );
      });
      console.log("Verified contract %s %s in %ss", name, address, (Date.now() - start) / 1000);
    } catch (ex) {
      console.error("Failed to verify contract %s in %ss", address, (Date.now() - start) / 1000);
      console.error(ex);
    }
  }

  console.log("Done");
}

main()
  .then(() => {
    process.exit(0);
  })
  .catch((ex) => {
    console.error(ex);
    process.exit(1);
  });
