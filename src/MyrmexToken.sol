// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MyrmexSI (MYRM)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 MYRM (18 decimals) is minted once,
/// in the constructor, to the deployer (`msg.sender`). There is no owner, no minter, no pause, no
/// blocklist, no fee and no hook: after construction the contract has no privileged party and the
/// supply can only shrink, through `burn`, never grow.
/// @dev Self-contained implementation of EIP-20 plus EIP-2612 `permit` (with EIP-5267 `eip712Domain`)
/// so that holders can approve by signature. It imports nothing, calls no other contract, and uses
/// no library, so its creation code deploys unlinked on an empty chain. The contract identifier is
/// `MyrmexToken` (11 characters, within the launch's 32-byte limit); the token's `name()` is "MyrmexSI".
contract MyrmexToken {
    // ───────────────────────────── Errors ─────────────────────────────

    /// @notice A transfer or approval named the zero address as sender, recipient, owner or spender.
    error ZeroAddress();
    /// @notice `from` holds less than the amount being moved or burned.
    error InsufficientBalance(address from, uint256 balance, uint256 needed);
    /// @notice `spender` is allowed less than the amount being moved on behalf of `owner`.
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 needed);
    /// @notice The permit's `deadline` is in the past.
    error PermitExpired(uint256 deadline, uint256 blockTimestamp);
    /// @notice The permit's signature does not recover to `owner`.
    error InvalidSigner(address recovered, address owner);

    // ───────────────────────────── Events ─────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ──────────────────────────── Constants ───────────────────────────

    /// @notice Token name, as returned by `name()`.
    string public constant NAME = "MyrmexSI";
    /// @notice Token symbol, as returned by `symbol()`.
    string public constant SYMBOL = "MYRM";
    /// @notice Decimals, as returned by `decimals()`.
    uint8 public constant DECIMALS = 18;
    /// @notice The whole supply in minor units: 1,000,000,000 * 10^18. Minted once, in the constructor.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice EIP-2612 permit type hash.
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256(bytes(NAME));
    bytes32 private constant _VERSION_HASH = keccak256(bytes("1"));
    /// @dev secp256k1 curve order / 2: signatures with a higher `s` are malleable and refused.
    uint256 private constant _HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // ───────────────────────────── Storage ────────────────────────────

    uint256 private _totalSupply;
    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;
    /// @notice EIP-2612 nonce of each owner; consumed by `permit`.
    mapping(address owner => uint256) public nonces;

    /// @dev Chain id at construction and the domain separator computed for it. If the chain forks,
    /// the separator is recomputed on the fly for the new id so permits cannot be replayed across forks.
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    // ─────────────────────────── Constructor ──────────────────────────

    /// @notice Mints `INITIAL_SUPPLY` to the deployer. Takes no arguments and calls no contract.
    constructor() {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();

        _totalSupply = INITIAL_SUPPLY;
        _balances[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ──────────────────────────── Metadata ────────────────────────────

    function name() external pure returns (string memory) {
        return NAME;
    }

    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    // ───────────────────────────── EIP-20 ─────────────────────────────

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Moves `amount` from the caller to `to`. Full amount, no fee, no hook.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to `amount` (overwrites, EIP-20 semantics).
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` on the strength of the caller's allowance. An
    /// allowance of `type(uint256).max` is treated as unlimited and is not decreased.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ─────────────────────────────── Burn ─────────────────────────────

    /// @notice Destroys `amount` of the caller's own tokens, reducing the total supply. Only the
    /// holder can burn its balance: there is no `burnFrom` and no privileged burn.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ──────────────────────────── EIP-2612 ────────────────────────────

    /// @notice EIP-712 domain separator for `permit`.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    /// @notice Sets `spender`'s allowance over `owner`'s tokens to `value` using `owner`'s signature.
    /// @dev Rejects expired deadlines, high-`s` (malleable) signatures, invalid `v`, the zero
    /// recovered address, and signatures by anyone but `owner`. Each successful call consumes
    /// `nonces[owner]`, so a signature can be used once.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert PermitExpired(deadline, block.timestamp);

        bytes32 structHash;
        unchecked {
            structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline));
        }
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        address recovered = address(0);
        if (uint256(s) <= _HALF_ORDER && (v == 27 || v == 28)) {
            recovered = ecrecover(digest, v, r, s);
        }
        if (recovered == address(0) || recovered != owner) revert InvalidSigner(recovered, owner);

        _approve(owner, spender, value);
    }

    /// @notice EIP-5267: describes the EIP-712 domain used by `permit`.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory domainName,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", NAME, "1", block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    // ──────────────────────────── Internals ───────────────────────────

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // fromBalance >= amount, and the sum of all balances is bounded by _totalSupply.
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) private {
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            _balances[from] = fromBalance - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(owner, spender, current, amount);
        unchecked {
            _allowances[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }
}
