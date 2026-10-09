// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {MockHook} from "./mocks/Mocks.sol";

/// @notice Stake is keyed to the UTC day it was parked, so a settle that lags behind the
/// calendar never lets a deposit made after a day ended share that day's pool or vote on it.
contract PlantSettleLagTest is PlantTestBase {
    function _claim(address who) private returns (uint256) {
        vm.prank(who);
        organism.claim();
        return imd.balanceOf(who);
    }

    function _expectedPool() private view returns (uint256) {
        return organism.spendablePot() / 10 / 3; // one sunny hour at water 50
    }

    function test_parkAfterDayEndedCannotEarnThatDaysPool() public {
        _withGardeners();
        _ask(); // day START+2 is asked and answered on day START+3, but nobody settles it
        _deliver(0, 0, true);
        vm.warp(uint256(START + 4) * 1 days + 1); // day START+3 has fully ended
        _park(bob, ORIGIN_CELL, 300 ether);
        organism.settle(); // settles START+2
        assertEq(organism.lastSettledDay(), START + 2);
        assertEq(organism.votingStake(ORIGIN_CELL), 100 ether, "stake parked after day START+3 ended counted");
        _ask(); // asks day START+3, whose outcome bob already knew when he parked
        _deliver(0xffffff, 0, true);
        organism.settle();
        _unpark(bob, ORIGIN_CELL, 300 ether);
        assertEq(_claim(bob), 0, "stake parked after day START+3 ended shared its pool");
        assertGt(_claim(alice), 0);
        _conservation();
    }

    function test_parkAfterDayEndedCannotVoteOnThatDay() public {
        _withGardeners();
        _ask();
        _deliver(0, 0, true);
        vm.warp(uint256(START + 4) * 1 days + 1);
        _park(bob, OTHER, 300 ether); // day START+4: eligible from day START+5 on
        organism.settle(); // START+2
        organism.challenge(OTHER);
        assertEq(organism.challenger(), 0);
        _weather(0, 0); // START+3
        _weather(0, 0); // START+4: its READ still sees no eligible stake at OTHER
        assertEq(organism.location(), ORIGIN_CELL);
        assertEq(organism.votingStake(OTHER), 300 ether);
        organism.challenge(OTHER);
        _weather(0, 0); // START+5
        assertEq(organism.location(), OTHER);
        _conservation();
    }

    function test_lagDepositsMatureDayByDayWithExactShares() public {
        _withGardeners();
        intake.setPrice(0);
        _park(bob, ORIGIN_CELL, 100 ether); // day START+2
        _ask(); // day START+3 asks START+2
        _deliver(1, 0, true);
        vm.warp(uint256(START + 3) * 1 days + 12 hours);
        _park(carol, ORIGIN_CELL, 100 ether); // day START+3
        vm.warp(uint256(START + 4) * 1 days + 1);
        uint256 pool = _expectedPool();
        organism.settle(); // START+2: only alice held through it
        assertApproxEqAbs(_claim(alice), pool, 300);
        assertEq(_claim(bob), 0);
        assertEq(_claim(carol), 0);
        uint256 aliceBefore = imd.balanceOf(alice);
        _ask();
        _deliver(1, 0, true);
        pool = _expectedPool();
        organism.settle(); // START+3: alice and bob
        assertApproxEqAbs(_claim(alice) - aliceBefore, pool / 2, 300);
        assertApproxEqAbs(_claim(bob), pool / 2, 300);
        assertEq(_claim(carol), 0);
        aliceBefore = imd.balanceOf(alice);
        uint256 bobBefore = imd.balanceOf(bob);
        vm.warp(uint256(START + 5) * 1 days);
        _ask();
        _deliver(1, 0, true);
        pool = _expectedPool();
        organism.settle(); // START+4: all three
        assertApproxEqAbs(_claim(alice) - aliceBefore, pool / 3, 300);
        assertApproxEqAbs(_claim(bob) - bobBefore, pool / 3, 300);
        assertApproxEqAbs(_claim(carol), pool / 3, 300);
        assertEq(organism.votingStake(ORIGIN_CELL), 300 ether);
        _conservation();
    }

    function test_withdrawalDuringLagLeavesNewestDayFirst() public {
        _withGardeners();
        _ask();
        _deliver(0, 0, true);
        vm.warp(uint256(START + 3) * 1 days + 12 hours);
        _park(alice, ORIGIN_CELL, 10 ether); // day START+3
        vm.warp(uint256(START + 4) * 1 days + 12 hours);
        _park(alice, ORIGIN_CELL, 20 ether); // day START+4
        _unpark(alice, ORIGIN_CELL, 25 ether); // all of day START+4, half of day START+3, none committed
        assertEq(organism.queuedOf(ORIGIN_CELL, alice, START + 4), 0);
        assertEq(organism.queuedOf(ORIGIN_CELL, alice, START + 3), 5 ether);
        assertEq(organism.votingStake(ORIGIN_CELL), 100 ether);
        organism.settle(); // START+2
        _weather(0, 0); // START+3
        assertEq(organism.votingStake(ORIGIN_CELL), 105 ether);
        _unpark(alice, ORIGIN_CELL, 105 ether);
        assertEq(organism.votingStake(ORIGIN_CELL), 0);
        _conservation();
    }

    function test_unlockedAdvanceIsNotRelockedByNextHeartbeat() public {
        intake.setPrice(1000 ether); // drain the pot into the first request
        _ask();
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.spendablePot(), 0);
        intake.setPrice(10 ether);
        uint256 start = imd.balanceOf(keeper);
        _ask(); // keeper advances 10
        assertEq(organism.feeAdvances(keeper), 10 ether);
        _deliver(0, 0, true);
        organism.settle(); // unlocks it, but nothing can be repaid
        assertEq(organism.feeAdvances(keeper), 10 ether);
        _ask(); // keeper advances 10 more: only this advance is locked
        assertEq(organism.feeAdvances(keeper), 20 ether);
        assertEq(organism.lockedAdvances(keeper), 10 ether);
        assertEq(imd.balanceOf(keeper), start - 20 ether);
        imd.mint(address(organism), 10 ether);
        vm.prank(keeper);
        organism.claim();
        assertEq(imd.balanceOf(keeper), start - 10 ether, "the already unlocked advance must be repaid");
        assertEq(organism.feeAdvances(keeper), 10 ether);
        imd.mint(address(organism), 10 ether);
        vm.prank(keeper);
        organism.claim();
        assertEq(imd.balanceOf(keeper), start - 10 ether, "the pending request's advance stays locked");
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.feeAdvances(keeper), 0);
        assertEq(imd.balanceOf(keeper), start);
        _conservation();
    }

    function test_settleNamedDayRefusesCatchUpBeyondIt() public {
        PlantOrganism fresh = _deploy();
        vm.warp(uint256(START + 10) * 1 days);
        vm.expectRevert(PlantOrganism.WrongDay.selector);
        fresh.settle(START + 1);
        assertEq(fresh.lastSettledDay(), START);
        fresh.settle();
        assertEq(fresh.lastSettledDay(), START + 9);
        vm.warp(uint256(START + 11) * 1 days);
        fresh.settle(START + 10);
        assertEq(fresh.lastSettledDay(), START + 10);
        // A named-day strike for an incomplete result still counts without advancing the day.
        _withGardeners();
        _ask();
        _deliver(0, 0, false);
        organism.settle(START + 2);
        assertEq(organism.incompletes(START + 2), 1);
        assertEq(organism.lastSettledDay(), START + 1);
    }

    function test_longLagWithDailyDepositsSettlesColdWithinStipend() public {
        _withCommittedCandidate(50 ether);
        for (uint32 d = START + 2; d < START + 30; ++d) {
            vm.warp(uint256(d) * 1 days + 12 hours);
            _park(carol, ORIGIN_CELL, 1 ether);
            _park(carol, OTHER, 1 ether);
            _park(bob, THIRD, 1 ether);
        }
        assertFalse(organism.isDead());
        vm.record();
        for (uint32 k; k < 4; ++k) {
            _ask();
            _deliver(0xffffff, 0, true);
            _cool(address(organism));
            _cool(address(imd));
            _cool(address(plant));
            _settleWithinGasLimit();
            assertEq(organism.lastSettledDay(), START + 2 + k);
            assertEq(organism.location(), ORIGIN_CELL);
            // Deposits through the day just settled are eligible: one more lag day each settle.
            assertEq(organism.votingStake(ORIGIN_CELL), 100 ether + uint256(k + 1) * 1 ether);
            assertEq(organism.votingStake(OTHER), 50 ether + uint256(k + 1) * 1 ether);
        }
        // A cell nobody rolled matures all of its settled days when it is finally nominated.
        assertEq(organism.votingStake(THIRD), 4 ether);
        organism.challenge(THIRD);
        assertEq(organism.challenger(), OTHER, "4 PLANT cannot replace a 54 PLANT challenger");
        (uint256 active,,,) = organism.cellRewards(THIRD);
        assertEq(active, 4 ether, "nomination rolled every settled day of the dormant cell");
        _conservation();
    }

    function _cool(address target) private {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        for (uint256 i; i < reads.length; ++i) {
            vm.coolSlot(target, reads[i]);
        }
        for (uint256 i; i < writes.length; ++i) {
            vm.coolSlot(target, writes[i]);
        }
        vm.cool(target);
    }

    function test_bindDayDepositsWaitForFirstFullDaySettle() public {
        PlantOrganism fresh = _deploy();
        fresh.bind(address(new MockHook(address(fresh), address(plant))));
        vm.startPrank(alice);
        plant.approve(address(fresh), 200 ether);
        fresh.park(OTHER, 100 ether);
        fresh.park(ORIGIN_CELL, 100 ether);
        vm.stopPrank();
        assertEq(fresh.votingStake(OTHER), 0);
        assertEq(fresh.challenger(), 0);
        fresh.challenge(OTHER);
        assertEq(fresh.challenger(), 0);
        (,, uint32 rolled, uint32 lastQueued) = fresh.cellRewards(OTHER);
        assertEq(lastQueued, START);
        assertLt(rolled, START);
    }
}
