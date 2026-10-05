// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The slice of an OpenZeppelin Governor this guard uses.
interface IGovernorLike {
    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external pure returns (uint256);
    function proposalSnapshot(uint256 proposalId) external view returns (uint256);
    function timelock() external view returns (address);
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);
}

/// @dev The slice of an OpenZeppelin TimelockController this guard uses.
interface ITimelockLike {
    function CANCELLER_ROLE() external view returns (bytes32);
    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);
    function cancel(bytes32 id) external;
}

/// @title ProposalGuard
/// @notice Cancels a governance proposal when, and only when, an IdentityMD swarm panel attests that
/// the PROPOSAL ITSELF contains a critical problem. It cannot propose, vote, queue, execute or move
/// funds. If no attestation arrives, governance proceeds exactly as it would without the guard.
/// @dev Design and the reasoning behind each rule: docs/DESIGN.md. Two rules exist because the
/// swarm-written spec this started from got them wrong:
///
/// FIX 1: THE QUESTION IS ABOUT THE PROPOSAL, NOT A REPORT. The spec asked the panel "does the report
/// with hash H contain a critical finding?". Anyone can write that report, so the panel would truthfully
/// say yes about a fabricated document, and any proposal could be censored for one oracle fee. Here the
/// only thing spliced into the question is the proposal id, which commits to the exact targets, values,
/// calldata and description. Reviews are supporting evidence the panel may read; they are never the
/// subject of the attestation.
///
/// FIX 2: THE GUARD CANNOT BLOCK ITS OWN REMOVAL. The spec relied on "governance can revoke the role".
/// But revocation is itself a proposal, and a compromised signing key needs no panel to sign "critical"
/// about it. So: a proposal whose every action removes this guard can never be cancelled; the guard
/// expires unless governance renews it; and it may cancel at most MAX_CANCELS_PER_PERIOD proposals per
/// period. The worst a stolen key can do is delay a bounded number of proposals until governance
/// removes the guard, which it always can.
contract ProposalGuard {
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    // ------------------------------------------------------------------ constants

    /// @notice The IdentityMD oracle service key; the only signer whose answers the guard acts on.
    address public constant SERVICE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    /// @notice Floors as COUNTS. Live attestations sign agreed == quorum, so a ratio would only force a
    /// higher request quorum and get requests refused.
    uint16 public constant MIN_PANEL_SIZE = 20;
    uint16 public constant MIN_AGREED = 15;

    uint8 public constant ANSWER_TYPE_BOOL = 0;

    uint256 public constant MAX_CANCELS_PER_PERIOD = 3;
    uint256 public constant CANCEL_PERIOD = 30 days;
    uint256 public constant MAX_TERM = 365 days;

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;

    bytes private constant _WINDOW_MARKER = ',"window":{"fromBlock":';
    uint256 private constant _HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    bytes4 private constant _REVOKE_ROLE = bytes4(keccak256("revokeRole(bytes32,address)"));
    bytes4 private constant _SET_PROPOSAL_GUARDIAN = bytes4(keccak256("setProposalGuardian(address)"));

    // ------------------------------------------------------------------ configuration

    IGovernorLike public immutable governor;
    ITimelockLike public immutable timelock;
    bytes32 public immutable cancellerRole;
    /// @notice How long one renewal keeps the guard active.
    uint256 public immutable term;

    /// @notice The canonical question document, split around the proposal id. Set once at construction;
    /// there is no setter. `questionTail` ends at `,"window":{"fromBlock":`.
    bytes public questionHead;
    bytes public questionTail;

    // ------------------------------------------------------------------ state

    uint256 public expiresAt;
    uint256 public periodStart;
    uint256 public cancelsThisPeriod;

    /// @notice Request id of the critical attestation that flagged each proposal, zero if none.
    mapping(uint256 proposalId => bytes32 requestId) public flaggedBy;
    mapping(bytes32 requestId => bool) public usedRequests;

    // ------------------------------------------------------------------ events and errors

    event Flagged(uint256 indexed proposalId, bytes32 indexed requestId, uint16 panelSize, uint16 agreed);
    event Cancelled(uint256 indexed proposalId, bool viaGovernor);
    event Renewed(uint256 expiresAt);

    error InvalidConfiguration();
    error GuardExpired();
    error UnknownProposal(uint256 proposalId);
    error AlreadyFlagged(uint256 proposalId);
    error NotFlagged(uint256 proposalId);
    error ProposalRemovesGuard(uint256 proposalId);
    error CancelLimitReached();
    error OnlyTimelock();
    error WrongDataChain();
    error WrongAnswerType();
    error NotCritical();
    error PanelTooSmall();
    error NotEnoughAgreement();
    error InvalidTimestamp();
    error ExpiredAttestation();
    error ReplayedAttestation();
    error InvalidWindow();
    error WrongQuestion(bytes32 expected, bytes32 given);
    error InvalidSignature();

    constructor(IGovernorLike governor_, uint256 term_, bytes memory questionHead_, bytes memory questionTail_) {
        if (address(governor_) == address(0) || term_ == 0 || term_ > MAX_TERM) revert InvalidConfiguration();
        if (questionHead_.length == 0 || !_endsWithWindowMarker(questionTail_)) revert InvalidConfiguration();
        ITimelockLike timelock_ = ITimelockLike(governor_.timelock());
        if (address(timelock_) == address(0)) revert InvalidConfiguration();

        governor = governor_;
        timelock = timelock_;
        cancellerRole = timelock_.CANCELLER_ROLE();
        term = term_;
        questionHead = questionHead_;
        questionTail = questionTail_;
        expiresAt = block.timestamp + term_;
        periodStart = block.timestamp;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
        emit Renewed(expiresAt);
    }

    // ------------------------------------------------------------------ flagging

    /// @notice Record that a swarm panel attested proposal `proposalId` contains a critical problem.
    /// Anyone may call; authority comes only from the attestation. A "not critical" answer is refused,
    /// so buying clean answers achieves nothing.
    function flag(uint256 proposalId, Attestation calldata a, bytes calldata sig) external {
        _requireActive();
        if (governor.proposalSnapshot(proposalId) == 0) revert UnknownProposal(proposalId);
        if (flaggedBy[proposalId] != bytes32(0)) revert AlreadyFlagged(proposalId);

        if (a.chainId != block.chainid) revert WrongDataChain();
        if (a.answerType != ANSWER_TYPE_BOOL) revert WrongAnswerType();
        if (a.answer.length != 32 || !abi.decode(a.answer, (bool))) revert NotCritical();
        if (a.panelSize < MIN_PANEL_SIZE) revert PanelTooSmall();
        if (a.agreed < MIN_AGREED || a.agreed > a.panelSize) revert NotEnoughAgreement();
        if (block.timestamp > a.expiresAt) revert ExpiredAttestation();
        if (a.issuedAt > block.timestamp || a.issuedAt > a.expiresAt) revert InvalidTimestamp();
        if (a.toBlock < a.fromBlock) revert InvalidWindow();
        if (usedRequests[a.requestId]) revert ReplayedAttestation();

        bytes32 expected = expectedQuestionHash(proposalId, a.fromBlock, a.toBlock);
        if (a.questionHash != expected) revert WrongQuestion(expected, a.questionHash);
        if (_recover(digest(a), sig) != _attester()) revert InvalidSignature();

        usedRequests[a.requestId] = true;
        flaggedBy[proposalId] = a.requestId;
        emit Flagged(proposalId, a.requestId, a.panelSize, a.agreed);
    }

    // ------------------------------------------------------------------ cancelling

    /// @notice Cancel a flagged proposal. Anyone may call once it is flagged. Uses the governor's
    /// proposal-guardian route when this guard holds it (any stage before execution), otherwise the
    /// timelock's canceller role (once queued).
    function cancel(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external {
        _requireActive();
        uint256 proposalId = governor.hashProposal(targets, values, calldatas, descriptionHash);
        if (flaggedBy[proposalId] == bytes32(0)) revert NotFlagged(proposalId);
        if (removesGuard(targets, values, calldatas)) revert ProposalRemovesGuard(proposalId);
        _countCancel();

        bool viaGovernor = _isProposalGuardian();
        if (viaGovernor) {
            governor.cancel(targets, values, calldatas, descriptionHash);
        } else {
            bytes32 salt = bytes20(address(governor)) ^ descriptionHash;
            timelock.cancel(timelock.hashOperationBatch(targets, values, calldatas, 0, salt));
        }
        emit Cancelled(proposalId, viaGovernor);
    }

    /// @notice True when EVERY action in the proposal only removes this guard: revoking its canceller
    /// role on the timelock, or replacing it as the governor's proposal guardian. Such a proposal can
    /// never be cancelled, so governance can always remove the guard. A bundle that also does anything
    /// else gets no exemption, so the exemption cannot shelter a malicious action.
    function removesGuard(address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas)
        public
        view
        returns (bool)
    {
        uint256 n = targets.length;
        if (n == 0 || values.length != n || calldatas.length != n) return false;
        for (uint256 i; i < n; ++i) {
            if (values[i] != 0 || !_isRemoval(targets[i], calldatas[i])) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ renewal

    /// @notice Extend the guard by one term from now. Only the timelock, i.e. only by passing a
    /// governance proposal. If governance stops renewing, the guard lapses and does nothing.
    function renew() external {
        if (msg.sender != address(timelock)) revert OnlyTimelock();
        expiresAt = block.timestamp + term;
        emit Renewed(expiresAt);
    }

    function isActive() public view returns (bool) {
        return block.timestamp <= expiresAt;
    }

    // ------------------------------------------------------------------ question

    /// @notice The questionHash the guard accepts for `proposalId` over a window. Public so a requester
    /// can check, before paying, that the question they are about to buy is the one the guard pins.
    function expectedQuestionHash(uint256 proposalId, uint64 fromBlock, uint64 toBlock) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                questionHead,
                _decimal(proposalId),
                questionTail,
                _decimal(fromBlock),
                ',"toBlock":',
                _decimal(toBlock),
                "}}"
            )
        );
    }

    function digest(Attestation calldata a) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _structHash(a)));
    }

    // ------------------------------------------------------------------ internals

    /// @dev VIRTUAL only so a test harness can sign with a known key. A deployed guard has no path to
    /// change it; any subclass under src/ must be read with that in mind.
    function _attester() internal view virtual returns (address) {
        return SERVICE_SIGNER;
    }

    function _requireActive() private view {
        if (!isActive()) revert GuardExpired();
    }

    function _countCancel() private {
        if (block.timestamp >= periodStart + CANCEL_PERIOD) {
            periodStart = block.timestamp;
            cancelsThisPeriod = 0;
        }
        if (cancelsThisPeriod >= MAX_CANCELS_PER_PERIOD) revert CancelLimitReached();
        ++cancelsThisPeriod;
    }

    function _isProposalGuardian() private view returns (bool) {
        (bool ok, bytes memory ret) = address(governor).staticcall(abi.encodeWithSignature("proposalGuardian()"));
        return ok && ret.length == 32 && abi.decode(ret, (address)) == address(this);
    }

    function _isRemoval(address target, bytes calldata data) private view returns (bool) {
        if (data.length < 4) return false;
        bytes4 selector = bytes4(data[:4]);
        if (target == address(timelock) && selector == _REVOKE_ROLE && data.length == 68) {
            (bytes32 role, address account) = abi.decode(data[4:], (bytes32, address));
            return role == cancellerRole && account == address(this);
        }
        if (target == address(governor) && selector == _SET_PROPOSAL_GUARDIAN && data.length == 36) {
            return abi.decode(data[4:], (address)) != address(this);
        }
        return false;
    }

    function _endsWithWindowMarker(bytes memory b) private pure returns (bool) {
        bytes memory m = _WINDOW_MARKER;
        if (b.length < m.length) return false;
        for (uint256 i; i < m.length; ++i) {
            if (b[b.length - m.length + i] != m[i]) return false;
        }
        return true;
    }

    function _structHash(Attestation calldata a) private pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }

    function _recover(bytes32 d, bytes calldata sig) private pure returns (address signer) {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (uint256(s) > _HALF_CURVE_ORDER || (v != 27 && v != 28)) revert InvalidSignature();
        signer = ecrecover(d, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }

    function _decimal(uint256 value) private pure returns (bytes memory out) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 v = value; v != 0; v /= 10) {
            ++digits;
        }
        out = new bytes(digits);
        for (uint256 v = value; v != 0; v /= 10) {
            out[--digits] = bytes1(uint8(48 + (v % 10)));
        }
    }
}
