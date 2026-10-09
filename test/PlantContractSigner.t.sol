// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockHook} from "./mocks/Mocks.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// Uses a contract-specific signature format, so recovering an EOA alone cannot validate it.
contract PlantSignerMock is IERC1271 {
    address public immutable key;
    bool public enabled = true;
    bool public rejectsByRevert;

    constructor(address key_) {
        key = key_;
    }

    function configure(bool enabled_, bool reverts_) external {
        enabled = enabled_;
        rejectsByRevert = reverts_;
    }

    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        require(!rejectsByRevert, "signer unavailable");
        if (!enabled || sig.length != 66 || sig[0] != 0x42) return bytes4(0);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, sig[1:]);
        return err == ECDSA.RecoverError.NoError && recovered == key ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

contract PlantContractSignerTest is PlantTestBase {
    uint256 private constant NEW_KEY = 76543;

    function _contractSig(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        return bytes.concat(hex"42", _signDigest(key, digest));
    }

    function _withRegistry() private returns (PlantSignerMock registry) {
        registry = new PlantSignerMock(vm.addr(KEY));
        organism =
            new PlantOrganism(address(imd), address(intake), ACTION, address(registry), ORIGIN_CELL, address(this));
        organism.bind(address(new MockHook(address(organism), address(plant))));
        imd.mint(address(organism), 1000 ether);
        _approve(alice);
        _approve(bob);
        vm.prank(keeper);
        imd.approve(address(organism), type(uint256).max);
    }

    function _cold(address target) private {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        for (uint256 i; i < reads.length; ++i) {
            vm.coolSlot(target, reads[i]);
        }
        for (uint256 i; i < writes.length; ++i) {
            vm.coolSlot(target, writes[i]);
        }
        vm.cool(target);
    }

    function test_constructorContractAttestationAndRotationFitCallbackStipend() public {
        vm.record();
        PlantSignerMock registry = _withRegistry();
        assertEq(organism.oracleSigner(), address(registry));
        _park(alice, ORIGIN_CELL, 100 ether);
        _ask();
        OracleAttestation.Attestation memory a = _attestation(0xffffff, 0, true);
        bytes memory sig = _contractSig(KEY, organism.attestationDigest(a));
        _cold(address(organism));
        _cold(address(registry));
        (bool ok,, uint256 used) = intake.deliver(intake.lastId(), a, sig);
        assertTrue(ok, "cold ERC-1271 callback exceeded stipend");
        emit log_named_uint("cold ERC-1271 callback gas", used);
        assertEq(organism.oracleSigner(), address(registry));
        assertTrue(organism.consumed(a.requestId));
        _settleWithinGasLimit();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = organism.rotationDigest(vm.addr(NEW_KEY), address(intake), ACTION, 0, deadline);
        organism.rotate(vm.addr(NEW_KEY), address(intake), ACTION, 0, deadline, _contractSig(KEY, digest));
        assertEq(organism.oracleSigner(), vm.addr(NEW_KEY));
        assertEq(organism.rotationNonce(), 1);
    }

    function test_canRotateToContractAndRejectInvalidOrRevokedSignatures() public {
        PlantSignerMock registry = new PlantSignerMock(vm.addr(NEW_KEY));
        uint256 deadline = vm.getBlockTimestamp() + 3 days;
        bytes32 digest = organism.rotationDigest(address(registry), address(intake), ACTION, 0, deadline);
        organism.rotate(address(registry), address(intake), ACTION, 0, deadline, _signDigest(KEY, digest));
        _ask();
        OracleAttestation.Attestation memory a = _attestation(0, 0, true);
        bytes memory valid = _contractSig(NEW_KEY, organism.attestationDigest(a));
        _rejected(a, _contractSig(123, organism.attestationDigest(a)));
        registry.configure(false, false);
        _rejected(a, valid);
        bytes32 rotation = organism.rotationDigest(vm.addr(KEY), address(intake), ACTION, 1, deadline);
        bytes memory authorization = _contractSig(NEW_KEY, rotation);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(KEY), address(intake), ACTION, 1, deadline, authorization);
        registry.configure(true, true);
        _rejected(a, valid);
        registry.configure(true, false);
        (bool ok,,) = intake.deliver(intake.lastId(), a, valid);
        assertTrue(ok);
        organism.rotate(vm.addr(KEY), address(intake), ACTION, 1, deadline, authorization);
        vm.expectRevert(PlantOrganism.InvalidNonce.selector);
        organism.rotate(vm.addr(KEY), address(intake), ACTION, 1, deadline, authorization);
    }

    function test_multiplePriorContractSignersKeepGraceWithoutRotationAuthority() public {
        vm.record();
        PlantSignerMock first = _withRegistry();
        PlantSignerMock second = new PlantSignerMock(vm.addr(NEW_KEY));
        _ask();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = organism.rotationDigest(address(second), address(intake), ACTION, 0, deadline);
        organism.rotate(address(second), address(intake), ACTION, 0, deadline, _contractSig(KEY, digest));
        digest = organism.rotationDigest(vm.addr(777), address(intake), ACTION, 1, deadline);
        organism.rotate(vm.addr(777), address(intake), ACTION, 1, deadline, _contractSig(NEW_KEY, digest));
        digest = organism.rotationDigest(vm.addr(888), address(intake), ACTION, 2, deadline);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        organism.rotate(vm.addr(888), address(intake), ACTION, 2, deadline, _contractSig(KEY, digest));
        OracleAttestation.Attestation memory a = _attestation(1, 0, true);
        bytes memory raw = _contractSig(KEY, organism.attestationDigest(a));
        _rejected(a, raw); // Previous contracts must be explicitly identified.
        _rejected(a, abi.encodePacked(address(second), raw));
        _rejected(a, hex"42");
        bytes memory sig = abi.encodePacked(address(first), raw);
        _cold(address(organism));
        _cold(address(first));
        (bool ok,,) = intake.deliver(intake.lastId(), a, sig);
        assertTrue(ok, "prior contract callback exceeded stipend");
        assertEq(organism.oracleSigner(), vm.addr(777));
        organism.settle();
        _ask();
        a = _attestation(0, 0, true);
        (ok,,) = intake.deliver(
            intake.lastId(), a, abi.encodePacked(address(second), _contractSig(NEW_KEY, organism.attestationDigest(a)))
        );
        assertTrue(ok);
    }

    function test_previousContractGraceExpiresAtThirtyDays() public {
        PlantSignerMock registry = _withRegistry();
        vm.warp(uint256(START) * 1 days);
        uint256 expiry = vm.getBlockTimestamp() + 30 days;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = organism.rotationDigest(vm.addr(NEW_KEY), address(intake), ACTION, 0, deadline);
        organism.rotate(vm.addr(NEW_KEY), address(intake), ACTION, 0, deadline, _contractSig(KEY, digest));
        while (vm.getBlockTimestamp() < expiry) {
            _ask();
            OracleAttestation.Attestation memory a = _attestation(0, 0, true);
            bytes memory sig = abi.encodePacked(address(registry), _contractSig(KEY, organism.attestationDigest(a)));
            if (vm.getBlockTimestamp() < expiry) {
                (bool ok,,) = intake.deliver(intake.lastId(), a, sig);
                assertTrue(ok);
            } else {
                assertEq(vm.getBlockTimestamp(), expiry);
                _rejected(a, sig);
                (bool ok,,) = intake.deliver(intake.lastId(), a, _signDigest(NEW_KEY, organism.attestationDigest(a)));
                assertTrue(ok);
            }
            organism.settle();
        }
        assertFalse(organism.isDead());
    }
}
