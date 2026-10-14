// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {MyrmexToken} from "../src/MyrmexToken.sol";

/// @notice Deploys the token from a contract, the way the launch factory does, so the whole supply
/// lands on the contract and not on the EOA that sent the transaction.
contract Deployer {
    MyrmexToken public token;

    constructor() {
        token = new MyrmexToken();
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice The inputs the implementation was least likely to think about: zero, one wei, the whole
/// supply, the maximum, the same call twice, a caller who is not who the code assumed, and the
/// surface outside the ERC-20 ABI (ETH, unknown selectors, a second deployment, another chain).
contract MyrmexTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant MAX = type(uint256).max;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    Deployer deployer;
    MyrmexToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 signerKey;
    address signer;

    function setUp() public {
        vm.warp(1_700_000_000);
        deployer = new Deployer();
        token = deployer.token();
        (signer, signerKey) = makeAddrAndKey("signer");
    }

    function _digest(MyrmexToken t, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(t.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(key, _digest(token, owner, spender, value, nonce, deadline));
    }

    // ───────────────────────── Construction edges ─────────────────────────

    /// @dev Two deployments are two independent tokens: each mints its own full supply to its own
    /// deployer and neither sees the other's balances. A launch that redeploys does not share state.
    function test_secondDeploymentIsIndependent() public {
        Deployer other = new Deployer();
        MyrmexToken second = other.token();
        assertTrue(address(second) != address(token));
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(address(other)), SUPPLY);
        assertEq(second.balanceOf(address(deployer)), 0);
        assertEq(token.balanceOf(address(other)), 0);
        assertTrue(second.DOMAIN_SEPARATOR() != token.DOMAIN_SEPARATOR(), "the domain must bind the address");
    }

    /// @dev Deployed straight from an EOA (no factory), the supply still goes to `msg.sender`.
    function test_deployFromEoaMintsToThatEoa() public {
        vm.prank(alice);
        MyrmexToken t = new MyrmexToken();
        assertEq(t.balanceOf(alice), SUPPLY);
        assertEq(t.totalSupply(), SUPPLY);
    }

    /// @dev The token has no receive or fallback: ETH sent to it is refused, and an unknown selector
    /// reverts instead of silently succeeding.
    function test_rejectsEtherAndUnknownSelectors() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "plain ETH transfer must be refused");
        assertEq(address(token).balance, 0);

        vm.prank(alice);
        (ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "unknown selector must revert");

        vm.prank(alice);
        (ok,) = address(token).call{value: 1}(abi.encodeWithSelector(token.transfer.selector, bob, 0));
        assertFalse(ok, "non-payable function must refuse value");
    }

    function test_eip712DomainHasNoSaltOrExtensions() public view {
        (bytes1 fields,,,,, bytes32 salt, uint256[] memory extensions) = token.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    // ───────────────────────── Transfer edges ─────────────────────────

    function test_transferOneWei() public {
        deployer.send(alice, 1);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_transferWholeSupplyMovesEverything() public {
        assertTrue(deployer.send(alice, SUPPLY));
        assertEq(token.balanceOf(address(deployer)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        token.transfer(bob, SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOneWeiOverWholeSupplyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, address(deployer), SUPPLY, SUPPLY + 1)
        );
        deployer.send(alice, SUPPLY + 1);
    }

    function test_transferMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, address(deployer), SUPPLY, MAX)
        );
        deployer.send(alice, MAX);
    }

    /// @dev An empty account sending zero is fine; an empty account sending one wei is not.
    function test_emptyAccountCanSendZeroButNotOne() public {
        vm.prank(carol);
        assertTrue(token.transfer(bob, 0));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, carol, 0, 1));
        token.transfer(bob, 1);
    }

    function test_zeroAmountTransferStillEmits() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 0);
        token.transfer(bob, 0);
    }

    /// @dev Zero to the zero address is still refused: the recipient check does not depend on amount.
    function test_transferZeroToZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(MyrmexToken.ZeroAddress.selector);
        token.transfer(address(0), 0);
    }

    /// @dev The same transfer twice: the second one is judged against the balance the first left.
    function test_sameTransferTwiceSecondFailsWhenFundsRunOut() public {
        deployer.send(alice, 10 ether);
        vm.startPrank(alice);
        token.transfer(bob, 6 ether);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 4 ether, 6 ether));
        token.transfer(bob, 6 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 6 ether);
        assertEq(token.balanceOf(alice), 4 ether);
    }

    /// @dev Self-transfer of the full balance neither loses nor duplicates tokens, even though the
    /// implementation writes the sender's balance before adding to the recipient's.
    function test_selfTransferOfWholeBalanceIsExact() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.transfer(alice, 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferOverBalanceReverts() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 10 ether, 10 ether + 1));
        token.transfer(alice, 10 ether + 1);
    }

    /// @dev Sending to the token contract itself is allowed by the standard; the tokens are then
    /// unrecoverable (there is no sweep), but they are still counted in the supply.
    function test_transferToTokenContractIsAcceptedAndStillCounted() public {
        deployer.send(alice, 5 ether);
        vm.prank(alice);
        token.transfer(address(token), 5 ether);
        assertEq(token.balanceOf(address(token)), 5 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
        // Nobody can move them out: the token never approves or transfers on its own behalf.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, address(token), alice, 0, 1));
        token.transferFrom(address(token), alice, 1);
    }

    /// @dev The one holder that matters at launch: a contract with the supply can transfer it out
    /// in several pieces that sum exactly to what it held.
    function test_deployerCanSplitSupplyExactly() public {
        uint256 swarm = SUPPLY / 10;
        uint256 pool = (SUPPLY * 8_000) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;
        deployer.send(alice, swarm);
        deployer.send(bob, pool);
        deployer.send(carol, remainder);
        assertEq(token.balanceOf(address(deployer)), 0);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol), SUPPLY);
    }

    function testFuzz_transferToAnyNonZeroAddressArrivesWhole(uint160 toSeed, uint256 amount) public {
        address to = address(uint160(bound(uint256(toSeed), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        uint256 before = token.balanceOf(to);
        uint256 deployerBefore = token.balanceOf(address(deployer));
        assertTrue(deployer.send(to, amount));
        if (to == address(deployer)) {
            assertEq(token.balanceOf(to), before);
        } else {
            assertEq(token.balanceOf(to), before + amount);
            assertEq(token.balanceOf(address(deployer)), deployerBefore - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_chainOfTransfersConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        deployer.send(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(carol, c);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(carol), c);
        assertEq(
            token.balanceOf(address(deployer)) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol),
            SUPPLY
        );
    }

    // ───────────────────────── Allowance edges ─────────────────────────

    /// @dev `allowance(owner, spender)` is directional: approving bob does not let alice spend bob's
    /// tokens. The fuzzed spender is kept distinct from the owner, otherwise both directions are
    /// the same slot and the check is meaningless.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveIsDirectional(uint160 spenderSeed, uint256 amount) public {
        address spender = address(uint160(bound(uint256(spenderSeed), 1, type(uint160).max)));
        if (spender == alice) spender = bob;
        vm.prank(alice);
        token.approve(spender, amount);
        assertEq(token.allowance(alice, spender), amount);
        assertEq(token.allowance(spender, alice), 0, "allowance is directional");
    }

    function test_approveSelfIsAllowedAndSpendable() public {
        deployer.send(alice, 3 ether);
        vm.startPrank(alice);
        token.approve(alice, 2 ether);
        token.transferFrom(alice, bob, 2 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.allowance(alice, alice), 0);
    }

    /// @dev Being the owner of the tokens does not exempt a caller from needing an allowance for
    /// `transferFrom` on its own account (standard EIP-20 behaviour, pinned here).
    function test_transferFromOwnAccountStillNeedsAllowance() public {
        deployer.send(alice, 3 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_approveZeroThenSpendZeroSucceeds() public {
        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 0));
    }

    function test_approveZeroThenSpendOneWeiReverts() public {
        deployer.send(alice, 1);
        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_approveNeedsNoBalance() public {
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        token.approve(bob, SUPPLY);
        assertEq(token.allowance(alice, bob), SUPPLY);
        // The allowance exceeds the balance; spending still fails on the balance check.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, carol, 1);
        assertEq(token.allowance(alice, bob), SUPPLY, "a failed spend leaves the allowance");
    }

    function test_sameApproveTwiceIsIdempotent() public {
        vm.startPrank(alice);
        token.approve(bob, 5 ether);
        token.approve(bob, 5 ether);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 5 ether);
    }

    function test_allowanceIsExactAtTheBoundary() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);
        vm.startPrank(bob);
        token.transferFrom(alice, carol, 4 ether);
        assertEq(token.allowance(alice, bob), 0);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        vm.stopPrank();
    }

    /// @dev Only exactly `type(uint256).max` is unlimited. One below it is an ordinary number.
    function test_allowanceOneBelowMaxIsNotUnlimited() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, MAX - 1);
        vm.prank(bob);
        token.transferFrom(alice, carol, 1 ether);
        assertEq(token.allowance(alice, bob), MAX - 1 - 1 ether);
    }

    function test_maxAllowanceEmitsNoApprovalOnSpend() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, MAX);
        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only the Transfer event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(token.allowance(alice, bob), MAX);
    }

    function test_finiteAllowanceEmitsApprovalWithRemainderOnSpend() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 3 ether);
        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "Approval then Transfer");
        assertEq(logs[0].topics[0], keccak256("Approval(address,address,uint256)"));
        assertEq(abi.decode(logs[0].data, (uint256)), 2 ether);
        assertEq(logs[1].topics[0], keccak256("Transfer(address,address,uint256)"));
    }

    /// @dev Re-approving after a partial spend overwrites, it does not add to the remainder.
    function test_reapproveAfterPartialSpendOverwrites() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 6 ether);
        vm.prank(bob);
        token.transferFrom(alice, carol, 2 ether);
        vm.prank(alice);
        token.approve(bob, 1 ether);
        assertEq(token.allowance(alice, bob), 1 ether);
    }

    /// @dev Spending for someone else does not touch the spender's own balance or allowances.
    function test_transferFromDoesNotTouchSpendersOwnBalance() public {
        deployer.send(alice, 10 ether);
        deployer.send(bob, 7 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.balanceOf(bob), 17 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(bob, alice), 0);
        assertEq(token.allowance(bob, bob), 0);
    }

    /// @dev A spender who is not who the owner approved gets nothing, even with the same amount.
    function test_unapprovedSpenderCannotUseAnotherSpendersAllowance() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, carol, 0, 10 ether));
        token.transferFrom(alice, carol, 10 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromAtExactAllowanceThenOneMoreFails(uint256 allowed) public {
        allowed = bound(allowed, 1, SUPPLY - 1);
        deployer.send(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.startPrank(bob);
        token.transferFrom(alice, carol, allowed);
        assertEq(token.allowance(alice, bob), 0);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(carol), allowed);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromSplitsSumToAllowance(uint256 allowed, uint256 first) public {
        allowed = bound(allowed, 0, SUPPLY);
        first = bound(first, 0, allowed);
        deployer.send(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.startPrank(bob);
        token.transferFrom(alice, carol, first);
        assertEq(token.allowance(alice, bob), allowed - first);
        token.transferFrom(alice, carol, allowed - first);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(carol), allowed);
    }

    // ───────────────────────── Burn edges ─────────────────────────

    function test_burnZeroIsANoOpThatEmits() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 0);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnOneWeiFromEmptyAccountReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    function test_burnWholeSupplyLeavesZeroAndTokenStillWorks() public {
        deployer.send(alice, SUPPLY);
        vm.prank(alice);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(alice), 0);
        // The contract keeps working with nothing left: zero-value moves succeed, real ones fail.
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    /// @dev Burned tokens are gone: nobody, not even the deployer, can recreate them.
    function test_burnedSupplyCannotComeBack() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.burn(10 ether);
        assertEq(token.totalSupply(), SUPPLY - 10 ether);
        vm.prank(address(deployer));
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 10 ether));
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY - 10 ether);
    }

    /// @dev `burn` takes no account argument: an allowance gives a spender no way to burn for the
    /// owner, and the owner's own burn ignores any allowance that was granted.
    function test_allowanceGivesNoBurnPower() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, bob, 0, 1 ether));
        token.burn(1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        vm.prank(bob);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_sameBurnTwiceSecondFailsWhenFundsRunOut() public {
        deployer.send(alice, 10 ether);
        vm.startPrank(alice);
        token.burn(6 ether);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 4 ether, 6 ether));
        token.burn(6 ether);
        vm.stopPrank();
        assertEq(token.totalSupply(), SUPPLY - 6 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_burnsFromSeveralHoldersSumToTheSupplyDrop(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY / 3);
        b = bound(b, 0, SUPPLY / 3);
        c = bound(c, 0, SUPPLY / 3);
        deployer.send(alice, a);
        deployer.send(bob, b);
        deployer.send(carol, c);
        vm.prank(alice);
        token.burn(a);
        vm.prank(bob);
        token.burn(b);
        vm.prank(carol);
        token.burn(c);
        assertEq(token.totalSupply(), SUPPLY - a - b - c);
        assertEq(token.balanceOf(address(deployer)), SUPPLY - a - b - c);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol), 0);
    }

    // ───────────────────────── Permit edges ─────────────────────────

    function test_permitZeroValueConsumesNonce() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 0, 0, block.timestamp);
        token.permit(signer, bob, 0, block.timestamp, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitMaxValueIsUnlimited() public {
        deployer.send(signer, 10 ether);
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, MAX, 0, MAX);
        token.permit(signer, bob, MAX, MAX, v, r, s);
        vm.prank(bob);
        token.transferFrom(signer, carol, 10 ether);
        assertEq(token.allowance(signer, bob), MAX);
    }

    /// @dev One second past the deadline is too late; the deadline second itself is in time.
    function test_permitExpiresExactlyOneSecondAfterDeadline() public {
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.PermitExpired.selector, deadline, deadline + 1));
        token.permit(signer, bob, 1, deadline, v, r, s);
        assertEq(token.nonces(signer), 0, "a rejected permit must not consume the nonce");
    }

    function test_permitDeadlineZeroIsAlwaysExpired() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.PermitExpired.selector, 0, block.timestamp));
        token.permit(signer, bob, 1, 0, v, r, s);
    }

    /// @dev Nonces are sequential: a signature for nonce 1 is useless until nonce 0 is spent, and
    /// then it works, so holders can pre-sign a queue.
    function test_permitNoncesAreSequential() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(signerKey, signer, bob, 2 ether, 1, deadline);
        (uint8 v0, bytes32 r0, bytes32 s0) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);

        vm.expectRevert();
        token.permit(signer, bob, 2 ether, deadline, v1, r1, s1);
        assertEq(token.nonces(signer), 0);

        token.permit(signer, bob, 1 ether, deadline, v0, r0, s0);
        assertEq(token.allowance(signer, bob), 1 ether);
        token.permit(signer, bob, 2 ether, deadline, v1, r1, s1);
        assertEq(token.allowance(signer, bob), 2 ether);
        assertEq(token.nonces(signer), 2);
    }

    /// @dev Nonces are per owner: one signer's permits never move another signer's counter.
    function test_permitNoncesAreIndependentPerOwner() public {
        (address other, uint256 otherKey) = makeAddrAndKey("other");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1, 0, deadline);
        token.permit(signer, bob, 1, deadline, v, r, s);
        assertEq(token.nonces(other), 0);
        (v, r, s) = _sign(otherKey, other, bob, 1, 0, deadline);
        token.permit(other, bob, 1, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
        assertEq(token.nonces(other), 1);
    }

    /// @dev A permit signed for a different token (same signer, same fields) is refused here, because
    /// the domain separator binds the verifying contract.
    function test_permitForAnotherTokenIsRefused() public {
        Deployer other = new Deployer();
        MyrmexToken second = other.token();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(second, signer, bob, 1 ether, 0, deadline));
        vm.expectRevert();
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
        // And it is still good on the token it was signed for.
        second.permit(signer, bob, 1 ether, deadline, v, r, s);
        assertEq(second.allowance(signer, bob), 1 ether);
    }

    /// @dev A permit signed on one chain id is refused after a fork changes the id, and the
    /// separator the token reports after the fork is the one computed for the new id.
    function test_permitDoesNotReplayAcrossChainIds() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        uint256 forkId = vm.getChainId() + 1;
        vm.chainId(forkId);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MyrmexSI"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
        vm.expectRevert();
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
        assertEq(token.nonces(signer), 0);
    }

    /// @dev Tampering with any one field (spender, deadline) invalidates the signature.
    function test_permitRevertsOnTamperedSpenderOrDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        vm.expectRevert();
        token.permit(signer, carol, 1 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, bob, 1 ether, deadline + 1, v, r, s);
        assertEq(token.nonces(signer), 0);
    }

    /// @dev `s` exactly at the half order is accepted, one above it is refused.
    function test_permitSBoundaryIsHalfOrder() public {
        uint256 half = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
        uint256 deadline = block.timestamp + 1 hours;
        (, bytes32 r,) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        // One above the half order never reaches ecrecover: the recovered address is reported as zero.
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, address(0), signer));
        token.permit(signer, bob, 1 ether, deadline, 27, r, bytes32(half + 1));
        // Exactly the half order passes the gate; with a synthetic s it then recovers to some other
        // account (or none), and is refused as a wrong signer either way.
        vm.expectRevert();
        token.permit(signer, bob, 1 ether, deadline, 27, r, bytes32(half));
        assertEq(token.nonces(signer), 0);
    }

    function test_permitRevertsOnVZeroAndOne() public {
        uint256 deadline = block.timestamp + 1 hours;
        (, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, address(0), signer));
        token.permit(signer, bob, 1 ether, deadline, 0, r, s);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, address(0), signer));
        token.permit(signer, bob, 1 ether, deadline, 1, r, s);
    }

    function test_permitWithAllZeroSignatureForRealOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, address(0), signer));
        token.permit(signer, bob, 1 ether, block.timestamp + 1, 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(signer), 0);
    }

    /// @dev A permit lets the spender move tokens, but never more than the owner holds.
    function test_permitAllowanceDoesNotCreateBalance() public {
        deployer.send(signer, 1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 5 ether, 0, deadline);
        token.permit(signer, bob, 5 ether, deadline, v, r, s);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, signer, 1 ether, 2 ether));
        token.transferFrom(signer, carol, 2 ether);
    }

    /// @dev `permit` overwrites a prior `approve` and vice versa; the two paths share one slot.
    function test_permitAndApproveShareOneSlot() public {
        vm.prank(signer);
        token.approve(bob, 9 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 1 ether);
        vm.prank(signer);
        token.approve(bob, 0);
        assertEq(token.allowance(signer, bob), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_permitByWrongKeyAlwaysReverts(uint256 wrongKey, uint256 value) public {
        // Any valid secp256k1 private key other than the signer's.
        wrongKey = bound(wrongKey, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        if (wrongKey == signerKey) wrongKey += 1;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(wrongKey, signer, bob, value, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, vm.addr(wrongKey), signer));
        token.permit(signer, bob, value, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
        assertEq(token.nonces(signer), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_permitWrongNonceAlwaysReverts(uint256 nonce, uint256 value) public {
        nonce = bound(nonce, 1, MAX);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, value, nonce, deadline);
        vm.expectRevert();
        token.permit(signer, bob, value, deadline, v, r, s);
        assertEq(token.nonces(signer), 0);
    }

    // ───────────────────────── Caller edges ─────────────────────────

    /// @dev The deployer has no power a stranger lacks: once its tokens are gone it is an ordinary
    /// empty account.
    function test_deployerIsOrdinaryOnceEmptied() public {
        deployer.send(alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, address(deployer), 0, 1));
        deployer.send(bob, 1);
        vm.prank(address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, address(deployer), 0, 1)
        );
        token.transferFrom(alice, address(deployer), 1);
    }

    /// @dev Calls from the zero address: `approve` is refused outright, and `transfer` fails on the
    /// zero-sender check before anything else.
    function test_callsFromZeroAddressAreRefused() public {
        vm.prank(address(0));
        vm.expectRevert(MyrmexToken.ZeroAddress.selector);
        token.approve(bob, 1);
        vm.prank(address(0));
        vm.expectRevert(MyrmexToken.ZeroAddress.selector);
        token.transfer(bob, 0);
    }

    /// @dev Every privileged selector in the floor's list, tried from the deployer, from the token
    /// itself and from a stranger: none exists, so none can freeze or move a holder.
    function test_privilegedSelectorsFromAnyCallerLeaveHoldersAlone() public {
        deployer.send(alice, 10 ether);
        string[13] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "renounceOwnership()"
        ];
        address[3] memory callers = [address(deployer), address(token), carol];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, true);
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.balanceOf(alice), 10 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }
}
