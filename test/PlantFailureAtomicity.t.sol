// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantTestBase} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "src/PlantOrganism.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PlantFailureAtomicityTest is PlantTestBase {
    function _holderState(uint32 cell, address holder) private view returns (bytes32) {
        (uint256 active, uint256 queued, uint256 epoch, uint256 paid) = organism.positions(cell, holder);
        return keccak256(
            abi.encode(
                active,
                queued,
                epoch,
                paid,
                organism.parked(cell, holder),
                organism.parkedTotal(cell),
                organism.totalParked(),
                organism.votingStake(cell),
                organism.credits(holder),
                organism.creditTotal(),
                organism.gardenerPoints(),
                organism.backing(),
                organism.burned(),
                organism.floor(),
                organism.lastParkedCell(holder),
                plant.balanceOf(holder),
                plant.balanceOf(address(organism)),
                plant.allowance(holder, address(organism)),
                imd.balanceOf(holder),
                imd.balanceOf(address(organism))
            )
        );
    }

    function test_failedUnparkRestoresCheckpointAndVotingPowerThenCanRetry() public {
        _withGardeners();
        _weather(1, 0);
        assertGt(organism.gardenerPoints(), 0);
        assertEq(organism.credits(alice), 0);
        bytes32 beforeState = _holderState(ORIGIN_CELL, alice);
        plant.setBlocked(alice, true);
        vm.expectRevert(bytes("blocked"));
        vm.prank(alice);
        organism.unpark(ORIGIN_CELL, 100 ether);
        assertEq(_holderState(ORIGIN_CELL, alice), beforeState, "failed exit changed rewards or votes");
        plant.setBlocked(alice, false);
        _unpark(alice, ORIGIN_CELL, 100 ether);
        assertEq(plant.balanceOf(alice), 600 ether);
        assertEq(organism.votingStake(ORIGIN_CELL), 0);
        assertGt(organism.credits(alice), 0);
        _conservation();
    }

    function test_failedParkCannotCheckpointOrConsumeAllowance() public {
        _withGardeners();
        _weather(1, 0);
        bytes32 beforeState = _holderState(ORIGIN_CELL, alice);
        plant.setBlocked(address(organism), true);
        vm.expectRevert(bytes("blocked"));
        vm.prank(alice);
        organism.park(ORIGIN_CELL, 1 ether);
        assertEq(_holderState(ORIGIN_CELL, alice), beforeState, "failed deposit changed custody or checkpoint");
        plant.setBlocked(address(organism), false);
        _park(alice, ORIGIN_CELL, 1 ether);
        assertEq(organism.votingStake(ORIGIN_CELL), 100 ether, "retry must remain queued");
        assertEq(organism.parked(ORIGIN_CELL, alice), 101 ether);
        _conservation();
    }

    function test_failedRedemptionCannotSurrenderPlantOrReduceBacking() public {
        _withGardeners();
        _weather(1, 0);
        bytes32 beforeState = _holderState(ORIGIN_CELL, alice);
        imd.setBlocked(alice, true);
        vm.expectRevert(bytes("blocked"));
        vm.prank(alice);
        organism.redeem(1 ether);
        assertEq(_holderState(ORIGIN_CELL, alice), beforeState, "unpaid redemption burned stake");
        imd.setBlocked(alice, false);
        vm.prank(alice);
        uint256 payout = organism.redeem(1 ether);
        assertGt(payout, 0);
        assertEq(imd.balanceOf(alice), payout);
        assertEq(organism.burned(), 1 ether);
        _conservation();
    }

    function test_falseReturnOnClaimPreservesCreditWithoutBlockingOtherGardeners() public {
        _park(alice, ORIGIN_CELL, 100 ether);
        _park(bob, ORIGIN_CELL, 100 ether);
        _activationDay();
        _weather(1, 0);
        organism.checkpoint(ORIGIN_CELL, alice);
        organism.checkpoint(ORIGIN_CELL, bob);
        uint256 expected = organism.credits(alice);
        assertGt(expected, 0);
        assertEq(organism.credits(bob), expected);
        vm.mockCall(address(imd), abi.encodeCall(IERC20.transfer, (alice, expected)), abi.encode(false));
        vm.prank(alice);
        organism.claim();
        assertEq(organism.credits(alice), expected);
        assertEq(imd.balanceOf(alice), 0);
        vm.prank(bob);
        organism.claim();
        assertEq(imd.balanceOf(bob), expected);
        assertEq(organism.creditTotal(), expected);
        vm.clearMockedCalls();
        vm.prank(alice);
        organism.claim();
        vm.prank(alice);
        organism.claim();
        assertEq(imd.balanceOf(alice), expected, "retry paid twice");
        assertEq(organism.owed(), 0);
        _conservation();
    }

    function test_underchargingIntakeRollsBackCallerAdvanceAndAllNestedTransfers() public {
        _nextEnded();
        intake.setPrice(1002 ether);
        intake.setUndercharge(true);
        uint256 allowance = imd.allowance(keeper, address(organism));
        vm.expectRevert(PlantOrganism.NonExactTransfer.selector);
        vm.prank(keeper);
        organism.heartbeat(2 ether);
        assertEq(imd.balanceOf(keeper), 100 ether);
        assertEq(imd.balanceOf(address(organism)), 1000 ether);
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(imd.allowance(keeper, address(organism)), allowance);
        assertEq(imd.allowance(address(organism), address(intake)), 0);
        assertEq(organism.feeAdvances(keeper), 0);
        assertEq(organism.feeAdvanceTotal(), 0);
        assertEq(organism.feeUnlockEpoch(keeper), 0);
        assertEq(intake.sequence(), 0);
        (,,,,,, bool exists,,) = organism.pending();
        assertFalse(exists);
        intake.setUndercharge(false);
        vm.prank(keeper);
        organism.heartbeat(2 ether);
        assertEq(imd.balanceOf(keeper), 98 ether);
        assertEq(organism.feeAdvances(keeper), 2 ether);
        assertEq(intake.sequence(), 1);
        _conservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_advanceCapUsesOnlySpendablePotAndFailedCapIsAtomic(uint96 seed) public {
        _withGardeners();
        _weather(1, 0);
        _nextEnded();
        uint256 advance = bound(seed, 1, 100 ether);
        uint256 price = organism.spendablePot() + advance;
        uint256 senior = organism.backing() + organism.gardenerReserve() + organism.creditTotal();
        assertGt(senior, 0);
        intake.setPrice(price);
        uint256 keeperBalance = imd.balanceOf(keeper);
        uint256 held = imd.balanceOf(address(organism));
        uint256 sequence = intake.sequence();
        vm.expectRevert(PlantOrganism.AdvanceTooLarge.selector);
        vm.prank(keeper);
        organism.heartbeat(advance - 1);
        assertEq(imd.balanceOf(keeper), keeperBalance);
        assertEq(imd.balanceOf(address(organism)), held);
        assertEq(intake.sequence(), sequence);
        assertEq(organism.feeAdvanceTotal(), 0);
        vm.prank(keeper);
        organism.heartbeat(advance);
        assertEq(imd.balanceOf(keeper), keeperBalance - advance);
        assertEq(imd.balanceOf(address(organism)), senior, "fee spent senior reserves");
        assertEq(organism.feeAdvances(keeper), advance);
        assertEq(organism.pot(), -int256(advance));
        _conservation();
    }
}
