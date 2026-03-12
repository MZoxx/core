#!/bin/bash
#
# test_qracel.sh — qRacel CLI Smoke- und Transaktionstests
# =========================================================
#
# Unterstützte Modi:
#   ./test_qracel.sh --smoke
#   ./test_qracel.sh --create
#   ./test_qracel.sh --bet
#   ./test_qracel.sh --claim
#   ./test_qracel.sh --full
#
# Hinweise:
# - Dieses Skript testet die qRacel CLI-Kommandos gegen einen laufenden Node.
# - Standardmäßig wird der qRacel-Contract-Index automatisch erkannt (18/15/25).
#   Bei Bedarf kann CONTRACT_INDEX explizit gesetzt werden.
# - Der Claim-Flow ist nicht vollautomatisch, da ein Round zuerst RESOLVED sein muss.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

NODE_IP="${NODE_IP:-135.181.160.185}"
NODE_PORT="${NODE_PORT:-31841}"
CONTRACT_INDEX="${CONTRACT_INDEX:-}"
SCHEDULE_TICK="${SCHEDULE_TICK:-3}"

DURATION="${DURATION:-10m}"
SIDE="${SIDE:-up}"
CREATE_AMOUNT="${CREATE_AMOUNT:-10000000}"
BET_AMOUNT="${BET_AMOUNT:-2000000}"
READ_WAIT_SEC="${READ_WAIT_SEC:-8}"
TX_WAIT_SEC="${TX_WAIT_SEC:-12}"

ROUND_ID="${ROUND_ID:-}"
BET_ID="${BET_ID:-}"

# Seeds mit Testnet-Funds
ADMIN_SEED="${ADMIN_SEED:-gtfgjhtoxcddbxrydatevcmildkmqeiezwgztpwseihqhqxmoamxfak}"
BETTER_SEED="${BETTER_SEED:-ytcltfdvfjvskmarrjxloxkjrwtbjbepzjphowjfszldyjscrmztmor}"
BETTER_SEED_2="${BETTER_SEED_2:-ahbpfnqltlotcyyaljwjouoheepykysdsokuazxlwecrwkuesxhahrx}"

CLI="${CLI:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

step() {
    echo -e "  ${CYAN}▶ $1${NC}"
}

info() {
    echo -e "    ${YELLOW}$1${NC}"
}

ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

warn() {
    echo -e "  ${YELLOW}!${NC} $1"
}

fail() {
    echo -e "  ${RED}✗${NC} $1" >&2
    exit 1
}

usage() {
    cat <<EOF
Nutzung:
  ./test_qracel.sh --smoke
  ./test_qracel.sh --create
  ./test_qracel.sh --bet
  ./test_qracel.sh --claim
  ./test_qracel.sh --full

Wichtige ENV-Variablen:
  NODE_IP=127.0.0.1
  NODE_PORT=31841
    CONTRACT_INDEX=18|15|25
  ADMIN_SEED=<seed>
  BETTER_SEED=<seed>
  DURATION=10m|60m|6h|24h
  SIDE=up|down
  CREATE_AMOUNT=10000000
  BET_AMOUNT=2000000
  ROUND_ID=<id>
  BET_ID=<id>
  CLI=/pfad/zur/qubic-cli

Beispiele:
  ./test_qracel.sh --smoke
    CONTRACT_INDEX=18 ./test_qracel.sh --create
    CONTRACT_INDEX=18 ROUND_ID=1 ./test_qracel.sh --bet
    CONTRACT_INDEX=18 BET_ID=0 ./test_qracel.sh --claim
    CONTRACT_INDEX=18 DURATION=10m SIDE=up ./test_qracel.sh --full
EOF
}

resolve_cli() {
    local candidates=()

    if [[ -n "$CLI" ]]; then
        candidates+=("$CLI")
    fi

    candidates+=(
        "$SCRIPT_DIR/qubic-cli/build-macos-aarch64/qubic-cli"
        "$SCRIPT_DIR/qubic-cli/build/qubic-cli"
        "$SCRIPT_DIR/qubic-cli/build-macos/qubic-cli"
        "$SCRIPT_DIR/../qubic-cli/build-macos-aarch64/qubic-cli"
        "$SCRIPT_DIR/../qubic-cli/build/qubic-cli"
        "$SCRIPT_DIR/../qubic-cli/build-macos/qubic-cli"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            CLI="$candidate"
            return 0
        fi
    done

    fail "Keine ausführbare qubic-cli gefunden. Setze CLI=/pfad/zur/qubic-cli"
}

ensure_qracel_cli_support() {
    local help_output
    help_output=$("$CLI" -help 2>&1)

    if ! echo "$help_output" | grep -qi 'QRACEL COMMANDS'; then
        fail "Die gewählte qubic-cli unterstützt keine qRacel-Kommandos: $CLI"
    fi
}

validate_qracel_response() {
    local action="$1"
    local output="$2"

    if echo "$output" | grep -q 'Unexpected command!'; then
        fail "${action} schlug fehl: qubic-cli kennt das qRacel-Kommando nicht"
    fi

    if echo "$output" | grep -q 'Received incomplete data'; then
        fail "${action} schlug fehl: Node-Rueckgabe passt nicht zum erwarteten qRacel-Format. Wahrscheinlich ist qRacel auf CONTRACT_INDEX=${CONTRACT_INDEX} nicht registriert"
    fi

    if echo "$output" | grep -q 'Failed to query qRacel'; then
        fail "${action} schlug fehl: qRacel-Abfrage wurde vom Node nicht erfolgreich beantwortet"
    fi
}

looks_like_qracel_config() {
    local output="$1"

    if echo "$output" | grep -q 'Unexpected command!\|Received incomplete data\|Failed to query qRacel'; then
        return 1
    fi

    echo "$output" | grep -q 'Next round id:'
}

autodetect_contract_index() {
    if [[ -n "$CONTRACT_INDEX" ]]; then
        return 0
    fi

    local candidates=(18 15 25)
    local idx
    local output

    for idx in "${candidates[@]}"; do
        output=$(cli_call -qracelgetconfig "$idx")
        if looks_like_qracel_config "$output"; then
            CONTRACT_INDEX="$idx"
            info "qRacel Contract Index automatisch erkannt: ${CONTRACT_INDEX}"
            return 0
        fi
    done

    fail "qRacel Contract-Index konnte nicht automatisch erkannt werden (getestet: 18, 15, 25). Ist qRacel auf dem Node schon registriert und deployed?"
}

cli_call() {
    "$CLI" -nodeip "$NODE_IP" -nodeport "$NODE_PORT" "$@" 2>&1
}

cli_call_seed() {
    local seed="$1"
    shift
    "$CLI" -nodeip "$NODE_IP" -nodeport "$NODE_PORT" -seed "$seed" -scheduletick "$SCHEDULE_TICK" "$@" 2>&1
}

extract_tx() {
    local output="$1"
    TX_HASH=$(echo "$output" | grep 'TxHash:' | awk '{print $2}' | head -1)
    TX_TICK=$(echo "$output" | grep -oE 'Tick:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
}

wait_and_check_tx() {
    local tick="$1"
    local tx_hash="$2"
    local attempt=0
    local result

    while [[ "$attempt" -lt 10 ]]; do
        attempt=$((attempt + 1))
        sleep "$TX_WAIT_SEC"
        result=$(cli_call -checktxontick "$tick" "$tx_hash")

        if echo "$result" | grep -qi 'Please wait'; then
            info "TX noch nicht final (Versuch ${attempt}/10)"
            continue
        fi

        echo "$result"
        return 0
    done

    echo "$result"
    return 1
}

parse_value() {
    local key="$1"
    local text="$2"
    echo "$text" | awk -F': ' -v key="$key" '$1 == key {print $2; exit}'
}

get_config_output() {
    local output
    output=$(cli_call -qracelgetconfig "$CONTRACT_INDEX")
    validate_qracel_response "Config lesen" "$output"
    echo "$output"
}

show_active_rounds() {
    local duration
    for duration in 10m 60m 6h 24h; do
        step "Lese aktiven Round für ${duration}"
        local output
        output=$(cli_call -qracelgetactiveround "$CONTRACT_INDEX" "$duration")
        validate_qracel_response "ActiveRound ${duration} lesen" "$output"
        echo "$output"
    done
}

smoke_test() {
    header "qRacel Smoke Test"
    step "Lese qRacel Config"
    local cfg
    if ! cfg=$(get_config_output); then
        exit 1
    fi
    echo "$cfg"

    step "Lese aktive Rounds"
    show_active_rounds

    if [[ -n "$ROUND_ID" ]]; then
        step "Lese Round ${ROUND_ID}"
        cli_call -qracelgetround "$CONTRACT_INDEX" "$ROUND_ID"
    fi

    if [[ -n "$BET_ID" ]]; then
        step "Lese Bet ${BET_ID}"
        cli_call -qracelgetbet "$CONTRACT_INDEX" "$BET_ID"
    fi
}

create_round() {
    header "qRacel Create Round"
    step "Sende CreateRound (${DURATION}, Amount=${CREATE_AMOUNT})"
    local output
    output=$(cli_call_seed "$ADMIN_SEED" -qracelcreateround "$CONTRACT_INDEX" "$DURATION" "$CREATE_AMOUNT")
    validate_qracel_response "CreateRound" "$output"
    echo "$output"
    extract_tx "$output"

    if [[ -n "${TX_HASH:-}" && -n "${TX_TICK:-}" ]]; then
        step "Warte auf TX-Bestätigung"
        wait_and_check_tx "$TX_TICK" "$TX_HASH"
    else
        warn "Konnte TxHash/Tick nicht aus CreateRound extrahieren"
    fi
}

place_bet() {
    header "qRacel Place Bet"
    [[ -n "$ROUND_ID" ]] || fail "ROUND_ID ist für --bet erforderlich"

    step "Sende PlaceBet (Round=${ROUND_ID}, Side=${SIDE}, Amount=${BET_AMOUNT})"
    local output
    output=$(cli_call_seed "$BETTER_SEED" -qracelbet "$CONTRACT_INDEX" "$ROUND_ID" "$SIDE" "$BET_AMOUNT")
    validate_qracel_response "PlaceBet" "$output"
    echo "$output"
    extract_tx "$output"

    if [[ -n "${TX_HASH:-}" && -n "${TX_TICK:-}" ]]; then
        step "Warte auf TX-Bestätigung"
        wait_and_check_tx "$TX_TICK" "$TX_HASH"
    else
        warn "Konnte TxHash/Tick nicht aus PlaceBet extrahieren"
    fi
}

claim_bet() {
    header "qRacel Claim"
    [[ -n "$BET_ID" ]] || fail "BET_ID ist für --claim erforderlich"

    step "Sende Claim für Bet ${BET_ID}"
    local output
    output=$(cli_call_seed "$BETTER_SEED" -qracelclaim "$CONTRACT_INDEX" "$BET_ID")
    validate_qracel_response "Claim" "$output"
    echo "$output"
    extract_tx "$output"

    if [[ -n "${TX_HASH:-}" && -n "${TX_TICK:-}" ]]; then
        step "Warte auf TX-Bestätigung"
        wait_and_check_tx "$TX_TICK" "$TX_HASH"
    else
        warn "Konnte TxHash/Tick nicht aus Claim extrahieren"
    fi
}

full_flow() {
    header "qRacel Full Flow"

    step "Lese Config vor CreateRound"
    local cfg_before
    if ! cfg_before=$(get_config_output); then
        exit 1
    fi
    echo "$cfg_before"

    local next_round_id
    local bet_count_before
    next_round_id=$(parse_value "Next round id" "$cfg_before")
    bet_count_before=$(parse_value "Bet count" "$cfg_before")
    next_round_id=${next_round_id:-0}
    bet_count_before=${bet_count_before:-0}

    [[ "$next_round_id" =~ ^[0-9]+$ ]] || fail "Konnte Next round id nicht aus qRacel Config lesen"
    [[ "$bet_count_before" =~ ^[0-9]+$ ]] || fail "Konnte Bet count nicht aus qRacel Config lesen"

    create_round

    ROUND_ID=$((next_round_id + 1))
    info "Erwartete neue Round ID: ${ROUND_ID}"
    sleep "$READ_WAIT_SEC"

    step "Prüfe aktive Round für ${DURATION}"
    local active_output
    active_output=$(cli_call -qracelgetactiveround "$CONTRACT_INDEX" "$DURATION")
    validate_qracel_response "ActiveRound nach CreateRound lesen" "$active_output"
    echo "$active_output"

    step "Lese neu erstellte Round ${ROUND_ID}"
    local round_output
    round_output=$(cli_call -qracelgetround "$CONTRACT_INDEX" "$ROUND_ID")
    validate_qracel_response "Round lesen" "$round_output"
    echo "$round_output"

    place_bet

    BET_ID="$bet_count_before"
    info "Erwartete neue Bet ID: ${BET_ID}"
    sleep "$READ_WAIT_SEC"

    step "Lese neu erstellte Bet ${BET_ID}"
    local bet_output
    bet_output=$(cli_call -qracelgetbet "$CONTRACT_INDEX" "$BET_ID")
    validate_qracel_response "Bet lesen" "$bet_output"
    echo "$bet_output"

    echo ""
    ok "CreateRound und PlaceBet wurden gesendet"
    info "Für den späteren Claim kannst du ausführen:"
    echo "BET_ID=${BET_ID} CONTRACT_INDEX=${CONTRACT_INDEX} ./test_qracel.sh --claim"
}

main() {
    local mode="${1:---smoke}"

    case "$mode" in
        -h|--help)
            usage
            exit 0
            ;;
    esac

    resolve_cli
    ensure_qracel_cli_support
    autodetect_contract_index

    header "qRacel Test Konfiguration"
    info "CLI: ${CLI}"
    info "Node: ${NODE_IP}:${NODE_PORT}"
    info "Contract Index: ${CONTRACT_INDEX}"
    info "Duration: ${DURATION} | Side: ${SIDE}"

    case "$mode" in
        --smoke)
            smoke_test
            ;;
        --create)
            create_round
            ;;
        --bet)
            place_bet
            ;;
        --claim)
            claim_bet
            ;;
        --full)
            full_flow
            ;;
        *)
            usage
            fail "Unbekannter Modus: ${mode}"
            ;;
    esac
}

main "$@"