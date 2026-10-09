// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {WeatherQuestion} from "../src/WeatherQuestion.sol";
import {MockToken, MockIntake} from "./mocks/Mocks.sol";

/// @dev Parks, nominates, asks, delivers a pre-signed answer, settles and withdraws in one call.
contract SingleTransactionFlasher {
    PlantOrganism internal immutable organism;
    MockToken internal immutable plant;
    MockIntake internal immutable intake;

    constructor(PlantOrganism organism_, MockToken plant_, MockIntake intake_) {
        organism = organism_;
        plant = plant_;
        intake = intake_;
        plant_.approve(address(organism_), type(uint256).max);
    }

    function flash(uint32 cell, OracleAttestation.Attestation calldata a, bytes calldata sig)
        external
        returns (uint32 nominated, bool delivered)
    {
        uint256 amount = plant.balanceOf(address(this));
        organism.park(cell, amount);
        organism.challenge(cell);
        nominated = organism.challenger();
        organism.heartbeat(type(uint256).max);
        (delivered,,) = intake.deliver(intake.lastId(), a, sig);
        organism.settle();
        organism.unpark(cell, amount);
    }

    function claim() external {
        organism.claim();
    }
}

/// @notice Pins the launch revision's structure: a plant born at deployment with no birth
/// machinery, an origin derived from real coordinates, and stake that is never a live balance.
contract PlantOriginRegressionTest is PlantTestBase {
    /// @dev Parses the exact "[-]D.ddd" coordinate text the question embeds back to microdegrees.
    function _microdegrees(string memory text) private pure returns (int256 micro) {
        bytes memory b = bytes(text);
        bool negative = b[0] == "-";
        uint256 i = negative ? 1 : 0;
        uint256 whole;
        while (b[i] != ".") {
            whole = whole * 10 + (uint8(b[i]) - 48);
            ++i;
        }
        ++i;
        assertEq(b.length - i, 3, "coordinate must carry exactly three decimals");
        uint256 fraction;
        for (; i < b.length; ++i) {
            fraction = fraction * 10 + (uint8(b[i]) - 48);
        }
        micro = int256(whole * 1000000 + fraction * 1000);
        if (negative) micro = -micro;
    }

    function _quarterOf(int256 micro) private pure returns (int256 q) {
        q = micro / 250000;
        if (micro < 0 && micro % 250000 != 0) --q;
    }

    function _pack(int16 lat, int16 lon) private pure returns (uint32) {
        return uint32(uint16(lat)) << 16 | uint16(lon);
    }

    function _absent(string memory signature) private {
        (bool ok, bytes memory data) = address(organism).call(abi.encodeWithSignature(signature));
        assertFalse(ok, string.concat(signature, " must not exist"));
        assertEq(data.length, 0, string.concat(signature, " must fall through to no fallback"));
    }

    function test_noBirthOrAdminSelectorsExist() public {
        // Birth machinery removed by the revision.
        _absent("FALLBACK_CELL()");
        _absent("birthSettles()");
        _absent("birthSettles(uint32)");
        _absent("birth()");
        _absent("born()");
        // No admin, upgrade, pause, ownership or roles.
        _absent("owner()");
        _absent("transferOwnership(address)");
        _absent("renounceOwnership()");
        _absent("pause()");
        _absent("unpause()");
        _absent("paused()");
        _absent("upgradeTo(address)");
        _absent("upgradeToAndCall(address,bytes)");
        _absent("implementation()");
        _absent("proxiableUUID()");
        _absent("hasRole(bytes32,address)");
        _absent("grantRole(bytes32,address)");
        _absent("setOracleSigner(address)");
        // Plain value sent to the body is refused as well: there is no receive or fallback.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(organism).call{value: 1}("");
        assertFalse(ok);
    }

    function test_originSentenceNamesThePlaceAndItsReasonOnce() public view {
        bytes memory origin = bytes(organism.ORIGIN());
        assertEq(organism.ORIGIN_CELL(), 10223578);
        assertEq(organism.location(), organism.ORIGIN_CELL());
        bytes memory prefix = "Sintra: ";
        for (uint256 i; i < prefix.length; ++i) {
            assertEq(uint8(origin[i]), uint8(prefix[i]), "ORIGIN must start with '<place>: '");
        }
        uint256 stops;
        for (uint256 i; i < origin.length; ++i) {
            if (origin[i] == ".") ++stops;
            assertTrue(origin[i] != "\n", "ORIGIN is one line");
        }
        assertEq(stops, 1, "ORIGIN is exactly one sentence");
        assertEq(uint8(origin[origin.length - 1]), uint8(bytes1(".")));
        // The same sentence is what launch.json and README.md carry.
        assertEq(
            keccak256(origin),
            keccak256("Sintra: Its gardens bring native and exotic trees together on forested hills.")
        );
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everyValidCellRoundTripsThroughItsPrintedCentre(int16 latQ, int16 lonQ) public pure {
        latQ = int16(bound(int256(latQ), -360, 359));
        lonQ = int16(bound(int256(lonQ), -720, 719));
        if (latQ == 0 && lonQ == 0) lonQ = 1;
        uint32 cell = _pack(latQ, lonQ);
        WeatherQuestion.validate(cell);
        // Unpacking is the inverse of packing.
        assertEq(int16(uint16(cell >> 16)), latQ);
        assertEq(int16(uint16(cell)), lonQ);
        // The printed centre lies strictly inside the quarter-degree cell and floors back to it.
        int256 latMicro = _microdegrees(WeatherQuestion.coordinate(latQ));
        int256 lonMicro = _microdegrees(WeatherQuestion.coordinate(lonQ));
        assertEq(latMicro, int256(latQ) * 250000 + 125000);
        assertEq(lonMicro, int256(lonQ) * 250000 + 125000);
        assertEq(_quarterOf(latMicro), latQ);
        assertEq(_quarterOf(lonMicro), lonQ);
        assertEq(_pack(int16(_quarterOf(latMicro)), int16(_quarterOf(lonMicro))), cell);
        // Nudging the centre by one microdegree never leaves the cell; a full quarter does.
        assertEq(_quarterOf(latMicro - 124999), latQ);
        assertEq(_quarterOf(latMicro + 124999), latQ);
        assertEq(_quarterOf(latMicro + 125000), int256(latQ) + 1);
        assertEq(_quarterOf(lonMicro - 125000), lonQ); // The lower edge belongs to the cell.
        assertEq(_quarterOf(lonMicro - 125001), int256(lonQ) - 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_constructorAcceptsEveryLandOrSeaCellAndRejectsTheRest(int16 latQ, int16 lonQ) public {
        uint32 cell = _pack(latQ, lonQ);
        bool valid = latQ >= -360 && latQ <= 359 && lonQ >= -720 && lonQ <= 719 && cell != 0;
        if (!valid) vm.expectRevert(WeatherQuestion.InvalidCell.selector);
        PlantOrganism fresh =
            new PlantOrganism(address(imd), address(intake), ACTION, vm.addr(KEY), cell, address(this));
        if (!valid) return;
        assertEq(fresh.location(), cell);
        assertEq(fresh.ORIGIN_CELL(), cell);
        assertEq(fresh.lastSettledDay(), START);
        assertEq(fresh.water(), 50);
        assertEq(fresh.hook(), address(0));
        assertFalse(fresh.isDead());
        // question() has no special case: it is the deployment cell and the next unsettled day.
        assertEq(fresh.question(), WeatherQuestion.question(cell, START + 1));
        assertEq(fresh.requestBody(cell, START + 1), WeatherQuestion.body(cell, START + 1));
    }

    function test_constructorRejectsEveryZeroDependency() public {
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        new PlantOrganism(address(0), address(intake), ACTION, vm.addr(KEY), ORIGIN_CELL, address(this));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        new PlantOrganism(address(imd), address(0), ACTION, vm.addr(KEY), ORIGIN_CELL, address(this));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        new PlantOrganism(address(imd), address(intake), bytes32(0), vm.addr(KEY), ORIGIN_CELL, address(this));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        new PlantOrganism(address(imd), address(intake), ACTION, vm.addr(KEY), ORIGIN_CELL, address(0));
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new PlantOrganism(address(imd), address(intake), ACTION, address(0), ORIGIN_CELL, address(this));
        vm.expectRevert(WeatherQuestion.InvalidCell.selector);
        new PlantOrganism(address(imd), address(intake), ACTION, vm.addr(KEY), 0, address(this));
    }

    function test_livePlantBalancesNeverCountAsStakeAnywhere() public {
        // 600 PLANT sent straight to the body and 300 held by bob are live balances, not stake.
        vm.prank(alice);
        plant.transfer(address(organism), 600 ether);
        _park(carol, OTHER, 60 ether);
        _activationDay();
        assertEq(organism.totalParked(), 60 ether);
        assertEq(organism.votingStake(ORIGIN_CELL), 0);
        assertEq(organism.votingStake(OTHER), 60 ether);
        assertEq(organism.votingStake(THIRD), 0);
        organism.challenge(ORIGIN_CELL);
        organism.challenge(THIRD);
        assertEq(organism.challenger(), 0);
        organism.challenge(OTHER);
        assertEq(organism.challenger(), OTHER);
        // Threshold is 5% of 1000 PLANT supply minus nothing burned: 50. 60 parked beats 0 at home.
        _weather(0, 0);
        assertEq(organism.location(), OTHER);
        assertEq(organism.challenger(), 0);
        // The donated PLANT stays a live balance: it earns nothing and votes for nobody.
        _weather(0xffffff, 0);
        assertEq(organism.votingStake(ORIGIN_CELL), 0);
        assertEq(organism.credits(alice), 0);
        assertGt(organism.credits(carol) + organism.gardenerReserve(), 0);
        assertEq(plant.balanceOf(address(organism)), 660 ether);
        assertEq(organism.totalParked() + organism.burned(), 60 ether);
    }

    function test_flashParkWithinOneTransactionNeverMovesOrEarns() public {
        _withCommittedCandidate(100 ether); // alice 100 at origin, bob 100 at OTHER, OTHER nominated.
        _unpark(bob, OTHER, 100 ether);
        organism.challenge(ORIGIN_CELL); // Cannot nominate the location; the stale nomination stays.
        assertEq(organism.challenger(), OTHER);
        assertEq(organism.votingStake(OTHER), 0);
        SingleTransactionFlasher flasher = new SingleTransactionFlasher(organism, plant, intake);
        vm.prank(alice);
        plant.transfer(address(flasher), 500 ether);
        _nextEnded();
        OracleAttestation.Attestation memory a = _attestation(0xffffff, 0, true);
        bytes memory sig = _sign(a);
        uint256 gardenersBefore = organism.gardenerReserve();
        (uint32 nominated, bool delivered) = flasher.flash(THIRD, a, sig);
        assertTrue(delivered);
        assertEq(nominated, OTHER, "a same-day deposit cannot nominate");
        assertEq(organism.location(), ORIGIN_CELL, "a same-day deposit cannot move the plant");
        assertEq(organism.challenger(), OTHER);
        assertEq(organism.votingStake(THIRD), 0);
        assertEq(organism.parked(THIRD, address(flasher)), 0);
        assertEq(plant.balanceOf(address(flasher)), 500 ether);
        assertEq(organism.credits(address(flasher)), 0);
        assertGt(organism.gardenerReserve(), gardenersBefore, "alice's matured stake earned the day");
        // The keeper bounty for asking is the only IMD the flasher ever sees; nothing more accrues.
        uint256 bounty = imd.balanceOf(address(flasher));
        assertGt(bounty, 0, "asking still pays the keeper bounty");
        flasher.claim();
        assertEq(imd.balanceOf(address(flasher)), bounty);
        SingleTransactionFlasher first = flasher;
        flasher = new SingleTransactionFlasher(organism, plant, intake);
        vm.prank(address(first));
        plant.transfer(address(flasher), 500 ether);
        _nextEnded();
        a = _attestation(0xffffff, 0, true);
        sig = _sign(a);
        uint256 aliceCredits = organism.credits(alice);
        organism.checkpoint(ORIGIN_CELL, alice);
        uint256 reserveBefore = organism.gardenerReserve();
        (nominated, delivered) = flasher.flash(ORIGIN_CELL, a, sig);
        assertTrue(delivered);
        organism.checkpoint(ORIGIN_CELL, alice);
        assertEq(organism.credits(address(flasher)), 0, "a flash at the location earns nothing");
        assertEq(organism.parked(ORIGIN_CELL, address(flasher)), 0);
        assertGt(organism.credits(alice), aliceCredits, "the standing gardener keeps the whole pool");
        assertEq(organism.gardenerReserve(), reserveBefore);
        bounty = imd.balanceOf(address(flasher));
        uint32[] memory cells = new uint32[](1);
        cells[0] = ORIGIN_CELL;
        vm.prank(address(flasher));
        organism.claim(cells);
        flasher.claim();
        assertEq(imd.balanceOf(address(flasher)), bounty);
        _conservation();
    }

    function test_rotateRequiresDeadlineFromSignedStructNotCalldataAlone() public {
        MockIntake next = new MockIntake();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = organism.rotationDigest(vm.addr(555), address(next), ACTION, 0, deadline);
        bytes memory sig = _signDigest(KEY, digest);
        // A later deadline than the one signed is a different struct: bad signature, not expiry.
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(555), address(next), ACTION, 0, deadline + 1 days, sig);
        // One second past the signed deadline is expired even with the right signature.
        vm.warp(deadline + 1);
        vm.expectRevert(PlantOrganism.RotationExpired.selector);
        organism.rotate(vm.addr(555), address(next), ACTION, 0, deadline, sig);
        assertEq(organism.rotationNonce(), 0);
        assertEq(address(organism.intake()), address(intake));
        // A zero deadline can never be used: it expired before the chain's clock started.
        bytes memory zero = _signDigest(KEY, organism.rotationDigest(vm.addr(555), address(next), ACTION, 0, 0));
        vm.expectRevert(PlantOrganism.RotationExpired.selector);
        organism.rotate(vm.addr(555), address(next), ACTION, 0, 0, zero);
        // Unbounded deadline is accepted; the nonce then blocks every replay of it.
        bytes memory open =
            _signDigest(KEY, organism.rotationDigest(vm.addr(555), address(next), ACTION, 0, type(uint256).max));
        organism.rotate(vm.addr(555), address(next), ACTION, 0, type(uint256).max, open);
        assertEq(organism.oracleSigner(), vm.addr(555));
        vm.expectRevert(PlantOrganism.InvalidNonce.selector);
        organism.rotate(vm.addr(555), address(next), ACTION, 0, type(uint256).max, open);
    }

    function test_heartbeatCapIsExactAndPendingNeverFormsOnRefusal() public {
        _nextEnded();
        intake.setPrice(1000 ether + 7);
        uint256 keeperBefore = imd.balanceOf(keeper);
        vm.expectRevert(PlantOrganism.AdvanceTooLarge.selector);
        vm.prank(keeper);
        organism.heartbeat(6);
        (,,,,,, bool exists,,) = organism.pending();
        assertFalse(exists);
        assertEq(imd.balanceOf(keeper), keeperBefore);
        assertEq(organism.owed(), 0);
        vm.prank(keeper);
        organism.heartbeat(7);
        (,,,,,, exists,,) = organism.pending();
        assertTrue(exists);
        assertEq(keeperBefore - imd.balanceOf(keeper), 7);
        assertEq(organism.feeAdvances(keeper), 7);
        assertEq(organism.lockedAdvances(keeper), 7);
        assertEq(organism.pot(), -7);
        _conservation();
    }
}
