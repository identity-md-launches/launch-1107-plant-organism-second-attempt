// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "src/PlantOrganism.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {MockToken, MockHook, MockIntake} from "./mocks/Mocks.sol";

contract PlantAdversarialTest is PlantTestBase {
    function test_callbackAndSettlementEventsDescribeTheAppliedResult() public {
        _withGardeners();
        bytes32 intakeId = _ask();
        OracleAttestation.Attestation memory a = _attestation(1, 0, true);
        bytes32 word = abi.decode(a.answer, (bytes32));
        bytes memory sig = _sign(a);
        assertNotEq(intakeId, a.requestId);
        vm.expectEmit(true, true, false, true, address(organism));
        emit PlantOrganism.Received(intakeId, a.requestId, word);
        (bool ok,,) = intake.deliver(intakeId, a, sig);
        assertTrue(ok);
        assertFalse(organism.consumed(intakeId), "intake ID and oracle UUID are different namespaces");
        uint256 sip = 999.5 ether / 10;
        uint256 pool = sip / 3;
        uint256 reserved = pool / 100 * 100;
        vm.expectEmit(true, false, false, true, address(organism));
        emit PlantOrganism.Settled(START + 2, word, sip, sip - reserved, 49, ORIGIN_CELL);
        organism.settle();
    }

    function _pending() private view returns (PlantOrganism.Pending memory p) {
        (p.requestId, p.day, p.challenger, p.caller, p.askedAt, p.intake, p.exists, p.received, p.word) =
            organism.pending();
    }

    function _rejectExactly(OracleAttestation.Attestation memory a, bytes memory sig, bytes memory error) private {
        bytes32 beforeState = keccak256(abi.encode(_pending()));
        (bool ok, bytes memory reason,) = intake.deliver(intake.lastId(), a, sig);
        assertFalse(ok, "invalid result accepted");
        assertEq(reason, error, "rejection must come from the intended check");
        assertFalse(organism.consumed(a.requestId), "rejected oracle UUID consumed");
        assertEq(keccak256(abi.encode(_pending())), beforeState, "rejection changed pending state");
    }

    function test_rejectedResultCanBeCorrectedWithoutBurningRequest() public {
        _withGardeners();
        _ask();
        OracleAttestation.Attestation memory a = _attestation(1, 0, true);
        a.answerType = 3;
        _rejectExactly(
            a, _sign(a), abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(2), uint8(3))
        );
        a.answerType = 2;
        bytes memory sig = _sign(a);
        _rejectExactly(a, hex"", abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        (bool ok,,) = intake.deliver(intake.lastId(), a, sig);
        assertTrue(ok);
        assertTrue(organism.consumed(a.requestId));
        assertTrue(_pending().received);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_reservedWeatherBitsRejectedWithoutMutatingPending(uint8 seed) public {
        _withGardeners();
        _ask();
        // The defined regions are [0,48] and [96,127]. Exercise every other bit.
        uint256 bit = 49 + uint256(seed) % 175;
        if (bit >= 96) bit += 32;
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        a.answer = abi.encode(bytes32(uint256(abi.decode(a.answer, (bytes32))) | uint256(1) << bit));
        _rejectExactly(a, _sign(a), abi.encodeWithSelector(PlantOrganism.InvalidWord.selector));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_signedMalformedPanelsAreRejected(uint8 seed) public {
        _withGardeners();
        _ask();
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        uint8 variant = seed % 5;
        if (variant == 0) a.panelSize = 14;
        if (variant == 1) a.quorum = 9;
        if (variant == 2) a.quorum = 16;
        if (variant == 3) a.agreed = 9;
        if (variant == 4) a.agreed = 16;
        _rejectExactly(a, _sign(a), abi.encodeWithSelector(PlantOrganism.InvalidAttestation.selector));
    }

    function test_answerMustBeExactlyOneWordIncludingTrailingData() public {
        _withGardeners();
        _ask();
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        a.answer = bytes.concat(a.answer, hex"00");
        _rejectExactly(a, _sign(a), abi.encodeWithSelector(PlantOrganism.InvalidAttestation.selector));
        a.answer = new bytes(31);
        _rejectExactly(a, _sign(a), abi.encodeWithSelector(PlantOrganism.InvalidAttestation.selector));
    }

    function test_validityWindowBoundariesAndAskedAt() public {
        _withGardeners();
        _ask();
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        a.issuedAt -= 1;
        _rejectExactly(a, _sign(a), abi.encodeWithSelector(PlantOrganism.InvalidAttestation.selector));
        a.issuedAt = uint64(vm.getBlockTimestamp() + 301);
        _rejectExactly(
            a, _sign(a), abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt)
        );
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt - 1;
        _rejectExactly(
            a, _sign(a), abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt)
        );
        a.expiresAt = a.issuedAt;
        (bool ok,,) = intake.deliver(intake.lastId(), a, _sign(a));
        assertTrue(ok, "canonical verifier accepts the exact expiry second");
    }

    function test_exactClockDriftToleranceAccepted() public {
        _withGardeners();
        _ask();
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        a.issuedAt += 300;
        (bool ok,,) = intake.deliver(intake.lastId(), a, _sign(a));
        assertTrue(ok);
    }

    function test_consumedOracleUuidCannotBeReusedForSameDayRetry() public {
        _withGardeners();
        bytes32 oldIntakeId = _ask();
        OracleAttestation.Attestation memory a = _attestation(0, 0, false);
        (bool ok,,) = intake.deliver(oldIntakeId, a, _sign(a));
        assertTrue(ok);
        organism.settle();
        vm.warp(organism.retryAt());
        bytes32 newIntakeId = _ask();
        assertNotEq(oldIntakeId, newIntakeId);
        // Fresh validity and signature ensure this exercises _consume rather than issuedAt.
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 1 days;
        (bool accepted, bytes memory error,) = intake.deliver(newIntakeId, a, _sign(a));
        assertFalse(accepted);
        assertEq(error, abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        assertFalse(_pending().received);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.lastSettledDay(), START + 2);
    }

    function test_timeoutExactSecondAndOldResultCannotPoisonReask() public {
        _withGardeners();
        bytes32 oldId = _ask();
        uint256 deadline = uint256(_pending().askedAt) + 1 days;
        vm.warp(deadline - 1);
        vm.expectRevert(PlantOrganism.NotTimedOut.selector);
        organism.clearPending();
        vm.warp(deadline);
        organism.clearPending();
        assertEq(organism.retryAt(), deadline + 6 hours);
        vm.warp(deadline + 6 hours);
        _ask();
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        (bool ok, bytes memory error,) = intake.deliver(oldId, a, _sign(a));
        assertFalse(ok);
        assertEq(error, abi.encodeWithSelector(PlantOrganism.UnknownRequest.selector));
        assertFalse(organism.consumed(a.requestId));
        (ok,,) = intake.deliver(intake.lastId(), a, _sign(a));
        assertTrue(ok);
    }

    function test_twoKeepersAdvancesSurviveTimeoutAndOnlyUnlockOnSettlement() public {
        _withGardeners();
        intake.setPrice(1002 ether);
        uint256 firstBalance = imd.balanceOf(keeper);
        _ask(); // uses 1000 pot + 2 from keeper
        vm.warp(vm.getBlockTimestamp() + 1 days);
        organism.clearPending();
        vm.warp(organism.retryAt());
        imd.mint(bob, 1002 ether);
        vm.startPrank(bob);
        imd.approve(address(organism), 1002 ether);
        organism.heartbeat(type(uint256).max);
        vm.stopPrank();
        assertEq(organism.feeAdvances(keeper), 2 ether);
        assertEq(organism.feeAdvances(bob), 1002 ether);
        assertEq(organism.feeAdvanceTotal(), 1004 ether);
        imd.mint(address(organism), 1004 ether);
        vm.prank(keeper);
        organism.claim();
        assertEq(imd.balanceOf(keeper), firstBalance - 2 ether, "clear is not a settle");
        _deliver(0, 0, true);
        organism.settle();
        assertEq(imd.balanceOf(bob), 1002 ether, "latest caller's advance repaid");
        assertEq(organism.feeAdvances(keeper), 2 ether, "previous caller's debt preserved");
        vm.prank(keeper);
        organism.claim();
        assertEq(imd.balanceOf(keeper), firstBalance);
        assertEq(organism.owed(), 0);
        assertEq(imd.balanceOf(address(organism)), 0);
    }

    function test_deferredAdvanceAndBountyRemainClaimableExactlyOnce() public {
        _withGardeners();
        intake.setPrice(1002 ether);
        _ask();
        imd.mint(address(organism), 102 ether);
        _deliver(0, 0, true);
        imd.setBlocked(keeper, true);
        organism.settle();
        assertEq(organism.feeAdvances(keeper), 2 ether);
        assertEq(organism.credits(keeper), 1 ether);
        imd.setBlocked(keeper, false);
        uint256 beforeBalance = imd.balanceOf(keeper);
        vm.prank(keeper);
        organism.claim();
        assertEq(imd.balanceOf(keeper), beforeBalance + 3 ether);
        vm.prank(keeper);
        organism.claim();
        assertEq(imd.balanceOf(keeper), beforeBalance + 3 ether);
        assertEq(organism.feeAdvanceTotal(), 0);
        assertEq(organism.creditTotal(), 0);
    }

    function test_thirdIncompleteReadsCandidateFromLatestRequest() public {
        _park(alice, THIRD, 200 ether);
        _withCommittedCandidate(250 ether);
        for (uint256 i; i < 2; ++i) {
            _ask();
            assertEq(_pending().challenger, OTHER);
            _deliver(0, 0, false);
            organism.clearPending();
            vm.warp(organism.retryAt());
        }
        _unpark(bob, OTHER, 100 ether);
        organism.challenge(THIRD);
        _ask();
        assertEq(_pending().challenger, THIRD);
        _unpark(bob, OTHER, 150 ether);
        _deliver(0, 0, false);
        organism.clearPending();
        assertEq(organism.location(), THIRD);
        assertEq(organism.water(), 50);
        assertEq(organism.backing(), 0);
        assertEq(organism.incompletes(START + 2), 3);
        assertEq(organism.epoch(), 2);
        assertFalse(_pending().exists);
    }

    function test_depositAfterAskMustMatureBeforeItCanChallenge() public {
        _withGardeners();
        _ask();
        _park(bob, OTHER, 150 ether);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), ORIGIN_CELL);
        assertEq(organism.challenger(), 0);
        // Parked on day START+3 while day START+2 was pending: it cannot be nominated until
        // day START+3 itself has settled.
        organism.challenge(OTHER);
        assertEq(organism.challenger(), 0);
        _weather(0, 0);
        organism.challenge(OTHER);
        assertEq(organism.challenger(), OTHER);
        _weather(0, 0);
        assertEq(organism.location(), OTHER);
        assertEq(organism.challenger(), 0);
    }

    function test_moveRewardsDepartingCellAndNeverIncomingCellForSameDay() public {
        _withCommittedCandidate(200 ether);
        _weather(1, 0);
        assertEq(organism.location(), OTHER);
        vm.prank(bob);
        organism.claim();
        assertEq(imd.balanceOf(bob), 0, "incoming cell did not host today's growth");
        vm.prank(alice);
        organism.claim();
        uint256 aliceReward = imd.balanceOf(alice);
        assertGt(aliceReward, 0);
        _weather(1, 0);
        vm.prank(bob);
        organism.claim();
        assertGt(imd.balanceOf(bob), 0, "new cell should earn starting next day");
        vm.prank(alice);
        organism.claim();
        assertEq(imd.balanceOf(alice), aliceReward);
    }

    function test_unparkAfterCallbackDropsOutBeforeHoursAndKeepsPreviousReward() public {
        _withGardeners();
        _weather(1, 0);
        _ask();
        _deliver(1, 0, true);
        _unpark(alice, ORIGIN_CELL, 100 ether);
        uint256 accrued = organism.credits(alice);
        assertGt(accrued, 0);
        uint256 beforeBacking = organism.backing();
        uint256 sip = organism.spendablePot() / 10;
        organism.settle();
        assertEq(organism.backing(), beforeBacking + sip, "no eligible gardeners: whole sip backs PLANT");
        vm.prank(alice);
        organism.claim();
        assertEq(imd.balanceOf(alice), accrued);
        assertEq(organism.gardenerPoints(), 0);
    }

    function test_moveThresholdRoundsUpWhenSupplyNotDivisibleByTwenty() public {
        plant.mint(carol, 1); // remaining supply = 1000e18 + 1, threshold = 50e18 + 1
        _park(alice, OTHER, 50 ether);
        _activationDay();
        organism.challenge(OTHER);
        _weather(0, 0);
        assertEq(organism.location(), ORIGIN_CELL);
        _park(alice, OTHER, 1);
        _weather(0, 0); // Fresh stake cannot meet the threshold yet.
        assertEq(organism.location(), ORIGIN_CELL);
        _weather(0, 0);
        assertEq(organism.location(), OTHER);
    }

    function test_deathClearsPendingAndPreservesGardenersAndFeeDebt() public {
        _withGardeners();
        _weather(1, 0);
        uint256 gardenerReserve = organism.gardenerReserve();
        intake.setPrice(organism.spendablePot() + 2 ether);
        bytes32 id = _ask();
        vm.warp(uint256(organism.lastSettledDay() + 30) * 1 days);
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        (bool ok, bytes memory reason,) = intake.deliver(id, a, _sign(a));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(PlantOrganism.DeadPlant.selector));
        assertFalse(organism.consumed(a.requestId));
        organism.die();
        assertFalse(_pending().exists);
        assertEq(organism.gardenerReserve(), gardenerReserve);
        assertEq(organism.feeAdvances(keeper), 2 ether);
        _unpark(alice, ORIGIN_CELL, 100 ether);
        vm.prank(alice);
        organism.claim();
        assertGt(imd.balanceOf(alice), 0);
        imd.mint(address(organism), 2 ether);
        vm.prank(keeper);
        organism.claim();
        assertEq(organism.owed(), 0);
    }

    function test_rotatedIntakeCannotAnswerPreviousIntakesRequest() public {
        _withGardeners();
        bytes32 id = _ask();
        MockIntake next = new MockIntake();
        address signer = vm.addr(91234);
        bytes32 nextAction = bytes32("oracle.request@oracle-2");
        organism.rotate(
            signer,
            address(next),
            nextAction,
            0,
            type(uint256).max,
            _signDigest(KEY, organism.rotationDigest(signer, address(next), nextAction, 0, type(uint256).max))
        );
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        bytes memory sig = _signDigest(91234, organism.attestationDigest(a));
        vm.prank(address(next));
        vm.expectRevert(PlantOrganism.NotTheIntake.selector);
        organism.onOracleResult(id, a, sig);
        (bool ok,,) = intake.deliver(id, a, sig);
        assertTrue(ok);
        organism.settle();
        intake = next;
        _ask();
        assertEq(intake.lastAction(), nextAction);
        assertEq(_pending().intake, address(next));
    }

    function test_bindRejectsNonContractWrongAndEmptyTokens() public {
        PlantOrganism fresh = _deploy();
        vm.expectRevert(PlantOrganism.WrongHook.selector);
        fresh.bind(alice);
        MockToken empty = new MockToken();
        address[4] memory tokens = [address(imd), address(fresh), alice, address(empty)];
        for (uint256 i; i < tokens.length; ++i) {
            MockHook bad = new MockHook(address(fresh), tokens[i]);
            vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
            fresh.bind(address(bad));
            assertEq(fresh.hook(), address(0), "failed bind must remain recoverable");
        }
        fresh.bind(address(new MockHook(address(fresh), address(plant))));
        assertEq(address(fresh.PLANT()), address(plant));
    }

    function test_zeroAmountsAndOverdrawCannotChangeCustody() public {
        _withGardeners();
        vm.startPrank(alice);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        organism.park(ORIGIN_CELL, 0);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        organism.unpark(ORIGIN_CELL, 0);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        organism.unpark(ORIGIN_CELL, 100 ether + 1);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        organism.redeem(0);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        organism.redeem(1000 ether + 1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        organism.unpark(ORIGIN_CELL, 1);
        assertEq(organism.parked(ORIGIN_CELL, alice), 100 ether);
        assertEq(plant.balanceOf(address(organism)), 100 ether);
        assertEq(organism.burned(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_parkUnparkRoundTripCannotEarnWithoutSettlement(uint96 seed, uint8 repetitions) public {
        uint256 amount = bound(seed, 1, 300 ether);
        uint256 n = bound(repetitions, 1, 20);
        uint256 beforeBalance = plant.balanceOf(bob);
        for (uint256 i; i < n; ++i) {
            _park(bob, OTHER, amount);
            _unpark(bob, OTHER, amount);
        }
        vm.prank(bob);
        organism.claim();
        assertEq(plant.balanceOf(bob), beforeBalance);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(organism.owed(), 0);
        assertEq(organism.totalParked(), 0);
        assertEq(organism.backing(), 0);
    }
}
