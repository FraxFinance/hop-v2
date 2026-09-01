/**
 * generateFeeMultipliers.ts
 *
 * Generates the FeeMultipliers for HopV201.setFeeMultipliersBatch() on every RemoteHop,
 * so that quoteHop() on a remote chain charges users what the FraxtalHop will actually
 * spend (in USD terms) on the Fraxtal => destination leg.
 *
 * Background: quoteHop() estimates the Fraxtal-leg executor fee by querying the LOCAL
 * chain's LZ Executor.getFee(dstEid, ...). But the fee actually paid is priced by the
 * FRAXTAL executor config for that dstEid (in FRAX). LZ's default executor on Fraxtal
 * carries route-specific floorMarginUSD values up to $3.00 (e.g. HyperEVM, Polygon, Sei,
 * Sonic, Solana) while the same destinations cost ~$0.02 from other chains, so the local
 * estimate can be off by >100x. The executor multiplier fixes this per (source, dst):
 *
 *   multiplier_bps = ceil( execFee_fraxtal(dst) * FRAXUSD * bufferBps
 *                        / (execFee_source(dst) * SRCUSD) )
 *
 * where both fees come from Executor.getFee() with the same options quoteHop() uses,
 * and both native USD prices come from each chain's LZ PriceFeed (the same oracle the
 * executors price with). DVN and treasury multipliers are left at 1x (10_000).
 *
 * Everything is read on-chain at runtime, so re-running refreshes the values.
 * Re-run whenever LZ pricing or the FRAX price moves materially (or on a schedule).
 *
 * Usage:
 *   npx tsx FeeMultipliers/generateFeeMultipliers.ts [options]
 *     --buffer-bps <n>      safety margin on the executor multiplier (default 10000 = exact,
 *                           e.g. 11000 = +10% to protect the float between refreshes)
 *     --dvn-bps <n>         dvn multiplier for all routes (default 10000)
 *     --treasury-bps <n>    treasury multiplier for all routes (default 10000)
 *     --lzreceive-gas <n>   lzReceive gas used in the getFee options (default 300000,
 *                           matching quoteHop()'s default executor options)
 *     --chains <a,b,c>      only generate for these source chains (default: all)
 *     --out <dir>           output directory (default out/feeMultipliers)
 *
 *   RPC override per chain: RPC_ETHEREUM=..., RPC_HYPEREVM=..., etc.
 *
 * Output:
 *   <out>/summary.csv           full (source, dst) table with USD costs and multipliers
 *   <out>/<chain>.json          eids[], FeeMultipliers[], and ready-to-submit calldata
 *                               for setFeeMultipliersBatch(uint32[],(uint64,uint64,uint64)[])
 */

import * as fs from "fs/promises";
import path from "path";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const BPS = 10_000n;

/// Default executor options used by HopV201.quoteHop() when executorOptions[eid] is unset:
/// worker id 01, size 0x11, option type 01 (lzReceive), gas uint128. Gas is patched in below.
const DEFAULT_LZRECEIVE_GAS = 300_000n; // 0x493E0, mirrors hex"01001101000000000000000000000000000493E0"

/// quoteHop() quotes with calldataSize = 360 + data.length; plain transfers have no data.
const CALLDATA_SIZE = 360n;

/// Hop sender addresses passed to Executor.getFee (executors may price-discriminate by sender)
const REMOTE_HOP_SENDER = "0x0000006D38568b00B457580b734e0076C62de659";
const FRAXTAL_HOP_SENDER = "0x00000000e18aFc20Afe54d4B2C8688bB60c06B36";

const FRAXTAL_EID = 30_255;

interface ChainConfig {
  name: string;
  chainId: number;
  eid: number;
  /** LZ default Executor (from https://metadata.layerzero-api.com/v1/metadata) */
  executor: string;
  rpcs: string[];
  /** Executor options stored by DeployRemoteHopV2 for this destination, when non-default */
  executorOptions?: string;
  /** dst-only chains (no EVM RemoteHop / no readable executor) are quoted as destinations only */
  dstOnly?: boolean;
  /** decimals of the native fee unit Executor.getFee() returns in (default 18; Tempo's native is 6) */
  nativeDecimals?: number;
  /** flagged chains get a warning in the output and should be reviewed manually */
  warn?: string;
}

/// Live frxUSD chains (matches HopConstants.sol + Solana as destination-only)
const CHAINS: ChainConfig[] = [
  {
    name: "Fraxtal",
    chainId: 252,
    eid: 30_255,
    executor: "0x41bdb4aa4a63a5b2efc531858d3118392b1a1c3d",
    rpcs: ["https://rpc.frax.com", "https://fraxtal.drpc.org"],
  },
  {
    name: "Ethereum",
    chainId: 1,
    eid: 30_101,
    executor: "0x173272739bd7aa6e4e214714048a9fe699453059",
    rpcs: ["https://ethereum-rpc.publicnode.com", "https://1rpc.io/eth"],
  },
  {
    name: "Abstract",
    chainId: 2741,
    eid: 30_324,
    executor: "0x643e1471f37c4680df30cf0c540cd379a0ff58a5",
    rpcs: ["https://api.mainnet.abs.xyz", "https://abstract.drpc.org"],
  },
  {
    name: "Arbitrum",
    chainId: 42_161,
    eid: 30_110,
    executor: "0x31cae3b7fb82d847621859fb1585353c5720660d",
    rpcs: ["https://arb1.arbitrum.io/rpc", "https://arbitrum-one-rpc.publicnode.com"],
  },
  {
    name: "Aurora",
    chainId: 1_313_161_554,
    eid: 30_211,
    executor: "0xa2b402ffe8dd7460a8b425644b6b9f50667f0a61",
    rpcs: ["https://mainnet.aurora.dev", "https://1rpc.io/aurora"],
  },
  {
    name: "Avalanche",
    chainId: 43_114,
    eid: 30_106,
    executor: "0x90e595783e43eb89ff07f63d27b8430e6b44bd9c",
    rpcs: ["https://api.avax.network/ext/bc/C/rpc", "https://avalanche-c-chain-rpc.publicnode.com"],
  },
  {
    name: "Base",
    chainId: 8453,
    eid: 30_184,
    executor: "0x2cca08ae69e0c44b18a57ab2a87644234daebae4",
    rpcs: ["https://mainnet.base.org", "https://base-rpc.publicnode.com"],
  },
  {
    name: "Berachain",
    chainId: 80_094,
    eid: 30_362,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://rpc.berachain.com", "https://berachain-rpc.publicnode.com"],
  },
  {
    name: "BSC",
    chainId: 56,
    eid: 30_102,
    executor: "0x3ebd570ed38b1b3b4bc886999fcf507e9d584859",
    rpcs: ["https://bsc-dataseed.bnbchain.org", "https://bsc-rpc.publicnode.com"],
  },
  {
    name: "HyperEVM",
    chainId: 999,
    eid: 30_367,
    executor: "0x41bdb4aa4a63a5b2efc531858d3118392b1a1c3d",
    rpcs: ["https://rpc.hyperliquid.xyz/evm", "https://rpc.hypurrscan.io", "https://hyperliquid.drpc.org"],
  },
  {
    name: "Ink",
    chainId: 57_073,
    eid: 30_339,
    executor: "0xfebcf17b11376c724ab5a5229803c6e838b6eae5",
    rpcs: ["https://rpc-gel.inkonchain.com", "https://rpc-qnd.inkonchain.com"],
  },
  {
    name: "Katana",
    chainId: 747_474,
    eid: 30_375,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://rpc.katana.network", "https://katana.drpc.org"],
  },
  {
    name: "Linea",
    chainId: 59_144,
    eid: 30_183,
    executor: "0x0408804c5dcd9796f22558464e6fe5bddf16a7c7",
    rpcs: ["https://rpc.linea.build", "https://linea-rpc.publicnode.com"],
  },
  {
    name: "Mode",
    chainId: 34_443,
    eid: 30_260,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://mainnet.mode.network", "https://1rpc.io/mode"],
  },
  {
    name: "Monad",
    chainId: 143,
    eid: 30_390,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://rpc.monad.xyz", "https://monad-rpc.publicnode.com"],
  },
  {
    name: "Optimism",
    chainId: 10,
    eid: 30_111,
    executor: "0x2d2ea0697bdbede3f01553d2ae4b8d0c486b666e",
    rpcs: ["https://mainnet.optimism.io", "https://optimism-rpc.publicnode.com"],
  },
  {
    name: "Plume",
    chainId: 98_866,
    eid: 30_370,
    executor: "0x41bdb4aa4a63a5b2efc531858d3118392b1a1c3d",
    rpcs: ["https://rpc.plume.org", "https://phoenix-rpc.plumenetwork.xyz"],
  },
  {
    name: "Polygon",
    chainId: 137,
    eid: 30_109,
    executor: "0xcd3f213ad101472e1713c72b1697e727c803885b",
    rpcs: ["https://polygon-rpc.com", "https://polygon-bor-rpc.publicnode.com"],
  },
  {
    name: "Robinhood",
    chainId: 4663,
    eid: 30_416,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://rpc.mainnet.chain.robinhood.com"],
  },
  {
    name: "Scroll",
    chainId: 534_352,
    eid: 30_214,
    executor: "0x581b26f362ad383f7b51ef8a165efa13dde398a4",
    rpcs: ["https://rpc.scroll.io", "https://scroll-rpc.publicnode.com"],
  },
  {
    name: "Sei",
    chainId: 1329,
    eid: 30_280,
    executor: "0xc097ab8cd7b053326dfe9fb3e3a31a0cce3b526f",
    rpcs: ["https://evm-rpc.sei-apis.com", "https://sei.drpc.org"],
  },
  {
    name: "Somnia",
    chainId: 5031,
    eid: 30_380,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://api.infra.mainnet.somnia.network"],
    executorOptions: defaultOptions(1_000_000n),
  },
  {
    name: "Sonic",
    chainId: 146,
    eid: 30_332,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://rpc.soniclabs.com", "https://sonic-rpc.publicnode.com"],
  },
  {
    name: "Stable",
    chainId: 988,
    eid: 30_396,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://rpc.stable.xyz"],
  },
  {
    name: "Tempo",
    chainId: 4217,
    eid: 30_410,
    executor: "0xf851abca1d0fd1df8eaba6de466a102996b7d7b2",
    rpcs: ["https://rpc.tempo.xyz", "https://tempo.drpc.org"],
    executorOptions: defaultOptions(2_500_000n),
    nativeDecimals: 6,
    warn: "Tempo native has 6 decimals (RemoteHopV201Tempo exists for a reason) - verify the computed multiplier against a live quote before submitting",
  },
  {
    name: "Unichain",
    chainId: 130,
    eid: 30_320,
    executor: "0x4208d6e27538189bb48e603d6123a94b8abe0a0b",
    rpcs: ["https://mainnet.unichain.org", "https://unichain-rpc.publicnode.com"],
  },
  {
    name: "Worldchain",
    chainId: 480,
    eid: 30_319,
    executor: "0xcce466a522984415bc91338c232d98869193d46e",
    rpcs: [
      "https://worldchain-mainnet.gateway.tenderly.co",
      "https://worldchain-mainnet.g.alchemy.com/public",
      "https://480.rpc.thirdweb.com",
      "https://worldchain.drpc.org",
    ],
  },
  {
    name: "XLayer",
    chainId: 196,
    eid: 30_274,
    executor: "0xcce466a522984415bc91338c232d98869193d46e",
    rpcs: [
      "https://rpc.xlayer.tech",
      "https://xlayerrpc.okx.com",
      "https://xlayer.drpc.org",
      "https://endpoints.omniatech.io/v1/xlayer/mainnet/public",
    ],
  },
  {
    name: "ZkSync",
    chainId: 324,
    eid: 30_165,
    executor: "0x664e390e672a811c12091db8426cbb7d68d5d8a6",
    rpcs: ["https://mainnet.era.zksync.io", "https://1rpc.io/zksync2-era"],
  },
  {
    name: "Solana",
    chainId: 0,
    eid: 30_168,
    executor: "",
    rpcs: [],
    dstOnly: true,
    executorOptions: "0x0100210100000000000000000000000000030d40000000000000000000000000002dc6c0",
  },
];

// ---------------------------------------------------------------------------
// Minimal ABI helpers (no dependencies)
// ---------------------------------------------------------------------------

const SEL_GET_FEE = "0x709eb664"; // getFee(uint32,address,uint256,bytes)
const SEL_PRICE_FEED = "0x741bef1a"; // priceFeed()
const SEL_NATIVE_PRICE = "0x92807f58"; // nativeTokenPriceUSD() -> uint128, 1e20 precision
const SEL_SET_BATCH = "0x4e5b8a9d"; // setFeeMultipliersBatch(uint32[],(uint64,uint64,uint64)[])

const word = (v: bigint | number): string => BigInt(v).toString(16).padStart(64, "0");
const addrWord = (a: string): string => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");

function encodeGetFee(dstEid: number, sender: string, calldataSize: bigint, options: string): string {
  const opts = options.replace(/^0x/, "");
  const padded = opts.padEnd(Math.ceil(opts.length / 64) * 64, "0");
  return (
    SEL_GET_FEE +
    word(dstEid) +
    addrWord(sender) +
    word(calldataSize) +
    word(0x80) + // offset of bytes
    word(opts.length / 2) +
    padded
  );
}

function defaultOptions(lzReceiveGas: bigint): string {
  // abi.encodePacked(worker id 01, option size 0x0011, option type 01, uint128 gas)
  return "0x" + "010011" + "01" + lzReceiveGas.toString(16).padStart(32, "0");
}

interface FeeMultipliers {
  dvn: bigint;
  executor: bigint;
  treasury: bigint;
}

function encodeSetFeeMultipliersBatch(eids: number[], mults: FeeMultipliers[]): string {
  if (eids.length !== mults.length) throw new Error("length mismatch");
  const n = eids.length;
  // head: two offsets
  const eidsOffset = 0x40;
  const multsOffset = eidsOffset + 0x20 + n * 0x20;
  let data = word(eidsOffset) + word(multsOffset);
  data += word(n);
  for (const e of eids) data += word(e);
  data += word(n);
  for (const m of mults) data += word(m.dvn) + word(m.executor) + word(m.treasury);
  return SEL_SET_BATCH + data;
}

// ---------------------------------------------------------------------------
// JSON-RPC with fallback
// ---------------------------------------------------------------------------

/** JSON-RPC errors meaning the call executed and reverted (vs transport/rate-limit failures) */
function isRevertError(err: unknown): boolean {
  if (!err || typeof err !== "object") return false;
  const e = err as { code?: number; message?: string };
  return e.code === 3 || (typeof e.message === "string" && /revert/i.test(e.message));
}

/**
 * eth_call batch with RPC fallback. Result slots: hex string = success, null = the
 * call itself reverted (or returned no data, e.g. no code at the address). A response
 * is only accepted if EVERY call was answered with a result or a revert - transport /
 * rate-limit errors on any slot move on to the next mode/RPC instead of letting a
 * flaky RPC masquerade as "pathway unsupported".
 */
async function rpcBatch(chain: ChainConfig, calls: { to: string; data: string }[]): Promise<(string | null)[]> {
  const envRpc = process.env[`RPC_${chain.name.toUpperCase().replace(/[^A-Z0-9]/g, "")}`];
  const rpcs = envRpc ? [envRpc, ...chain.rpcs] : chain.rpcs;
  const headers = { "Content-Type": "application/json", "User-Agent": "curl/8.7.1" };
  const payload = calls.map((c, i) => ({ jsonrpc: "2.0", id: i, method: "eth_call", params: [c, "latest"] }));
  for (const rpc of rpcs) {
    // 1st attempt: batched; 2nd attempt: sequential (some RPCs reject batches)
    for (const batched of [true, false]) {
      try {
        // undefined = unanswered (transport error), null = reverted, string = result
        const out: (string | null | undefined)[] = new Array(calls.length).fill(undefined);
        const record = (slot: number, r: { result?: unknown; error?: unknown }) => {
          if (typeof r.result === "string") out[slot] = r.result === "0x" ? null : r.result;
          else if (isRevertError(r.error)) out[slot] = null;
        };
        if (batched) {
          const res = await fetch(rpc, {
            method: "POST",
            headers,
            body: JSON.stringify(payload),
            signal: AbortSignal.timeout(25_000),
          });
          const json = await res.json();
          if (!Array.isArray(json)) continue;
          for (const r of json) {
            const id = Number(r?.id);
            if (Number.isInteger(id) && id >= 0 && id < calls.length) record(id, r);
          }
        } else {
          for (let i = 0; i < payload.length; i++) {
            const res = await fetch(rpc, {
              method: "POST",
              headers,
              body: JSON.stringify(payload[i]),
              signal: AbortSignal.timeout(15_000),
            });
            record(i, await res.json());
          }
        }
        if (out.every((v) => v !== undefined)) return out as (string | null)[];
        /* partially answered - try next mode / rpc */
      } catch {
        /* try next mode / rpc */
      }
    }
  }
  throw new Error(`${chain.name}: no RPC answered all ${calls.length} calls (tried ${rpcs.join(", ")})`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function arg(name: string, dflt: string): string {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return dflt;
  const v = process.argv[i + 1];
  if (v === undefined || v.startsWith("--")) throw new Error(`--${name} requires a value`);
  return v;
}

async function main() {
  const bufferBps = BigInt(arg("buffer-bps", "10000"));
  const dvnBps = BigInt(arg("dvn-bps", "10000"));
  const treasuryBps = BigInt(arg("treasury-bps", "10000"));
  const lzReceiveGas = BigInt(arg("lzreceive-gas", DEFAULT_LZRECEIVE_GAS.toString()));
  const outDir = arg("out", "out/feeMultipliers");
  const only = arg("chains", "")
    .split(",")
    .filter(Boolean)
    .map((s) => s.toLowerCase());

  const options = defaultOptions(lzReceiveGas);
  const fraxtal = CHAINS.find((c) => c.eid === FRAXTAL_EID)!;
  const sources = CHAINS.filter((c) => !c.dstOnly && c.eid !== FRAXTAL_EID).filter(
    (c) => only.length === 0 || only.includes(c.name.toLowerCase()),
  );
  // Destinations: every live chain except Fraxtal (quoteHop is never called for dst=Fraxtal)
  const dstsFor = (src: ChainConfig) => CHAINS.filter((c) => c.eid !== FRAXTAL_EID && c.eid !== src.eid);
  const allDsts = CHAINS.filter((c) => c.eid !== FRAXTAL_EID);

  // 1) Fraxtal side: executor fee (in FRAX wei) for every destination + FRAX USD price
  const fraxCalls = [
    { to: fraxtal.executor, data: SEL_PRICE_FEED },
    ...allDsts.map((d) => ({
      to: fraxtal.executor,
      data: encodeGetFee(d.eid, FRAXTAL_HOP_SENDER, CALLDATA_SIZE, d.executorOptions ?? options),
    })),
  ];
  const fraxRes = await rpcBatch(fraxtal, fraxCalls);
  const fraxFeedWord = fraxRes[0];
  if (!fraxFeedWord)
    throw new Error(
      `Fraxtal: priceFeed() returned nothing from executor ${fraxtal.executor} - check the executor address`,
    );
  const fraxPriceFeed = "0x" + fraxFeedWord.slice(-40);
  const [fraxPriceRes] = await rpcBatch(fraxtal, [{ to: fraxPriceFeed, data: SEL_NATIVE_PRICE }]);
  if (!fraxPriceRes)
    throw new Error(`Fraxtal: nativeTokenPriceUSD() returned nothing from price feed ${fraxPriceFeed}`);
  const fraxUsd = BigInt(fraxPriceRes); // 1e20 precision
  if (fraxUsd === 0n) throw new Error(`Fraxtal: price feed ${fraxPriceFeed} reports FRAX at $0`);
  const fraxFee = new Map<number, bigint>(); // eid -> fee in FRAX wei
  allDsts.forEach((d, i) => {
    const r = fraxRes[i + 1];
    if (r) fraxFee.set(d.eid, BigInt(r));
  });
  console.log(`Fraxtal: FRAX = $${Number(fraxUsd) / 1e20}, ${fraxFee.size}/${allDsts.length} destination fees quoted`);

  // 2) Each source chain: local executor fee for every destination + native USD price
  const summary: string[] = [
    "source,dstEid,dst,srcExecFeeNative,srcExecFeeUSD,fraxtalExecFeeFRAX,fraxtalExecFeeUSD,executorMultiplierBps,multiplierX",
  ];
  await fs.mkdir(outDir, { recursive: true });

  for (const src of sources) {
    const dsts = dstsFor(src);
    try {
      const calls = [
        { to: src.executor, data: SEL_PRICE_FEED },
        ...dsts.map((d) => ({
          to: src.executor,
          data: encodeGetFee(d.eid, REMOTE_HOP_SENDER, CALLDATA_SIZE, d.executorOptions ?? options),
        })),
      ];
      const res = await rpcBatch(src, calls);
      const feedWord = res[0];
      if (!feedWord)
        throw new Error(`priceFeed() returned nothing from executor ${src.executor} - check the executor address`);
      const priceFeed = "0x" + feedWord.slice(-40);
      const [priceRes] = await rpcBatch(src, [{ to: priceFeed, data: SEL_NATIVE_PRICE }]);
      if (!priceRes) throw new Error(`nativeTokenPriceUSD() returned nothing from price feed ${priceFeed}`);
      const srcUsd = BigInt(priceRes); // 1e20 precision
      if (srcUsd === 0n) throw new Error(`price feed ${priceFeed} reports the native token at $0`);

      const eids: number[] = [];
      const mults: FeeMultipliers[] = [];
      for (let i = 0; i < dsts.length; i++) {
        const d = dsts[i];
        const srcFeeRes = res[i + 1];
        const fFee = fraxFee.get(d.eid);
        if (!srcFeeRes || fFee === undefined) {
          const side = !srcFeeRes ? `${src.name}'s` : "Fraxtal's";
          console.warn(
            `  SKIP ${src.name} -> ${d.name} (eid ${d.eid}): ${side} executor getFee() reverted - ` +
              `pathway unsupported by the default executor, quoteHop() would revert there too`,
          );
          continue;
        }
        const sFee = BigInt(srcFeeRes);
        if (sFee === 0n) {
          console.warn(
            `  SKIP ${src.name} -> ${d.name} (eid ${d.eid}): local executor quoted a zero fee - cannot derive a multiplier`,
          );
          continue;
        }
        // multiplier = ceil(fraxtalFeeUSD * buffer / srcFeeUSD), in bps.
        // 10^nativeDecimals/1e18 rescales sources whose executor quotes in non-18-decimal native units.
        const dec = BigInt(src.nativeDecimals ?? 18);
        const num = fFee * fraxUsd * bufferBps * 10n ** dec;
        const den = sFee * srcUsd * 10n ** 18n;
        let m = (num + den - 1n) / den;
        if (m < 1n) m = 1n; // 0 means "unset = 1x" in the contract, never emit it
        eids.push(d.eid);
        mults.push({ dvn: dvnBps, executor: m, treasury: treasuryBps });
        summary.push(
          [
            src.name,
            d.eid,
            d.name,
            (Number(sFee) / 10 ** (src.nativeDecimals ?? 18)).toExponential(4),
            ((Number(sFee) / 10 ** (src.nativeDecimals ?? 18)) * (Number(srcUsd) / 1e20)).toFixed(6),
            (Number(fFee) / 1e18).toFixed(6),
            ((Number(fFee) / 1e18) * (Number(fraxUsd) / 1e20)).toFixed(6),
            m.toString(),
            (Number(m) / 10_000).toFixed(2),
          ].join(","),
        );
      }

      if (eids.length === 0) {
        console.warn(`${src.name}: all ${dsts.length} routes skipped - no output written`);
        continue;
      }
      const calldata = encodeSetFeeMultipliersBatch(eids, mults);
      const file = {
        chain: src.name,
        chainId: src.chainId,
        eid: src.eid,
        generatedAt: new Date().toISOString(),
        params: {
          bufferBps: bufferBps.toString(),
          dvnBps: dvnBps.toString(),
          treasuryBps: treasuryBps.toString(),
          lzReceiveGas: lzReceiveGas.toString(),
        },
        nativeUsd: (Number(srcUsd) / 1e20).toString(),
        fraxUsd: (Number(fraxUsd) / 1e20).toString(),
        warn: src.warn,
        eids,
        multipliers: mults.map((m) => ({
          dvn: m.dvn.toString(),
          executor: m.executor.toString(),
          treasury: m.treasury.toString(),
        })),
        setFeeMultipliersBatchCalldata: calldata,
      };
      await fs.writeFile(path.join(outDir, `${src.name}.json`), JSON.stringify(file, null, 2));
      const top = [...mults]
        .map((m, i) => ({ e: eids[i], x: Number(m.executor) / 10_000 }))
        .sort((a, b) => b.x - a.x)[0];
      console.log(
        `${src.name.padEnd(11)} native=$${(Number(srcUsd) / 1e20).toFixed(4)} routes=${eids.length}` +
          ` maxExecMult=${top.x.toFixed(1)}x (eid ${top.e})` +
          (src.warn ? `  !! ${src.warn}` : ""),
      );
    } catch (e) {
      console.error(`ERROR ${src.name}: ${(e as Error).message} - no output written`);
    }
  }

  await fs.writeFile(path.join(outDir, "summary.csv"), summary.join("\n"));
  console.log(`\nWrote ${outDir}/summary.csv and per-chain JSON (eids, multipliers, batch calldata).`);
  console.log(`Submit each chain's calldata to its RemoteHop via the admin (setFeeMultipliersBatch).`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
