// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {WeatherQuestion} from "../src/WeatherQuestion.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockToken, MockHook, MockIntake} from "./mocks/Mocks.sol";

abstract contract PlantTestBase is Test {
    uint256 internal constant KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint32 internal constant ORIGIN_CELL = 10223578;
    uint32 internal constant OTHER = (156 << 16) | 65500;
    uint32 internal constant THIRD = (157 << 16) | 65501;
    uint32 internal constant START = 20000;
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);
    address internal carol = address(0xca201);
    address internal keeper = address(0xbee);
    MockToken internal imd;
    MockToken internal plant;
    MockIntake internal intake;
    PlantOrganism internal organism;
    MockHook internal hook;
    uint256 internal serial;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(uint256(START) * 1 days + 123);
        imd = new MockToken();
        plant = new MockToken();
        intake = new MockIntake();
        plant.mint(alice, 600 ether);
        plant.mint(bob, 300 ether);
        plant.mint(carol, 100 ether);
        organism = _deploy();
        hook = new MockHook(address(organism), address(plant));
        organism.bind(address(hook));
        imd.mint(address(organism), 1000 ether);
        imd.mint(keeper, 100 ether);
        vm.prank(keeper);
        imd.approve(address(organism), type(uint256).max);
        _approve(alice);
        _approve(bob);
        _approve(carol);
    }

    function _deploy() internal returns (PlantOrganism) {
        return new PlantOrganism(address(imd), address(intake), ACTION, vm.addr(KEY), ORIGIN_CELL, address(this));
    }

    function _approve(address who) internal {
        vm.prank(who);
        plant.approve(address(organism), type(uint256).max);
    }

    function _park(address who, uint32 cell, uint256 amount) internal {
        vm.prank(who);
        organism.park(cell, amount);
    }

    function _unpark(address who, uint32 cell, uint256 amount) internal {
        vm.prank(who);
        organism.unpark(cell, amount);
    }

    function _nextEnded() internal {
        uint256 time = uint256(organism.lastSettledDay() + 2) * 1 days;
        if (vm.getBlockTimestamp() < time) vm.warp(time);
    }

    // Mature deposits with an actual complete day. Return its keeper bounty and charge no
    // mock fee so each existing economic test still starts with its explicit 1000 IMD pot.
    function _activationDay() internal {
        uint256 price = intake.price();
        uint256 balance = imd.balanceOf(keeper);
        intake.setPrice(0);
        _weather(0, 0);
        intake.setPrice(price);
        uint256 bounty = imd.balanceOf(keeper) - balance;
        vm.prank(keeper);
        imd.transfer(address(organism), bounty);
    }

    function _withGardeners() internal {
        _park(alice, ORIGIN_CELL, 100 ether);
        _activationDay();
        assertEq(organism.location(), ORIGIN_CELL);
    }

    function _withCommittedCandidate(uint256 amount) internal {
        _park(alice, ORIGIN_CELL, 300 ether);
        _park(bob, OTHER, amount);
        _activationDay();
        assertEq(organism.location(), ORIGIN_CELL);
        _unpark(alice, ORIGIN_CELL, 200 ether);
        organism.challenge(OTHER);
        assertEq(organism.votingStake(OTHER), amount);
    }

    function _ask() internal returns (bytes32 id) {
        _nextEnded();
        vm.prank(keeper);
        id = organism.heartbeat(type(uint256).max);
    }

    function _attestation(uint24 sun, uint24 rain, bool complete)
        internal
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = keccak256(abi.encode("oracle uuid", ++serial));
        a.chainId = 4663;
        a.questionHash = keccak256("resolved document, including the block window");
        a.answerType = 2;
        a.answer = abi.encode(
            bytes32(
                uint256(sun) | uint256(rain) << 24 | (complete ? uint256(1) << 48 : 0)
                    | uint256(organism.lastSettledDay() + 1) << 96
            )
        );
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = bytes32(uint256(7));
        a.panelJobId = keccak256("weather panel");
        a.panelSize = 15;
        a.quorum = 10;
        a.agreed = 12;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return _signDigest(KEY, organism.attestationDigest(a));
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _deliver(uint24 sun, uint24 rain, bool complete) internal returns (uint256 gasUsed) {
        OracleAttestation.Attestation memory a = _attestation(sun, rain, complete);
        (bool ok, bytes memory reason, uint256 gas_) = intake.deliver(intake.lastId(), a, _sign(a));
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        assertTrue(organism.consumed(a.requestId));
        return gas_;
    }

    function _weather(uint24 sun, uint24 rain) internal {
        _ask();
        _deliver(sun, rain, true);
        organism.settle();
    }

    function _settleWithinGasLimit() internal {
        (bool ok, bytes memory reason) = address(organism).call{gas: 400000}(abi.encodeWithSignature("settle()"));
        if (!ok) emit log_bytes(reason);
        assertTrue(ok, "settle must succeed with a 400,000 gas stipend");
    }

    function _conservation() internal view {
        assertEq(
            organism.pot() + int256(organism.backing()) + int256(organism.owed()),
            int256(imd.balanceOf(address(organism)))
        );
        assertEq(plant.balanceOf(address(organism)), organism.burned() + organism.totalParked());
    }

    function _rejected(OracleAttestation.Attestation memory a, bytes memory sig) internal {
        (bool ok,,) = intake.deliver(intake.lastId(), a, sig);
        assertFalse(ok);
        assertFalse(organism.consumed(a.requestId));
    }
}

contract PlantLifecycleTest is PlantTestBase {
    function test_bindIsOnceAndOnlyDeployerWithMatchingHook() public {
        PlantOrganism fresh = _deploy();
        MockHook correct = new MockHook(address(fresh), address(plant));
        vm.expectRevert(PlantOrganism.NotDeployer.selector);
        vm.prank(alice);
        fresh.bind(address(correct));
        vm.expectRevert(PlantOrganism.WrongHook.selector);
        fresh.bind(address(hook));
        fresh.bind(address(correct));
        assertEq(address(fresh.PLANT()), address(plant));
        assertEq(fresh.bindDay(), START);
        vm.expectRevert(PlantOrganism.AlreadyBound.selector);
        fresh.bind(address(correct));
    }

    function test_unboundCatchUpIsBoundedAtOrigin() public {
        PlantOrganism fresh = _deploy();
        vm.expectRevert(PlantOrganism.Unbound.selector);
        fresh.park(ORIGIN_CELL, 1);
        vm.expectRevert(PlantOrganism.Unbound.selector);
        fresh.redeem(1);
        vm.warp(uint256(START + 5000) * 1 days);
        fresh.settle();
        assertEq(fresh.lastSettledDay(), START + 4999);
        assertEq(fresh.water(), 50);
        assertEq(fresh.epoch(), 0);
        assertEq(fresh.location(), ORIGIN_CELL);
        assertFalse(fresh.isDead());
    }

    function test_preBindDaysSkipInOneCallWithoutRead() public {
        PlantOrganism fresh = _deploy();
        vm.warp(uint256(START + 100) * 1 days);
        MockHook correct = new MockHook(address(fresh), address(plant));
        fresh.bind(address(correct));
        vm.startPrank(alice);
        plant.approve(address(fresh), 100 ether);
        fresh.park(ORIGIN_CELL, 100 ether);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        fresh.settle();
        assertEq(fresh.lastSettledDay(), START + 100);
        assertEq(fresh.location(), ORIGIN_CELL);
        assertEq(fresh.epoch(), 0);
        assertEq(fresh.votingStake(ORIGIN_CELL), 0);
        vm.expectRevert(PlantOrganism.NoResult.selector);
        fresh.settle();
    }

    function test_noEarlyOrOutOfOrderSettleAndHeartbeat() public {
        vm.expectRevert(PlantOrganism.DayNotEnded.selector);
        organism.settle();
        vm.expectRevert(PlantOrganism.WrongDay.selector);
        organism.settle(START + 2);
        vm.expectRevert(PlantOrganism.DayNotEnded.selector);
        organism.heartbeat(type(uint256).max);
        _nextEnded();
        organism.heartbeat(0);
    }

    function test_challengerOnlyStrictlyLargerAndCanBeRepaired() public {
        _park(alice, THIRD, 100 ether);
        _park(bob, OTHER, 100 ether);
        assertEq(organism.challenger(), 0);
        _activationDay();
        organism.challenge(THIRD);
        organism.challenge(OTHER);
        assertEq(organism.challenger(), THIRD); // Equal retained stake cannot replace it.
        _unpark(alice, THIRD, 1);
        organism.challenge(OTHER);
        assertEq(organism.challenger(), OTHER);
        _unpark(bob, OTHER, 100 ether);
        organism.challenge(THIRD);
        assertEq(organism.challenger(), THIRD);
        _weather(0, 0);
        assertEq(organism.location(), THIRD);
        assertEq(organism.challenger(), 0);
        organism.challenge(THIRD);
        assertEq(organism.challenger(), 0);
    }

    function test_moveUsesPendingCandidateAndRemainingCommittedBalances() public {
        _withCommittedCandidate(150 ether);
        _ask();
        _park(alice, THIRD, 200 ether);
        _deliver(1, 0, true);
        organism.settle();
        assertEq(organism.location(), OTHER);
        assertEq(organism.challenger(), 0);
        organism.challenge(THIRD);
        _ask();
        _unpark(alice, THIRD, 199 ether);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), OTHER);
    }

    function test_cellBoundsAndZeroRejected() public {
        uint32[5] memory invalid = [
            uint32(0),
            uint32(360 << 16),
            uint32(uint32(uint16(int16(-361))) << 16),
            uint32((155 << 16) | 720),
            uint32((155 << 16) | uint16(int16(-721)))
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(WeatherQuestion.InvalidCell.selector);
            organism.challenge(invalid[i]);
        }
        _park(alice, (uint32(uint16(int16(-360))) << 16) | uint16(int16(-720)), 1);
        _park(alice, (359 << 16) | 719, 1);
    }

    function test_deathIsFinalAtThirtyDaysAndKeepsExits() public {
        _withGardeners();
        _weather(1, 0);
        uint256 existingFloor = organism.floor();
        uint32 last = organism.lastSettledDay();
        vm.warp(uint256(last + 30) * 1 days - 1);
        assertFalse(organism.isDead());
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(organism.isDead());
        uint256 merged = organism.spendablePot();
        uint256 oldBacking = organism.backing();
        organism.die();
        assertEq(organism.backing(), oldBacking + merged);
        assertEq(organism.pot(), 0);
        vm.expectRevert(PlantOrganism.DeadPlant.selector);
        organism.heartbeat(type(uint256).max);
        vm.expectRevert(PlantOrganism.DeadPlant.selector);
        organism.park(ORIGIN_CELL, 1);
        _nextEnded();
        vm.expectRevert(PlantOrganism.DeadPlant.selector);
        organism.settle();
        _unpark(alice, ORIGIN_CELL, 100 ether);
        uint256 quote = organism.floor();
        assertGe(quote, existingFloor);
        vm.prank(alice);
        uint256 payout = organism.redeem(100 ether);
        assertEq(payout, 100 * quote);
        vm.prank(alice);
        organism.claim();
        _conservation();
        imd.mint(address(organism), 100 ether);
        uint256 newBacking = organism.backing();
        organism.die();
        assertEq(organism.backing(), newBacking + 100 ether);
    }

    function test_deathUsesBindDayAfterLongUnboundPeriod() public {
        PlantOrganism fresh = _deploy();
        vm.warp(uint256(START + 1000) * 1 days);
        fresh.bind(address(new MockHook(address(fresh), address(plant))));
        assertFalse(fresh.isDead());
        vm.warp(vm.getBlockTimestamp() + 30 days);
        fresh.die();
        assertTrue(fresh.dead());
    }
}

contract PlantOracleTest is PlantTestBase {
    function test_exactApprovalAndIntakeBody() public {
        _withGardeners();
        _ask();
        assertEq(intake.lastBody(), organism.requestBody(ORIGIN_CELL, START + 2));
        assertEq(intake.allowanceAtRequest(), intake.price());
        assertEq(imd.allowance(address(organism), address(intake)), 0);
        assertEq(intake.lastAction(), ACTION);
        assertEq(intake.lastAsset(), address(imd));
        (address target, bytes4 selector) = intake.callback();
        assertEq(target, address(organism));
        assertEq(selector, organism.onOracleResult.selector);
        vm.expectRevert(PlantOrganism.RequestPending.selector);
        organism.heartbeat(type(uint256).max);
    }

    function test_callbackStoresOnlyAndFitsStipend() public {
        _withGardeners();
        _ask();
        uint256 gasUsed = _deliver(0x555555, 0xaaaaaa, true);
        emit log_named_uint("callback gas including mock encoding", gasUsed);
        assertEq(organism.water(), 50);
        assertEq(organism.backing(), 0);
        assertEq(organism.lastSettledDay(), START + 1);
        _settleWithinGasLimit();
        assertEq(organism.lastSettledDay(), START + 2);
        _conservation();
    }

    function test_callbackSenderIdAndReplay() public {
        _withGardeners();
        bytes32 id = _ask();
        OracleAttestation.Attestation memory a = _attestation(1, 0, true);
        bytes memory sig = _sign(a);
        vm.expectRevert(PlantOrganism.NotTheIntake.selector);
        organism.onOracleResult(id, a, sig);
        vm.expectRevert(PlantOrganism.UnknownRequest.selector);
        vm.prank(address(intake));
        organism.onOracleResult(bytes32(uint256(123)), a, sig);
        (bool ok,,) = intake.deliver(id, a, sig);
        assertTrue(ok);
        (ok,,) = intake.deliver(id, a, sig);
        assertFalse(ok);
        organism.settle();
        (ok,,) = intake.deliver(id, a, sig);
        assertFalse(ok);
        _ask();
        a.answer = abi.encode(bytes32(uint256(1) << 48 | uint256(organism.lastSettledDay() + 1) << 96));
        (ok,,) = intake.deliver(intake.lastId(), a, _sign(a));
        assertFalse(ok);
        assertTrue(organism.consumed(a.requestId));
    }

    function test_rejectsExpiredWrongDomainSignerTypeDayChainAndPanel() public {
        _withGardeners();
        _ask();
        OracleAttestation.Attestation memory a = _attestation(1, 0, true);
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        _rejected(a, _sign(a));
        a = _attestation(1, 0, true);
        _rejected(a, _signDigest(77, organism.attestationDigest(a)));
        PlantOrganism neighbor = _deploy();
        _rejected(a, _signDigest(KEY, neighbor.attestationDigest(a)));
        vm.chainId(1);
        bytes memory wrongChainDomain = _sign(a);
        vm.chainId(4663);
        _rejected(a, wrongChainDomain);
        a.answerType = 3;
        _rejected(a, _sign(a));
        a = _attestation(1, 0, true);
        a.answer = abi.encode(bytes32(uint256(1) << 48 | uint256(START + 99) << 96));
        _rejected(a, _sign(a));
        a = _attestation(1, 0, true);
        a.chainId = 1;
        _rejected(a, _sign(a));
        a = _attestation(1, 0, true);
        a.panelSize = 14;
        _rejected(a, _sign(a));
        a.panelSize = 15;
        a.quorum = 9;
        _rejected(a, _sign(a));
        a.quorum = 10;
        a.agreed = 9;
        _rejected(a, _sign(a));
        a.agreed = 16;
        _rejected(a, _sign(a));
    }

    function test_rejectsPreAskFutureTamperedAndMalformedAttestations() public {
        _withGardeners();
        _ask();
        OracleAttestation.Attestation memory a = _attestation(1, 0, true);
        a.issuedAt = uint64(vm.getBlockTimestamp() - 1);
        _rejected(a, _sign(a));
        a.issuedAt = uint64(vm.getBlockTimestamp() + 301);
        _rejected(a, _sign(a));
        a = _attestation(1, 0, true);
        bytes memory signature = _sign(a);
        a.figure = 1;
        _rejected(a, signature);
        a = _attestation(1, 1, true);
        _rejected(a, _sign(a));
        a = _attestation(1, 0, false);
        _rejected(a, _sign(a));
        a = _attestation(0, 0, true);
        a.answer = abi.encode(bytes32(uint256(1) << 255));
        _rejected(a, _sign(a));
        a.answer = hex"01";
        _rejected(a, _sign(a));
        _deliver(0, 0, true);
    }

    function test_timeoutClearsAndWaitsSixHoursToReaskSameDay() public {
        _withGardeners();
        bytes32 oldId = _ask();
        vm.expectRevert(PlantOrganism.NotTimedOut.selector);
        organism.clearPending();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        organism.clearPending();
        assertEq(organism.lastSettledDay(), START + 1);
        assertEq(organism.incompletes(START + 2), 1);
        vm.expectRevert(PlantOrganism.RetryLater.selector);
        organism.heartbeat(type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 6 hours - 1);
        vm.expectRevert(PlantOrganism.RetryLater.selector);
        organism.heartbeat(type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1);
        bytes32 id = _ask();
        assertTrue(id != oldId);
        OracleAttestation.Attestation memory a = _attestation(1, 0, true);
        (bool ok,,) = intake.deliver(oldId, a, _sign(a));
        assertFalse(ok);
        _deliver(1, 0, true);
        organism.settle();
    }

    function test_incompleteHasNoBiologicalChangesThenThirdReads() public {
        _withCommittedCandidate(200 ether);
        for (uint8 i = 1; i <= 3; ++i) {
            _ask();
            _deliver(0, 0, false);
            uint256 backing = organism.backing();
            uint256 owed = organism.owed();
            organism.settle();
            assertEq(organism.incompletes(START + 2), i);
            assertEq(organism.water(), 50);
            assertEq(organism.backing(), backing);
            assertEq(organism.owed(), owed);
            if (i < 3) {
                assertEq(organism.lastSettledDay(), START + 1);
                assertEq(organism.location(), ORIGIN_CELL);
                assertEq(organism.epoch(), 1);
                vm.expectRevert(PlantOrganism.RetryLater.selector);
                organism.heartbeat(type(uint256).max);
                vm.warp(vm.getBlockTimestamp() + 6 hours);
            }
        }
        assertEq(organism.lastSettledDay(), START + 2);
        assertEq(organism.location(), OTHER);
        assertEq(organism.retryAt(), 0);
    }

    function test_clearIncompleteUsesSameCounterAndCannotDiscardComplete() public {
        _withGardeners();
        _ask();
        _deliver(0, 0, false);
        organism.clearPending();
        assertEq(organism.incompletes(START + 2), 1);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _ask();
        _deliver(0, 0, true);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(PlantOrganism.NotTimedOut.selector);
        organism.clearPending();
        organism.settle();
    }

    function test_feeAdvanceTracksDeficitThenRepaidAtSettle() public {
        _withGardeners();
        intake.setPrice(1002 ether);
        imd.mint(keeper, 10000 ether);
        uint256 beforeBalance = imd.balanceOf(keeper);
        _ask();
        assertEq(organism.feeAdvances(keeper), 2 ether);
        assertEq(organism.pot(), -int256(2 ether));
        _conservation();
        vm.prank(keeper);
        organism.claim();
        assertEq(imd.balanceOf(keeper), beforeBalance - 2 ether);
        imd.mint(address(organism), 102 ether);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.feeAdvances(keeper), 0);
        assertEq(imd.balanceOf(keeper), beforeBalance + 1 ether);
        _conservation();
    }

    function test_unfundedAdvanceDoesNotSpendBackingOrBlockSettle() public {
        _withGardeners();
        _weather(0xffffff, 0);
        uint256 backing = organism.backing();
        uint256 debt = 2 ether;
        intake.setPrice(organism.spendablePot() + debt);
        _ask();
        _deliver(1, 0, true);
        organism.settle();
        assertEq(organism.backing(), backing);
        assertEq(organism.feeAdvances(keeper), debt);
        assertEq(organism.pot(), -int256(debt));
        imd.mint(address(organism), debt);
        vm.prank(keeper);
        organism.claim();
        assertEq(organism.feeAdvances(keeper), 0);
        assertEq(organism.pot(), 0);
        _conservation();
    }

    function test_blockedKeeperDoesNotBlockSettleAndCanClaimLater() public {
        _withGardeners();
        _ask();
        _deliver(1, 0, true);
        imd.setBlocked(keeper, true);
        organism.settle();
        assertGt(organism.credits(keeper), 0);
        uint256 credit = organism.credits(keeper);
        uint256 beforeBalance = imd.balanceOf(keeper);
        imd.setBlocked(keeper, false);
        vm.prank(keeper);
        organism.claim();
        assertEq(imd.balanceOf(keeper), beforeBalance + credit);
        assertEq(organism.credits(keeper), 0);
        _conservation();
    }

    function test_intakeMustPullExactPrice() public {
        _withGardeners();
        intake.setUndercharge(true);
        _nextEnded();
        vm.expectRevert(PlantOrganism.NonExactTransfer.selector);
        organism.heartbeat(type(uint256).max);
        assertEq(imd.allowance(address(organism), address(intake)), 0);
    }
}

contract PlantRewardsTest is PlantTestBase {
    function test_parkSettleClaimProRataAndMidDayJoinsWaitOneSettle() public {
        _withGardeners();
        _park(bob, ORIGIN_CELL, 100 ether);
        _weather(1, 0);
        uint256 firstPool = uint256(999.5 ether / 10) / 3;
        vm.prank(alice);
        organism.claim();
        assertApproxEqAbs(imd.balanceOf(alice), firstPool, 100);
        vm.prank(bob);
        organism.claim();
        assertEq(imd.balanceOf(bob), 0);
        uint256 oldAlice = imd.balanceOf(alice);
        _weather(1, 0);
        vm.prank(alice);
        organism.claim();
        vm.prank(bob);
        organism.claim();
        assertEq(imd.balanceOf(alice) - oldAlice, imd.balanceOf(bob));
        _conservation();
    }

    function test_departuresDropOutAndReparkingCannotCaptureDay() public {
        _withGardeners();
        _park(bob, ORIGIN_CELL, 100 ether);
        _weather(0, 0);
        _unpark(alice, ORIGIN_CELL, 100 ether);
        _park(alice, ORIGIN_CELL, 100 ether);
        _weather(1, 0);
        vm.prank(alice);
        organism.claim();
        assertEq(imd.balanceOf(alice), 0);
        vm.prank(bob);
        organism.claim();
        assertGt(imd.balanceOf(bob), 0);
        _unpark(alice, ORIGIN_CELL, 50 ether);
        _unpark(bob, ORIGIN_CELL, 100 ether);
        _weather(1, 0);
        vm.prank(alice);
        organism.claim();
        assertGt(imd.balanceOf(alice), 0);
        _conservation();
    }

    function test_oldCellKeepsItsRewardsAfterMoveAndLazyActivation() public {
        _withCommittedCandidate(200 ether);
        _weather(1, 0);
        assertEq(organism.location(), OTHER);
        assertEq(organism.lastRewardCell(), ORIGIN_CELL);
        _weather(1, 0);
        _park(alice, THIRD, 300 ether);
        _weather(0, 0); // Mature the destination stake before proposing a move.
        organism.challenge(THIRD);
        _weather(1, 0);
        assertEq(organism.location(), THIRD);
        _weather(1, 0);
        uint32[] memory cells = new uint32[](3);
        cells[0] = ORIGIN_CELL;
        cells[1] = OTHER;
        cells[2] = THIRD;
        vm.prank(alice);
        organism.claim(cells);
        vm.prank(bob);
        organism.claim(cells);
        assertGt(imd.balanceOf(alice), 0);
        assertGt(imd.balanceOf(bob), 0);
        uint256 total = imd.balanceOf(alice) + imd.balanceOf(bob);
        vm.prank(alice);
        organism.claim(cells);
        vm.prank(bob);
        organism.claim(cells);
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), total);
        assertEq(organism.gardenerPoints(), 0);
        _conservation();
    }

    function test_noGardenersSendsEntireSipToBacking() public {
        uint256 sip = (1000 ether - intake.price()) / 10;
        _weather(1, 0);
        assertEq(organism.backing(), sip);
        assertEq(organism.gardenerReserve(), 0);
    }

    function test_hourZeroFirstRainCapAndSunRequiresWater() public {
        _withGardeners();
        _weather(0xffffff, 0);
        assertEq(organism.water(), 26);
        _weather(0xffffff, 0);
        assertEq(organism.water(), 2);
        _weather(0xffffff, 0);
        assertEq(organism.water(), 0);
        uint256 beforeBacking = organism.backing();
        _weather(0xfffffe, 1); // hour zero rain allows only hours 1,2,3 to sip.
        assertEq(organism.water(), 0);
        assertGt(organism.backing(), beforeBacking);
        _weather(0, 0xffffff);
        assertEq(organism.water(), 72);
        _weather(0, 0xffffff);
        assertEq(organism.water(), 100);
        _conservation();
    }

    function test_gardenerDustRoundsToBackingAndAccountsCloseExactly() public {
        // Small indivisible stakes exercise both global and individual fractional rounding.
        _park(alice, ORIGIN_CELL, 50 ether);
        _activationDay();
        _unpark(alice, ORIGIN_CELL, 50 ether);
        _park(alice, ORIGIN_CELL, 3);
        _park(bob, ORIGIN_CELL, 7);
        _weather(0, 0);
        for (uint256 i; i < 4; ++i) {
            _weather(0x155555, 0);
        }
        uint256 oldBacking = organism.backing();
        _unpark(alice, ORIGIN_CELL, 3);
        _unpark(bob, ORIGIN_CELL, 7);
        vm.prank(alice);
        organism.claim();
        vm.prank(bob);
        organism.claim();
        assertEq(organism.gardenerPoints(), 0);
        assertEq(organism.owed(), 0);
        assertGe(organism.backing(), oldBacking);
        _conservation();
    }

    function test_redeemRetainsPlantAndTenPercentAndFloorMonotonic() public {
        _withGardeners();
        _weather(0xffffff, 0);
        uint256 quote = organism.floor();
        uint256 oldBacking = organism.backing();
        _unpark(alice, ORIGIN_CELL, 100 ether);
        vm.prank(alice);
        uint256 payout = organism.redeem(100 ether);
        assertEq(payout, 100 * quote * 9 / 10);
        assertEq(organism.backing(), oldBacking - payout);
        assertGe(organism.floor(), quote);
        assertEq(organism.burned(), 100 ether);
        assertEq(plant.balanceOf(address(organism)), 100 ether);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        vm.prank(alice);
        organism.unpark(ORIGIN_CELL, 1);
        _conservation();
    }

    function test_finalRedemptionDoesNotDivideByZeroOrReleaseBurnedPlant() public {
        _withGardeners();
        _weather(1, 0);
        _unpark(alice, ORIGIN_CELL, 100 ether);
        vm.prank(alice);
        organism.redeem(600 ether);
        vm.prank(bob);
        organism.redeem(300 ether);
        uint256 quote = organism.floor();
        vm.prank(carol);
        organism.redeem(100 ether);
        assertEq(organism.floor(), quote);
        assertEq(organism.burned(), plant.totalSupply());
        assertEq(plant.balanceOf(address(organism)), plant.totalSupply());
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        organism.redeem(1);
        _conservation();
    }

    function test_nonExactTokenTransfersRejected() public {
        plant.setTransferFee(100);
        vm.expectRevert(PlantOrganism.NonExactTransfer.selector);
        vm.prank(alice);
        organism.park(ORIGIN_CELL, 100 ether);
        assertEq(organism.totalParked(), 0);
        vm.expectRevert(PlantOrganism.NonExactTransfer.selector);
        vm.prank(alice);
        organism.redeem(100 ether);
        assertEq(organism.burned(), 0);
    }

    function test_reentrancyFromTokensAndIntakeBlocked() public {
        plant.setReentry(address(organism), abi.encodeWithSignature("park(uint32,uint256)", ORIGIN_CELL, 1));
        _withGardeners();
        assertTrue(plant.reentryAttempted());
        assertFalse(plant.reentrySucceeded());
        intake.setReenter(true);
        _weather(1, 0);
        assertFalse(intake.reentrySucceeded());
        imd.setReentry(address(organism), abi.encodeWithSignature("claim()"));
        vm.prank(alice);
        organism.claim();
        assertTrue(imd.reentryAttempted());
        assertFalse(imd.reentrySucceeded());
        _conservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_hourlyAccountingMatchesIndependentModel(uint24 sun, uint24 rain) public {
        _withGardeners();
        rain &= ~sun;
        uint256 remaining = 1000 ether - intake.price();
        uint256 wet = 50;
        uint256 totalSips;
        uint256 pool;
        for (uint256 hour; hour < 24; ++hour) {
            if ((rain >> hour) & 1 == 1) wet = wet > 97 ? 100 : wet + 3;
            if ((sun >> hour) & 1 == 1 && wet != 0) {
                wet -= 1;
                uint256 sip = remaining / 10;
                remaining -= sip;
                totalSips += sip;
                pool += sip / 3;
            }
        }
        _weather(sun, rain);
        // Exactly 100e18 eligible base units: reward-per-token truncation reserves whole 100s.
        uint256 reserved = pool / 100 * 100;
        assertEq(organism.water(), wet);
        assertEq(organism.gardenerReserve(), reserved);
        assertEq(organism.backing(), totalSips - reserved);
        assertEq(organism.pot(), int256(remaining - remaining / 100));
        _conservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_floorConservationAndBurnCustody(uint96 donation, uint96 redemption, uint24 sun) public {
        _withGardeners();
        imd.mint(address(organism), donation);
        _weather(sun, 0);
        uint256 quote = organism.floor();
        uint256 amount = bound(redemption, 1, 300 ether);
        vm.prank(bob);
        organism.redeem(amount);
        assertGe(organism.floor(), quote);
        _conservation();
        _unpark(alice, ORIGIN_CELL, 100 ether);
        vm.prank(alice);
        organism.claim();
        assertEq(plant.balanceOf(address(organism)), organism.burned());
        _conservation();
    }
}

contract PlantRotationTest is PlantTestBase {
    uint256 private constant NEW_KEY = 91234;

    function _rotate(MockIntake next, uint256 key) private {
        uint256 nonce = organism.rotationNonce();
        bytes32 digest = organism.rotationDigest(vm.addr(NEW_KEY), address(next), ACTION, nonce, type(uint256).max);
        organism.rotate(vm.addr(NEW_KEY), address(next), ACTION, nonce, type(uint256).max, _signDigest(key, digest));
    }

    function test_onlyCurrentSignerCanRotateNonceCannotReplay() public {
        MockIntake next = new MockIntake();
        bytes32 digest = organism.rotationDigest(vm.addr(NEW_KEY), address(next), ACTION, 0, type(uint256).max);
        bytes memory sig = _signDigest(KEY, digest);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(NEW_KEY), address(next), ACTION, 0, type(uint256).max, _signDigest(777, digest));
        organism.rotate(vm.addr(NEW_KEY), address(next), ACTION, 0, type(uint256).max, sig);
        assertEq(organism.oracleSigner(), vm.addr(NEW_KEY));
        assertEq(address(organism.intake()), address(next));
        assertEq(organism.rotationNonce(), 1);
        vm.expectRevert(PlantOrganism.InvalidNonce.selector);
        organism.rotate(vm.addr(NEW_KEY), address(next), ACTION, 0, type(uint256).max, sig);
        bytes memory oldSignerSig =
            _signDigest(KEY, organism.rotationDigest(vm.addr(NEW_KEY), address(next), ACTION, 1, type(uint256).max));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(NEW_KEY), address(next), ACTION, 1, type(uint256).max, oldSignerSig);
        _rotate(next, NEW_KEY);
    }

    function test_rotationDomainBindsAllFieldsAndContract() public {
        MockIntake next = new MockIntake();
        bytes32 digest = organism.rotationDigest(vm.addr(NEW_KEY), address(next), ACTION, 0, type(uint256).max);
        bytes memory sig = _signDigest(KEY, digest);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(NEW_KEY), address(intake), ACTION, 0, type(uint256).max, sig);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(NEW_KEY), address(next), bytes32("oracle.request@oracle-2"), 0, type(uint256).max, sig);
        vm.chainId(1);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(NEW_KEY), address(next), ACTION, 0, type(uint256).max, sig);
        vm.chainId(4663);
        PlantOrganism neighbor = _deploy();
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        neighbor.rotate(vm.addr(NEW_KEY), address(next), ACTION, 0, type(uint256).max, sig);
    }

    function test_pendingIntakeAndOldSignerWorkAfterRotation() public {
        _withGardeners();
        _ask();
        MockIntake next = new MockIntake();
        _rotate(next, KEY);
        _deliver(1, 0, true);
        assertEq(organism.oracleSigner(), vm.addr(NEW_KEY));
        organism.settle();
        intake = next;
        _ask();
        OracleAttestation.Attestation memory a = _attestation(1, 0, true);
        bytes memory sig = _signDigest(NEW_KEY, organism.attestationDigest(a));
        (bool ok,,) = intake.deliver(intake.lastId(), a, sig);
        assertTrue(ok);
        organism.settle();
    }

    function test_oldSignerExpiresAtThirtyDaysWhileNewSignerKeepsPlantAlive() public {
        _withGardeners();
        uint256 rotatedAt = vm.getBlockTimestamp();
        _rotate(intake, KEY);
        uint256 expiry = rotatedAt + 30 days;
        while (vm.getBlockTimestamp() < expiry) {
            _ask();
            OracleAttestation.Attestation memory a = _attestation(0, 0, true);
            if (vm.getBlockTimestamp() < expiry) {
                _deliver(0, 0, true); // old signer, during grace
            } else {
                _rejected(a, _sign(a));
                (bool ok,,) = intake.deliver(intake.lastId(), a, _signDigest(NEW_KEY, organism.attestationDigest(a)));
                assertTrue(ok);
            }
            organism.settle();
        }
        assertFalse(organism.isDead());
        assertEq(organism.oracleSigner(), vm.addr(NEW_KEY));
    }
}
