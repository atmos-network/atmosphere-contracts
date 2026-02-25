#!/usr/bin/env bash
# ============================================================
# ATMOS Protocol — Build, Test & Deploy Script
# Targets Sui Testnet. Adjust RPC_URL for mainnet.
#
# Usage:
#   chmod +x scripts/deploy.sh
#   ./scripts/deploy.sh [--testnet|--mainnet|--localnet]
# ============================================================

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $1 ━━━${NC}"; }

# ─── Network selection ────────────────────────────────────────────────────────
NETWORK="${1:---testnet}"
case "$NETWORK" in
    --testnet)
        ENV="testnet"
        RPC_URL="https://fullnode.testnet.sui.io:443"
        FAUCET_URL="https://faucet.testnet.sui.io/gas"
        ;;
    --mainnet)
        ENV="mainnet"
        RPC_URL="https://fullnode.mainnet.sui.io:443"
        FAUCET_URL=""
        warn "Deploying to MAINNET. This is irreversible."
        read -p "Continue? (y/N): " confirm
        [[ "$confirm" == "y" ]] || exit 0
        ;;
    --localnet)
        ENV="localnet"
        RPC_URL="http://127.0.0.1:9000"
        FAUCET_URL="http://127.0.0.1:9123/gas"
        ;;
    *)
        error "Unknown network: $NETWORK. Use --testnet, --mainnet, or --localnet"
        ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${PROJECT_ROOT}/scripts/config.env"

echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       ATMOS Protocol Deploy               ║${NC}"
echo -e "${BOLD}║  Network: ${ENV}                          ${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"

# ─── Prerequisites check ──────────────────────────────────────────────────────
step "Checking prerequisites"
command -v sui  >/dev/null || error "sui CLI not found. Install: https://docs.sui.io/build/install"
command -v jq   >/dev/null || error "jq not found. Install: brew install jq / apt install jq"
success "All prerequisites found"

# ─── Wallet check ─────────────────────────────────────────────────────────────
step "Wallet status"
ACTIVE_ADDR=$(sui client active-address 2>/dev/null || error "No active Sui address. Run: sui client new-address ed25519")
info "Active address: ${ACTIVE_ADDR}"

sui client switch --env "$ENV" 2>/dev/null || {
    warn "Environment ${ENV} not configured. Adding..."
    sui client new-env --alias "$ENV" --rpc "$RPC_URL"
    sui client switch --env "$ENV"
}

GAS_BALANCE=$(sui client gas --json 2>/dev/null | jq '.[0].gasBalance // 0' -r)
info "Gas balance: ${GAS_BALANCE} MIST"

if [[ "${GAS_BALANCE}" == "0" || "${GAS_BALANCE}" == "null" ]]; then
    if [[ -n "${FAUCET_URL}" ]]; then
        warn "Requesting gas from faucet..."
        curl -s -X POST "$FAUCET_URL" \
            -H "Content-Type: application/json" \
            -d "{\"FixedAmountRequest\":{\"recipient\":\"${ACTIVE_ADDR}\"}}" | jq .
        sleep 3
    else
        error "Insufficient gas and no faucet available for ${ENV}. Fund your wallet first."
    fi
fi

# ─── Build ────────────────────────────────────────────────────────────────────
step "Building Move package"
cd "$PROJECT_ROOT"
info "Running: sui move build"
sui move build 2>&1 || error "Build failed. Check compiler errors above."
success "Build successful"

# ─── Test ─────────────────────────────────────────────────────────────────────
step "Running test suite"
info "Running 25 test cases..."
TEST_OUTPUT=$(sui move test 2>&1)
echo "$TEST_OUTPUT"

PASS_COUNT=$(echo "$TEST_OUTPUT" | grep -c "PASS" || true)
FAIL_COUNT=$(echo "$TEST_OUTPUT" | grep -c "FAIL" || true)

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    error "${FAIL_COUNT} test(s) failed. Fix before deploying."
fi
success "All ${PASS_COUNT} tests passed"

# ─── Publish ──────────────────────────────────────────────────────────────────
step "Publishing to ${ENV}"
info "Running: sui client publish"
PUBLISH_OUTPUT=$(sui client publish \
    --gas-budget 500000000 \
    --json 2>&1)

echo "$PUBLISH_OUTPUT" | jq . 2>/dev/null || echo "$PUBLISH_OUTPUT"

# ─── Extract object IDs ───────────────────────────────────────────────────────
step "Extracting deployed object IDs"

PACKAGE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '
    .objectChanges[]
    | select(.type == "published")
    | .packageId' | head -1)

TREASURY_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '
    .objectChanges[]
    | select(.objectType // "" | contains("token::Treasury"))
    | .objectId' | head -1)

GOVERNANCE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '
    .objectChanges[]
    | select(.objectType // "" | contains("governance::GovernanceParams"))
    | .objectId' | head -1)

REWARD_POOL_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '
    .objectChanges[]
    | select(.objectType // "" | contains("rewards::RewardPool"))
    | .objectId' | head -1)

DIGEST=$(echo "$PUBLISH_OUTPUT" | jq -r '.digest // "unknown"')

# ─── Write config ─────────────────────────────────────────────────────────────
step "Writing config.env"
cat > "$OUTPUT_FILE" << ENV
# ATMOS Protocol — Deployment Config
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Network: ${ENV}
# Publish tx: ${DIGEST}

PACKAGE_ID="${PACKAGE_ID}"
TREASURY_ID="${TREASURY_ID}"
GOVERNANCE_ID="${GOVERNANCE_ID}"
REWARD_POOL_ID="${REWARD_POOL_ID}"
ADMIN_ADDR="${ACTIVE_ADDR}"

# Fill in after creating test wallets:
ALICE_ADDR=""
BOB_ADDR=""
ENV

success "Config saved to: ${OUTPUT_FILE}"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         Deployment Successful! 🚀              ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Network:${NC}      ${ENV}"
echo -e "  ${BOLD}Package:${NC}      ${PACKAGE_ID}"
echo -e "  ${BOLD}Treasury:${NC}     ${TREASURY_ID}"
echo -e "  ${BOLD}Governance:${NC}   ${GOVERNANCE_ID}"
echo -e "  ${BOLD}RewardPool:${NC}   ${REWARD_POOL_ID}"
echo -e "  ${BOLD}Publish TX:${NC}   ${DIGEST}"
echo ""

if [[ "$ENV" == "testnet" ]]; then
    echo -e "  ${BOLD}Explorer:${NC}"
    echo -e "  https://suiexplorer.com/object/${PACKAGE_ID}?network=testnet"
fi

echo ""
info "Next: Fill in ALICE_ADDR and BOB_ADDR in scripts/config.env"
info "Then: ./scripts/e2e_workflow.sh"
