// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {MockToken} from "./mocks/Mocks.sol";

/// @dev Each method borrows, acts and repays in one external call.
contract VotingBorrower {
    PlantOrganism internal immutable organism;
    MockToken internal immutable plant;
    address internal immutable lender;

    constructor(PlantOrganism organism_, MockToken plant_, address lender_) {
        organism = organism_;
        plant = plant_;
        lender = lender_;
        plant.approve(address(organism), type(uint256).max);
    }

    function seed(uint32 cell) external {
        organism.park(cell, plant.balanceOf(address(this)));
    }

    function askWithLoan(uint32 cell, uint256 amount) external {
        plant.transferFrom(lender, address(this), amount);
        organism.park(cell, amount);
        organism.heartbeat(type(uint256).max);
        organism.unpark(cell, amount);
        plant.transfer(lender, amount);
    }

    function settleWithLoan(uint32 cell, uint256 amount) external returns (uint32 candidate) {
        plant.transferFrom(lender, address(this), amount);
        organism.park(cell, amount);
        candidate = organism.challenger();
        organism.settle();
        organism.unpark(cell, amount);
        plant.transfer(lender, amount);
    }

    function claim() external {
        organism.claim();
    }
}

contract PlantVotingCommitmentTest is PlantTestBase {
    VotingBorrower internal borrower;

    function setUp() public override {
        super.setUp();
        borrower = new VotingBorrower(organism, plant, alice);
        vm.prank(alice);
        plant.approve(address(borrower), type(uint256).max);
    }

    function _seedBorrower() internal {
        vm.prank(alice);
        plant.transfer(address(borrower), 1);
        borrower.seed(OTHER);
    }

    function _doubleFlashMove() internal {
        _withGardeners();
        _seedBorrower();
        _weather(0, 0);
        _weather(0, 0);
        _nextEnded();
        uint256 lenderBefore = plant.balanceOf(alice);
        borrower.askWithLoan(OTHER, 100 ether);
        assertEq(plant.balanceOf(alice), lenderBefore);
        assertEq(organism.parkedTotal(OTHER), 1);
        _deliver(0, 0, true);
        borrower.settleWithLoan(OTHER, 100 ether);
        assertEq(plant.balanceOf(alice), lenderBefore);
        assertEq(plant.balanceOf(address(borrower)), 0);
        assertEq(organism.parkedTotal(OTHER), 1);
    }

    function test_borrowingAtBothHeartbeatAndSettleCannotMove() public {
        _doubleFlashMove();
        assertEq(organism.location(), ORIGIN_CELL, "two atomic loans moved the plant");
        _conservation();
    }

    function test_borrowingAtBothHeartbeatAndSettleCannotCaptureGardenersPool() public {
        _doubleFlashMove();
        uint256 beforeReward = imd.balanceOf(address(borrower));
        _weather(0xffffff, 0);
        borrower.claim();
        vm.prank(alice);
        organism.claim();
        assertEq(imd.balanceOf(address(borrower)), beforeReward, "one wei captured the gardener pool");
        assertGt(imd.balanceOf(alice), 0);
        _conservation();
    }

    function test_rearmedDecoyCannotHideHoldersCandidate() public {
        _withCommittedCandidate(200 ether);
        _nextEnded();
        borrower.askWithLoan(THIRD, 201 ether);
        (,, uint32 captured,,,,,,) = organism.pending();
        assertEq(captured, OTHER, "heartbeat decoy replaced committed challenger");
        assertEq(organism.votingStake(THIRD), 0);
        organism.challenge(OTHER);
        _deliver(1, 0, true);
        uint32 decoy2 = (101 << 16) | uint32(uint16(int16(-21)));
        assertEq(borrower.settleWithLoan(decoy2, 201 ether), OTHER, "settle decoy replaced challenger");
        assertEq(organism.location(), OTHER, "holders' candidate was never read");
        assertEq(plant.balanceOf(address(borrower)), 0);
        assertEq(organism.parkedTotal(decoy2), 0);
        _conservation();
    }

    function test_borrowingAtBothHeartbeatAndSettleCannotVeto() public {
        _withCommittedCandidate(200 ether);
        _nextEnded();
        uint256 lenderBefore = plant.balanceOf(alice);
        borrower.askWithLoan(ORIGIN_CELL, 201 ether);
        assertEq(organism.votingStake(ORIGIN_CELL), 100 ether);
        _deliver(0, 0, true);
        borrower.settleWithLoan(ORIGIN_CELL, 201 ether);
        assertEq(organism.location(), OTHER);
        assertEq(plant.balanceOf(alice), lenderBefore);
        assertEq(organism.parkedTotal(ORIGIN_CELL), 100 ether);
        _conservation();
    }

    function test_loanAcrossPreviousSettleLosesPowerOnWithdrawal() public {
        _withGardeners();
        _seedBorrower();
        _ask();
        _deliver(0, 0, true);
        borrower.settleWithLoan(OTHER, 100 ether);
        assertEq(organism.votingStake(OTHER), 1);
        _nextEnded();
        borrower.askWithLoan(OTHER, 100 ether);
        _deliver(0, 0, true);
        borrower.settleWithLoan(OTHER, 100 ether);
        assertEq(organism.location(), ORIGIN_CELL);
        assertEq(organism.votingStake(OTHER), 1);
        _conservation();
    }

    function test_thresholdUsesCommittedStakeAndNewDepositsMatureAtSettle() public {
        _withGardeners();
        _unpark(alice, ORIGIN_CELL, 100 ether);
        _park(bob, OTHER, 40 ether);
        assertEq(organism.votingStake(OTHER), 0);
        assertEq(organism.challenger(), 0);
        _weather(0, 0);
        assertEq(organism.votingStake(OTHER), 40 ether);
        organism.challenge(OTHER);
        _park(bob, OTHER, 10 ether);
        assertEq(organism.votingStake(OTHER), 40 ether);
        _weather(0, 0);
        assertEq(organism.location(), ORIGIN_CELL, "fresh stake counted toward 5% threshold");
        assertEq(organism.votingStake(OTHER), 50 ether);
        _weather(0, 0);
        assertEq(organism.location(), OTHER);
    }

    function test_timeoutAndReaskCannotRestoreWithdrawnPower() public {
        _withCommittedCandidate(200 ether);
        _ask();
        _unpark(bob, OTHER, 200 ether);
        _park(carol, OTHER, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        organism.clearPending();
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _ask();
        assertEq(organism.votingStake(OTHER), 0);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), ORIGIN_CELL);
        // Carol parked on day START+3, after day START+2 had ended: eligible from day START+4.
        assertEq(organism.votingStake(OTHER), 0);
        _weather(0, 0);
        assertEq(organism.votingStake(OTHER), 100 ether);
    }

    function testFuzz_withdrawalAndRedepositCannotIncreasePower(uint96 withdrawalSeed, uint96 additionSeed) public {
        _withCommittedCandidate(200 ether);
        uint256 amount = bound(uint256(withdrawalSeed), 1, 200 ether);
        uint256 addition = bound(uint256(additionSeed), 0, 100 ether);
        _unpark(bob, OTHER, amount);
        _park(bob, OTHER, amount + addition);
        assertEq(organism.votingStake(OTHER), 200 ether - amount);
        organism.checkpoint(OTHER, bob);
        assertEq(organism.votingStake(OTHER), 200 ether - amount);
        _ask();
        assertEq(organism.votingStake(OTHER), 200 ether - amount);
        _deliver(0, 0, true);
        organism.settle();
        assertEq(organism.location(), amount < 100 ether ? OTHER : ORIGIN_CELL);
        assertEq(organism.votingStake(OTHER), 200 ether + addition);
        _conservation();
    }
}
