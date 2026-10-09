// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockHook} from "./mocks/Mocks.sol";

contract GasAndDeploymentTest is PlantTestBase {
    function test_settlementFitsStipendWithManyEligibleHolders() public {
        _withGardeners();
        for (uint256 i; i < 128; ++i) {
            address holder = address(uint160(0x10000 + i));
            vm.prank(bob);
            plant.transfer(holder, 1 ether);
            vm.startPrank(holder);
            plant.approve(address(organism), 1 ether);
            organism.park(ORIGIN_CELL, 1 ether);
            vm.stopPrank();
        }
        _weather(0, 0); // Activate every newly parked holder for the following settle.
        vm.record();
        _ask();
        _deliver(0xffffff, 0, true);
        _cool(address(organism));
        _cool(address(imd));
        _cool(address(plant));
        _settleWithinGasLimit();
        assertEq(organism.lastSettledDay(), START + 3);
        assertGt(organism.gardenerReserve(), 0);
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

    function test_requestedStaticConstructorAndForbiddenOpcodes() public {
        vm.prank(bob); // Factory caller differs from the launch owner.
        PlantOrganism liveConfig = new PlantOrganism(
            0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127,
            0x1397434cd35e8a9C8aC312A61D3A285EB31dea56,
            ACTION,
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982,
            ORIGIN_CELL,
            alice
        );
        assertEq(liveConfig.deployer(), alice);
        assertEq(liveConfig.location(), ORIGIN_CELL);
        assertLe(type(PlantOrganism).creationCode.length + 6 * 32, 49152);
        MockHook futureHook = new MockHook(address(liveConfig), address(plant));
        vm.expectRevert(PlantOrganism.NotDeployer.selector);
        vm.prank(bob);
        liveConfig.bind(address(futureHook));
        vm.prank(alice);
        liveConfig.bind(address(futureHook));
        assertEq(liveConfig.ORIGIN_CELL(), ORIGIN_CELL);
        assertEq(liveConfig.lastSettledDay(), START);
        assertEq(liveConfig.action(), ACTION);
        bytes memory code = address(liveConfig).code;
        assertLe(code.length, 24576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function test_coldCallbackAndMaxHoursMoveSettleGas() public {
        vm.record();
        _withCommittedCandidate(201 ether);
        _park(carol, ORIGIN_CELL, 100 ether);
        _ask();
        OracleAttestation.Attestation memory a = _attestation(0xffffff, 0, true);
        bytes memory sig = _sign(a);
        _cool(address(organism));
        (bool ok,, uint256 callbackGas) = intake.deliver(intake.lastId(), a, sig);
        assertTrue(ok);
        _cool(address(organism));
        _cool(address(imd));
        _cool(address(plant));
        _settleWithinGasLimit();
        emit log_named_uint("cold callback gas", callbackGas);
        assertEq(organism.location(), OTHER);
    }

    function test_thirdIncompleteMoveAndAdvancePaymentGas() public {
        vm.record();
        _withCommittedCandidate(201 ether);
        intake.setPrice(1001 ether);
        imd.mint(keeper, 10000 ether);
        for (uint256 i; i < 3; ++i) {
            _ask();
            _deliver(0, 0, false);
            if (i != 2) {
                organism.settle();
                vm.warp(vm.getBlockTimestamp() + 6 hours);
            }
        }
        imd.mint(address(organism), 4000 ether);
        _cool(address(organism));
        _cool(address(imd));
        _cool(address(plant));
        _settleWithinGasLimit();
        assertEq(organism.location(), OTHER);
        assertEq(organism.feeAdvances(keeper), 0);
    }

    function test_coldMaxHoursWithRepairedCandidateSettleGas() public {
        vm.record();
        _park(alice, THIRD, 201 ether);
        _withCommittedCandidate(200 ether);
        organism.challenge(THIRD);
        _ask();
        _unpark(alice, THIRD, 201 ether);
        organism.challenge(OTHER);
        _deliver(0xffffff, 0, true);
        _cool(address(organism));
        _cool(address(imd));
        _cool(address(plant));
        _settleWithinGasLimit();
        assertEq(organism.location(), OTHER);
    }

    function test_thirdTimeoutMoveAndAdvancePaymentFitsColdStipend() public {
        vm.record();
        _withCommittedCandidate(201 ether);
        intake.setPrice(1001 ether);
        imd.mint(keeper, 10000 ether);
        for (uint256 i; i < 3; ++i) {
            _ask();
            vm.warp(vm.getBlockTimestamp() + 1 days);
            if (i < 2) {
                organism.clearPending();
                vm.warp(organism.retryAt());
            }
        }
        imd.mint(address(organism), 4000 ether);
        _cool(address(organism));
        _cool(address(imd));
        _cool(address(plant));
        (bool ok,) = address(organism).call{gas: 400000}(abi.encodeCall(organism.clearPending, ()));
        assertTrue(ok, "third timeout must settle within 400k");
        assertEq(organism.location(), OTHER);
        assertEq(organism.feeAdvances(keeper), 0);
    }
}
