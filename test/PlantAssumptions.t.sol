// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {WeatherQuestion} from "../src/WeatherQuestion.sol";
import {MockIntake} from "./mocks/Mocks.sol";

contract PlantAssumptionsTest is PlantTestBase {
    function test_explicitZeroCellQuestionRemainsInvalid() public {
        uint32 cell = 0;
        uint32 day = organism.lastSettledDay() + 1;
        vm.expectRevert(WeatherQuestion.InvalidCell.selector);
        organism.question(cell, day);
    }

    function test_threeSilentRequestsSettleEmptyAndMoveWithRetainedStake() public {
        _withCommittedCandidate(300 ether);
        uint256 oldEpoch = organism.epoch();
        for (uint256 i; i < 3; ++i) {
            _ask();
            vm.warp(vm.getBlockTimestamp() + 1 days);
            organism.clearPending();
            assertEq(organism.incompletes(START + 2), i + 1);
            assertEq(organism.epoch(), oldEpoch + (i == 2 ? 1 : 0));
            if (i < 2) vm.warp(organism.retryAt());
        }
        assertFalse(organism.isDead());
        assertEq(organism.lastSettledDay(), START + 2);
        assertEq(organism.location(), OTHER);
        assertEq(organism.water(), 50);
        assertEq(organism.backing(), 0);
        assertEq(organism.retryAt(), 0);
        _conservation();
    }

    function test_oldRotationSignatureExpires() public {
        MockIntake next = new MockIntake();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory sig = _signDigest(KEY, organism.rotationDigest(vm.addr(555), address(next), ACTION, 0, deadline));
        vm.warp(vm.getBlockTimestamp() + 400 days);
        vm.expectRevert(PlantOrganism.RotationExpired.selector);
        organism.rotate(vm.addr(555), address(next), ACTION, 0, deadline, sig);
        assertEq(organism.oracleSigner(), vm.addr(KEY));
        assertEq(organism.rotationNonce(), 0);
    }

    function test_redeemedSupplyIsExcludedFromThreshold() public {
        _withGardeners();
        _weather(1, 0);
        _unpark(alice, ORIGIN_CELL, 100 ether);
        vm.prank(alice);
        organism.redeem(600 ether);
        vm.prank(bob);
        organism.redeem(300 ether);
        vm.prank(carol);
        organism.redeem(60 ether);
        _park(carol, OTHER, 40 ether);
        _weather(0, 0);
        organism.challenge(OTHER);
        assertEq(organism.votingStake(OTHER), 40 ether);
        assertEq(organism.votingStake(ORIGIN_CELL), 0);
        _weather(0, 0);
        assertEq(organism.burned(), 960 ether);
        assertEq(organism.location(), OTHER);
    }

    function test_rotatedIntakeCannotPullAboveKeeperCap() public {
        MockIntake next = new MockIntake();
        next.setPrice(10000 ether);
        uint256 deadline = vm.getBlockTimestamp() + 3 days;
        bytes memory sig = _signDigest(KEY, organism.rotationDigest(vm.addr(555), address(next), ACTION, 0, deadline));
        organism.rotate(vm.addr(555), address(next), ACTION, 0, deadline, sig);
        imd.mint(keeper, 10000 ether);
        uint256 beforeBalance = imd.balanceOf(keeper);
        _nextEnded();
        vm.expectRevert(PlantOrganism.AdvanceTooLarge.selector);
        vm.prank(keeper);
        organism.heartbeat(0);
        assertEq(imd.balanceOf(keeper), beforeBalance);
        assertEq(organism.feeAdvances(keeper), 0);
        assertEq(next.sequence(), 0);
        vm.expectRevert(PlantOrganism.AdvanceTooLarge.selector);
        vm.prank(keeper);
        organism.heartbeat(9000 ether - 1);
        vm.prank(keeper);
        organism.heartbeat(9000 ether);
        assertEq(beforeBalance - imd.balanceOf(keeper), 9000 ether);
        assertEq(organism.feeAdvances(keeper), 9000 ether);
        _conservation();
    }

    function test_oldSourceWindowBacklogIsAlreadyDead() public {
        _withGardeners();
        vm.warp(uint256(START + 101) * 1 days);
        assertTrue(organism.isDead());
        vm.expectRevert(PlantOrganism.DeadPlant.selector);
        organism.heartbeat(type(uint256).max);
    }

    function test_preBindDonationsHaveNoExit() public {
        PlantOrganism fresh = _deploy();
        imd.mint(address(fresh), 1000 ether);
        fresh.claim();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        fresh.settle();
        vm.expectRevert(PlantOrganism.Unbound.selector);
        fresh.redeem(1);
        assertEq(imd.balanceOf(address(fresh)), 1000 ether);
    }
}
