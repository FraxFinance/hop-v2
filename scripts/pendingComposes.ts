/**
 * pendingComposes.ts
 *
 * Lists the composes a hop has been credited for but not yet executed: every `ComposeSent` addressed to the hop
 * whose entry in the endpoint's compose queue is still the message hash. The endpoint overwrites a delivered
 * entry with 0x…01, so what is left is exactly the principal the hop holds on behalf of queued messages.
 *
 * Run before any admin action that a queued compose depends on (`recoverERC20` of an OFT token,
 * `setApprovedOft(oft, false)`, `setRemoteHop`, `pauseOn`), and to find the inputs for the endpoint-verified
 * `setMessageProcessed(oft, guid, index, message)` when a compose has to be retired. See README §6.7.
 *
 * Usage:
 *   pnpm pending-composes --rpc <url> --hop <address> --from-block <n> [--to-block <n>] [--chunk <n>] [--json]
 *
 * `--from-block` should be the block the hop proxy was deployed in (earlier is fine, only slower).
 * `--to-block` also pins the compose-queue reads, so a past block shows what was pending then.
 * `--chunk` defaults to 100000, the largest log range rpc.tempo.xyz accepts.
 * Exit code: 0 when nothing is pending, 2 when something is, 1 on error. Through `pnpm`, any non-zero code reads as 1.
 */
import { createPublicClient, http, parseAbi, parseAbiItem, getAddress, type Address, type Hex } from "viem";

const COMPOSE_SENT = parseAbiItem(
  "event ComposeSent(address from, address to, bytes32 guid, uint16 index, bytes message)",
);
const ABI = parseAbi([
  "function endpoint() view returns (address)",
  "function composeQueue(address from, address to, bytes32 guid, uint16 index) view returns (bytes32)",
]);
const DELIVERED = `0x${"0".repeat(63)}1`;
const EMPTY = `0x${"0".repeat(64)}`;

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
}

function required(name: string): string {
  const value = arg(name);
  if (!value) throw new Error(`missing --${name}`);
  return value;
}

/// OFTComposeMsgCodec layout: nonce (8) | srcEid (4) | amountLD (32) | composeFrom (32) | composeMsg
function decode(message: Hex) {
  const m = message.slice(2);
  return {
    nonce: BigInt(`0x${m.slice(0, 16)}`),
    srcEid: Number(`0x${m.slice(16, 24)}`),
    amountLD: BigInt(`0x${m.slice(24, 88)}`),
    composeFrom: `0x${m.slice(88, 152)}` as Hex,
  };
}

async function main() {
  const client = createPublicClient({ transport: http(required("rpc")) });
  const hop = getAddress(required("hop"));
  const fromBlock = BigInt(required("from-block"));
  const toBlock = arg("to-block") ? BigInt(arg("to-block")!) : await client.getBlockNumber();
  const chunk = BigInt(arg("chunk") ?? "100000");
  const endpoint = await client.readContract({
    address: hop,
    abi: ABI,
    functionName: "endpoint",
    blockNumber: toBlock,
  });

  const queued: { from: Address; guid: Hex; index: number; message: Hex; block: bigint; tx: Hex }[] = [];
  for (let start = fromBlock; start <= toBlock; start += chunk) {
    const end = start + chunk - 1n < toBlock ? start + chunk - 1n : toBlock;
    const logs = await client.getLogs({ address: endpoint, event: COMPOSE_SENT, fromBlock: start, toBlock: end });
    for (const log of logs) {
      if (getAddress(log.args.to!) !== hop) continue;
      queued.push({
        from: getAddress(log.args.from!),
        guid: log.args.guid!,
        index: log.args.index!,
        message: log.args.message!,
        block: log.blockNumber!,
        tx: log.transactionHash!,
      });
    }
  }

  const pending = [];
  for (const q of queued) {
    const entry = await client.readContract({
      address: endpoint,
      abi: ABI,
      functionName: "composeQueue",
      args: [q.from, hop, q.guid, q.index],
      blockNumber: toBlock,
    });
    if (entry === DELIVERED || entry === EMPTY) continue;
    pending.push({ oft: q.from, ...q, ...decode(q.message) });
  }

  console.error(
    `hop ${hop} endpoint ${endpoint} blocks ${fromBlock}-${toBlock}: ${queued.length} composes queued, ${pending.length} pending`,
  );
  if (process.argv.includes("--json")) {
    console.log(JSON.stringify(pending, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
  } else {
    for (const p of pending) {
      console.log(
        [
          `guid ${p.guid} index ${p.index}`,
          `  oft ${p.oft} srcEid ${p.srcEid} nonce ${p.nonce} amountLD ${p.amountLD}`,
          `  composeFrom ${p.composeFrom}`,
          `  queued in block ${p.block} tx ${p.tx}`,
          `  message ${p.message}`,
        ].join("\n"),
      );
    }
  }
  process.exitCode = pending.length > 0 ? 2 : 0;
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
