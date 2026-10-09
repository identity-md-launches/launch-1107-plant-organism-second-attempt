// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";

contract PlantVotingRevisionTest is PlantTestBase {
    function test_questionUsesOriginFromDeployment() public {
        PlantOrganism fresh = _deploy();
        assertEq(fresh.question(), fresh.question(ORIGIN_CELL, START + 1));
        assertEq(organism.question(), organism.question(ORIGIN_CELL, START + 1));
        _withGardeners();
        assertEq(organism.question(), organism.question(ORIGIN_CELL, START + 2));
    }

    function test_atomicDestinationTopUpCannotMoveOrCaptureRewards() public {
        _withGardeners();
        _park(bob, OTHER, 1);
        _weather(0, 0);
        _ask();
        _deliver(0, 0, true);
        uint256 before = plant.balanceOf(bob);
        _park(bob, OTHER, 100 ether);
        organism.settle();
        _unpark(bob, OTHER, 100 ether);
        assertEq(plant.balanceOf(bob), before);
        assertEq(organism.location(), ORIGIN_CELL);
        _weather(0xffffff, 0);
        vm.prank(bob);
        organism.claim();
        vm.prank(alice);
        organism.claim();
        assertEq(imd.balanceOf(bob), 0);
        assertGt(imd.balanceOf(alice), 0);
        _conservation();
    }

    function test_atomicCurrentCellTopUpCannotVetoCommittedCandidate() public {
        _withCommittedCandidate(200 ether);
        _ask();
        _deliver(0, 0, true);
        _park(alice, ORIGIN_CELL, 300 ether);
        organism.settle();
        _unpark(alice, ORIGIN_CELL, 300 ether);
        assertEq(organism.location(), OTHER);
        _conservation();
    }

    function test_emptyCapturedCandidateFallsBackToRepairedLiveCandidate() public {
        _park(alice, THIRD, 201 ether);
        _withCommittedCandidate(200 ether);
        organism.challenge(THIRD);
        _ask();
        (,, uint32 captured,,,,,,) = organism.pending();
        assertEq(captured, THIRD);
        _unpark(alice, THIRD, 201 ether);
        organism.challenge(OTHER);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), OTHER);
        _conservation();
    }

    function test_fallbackCannotUseNewPostHeartbeatStake() public {
        _withCommittedCandidate(150 ether);
        _ask();
        _unpark(bob, OTHER, 150 ether);
        _park(alice, THIRD, 200 ether);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), ORIGIN_CELL);
        organism.challenge(THIRD);
        _weather(0, 0);
        assertEq(organism.location(), THIRD);
    }

    function test_withdrawalRemovesPowerAndReaskCannotRestoreIt() public {
        _withCommittedCandidate(200 ether);
        _ask();
        _unpark(bob, OTHER, 199 ether);
        assertEq(organism.votingStake(OTHER), 1 ether);
        _deliver(0, 0, false);
        organism.settle();
        _park(bob, OTHER, 199 ether);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _ask();
        assertEq(organism.votingStake(OTHER), 1 ether);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), ORIGIN_CELL);
        assertEq(organism.votingStake(OTHER), 200 ether);
        organism.challenge(OTHER);
        _weather(0, 0);
        assertEq(organism.location(), OTHER);
        _conservation();
    }

    function test_thirdIncompleteAlsoUsesRepairedCandidate() public {
        _park(alice, THIRD, 201 ether);
        _withCommittedCandidate(200 ether);
        organism.challenge(THIRD);
        for (uint256 i; i < 3; ++i) {
            if (i != 0) _park(alice, THIRD, 201 ether);
            _ask();
            _unpark(alice, THIRD, 201 ether);
            organism.challenge(OTHER);
            _deliver(0, 0, false);
            organism.settle();
            if (i < 2) vm.warp(vm.getBlockTimestamp() + 6 hours);
        }
        assertEq(organism.location(), OTHER);
        assertEq(organism.water(), 50);
        assertEq(organism.incompletes(START + 2), 3);
    }

    function test_currentCellWithdrawalBreaksTieForCommittedCandidate() public {
        _withCommittedCandidate(100 ether);
        _ask();
        _deliver(0, 0, true);
        _unpark(alice, ORIGIN_CELL, 1);
        organism.settle();
        assertEq(organism.location(), OTHER);
        assertEq(organism.challenger(), 0);
        _conservation();
    }

    function test_timeoutRetryCannotMatureRequestOrCooldownDeposits() public {
        _withCommittedCandidate(50 ether);
        _ask();
        uint256 oldEpoch = organism.epoch();
        _park(bob, OTHER, 150 ether);
        assertEq(organism.votingStake(OTHER), 50 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        organism.clearPending();
        _park(bob, OTHER, 50 ether);
        vm.warp(organism.retryAt());
        _ask();
        assertEq(organism.epoch(), oldEpoch);
        assertEq(organism.votingStake(OTHER), 50 ether);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), ORIGIN_CELL);
        assertEq(organism.lastSettledDay(), START + 2);
        assertEq(organism.votingStake(OTHER), 250 ether);
        organism.challenge(OTHER);
        _weather(0, 0);
        assertEq(organism.location(), OTHER);
        _conservation();
    }

    function test_thirdIncompleteReadsBeforePromotingFreshDeposits() public {
        _withCommittedCandidate(50 ether);
        _park(bob, OTHER, 100 ether);
        uint256 oldEpoch = organism.epoch();
        for (uint256 i; i < 3; ++i) {
            _ask();
            assertEq(organism.votingStake(OTHER), 50 ether);
            _deliver(0, 0, false);
            organism.clearPending();
            assertEq(organism.location(), ORIGIN_CELL, "fresh deposits voted in the incomplete day");
            if (i < 2) {
                assertEq(organism.epoch(), oldEpoch);
                vm.warp(organism.retryAt());
            }
        }
        assertEq(organism.epoch(), oldEpoch + 1);
        assertEq(organism.water(), 50);
        assertEq(organism.backing(), 0);
        assertEq(organism.votingStake(OTHER), 150 ether);
        _weather(0, 0);
        assertEq(organism.location(), OTHER);
        _conservation();
    }

    function test_replacementHolderCannotInheritWithdrawnVotingPower() public {
        _withCommittedCandidate(150 ether);
        _ask();
        _park(carol, OTHER, 100 ether);
        _unpark(bob, OTHER, 100 ether);
        assertEq(organism.parkedTotal(OTHER), 150 ether);
        assertEq(organism.votingStake(OTHER), 50 ether);
        organism.checkpoint(OTHER, carol);
        vm.prank(bob);
        organism.claim();
        assertEq(organism.votingStake(OTHER), 50 ether, "checkpointing must not mature fresh stake");
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), ORIGIN_CELL);
        assertEq(organism.votingStake(OTHER), 150 ether);
        _weather(0, 0);
        assertEq(organism.location(), OTHER);
        _conservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_withdrawalUsesOwnQueuedStakeBeforeCommitment(uint96 withdrawalSeed) public {
        _withCommittedCandidate(150 ether);
        _ask();
        _park(bob, OTHER, 100 ether);
        uint256 withdrawn = bound(withdrawalSeed, 1, 250 ether);
        _unpark(bob, OTHER, withdrawn);
        uint256 retained = withdrawn <= 100 ether ? 150 ether : 250 ether - withdrawn;
        assertEq(organism.votingStake(OTHER), retained);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), retained > 100 ether ? OTHER : ORIGIN_CELL);
        assertEq(organism.votingStake(OTHER), 250 ether - withdrawn);
        _conservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_repeatedTopUpsCannotIncreaseCommittedStake(uint96 seed) public {
        _withCommittedCandidate(100 ether);
        _ask();
        uint256 amount = bound(seed, 1, 100 ether);
        _park(bob, OTHER, amount);
        _park(bob, OTHER, amount);
        assertEq(organism.votingStake(OTHER), 100 ether);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), ORIGIN_CELL, "post-request deposits cannot break a voting tie");
        _weather(0, 0);
        assertEq(organism.location(), OTHER, "retained deposits vote on the following request");
        _conservation();
    }
}
