// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockHook} from "./mocks/Mocks.sol";

// Exposes only the canonical verifier to accept the original bytes32[] protocol vector.
// The application rejects that type and separately tests a bytes32 weather fixture below.
contract VerificationHarness is OracleAttestationConsumer {
    constructor(address signer) OracleAttestationConsumer(signer) {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata sig) external {
        _verifyAttestation(a, sig);
        _consume(a.requestId);
    }
}

contract OracleConsumerConformanceTest is PlantTestBase {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    /// @dev The callback's canonical signature. Its selector is what the intake calls: a struct that
    /// differs from the protocol's by one field has another selector and is never reached.
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    address constant WRITER = address(0x717E);
    address constant SOURCE_INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;

    function setUp() public override {
        super.setUp();
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        deployCodeTo(
            "PlantOrganism.sol:PlantOrganism",
            abi.encode(address(imd), address(intake), ACTION, SIGNER, ORIGIN_CELL, address(this)),
            VECTOR_CONSUMER
        );
        organism = PlantOrganism(VECTOR_CONSUMER);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(organism.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function test_callbackSelectorIsCanonical() public view {
        assertEq(organism.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    function test_acceptsOriginalProtocolSignatureInCanonicalVerifier() public {
        // Exact constants copied from the supplied cross-implementation vector.
        vm.etch(VECTOR_CONSUMER, bytes(""));
        deployCodeTo("OracleConsumerConformance.t.sol:VerificationHarness", abi.encode(SIGNER), VECTOR_CONSUMER);
        VerificationHarness consumer = VerificationHarness(VECTOR_CONSUMER);
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
        consumer.verify(vector(), VECTOR_SIGNATURE);
        assertTrue(consumer.consumed(vector().requestId));
    }

    function test_bytes32WeatherFixtureAcceptedUnderStipend() public {
        vm.chainId(4663);
        organism.bind(address(new MockHook(address(organism), address(plant))));
        _approve(alice);
        imd.mint(address(organism), 100 ether);
        _withGardeners();
        _ask();
        OracleAttestation.Attestation memory a = vector();
        a.chainId = 4663;
        a.answerType = 2;
        a.answer = abi.encode(
            bytes32(
                uint256(0x123456) | uint256(0x654321 & ~0x123456) << 24 | uint256(1) << 48
                    | uint256(organism.lastSettledDay() + 1) << 96
            )
        );
        a.panelSize = 15;
        a.quorum = 10;
        a.agreed = 15;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 3600);
        // Independent fixture in test/fixtures/weather.json; no runtime filesystem access.
        assertEq(
            organism.attestationDigest(a), bytes32(0x38fef366c1779aa5bf51a626d0c44ecaf07b029559021f914b8ac5b0351a817a)
        );
        assertEq(a.answer, abi.encode(bytes32(0x0000000000000000000000000000000000005163000000000001654321123456)));
        bytes memory fixtureSignature =
            hex"e08814b42c067269013ccfe011ee104cd8638a8188ba37bf2c38255bb5d9dc3873337c7a72d439e67f52cf5a3a70a587fec46eb223d86061ac877e436573ed4a1b";
        (bool ok,,) = intake.deliver(intake.lastId(), a, fixtureSignature);
        assertTrue(ok);
        assertTrue(organism.consumed(a.requestId));
    }
}
