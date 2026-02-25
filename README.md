# Atmosphere - Contracts

## Atmos Protocol

> Atmosphere governance + autonomous agent payment stack on Sui Move.

---

## Architecture

```
sources/
├── token.move         Core ATMOS token + treasury (mint, burn, split)
├── governance.move    Protocol parameters (quorum, burn rate, fees)
├── locking.move       veATMOS: time-locked positions with decay
├── delegation.move    Partial VP delegation with configurable fees
├── voting.move        Quadratic voting + KPI-linked proposals
├── futarchy.move      Prediction market layer for proposal outcomes
├── rewards.move       Epoch-based reward accrual & claiming
└── atmospay.move      AtmosPay Agents: autonomous tx engine

tests/
└── atmos_tests.move   25 comprehensive test cases

scripts/
├── deploy.sh          Build → Test → Publish to any Sui network
├── e2e_workflow.sh    Full lifecycle simulation via CLI
└── config.env.example Deployment config template
```

---

## Quick Start

### 1. Install Sui CLI
```bash
cargo install --locked --git https://github.com/MystenLabs/sui.git \
  --branch testnet sui
```

### 2. Set up wallet
```bash
sui client new-address ed25519
sui client switch --env testnet
# Fund via: https://faucet.testnet.sui.io
```

### 3. Build & Test
```bash
sui move build
sui move test
# Expected: 25/25 tests PASS
```

### 4. Deploy
```bash
chmod +x scripts/deploy.sh scripts/e2e_workflow.sh
./scripts/deploy.sh --testnet
```

### 5. Run E2E Simulation
```bash
# Fill in Alice/Bob addresses in scripts/config.env
./scripts/e2e_workflow.sh
```

---

## Module Overview

### `token.move` — ATMOS Token
- 1 billion supply cap (6 decimals)
- `admin_mint` / `user_burn` / `split_coin`
- Friend-gated mint/burn for protocol use only

### `locking.move` — veATMOS
- Lock ATMOS for 7 days – 2 years
- Linear voting power decay
- Early unlock: 30% penalty burned
- `extend_lock`, `increase_lock`, `merge_locks`

### `delegation.move` — Partial Delegation
- Delegate any % of voting power (basis points)
- Configurable fee for delegates (max 20%)
- `DelegationReceipt` held by delegate proves delegated power

### `voting.move` — Quadratic Voting
- Proposals with optional KPI targets
- Effective power = √(raw_veATMOS_power) — resists whale dominance
- Execute after voting window closes

### `futarchy.move` — Prediction Markets
- YES/NO pools per proposal
- Resolver calls `resolve(yes_won)` after market ends
- Winners claim proportional share of loser pool

### `rewards.move` — Epoch Rewards
- Weekly epochs; 10% of pool distributed per epoch
- Rewards proportional to veATMOS voting power
- AtmosPay agent activity earns additional reward bonus

### `atmospay.move` — Autonomous Agents
- Per-agent daily spend limits
- 1-minute cooldown between transactions
- Actions: `onramp`, `offramp`, `swap`, `trade`
- Burn fee applied per tx (governance-configured)
- 0.1% of each tx accrues as reward to agent owner
- `AgentCap` capability pattern for secure authorization

---

## Test Coverage (25 cases)

| # | Test | Module |
|---|------|--------|
| 1 | Treasury initializes correctly | token |
| 2 | Admin mint to recipient | token |
| 3 | User burn own tokens | token |
| 4 | Mint exceeds cap → fail | token |
| 5 | Lock creates veATMOS with VP | locking |
| 6 | VP decays over time | locking |
| 7 | Early unlock 30% penalty | locking |
| 8 | Normal unlock full return | locking |
| 9 | Extend lock increases unlock time | locking |
| 10 | Merge two locks | locking |
| 11 | Delegate voting power | delegation |
| 12 | Create and vote on proposal | voting |
| 13 | Execute proposal after window | voting |
| 14 | Double vote rejected | voting |
| 15 | Place futarchy bets | futarchy |
| 16 | Resolve market + claim winnings | futarchy |
| 17 | Create reward account + deposit | rewards |
| 18 | Accrue and claim rewards | rewards |
| 19 | Update governance params | governance |
| 20 | Non-admin param update fails | governance |
| 21 | Create agent with daily limit | atmospay |
| 22 | Agent executes onramp | atmospay |
| 23 | Inactive agent blocked | atmospay |
| 24 | Daily limit enforced | atmospay |
| 25 | Cooldown between txs enforced | atmospay |

---

## Security Notes

- All state-changing functions check caller ownership
- Treasury mint/burn gated to `friend` modules only
- Agent `AgentCap` prevents unauthorized tx execution
- Governance params capped (burn ≤ 10%, delegation fee ≤ 20%)
- Early unlock penalty destroyed (burned), not redirected

---

## License

MIT — see [LICENSE](LICENSE)

### 2026 Atmos Protocol
