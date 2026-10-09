// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlantOrganism} from "src/PlantOrganism.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {MockToken, MockHook, MockIntake} from "./mocks/Mocks.sol";

/// @notice Eager, per-holder ledger checked against the organism's lazy cell/epoch accounting.
/// It never reads positions, rewardPerToken or activationCheckpoint to compute entitlement.
contract PlantRewardOwnershipHandler is Test {
    PlantOrganism public organism;
    MockToken public imd;
    MockToken public plant;
    MockIntake public intake;
    address[3] public actors;
    uint32[3] public cells = [uint32(10223578), uint32(10354651), uint32(10420186)];
    uint256[3][3] public deposited;
    uint256[3][3] public eligible;
    uint256[3][3] public points;
    uint256[3] public credit;
    uint256[3] public paid;
    uint256[3] public lastCell;
    uint256 public lastReward;
    uint256 public donations;
    uint256 public serial;
    uint256 public rewardedDays;
    uint256 public moves;
    uint256 private constant SCALE = 1e18;
    uint256 private constant KEY = 648921;

    constructor() {
        imd = new MockToken();
        plant = new MockToken();
        intake = new MockIntake();
        intake.setPrice(0);
        organism = new PlantOrganism(
            address(imd), address(intake), bytes32("oracle.request@oracle-1"), vm.addr(KEY), cells[0], address(this)
        );
        for (uint256 a; a < 3; ++a) {
            actors[a] = vm.addr(8100 + a);
            plant.mint(actors[a], 1000 ether);
            vm.prank(actors[a]);
            plant.approve(address(organism), type(uint256).max);
        }
        organism.bind(address(new MockHook(address(organism), address(plant))));
        park(0, 0, 100 ether);
        park(1, 1, 200 ether);
        park(2, 2, 300 ether);
        grow(100 ether); // Activation has no gardener rewards.
        challenge(1);
        grow(100 ether); // Origin earns, then move.
        challenge(2);
        grow(100 ether); // Second cell earns, then move.
        grow(100 ether); // Third cell earns; all three retain unclaimed rewards.
    }

    function _checkpoint(uint256 a, uint256 c) private {
        credit[a] += points[c][a] / SCALE;
        points[c][a] = 0; // The documented per-checkpoint fractional dust goes to backing.
    }

    function park(uint8 actorSeed, uint8 cellSeed, uint96 seed) public {
        uint256 a = actorSeed % 3;
        uint256 c = cellSeed % 3;
        uint256 available = plant.balanceOf(actors[a]);
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available);
        vm.prank(actors[a]);
        organism.park(cells[c], amount);
        _checkpoint(a, c);
        deposited[c][a] += amount;
        lastCell[a] = c;
    }

    function unpark(uint8 actorSeed, uint8 cellSeed, uint96 seed) public {
        uint256 a = actorSeed % 3;
        uint256 c = cellSeed % 3;
        if (deposited[c][a] == 0) return;
        uint256 amount = bound(seed, 1, deposited[c][a]);
        vm.prank(actors[a]);
        organism.unpark(cells[c], amount);
        _checkpoint(a, c);
        deposited[c][a] -= amount;
        if (eligible[c][a] > deposited[c][a]) eligible[c][a] = deposited[c][a];
    }

    function checkpoint(uint8 actorSeed, uint8 cellSeed) external {
        uint256 a = actorSeed % 3;
        uint256 c = cellSeed % 3;
        // An unrelated caller may checkpoint but cannot receive this holder's credit.
        organism.checkpoint(cells[c], actors[a]);
        _checkpoint(a, c);
    }

    function blockPayment(uint8 actorSeed, bool blocked) external {
        imd.setBlocked(actors[actorSeed % 3], blocked);
    }

    function _payment(uint256 a) private {
        if (!imd.blocked(actors[a])) {
            paid[a] += credit[a];
            credit[a] = 0;
        }
        assertEq(imd.balanceOf(actors[a]), paid[a], "holder received somebody else's reward");
    }

    function claimSome(uint8 actorSeed, uint8 firstSeed, uint8 secondSeed) public {
        uint256 a = actorSeed % 3;
        uint256 c = firstSeed % 3;
        uint256 d = secondSeed % 3;
        uint32[] memory list = new uint32[](3);
        list[0] = cells[c];
        list[1] = cells[d];
        list[2] = cells[c]; // Repeated historical cells must not double-pay.
        vm.prank(actors[a]);
        organism.claim(list);
        _checkpoint(a, c);
        _checkpoint(a, d);
        _payment(a);
    }

    function claimDefault(uint8 actorSeed) external {
        uint256 a = actorSeed % 3;
        vm.prank(actors[a]);
        organism.claim();
        _checkpoint(a, lastCell[a]);
        _checkpoint(a, lastReward);
        _payment(a);
    }

    function challenge(uint8 cellSeed) public {
        organism.challenge(cells[cellSeed % 3]);
    }

    function _totals() private view returns (uint256 allPoints, uint256 allCredits) {
        for (uint256 a; a < 3; ++a) {
            allCredits += credit[a];
            for (uint256 c; c < 3; ++c) {
                allPoints += points[c][a];
            }
        }
    }

    function grow(uint96 donationSeed) public {
        uint256 donation = bound(donationSeed, 1, 100 ether);
        donations += donation;
        imd.mint(address(organism), donation);
        uint256 c;
        while (cells[c] != organism.location()) ++c;
        (uint256 allPoints, uint256 allCredits) = _totals();
        uint256 reserve = (allPoints + SCALE - 1) / SCALE;
        uint256 available = imd.balanceOf(address(organism)) - organism.backing() - reserve - allCredits;
        // Rain at hour 0 guarantees water for exactly one sip at hour 1.
        uint256 pool = (available / 10) / 3;
        uint256 stake = eligible[c][0] + eligible[c][1] + eligible[c][2];
        if (stake != 0 && pool != 0) {
            uint256 rate = pool * SCALE / stake;
            for (uint256 a; a < 3; ++a) {
                points[c][a] += eligible[c][a] * rate;
            }
            ++rewardedDays;
        }
        vm.warp(uint256(organism.lastSettledDay() + 2) * 1 days);
        bytes32 id = organism.heartbeat(0);
        OracleAttestation.Attestation memory attestation;
        attestation.requestId = keccak256(abi.encode("ownership", ++serial));
        attestation.chainId = 4663;
        attestation.answerType = 2;
        attestation.answer = abi.encode(
            bytes32(uint256(2) | uint256(1) << 24 | uint256(1) << 48 | uint256(organism.lastSettledDay() + 1) << 96)
        );
        attestation.panelSize = 15;
        attestation.quorum = 10;
        attestation.agreed = 10;
        attestation.issuedAt = uint64(vm.getBlockTimestamp());
        attestation.expiresAt = attestation.issuedAt + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, organism.attestationDigest(attestation));
        (bool ok,,) = intake.deliver(id, attestation, abi.encodePacked(r, s, v));
        assertTrue(ok, "callback failed under 200k stipend");
        organism.settle();
        if (organism.location() != cells[c]) ++moves;
        lastReward = c;
        for (uint256 a; a < 3; ++a) {
            for (uint256 cell; cell < 3; ++cell) {
                eligible[cell][a] = deposited[cell][a];
            }
        }
    }

    function assertOwnership() public view {
        (uint256 allPoints, uint256 allCredits) = _totals();
        assertEq(organism.gardenerPoints(), allPoints, "unassigned or missing gardener points");
        assertEq(organism.creditTotal(), allCredits, "credit total differs from earned credit");
        uint256 totalPaid = imd.balanceOf(address(this)); // Keeper bounties have a separate recipient.
        uint256 totalParked;
        for (uint256 a; a < 3; ++a) {
            assertEq(organism.credits(actors[a]), credit[a], "credit belongs to wrong holder");
            assertEq(imd.balanceOf(actors[a]), paid[a], "unexpected holder payout");
            totalPaid += paid[a];
            uint256 holderParked;
            for (uint256 c; c < 3; ++c) {
                assertEq(organism.parked(cells[c], actors[a]), deposited[c][a]);
                holderParked += deposited[c][a];
            }
            assertEq(plant.balanceOf(actors[a]) + holderParked, 1000 ether, "stake lost or created");
            totalParked += holderParked;
        }
        assertEq(plant.balanceOf(address(organism)), totalParked);
        assertEq(organism.totalParked(), totalParked);
        assertEq(plant.totalSupply(), 3000 ether);
        assertEq(imd.balanceOf(address(organism)) + totalPaid, donations, "IMD conservation");
        assertGe(imd.balanceOf(address(organism)), organism.backing() + (allPoints + SCALE - 1) / SCALE + allCredits);
    }

    function closeAll() external {
        vm.warp(vm.getBlockTimestamp() + 31 days);
        organism.die();
        for (uint8 a; a < 3; ++a) {
            imd.setBlocked(actors[a], false);
            for (uint8 c; c < 3; ++c) {
                unpark(a, c, uint96(deposited[c][a]));
            }
            claimSome(a, 0, 1);
            claimSome(a, 2, 2);
        }
        assertOwnership();
        assertEq(organism.owed(), 0, "all funded gardening rewards must be withdrawable");
        assertEq(organism.totalParked(), 0);
    }
}

contract PlantRewardOwnershipInvariantTest is Test {
    PlantRewardOwnershipHandler private handler;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(20000 days);
        handler = new PlantRewardOwnershipHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.park.selector;
        selectors[1] = handler.unpark.selector;
        selectors[2] = handler.checkpoint.selector;
        selectors[3] = handler.blockPayment.selector;
        selectors[4] = handler.claimSome.selector;
        selectors[5] = handler.claimDefault.selector;
        selectors[6] = handler.challenge.selector;
        selectors[7] = handler.grow.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_eachGardenerOwnsExactlyTheirEarnedRewards() public view {
        handler.assertOwnership();
        assertGe(handler.rewardedDays(), 3);
        assertGe(handler.moves(), 2);
    }

    function afterInvariant() public {
        handler.closeAll();
    }
}
