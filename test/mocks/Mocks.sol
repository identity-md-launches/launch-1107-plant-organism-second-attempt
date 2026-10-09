// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

contract MockToken is IERC20 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    uint256 public transferFee;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    bool public reentryAttempted;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function setTransferFee(uint256 fee) external {
        transferFee = fee;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(!blocked[to], "blocked");
        balanceOf[from] -= amount;
        uint256 fee = amount * transferFee / 10000;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
    }
}

contract MockHook {
    address public immutable organism;
    address public immutable plant;

    constructor(address organism_, address plant_) {
        organism = organism_;
        plant = plant_;
    }
}

contract MockIntake is IIntake {
    uint256 public price = 0.5 ether;
    uint256 public sequence;
    bytes public lastBody;
    bytes32 public lastAction;
    address public lastAsset;
    uint256 public lastAmount;
    uint256 public allowanceAtRequest;
    bytes32 public lastId;
    Callback public callback;
    bool public undercharge;
    bool public reenter;
    bool public reentrySucceeded;

    function setPrice(uint256 value) external {
        price = value;
    }

    function setUndercharge(bool value) external {
        undercharge = value;
    }

    function setReenter(bool value) external {
        reenter = value;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata cb, address asset, uint256 amount)
        external
        payable
        returns (bytes32 id)
    {
        require(msg.value == 0 && amount == price, "price");
        allowanceAtRequest = IERC20(asset).allowance(msg.sender, address(this));
        require(allowanceAtRequest == price, "exact approval");
        require(IERC20(asset).transferFrom(msg.sender, address(this), undercharge ? amount / 2 : amount));
        lastBody = body;
        lastAction = action;
        lastAsset = asset;
        lastAmount = amount;
        callback = cb;
        id = keccak256(abi.encode(address(this), ++sequence));
        lastId = id;
        if (reenter) {
            (reentrySucceeded,) = msg.sender.call(abi.encodeWithSignature("heartbeat(uint256)", type(uint256).max));
        }
    }

    function deliver(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata sig)
        external
        returns (bool ok, bytes memory result, uint256 gasUsed)
    {
        uint256 start = gasleft();
        (ok, result) = callback.target.call{gas: 200000}(abi.encodeWithSelector(callback.selector, id, a, sig));
        gasUsed = start - gasleft();
    }
}
