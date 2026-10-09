// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {VotingBorrower} from "./PlantVotingCommitment.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {WeatherQuestion} from "../src/WeatherQuestion.sol";
import {MockHook} from "./mocks/Mocks.sol";

contract PlantLaunchRevisionTest is PlantTestBase {
    function _quarter(int256 microDegrees) private pure returns (int16) {
        int256 q = microDegrees / 250000;
        if (microDegrees < 0 && microDegrees % 250000 != 0) --q;
        return int16(q);
    }

    function _cell(int256 lat, int256 lon) private pure returns (uint32) {
        return uint32(uint16(_quarter(lat))) << 16 | uint16(_quarter(lon));
    }

    function test_originFromRealCoordinatesRoundTripsThroughCentre() public {
        // UNESCO Sintra: N38 46 59.988, W9 25 0.012 (rounded to microdegrees).
        uint32 cell = _cell(38_783_330, -9_416_670);
        assertEq(cell, 10223578);
        assertEq(organism.ORIGIN_CELL(), cell);
        assertEq(organism.location(), cell);
        assertEq(organism.ORIGIN(), "Sintra: Its gardens bring native and exotic trees together on forested hills.");
        int16 lat = int16(uint16(cell >> 16));
        int16 lon = int16(uint16(cell));
        assertEq(lat, 155);
        assertEq(lon, -38);
        assertEq(WeatherQuestion.coordinate(lat), "38.875");
        assertEq(WeatherQuestion.coordinate(lon), "-9.375");
        assertEq(_cell(int256(lat) * 250000 + 125000, int256(lon) * 250000 + 125000), cell);
        PlantOrganism fresh = _deploy();
        assertEq(fresh.location(), cell);
        assertEq(fresh.hook(), address(0));
        assertEq(fresh.water(), 50);
    }

    function test_lateBindSkipsThroughBindDayAndRequestsOnlyFirstFullDay() public {
        PlantOrganism fresh = _deploy();
        vm.warp(uint256(START + 5000) * 1 days + 1 days - 60);
        fresh.bind(address(new MockHook(address(fresh), address(plant))));
        vm.startPrank(alice);
        plant.approve(address(fresh), 100 ether);
        fresh.park(OTHER, 100 ether);
        vm.stopPrank();
        vm.warp(uint256(START + 5001) * 1 days);
        vm.expectRevert(PlantOrganism.NoRequest.selector);
        fresh.heartbeat(0);
        (bool ok,) = address(fresh).call{gas: 400000}(abi.encodeWithSignature("settle()"));
        assertTrue(ok);
        assertEq(fresh.lastSettledDay(), START + 5000);
        assertEq(fresh.location(), ORIGIN_CELL);
        assertEq(fresh.epoch(), 0);
        assertEq(fresh.votingStake(OTHER), 0);
        vm.expectRevert(PlantOrganism.DayNotEnded.selector);
        fresh.heartbeat(0);
        vm.warp(uint256(START + 5002) * 1 days);
        intake.setPrice(0);
        fresh.heartbeat(0);
        (, uint32 day,,,,,,,) = fresh.pending();
        assertEq(day, START + 5001);
        assertEq(intake.lastBody(), fresh.requestBody(ORIGIN_CELL, day));
    }

    function _firstEpochFlash(uint32 cell) private {
        VotingBorrower borrower = new VotingBorrower(organism, plant, alice);
        vm.prank(alice);
        plant.approve(address(borrower), type(uint256).max);
        uint256 balance = plant.balanceOf(alice);
        _nextEnded();
        borrower.askWithLoan(cell, 300 ether);
        assertEq(organism.epoch(), 0);
        assertEq(organism.challenger(), 0);
        _deliver(0xffffff, 0, true);
        borrower.settleWithLoan(cell, 300 ether);
        assertEq(organism.location(), ORIGIN_CELL);
        assertEq(organism.votingStake(cell), 0);
        assertEq(organism.gardenerReserve(), 0);
        assertEq(organism.credits(address(borrower)), 0);
        // The heartbeat caller still receives the unchanged keeper bounty, never gardening rewards.
        uint256 bountyBalance = imd.balanceOf(address(borrower));
        borrower.claim();
        assertEq(imd.balanceOf(address(borrower)), bountyBalance);
        assertEq(plant.balanceOf(alice), balance);
        assertEq(organism.totalParked(), 0);
        _weather(1, 0);
        borrower.claim();
        assertEq(imd.balanceOf(address(borrower)), bountyBalance);
        _conservation();
    }

    function test_firstEpochFlashCannotMoveOrEarnGardenersAtDestination() public {
        _firstEpochFlash(OTHER);
    }

    function test_firstEpochFlashCannotEarnGardenersAtOrigin() public {
        _firstEpochFlash(ORIGIN_CELL);
    }

    function test_rotationDeadlineIsSignedAndAcceptedAtExactBoundary() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = organism.rotationDigest(vm.addr(1234), address(intake), ACTION, 0, deadline);
        bytes memory sig = _signDigest(KEY, digest);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(1234), address(intake), ACTION, 0, deadline + 1, sig);
        vm.warp(deadline);
        organism.rotate(vm.addr(1234), address(intake), ACTION, 0, deadline, sig);
        assertEq(organism.oracleSigner(), vm.addr(1234));
    }

    function test_repricingCannotExceedAdvanceCapAndZeroCapUsesPot() public {
        _nextEnded();
        intake.setPrice(1002 ether);
        vm.expectRevert(PlantOrganism.AdvanceTooLarge.selector);
        vm.prank(keeper);
        organism.heartbeat(1 ether);
        assertEq(intake.sequence(), 0);
        assertEq(organism.feeAdvanceTotal(), 0);
        assertEq(organism.pot(), 1000 ether);
        intake.setPrice(1000 ether);
        vm.prank(keeper);
        organism.heartbeat(0);
        assertEq(organism.feeAdvanceTotal(), 0);
        assertEq(imd.balanceOf(keeper), 100 ether);
        assertEq(organism.pot(), 0);
    }

    function test_timeoutsAndIncompleteShareCounterAndReadRepairedCandidate() public {
        _park(alice, THIRD, 201 ether);
        _withCommittedCandidate(200 ether);
        organism.challenge(THIRD);
        _ask();
        _deliver(0, 0, false);
        organism.clearPending();
        assertEq(organism.incompletes(START + 2), 1);
        vm.warp(organism.retryAt());
        _ask();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        organism.clearPending();
        assertEq(organism.incompletes(START + 2), 2);
        vm.warp(organism.retryAt());
        _ask();
        _unpark(alice, THIRD, 201 ether);
        organism.challenge(OTHER);
        // Fresh deposits still cannot vote in the READ performed by the third strike.
        _park(alice, ORIGIN_CELL, 300 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        organism.clearPending();
        assertEq(organism.incompletes(START + 2), 3);
        assertEq(organism.location(), OTHER);
        assertEq(organism.water(), 50);
        assertEq(organism.backing(), 0);
        assertEq(organism.epoch(), 2);
        vm.expectRevert(PlantOrganism.NoRequest.selector);
        organism.clearPending();
        _conservation();
    }

    function test_timeoutAfterDeathCannotAdvanceDayOrRevive() public {
        _ask();
        uint32 day = organism.lastSettledDay();
        vm.warp(uint256(day + 30) * 1 days);
        organism.clearPending();
        assertEq(organism.lastSettledDay(), day);
        assertEq(organism.epoch(), 0);
        assertTrue(organism.isDead());
        organism.die();
        assertTrue(organism.dead());
    }
}
