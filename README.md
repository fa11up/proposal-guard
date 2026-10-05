# proposal-guard

A governance guard that **cancels a proposal when an [IdentityMD](https://imd.fun) swarm panel
attests that the proposal contains a critical problem**, and does nothing otherwise.

> **Status: v0, unaudited, testnet only.** Read [`docs/DESIGN.md`](docs/DESIGN.md) first.

## What it does

```
anyone buys an oracle.request:  "Does proposal <id> on governor <G> contain a critical problem?"
        │  a panel of swarm agents answers; the service signs (EIP-712, bound to this guard)
        ▼
flag(proposalId, attestation, sig)   verifies the signature, answer == true, panel floors,
                                     and that the question is exactly this guard's, about this id
        ▼
cancel(targets, values, calldatas, descriptionHash)
        ├─ governor's proposal guardian  → cancels at any stage
        └─ timelock CANCELLER_ROLE       → cancels once queued
```

- **Cancel-only.** It cannot propose, vote, queue, execute or move funds. The worst case is a
  delayed proposal that can be re-proposed.
- **Fails open.** No attestation means governance proceeds exactly as it does today.
- **Only "critical" counts.** Buying clean answers does nothing; one critical answer from anyone
  is enough.
- **No fork.** It works with a standard OpenZeppelin Governor + TimelockController. Adopt it by
  granting it `CANCELLER_ROLE`, or by setting it as proposal guardian with
  `GovernorProposalGuardian`.

## Two things the original spec got wrong, fixed here

1. **The panel is asked about the proposal, never a report.** A question about a report lets
   anyone write a fake report and get a truthful "yes", which would let anyone censor any
   proposal for about $8.50. The only value spliced into the question is the proposal id, which
   commits to the exact calldata.
2. **The guard cannot block its own removal.** A proposal that only removes the guard can never be
   cancelled; the guard expires unless governance renews it; and it may cancel at most 3 proposals
   per 30 days. A compromised signing key can delay a few proposals, never freeze governance.

## Deploy

```bash
# 1. Build the question for your governor and chain
node script/question-template.mjs question/template.json --governor 0xYourGovernor --chain 1

# 2. Deploy ProposalGuard(governor, term, questionHead, questionTail) with the two hex values

# 3. Through governance, grant it one route:
#    timelock.grantRole(CANCELLER_ROLE, guard)     or     governor.setProposalGuardian(guard)

# 4. Check before buying a request: guard.expectedQuestionHash(id, from, to) must match the
#    hash of the document you are about to pay for.
```

## Test

```bash
git clone --recurse-submodules https://github.com/fa11up/proposal-guard
cd proposal-guard
forge test
```

22 tests against a real OpenZeppelin Governor + TimelockController: both cancel routes, the
fail-open baseline, both fixes end to end (including a compromised key failing to stop the guard's
removal through real governance), the rate limit and sunset, and a byte-for-byte check of the
on-chain question splice against the generator.

## Provenance

The design began as a spec written by a swarm agent, archived verbatim in
[`docs/SWARM-SPEC-2026-10-05.md`](docs/SWARM-SPEC-2026-10-05.md). The attestation verifier is the one
proven against a live production signature in [oracle-coop](https://github.com/fa11up/oracle-coop).

## License

MIT
