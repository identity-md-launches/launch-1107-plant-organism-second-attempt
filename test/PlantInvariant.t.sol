// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockToken, MockHook, MockIntake} from "./mocks/Mocks.sol";

contract PlantHandler is Test {
    PlantOrganism public organism;
    MockToken public imd;
    MockToken public plant;
    MockIntake public intake;
    uint256 public previousFloor;
    uint256 public serial;
    uint256 internal constant KEY = 918273;
    uint32[3] internal cells = [uint32(10223579), uint32(10354651), uint32(10420186)];
    address[3] internal actors = [address(0x111), address(0x222), address(0x333)];

    constructor() {
        imd = new MockToken();
        plant = new MockToken();
        intake = new MockIntake();
        intake.setPrice(0);
        organism = new PlantOrganism(
            address(imd), address(intake), bytes32("oracle.request@oracle-1"), vm.addr(KEY), cells[0], address(this)
        );
        for (uint256 i; i < 3; ++i) {
            plant.mint(actors[i], 1000 ether);
            vm.prank(actors[i]);
            plant.approve(address(organism), type(uint256).max);
        }
        organism.bind(address(new MockHook(address(organism), address(plant))));
        imd.mint(address(organism), 10000 ether);
    }

    function _check() private {
        assertGe(organism.floor(), previousFloor, "floor decreased");
        previousFloor = organism.floor();
        assertEq(
            organism.pot() + int256(organism.backing()) + int256(organism.owed()),
            int256(imd.balanceOf(address(organism)))
        );
        assertEq(plant.balanceOf(address(organism)), organism.totalParked() + organism.burned());
    }

    function fund(uint96 amount) external {
        imd.mint(address(organism), amount);
        _check();
    }

    function park(uint8 actorSeed, uint8 cellSeed, uint96 amountSeed) external {
        address who = actors[actorSeed % 3];
        uint256 balance = plant.balanceOf(who);
        if (balance == 0) return;
        vm.prank(who);
        organism.park(cells[cellSeed % 3], bound(amountSeed, 1, balance));
        _check();
    }

    function unpark(uint8 actorSeed, uint8 cellSeed, uint96 amountSeed) external {
        address who = actors[actorSeed % 3];
        uint32 cell = cells[cellSeed % 3];
        uint256 balance = organism.parked(cell, who);
        if (balance == 0) return;
        vm.prank(who);
        organism.unpark(cell, bound(amountSeed, 1, balance));
        _check();
    }

    function redeem(uint8 actorSeed, uint96 amountSeed) external {
        address who = actors[actorSeed % 3];
        uint256 balance = plant.balanceOf(who);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        uint256 quote = amount * organism.floor() / 1e18;
        if (!organism.isDead()) quote = quote * 9 / 10;
        if (quote == 0) return; // Zero-payout redemptions are refused.
        vm.prank(who);
        organism.redeem(amount);
        _check();
    }

    function claim(uint8 actorSeed) external {
        uint32[] memory list = new uint32[](3);
        for (uint256 i; i < 3; ++i) {
            list[i] = cells[i];
        }
        vm.prank(actors[actorSeed % 3]);
        organism.claim(list);
        _check();
    }

    function challenge(uint8 cellSeed) external {
        organism.challenge(cells[cellSeed % 3]);
        _check();
    }

    function weather(uint24 sun, uint24 rain) external {
        vm.warp(uint256(organism.lastSettledDay() + 2) * 1 days);
        {
            bytes32 id = organism.heartbeat(type(uint256).max);
            OracleAttestation.Attestation memory a;
            a.requestId = keccak256(abi.encode(++serial));
            a.chainId = 4663;
            a.answerType = 2;
            a.answer = abi.encode(
                bytes32(
                    uint256(sun) | uint256(rain & ~sun) << 24 | uint256(1) << 48
                        | uint256(organism.lastSettledDay() + 1) << 96
                )
            );
            a.panelSize = 15;
            a.quorum = 10;
            a.agreed = 10;
            a.issuedAt = uint64(vm.getBlockTimestamp());
            a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, organism.attestationDigest(a));
            (bool ok,,) = intake.deliver(id, a, abi.encodePacked(r, s, v));
            assertTrue(ok);
        }
        organism.settle();
        _check();
    }

    function checkpointAll() external {
        for (uint256 c; c < 3; ++c) {
            for (uint256 a; a < 3; ++a) {
                organism.checkpoint(cells[c], actors[a]);
            }
        }
        assertEq(organism.gardenerPoints(), 0, "orphan fractional liability");
        _check();
    }
}

contract PlantInvariantTest is StdInvariant, Test {
    PlantHandler internal handler;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(20000 days);
        handler = new PlantHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.park.selector;
        selectors[2] = handler.unpark.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.challenge.selector;
        selectors[6] = handler.weather.selector;
        selectors[7] = handler.checkpointAll.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_conservationAndPermanentBurnCustody() public view {
        PlantOrganism o = handler.organism();
        assertEq(o.pot() + int256(o.backing()) + int256(o.owed()), int256(handler.imd().balanceOf(address(o))));
        assertEq(handler.plant().balanceOf(address(o)), o.burned() + o.totalParked());
        assertGe(o.floor(), handler.previousFloor());
        assertLe(o.water(), 100);
        assertLe(o.burned(), handler.plant().totalSupply());
    }

    function afterInvariant() public {
        handler.checkpointAll();
    }
}
