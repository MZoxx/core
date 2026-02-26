#!/bin/bash
#
# test_arb.sh — qRWA Dev-Payout Test
# ==================================
# Ziel:
# - Prüfen: Wer QMINE innerhalb einer Epoch reduziert, bekommt NULL Payout.
# - Der Anteil des Reducers geht vollständig an die Dev-Adresse.
#
# Ablauf (vereinfacht):
# 1) Aktuelle Epoch: Dev-Balance Snapshot E0
# 2) Nächste Epoch E1: Seeds kaufen QMINE + bewegen QMINE zwischen A/B + senden 20B Revenue an qRWA
# 3) Nächste Epoch E2: Dev-Balance erneut lesen und mit E0 vergleichen
#
# Nutzung:
#   chmod +x core/test_arb.sh
#   cd core && ./test_arb.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

NODE_IP="135.181.160.185"
NODE_PORT="31841"

CLI="${SCRIPT_DIR}/../qubic-cli/build/qubic-cli"

CONTRACT_INDEX=20
QRWA_IDENTITY="UAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHQEE"

# Test Seeds
SEED_A="gtfgjhtoxcddbxrydatevcmildkmqeiezwgztpwseihqhqxmoamxfak"
SEED_B="ytcltfdvfjvskmarrjxloxkjrwtbjbepzjphowjfszldyjscrmztmor"

# QMINE
QMINE_ISSUER="QMINEQQXYBEGBHNSUPOUYDIQKZPCBPQIIHUUZMCPLBPCCAIARVZBTYKGFCWM"
QMINE_NAME="QMINE"

# Volumen
QMINE_BUDGET_A=${QMINE_BUDGET_A:-100000000000}   # 100B buy budget
QMINE_BUDGET_B=${QMINE_BUDGET_B:-100000000000}   # 100B buy budget
REVENUE_SEND=20000000000     # 20B QU -> qRWA (Pool B input)

SCHEDULE_TICK=3
TX_WAIT_SEC=12

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

step() { echo -e "  ${CYAN}▶ $1${NC}"; }
info() { echo -e "    ${YELLOW}$1${NC}"; }
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "  ${GREEN}✓ PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "  ${RED}✗ FAIL${NC} $1 — $2"; }
header() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

cli_call() {
  "$CLI" -nodeip "$NODE_IP" -nodeport "$NODE_PORT" "$@" 2>&1
}

cli_call_seed() {
  local seed="$1"; shift
  seed=$(echo "$seed" | tr 'A-Z' 'a-z')
  "$CLI" -nodeip "$NODE_IP" -nodeport "$NODE_PORT" -seed "$seed" -scheduletick "$SCHEDULE_TICK" "$@" 2>&1
}

validate_tick() {
  local tick="$1"
  [[ -n "$tick" && "$tick" =~ ^[0-9]+$ && "$tick" -gt 1000 ]]
}

get_current_tick_safe() {
  local out tick
  out=$(cli_call -getcurrenttick)
  tick=$(echo "$out" | grep -oE 'Tick:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [[ -z "$tick" ]]; then
    tick=$(echo "$out" | grep -ioE 'current tick[[:space:]:]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  fi
  echo "${tick:-0}"
}

wait_for_node_online() {
  local tick=0
  while true; do
    tick=$(get_current_tick_safe)
    if validate_tick "$tick"; then
      echo "$tick"
      return 0
    fi
    echo -e "    ${YELLOW}No connection / ungültiger Tick — warte 5s und retry...${NC}" >&2
    sleep 5
  done
}

extract_tx() {
  local output="$1"
  TX_HASH=$(echo "$output" | grep "TxHash:" | awk '{print $2}' | head -1)
  TX_TICK=$(echo "$output" | grep -oE 'Tick:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
}

wait_and_check_tx() {
  local tick="$1" tx_hash="$2"
  local result attempt=0
  while true; do
    attempt=$((attempt + 1))
    sleep "$TX_WAIT_SEC"
    result=$(cli_call -checktxontick "$tick" "$tx_hash")

    if echo "$result" | grep -qi "No connection"; then
      echo -e "    [${attempt}] No connection bei -checktxontick — warte auf Node..." >&2
      wait_for_node_online >/dev/null
      continue
    fi

    if echo "$result" | grep -q "Please wait"; then
      local cur_tick
      cur_tick=$(echo "$result" | grep -oE 'current tick [0-9]+' | grep -oE '[0-9]+')
      echo -e "    [${attempt}] Tick noch nicht erreicht (aktuell: ${cur_tick:-?})" >&2
      continue
    fi

    echo "$result"
    return 0
  done
}

send_tx_with_retry() {
  local label="$1"; shift
  local seed="$1"; shift
  local output attempt=0

  while true; do
    attempt=$((attempt + 1))
    local online_tick
    online_tick=$(wait_for_node_online)
    echo -e "    Node erreichbar bei Tick ${online_tick} — sende TX (Versuch ${attempt})..."

    output=$(cli_call_seed "$seed" "$@")
    echo "$output" | head -5 | sed 's/^/    /'
    extract_tx "$output"

    if [[ -n "${TX_HASH:-}" && -n "${TX_TICK:-}" ]] && validate_tick "$TX_TICK"; then
      step "Warte auf Bestätigung (Tick $TX_TICK)..."
      local check
      check=$(wait_and_check_tx "$TX_TICK" "$TX_HASH")
      echo "$check" | head -3 | sed 's/^/    /'

      if echo "$check" | grep -qi "fail\|error\|rejected"; then
        fail "$label" "TX fehlgeschlagen"
        return 1
      fi
      pass "$label"
      return 0
    fi

    if echo "$output" | grep -qi "No connection"; then
      echo -e "    ${YELLOW}No connection beim TX-Senden — retry...${NC}"
      sleep 3
      continue
    fi

    fail "$label" "TX konnte nicht gesendet werden"
    return 1
  done
}

get_identity_from_seed() {
  local seed="$1"
  local out id
  seed=$(echo "$seed" | tr 'A-Z' 'a-z')
  out=$(cli_call -seed "$seed" -showkeys)
  id=$(echo "$out" | grep -E "Identity:" | awk '{print $2}' | head -1)
  echo "${id:-}"
}

get_balance_of() {
  local id="$1"
  local out bal
  out=$(cli_call -getbalance "$id")
  bal=$(echo "$out" | grep -E "Balance:" | awk '{print $2}' | head -1)
  echo "${bal:-0}"
}

count_asset_shares() {
  local id="$1" name="$2"
  local result
  result=$(cli_call -enabletestcontracts -getasset "$id")
  echo "$result" | awk -v asset="$name" '
      /Asset name:/ { found = ($3 == asset) }
      found && /Number Of Shares:/ { print $4; found=0 }
  ' | head -1
}

get_lowest_ask_price() {
  local issuer="$1" name="$2"
  local orders ask
  orders=$(cli_call -enabletestcontracts -qxgetorder asset ask "$issuer" "$name" 0)
  ask=$(echo "$orders" | awk 'NR>1 && /^[A-Z]/{print $2; exit}')
  echo "${ask:-0}"
}

get_epoch_tick() {
  local sys ep tk
  sys=$(cli_call -getsysteminfo)
  ep=$(echo "$sys" | grep -i 'Epoch:' | awk '{print $2}' | head -1)
  tk=$(echo "$sys" | grep -i 'Tick:' | awk '{print $2}' | head -1)
  if [[ -z "$ep" || -z "$tk" ]]; then
    local fb
    fb=$(cli_call -getcurrenttick)
    ep=$(echo "$fb" | grep -i 'Epoch:' | awk '{print $2}' | head -1)
    tk=$(echo "$fb" | grep -i 'Tick:' | awk '{print $2}' | head -1)
  fi
  echo "${ep:-0} ${tk:-0}"
}

wait_for_next_epoch() {
  local cur_ep cur_tk new_ep new_tk wi=0 ticks_left=0
  read -r cur_ep cur_tk <<< "$(get_epoch_tick)"
  info "Aktuelle Epoch: ${cur_ep}, Tick: ${cur_tk} — warte auf Epoch $((cur_ep + 1)) (kann mehrere Minuten dauern)"
  while true; do
    wi=$((wi + 1))
    sleep 15
    read -r new_ep new_tk <<< "$(get_epoch_tick)"
    if [[ "$new_ep" =~ ^[0-9]+$ && "$new_ep" -gt "$cur_ep" ]]; then
      echo "$cur_ep $new_ep"
      return 0
    fi

    if [[ "$new_tk" =~ ^[0-9]+$ ]]; then
      ticks_left=$((100 - (new_tk % 100)))
      if [[ "$ticks_left" -eq 100 ]]; then
        ticks_left=0
      fi
    else
      ticks_left=0
    fi

    if [[ "$((wi % 2))" -eq 0 || "$wi" -eq 1 ]]; then
      echo -e "    Epoch=${new_ep:-?}, Tick=${new_tk:-?}, bis Wechsel ~${ticks_left} Ticks"
    fi
  done
}

get_dev_address_from_govparams() {
  local out ids
  out=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 1 "" "{ {id, id, id, id, id, uint64, uint64, uint64} }")
  ids=$(echo "$out" | grep -oE '[A-Z]{56}')
  echo "$ids" | sed -n '5p'
}

header "test_arb.sh — Dev-Payout Test"

if [[ ! -x "$CLI" ]]; then
  echo -e "${RED}CLI nicht gefunden oder nicht executable:${NC} $CLI"
  echo "Bitte zuerst qubic-cli bauen."
  exit 1
fi

step "Identities laden..."
ID_A=$(get_identity_from_seed "$SEED_A")
ID_B=$(get_identity_from_seed "$SEED_B")
DEV_ID=$(get_dev_address_from_govparams)

if [[ -z "$ID_A" || -z "$ID_B" || -z "$DEV_ID" ]]; then
  echo -e "${RED}Konnte nicht alle IDs laden.${NC}"
  echo "A=$ID_A"
  echo "B=$ID_B"
  echo "DEV=$DEV_ID"
  exit 1
fi

info "Seed A:  ${ID_A}"
info "Seed B:  ${ID_B}"
info "Dev ID:  ${DEV_ID}"

header "Phase 1 — E0 Baseline (Dev-Balance)"
read -r EP0_START TK0_START <<< "$(get_epoch_tick)"
info "Aktuelle Epoch: ${EP0_START}, Tick: ${TK0_START}"
DEV_BAL_E0=$(get_balance_of "$DEV_ID")
info "Dev Balance @E0: ${DEV_BAL_E0}"

header "Phase 2 — Auf E1 warten und Aktionen ausführen"
read -r EP_BEFORE EP_E1 <<< "$(wait_for_next_epoch)"
info "Epoch gewechselt: ${EP_BEFORE} -> ${EP_E1}"

step "QMINE Käufe auf QX"
ASK=$(get_lowest_ask_price "$QMINE_ISSUER" "$QMINE_NAME")
if [[ "$ASK" -le 0 ]]; then
  ASK=750000000000
  info "Kein Ask gefunden, Fallback Ask=${ASK}"
fi
BID=$((ASK + ASK / 20))
AMOUNT_A=$((QMINE_BUDGET_A / BID))
AMOUNT_B=$((QMINE_BUDGET_B / BID))
if [[ "$AMOUNT_A" -lt 1 ]]; then AMOUNT_A=1; fi
if [[ "$AMOUNT_B" -lt 1 ]]; then AMOUNT_B=1; fi

info "QMINE Ask=${ASK}, Bid=${BID}"
info "Kaufmengen: A=${AMOUNT_A}, B=${AMOUNT_B}"

send_tx_with_retry "Seed A kauft QMINE" "$SEED_A" \
  -enabletestcontracts -qxorder add bid "$QMINE_ISSUER" "$QMINE_NAME" "$BID" "$AMOUNT_A"

send_tx_with_retry "Seed B kauft QMINE" "$SEED_B" \
  -enabletestcontracts -qxorder add bid "$QMINE_ISSUER" "$QMINE_NAME" "$BID" "$AMOUNT_B"

step "QMINE Bestände nach Kauf lesen"
A_QMINE_BEFORE=$(count_asset_shares "$ID_A" "$QMINE_NAME")
B_QMINE_BEFORE=$(count_asset_shares "$ID_B" "$QMINE_NAME")
A_QMINE_BEFORE=${A_QMINE_BEFORE:-0}
B_QMINE_BEFORE=${B_QMINE_BEFORE:-0}
info "QMINE nach Kauf: A=${A_QMINE_BEFORE}, B=${B_QMINE_BEFORE}"

step "QU-Balances vor Auszahlung lesen"
A_QU_BEFORE=$(get_balance_of "$ID_A")
B_QU_BEFORE=$(get_balance_of "$ID_B")
info "QU vor Payout: A=${A_QU_BEFORE}, B=${B_QU_BEFORE}"

header "Phase 3 — In E1 ALLE Shares von A nach B + 20B Revenue senden"

if [[ "$A_QMINE_BEFORE" -lt 1 ]]; then
  fail "QMINE Bewegung" "Seed A hat keine QMINE Shares"
  echo "Abbruch"
  exit 1
fi

# Alle Shares von A zu B transferieren → A hat EndBalance=0 → Payout=0 → alles an Dev
info "Transferiere ALLE ${A_QMINE_BEFORE} QMINE von A -> B (A EndBalance=0 → Payout=0 → Dev)"
send_tx_with_retry "Seed A transferiert ALLE QMINE -> B" "$SEED_A" \
  -enabletestcontracts -qxtransferasset "$QMINE_NAME" "$QMINE_ISSUER" "$ID_B" "$A_QMINE_BEFORE"

info "Sende ${REVENUE_SEND} QU an qRWA (Pool B input)"
send_tx_with_retry "Revenue Send 20B -> qRWA" "$SEED_B" \
  -sendtoaddress "$QRWA_IDENTITY" "$REVENUE_SEND"

header "Phase 4 — E2 prüfen (Vergleich mit E0)"
read -r _ EP_E2 <<< "$(wait_for_next_epoch)"
info "Jetzt in E2: ${EP_E2}"
DEV_BAL_E2=$(get_balance_of "$DEV_ID")
info "Dev Balance @E2: ${DEV_BAL_E2}"

A_QMINE_AFTER_E2=$(count_asset_shares "$ID_A" "$QMINE_NAME")
B_QMINE_AFTER_E2=$(count_asset_shares "$ID_B" "$QMINE_NAME")
A_QMINE_AFTER_E2=${A_QMINE_AFTER_E2:-0}
B_QMINE_AFTER_E2=${B_QMINE_AFTER_E2:-0}
info "QMINE in E2: A=${A_QMINE_AFTER_E2}, B=${B_QMINE_AFTER_E2}"

A_QU_AFTER=$(get_balance_of "$ID_A")
B_QU_AFTER=$(get_balance_of "$ID_B")
info "QU nach Payout: A=${A_QU_AFTER}, B=${B_QU_AFTER}"

DELTA_E0_E2=$((DEV_BAL_E2 - DEV_BAL_E0))
DELTA_A_QU=$((A_QU_AFTER - A_QU_BEFORE))
DELTA_B_QU=$((B_QU_AFTER - B_QU_BEFORE))

header "Ergebnis"
echo "Dev balance E0:    ${DEV_BAL_E0}"
echo "Dev balance E2:    ${DEV_BAL_E2}"
echo "Delta Dev E0->E2:  ${DELTA_E0_E2}"
echo ""
echo "QU Seed A vorher:  ${A_QU_BEFORE}"
echo "QU Seed A nachher: ${A_QU_AFTER}"
echo "Delta A QU:        ${DELTA_A_QU}  (erwartet: 0 — kein Payout)"
echo ""
echo "QU Seed B vorher:  ${B_QU_BEFORE}"
echo "QU Seed B nachher: ${B_QU_AFTER}"
echo "Delta B QU:        ${DELTA_B_QU}  (erwartet: > 0 — normaler Payout)"

# Dev bekommt A's Anteil
if [[ "$DELTA_E0_E2" -gt 0 ]]; then
  pass "Dev income sichtbar (E2 > E0)"
else
  fail "Dev income" "Keine Balance-Erhöhung von E0 auf E2 festgestellt"
fi

# A hat verkauft → EndBalance=0 → kein Payout
if [[ "$DELTA_A_QU" -le 0 ]]; then
  pass "Seed A kein Payout (Shares reduziert auf 0)"
else
  fail "Seed A Payout" "A erhielt trotz Null-EndBalance einen Payout: ${DELTA_A_QU}"
fi

# B hat gehalten (und A's Shares dazubekommen) → normaler Payout
if [[ "$DELTA_B_QU" -gt 0 ]]; then
  pass "Seed B Payout korrekt"
else
  fail "Seed B Payout" "B hat keinen Payout erhalten"
fi

if [[ "$A_QMINE_AFTER_E2" -lt "$A_QMINE_BEFORE" ]]; then
  pass "Seed A Shares wurden reduziert"
else
  fail "Share Reduktion" "Seed A wurde nicht reduziert"
fi

echo ""
echo -e "${BOLD}Summary:${NC} PASS=${PASS}, FAIL=${FAIL}, TOTAL=${TOTAL}"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
