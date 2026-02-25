#!/usr/bin/env bash
# ============================================================
# ATMOS Protocol — End-to-End Workflow Simulation
# Simulates: Lock → Delegate → Vote → Futarchy → Agent Transact → Claim Rewards
#
# Prerequisites:
#   - sui CLI installed (https://docs.sui.io/build/install)
#   - Active Sui wallet (sui client addresses)
#   - Funded wallet on testnet (sui client faucet)
#   - Protocol already published (run deploy.sh first)
#
# Usage:
#   chmod +x scripts/e2e_workflow.sh
#   ./scripts/e2e_workflow.sh
# ============================================================

set -euo pipefail

# ─── Load config ──────────────────────────────────────────────────────────────
source "$(dirname "$0")/config.env" 2>/dev/null || {
    echo "⚠️  config.env not found. Copy config.env.example and fill in values."
    exit 1
}

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
step()    { echo -e "\n${BOLD}${GREEN}━━━ STEP $1 ━━━${NC}"; }

check_env() {
    local missing=()
    for var in TREASURY_ID GOVERNANCE_ID REWARD_POOL_ID PACKAGE_ID ADMIN_ADDR ALICE_ADDR BOB_ADDR; do
        [[ -z "${!var:-}" ]] && missing+=("$var")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}ERROR: Missing env vars: ${missing[*]}${NC}"
        exit 1
    fi
}

# ─── Constants ────────────────────────────────────────────────────────────────
ONE_WEEK_MS=$((7 * 24 * 60 * 60 * 1000))
ONE_YEAR_MS=$((365 * 24 * 60 * 60 * 1000))
MINT_AMOUNT=1000000000       # 1000 ATMOS
LOCK_AMOUNT=500000000        # 500 ATMOS
BET_AMOUNT=100000000         # 100 ATMOS
AGENT_TX_AMOUNT=50000000     # 50 ATMOS
DAILY_LIMIT=1000000000       # 1000 ATMOS

# ─── Main workflow ────────────────────────────────────────────────────────────

echo -e "${BOLD}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      ATMOS Protocol E2E Workflow              ║${NC}"
echo -e "${BOLD}║  Lock → Delegate → Vote → Bet → Agent → Claim ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════╝${NC}"

check_env

# ─── STEP 1: Admin mints ATMOS to Alice and Bob ───────────────────────────────
step "1: Admin mints ATMOS"
info "Minting ${MINT_AMOUNT} ATMOS to Alice (${ALICE_ADDR})..."
TX1=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  token \
    --function admin_mint \
    --args    "$TREASURY_ID" "$MINT_AMOUNT" "$ALICE_ADDR" \
    --gas-budget 10000000 \
    --json | jq -r '.digest')
success "Mint tx (Alice): ${TX1}"

info "Minting ${MINT_AMOUNT} ATMOS to Bob (${BOB_ADDR})..."
TX2=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  token \
    --function admin_mint \
    --args    "$TREASURY_ID" "$MINT_AMOUNT" "$BOB_ADDR" \
    --gas-budget 10000000 \
    --json | jq -r '.digest')
success "Mint tx (Bob): ${TX2}"

# ─── STEP 2: Alice creates reward account ─────────────────────────────────────
step "2: Alice creates reward account"
sui client switch --address "$ALICE_ADDR"
TX3=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  rewards \
    --function create_account \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Reward account created: ${TX3}"

ALICE_REWARD_ACC=$(sui client objects --address "$ALICE_ADDR" --json \
    | jq -r '.[] | select(.type | contains("RewardAccount")) | .objectId' | head -1)
info "Alice reward account: ${ALICE_REWARD_ACC}"

# ─── STEP 3: Alice locks ATMOS for veATMOS ───────────────────────────────────
step "3: Alice locks ATMOS → veATMOS"
ALICE_COIN=$(sui client objects --address "$ALICE_ADDR" --json \
    | jq -r --arg pkg "$PACKAGE_ID" \
    '.[] | select(.type | contains("Coin<\($pkg)::token::ATMOS>")) | .objectId' | head -1)

info "Locking ${LOCK_AMOUNT} ATMOS for 1 year..."
TX4=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  locking \
    --function lock \
    --args    "$TREASURY_ID" "$ALICE_COIN" "$ONE_YEAR_MS" "0x6" \
    --gas-budget 10000000 \
    --json | jq -r '.digest')
success "Lock created: ${TX4}"

ALICE_VE=$(sui client objects --address "$ALICE_ADDR" --json \
    | jq -r '.[] | select(.type | contains("VeLock")) | .objectId' | head -1)
info "Alice veATMOS (VeLock): ${ALICE_VE}"

# ─── STEP 4: Alice delegates 30% voting power to Bob ─────────────────────────
step "4: Alice delegates 30% VP to Bob"
TX5=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  delegation \
    --function delegate \
    --args    "$ALICE_VE" "$BOB_ADDR" 3000 200 \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Delegation created: ${TX5}"

# ─── STEP 5: Alice creates a governance proposal ──────────────────────────────
step "5: Alice creates governance proposal"
PROP_TITLE=$(echo -n "Increase Max Agent Daily Limit" | xxd -p | tr -d '\n')
PROP_DESC=$(echo -n "Proposal to raise agent daily limit to 10000 ATMOS for power users" | xxd -p | tr -d '\n')

TX6=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  voting \
    --function create_proposal \
    --args    "$GOVERNANCE_ID" "$ALICE_VE" \
              "0x${PROP_TITLE}" "0x${PROP_DESC}" \
              '{"None":null}' "$ONE_WEEK_MS" "0x6" \
    --gas-budget 10000000 \
    --json | jq -r '.digest')
success "Proposal created: ${TX6}"

PROPOSAL_ID=$(sui client objects --json \
    | jq -r '.[] | select(.type | contains("Proposal")) | .objectId' | head -1)
info "Proposal ID: ${PROPOSAL_ID}"

# ─── STEP 6: Alice votes YES on proposal ─────────────────────────────────────
step "6: Alice votes YES"
TX7=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  voting \
    --function vote \
    --args    "$PROPOSAL_ID" "$ALICE_VE" true "0x6" \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Vote cast: ${TX7}"

# ─── STEP 7: Bob bets YES on the futarchy market ──────────────────────────────
step "7: Create futarchy market + Bob bets YES"
sui client switch --address "$ADMIN_ADDR"
MARKET_DURATION=$ONE_WEEK_MS

TX8=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  futarchy \
    --function create_market \
    --args    "$PROPOSAL_ID" "$ADMIN_ADDR" "$MARKET_DURATION" "0x6" \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Market created: ${TX8}"

MARKET_ID=$(sui client objects --json \
    | jq -r '.[] | select(.type | contains("Market")) | .objectId' | head -1)
info "Market ID: ${MARKET_ID}"

sui client switch --address "$BOB_ADDR"
BOB_COIN=$(sui client objects --address "$BOB_ADDR" --json \
    | jq -r --arg pkg "$PACKAGE_ID" \
    '.[] | select(.type | contains("Coin<\($pkg)::token::ATMOS>")) | .objectId' | head -1)

TX9=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  futarchy \
    --function bet \
    --args    "$MARKET_ID" "$BOB_COIN" true "0x6" \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Bob bet YES: ${TX9}"

# ─── STEP 8: Alice creates and runs agent (onramp) ───────────────────────────
step "8: Alice creates AtmosPay agent & executes onramp"
sui client switch --address "$ALICE_ADDR"

TX10=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  atmospay \
    --function create_agent \
    --args    "$DAILY_LIMIT" "0x6" \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Agent created: ${TX10}"

AGENT_ID=$(sui client objects --address "$ALICE_ADDR" --json \
    | jq -r '.[] | select(.type | contains("Agent")) | .objectId' | head -1)
AGENT_CAP=$(sui client objects --address "$ALICE_ADDR" --json \
    | jq -r '.[] | select(.type | contains("AgentCap")) | .objectId' | head -1)
info "Agent: ${AGENT_ID} | Cap: ${AGENT_CAP}"

ACTION_ONRAMP=$(echo -n "onramp" | xxd -p | tr -d '\n')

TX11=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  atmospay \
    --function transact \
    --args    "$AGENT_ID" "$AGENT_CAP" "$TREASURY_ID" "$GOVERNANCE_ID" \
              "$ALICE_REWARD_ACC" "$BOB_ADDR" "$AGENT_TX_AMOUNT" \
              "0x${ACTION_ONRAMP}" "0x6" \
    --gas-budget 10000000 \
    --json | jq -r '.digest')
success "Agent onramp tx: ${TX11}"

# ─── STEP 9: Advance epoch + accrue rewards ───────────────────────────────────
step "9: Admin advances reward epoch"
warn "In production, wait for clock to advance. On testnet, use devInspect to simulate."
sui client switch --address "$ADMIN_ADDR"

TX12=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  rewards \
    --function advance_epoch \
    --args    "$REWARD_POOL_ID" 1000000 "0x6" \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Epoch advanced: ${TX12}"

# ─── STEP 10: Alice accrues + claims rewards ─────────────────────────────────
step "10: Alice accrues & claims rewards"
sui client switch --address "$ALICE_ADDR"

TX13=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  rewards \
    --function accrue \
    --args    "$REWARD_POOL_ID" "$ALICE_REWARD_ACC" "$ALICE_VE" "0x6" \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Rewards accrued: ${TX13}"

TX14=$(sui client call \
    --package "$PACKAGE_ID" \
    --module  rewards \
    --function claim \
    --args    "$REWARD_POOL_ID" "$ALICE_REWARD_ACC" "$TREASURY_ID" \
    --gas-budget 5000000 \
    --json | jq -r '.digest')
success "Rewards claimed: ${TX14}"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     E2E Workflow Complete ✅           ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════╝${NC}"
echo ""
echo -e "  Mint (Alice):      ${TX1}"
echo -e "  Mint (Bob):        ${TX2}"
echo -e "  Reward Account:    ${TX3}"
echo -e "  Lock:              ${TX4}"
echo -e "  Delegate:          ${TX5}"
echo -e "  Proposal:          ${TX6}"
echo -e "  Vote:              ${TX7}"
echo -e "  Market:            ${TX8}"
echo -e "  Bet:               ${TX9}"
echo -e "  Agent Created:     ${TX10}"
echo -e "  Agent Onramp:      ${TX11}"
echo -e "  Epoch Advanced:    ${TX12}"
echo -e "  Rewards Accrued:   ${TX13}"
echo -e "  Rewards Claimed:   ${TX14}"
echo ""
info "Verify on explorer: https://suiexplorer.com/txblock/<TX_DIGEST>?network=testnet"
