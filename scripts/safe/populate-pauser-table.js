const fs=require("fs"),path=require("path");
const C=path.join(__dirname,"..","..","deployments"); // contracts repo deployments
const LPA="/home/dominique/Projets/magneta-finance-tokens/contracts/solidity/deployments-lp-atomic";
const GUARD="0x92F440Bc1f1FaBD6D3e6256491631E07857F4260";
const MAIN="0xC4c96aF54cdE078dc993d6948199b0AF8cD6717a",LEGACY="0x4AeA3A398Db41b45e146c08131aD27c75b02EC2F",INH="0x40ea2908Ea490d58E62D1Fd3364464D8A857b297";
const safeOf={arbitrum:LEGACY,polygon:LEGACY,abstract:INH,flare:INH,sei:INH,cronos:INH};
// curve factories recorded this wave (fallback if not in JSON)
const curveFallback={cronos:"0x5588Cd99E28518D13A316996dc0D4351afAe4D4a",monad:"0x5B7c12A4685b45e40326F42123128f05E756E76D",bsc:"0x0e09fd3f18B66F2750A0Aa0B8bB6365fcE5f6B60",mantle:"0x5B7c12A4685b45e40326F42123128f05E756E76D",katana:"0xD91aF46F947a783B68D40137a2526C25d6067927"};
const chains=["arbitrum","avalanche","base","bsc","celo","flare","gnosis","linea","mantle","optimism","polygon","sei","berachain","katana","monad","plasma","sonic","unichain","abstract","cronos"];
const out={_README:["Auto-populated from deployment JSONs (redeploy wave 2026-07). relayer='' → Defender not yet provisioned, skipped by generator."],chains:{}};
for(const n of chains){
 const f=path.join(C,n+".json");
 if(!fs.existsSync(f)){console.log("MANQUE deployments/"+n+".json");continue;}
 const d=JSON.parse(fs.readFileSync(f));const c=d.contracts||{};
 let lpAtomic="";const laf=path.join(LPA,n+".json");
 if(fs.existsSync(laf)){const la=JSON.parse(fs.readFileSync(laf));lpAtomic=la.address||la.MagnetaLpAtomicHelper||la.helper||"";}
 out.chains[String(d.chainId)]={network:n,safe:safeOf[n]||MAIN,guardian:GUARD,relayer:"",contracts:{
  gateway:c.MagnetaGateway||"",swap:c.MagnetaSwap||"",factory:c.MagnetaFactory||"",pool:c.MagnetaPool||"",
  bundler:c.MagnetaBundler||"",proxy:"",lpModule:c.LPModule||"",swapModule:c.SwapModule||"",
  taxClaimModule:c.TaxClaimModule||"",tokenOpsModule:c.TokenOpsModule||"",lpAtomicModule:lpAtomic,
  curveFactory:c.MagnetaCurveFactory||curveFallback[n]||"",curvePool:"",bridge:c.MagnetaBridgeOApp||""}};
}
fs.writeFileSync(path.join(__dirname,"pauser-addresses.json"),JSON.stringify(out,null,2));
console.log("pauser-addresses.json généré —",Object.keys(out.chains).length,"chaînes");
// summary of filled contracts per chain
for(const [id,ch] of Object.entries(out.chains)){const filled=Object.values(ch.contracts).filter(x=>x&&x!=="").length;console.log(" ",ch.network.padEnd(10),"safe",ch.safe.slice(0,6),"| contrats remplis:",filled);}
