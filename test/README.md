# PLANT ORGANISM tests

The existing launch origin is Sintra: Its gardens bring native and exotic trees together on
forested hills. Its cell is `10223578`, with centre `38.875, -9.375`; the origin regression
derives that cell from the documented coordinates and round-trips through the centre.

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
checkpoints. The state-machine invariant runs 256 sequences of 96 calls; arithmetic fuzz tests run 1,000
cases via inline configuration.

`PlantRewardOwnershipInvariant.t.sol` independently assigns each day's gardening pool to each
eligible holder in an eager ledger, without reading the implementation's positions, reward index,
or activation checkpoints. Across 256 sequences of 96 calls it compares exact fractional liabilities,
individual credits and actual payouts through lazy activation, withdrawals, moves, third-party
checkpoints, duplicate historical claim cells, default claims and rejected payments. Every sequence
starts with rewards in three cells and two moves, and ends by withdrawing all stake and rewards
after death. The model applies the documented checkpoint dust rounding; it does not assume that
checkpointing preserves fractions below one IMD base unit.

`PlantFailureAtomicity.t.sol` verifies that failed deposits, withdrawals and redemptions roll back
checkpoints, voting power, allowances and custody; a token returning false defers only the affected
holder's claim; and an undercharging Intake rolls back the caller's advance and nested transfers.
A 1,000-case property rejects a fee cap one unit below the required advance, then accepts the exact
cap while preserving backing and gardener reserves.

`GasAndDeployment.t.sol` tests deployment constraints and cold settlement with 24 sips, a move,
fee repayment, or 129 eligible holders. Callback mocks forward an actual 200,000 gas stipend;
settlement checks forward 400,000 gas and require success. Gas-left measurements are diagnostic
only, avoiding dependence on Foundry's isolation accounting.

No fork, FFI, RPC, environment mutation, production keys, or new dependency is required.
Mock token supply is fixed after each invariant's setup; the mocks model exact-transfer ERC-20s,
rejected transfers, transfer fees, and reentrancy. Live Robinhood IMD/Intake behavior and the future
PLANT/hook deployment remain integration checks outside this offline suite. All signer secrets
used here are synthetic test fixtures. Production build configuration and dependencies are unchanged.

`PlantOriginRegression.t.sol` pins the structure of the no-birth revision: the birth selectors
(`FALLBACK_CELL`, `birthSettles`) and every admin, upgrade, pause, ownership and role selector are
absent and plain value is refused; `ORIGIN` is one sentence of the form `<place>: <why>` matching
launch.json and README.md; a 1,000-case fuzz packs every valid quarter-degree cell, prints its
centre through the question's own coordinate text, parses it back and floors it to the same cell,
including both edges; the constructor accepts every valid cell as the deployment location with an
unspecialised `question()` and rejects every invalid cell and zero dependency; PLANT sent straight
to the body or merely held in a wallet never votes, nominates, defends or earns; a single
transaction that parks, nominates, asks, delivers, settles and withdraws can neither move the plant
nor earn gardening credit, at the destination or at the location; a rotation deadline is part of
the signed struct and expires one second late; and the heartbeat cap is exact with no pending
request left behind by a refusal.

`PlantStakeRuleInvariant.t.sol` keeps an independent ledger of dated deposits per holder and cell,
written from the launch's one stake rule (parked by a day that has settled, withdrawn drops out at
once, never a live balance), without reading the body's positions, batches or activation
checkpoints. Across 200 sequences of 64 calls mixing parks, withdrawals, nominations, complete
days, three-strike silent days and same-call flashes by a holder richer than all gardeners, it
asserts after every call that `votingStake` equals the ledger for every cell, that nomination and
READ (including the silent-day READ and the live-challenger fallback, with the 5% threshold over
remaining supply) follow the ledger, that a gardener pool with no settled stake reserves nothing,
that the flasher never holds stake or credit, and that PLANT custody equals parked plus burned.

`PlantLaunchRevision.t.sol`, `PlantAssumptions.t.sol` and `PlantContractSigner.t.sol` cover the launch corrections: real origin and centre round-trip, first full post-bind day, first-epoch flash deposits, unanswered/mixed strikes, remaining-supply threshold, fee caps, signed rotation expiry, ERC-1271 validity/revocation, and overlapping signer grace. The state machine models settlement from both delivered results and the third timeout.
