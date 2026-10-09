// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {WeatherQuestion} from "./WeatherQuestion.sol";

interface IPlantHook {
    function organism() external view returns (address);
    function plant() external view returns (address);
}

/// @notice An immutable plant body. The deployer can bind its future token hook exactly once.
contract PlantOrganism is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant ORIGIN = "Sintra: Its gardens bring native and exotic trees together on forested hills.";
    uint256 public constant CHAIN_ID = 4663;
    uint256 public constant SCALE = 1e18;
    uint256 public constant ORACLE_TIMEOUT = 1 days;
    uint256 public constant RETRY_DELAY = 6 hours;
    uint256 public constant DEATH_DAYS = 30;
    uint256 public constant SIGNER_GRACE = 30 days;
    bytes32 public constant ROTATE_TYPEHASH = keccak256(
        "Rotate(address organism,uint256 chainId,address newSigner,address newIntake,bytes32 newAction,uint256 nonce,uint256 deadline)"
    );

    IERC20 public immutable IMD;
    address public immutable deployer;
    uint32 public immutable ORIGIN_CELL;
    IIntake public intake;
    bytes32 public action;
    address public hook;
    IERC20 public PLANT;
    uint32 public bindDay;
    uint32 public lastSettledDay;
    uint32 public location;
    uint32 public challenger;
    uint32 public lastRewardCell;
    uint8 public water = 50;
    bool public dead;
    uint256 public backing;
    uint256 public burned;
    uint256 public terminalFloor;
    uint256 public totalParked;
    uint256 public epoch;
    uint256 public rotationNonce;
    uint256 public retryAt;
    mapping(address => uint256) public signerAcceptedUntil;
    mapping(uint32 => uint8) public incompletes;
    mapping(uint32 => mapping(address => uint256)) public parked;
    mapping(uint32 => uint256) public parkedTotal;

    struct Pending {
        bytes32 requestId;
        uint32 day;
        uint32 challenger;
        address caller;
        uint64 askedAt;
        address intake;
        bool exists;
        bool received;
        bytes32 word;
    }
    Pending public pending;

    struct CellRewards {
        uint256 active;
        uint256 queued;
        uint256 epoch;
        uint256 rewardPerToken;
    }

    struct Position {
        uint256 active;
        uint256 queued;
        uint256 epoch;
        uint256 paid;
    }
    mapping(uint32 => CellRewards) public cellRewards;
    mapping(uint32 => mapping(address => Position)) public positions;
    mapping(uint32 => mapping(uint256 => uint256)) public activationCheckpoint;
    mapping(address => uint32) public lastParkedCell;
    // Exact fractional reward liabilities, before each account rounds down on checkpoint.
    uint256 public gardenerPoints;
    mapping(address => uint256) public credits;
    uint256 public creditTotal;
    mapping(address => uint256) public feeAdvances;
    mapping(address => uint256) public feeUnlockEpoch;
    uint256 public feeAdvanceTotal;

    error InvalidConfiguration();
    error NotDeployer();
    error AlreadyBound();
    error Unbound();
    error DeadPlant();
    error NotDead();
    error WrongHook();
    error InvalidAmount();
    error NonExactTransfer();
    error DayNotEnded();
    error WrongDay();
    error RequestPending();
    error NoRequest();
    error NoResult();
    error RetryLater();
    error NotTimedOut();
    error NotTheIntake();
    error UnknownRequest();
    error InvalidAttestation();
    error InvalidWord();
    error InvalidNonce();
    error RotationExpired();
    error AdvanceTooLarge();

    event Bound(address indexed hook, address indexed plant, uint32 day);
    event Parked(address indexed holder, uint32 indexed cell, uint256 amount);
    event Unparked(address indexed holder, uint32 indexed cell, uint256 amount);
    event Challenged(uint32 indexed cell);
    event Asked(
        bytes32 indexed requestId, uint32 indexed day, uint32 cell, uint32 challenger, address caller, uint256 price
    );
    event Advanced(address indexed caller, uint256 amount);
    event Received(bytes32 indexed requestId, bytes32 indexed oracleRequestId, bytes32 word);
    event Cleared(bytes32 indexed requestId, uint32 indexed day, uint256 retryAt);
    event Incomplete(uint32 indexed day, uint8 count);
    event Moved(uint32 indexed from, uint32 indexed to);
    event Settled(uint32 indexed day, bytes32 word, uint256 sips, uint256 backing, uint8 water, uint32 location);
    event EmptyCatchUp(uint32 firstDay, uint32 lastDay);
    event Rewarded(uint32 indexed cell, uint256 pool, uint256 reserved);
    event Checkpointed(address indexed holder, uint32 indexed cell, uint256 credit);
    event Bounty(address indexed caller, uint256 amount);
    event Paid(address indexed holder, uint256 credit, uint256 advance);
    event PaymentDeferred(address indexed holder, uint256 amount);
    event Redeemed(address indexed holder, uint256 amount, uint256 imd, bool dead);
    event Died(uint32 day, uint256 merged);
    event PotMerged(uint256 amount);
    event Rotated(
        address indexed oldSigner, address indexed newSigner, address indexed intake, bytes32 action, uint256 nonce
    );

    constructor(address imd_, address intake_, bytes32 action_, address signer_, uint32 originCell_, address deployer_)
        OracleAttestationConsumer(signer_)
    {
        if (imd_ == address(0) || intake_ == address(0) || action_ == bytes32(0) || deployer_ == address(0)) {
            revert InvalidConfiguration();
        }
        WeatherQuestion.validate(originCell_);
        IMD = IERC20(imd_);
        intake = IIntake(intake_);
        action = action_;
        ORIGIN_CELL = originCell_;
        location = originCell_;
        deployer = deployer_;
        lastSettledDay = today();
    }

    function today() public view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    function bind(address hook_) external nonReentrant {
        if (hook != address(0)) revert AlreadyBound();
        if (msg.sender != deployer) revert NotDeployer();
        if (hook_.code.length == 0 || IPlantHook(hook_).organism() != address(this)) revert WrongHook();
        address plant = IPlantHook(hook_).plant();
        if (
            plant == address(IMD) || plant == address(this) || plant.code.length == 0
                || IERC20(plant).totalSupply() == 0
        ) revert InvalidConfiguration();
        hook = hook_;
        PLANT = IERC20(plant);
        bindDay = today();
        emit Bound(hook_, plant, bindDay);
    }

    function isDead() public view returns (bool) {
        return dead || (hook != address(0) && uint256(today()) >= Math.max(bindDay, lastSettledDay) + DEATH_DAYS);
    }

    function _aliveBound() private view {
        if (hook == address(0)) revert Unbound();
        if (isDead()) revert DeadPlant();
    }

    function gardenerReserve() public view returns (uint256) {
        return Math.ceilDiv(gardenerPoints, SCALE);
    }

    function owed() public view returns (uint256) {
        return gardenerReserve() + creditTotal + feeAdvanceTotal;
    }

    /// @notice Signed because a caller's spent oracle fee is a real, potentially unfunded debt.
    function pot() public view returns (int256) {
        uint256 held = IMD.balanceOf(address(this));
        uint256 reserved = backing + owed();
        require(held <= uint256(type(int256).max) && reserved <= uint256(type(int256).max));
        return int256(held) - int256(reserved);
    }

    function spendablePot() public view returns (uint256) {
        int256 p = pot();
        return p > 0 ? uint256(p) : 0;
    }

    /// @notice IMD base units per PLANT base unit, scaled by 1e18; zero supply retains its last floor.
    function floor() public view returns (uint256) {
        if (hook == address(0)) return 0;
        uint256 supply = PLANT.totalSupply() - burned;
        if (supply == 0) return terminalFloor;
        uint256 assets = backing + (isDead() ? spendablePot() : 0);
        return Math.mulDiv(assets, SCALE, supply);
    }

    function question(uint32 cell, uint32 day) public pure returns (string memory) {
        return WeatherQuestion.question(cell, day);
    }

    function question() external view returns (string memory) {
        return question(location, lastSettledDay + 1);
    }

    function requestBody(uint32 cell, uint32 day) public pure returns (bytes memory) {
        return WeatherQuestion.body(cell, day);
    }

    function park(uint32 cell, uint256 amount) external nonReentrant {
        _aliveBound();
        WeatherQuestion.validate(cell);
        if (amount == 0) revert InvalidAmount();
        _checkpoint(cell, msg.sender);
        _pullExact(PLANT, msg.sender, amount);
        positions[cell][msg.sender].queued += amount;
        cellRewards[cell].queued += amount;
        parked[cell][msg.sender] += amount;
        parkedTotal[cell] += amount;
        totalParked += amount;
        lastParkedCell[msg.sender] = cell;
        _challenge(cell);
        emit Parked(msg.sender, cell, amount);
    }

    function unpark(uint32 cell, uint256 amount) external nonReentrant {
        if (amount == 0 || amount > parked[cell][msg.sender]) revert InvalidAmount();
        _syncDeath();
        _checkpoint(cell, msg.sender);
        Position storage p = positions[cell][msg.sender];
        CellRewards storage c = cellRewards[cell];
        uint256 queued = Math.min(amount, p.queued);
        p.queued -= queued;
        c.queued -= queued;
        p.active -= amount - queued;
        c.active -= amount - queued;
        parked[cell][msg.sender] -= amount;
        parkedTotal[cell] -= amount;
        totalParked -= amount;
        PLANT.safeTransfer(msg.sender, amount);
        emit Unparked(msg.sender, cell, amount);
    }

    function challenge(uint32 cell) external nonReentrant {
        _aliveBound();
        WeatherQuestion.validate(cell);
        _challenge(cell);
    }

    function _challenge(uint32 cell) private {
        if (cell != location && votingStake(cell) > votingStake(challenger)) {
            challenger = cell;
            emit Challenged(cell);
        }
    }

    function heartbeat(uint256 maxAdvance) external nonReentrant returns (bytes32 id) {
        _aliveBound();
        if (pending.exists) revert RequestPending();
        uint32 day = lastSettledDay + 1;
        if (day >= today()) revert DayNotEnded();
        if (day <= bindDay) revert NoRequest();
        if (block.timestamp < retryAt) revert RetryLater();
        uint256 price = intake.priceOf(action, address(IMD));
        uint256 available = spendablePot();
        if (price > available) {
            uint256 advance = price - available;
            if (advance > maxAdvance) revert AdvanceTooLarge();
            _pullExact(IMD, msg.sender, advance);
            feeAdvances[msg.sender] += advance;
            feeAdvanceTotal += advance;
            feeUnlockEpoch[msg.sender] = epoch + 1;
            emit Advanced(msg.sender, advance);
        }
        uint256 beforeBalance = IMD.balanceOf(address(this));
        IMD.forceApprove(address(intake), price);
        id = intake.request(
            action,
            requestBody(location, day),
            IIntake.Callback(address(this), this.onOracleResult.selector),
            address(IMD),
            price
        );
        IMD.forceApprove(address(intake), 0);
        if (IMD.balanceOf(address(this)) != beforeBalance - price) revert NonExactTransfer();
        pending =
            Pending(id, day, challenger, msg.sender, uint64(block.timestamp), address(intake), true, false, bytes32(0));
        emit Asked(id, day, location, challenger, msg.sender, price);
    }

    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata sig)
        external
        nonReentrant
    {
        Pending storage p = pending;
        if (!p.exists || p.received || requestId != p.requestId) revert UnknownRequest();
        if (msg.sender != p.intake) revert NotTheIntake();
        if (isDead()) revert DeadPlant();
        _verifyAttestation(a, sig);
        if (
            a.chainId != CHAIN_ID || a.issuedAt < p.askedAt || a.panelSize < 15 || a.quorum < 10
                || a.quorum > a.panelSize || a.agreed < a.quorum || a.agreed > a.panelSize || a.answer.length != 32
        ) revert InvalidAttestation();
        bytes32 word = decodeBytes32(a);
        uint256 w = uint256(word);
        if (uint32(w >> 96) != p.day) revert WrongDay();
        // Only the two masks, complete bit and 32-bit day are defined. Weather cannot be both.
        uint256 mask = (uint256(type(uint32).max) << 96) | ((uint256(1) << 49) - 1);
        if (
            (w & ~mask) != 0 || ((w & 0xffffff) & ((w >> 24) & 0xffffff)) != 0
                || ((w & (uint256(1) << 48)) == 0 && (w & ((uint256(1) << 48) - 1)) != 0)
        ) revert InvalidWord();
        _consume(a.requestId);
        p.word = word;
        p.received = true;
        emit Received(requestId, a.requestId, word);
    }

    function clearPending() external nonReentrant {
        if (!pending.exists) revert NoRequest();
        if (pending.received) {
            if ((uint256(pending.word) & (uint256(1) << 48)) != 0) revert NotTimedOut();
            _settle(false);
        } else {
            if (block.timestamp < uint256(pending.askedAt) + ORACLE_TIMEOUT) revert NotTimedOut();
            if (isDead()) _clear();
            else _settle(true);
        }
    }

    function _clear() private {
        bytes32 id = pending.requestId;
        uint32 day = pending.day;
        delete pending;
        retryAt = block.timestamp + RETRY_DELAY;
        emit Cleared(id, day, retryAt);
    }

    function settle() external nonReentrant {
        _settle(false);
    }

    function settle(uint32 day) external nonReentrant {
        if (day != lastSettledDay + 1) revert WrongDay();
        _settle(false);
    }

    function _settle(bool timedOut) private {
        uint32 day = lastSettledDay + 1;
        if (day >= today()) revert DayNotEnded();
        if (hook == address(0) || day <= bindDay) {
            uint32 end = hook == address(0) ? today() - 1 : uint32(Math.min(today() - 1, bindDay));
            lastSettledDay = end;
            emit EmptyCatchUp(day, end);
            return;
        }
        _aliveBound();
        if (!pending.received && !timedOut) revert NoResult();
        Pending memory p = pending;
        if (p.day != day) revert WrongDay();
        uint32 candidate = p.challenger;
        bytes32 word = timedOut ? bytes32(uint256(day) << 96) : p.word;
        address caller = p.caller;
        uint256 pool;
        uint256 sips;
        if ((uint256(word) & (uint256(1) << 48)) == 0) {
            uint8 count = ++incompletes[day];
            emit Incomplete(day, count);
            _clear();
            if (count < 3) return;
        } else {
            (sips, pool) = _hours(uint256(word));
            delete pending;
        }
        uint32 oldCell = location;
        _distribute(oldCell, pool);
        if (!_read(candidate) && challenger != candidate) _read(challenger);
        lastSettledDay = day;
        ++epoch;
        retryAt = 0;
        if (caller != address(0)) {
            uint256 bounty = spendablePot() / 100;
            credits[caller] += bounty;
            creditTotal += bounty;
            emit Bounty(caller, bounty);
            _pay(caller);
        }
        emit Settled(day, word, sips, backing, water, location);
    }

    function _hours(uint256 word) private returns (uint256 sips, uint256 pool) {
        uint256 available = spendablePot();
        uint256 wet = water;
        for (uint256 h; h < 24; ++h) {
            if ((word & (uint256(1) << (24 + h))) != 0) wet = Math.min(100, wet + 3);
            if ((word & (uint256(1) << h)) != 0 && wet > 0) {
                --wet;
                uint256 sip = available / 10;
                available -= sip;
                sips += sip;
                pool += sip / 3;
            }
        }
        backing += sips - pool;
        water = uint8(wet);
    }

    /// @notice stake[cell] = PLANT parked since the previous successful settle.
    /// New parks count from the next settle; unparked stake drops out immediately.
    /// Nomination, READ, its 5% threshold and the gardener pool all use this rule.
    function votingStake(uint32 cell) public view returns (uint256) {
        CellRewards storage c = cellRewards[cell];
        // Mirror _rollCell without writing. Queued deposits mature only after a successful
        // settle advances epoch; withdrawals already remove active stake in unpark.
        uint256 active = c.active + (c.epoch < epoch ? c.queued : 0);
        return Math.min(active, parkedTotal[cell]);
    }

    function _read(uint32 candidate) private returns (bool moved) {
        uint32 current = location;
        uint256 candidateStake = votingStake(candidate);
        uint256 currentStake = votingStake(current);
        if (
            candidate != 0 && candidate != current && candidateStake > currentStake
                && candidateStake >= Math.ceilDiv(PLANT.totalSupply() - burned, 20)
        ) {
            location = candidate;
            challenger = 0;
            emit Moved(current, candidate);
            return true;
        }
    }

    function _rollCell(uint32 cell) private {
        CellRewards storage c = cellRewards[cell];
        if (c.epoch < epoch) {
            if (c.queued != 0) {
                activationCheckpoint[cell][c.epoch] = c.rewardPerToken;
                c.active += c.queued;
                c.queued = 0;
            }
            c.epoch = epoch;
        }
    }

    function _distribute(uint32 cell, uint256 pool) private {
        lastRewardCell = cell;
        _rollCell(cell);
        CellRewards storage c = cellRewards[cell];
        if (pool == 0) return;
        uint256 oldReserve = gardenerReserve();
        uint256 stake = votingStake(cell);
        if (stake != 0) {
            uint256 delta = Math.mulDiv(pool, SCALE, stake);
            c.rewardPerToken += delta;
            gardenerPoints += delta * stake;
        }
        uint256 reserved = gardenerReserve() - oldReserve;
        backing += pool - reserved;
        emit Rewarded(cell, pool, reserved);
    }

    function _checkpoint(uint32 cell, address holder) private {
        _rollCell(cell);
        Position storage p = positions[cell][holder];
        uint256 rpt = cellRewards[cell].rewardPerToken;
        uint256 points = p.active * (rpt - p.paid);
        if (p.epoch < epoch && p.queued != 0) {
            points += p.queued * (rpt - activationCheckpoint[cell][p.epoch]);
            p.active += p.queued;
            p.queued = 0;
        }
        p.epoch = epoch;
        p.paid = rpt;
        if (points != 0) {
            uint256 oldReserve = gardenerReserve();
            gardenerPoints -= points;
            uint256 credit = points / SCALE;
            credits[holder] += credit;
            creditTotal += credit;
            backing += oldReserve - gardenerReserve() - credit;
            emit Checkpointed(holder, cell, credit);
        }
    }

    /// @notice Checkpoint any holder in a known cell without an on-chain list of cells/holders.
    function checkpoint(uint32 cell, address holder) external nonReentrant {
        _checkpoint(cell, holder);
    }

    function claim() external nonReentrant {
        _syncDeath();
        _checkpoint(lastParkedCell[msg.sender], msg.sender);
        if (lastRewardCell != lastParkedCell[msg.sender]) _checkpoint(lastRewardCell, msg.sender);
        _pay(msg.sender);
    }

    /// @notice Claim older cells after moves; a caller supplies cells, never a global scan.
    function claim(uint32[] calldata cells) external nonReentrant {
        _syncDeath();
        for (uint256 i; i < cells.length; ++i) {
            _checkpoint(cells[i], msg.sender);
        }
        _pay(msg.sender);
    }

    function _pay(address holder) private {
        uint256 credit = credits[holder];
        uint256 advance;
        if (epoch >= feeUnlockEpoch[holder] || dead) {
            // Reserved backing and gardener/bounty claims never finance oracle fees.
            uint256 held = IMD.balanceOf(address(this));
            uint256 senior = backing + gardenerReserve() + creditTotal;
            if (held > senior) advance = Math.min(feeAdvances[holder], held - senior);
        }
        if (credit + advance == 0) return;
        credits[holder] = 0;
        creditTotal -= credit;
        feeAdvances[holder] -= advance;
        feeAdvanceTotal -= advance;
        if (IMD.trySafeTransfer(holder, credit + advance)) {
            emit Paid(holder, credit, advance);
        } else {
            credits[holder] = credit;
            creditTotal += credit;
            feeAdvances[holder] += advance;
            feeAdvanceTotal += advance;
            emit PaymentDeferred(holder, credit + advance);
        }
    }

    function redeem(uint256 amount) external nonReentrant returns (uint256 payout) {
        if (hook == address(0)) revert Unbound();
        _syncDeath();
        uint256 remaining = PLANT.totalSupply() - burned;
        if (amount == 0 || amount > remaining) revert InvalidAmount();
        uint256 currentFloor = floor();
        payout = Math.mulDiv(amount, currentFloor, SCALE);
        if (!dead) payout = Math.mulDiv(payout, 9, 10);
        _pullExact(PLANT, msg.sender, amount);
        burned += amount;
        backing -= payout;
        if (amount == remaining) terminalFloor = currentFloor;
        if (payout != 0) IMD.safeTransfer(msg.sender, payout);
        emit Redeemed(msg.sender, amount, payout, dead);
    }

    function die() external nonReentrant {
        if (!isDead()) revert NotDead();
        _syncDeath();
    }

    function _syncDeath() private {
        if (!isDead()) return;
        uint256 merged = spendablePot();
        backing += merged;
        if (!dead) {
            dead = true;
            delete pending;
            emit Died(today(), merged);
        } else if (merged != 0) {
            emit PotMerged(merged);
        }
    }

    function rotationDigest(address newSigner, address newIntake, bytes32 newAction, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ROTATE_TYPEHASH, address(this), block.chainid, newSigner, newIntake, newAction, nonce, deadline
                )
            )
        );
    }

    function rotate(
        address newSigner,
        address newIntake,
        bytes32 newAction,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant {
        if (newSigner == address(0) || newIntake.code.length == 0 || newAction == bytes32(0)) {
            revert InvalidConfiguration();
        }
        if (nonce != rotationNonce) revert InvalidNonce();
        if (block.timestamp > deadline) revert RotationExpired();
        if (!SignatureChecker.isValidSignatureNowCalldata(
                oracleSigner, rotationDigest(newSigner, newIntake, newAction, nonce, deadline), sig
            )) revert BadSignature();
        address oldSigner = oracleSigner;
        signerAcceptedUntil[oldSigner] = block.timestamp + SIGNER_GRACE;
        ++rotationNonce;
        _setOracleSigner(newSigner);
        intake = IIntake(newIntake);
        action = newAction;
        emit Rotated(oldSigner, newSigner, newIntake, newAction, nonce);
    }

    /// @dev Raw signatures retain EOA compatibility. A previous contract signer is identified by
    /// abi.encodePacked(signer, signature); lookup is bounded even after many rotations.
    function _isValidAttestationSignature(bytes32 digest, bytes calldata sig) internal view override returns (bool) {
        if (SignatureChecker.isValidSignatureNowCalldata(oracleSigner, digest, sig)) return true;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, sig);
        if (err == ECDSA.RecoverError.NoError && _graceSignature(recovered, digest, sig)) return true;
        if (sig.length >= 20) return _graceSignature(address(bytes20(sig[:20])), digest, sig[20:]);
        return false;
    }

    function _graceSignature(address signer, bytes32 digest, bytes calldata sig) private view returns (bool) {
        return block.timestamp < signerAcceptedUntil[signer]
            && SignatureChecker.isValidSignatureNowCalldata(signer, digest, sig);
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert NonExactTransfer();
    }
}
