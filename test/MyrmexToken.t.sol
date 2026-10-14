// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyrmexToken} from "../src/MyrmexToken.sol";

/// @notice Deploys the token from a contract, the way the launch factory does, so that the test can
/// check the supply is minted to `msg.sender` of the constructor and not to the EOA that sent the tx.
contract DeployerProbe {
    MyrmexToken public token;

    function deploy() external returns (MyrmexToken) {
        token = new MyrmexToken();
        return token;
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract MyrmexTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether; // 1e9 * 1e18, since `ether` is 1e18
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant SECP256K1_HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    DeployerProbe factory;
    MyrmexToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 signerKey;
    address signer;

    function setUp() public {
        factory = new DeployerProbe();
        token = factory.deploy();
        (signer, signerKey) = makeAddrAndKey("signer");
    }

    // ────────────────────────── Construction ─────────────────────────

    function test_metadata() public view {
        assertEq(token.name(), "MyrmexSI");
        assertEq(token.symbol(), "MYRM");
        assertEq(token.decimals(), 18);
        assertEq(token.NAME(), "MyrmexSI");
        assertEq(token.SYMBOL(), "MYRM");
        assertEq(token.DECIMALS(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the deploying contract holds everything");
        assertEq(token.balanceOf(address(this)), 0, "the test (tx sender) holds nothing");
        assertEq(token.balanceOf(tx.origin), 0, "tx.origin holds nothing");
    }

    function test_constructorEmitsMintTransfer() public {
        DeployerProbe other = new DeployerProbe();
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(other), SUPPLY);
        other.deploy();
    }

    function test_supplyIsExactlyOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
    }

    function test_hasNoMintOrPrivilegedEntryPoints() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "burnFrom(address,uint256)",
            "owner()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ──────────────────────────── Transfer ───────────────────────────

    function test_transferMovesFullAmount() public {
        factory.send(alice, 1_000 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 400 ether);
        assertTrue(token.transfer(bob, 400 ether));
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob), 400 ether);
        assertEq(token.totalSupply(), SUPPLY, "transfers do not change supply");
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        factory.send(alice, 10 ether);
        vm.prank(alice);
        token.transfer(alice, 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        factory.send(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 5 ether, 6 ether));
        token.transfer(bob, 6 ether);
    }

    function test_transferRevertsToZeroAddress() public {
        factory.send(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(MyrmexToken.ZeroAddress.selector);
        token.transfer(address(0), 1 ether);
    }

    function testFuzz_transferConservesSupply(address to, uint256 seedAmount, uint256 moved) public {
        vm.assume(to != address(0) && to != alice);
        seedAmount = bound(seedAmount, 0, SUPPLY);
        moved = bound(moved, 0, seedAmount);
        factory.send(alice, seedAmount);
        vm.prank(alice);
        token.transfer(to, moved);
        assertEq(token.balanceOf(alice), seedAmount - moved);
        assertEq(token.balanceOf(to), moved);
        assertEq(token.balanceOf(alice) + token.balanceOf(to) + token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferMoreThanBalanceReverts(uint256 held, uint256 extra) public {
        held = bound(held, 0, SUPPLY - 1);
        extra = bound(extra, 1, SUPPLY - held);
        factory.send(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, held, held + extra));
        token.transfer(bob, held + extra);
    }

    // ───────────────────────── Approve / transferFrom ─────────────────────────

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 7 ether);
        assertTrue(token.approve(bob, 7 ether));
        assertEq(token.allowance(alice, bob), 7 ether);
    }

    function test_approveOverwritesNotAccumulates() public {
        vm.startPrank(alice);
        token.approve(bob, 7 ether);
        token.approve(bob, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 3 ether);
    }

    function test_approveRevertsOnZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(MyrmexToken.ZeroAddress.selector);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        factory.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 6 ether);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 2 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 4 ether);
        assertTrue(token.transferFrom(alice, carol, 4 ether));

        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.balanceOf(carol), 4 ether);
        assertEq(token.allowance(alice, bob), 2 ether);
    }

    function test_transferFromInfiniteAllowanceIsNotDecreased() public {
        factory.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 4 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), 4 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        factory.send(alice, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, bob, 0, 1 ether));
        token.transferFrom(alice, carol, 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_transferFromRevertsWhenAllowanceTooSmall() public {
        factory.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 3 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, bob, 3 ether, 4 ether)
        );
        token.transferFrom(alice, carol, 4 ether);
    }

    function test_transferFromRevertsWhenBalanceTooSmallEvenWithAllowance() public {
        factory.send(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(alice, carol, 2 ether);
        assertEq(token.allowance(alice, bob), 5 ether, "a failed transferFrom leaves the allowance");
    }

    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        factory.send(alice, 10 ether);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, address(factory), 0, 1)
        );
        token.transferFrom(alice, address(factory), 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, SUPPLY);
        spent = bound(spent, 0, SUPPLY);
        factory.send(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        if (spent > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(MyrmexToken.InsufficientAllowance.selector, alice, bob, allowed, spent)
            );
            token.transferFrom(alice, carol, spent);
        } else {
            token.transferFrom(alice, carol, spent);
            assertEq(token.balanceOf(carol), spent);
            assertEq(token.allowance(alice, bob), allowed - spent);
        }
    }

    // ───────────────────────────── Burn ──────────────────────────────

    function test_burnReducesSupplyAndBalance() public {
        factory.send(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 4 ether);
        token.burn(4 ether);
        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.totalSupply(), SUPPLY - 4 ether);
    }

    function test_burnRevertsOnInsufficientBalance() public {
        factory.send(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.burn(2 ether);
    }

    function test_burnOnlyAffectsCallerNotOthers() public {
        factory.send(alice, 10 ether);
        factory.send(bob, 10 ether);
        vm.prank(alice);
        token.burn(10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function testFuzz_supplyNeverExceedsInitial(uint256 burned) public {
        burned = bound(burned, 0, SUPPLY);
        factory.send(alice, SUPPLY);
        vm.prank(alice);
        token.burn(burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertLe(token.totalSupply(), SUPPLY);
    }

    // ──────────────────────────── Launch flows ───────────────────────────

    /// @dev The factory moves 10% to the distributor, which pays it out whole; nothing is taxed.
    function test_launchFlowsArriveWhole() public {
        address distributor = makeAddr("distributor");
        address claimant = makeAddr("claimant");
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.send(distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm);
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm);
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A pool-manager-like contract pulls via transferFrom and pushes via transfer with no loss.
    function test_contractCounterpartyRoundTripIsLossless() public {
        address poolManager = makeAddr("poolManager");
        factory.send(alice, 100 ether);
        vm.prank(alice);
        token.approve(poolManager, 100 ether);
        vm.prank(poolManager);
        token.transferFrom(alice, poolManager, 100 ether);
        assertEq(token.balanceOf(poolManager), 100 ether);
        vm.prank(poolManager);
        token.transfer(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(poolManager), 0);
    }

    // ──────────────────────────── Permit ───────────────────────────

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(token.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_domainSeparatorMatchesEip712() public view {
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
        (bytes1 fields, string memory domainName, string memory version, uint256 chainId, address verifying,,) =
            token.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(domainName, "MyrmexSI");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
    }

    function test_domainSeparatorChangesWithChainId() public {
        bytes32 before = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != before, "a fork must get its own domain");
    }

    function test_permitSetsAllowanceAndConsumesNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        vm.expectEmit(true, true, true, true);
        emit Approval(signer, bob, 5 ether);
        vm.prank(carol); // anyone may relay
        token.permit(signer, bob, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 5 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitThenTransferFrom() public {
        factory.send(signer, 10 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        token.permit(signer, bob, 5 ether, deadline, v, r, s);
        vm.prank(bob);
        token.transferFrom(signer, carol, 5 ether);
        assertEq(token.balanceOf(carol), 5 ether);
        assertEq(token.allowance(signer, bob), 0);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        token.permit(signer, bob, 5 ether, deadline, v, r, s);
        // The nonce moved on, so the same signature recovers to a different address.
        vm.expectRevert();
        token.permit(signer, bob, 5 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 deadline = block.timestamp + 10;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.PermitExpired.selector, deadline, deadline + 1));
        token.permit(signer, bob, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
    }

    function test_permitAtDeadlineIsAccepted() public {
        uint256 deadline = block.timestamp + 10;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        vm.warp(deadline);
        token.permit(signer, bob, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 5 ether);
    }

    function test_permitRevertsOnWrongSigner() public {
        (address mallory, uint256 malloryKey) = makeAddrAndKey("mallory");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(malloryKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, mallory, signer));
        token.permit(signer, bob, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
    }

    function test_permitRevertsOnTamperedValue() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        vm.expectRevert();
        token.permit(signer, bob, 6 ether, deadline, v, r, s);
    }

    function test_permitRevertsOnMalleableHighS() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        // Flip to the other valid (s, v) pair; the token must refuse the high-s form.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        assertGt(uint256(highS), SECP256K1_HALF_ORDER);
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, address(0), signer));
        token.permit(signer, bob, 5 ether, deadline, flippedV, r, highS);
    }

    function test_permitRevertsOnBadV() public {
        uint256 deadline = block.timestamp + 1 hours;
        (, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 5 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, address(0), signer));
        token.permit(signer, bob, 5 ether, deadline, 29, r, s);
    }

    function test_permitRevertsOnZeroOwnerWithGarbageSignature() public {
        vm.expectRevert(abi.encodeWithSelector(MyrmexToken.InvalidSigner.selector, address(0), address(0)));
        token.permit(address(0), bob, 5 ether, block.timestamp + 1, 27, bytes32(0), bytes32(0));
    }

    function test_permitRevertsOnZeroSpender() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, address(0), 5 ether, 0, deadline));
        vm.expectRevert(MyrmexToken.ZeroAddress.selector);
        token.permit(signer, address(0), 5 ether, deadline, v, r, s);
    }

    function testFuzz_permitAnyValueAndDeadline(uint256 value, uint64 lifetime) public {
        uint256 deadline = block.timestamp + uint256(lifetime);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, value, 0, deadline));
        token.permit(signer, bob, value, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), value);
        assertEq(token.nonces(signer), 1);
    }
}
