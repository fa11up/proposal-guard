// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorProposalGuardian} from "@openzeppelin/contracts/governance/extensions/GovernorProposalGuardian.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract VotesToken is ERC20, ERC20Permit, ERC20Votes {
    constructor(address holder) ERC20("Gov", "GOV") ERC20Permit("Gov") {
        _mint(holder, 1_000_000e18);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

/// @notice A standard OZ Governor executing through a TimelockController.
contract TimelockGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    constructor(IVotes token, TimelockController tl)
        Governor("Testbed")
        GovernorSettings(1, 50, 0)
        GovernorVotes(token)
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(tl)
    {}

    function votingDelay() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 id) public view virtual override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(id);
    }

    function proposalNeedsQueuing(uint256 id)
        public
        view
        virtual
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(id);
    }

    function _queueOperations(uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 d)
        internal
        virtual
        override(Governor, GovernorTimelockControl)
        returns (uint48)
    {
        return super._queueOperations(id, t, v, c, d);
    }

    function _executeOperations(uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 d)
        internal
        virtual
        override(Governor, GovernorTimelockControl)
    {
        super._executeOperations(id, t, v, c, d);
    }

    function _cancel(address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 d)
        internal
        virtual
        override(Governor, GovernorTimelockControl)
        returns (uint256)
    {
        return super._cancel(t, v, c, d);
    }

    function _executor() internal view virtual override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}

/// @notice The same governor with OZ's proposal-guardian extension, which may cancel at any stage.
contract GuardianGovernor is TimelockGovernor, GovernorProposalGuardian {
    constructor(IVotes token, TimelockController tl) TimelockGovernor(token, tl) {}

    function _validateCancel(uint256 id, address caller)
        internal
        view
        override(Governor, GovernorProposalGuardian)
        returns (bool)
    {
        return super._validateCancel(id, caller);
    }

    function votingDelay() public view override(Governor, TimelockGovernor) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, TimelockGovernor) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, TimelockGovernor) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 id) public view override(Governor, TimelockGovernor) returns (ProposalState) {
        return super.state(id);
    }

    function proposalNeedsQueuing(uint256 id) public view override(Governor, TimelockGovernor) returns (bool) {
        return super.proposalNeedsQueuing(id);
    }

    function _queueOperations(uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 d)
        internal
        override(Governor, TimelockGovernor)
        returns (uint48)
    {
        return super._queueOperations(id, t, v, c, d);
    }

    function _executeOperations(uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 d)
        internal
        override(Governor, TimelockGovernor)
    {
        super._executeOperations(id, t, v, c, d);
    }

    function _cancel(address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 d)
        internal
        override(Governor, TimelockGovernor)
        returns (uint256)
    {
        return super._cancel(t, v, c, d);
    }

    function _executor() internal view override(Governor, TimelockGovernor) returns (address) {
        return super._executor();
    }
}
