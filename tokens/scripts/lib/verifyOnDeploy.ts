import { run, network } from "hardhat";

/**
 * Verify a contract on the chain's explorer immediately after deploying it.
 *
 * Why at deploy time rather than in a later pass: verification needs a
 * byte-for-byte match between the deployed bytecode and a recompile, and the
 * bytecode bakes in every dependency. MagnetaOFTStandardFactory on Base is the
 * cautionary tale — it went out unverified in June, and by July no combination
 * of source revision and compiler settings reproduced it (24400 / 24403 /
 * 24572 / 24615 against 24443 on-chain, identical solc and optimizer settings)
 * because @layerzerolabs/oft-evm and @openzeppelin/contracts had moved
 * underneath it. Verifying while the artifacts that produced the transaction
 * are still on disk costs one call; reconstructing it later means restoring a
 * lockfile from months earlier.
 *
 * Never throws. The deployment has already happened and been paid for by the
 * time this runs, so a failing explorer must not abort the script or leave the
 * caller unsure whether the contract exists. Failures print the exact manual
 * command instead.
 *
 * Set SKIP_VERIFY=1 to bypass entirely (local forks, dry runs).
 */
export async function verifyOnDeploy(
    name: string,
    address: string,
    constructorArguments: unknown[] = [],
    opts: { confirmations?: number; attempts?: number } = {},
): Promise<boolean> {
    if (process.env.SKIP_VERIFY === "1") {
        console.log(`  verify: skipped (SKIP_VERIFY=1) — ${name}`);
        return false;
    }
    if (network.name === "hardhat" || network.name === "localhost") {
        return false;
    }

    // Explorers index from their own node, which lags the RPC that just gave
    // us the receipt. Verifying instantly returns "contract not found" on most
    // chains, so wait before the first attempt and back off between retries.
    const attempts = opts.attempts ?? 4;
    let waitMs = (opts.confirmations ?? 5) * 3000;

    for (let i = 1; i <= attempts; i++) {
        await new Promise((r) => setTimeout(r, waitMs));
        try {
            await run("verify:verify", { address, constructorArguments });
            console.log(`  verify: OK — ${name} ${address}`);
            return true;
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : String(e);

            if (/already.{0,12}verified/i.test(msg)) {
                console.log(`  verify: already verified — ${name} ${address}`);
                return true;
            }
            // Not yet indexed: worth another pass.
            if (i < attempts && /does not have bytecode|not found|unable to locate|rate limit/i.test(msg)) {
                waitMs = Math.min(waitMs * 2, 60000);
                console.log(`  verify: not indexed yet, retrying in ${Math.round(waitMs / 1000)}s (${i}/${attempts})`);
                continue;
            }

            console.log(`  verify: FAILED — ${name} ${address}`);
            console.log(`          ${msg.split("\n")[0].slice(0, 160)}`);
            console.log(`          retry manually:`);
            console.log(
                `          pnpm hardhat verify --network ${network.name} ${address} ${constructorArguments
                    .map((a) => JSON.stringify(String(a)))
                    .join(" ")}`,
            );
            return false;
        }
    }
    return false;
}
