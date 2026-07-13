const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider("https://evm.cronos.org");
  const endpointAbi = ["function eid() view returns (uint32)"];
  
  const epB = "0x6F475642a6e85809B1c36Fa62763669b1b48DD5B".toLowerCase();
  try {
    const code = await provider.getCode(epB);
    console.log("epB Code:", code.length);
    const c1 = new ethers.Contract(epB, endpointAbi, provider);
    const eid1 = await c1.eid();
    console.log("epB EID:", eid1);
  } catch(e) { console.error("epB err:", e.message) }
}
main().catch(console.error);
