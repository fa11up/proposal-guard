#!/usr/bin/env node
// Builds ProposalGuard's constructor arguments `questionHead` and `questionTail` from the oracle
// request template, by the same canonicalisation the IdentityMD control plane hashes.
//
//   node script/question-template.mjs question/template.json --governor 0x... --chain 11155111 [--sample <proposalId>]
//
// The plane hashes the question document
//   { v, question, chainId, window: {fromBlock, toBlock}, answerType, head?, definitions?, evidence? }
// canonicalised as an RFC 8785 subset: object keys sorted, JSON string escaping, integers only.
// Keys sort as answerType, chainId, definitions, evidence, question, v, window, so the proposal id
// (inside `question`) is the only varying text before the window, and the window is a pure suffix:
//
//   <HEAD>{proposalId}<TAIL>{fromBlock},"toBlock":{toBlock}}}
//
// The guard stores HEAD and TAIL and splices the id and the SIGNED window back in.
// Mirrors fa11up/infer-protocol oracle/question-prefix.mjs, which is verified against live hashes.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const canon = (v) => {
  if (v === null) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") {
    if (!Number.isInteger(v)) throw new Error("non-integer number");
    return JSON.stringify(v === 0 ? 0 : v);
  }
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canon).join(",")}]`;
  const keys = Object.keys(v).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(",")}}`;
};

const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const [path] = args;
const governor = opt("--governor");
const chain = opt("--chain");
if (!path || !governor || !chain) {
  console.error("usage: node script/question-template.mjs <template.json> --governor 0x.. --chain <id> [--sample <proposalId>]");
  process.exit(1);
}
if (!/^0x[0-9a-fA-F]{40}$/.test(governor)) throw new Error("--governor must be an address");

const fill = (s) => s.replaceAll("{{GOVERNOR}}", governor.toLowerCase()).replaceAll("{{CHAIN_ID}}", chain);
const input = JSON.parse(readFileSync(path, "utf8")).input;
const filled = JSON.parse(fill(JSON.stringify(input)));
filled.chainId = Number(chain);

const PLACEHOLDER = "{{PROPOSAL_ID}}";
const doc = (proposalId, from, to) => {
  const q = JSON.parse(JSON.stringify(filled).replaceAll(PLACEHOLDER, proposalId));
  return {
    v: 1,
    question: q.question,
    chainId: q.chainId,
    window: { fromBlock: from, toBlock: to },
    answerType: q.answerType,
    ...(q.definitions ? { definitions: q.definitions } : {}),
    ...(q.evidence === "panel" ? { evidence: "panel" } : {}),
  };
};

const marked = canon(doc(PLACEHOLDER, 1, 2));
const occurrences = marked.split(PLACEHOLDER).length - 1;
if (occurrences !== 1) throw new Error(`the proposal id must appear exactly once in the document (found ${occurrences})`);
const [head, rest] = marked.split(PLACEHOLDER);
const marker = ',"window":{"fromBlock":';
const at = rest.indexOf(marker);
if (at < 0) throw new Error("window key not found: canonicalisation changed");
const tail = rest.slice(0, at + marker.length);
if (`${head}${PLACEHOLDER}${tail}1,"toBlock":2}}` !== marked) throw new Error("splice does not reproduce the document");

const hex = (s) => "0x" + Buffer.from(s, "utf8").toString("hex");
const sample = opt("--sample");
const out = { questionHead: hex(head), questionTail: hex(tail), headBytes: head.length, tailBytes: tail.length };
if (sample) {
  const full = canon(doc(sample, 100, 200));
  out.sample = { proposalId: sample, fromBlock: 100, toBlock: 200, document: full, questionHash: execFileSync("cast", ["keccak", full], { encoding: "utf8" }).trim() };
}
console.log(JSON.stringify(out, null, 2));
