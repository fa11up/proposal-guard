// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ProposalGuard, IGovernorLike} from "../src/ProposalGuard.sol";
import {VotesToken, TimelockGovernor, GuardianGovernor} from "./testbed/Testbed.sol";

/// @dev Signs with a test key. A deployed guard trusts only the service key.
contract GuardHarness is ProposalGuard {
    address private immutable _signer;

    constructor(address signer_, IGovernorLike governor_, uint256 term_, bytes memory head_, bytes memory tail_)
        ProposalGuard(governor_, term_, head_, tail_)
    {
        _signer = signer_;
    }

    function _attester() internal view override returns (address) {
        return _signer;
    }
}

contract ProposalGuardTest is Test {
    uint256 constant SIGNER_PK = 0xA11CE;
    uint256 constant TERM = 180 days;
    uint256 constant DELAY = 1 days;

    bytes constant HEAD = '{"answerType":"bool","chainId":31337,"evidence":"panel","question":"Is proposal ';
    bytes constant TAIL = ' critical?","v":1,"window":{"fromBlock":';

    address voter = makeAddr("voter");
    address attacker = makeAddr("attacker");
    VotesToken token;
    TimelockController timelock;
    TimelockGovernor governor;
    GuardHarness guard;
    uint256 nonce;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        token = new VotesToken(voter);
        vm.prank(voter);
        token.delegate(voter);
        vm.prank(voter);
        token.transfer(address(this), 100_000e18);

        (timelock, governor) = _deployGovernance(false);
        guard = _deployGuard(governor);
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(guard));
        vm.roll(block.number + 1);
    }

    // ------------------------------------------------------------------ helpers

    function _deployGovernance(bool withGuardian) internal returns (TimelockController tl, TimelockGovernor gov) {
        address[] memory none = new address[](0);
        address[] memory anyone = new address[](1); // address(0) = open executor role
        tl = new TimelockController(DELAY, none, anyone, address(this));
        gov = withGuardian ? TimelockGovernor(new GuardianGovernor(token, tl)) : new TimelockGovernor(token, tl);
        tl.grantRole(tl.PROPOSER_ROLE(), address(gov));
        tl.grantRole(tl.CANCELLER_ROLE(), address(gov));
        token.transfer(address(tl), 50_000e18); // a treasury worth stealing
    }

    function _deployGuard(TimelockGovernor gov) internal returns (GuardHarness g) {
        g = new GuardHarness(vm.addr(SIGNER_PK), IGovernorLike(address(gov)), TERM, HEAD, TAIL);
    }

    struct P {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        uint256 id;
    }

    function _one(address target, bytes memory data, string memory description) internal pure returns (P memory p) {
        p.targets = new address[](1);
        p.values = new uint256[](1);
        p.calldatas = new bytes[](1);
        p.targets[0] = target;
        p.calldatas[0] = data;
        p.description = description;
    }

    function _drain(string memory description) internal view returns (P memory) {
        return _one(address(token), abi.encodeCall(token.transfer, (attacker, 50_000e18)), description);
    }

    function _revokeGuard(string memory description) internal view returns (P memory) {
        return _one(
            address(timelock),
            abi.encodeCall(timelock.revokeRole, (timelock.CANCELLER_ROLE(), address(guard))),
            description
        );
    }

    function _propose(TimelockGovernor gov, P memory p) internal returns (P memory) {
        vm.prank(voter);
        p.id = gov.propose(p.targets, p.values, p.calldatas, p.description);
        return p;
    }

    function _passAndQueue(TimelockGovernor gov, P memory p) internal returns (P memory) {
        p = _propose(gov, p);
        vm.roll(block.number + 2);
        vm.prank(voter);
        gov.castVote(p.id, 1);
        vm.roll(block.number + 51);
        gov.queue(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
        return p;
    }

    function _execute(TimelockGovernor gov, P memory p) internal {
        vm.warp(block.timestamp + DELAY + 1);
        gov.execute(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
    }

    function _att(GuardHarness g, uint256 proposalId, bool critical)
        internal
        returns (ProposalGuard.Attestation memory a)
    {
        uint64 to = uint64(block.number);
        a = ProposalGuard.Attestation({
            requestId: keccak256(abi.encode("req", ++nonce)),
            chainId: block.chainid,
            questionHash: g.expectedQuestionHash(proposalId, to - 10, to),
            answerType: 0,
            answer: abi.encode(critical),
            figure: critical ? 1 : 0,
            fromBlock: to - 10,
            toBlock: to,
            blockHash: blockhash(to - 1),
            panelJobId: keccak256(abi.encode("job", nonce)),
            panelSize: 60,
            quorum: 20,
            agreed: 20,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function _sign(GuardHarness g, ProposalGuard.Attestation memory a, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, g.digest(a));
        return abi.encodePacked(r, s, v);
    }

    function _flag(GuardHarness g, uint256 proposalId) internal {
        ProposalGuard.Attestation memory a = _att(g, proposalId, true);
        g.flag(proposalId, a, _sign(g, a, SIGNER_PK));
    }

    /// @dev Signs BEFORE arming expectRevert: signing calls g.digest(), which would consume it.
    function _flagExpecting(uint256 proposalId, ProposalGuard.Attestation memory a, bytes memory err) internal {
        bytes memory sig = _sign(guard, a, SIGNER_PK);
        vm.expectRevert(err);
        guard.flag(proposalId, a, sig);
    }

    /// @dev Through a real proposal: OZ's onlyGovernance only accepts calls the governor itself queued.
    function _setGuardian(TimelockGovernor gov, GuardHarness g) internal {
        P memory p = _passAndQueue(
            gov, _one(address(gov), abi.encodeWithSignature("setProposalGuardian(address)", address(g)), "Set guardian")
        );
        _execute(gov, p);
        assertEq(GuardianGovernor(payable(address(gov))).proposalGuardian(), address(g));
    }

    function _cancel(GuardHarness g, P memory p) internal {
        g.cancel(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
    }

    // ------------------------------------------------------------------ the core path

    function test_CriticalAttestationCancelsQueuedProposal() public {
        P memory p = _passAndQueue(governor, _drain("Donate to a good cause"));
        _flag(guard, p.id);
        _cancel(guard, p);

        assertEq(uint256(governor.state(p.id)), uint256(IGovernor.ProposalState.Canceled));
        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert();
        governor.execute(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_FlagDuringVotingThenCancelOnceQueued() public {
        P memory p = _propose(governor, _drain("Routine upkeep"));
        _flag(guard, p.id); // flagged while Pending
        vm.roll(block.number + 2);
        vm.prank(voter);
        governor.castVote(p.id, 1);
        vm.roll(block.number + 51);
        governor.queue(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
        _cancel(guard, p);
        assertEq(uint256(governor.state(p.id)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_GuardianRouteCancelsAtAnyStage() public {
        (TimelockController tl, TimelockGovernor gov) = _deployGovernance(true);
        GuardHarness g = _deployGuard(gov);
        _setGuardian(gov, g);
        vm.roll(block.number + 1);

        P memory p = _propose(gov, _one(address(token), abi.encodeCall(token.transfer, (attacker, 1)), "x"));
        _flag(g, p.id);
        g.cancel(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
        assertEq(uint256(gov.state(p.id)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_NoAttestationMeansGovernanceProceeds() public {
        P memory p = _passAndQueue(governor, _drain("Pay the grant"));
        _execute(governor, p);
        assertEq(token.balanceOf(attacker), 50_000e18);
    }

    // ------------------------------------------------------------------ fix 1: the subject is the proposal

    /// @notice A clean answer has no effect, so buying many of them achieves nothing.
    function test_CleanAnswerIsInert() public {
        P memory p = _propose(governor, _drain("a"));
        _flagExpecting(p.id, _att(guard, p.id, false), abi.encodeWithSelector(ProposalGuard.NotCritical.selector));
    }

    function test_AnswerAboutAnotherProposalIsRejected() public {
        P memory a = _propose(governor, _drain("a"));
        P memory b = _propose(governor, _drain("b"));
        ProposalGuard.Attestation memory att = _att(guard, a.id, true);
        _flagExpecting(
            b.id,
            att,
            abi.encodeWithSelector(
                ProposalGuard.WrongQuestion.selector,
                guard.expectedQuestionHash(b.id, att.fromBlock, att.toBlock),
                att.questionHash
            )
        );
    }

    /// @notice The spec's flaw: a question about a requester-supplied report. Such a document hashes to
    /// something else, so a genuine critical answer about the attacker's fabricated report is refused.
    function test_AnswerAboutARequesterSuppliedReportIsRejected() public {
        P memory p = _propose(governor, _one(address(token), abi.encodeCall(token.approve, (voter, 1)), "benign"));
        ProposalGuard.Attestation memory att = _att(guard, p.id, true);
        att.questionHash = keccak256(
            bytes.concat(
                '{"answerType":"bool","chainId":31337,"evidence":"panel","question":"Does report 0xfab1ed for proposal ',
                bytes(vm.toString(p.id)),
                ' contain a critical finding?","v":1,"window":{"fromBlock":',
                bytes(vm.toString(att.fromBlock)),
                ',"toBlock":',
                bytes(vm.toString(att.toBlock)),
                "}}"
            )
        );
        bytes32 expected = guard.expectedQuestionHash(p.id, att.fromBlock, att.toBlock);
        _flagExpecting(
            p.id, att, abi.encodeWithSelector(ProposalGuard.WrongQuestion.selector, expected, att.questionHash)
        );
    }

    // ------------------------------------------------------------------ verification

    function test_RejectsWrongSigner() public {
        P memory p = _propose(governor, _drain("a"));
        ProposalGuard.Attestation memory att = _att(guard, p.id, true);
        bytes memory sig = _sign(guard, att, 0xBAD);
        vm.expectRevert(ProposalGuard.InvalidSignature.selector);
        guard.flag(p.id, att, sig);
    }

    function test_RejectsSignatureForAnotherGuard() public {
        GuardHarness other = _deployGuard(governor);
        P memory p = _propose(governor, _drain("a"));
        ProposalGuard.Attestation memory att = _att(guard, p.id, true);
        bytes memory sigForOther = _sign(other, att, SIGNER_PK);
        vm.expectRevert(ProposalGuard.InvalidSignature.selector);
        guard.flag(p.id, att, sigForOther);
    }

    function test_PanelFloorsAreCounts() public {
        P memory p = _propose(governor, _drain("a"));
        ProposalGuard.Attestation memory att = _att(guard, p.id, true);
        att.panelSize = 19;
        _flagExpecting(p.id, att, abi.encodeWithSelector(ProposalGuard.PanelTooSmall.selector));
        att = _att(guard, p.id, true);
        att.agreed = 14;
        _flagExpecting(p.id, att, abi.encodeWithSelector(ProposalGuard.NotEnoughAgreement.selector));
        att = _att(guard, p.id, true); // 20 of 60 agreeing: a 33% "ratio", and accepted
        bytes memory sig = _sign(guard, att, SIGNER_PK);
        guard.flag(p.id, att, sig);
    }

    function test_RejectsReplayAcrossProposals() public {
        P memory a = _propose(governor, _drain("a"));
        P memory b = _propose(governor, _drain("b"));
        ProposalGuard.Attestation memory att = _att(guard, a.id, true);
        guard.flag(a.id, att, _sign(guard, att, SIGNER_PK));
        att.questionHash = guard.expectedQuestionHash(b.id, att.fromBlock, att.toBlock);
        _flagExpecting(b.id, att, abi.encodeWithSelector(ProposalGuard.ReplayedAttestation.selector));
    }

    function test_RejectsExpiredWrongChainWrongTypeAndUnknown() public {
        P memory p = _propose(governor, _drain("a"));
        ProposalGuard.Attestation memory att = _att(guard, p.id, true);
        att.expiresAt = uint64(block.timestamp - 1);
        _flagExpecting(p.id, att, abi.encodeWithSelector(ProposalGuard.ExpiredAttestation.selector));

        att = _att(guard, p.id, true);
        att.chainId = 1;
        _flagExpecting(p.id, att, abi.encodeWithSelector(ProposalGuard.WrongDataChain.selector));

        att = _att(guard, p.id, true);
        att.answerType = 3;
        _flagExpecting(p.id, att, abi.encodeWithSelector(ProposalGuard.WrongAnswerType.selector));

        att = _att(guard, 12345, true);
        _flagExpecting(12345, att, abi.encodeWithSelector(ProposalGuard.UnknownProposal.selector, 12345));
    }

    function test_CannotCancelUnflagged() public {
        P memory p = _passAndQueue(governor, _drain("a"));
        vm.expectRevert(abi.encodeWithSelector(ProposalGuard.NotFlagged.selector, p.id));
        _cancel(guard, p);
    }

    // ------------------------------------------------------------------ fix 2: the guard can always be removed

    /// @notice A compromised key signs "critical" about the proposal that revokes the guard. The guard
    /// still refuses to cancel it, governance removes the guard, and the guard is powerless after.
    function test_CompromisedKeyCannotBlockTheGuardsRemoval() public {
        P memory removal = _passAndQueue(governor, _revokeGuard("Remove the guard"));
        _flag(guard, removal.id);
        vm.expectRevert(abi.encodeWithSelector(ProposalGuard.ProposalRemovesGuard.selector, removal.id));
        _cancel(guard, removal);

        _execute(governor, removal);
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(guard)));

        P memory next = _passAndQueue(governor, _drain("After removal"));
        _flag(guard, next.id);
        vm.expectRevert(); // AccessControlUnauthorizedAccount: the guard no longer holds the role
        _cancel(guard, next);
    }

    function test_ReplacingTheGuardianCannotBeCancelled() public {
        (TimelockController tl, TimelockGovernor gov) = _deployGovernance(true);
        GuardHarness g = _deployGuard(gov);
        _setGuardian(gov, g);
        vm.roll(block.number + 1);

        P memory p =
            _propose(gov, _one(address(gov), abi.encodeWithSignature("setProposalGuardian(address)", address(0)), "x"));
        _flag(g, p.id);
        vm.expectRevert(abi.encodeWithSelector(ProposalGuard.ProposalRemovesGuard.selector, p.id));
        g.cancel(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
    }

    /// @notice The exemption cannot shelter a malicious action bundled with a revocation.
    function test_RevocationBundledWithAnythingElseIsCancellable() public {
        P memory p = _revokeGuard("Remove the guard and pay a friend");
        address[] memory t = new address[](2);
        uint256[] memory v = new uint256[](2);
        bytes[] memory c = new bytes[](2);
        (t[0], c[0]) = (p.targets[0], p.calldatas[0]);
        (t[1], c[1]) = (address(token), abi.encodeCall(token.transfer, (attacker, 50_000e18)));
        p.targets = t;
        p.values = v;
        p.calldatas = c;
        p = _passAndQueue(governor, p);
        _flag(guard, p.id);
        _cancel(guard, p);
        assertEq(uint256(governor.state(p.id)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_RemovesGuardIsExact() public view {
        bytes32 role = timelock.CANCELLER_ROLE();
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);

        t[0] = address(timelock);
        c[0] = abi.encodeCall(timelock.revokeRole, (role, address(guard)));
        assertTrue(guard.removesGuard(t, v, c));

        c[0] = abi.encodeCall(timelock.revokeRole, (timelock.PROPOSER_ROLE(), address(guard)));
        assertFalse(guard.removesGuard(t, v, c), "another role");

        c[0] = abi.encodeCall(timelock.revokeRole, (role, address(governor)));
        assertFalse(guard.removesGuard(t, v, c), "another account");

        c[0] = abi.encodeCall(timelock.revokeRole, (role, address(guard)));
        v[0] = 1;
        assertFalse(guard.removesGuard(t, v, c), "sends value");

        v[0] = 0;
        t[0] = address(token);
        assertFalse(guard.removesGuard(t, v, c), "wrong target");

        assertFalse(guard.removesGuard(new address[](0), new uint256[](0), new bytes[](0)), "empty");
    }

    function test_ExpiresUnlessGovernanceRenews() public {
        P memory p = _propose(governor, _drain("a"));
        vm.warp(block.timestamp + TERM + 1);
        assertFalse(guard.isActive());
        ProposalGuard.Attestation memory att = _att(guard, p.id, true);
        _flagExpecting(p.id, att, abi.encodeWithSelector(ProposalGuard.GuardExpired.selector));

        vm.expectRevert(ProposalGuard.OnlyTimelock.selector);
        guard.renew();
        vm.prank(address(timelock));
        guard.renew();
        assertTrue(guard.isActive());
        assertEq(guard.expiresAt(), block.timestamp + TERM);
    }

    function test_CancelsAreRateLimited() public {
        (TimelockController tl, TimelockGovernor gov) = _deployGovernance(true);
        GuardHarness g = _deployGuard(gov);
        _setGuardian(gov, g);
        vm.roll(block.number + 1);

        for (uint256 i; i < 3; ++i) {
            P memory p = _propose(gov, _one(address(token), abi.encodeCall(token.transfer, (attacker, i + 1)), "x"));
            _flag(g, p.id);
            g.cancel(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
        }
        P memory fourth = _propose(gov, _one(address(token), abi.encodeCall(token.transfer, (attacker, 99)), "x"));
        _flag(g, fourth.id);
        vm.expectRevert(ProposalGuard.CancelLimitReached.selector);
        g.cancel(fourth.targets, fourth.values, fourth.calldatas, keccak256(bytes(fourth.description)));

        vm.warp(block.timestamp + g.CANCEL_PERIOD());
        g.cancel(fourth.targets, fourth.values, fourth.calldatas, keccak256(bytes(fourth.description)));
    }

    // ------------------------------------------------------------------ question template

    function test_ConstructorValidation() public {
        vm.expectRevert(ProposalGuard.InvalidConfiguration.selector);
        new GuardHarness(address(1), IGovernorLike(address(governor)), 0, HEAD, TAIL);
        vm.expectRevert(ProposalGuard.InvalidConfiguration.selector);
        new GuardHarness(address(1), IGovernorLike(address(governor)), 366 days, HEAD, TAIL);
        vm.expectRevert(ProposalGuard.InvalidConfiguration.selector);
        new GuardHarness(address(1), IGovernorLike(address(governor)), TERM, HEAD, bytes('"no window marker"'));
    }

    function testFuzz_SpliceMatchesDocument(uint256 id, uint64 from, uint64 to) public view {
        bytes memory doc = bytes.concat(
            HEAD, bytes(vm.toString(id)), TAIL, bytes(vm.toString(from)), ',"toBlock":', bytes(vm.toString(to)), "}}"
        );
        assertEq(guard.expectedQuestionHash(id, from, to), keccak256(doc));
    }
}
