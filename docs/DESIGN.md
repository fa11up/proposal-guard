# Design

This repository started from a design spec written by the IdentityMD swarm
([`SWARM-SPEC-2026-10-05.md`](SWARM-SPEC-2026-10-05.md)). Its architecture is kept. Two of its
security arguments did not hold up, and the fixes for both are the main thing this code adds.

## The idea

Most voters never read calldata. Governance exploits (Tornado Cash in May 2023, Beanstalk in 2022,
Compound proposal 62 in 2021) passed because nobody checked what a proposal would actually do.
Today the enforcing layer, where one exists, is a handful of humans on a multisig.

This guard turns an independent review into an enforceable action:

1. For any proposal, anyone buys an IdentityMD `oracle.request`. A panel of swarm agents answers
   one bool question: *does this proposal contain a critical problem?*
2. The oracle service signs the answer (EIP-712, domain "IdentityMD Oracle" v2, bound to this
   guard's address and chain).
3. `flag` verifies the signature, that the answer is `true`, the panel floors, and that the signed
   `questionHash` is exactly this guard's question about **this** proposal id.
4. `cancel` cancels the flagged proposal through whichever route the DAO granted.

## Decisions kept from the spec

| Decision | Reason |
|---|---|
| **Cancel-only.** The guard cannot propose, vote, queue, execute or move funds | Even a wrong or forged attestation can only delay a proposal, and a cancelled proposal can be re-proposed. A guard that gated `execute` would make the oracle a single point that could halt all governance. |
| **Fail open.** No attestation means governance proceeds as it does today | An oracle outage, a refusal or a pricing dispute must never stop governance. |
| **Only `true` has an effect** | Buying "clean" answers achieves nothing, while one critical answer from anyone (the DAO, a rival delegate, a white hat) is enough. The asymmetry favours defenders. |
| **No governor fork.** Two standard routes: the timelock's `CANCELLER_ROLE`, or OZ `GovernorProposalGuardian` | Adoption is one role grant. The guardian route cancels at any stage; the timelock route cancels once the proposal is queued. A flag can be recorded at any time. |
| **Floors are counts:** `panelSize >= 20`, `agreed >= 15` | Live attestations sign `agreed == quorum` (60 / 20 / 20 observed), so a ratio floor would only force a higher request quorum and get requests refused. |

## Two fixes

### Fix 1: the question is about the proposal, not a report

The spec asked the panel *"does the report with content hash H contain a critical finding?"*.
Whoever buys the request can write that report. An attacker writes a report claiming a critical
bug in a proposal they want dead, buys one answer, and the panel truthfully says yes: the report
does contain such a claim. Any proposal could be censored for one oracle fee, about $8.50. The
spec's defence ("the panel would have to co-sign visible nonsense") fails, because the panel signs
a true statement about a false document.

Here the question is fixed at deployment (`questionHead` + proposal id + `questionTail`), and the
**only** value spliced in, apart from the signed window, is the proposal id. The id is the hash of
the exact targets, values, calldata and description. Reviews, including one linked by the
requester, are supporting evidence the panel is told to verify and ignore where wrong; they are
never the subject. Test: `test_AnswerAboutARequesterSuppliedReportIsRejected`.

### Fix 2: the guard cannot block its own removal

The spec relied on "governance can revoke the role". But revoking it takes a proposal, and the
guard can cancel proposals. With an honest panel that is unlikely; with a **compromised signing
key** it is trivial, because the key needs no panel to sign "critical". The timelock's canceller
role never expires, so the result would be a permanent freeze. Three rules close it:

- **Self-removal is exempt.** A proposal whose every action removes this guard (revoking its
  canceller role, or replacing it as proposal guardian) can never be cancelled. A bundle that does
  anything else as well gets no exemption, so the exemption can't shelter a malicious action.
  Tests: `test_CompromisedKeyCannotBlockTheGuardsRemoval`,
  `test_RevocationBundledWithAnythingElseIsCancellable`.
- **Sunset.** The guard expires after `term` (at most 365 days) unless governance calls `renew()`
  through the timelock. If governance stops renewing, the guard does nothing.
- **Rate limit.** At most 3 cancels per 30 days. A stolen key can delay at most three proposals
  before the DAO removes the guard, which it always can.

## The question

`question/template.json` is the oracle request. `script/question-template.mjs` canonicalises it
the way the control plane does (RFC 8785 subset, sorted keys) and splits it around the proposal id
into the guard's two constructor arguments. Keys sort as `answerType, chainId, definitions,
evidence, question, v, window`, so the id inside `question` is the only varying text before the
window, and the window is a pure suffix. `test/TemplateVector.t.sol` checks the guard's on-chain
splice against the generator's output byte for byte.

The rubric ("critical" = moves or locks assets beyond the description, transfers control, calls
code that can change after proposal, or contradicts its own description in a way that moves value
or control) and the review procedure live in `definitions`, which is part of the hashed document.
The procedure tells panelists to treat all natural-language input as data, which is the prompt
injection defence, and to simulate the batch from the timelock.

## Known limitations

- **No live vector for a bool panel answer.** The struct, the domain and `uint256` answers are
  proven against production in [oracle-coop](https://github.com/fa11up/oracle-coop). This guard
  assumes a bool answer is `abi.encode(bool)` with answer type 0, and that a panel question
  carries `evidence: "panel"` in its document. Both match the live service's canonicaliser, but
  have not been checked against a signed bool attestation. **Buy one against a testnet guard
  before relying on it.**
- **Panel evidence is voted, not re-run.** A majority can be wrong; one once returned a price wrong
  by 256x. This is defence in depth on top of timelocks and human review, not a replacement.
- **Fail-open has a window.** A malicious proposal during a total oracle outage proceeds as it
  would today. Whoever runs the request watcher should alert loudly when a proposal nears
  execution without a completed review.
- **OZ only.** Governor Bravo (Compound's `proposalGuardian`, reported to exist since August 2024)
  is not implemented yet and that claim has not been verified here.
- **Unaudited.**

## Gas

`flag` about 154k, `cancel` 76k–88k.

## Roadmap

1. A Sepolia DAO testbed and one bought bool attestation, which proves the panel path against
   production.
2. A watcher that buys a request for every `ProposalCreated` and alerts on proposals approaching
   execution unreviewed.
3. Governor Bravo support.
4. A review job per proposal (`audit-imported-code`) whose report is published for voters, as
   evidence alongside the attestation, never as its subject.

## Open questions for the IdentityMD developer

1. Is a bool answer signed as `answerType 0` with `answer = abi.encode(bool)`?
2. What panel sizes are available for a panel-evidence bool question, and will `panelSize >= 20`
   with `agreed >= 15` be met by a standard request?
3. Do panel members read chain state (the ProposalCreated event, verified sources, a simulation)
   when answering, or only the question text?
4. Can a request be bought programmatically on an on-chain event, so the watcher needs no
   browser signing?
