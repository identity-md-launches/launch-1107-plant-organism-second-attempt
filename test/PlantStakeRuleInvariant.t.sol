// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockToken, MockHook, MockIntake} from "./mocks/Mocks.sol";

/// @notice Drives the plant with random parks, withdrawals, nominations, complete days, silent
/// days and same-call flashes, and keeps its own ledger of the one stake rule the launch states:
/// stake[cell] is PLANT parked behind the cell by a day that has already settled, withdrawn stake
/// drops out at once, and live balances never count. The ledger is a list of dated deposits per
/// holder; it never reads the body's positions, reward index, batches or activation checkpoints.
contract PlantStakeRuleHandler is Test {
    struct Deposit {
        uint32 day;
        uint256 amount;
    }

    PlantOrganism public organism;
    MockToken public imd;
    MockToken public plant;
    MockIntake public intake;
    uint256 internal constant KEY = 5150;
    uint32 internal constant ORIGIN = 10223578;
    uint32[3] public cells = [ORIGIN, uint32((156 << 16) | 65500), uint32((157 << 16) | 65501)];
    address[3] public actors = [address(0xA1), address(0xB2), address(0xC3)];
    address public constant FLASHER = address(0xF1A5);
    mapping(uint32 => mapping(address => Deposit[])) internal ledger;
    uint256 public serial;
    uint256 public moves;
    uint256 public silentMoves;
    uint256 public flashes;
    uint256 public nominations;

    constructor() {
        imd = new MockToken();
        plant = new MockToken();
        intake = new MockIntake();
        intake.setPrice(0);
        organism = new PlantOrganism(
            address(imd), address(intake), bytes32("oracle.request@oracle-1"), vm.addr(KEY), ORIGIN, address(this)
        );
        for (uint256 i; i < 3; ++i) {
            plant.mint(actors[i], 400 ether);
            vm.prank(actors[i]);
            plant.approve(address(organism), type(uint256).max);
        }
        // The flasher alone holds more than every honest gardener together.
        plant.mint(FLASHER, 2000 ether);
        vm.prank(FLASHER);
        plant.approve(address(organism), type(uint256).max);
        organism.bind(address(new MockHook(address(organism), address(plant))));
        imd.mint(address(organism), 10000 ether);
    }

    // ---- the rule, stated once ----

    function matureThrough() public view returns (uint32) {
        uint32 last = organism.lastSettledDay();
        uint32 bindDay = organism.bindDay();
        return last > bindDay ? last : bindDay - 1;
    }

    function ghostStake(uint32 cell) public view returns (uint256 total) {
        uint32 through = matureThrough();
        for (uint256 i; i < 3; ++i) {
            Deposit[] storage list = ledger[cell][actors[i]];
            for (uint256 j; j < list.length; ++j) {
                if (list[j].day <= through) total += list[j].amount;
            }
        }
    }

    function ghostParked(uint32 cell, address who) public view returns (uint256 total) {
        Deposit[] storage list = ledger[cell][who];
        for (uint256 j; j < list.length; ++j) {
            total += list[j].amount;
        }
    }

    function threshold() public view returns (uint256) {
        return Math.ceilDiv(plant.totalSupply() - organism.burned(), 20);
    }

    /// @dev READ as the launch states it: the committed candidate first, the live one second.
    function _expectedDestination(uint32 candidate) private view returns (uint32) {
        uint32 current = organism.location();
        uint256 currentStake = ghostStake(current);
        if (_wins(candidate, current, currentStake)) return candidate;
        uint32 live = organism.challenger();
        if (live != candidate && _wins(live, current, currentStake)) return live;
        return current;
    }

    function _wins(uint32 candidate, uint32 current, uint256 currentStake) private view returns (bool) {
        if (candidate == 0 || candidate == current) return false;
        uint256 stake = ghostStake(candidate);
        return stake > currentStake && stake >= threshold();
    }

    // ---- operations ----

    function park(uint8 actorSeed, uint8 cellSeed, uint96 amountSeed) external {
        if (organism.isDead()) return;
        address who = actors[actorSeed % 3];
        uint32 cell = cells[cellSeed % 3];
        uint256 balance = plant.balanceOf(who);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        uint32 previous = organism.challenger();
        vm.prank(who);
        organism.park(cell, amount);
        ledger[cell][who].push(Deposit(organism.today(), amount));
        _nominationRule(cell, previous);
    }

    function unpark(uint8 actorSeed, uint8 cellSeed, uint96 amountSeed) external {
        address who = actors[actorSeed % 3];
        uint32 cell = cells[cellSeed % 3];
        uint256 held = organism.parked(cell, who);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        vm.prank(who);
        organism.unpark(cell, amount);
        // Newest deposits leave first; the stake total is what the rule cares about.
        Deposit[] storage list = ledger[cell][who];
        uint256 remaining = amount;
        while (remaining != 0) {
            Deposit storage last = list[list.length - 1];
            if (last.amount <= remaining) {
                remaining -= last.amount;
                list.pop();
            } else {
                last.amount -= remaining;
                remaining = 0;
            }
        }
        assertEq(organism.parked(cell, who), ghostParked(cell, who), "position mismatch after withdrawal");
    }

    function challenge(uint8 cellSeed) external {
        if (organism.isDead()) return;
        uint32 cell = cells[cellSeed % 3];
        uint32 previous = organism.challenger();
        organism.challenge(cell);
        _nominationRule(cell, previous);
    }

    function _nominationRule(uint32 cell, uint32 previous) private {
        uint32 expected = previous;
        if (cell != organism.location() && ghostStake(cell) > ghostStake(previous)) {
            expected = cell;
            ++nominations;
        }
        assertEq(organism.challenger(), expected, "nomination must follow settled stake only");
    }

    function claim(uint8 actorSeed) external {
        uint32[] memory list = new uint32[](3);
        for (uint256 i; i < 3; ++i) {
            list[i] = cells[i];
        }
        vm.prank(actors[actorSeed % 3]);
        organism.claim(list);
    }

    /// @dev One complete weather day, settled from a delivered result.
    function weather(uint24 sun, uint24 rain) external {
        if (!_ready()) return;
        bytes32 id = organism.heartbeat(type(uint256).max);
        (,, uint32 candidate,,,,,,) = organism.pending();
        _deliver(id, sun, rain);
        _settleAndCheck(candidate, false);
    }

    /// @dev Three silent requests for the same day: cleared as unanswered after 24 hours each, the
    /// third one settles the day empty and performs READ with the same stake rule.
    function silentDay() external {
        if (!_ready()) return;
        // Three strikes take ninety hours; refuse to start if that would run into the death clock.
        uint256 deathAt = uint256(Math.max(organism.bindDay(), organism.lastSettledDay()) + 30) * 1 days;
        if (vm.getBlockTimestamp() + 5 days >= deathAt) return;
        uint32 day = organism.lastSettledDay() + 1;
        uint32 candidate;
        for (uint256 strike; strike < 3; ++strike) {
            organism.heartbeat(type(uint256).max);
            (,, candidate,,,,,,) = organism.pending();
            vm.warp(vm.getBlockTimestamp() + 1 days);
            if (strike < 2) {
                organism.clearPending();
                assertEq(organism.lastSettledDay(), day - 1, "a strike below three must not settle");
                assertEq(organism.incompletes(day), strike + 1);
                vm.warp(organism.retryAt());
            }
        }
        uint8 water = organism.water();
        uint256 backing = organism.backing();
        _settleAndCheck(candidate, true);
        assertEq(organism.water(), water, "an empty day has no hours");
        assertEq(organism.backing(), backing, "an empty day has no sips");
        assertEq(organism.lastSettledDay(), day);
    }

    /// @dev A same-call park, settle and withdraw by a holder richer than everyone else.
    function flashSettle(uint8 cellSeed, uint24 sun, uint16 amountSeed) external {
        if (!_ready()) return;
        uint32 cell = cells[cellSeed % 3];
        bytes32 id = organism.heartbeat(type(uint256).max);
        (,, uint32 candidate,,,,,,) = organism.pending();
        _deliver(id, sun, 0);
        uint256 amount = bound(amountSeed, 1, 2000 ether);
        uint32 previous = organism.challenger();
        vm.startPrank(FLASHER);
        organism.park(cell, amount);
        organism.challenge(cell);
        vm.stopPrank();
        // Only settled honest stake at the cell can nominate it; the flash itself never does.
        _nominationRule(cell, previous);
        _settleAndCheck(candidate, false);
        vm.prank(FLASHER);
        organism.unpark(cell, amount);
        ++flashes;
    }

    function _ready() private returns (bool) {
        if (organism.isDead()) return false;
        uint256 ended = uint256(organism.lastSettledDay() + 2) * 1 days;
        if (vm.getBlockTimestamp() < ended) vm.warp(ended);
        if (organism.isDead()) return false;
        (,,,,,, bool exists,,) = organism.pending();
        return !exists;
    }

    function _deliver(bytes32 id, uint24 sun, uint24 rain) private {
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("stake rule", ++serial));
        a.chainId = 4663;
        a.answerType = 2;
        a.answer = abi.encode(
            bytes32(
                uint256(sun) | uint256(rain & ~sun) << 24 | uint256(1) << 48 | uint256(organism.lastSettledDay() + 1)
                    << 96
            )
        );
        a.panelSize = 15;
        a.quorum = 10;
        a.agreed = 10;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, organism.attestationDigest(a));
        (bool ok,,) = intake.deliver(id, a, abi.encodePacked(r, s, v));
        assertTrue(ok, "callback rejected a well-formed result");
    }

    function _settleAndCheck(uint32 candidate, bool silent) private {
        uint32 before = organism.location();
        uint32 expected = _expectedDestination(candidate);
        uint256 homeStake = ghostStake(before);
        uint256 reserve = organism.gardenerReserve();
        if (silent) organism.clearPending();
        else organism.settle();
        assertEq(organism.location(), expected, "READ must follow the stated stake rule");
        if (expected != before) {
            assertEq(organism.challenger(), 0, "a move clears the nomination");
            ++moves;
            if (silent) ++silentMoves;
        }
        // The gardener pool goes to settled stake at the departing cell, or to backing when none.
        if (homeStake == 0 || silent) assertEq(organism.gardenerReserve(), reserve, "pool without gardeners");
    }
}

/// forge-config: default.invariant.runs = 200
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PlantStakeRuleInvariantTest is StdInvariant, Test {
    PlantStakeRuleHandler internal handler;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(20000 days + 1);
        handler = new PlantStakeRuleHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.park.selector;
        selectors[1] = handler.unpark.selector;
        selectors[2] = handler.challenge.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.weather.selector;
        selectors[5] = handler.silentDay.selector;
        selectors[6] = handler.flashSettle.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_votingStakeIsSettledParkedStakeAndNeverALiveBalance() public view {
        PlantOrganism o = handler.organism();
        uint256 parkedSum;
        for (uint256 i; i < 3; ++i) {
            uint32 cell = handler.cells(i);
            uint256 stake = o.votingStake(cell);
            assertEq(stake, handler.ghostStake(cell), "votingStake drifted from the dated ledger");
            assertLe(stake, o.parkedTotal(cell), "stake above what is parked");
            parkedSum += o.parkedTotal(cell);
            for (uint256 j; j < 3; ++j) {
                address who = handler.actors(j);
                assertEq(o.parked(cell, who), handler.ghostParked(cell, who), "position drifted");
            }
            assertEq(o.parked(cell, handler.FLASHER()), 0, "a flash leaves nothing behind");
        }
        assertEq(parkedSum, o.totalParked());
        assertEq(handler.plant().balanceOf(address(o)), o.totalParked() + o.burned(), "PLANT custody");
        assertEq(o.credits(handler.FLASHER()), 0, "a flash earns no gardening credit");
        assertTrue(o.location() != 0, "the plant always has a location");
        assertTrue(o.challenger() != o.location(), "the location cannot be its own challenger");
    }

    function afterInvariant() public view {
        PlantOrganism o = handler.organism();
        // A flash parker never earns even through a checkpoint on every cell it touched.
        for (uint256 i; i < 3; ++i) {
            (uint256 active,,,) = o.positions(handler.cells(i), handler.FLASHER());
            assertEq(active, 0);
        }
    }
}
