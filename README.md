# MyrmexSI (MYRM)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Property | Value |
| --- | --- |
| Solidity contract | `MyrmexToken` (`src/MyrmexToken.sol`) |
| `name()` | `MyrmexSI` |
| `symbol()` | `MYRM` |
| `decimals()` | `18` |
| Total supply | `1_000_000_000 * 10**18` = `1000000000000000000000000000` minor units |
| Minted to | `msg.sender` of the constructor (the launch factory), once, in the constructor |
| Constructor arguments | none |
| Owner / admin | none: there is no privileged role at all |
| Can supply grow? | no: there is no mint path after the constructor |
| Can supply shrink? | yes: a holder may `burn` its own balance only |
| Compiler | solc `0.8.26`, optimizer on (200 runs), `bytecode_hash = "none"`, EVM `cancun` |

## Behaviour

The token is a self-contained implementation of EIP-20 plus EIP-2612 `permit` and EIP-5267
`eip712Domain`. It imports nothing, calls no other contract, uses no library and no proxy, so its
creation code deploys unlinked on an empty chain and its runtime contains no `DELEGATECALL`,
`CALLCODE` or `SELFDESTRUCT` (a test scans the bytecode for them).

- `transfer` / `transferFrom` move exactly the amount requested. There is no fee, tax, burn, reflection,
  hook, cooldown, max-wallet or max-transaction rule. Transfers to or from the zero address revert.
- `approve` overwrites the allowance (plain EIP-20 semantics). `transferFrom` decreases the allowance,
  except an allowance of `type(uint256).max`, which is treated as unlimited and left untouched.
- `burn(amount)` destroys the caller's own tokens and reduces `totalSupply`. There is no `burnFrom`
  and nobody can burn another holder's tokens.
- `permit` sets an allowance from an EIP-712 signature. It rejects expired deadlines, signatures with a
  high `s` (malleable), `v` outside 27/28, the zero recovered address and signatures by anyone but the
  owner. Each use consumes the owner's nonce, so a signature works once. The domain separator is
  cached for the deployment chain id and recomputed if the chain id changes (a fork), so permits
  signed on one fork do not replay on the other.
- Nothing is pausable, blocklistable, freezable, seizable, upgradeable or ownable. The launch floor's
  list of privileged selectors (`mint`, `pause`, `blacklist`, `freeze`, `setOwner`, `upgradeTo`,
  `burnFrom`, ...) all revert with no effect because none of them exist.

Custom errors: `ZeroAddress`, `InsufficientBalance(from, balance, needed)`,
`InsufficientAllowance(owner, spender, allowance, needed)`, `PermitExpired(deadline, blockTimestamp)`,
`InvalidSigner(recovered, owner)`.

## Launch flows

The launch factory deploys `MyrmexToken` and receives the whole supply in the constructor. It then
transfers the swarm's 10% to the launch's MerkleDistributor, seeds the Uniswap v4 pool through the
PoolManager with 80% of the supply (`economics.poolBps = 8000`), and forwards the remaining 10% to
`economics.remainderTo` (`0xff3e8d9ba776662ca6ed1420ee366afb436d2684`). Because the token has no
transfer rules, every one of these flows moves exactly what it says, the distributor pays claims
whole, and any trader can buy from and sell into the PoolManager. The token needs no exemptions and
therefore takes no `$factory`, `$poolManager` or `$launchNumber` constructor argument.

Pool parameters are the launch's, not the token's: paired currency IMD
(`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee 12500 (1.25%), tick spacing 60, opening price
derived by the deployer from `economics.initialMarketCapWei` (2,500 IMD for the whole supply). The
token does not care which currency sorts first.

## Assumptions

- "The deployer" in the brief is the constructor's `msg.sender`, which at launch is the factory.
  The token never reads `tx.origin` and takes no owner argument, because it has no owner.
- The brief asked for no transfer rules, so none were added. Permit and self-burn are standard
  conveniences that do not alter any launch flow; if the requester does not want them, deleting
  `burn`, `permit`, `nonces`, `DOMAIN_SEPARATOR` and `eip712Domain` leaves a pure EIP-20 token.
- No number was left open by the brief. The only constants are the name, symbol, decimals and
  supply, all fixed in the contract.

## Deployment parameters

| Manifest field | Value |
| --- | --- |
| `token.contract` | `MyrmexToken` |
| `token.name` | `MyrmexSI` |
| `token.symbol` | `MYRM` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `contracts` | `[]` (no application contracts) |

The manifest (`launch.json`) is written by the manifest step after acceptance, not by this
repository. The creation code is deterministic: `bytecode_hash = "none"` and `cbor_metadata = false`
are set in `foundry.toml`, so a rebuild with solc 0.8.26 and the pinned optimizer settings reproduces
the deployed bytes exactly.

## After launch

Nothing to configure. The token has no owner-settable value, no setter and no post-deployment
initialization. There is no key to hold, rotate or hand to a multisig, because no key has power over
the contract.

## Operational responsibilities

- The requester's share arrives at `economics.remainderTo`. Whoever controls that wallet is
  responsible for its custody; the contract cannot recover tokens sent to a wrong address, to the
  token contract itself, or burned.
- Holders who use `permit` must guard their signatures like transactions: a valid, unexpired permit
  can be submitted by anyone (relayers are intended) and grants exactly the allowance signed.
- Unlimited allowances (`type(uint256).max`) are never decreased; holders granting them to a contract
  trust that contract fully.
- Explorer source verification after the launch is the network deployer's task
  (`forge verify-contract` with compiler `0.8.26`, optimizer `200` runs, `bytecode_hash = none`,
  `cbor_metadata = false`, EVM version `cancun`). This repository does not deploy, broadcast or hold
  keys.

## Security review

Checked against the eth-security reference supplied with the task:

- Reentrancy: the token makes no external calls, so there is no reentrancy surface.
- Access control: there are no privileged functions, so nothing to misconfigure.
- Integer safety: Solidity 0.8 checked arithmetic; the `unchecked` blocks only run after an explicit
  bound check (`balance >= amount`, `allowance >= amount`) or on a value already shown to be in range.
- Signature safety: low-`s` and `v in {27,28}` enforced, zero recovered address rejected, nonce
  consumed per use, deadline checked, chain-id-aware domain separator.
- Upgradeability / destruction: none; the runtime is scanned for `DELEGATECALL`, `CALLCODE` and
  `SELFDESTRUCT`.
- Supply: fixed at construction, tests assert no common admin selector can raise it.
- Tooling run: `forge build`, `forge test` (43 tests, incl. fuzz with the verifier's seed),
  `forge fmt --check`, forge's built-in lint. Slither and Mythril were not available in this
  environment and did not run. Tests passing are not an audit; a separate adversarial review by an
  independent contributor is still appropriate before relying on the token for anything beyond the
  launch flows described above.

## Repository layout

```
foundry.toml          compiler pins (solc 0.8.26, bytecode_hash none), no ffi, no fs permissions
remappings.txt        forge-std/ -> lib/forge-std/src/
src/MyrmexToken.sol   the token
test/MyrmexToken.t.sol  success and failure tests, fuzz tests
lib/forge-std/        forge-std v1.14.0 vendored as ordinary files (MIT / Apache-2.0)
```

## Running the checks

```
forge build
forge test
forge fmt --check
```
