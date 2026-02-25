#!/usr/bin/env node
// Toggles Hyperliquid big blocks on/off for the GCP signer via the L1 evmUserModify action.
// Usage: node scripts/hl-big-blocks.mjs [true|false]

import { execSync } from "child_process";

const ENABLE = process.argv[2] !== "false";
const GCP_ADDRESS = "0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC";
const HL_API = "https://api.hyperliquid.xyz/exchange";
const IS_MAINNET = true;

// --- minimal msgpack encoder (no external deps) ---
function encodeStr(s) {
    const b = Buffer.from(s, "utf8");
    if (b.length <= 31) return Buffer.concat([Buffer.from([0xa0 | b.length]), b]);
    if (b.length <= 0xff) return Buffer.concat([Buffer.from([0xd9, b.length]), b]);
    throw new Error("string too long");
}
function msgpackEncode(obj) {
    const keys = Object.keys(obj);
    const parts = [Buffer.from([0x80 | keys.length])];
    for (const k of keys) {
        parts.push(encodeStr(k));
        const v = obj[k];
        if (typeof v === "string") parts.push(encodeStr(v));
        else if (typeof v === "boolean") parts.push(Buffer.from([v ? 0xc3 : 0xc2]));
        else throw new Error("unsupported msgpack type: " + typeof v);
    }
    return Buffer.concat(parts);
}

function castKeccak(hex) {
    return execSync(`cast keccak ${hex}`).toString().trim();
}

// --- compute connectionId: keccak256(msgpack(action) ++ nonce_8be ++ 0x00) ---
const action = { type: "evmUserModify", usingBigBlocks: ENABLE };
const nonce = Date.now();
const actionBytes = msgpackEncode(action);
const nonceBytes = Buffer.alloc(8);
nonceBytes.writeBigUInt64BE(BigInt(nonce));
const preimage = Buffer.concat([actionBytes, nonceBytes, Buffer.from([0x00])]);
const connectionId = castKeccak("0x" + preimage.toString("hex"));

// --- EIP-712 typed data hash ---
// domain: { name: "Exchange", version: "1", chainId: 1337, verifyingContract: 0x000...0 }
// type: Agent(string source, bytes32 connectionId)
const source = IS_MAINNET ? "a" : "b";

const ETHERS = '/home/carter/Documents/frax/hop-v2/node_modules/.pnpm/ethers@5.8.0/node_modules/ethers/lib/index.js';
const { utils } = await import(ETHERS);

const domain = {
    name: "Exchange",
    version: "1",
    chainId: 1337,
    verifyingContract: "0x0000000000000000000000000000000000000000",
};
const types = {
    Agent: [
        { name: "source", type: "string" },
        { name: "connectionId", type: "bytes32" },
    ],
};
const message = { source, connectionId };

const digest = utils._TypedDataEncoder.hash(domain, types, message);

console.log(`Action: evmUserModify { usingBigBlocks: ${ENABLE} }`);
console.log(`Nonce:  ${nonce}`);
console.log(`Digest: ${digest}`);

// --- sign with GCP key (--no-hash signs raw bytes, no eth_sign prefix) ---
const sigHex = execSync(
    `cast wallet sign --gcp --from ${GCP_ADDRESS} --no-hash ${digest}`
).toString().trim();

console.log(`Sig:    ${sigHex}`);

// --- verify recovery locally before posting ---
const recovered = utils.recoverAddress(digest, sigHex);
if (recovered.toLowerCase() !== GCP_ADDRESS.toLowerCase()) {
    console.error(`ERROR: recovered ${recovered}, expected ${GCP_ADDRESS}`);
    process.exit(1);
}
console.log(`Recovered: ${recovered} ✓`);

// parse r, s, v
const sigBuf = Buffer.from(sigHex.replace("0x", ""), "hex");
const r = "0x" + sigBuf.slice(0, 32).toString("hex");
const s = "0x" + sigBuf.slice(32, 64).toString("hex");
const v = sigBuf[64];

// --- POST to Hyperliquid exchange ---
const body = JSON.stringify({ action, nonce, signature: { r, s, v } });
console.log(`\nPosting to ${HL_API}...`);
const resp = execSync(`curl -s -X POST ${HL_API} -H 'Content-Type: application/json' -d '${body}'`).toString();
console.log(`Response: ${resp}`);
