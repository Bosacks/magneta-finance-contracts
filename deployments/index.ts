import fs from "node:fs";
import path from "node:path";

export interface Deployment {
  network: string;
  chainId: string;
  deployer: string;
  admin: string;
  timestamp: string;
  contracts: Record<string, string>;
}

const DIR = __dirname;

function loadAll(): Record<string, Deployment> {
  const out: Record<string, Deployment> = {};
  for (const f of fs.readdirSync(DIR)) {
    if (!f.endsWith(".json")) continue;
    const raw = fs.readFileSync(path.join(DIR, f), "utf8");
    const d = JSON.parse(raw) as Deployment;
    out[d.network] = d;
  }
  return out;
}

export const deployments = loadAll();

export function get(network: string): Deployment {
  const d = deployments[network];
  if (!d) {
    throw new Error(
      `No deployment for network "${network}". Known: ${Object.keys(deployments).join(", ")}`,
    );
  }
  return d;
}

export function address(network: string, contract: string): string {
  const d = get(network);
  const a = d.contracts[contract];
  if (!a) {
    throw new Error(
      `${contract} not deployed on ${network}. Known: ${Object.keys(d.contracts).join(", ")}`,
    );
  }
  return a;
}
