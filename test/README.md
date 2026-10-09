# PLANT ORGANISM tests

Run entirely offline with the repository's pinned compiler and vendored libraries:

```sh
forge build --offline
forge test --offline
forge test --offline --fuzz-seed 0x20261008 --fuzz-runs 2000
forge fmt --check
```

`PlantOrganism.t.sol` covers binding, deployment origin, bounded catch-up, challenger selection,
hour ordering, water limits, reward activation, redemptions, oracle fees, failure paths,
reentrancy, final death, and signer rotation. `WeatherQuestion.t.sol` compares literal JSON
bodies, signed cell coordinates, leap days, and boundary dates. The canonical protocol
digest/signature and independent bytes32 weather fixture remain in
`OracleConsumerConformance.t.sol` and `fixtures/weather.json`.

`PlantAdversarial.t.sol` adds precise rejection errors and unchanged pending state, all reserved
weather bits, malformed panels and answer lengths, signature time boundaries, oracle UUID replay
across re-asks, exact timeout boundaries, multiple keepers' fee debts, deferred payouts, latest
incomplete-request candidate selection, reward ownership across moves, withdrawals after callbacks,
fractional five-percent thresholds, death with pending debt, intake rotation, invalid binding,
zero/overdraw inputs, lifecycle events, and repeated park/unpark round trips.

`PlantVotingRevision.t.sol` covers committed voting ties, repeated deposits during a request,
withdrawals, repaired challengers, and retries that cannot mature fresh stake. The accepted voting
rule activates deposits only after a successful settle, including the first epoch after bind.
`PlantVotingCommitment.t.sol` covers loans at both heartbeat and settlement, decoy candidates,
veto attempts, withdrawal/redeposit, and the five-percent threshold using retained commitments.
`PlantSettleLag.t.sol` covers settlement that lags the calendar: stake parked after a day ended
never earns or votes for that day, lag deposits mature one day at a time with exact shares,
withdrawals leave newest first, bind-day deposits wait for the first full day, cold settles stay
within 400k after a 28-day lag with daily deposits, an unlocked fee advance is not re-locked by
the next heartbeat, zero-payout redemptions are refused, and `settle(day)` never overshoots.

`PlantStateMachine.t.sol` drives twelve operations among three holders and three cells in random
order, including separately requested, delivered, cleared, and settled oracle results. Every run
starts with actual growth and an outstanding fee advance. Its independent ghost ledgers track IMD
donations, caller contributions, oracle fees, payouts, each holder's stake, and permanently
surrendered PLANT. Assertions compare these with actual custody, sum per-holder credits/debts,
check funded senior reserves, enforce floor/day monotonicity and final death, and verify repeated
claims cannot pay twice. Per-holder ghost commitments also check voting power and the exact expected
destination through deposits, withdrawals, callbacks, retries, and settlement. After every sequence it forces
death, exits every position, funds any remaining oracle deficit, claims all debts, and redeems all
remaining supply. The existing
`PlantInvariant.t.sol` additionally exercises repeated complete weather days and lazy reward
checkpoints. The new invariant runs 256 sequences of 96 calls; arithmetic fuzz tests run 1,000
cases via inline configuration.

`GasAndDeployment.t.sol` tests deployment constraints and cold settlement with 24 sips, a move,
fee repayment, or 129 eligible holders. Callback mocks forward an actual 200,000 gas stipend;
settlement checks forward 400,000 gas and require success. Gas-left measurements are diagnostic
only, avoiding dependence on Foundry's isolation accounting.

No fork, FFI, RPC, environment mutation, production keys, or new dependency is required.
Mock token supply is fixed after each invariant's setup; the mocks model exact-transfer ERC-20s,
rejected transfers, transfer fees, and reentrancy. Live Robinhood IMD/Intake behavior and the future
PLANT/hook deployment remain integration checks outside this offline suite. All signer secrets
used here are synthetic test fixtures. Production build configuration and dependencies are unchanged.

`PlantLaunchRevision.t.sol`, `PlantAssumptions.t.sol` and `PlantContractSigner.t.sol` cover the launch corrections: real origin and centre round-trip, first full post-bind day, first-epoch flash deposits, unanswered/mixed strikes, remaining-supply threshold, fee caps, signed rotation expiry, ERC-1271 validity/revocation, and overlapping signer grace. The state machine models settlement from both delivered results and the third timeout.
