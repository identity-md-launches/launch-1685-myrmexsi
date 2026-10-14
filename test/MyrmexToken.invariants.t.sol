// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MyrmexToken} from "../src/MyrmexToken.sol";

/// @notice Drives `MyrmexToken` with random, bounded call sequences from several actors and keeps a
/// ghost copy of everything the token should be tracking: the supply it still owes, every allowance,
/// every permit nonce. The handler is also the token's deployer, so it plays the launch factory and
/// starts holding the whole supply.
/// @dev Every handler function is written so it never reverts on its own (`fail_on_revert` is on):
/// inputs are bounded into the valid range, and the failure paths are exercised deliberately in
/// functions that expect the revert, check the reason, and check that nothing moved.
contract MyrmexHandler is CommonBase, StdCheats, StdUtils {
    MyrmexToken public immutable token;
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    /// @dev Every address that can ever hold a balance: the handler (deployer), the actors, the
    /// token itself (tokens sent there are stuck but still part of the supply) and one outsider that
    /// only ever receives.
    address[] public holders;
    address[] public actors;
    mapping(address => uint256) public keyOf;
    address public immutable outsider;

    // ───────────────────────────── Ghosts ─────────────────────────────

    uint256 public ghost_burned;
    uint256 public ghost_transferred;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    mapping(address => uint256) public ghost_nonce;

    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_approve;
    uint256 public calls_burn;
    uint256 public calls_permit;
    uint256 public calls_expectedReverts;

    // Last permit signature seen, to try replaying it.
    struct LastPermit {
        address owner;
        address spender;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bool set;
    }

    LastPermit internal lastPermit;

    constructor(uint256 actorCount) {
        token = new MyrmexToken();
        outsider = makeAddr("outsider");
        holders.push(address(this));
        for (uint256 i; i < actorCount; ++i) {
            (address actor, uint256 key) = makeAddrAndKey(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            holders.push(actor);
            keyOf[actor] = key;
        }
        holders.push(address(token));
        holders.push(outsider);
    }

    // ──────────────────────────── Helpers ────────────────────────────

    function holdersLength() external view returns (uint256) {
        return holders.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    /// @dev Any address that may send: the handler itself or an actor.
    function _sender(uint256 seed) internal view returns (address) {
        uint256 i = bound(seed, 0, actors.length);
        return i == actors.length ? address(this) : actors[i];
    }

    /// @dev Any address that may receive: every holder, which includes the token and the outsider.
    function _recipient(uint256 seed) internal view returns (address) {
        return holders[bound(seed, 0, holders.length - 1)];
    }

    /// @dev Only actors sign permits (they have keys).
    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _digest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(token.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev Sends tokens from the handler's own stock to an actor so that actors have something to
    /// move. The handler's balance shrinks, which the sum invariant accounts for.
    function _fund(address to, uint256 amount) internal {
        if (amount == 0 || to == address(this)) return;
        uint256 stock = token.balanceOf(address(this));
        if (stock == 0) return;
        if (amount > stock) amount = stock;
        token.transfer(to, amount);
        ghost_transferred += amount;
    }

    // ───────────────────────────── Actions ────────────────────────────

    /// @notice Seeds an actor from the deployer's stock, like the factory forwarding the launch shares.
    function fund(uint256 actorSeed, uint256 amount) external {
        address to = _actor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(address(this)));
        _fund(to, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _sender(fromSeed);
        address to = _recipient(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        require(ok, "transfer returned false");

        if (from == to) {
            require(token.balanceOf(from) == fromBefore, "self-transfer changed balance");
        } else {
            require(token.balanceOf(from) == fromBefore - amount, "sender balance wrong");
            require(token.balanceOf(to) == toBefore + amount, "recipient balance wrong");
        }
        ghost_transferred += amount;
        ++calls_transfer;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _sender(ownerSeed);
        address spender = _recipient(spenderSeed);

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        require(ok, "approve returned false");

        ghost_allowance[owner][spender] = amount;
        ++calls_approve;
    }

    function approveMax(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _sender(ownerSeed);
        address spender = _recipient(spenderSeed);
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghost_allowance[owner][spender] = type(uint256).max;
        ++calls_approve;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _sender(spenderSeed);
        address owner = _sender(ownerSeed);
        address to = _recipient(toSeed);

        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = allowed < token.balanceOf(owner) ? allowed : token.balanceOf(owner);
        amount = bound(amount, 0, cap);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        require(ok, "transferFrom returned false");

        if (owner == to) {
            require(token.balanceOf(owner) == ownerBefore, "self-transferFrom changed balance");
        } else {
            require(token.balanceOf(owner) == ownerBefore - amount, "owner balance wrong");
            require(token.balanceOf(to) == toBefore + amount, "recipient balance wrong");
        }
        if (allowed != type(uint256).max) {
            ghost_allowance[owner][spender] = allowed - amount;
        }
        ghost_transferred += amount;
        ++calls_transferFrom;
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _sender(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 before = token.balanceOf(from);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(from);
        token.burn(amount);

        require(token.balanceOf(from) == before - amount, "burn did not reduce balance");
        require(token.totalSupply() == supplyBefore - amount, "burn did not reduce supply");
        ghost_burned += amount;
        ++calls_burn;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 relayerSeed, uint256 value, uint256 lifetime)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _recipient(spenderSeed);
        if (spender == address(0)) spender = outsider;
        address relayer = _sender(relayerSeed);
        lifetime = bound(lifetime, 0, 365 days);
        uint256 deadline = block.timestamp + lifetime;
        uint256 nonce = token.nonces(owner);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[owner], _digest(owner, spender, value, nonce, deadline));

        vm.prank(relayer);
        token.permit(owner, spender, value, deadline, v, r, s);

        require(token.allowance(owner, spender) == value, "permit did not set allowance");
        require(token.nonces(owner) == nonce + 1, "permit did not consume the nonce");
        ghost_allowance[owner][spender] = value;
        ghost_nonce[owner] = nonce + 1;
        lastPermit = LastPermit(owner, spender, value, deadline, v, r, s, true);
        ++calls_permit;
    }

    // ───────────────────────── Expected failures ─────────────────────────

    /// @notice Moving more than the balance must revert with the exact error and move nothing.
    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 extra) external {
        address from = _sender(fromSeed);
        address to = _recipient(toSeed);
        uint256 held = token.balanceOf(from);
        extra = bound(extra, 1, type(uint256).max - held);
        uint256 amount = held + extra;

        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) {
            revert("transfer over balance did not revert");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, from, held, amount)),
                "wrong revert reason for transfer over balance"
            );
        }
        require(token.balanceOf(from) == held, "a failed transfer moved the sender's balance");
        require(token.balanceOf(to) == toBefore, "a failed transfer credited the recipient");
        ++calls_expectedReverts;
    }

    /// @notice Spending more than the allowance must revert with the exact error and leave the
    /// allowance and both balances alone. Only for finite allowances; unlimited ones never run out.
    function transferFromOverAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 extra) external {
        address spender = _sender(spenderSeed);
        address owner = _sender(ownerSeed);
        address to = _recipient(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Pin it to a finite value first so the failure path is reachable.
            vm.prank(owner);
            token.approve(spender, 0);
            ghost_allowance[owner][spender] = 0;
            allowed = 0;
        }
        extra = bound(extra, 1, type(uint256).max - allowed);
        uint256 amount = allowed + extra;

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transferFrom over allowance did not revert");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(
                            MyrmexToken.InsufficientAllowance.selector, owner, spender, allowed, amount
                        )
                    ),
                "wrong revert reason for transferFrom over allowance"
            );
        }
        require(token.allowance(owner, spender) == allowed, "a failed transferFrom changed the allowance");
        require(token.balanceOf(owner) == ownerBefore, "a failed transferFrom moved the owner's balance");
        require(token.balanceOf(to) == toBefore, "a failed transferFrom credited the recipient");
        ++calls_expectedReverts;
    }

    /// @notice An unlimited allowance does not help a spender past the owner's balance.
    function transferFromOverBalanceWithMaxAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 extra) external {
        address spender = _sender(spenderSeed);
        address owner = _sender(ownerSeed);
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghost_allowance[owner][spender] = type(uint256).max;

        uint256 held = token.balanceOf(owner);
        extra = bound(extra, 1, type(uint256).max - held);
        uint256 amount = held + extra;

        vm.prank(spender);
        try token.transferFrom(owner, outsider, amount) {
            revert("transferFrom over balance did not revert");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, owner, held, amount)),
                "wrong revert reason for transferFrom over balance"
            );
        }
        require(token.balanceOf(owner) == held, "a failed transferFrom moved the owner's balance");
        require(token.allowance(owner, spender) == type(uint256).max, "a failed transferFrom touched the allowance");
        ++calls_expectedReverts;
    }

    /// @notice Burning more than held must revert and change neither balance nor supply.
    function burnOverBalance(uint256 fromSeed, uint256 extra) external {
        address from = _sender(fromSeed);
        uint256 held = token.balanceOf(from);
        extra = bound(extra, 1, type(uint256).max - held);
        uint256 amount = held + extra;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(from);
        try token.burn(amount) {
            revert("burn over balance did not revert");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, from, held, amount)),
                "wrong revert reason for burn over balance"
            );
        }
        require(token.balanceOf(from) == held, "a failed burn moved the balance");
        require(token.totalSupply() == supplyBefore, "a failed burn changed the supply");
        ++calls_expectedReverts;
    }

    /// @notice Transfers to the zero address are refused; nothing is burned by accident.
    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _sender(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 held = token.balanceOf(from);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(from);
        try token.transfer(address(0), amount) {
            revert("transfer to zero did not revert");
        } catch (bytes memory reason) {
            require(keccak256(reason) == keccak256(abi.encodeWithSelector(MyrmexToken.ZeroAddress.selector)));
        }
        require(token.balanceOf(from) == held);
        require(token.totalSupply() == supplyBefore);
        ++calls_expectedReverts;
    }

    /// @notice The zero spender is refused by `approve`.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _sender(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            revert("approve of zero spender did not revert");
        } catch (bytes memory reason) {
            require(keccak256(reason) == keccak256(abi.encodeWithSelector(MyrmexToken.ZeroAddress.selector)));
        }
        require(token.allowance(owner, address(0)) == 0);
        ++calls_expectedReverts;
    }

    /// @notice A signature that already set an allowance is dead: the nonce has moved on.
    function replayLastPermit(uint256 relayerSeed) external {
        if (!lastPermit.set) return;
        LastPermit memory p = lastPermit;
        uint256 nonceBefore = token.nonces(p.owner);
        uint256 allowanceBefore = token.allowance(p.owner, p.spender);

        vm.prank(_sender(relayerSeed));
        try token.permit(p.owner, p.spender, p.value, p.deadline, p.v, p.r, p.s) {
            revert("a used permit was accepted again");
        } catch (bytes memory reason) {
            // Still in date: the nonce moved on so the digest recovers to someone else. Out of
            // date: the deadline is checked first.
            bytes4 expected =
                block.timestamp > p.deadline ? MyrmexToken.PermitExpired.selector : MyrmexToken.InvalidSigner.selector;
            require(bytes4(reason) == expected, "replay failed for the wrong reason");
        }
        require(token.nonces(p.owner) == nonceBefore, "a rejected permit consumed a nonce");
        require(token.allowance(p.owner, p.spender) == allowanceBefore, "a rejected permit changed an allowance");
        ++calls_expectedReverts;
    }

    /// @notice A permit signed by anyone but the owner, or with the wrong nonce, sets nothing.
    function permitByWrongKey(uint256 ownerSeed, uint256 signerSeed, uint256 spenderSeed, uint256 value) external {
        address owner = _actor(ownerSeed);
        address signer = _actor(signerSeed);
        if (signer == owner) signer = actors[(bound(signerSeed, 0, actors.length - 1) + 1) % actors.length];
        address spender = _recipient(spenderSeed);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);
        uint256 allowanceBefore = token.allowance(owner, spender);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[signer], _digest(owner, spender, value, nonce, deadline));
        try token.permit(owner, spender, value, deadline, v, r, s) {
            revert("a permit by the wrong key was accepted");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, signer, owner)),
                "wrong-key permit failed for the wrong reason"
            );
        }
        require(token.nonces(owner) == nonce, "a rejected permit consumed a nonce");
        require(token.allowance(owner, spender) == allowanceBefore, "a rejected permit changed an allowance");
        ++calls_expectedReverts;
    }

    /// @notice An expired permit is refused before any signature work, and nothing changes.
    function permitExpired(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 age) external {
        address owner = _actor(ownerSeed);
        address spender = _recipient(spenderSeed);
        age = bound(age, 1, block.timestamp);
        uint256 deadline = block.timestamp - age;
        uint256 nonce = token.nonces(owner);
        uint256 allowanceBefore = token.allowance(owner, spender);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[owner], _digest(owner, spender, value, nonce, deadline));
        try token.permit(owner, spender, value, deadline, v, r, s) {
            revert("an expired permit was accepted");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(MyrmexToken.PermitExpired.selector, deadline, block.timestamp)),
                "expired permit failed for the wrong reason"
            );
        }
        require(token.nonces(owner) == nonce, "a rejected permit consumed a nonce");
        require(token.allowance(owner, spender) == allowanceBefore, "a rejected permit changed an allowance");
        ++calls_expectedReverts;
    }

    /// @notice Time moves between calls so deadlines actually matter.
    function warp(uint256 by) external {
        by = bound(by, 0, 30 days);
        vm.warp(block.timestamp + by);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MyrmexTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    MyrmexHandler handler;
    MyrmexToken token;
    bytes32 domainAtDeployment;

    function setUp() public {
        vm.warp(1_700_000_000);
        handler = new MyrmexHandler(5);
        token = handler.token();
        domainAtDeployment = token.DOMAIN_SEPARATOR();
        targetContract(address(handler));
    }

    function _sumOfHolderBalances() internal view returns (uint256 sum) {
        uint256 n = handler.holdersLength();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
    }

    /// @dev A fixed-supply token: after any sequence the supply is at most what was minted.
    function invariant_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), SUPPLY, "supply grew");
        assertLe(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    /// @dev The only way the supply moves is `burn`, and it moves by exactly what was burned.
    function invariant_supplyIsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), SUPPLY - handler.ghost_burned(), "supply != initial - burned");
    }

    /// @dev What the token owes (every balance) equals what it says exists (`totalSupply`).
    function invariant_balancesSumToSupply() public view {
        assertEq(_sumOfHolderBalances(), token.totalSupply(), "sum of balances != totalSupply");
    }

    /// @dev No single holder can hold more than exists.
    function invariant_noHolderExceedsSupply() public view {
        uint256 n = handler.holdersLength();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.holders(i)), token.totalSupply(), "a holder exceeds the supply");
        }
    }

    /// @dev Nothing ever lands on the zero address: it is neither a valid sender nor recipient.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// @dev Every allowance the token reports is exactly what the sequence of approve, permit and
    /// transferFrom calls should have left; unlimited allowances are never decreased.
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.holdersLength();
        for (uint256 i; i < n; ++i) {
            address owner = handler.holders(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.holders(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// @dev One accepted permit consumes exactly one nonce; a rejected one consumes none.
    function invariant_noncesMatchAcceptedPermits() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertEq(token.nonces(actor), handler.ghost_nonce(actor), "nonce drifted");
        }
    }

    /// @dev Nothing in the call surface can change the metadata, the domain or the minted constant.
    function invariant_metadataAndDomainAreFixed() public view {
        assertEq(token.name(), "MyrmexSI");
        assertEq(token.symbol(), "MYRM");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.DOMAIN_SEPARATOR(), domainAtDeployment, "domain separator moved on the same chain");
    }
}
