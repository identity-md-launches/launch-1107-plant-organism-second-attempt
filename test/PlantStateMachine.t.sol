// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlantOrganism} from "src/PlantOrganism.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {MockToken, MockHook, MockIntake} from "./mocks/Mocks.sol";

/// @notice Independent custody ledger; only the handler can mint, and PLANT supply is fixed after setup.
contract PlantStateMachineHandler is Test {
    PlantOrganism public organism;
    MockToken public imd;
    MockToken public plant;
    MockIntake public intake;
    address[3] public actors;
    uint32[3] public cells = [uint32(10223579), uint32(10354651), uint32(10420186)];
    uint256[3][3] public stake;
    // Per-holder stake retained since the last successful settle. New deposits do not vote yet.
    uint256[3][3] public committed;
    uint256 public donated;
    uint256 public advanced;
    uint256 public fees;
    uint256 public paid;
    uint256 public surrendered;
    uint256 public previousFloor;
    uint256 public previousDay;
    uint256 public deathDay;
    uint256 public serial;
    uint256 public requests;
    uint256 public settlements;
    uint256 public clears;
    uint256 public callbacks;
    uint256 internal constant KEY = 982731;

    constructor() {
        imd = new MockToken();
        plant = new MockToken();
        intake = new MockIntake();
        organism = new PlantOrganism(
            address(imd), address(intake), bytes32("oracle.request@oracle-1"), vm.addr(KEY), cells[0], address(this)
        );
        for (uint256 i; i < 3; ++i) {
            actors[i] = address(uint160(0x1000 + i));
            plant.mint(actors[i], 1000 ether);
            imd.mint(actors[i], 10000 ether);
            vm.startPrank(actors[i]);
            plant.approve(address(organism), type(uint256).max);
            imd.approve(address(organism), type(uint256).max);
            vm.stopPrank();
        }
        organism.bind(address(new MockHook(address(organism), address(plant))));
        previousDay = organism.lastSettledDay();
        // Reach nontrivial biology and accounting before random calls begin.
        donate(3 ether);
        park(0, 0, 200 ether);
        vm.warp(uint256(organism.lastSettledDay() + 2) * 1 days);
        request(0);
        answer(0, 0, true);
        settle();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        request(0);
        answer(1, 0, true);
        settle();
        // A paid, outstanding request exercises asynchronous interleavings on every run.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // Consume the remaining pot and create a real, initially unfunded fee advance.
        intake.setPrice(organism.spendablePot() + 0.5 ether);
        request(1);
        intake.setPrice(0.5 ether);
    }

    function _pending() private view returns (PlantOrganism.Pending memory p) {
        (p.requestId, p.day, p.challenger, p.caller, p.askedAt, p.intake, p.exists, p.received, p.word) =
            organism.pending();
    }

    function _paidToActors() private view returns (uint256 sum) {
        for (uint256 i; i < 3; ++i) {
            sum += imd.balanceOf(actors[i]);
        }
    }

    function _observe() private {
        assertGe(organism.floor(), previousFloor, "floor decreased between operations");
        previousFloor = organism.floor();
        assertGe(organism.lastSettledDay(), previousDay, "settled day went backwards");
        previousDay = organism.lastSettledDay();
        if (deathDay != 0) {
            assertTrue(organism.isDead(), "death was reversed");
            assertEq(organism.lastSettledDay(), deathDay, "dead organism settled again");
        } else if (organism.isDead()) {
            deathDay = organism.lastSettledDay();
        }
    }

    function donate(uint96 seed) public {
        uint256 amount = bound(seed, 1, 100 ether);
        imd.mint(address(organism), amount);
        donated += amount;
        _observe();
    }

    function park(uint8 actorSeed, uint8 cellSeed, uint96 seed) public {
        if (organism.isDead()) return;
        uint256 a = actorSeed % 3;
        uint256 c = cellSeed % 3;
        uint256 balance = plant.balanceOf(actors[a]);
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, balance);
        vm.prank(actors[a]);
        organism.park(cells[c], amount);
        stake[c][a] += amount;
        _observe();
    }

    function unpark(uint8 actorSeed, uint8 cellSeed, uint96 seed) public {
        uint256 a = actorSeed % 3;
        uint256 c = cellSeed % 3;
        if (stake[c][a] == 0) return;
        uint256 amount = bound(seed, 1, stake[c][a]);
        uint256 beforeBalance = plant.balanceOf(actors[a]);
        vm.prank(actors[a]);
        organism.unpark(cells[c], amount);
        stake[c][a] -= amount;
        // Withdraw fresh deposits first; a withdrawn commitment cannot be restored by redepositing.
        if (committed[c][a] > stake[c][a]) committed[c][a] = stake[c][a];
        assertEq(plant.balanceOf(actors[a]), beforeBalance + amount, "unpark must return exact stake");
        _observe();
    }

    function transferPlant(uint8 fromSeed, uint8 toSeed, uint96 seed) external {
        address from = actors[fromSeed % 3];
        uint256 balance = plant.balanceOf(from);
        if (balance == 0) return;
        vm.prank(from);
        plant.transfer(actors[toSeed % 3], bound(seed, 1, balance));
        _observe();
    }

    function redeem(uint8 actorSeed, uint96 seed) public {
        address who = actors[actorSeed % 3];
        uint256 balance = plant.balanceOf(who);
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, balance);
        uint256 beforeBalance = imd.balanceOf(who);
        uint256 quote = amount * organism.floor() / 1e18;
        if (!organism.isDead()) quote = quote * 9 / 10;
        vm.prank(who);
        uint256 payout = organism.redeem(amount);
        assertEq(payout, quote, "redemption differs from advertised floor");
        assertEq(imd.balanceOf(who) - beforeBalance, payout, "redemption token delta");
        surrendered += amount;
        paid += payout;
        _observe();
    }

    function claim(uint8 actorSeed) public {
        uint32[] memory list = new uint32[](3);
        for (uint256 i; i < 3; ++i) {
            list[i] = cells[i];
        }
        address who = actors[actorSeed % 3];
        uint256 beforeBalance = imd.balanceOf(who);
        vm.prank(who);
        organism.claim(list);
        paid += imd.balanceOf(who) - beforeBalance;
        uint256 afterBalance = imd.balanceOf(who);
        vm.prank(who);
        organism.claim(list);
        assertEq(imd.balanceOf(who), afterBalance, "claim is not idempotent");
        _observe();
    }

    function request(uint8 actorSeed) public {
        if (organism.isDead() || _pending().exists) return;
        if (organism.lastSettledDay() + 1 >= organism.today() || block.timestamp < organism.retryAt()) return;
        address who = actors[actorSeed % 3];
        uint256 beforeBalance = imd.balanceOf(who);
        vm.prank(who);
        organism.heartbeat(type(uint256).max);
        advanced += beforeBalance - imd.balanceOf(who);
        fees += intake.price();
        ++requests;
        assertEq(imd.allowance(address(organism), address(intake)), 0, "lingering intake approval");
        _observe();
    }

    function answer(uint24 sun, uint24 rain, bool complete) public {
        PlantOrganism.Pending memory p = _pending();
        if (!p.exists || p.received || organism.isDead()) return;
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("state machine", ++serial));
        a.chainId = 4663;
        a.answerType = 2;
        uint256 word = uint256(p.day) << 96;
        if (complete) word |= uint256(sun) | uint256(rain & ~sun) << 24 | uint256(1) << 48;
        a.answer = abi.encode(bytes32(word));
        a.panelSize = 15;
        a.quorum = 10;
        a.agreed = 10;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, organism.attestationDigest(a));
        uint256 oldBacking = organism.backing();
        uint256 oldWater = organism.water();
        uint256 oldEpoch = organism.epoch();
        (bool ok,,) = intake.deliver(p.requestId, a, abi.encodePacked(r, s, v));
        assertTrue(ok, "valid callback must fit the 200k stipend");
        assertTrue(organism.consumed(a.requestId));
        assertEq(organism.backing(), oldBacking, "callback applied hours");
        assertEq(organism.water(), oldWater, "callback applied water");
        assertEq(organism.epoch(), oldEpoch, "callback advanced epoch");
        ++callbacks;
        _observe();
    }

    function settle() public {
        if (organism.isDead() || organism.lastSettledDay() + 1 >= organism.today()) return;
        if (!_pending().received) return;
        _finish(false);
    }

    // Both a delivered result and the third timeout can advance the same ghost ledger.
    function _finish(bool timeout) private {
        uint256 beforeBalance = _paidToActors();
        uint256 beforeDay = organism.lastSettledDay();
        uint32 beforeLocation = organism.location();
        uint32 capturedCandidate = _pending().challenger;
        uint32 liveCandidate = organism.challenger();
        uint32 expectedLocation = beforeLocation;
        if (_canMove(capturedCandidate, beforeLocation)) expectedLocation = capturedCandidate;
        else if (_canMove(liveCandidate, beforeLocation)) expectedLocation = liveCandidate;
        if (timeout) organism.clearPending();
        else organism.settle();
        paid += _paidToActors() - beforeBalance;
        if (organism.lastSettledDay() > beforeDay) {
            ++settlements;
            uint32 destination = organism.location();
            assertEq(destination, expectedLocation, "READ differs from retained votes");
            if (destination != beforeLocation) {
                assertTrue(
                    destination == capturedCandidate || destination == liveCandidate, "move used an unnominated cell"
                );
                assertGe(_committedStake(destination), _threshold(), "move used uncommitted quorum");
                assertGt(
                    _committedStake(destination), _committedStake(beforeLocation), "move used uncommitted majority"
                );
            }
            for (uint256 c; c < 3; ++c) {
                for (uint256 a; a < 3; ++a) {
                    committed[c][a] = stake[c][a];
                }
            }
        }
        _observe();
    }

    function _threshold() private view returns (uint256) {
        return (3000 ether - surrendered + 19) / 20;
    }

    function _committedStake(uint32 cell) private view returns (uint256) {
        if (cell == 0) return 0;
        for (uint256 c; c < 3; ++c) {
            if (cells[c] == cell) {
                return committed[c][0] + committed[c][1] + committed[c][2];
            }
        }
        revert("untracked cell");
    }

    function _canMove(uint32 candidate, uint32 current) private view returns (bool) {
        return candidate != 0 && candidate != current && _committedStake(candidate) >= _threshold()
            && _committedStake(candidate) > _committedStake(current);
    }

    function clear() external {
        PlantOrganism.Pending memory p = _pending();
        // Incomplete results use settle(), and complete results cannot be discarded.
        if (!p.exists || p.received || block.timestamp < uint256(p.askedAt) + 1 days) return;
        _finish(true);
        ++clears;
        _observe();
    }

    function elapse(uint32 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 1, 36 hours));
        _observe();
    }

    function challenge(uint8 cellSeed) external {
        if (organism.isDead()) return;
        organism.challenge(cells[cellSeed % 3]);
        _observe();
    }

    function assertLedger() public view {
        uint256 held = imd.balanceOf(address(organism));
        assertEq(intake.sequence(), requests, "each heartbeat must create exactly one intake request");
        assertEq(held + fees + paid, donated + advanced, "IMD inflow/outflow ghost ledger");
        assertEq(imd.balanceOf(address(intake)), fees, "oracle fees paid exactly once");
        assertEq(_paidToActors() + advanced, 30000 ether + paid, "actor IMD ledger");
        uint256 allParked;
        uint256 userPlant;
        uint256 credits;
        uint256 advances;
        for (uint256 a; a < 3; ++a) {
            userPlant += plant.balanceOf(actors[a]);
            credits += organism.credits(actors[a]);
            advances += organism.feeAdvances(actors[a]);
        }
        for (uint256 c; c < 3; ++c) {
            uint256 cellSum;
            for (uint256 a; a < 3; ++a) {
                assertEq(organism.parked(cells[c], actors[a]), stake[c][a], "holder stake ghost ledger");
                cellSum += stake[c][a];
            }
            assertEq(organism.parkedTotal(cells[c]), cellSum, "cell aggregation");
            assertEq(
                organism.votingStake(cells[c]),
                _committedStake(cells[c]),
                "vote differs from each holder's retained commitment"
            );
            allParked += cellSum;
        }
        assertEq(organism.totalParked(), allParked);
        assertEq(organism.burned(), surrendered, "burned cannot disappear");
        assertEq(plant.balanceOf(address(organism)), surrendered + allParked, "permanent burn custody");
        assertEq(userPlant + allParked + surrendered, 3000 ether, "fixed PLANT supply");
        assertEq(organism.creditTotal(), credits, "credit aggregation");
        assertEq(organism.feeAdvanceTotal(), advances, "fee advance aggregation");
        assertGe(held, organism.backing() + organism.gardenerReserve() + credits, "senior reserves underfunded");
        assertEq(organism.owed(), organism.gardenerReserve() + credits + advances);
        assertEq(organism.pot() + int256(organism.backing() + organism.owed()), int256(held));
        assertLe(organism.water(), 100);
    }

    /// @notice Every random history must still permit all stake and funded claims to exit after death.
    function closeAll() external {
        vm.warp(vm.getBlockTimestamp() + 31 days);
        organism.die();
        _observe();
        for (uint8 a; a < 3; ++a) {
            for (uint8 c; c < 3; ++c) {
                unpark(a, c, uint96(stake[c][a]));
            }
            claim(a);
        }
        assertEq(organism.totalParked(), 0);
        assertEq(organism.gardenerPoints(), 0, "unclaimable gardener liability");
        assertEq(organism.creditTotal(), 0, "unclaimable credit");
        // Fully fund any oracle deficit, so all outstanding advances must now be repayable.
        uint256 deficit = organism.feeAdvanceTotal();
        imd.mint(address(organism), deficit);
        donated += deficit;
        for (uint8 a; a < 3; ++a) {
            claim(a);
            redeem(a, uint96(plant.balanceOf(actors[a])));
        }
        assertEq(organism.owed(), 0, "all debt must close when funded");
        assertEq(organism.burned(), 3000 ether);
        assertLedger();
    }
}

contract PlantStateMachineInvariantTest is Test {
    PlantStateMachineHandler internal handler;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(20000 days);
        handler = new PlantStateMachineHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.park.selector;
        selectors[2] = handler.unpark.selector;
        selectors[3] = handler.transferPlant.selector;
        selectors[4] = handler.redeem.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.request.selector;
        selectors[7] = handler.answer.selector;
        selectors[8] = handler.settle.selector;
        selectors[9] = handler.clear.selector;
        selectors[10] = handler.elapse.selector;
        selectors[11] = handler.challenge.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_independentCustodyAndSolvency() public view {
        handler.assertLedger();
        assertGt(handler.requests(), 0);
        assertGt(handler.callbacks(), 0);
        assertGt(handler.settlements(), 0);
    }

    function afterInvariant() public {
        handler.closeAll();
    }
}
