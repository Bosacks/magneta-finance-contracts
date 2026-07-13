const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider("https://evm.cronos.org");
  
  // VVS Router
  const vvsRouter = "0x145863Eb42Cf62847A6073F6c8C6e6C4512E27B1".toLowerCase();
  const code = await provider.getCode(vvsRouter);
  console.log("VVS Router code size:", code.length);

  // USDC
  const usdc = "0xc21223249CA28397B4B6541dfFaEcC539BfF0c59".toLowerCase();
  const erc20Abi = ["function symbol() view returns (string)", "function decimals() view returns (uint8)"];
  const usdcContract = new ethers.Contract(usdc, erc20Abi, provider);
  try {
    const symbol = await usdcContract.symbol();
    const decimals = await usdcContract.decimals();
    console.log("USDC 1 symbol:", symbol, "decimals:", decimals);
  } catch (e) {
    console.log("USDC 1 error:", e.message);
  }

  // Bridged USDC
  const usdcBridged = "0x062E66477Faf219F25D27dCED647BF57C3107d52".toLowerCase();
  const usdcBridgedContract = new ethers.Contract(usdcBridged, erc20Abi, provider);
  try {
    const symbol = await usdcBridgedContract.symbol();
    const decimals = await usdcBridgedContract.decimals();
    console.log("USDC bridged symbol:", symbol, "decimals:", decimals);
  } catch (e) {
    console.log("USDC bridged error:", e.message);
  }

  // LZ Endpoint - The user says 30040. LZ V2 endpoint on Cronos.
  const lzEndpoint = "0x1a44076050125825900e736c501f859c50fE728c".toLowerCase(); // LZ_ENDPOINT_STANDARD
  const endpointAbi = ["function eid() view returns (uint32)"];
  const endpointContract = new ethers.Contract(lzEndpoint, endpointAbi, provider);
  try {
    const eid = await endpointContract.eid();
    console.log("LZ Endpoint eid:", eid);
  } catch (e) {
    console.log("LZ Endpoint error:", e.message);
  }
}

main().catch(console.error);
