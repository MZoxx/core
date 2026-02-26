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

# Wartet, bis N Ticks vergangen sind (relativ zum aktuellen Tick beim Aufruf).
# qpi.transfer()-Payouts vom Contract erscheinen NICHT als User-TX; Balance-Delta
# in engem Fenster (vor/nach Payout-Tick) ist die einzige Möglichkeit Einzelzahlungen
# zu verifizieren.
wait_n_ticks() {
  local n="$1"
  local start_tick cur_tick target_tick
  start_tick=$(get_current_tick_safe)
  target_tick=$((start_tick + n))
  info "Warte ${n} Ticks (ab ${start_tick} → bis ${target_tick})..."
  while true; do
    sleep 5
    cur_tick=$(get_current_tick_safe)
    if validate_tick "$cur_tick" && [[ "$cur_tick" -ge "$target_tick" ]]; then
      info "Ziel-Tick ${target_tick} erreicht (aktuell: ${cur_tick})"
      return 0
    fi
  done
}

get_dev_address_from_govparams() {
  local out ids
  # GetGovParams = fn 1; output: QRWAGovParams = 5× id + 3× uint64
  # Fields: mAdminAddress, electricityAddress, maintenanceAddress, reinvestmentAddress, qmineDevAddress, ...
  out=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 1 "" "{ {id, id, id, id, id, uint64, uint64, uint64} }")
  ids=$(echo "$out" | grep -oE '[A-Z]{60}')
  echo "$ids" | sed -n '5p'
}

# GetDividendBalances = fn 5
# Returns: revenuePoolA revenuePoolB qmineDividendPool qrwaDividendPool dedicatedRevenuePool dedicatedQRWADividendPool
get_dividend_balances() {
  local out vals
  out=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 5 "" \
    "{ {uint64, uint64, uint64, uint64, uint64, uint64} }")
  vals=$(echo "$out" | grep -oE '\b[0-9]+\b')
  local rpa rpb qm qrwa
  rpa=$(echo "$vals" | sed -n '1p')
  rpb=$(echo "$vals" | sed -n '2p')
  qm=$(echo "$vals"  | sed -n '3p')
  qrwa=$(echo "$vals" | sed -n '4p')
  echo "${rpa:-0} ${rpb:-0} ${qm:-0} ${qrwa:-0}"
}

# GetTotalDistributed = fn 6
# Returns: totalQmineDistributed totalQRWADistributed
get_total_distributed() {
  local out vals
  out=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 6 "" \
    "{ {uint64, uint64} }")
  vals=$(echo "$out" | grep -oE '\b[0-9]+\b')
  local qm_dist qrwa_dist
  qm_dist=$(echo "$vals"   | sed -n '1p')
  qrwa_dist=$(echo "$vals" | sed -n '2p')
  echo "${qm_dist:-0} ${qrwa_dist:-0}"
}

# GetLatestPayouts = fn 11
# Returns ring buffer: Array<QRWAPayoutEntry,64> + uint8 nextIdx
# Each entry: id recipient, uint64 amount, uint32 tick, uint8 payoutType (0=QMINE,1=dev,2=qRWA,3=dedicatedqRWA)
# Format: { [64; {id, uint64, uint32, uint8, uint8, uint8, uint8}], uint8 }
get_latest_payouts_raw() {
  cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 11 "" \
    '{ [64; {id, uint64, uint32, uint8, uint8, uint8, uint8}], uint8 }'
}

# Gibt alle Adressen zurück, die im Ring-Buffer vorkommen (dedupliziert, sortiert)
get_payees_from_ring() {
  get_latest_payouts_raw | grep -oE '[A-Z]{60}' | sort -u
}

# Prüft ob ADDRESS im Ring-Buffer der letzten Payouts vorkommt
address_paid_in_ring() {
  local addr="$1"
  get_latest_payouts_raw | grep -qF "$addr"
  echo $?  # 0 = found, 1 = not found
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

header "Phase 1 — E0 Baseline: Dev-Balance + QMINE kaufen"
read -r EP0_START TK0_START <<< "$(get_epoch_tick)"
info "Aktuelle Epoch: ${EP0_START}, Tick: ${TK0_START}"
DEV_BAL_E0=$(get_balance_of "$DEV_ID")
info "Dev Balance @E0: ${DEV_BAL_E0}"

step "Pool-Balances @E0 (GetDividendBalances + GetTotalDistributed)"
read -r RPA_E0 RPB_E0 QM_POOL_E0 QRWA_POOL_E0 <<< "$(get_dividend_balances)"
read -r QM_DIST_E0 QRWA_DIST_E0 <<< "$(get_total_distributed)"
info "E0 revenuePoolA=${RPA_E0}  revenuePoolB=${RPB_E0}"
info "E0 qmineDividendPool=${QM_POOL_E0}  qrwaDividendPool=${QRWA_POOL_E0}"
info "E0 totalQmineDistributed=${QM_DIST_E0}  totalQRWADistributed=${QRWA_DIST_E0}"

# QMINE JETZT in E0 kaufen — damit A und B im BEGIN_EPOCH von E1
# als Holder mit beginBalance > 0 erfasst werden.
step "QMINE Käufe auf QX (in E0, vor dem nächsten Epoch-Wechsel)"
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

step "QMINE Bestände nach Kauf lesen (E0)"
A_QMINE_BEFORE=$(count_asset_shares "$ID_A" "$QMINE_NAME")
B_QMINE_BEFORE=$(count_asset_shares "$ID_B" "$QMINE_NAME")
A_QMINE_BEFORE=${A_QMINE_BEFORE:-0}
B_QMINE_BEFORE=${B_QMINE_BEFORE:-0}
info "QMINE in E0: A=${A_QMINE_BEFORE}, B=${B_QMINE_BEFORE}"

step "QU-Balances lesen (E0, nach QMINE-Kauf)"
A_QU_BEFORE=$(get_balance_of "$ID_A")
B_QU_BEFORE=$(get_balance_of "$ID_B")
info "QU in E0: A=${A_QU_BEFORE}, B=${B_QU_BEFORE}"

header "Phase 2 — Auf E1 warten: A transferiert ALLE Shares + Revenue senden"
# Jetzt auf E1 warten. BEGIN_EPOCH E1 erfasst A und B mit ihrer E0-QMINE-Balance.
read -r EP_BEFORE EP_E1 <<< "$(wait_for_next_epoch)"
info "Epoch gewechselt: ${EP_BEFORE} -> ${EP_E1}"

# Nochmals QMINE-Bestand lesen (kann sich nach Epoch-Wechsel leicht ändern)
A_QMINE_BEFORE=$(count_asset_shares "$ID_A" "$QMINE_NAME")
A_QMINE_BEFORE=${A_QMINE_BEFORE:-0}
info "QMINE in E1 (nach BEGIN_EPOCH): A=${A_QMINE_BEFORE}"

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

# ----- Enger Vor/Nach-Snapshot für präzise Payout-Messung pro Adresse -----
# qpi.transfer() vom Contract erscheint NICHT als User-TX → einziger Weg ist
# Balance-Delta in engem Fenster (vor erstem END_TICK mit Pool-Ausschüttung).
step "Snapshot VORHER (direkt nach E2-Start, vor erstem Payout-Tick)"
DEV_BAL_E2_BEFORE=$(get_balance_of "$DEV_ID")
A_QU_E2_BEFORE=$(get_balance_of "$ID_A")
B_QU_E2_BEFORE=$(get_balance_of "$ID_B")
info "VORHER — Dev: ${DEV_BAL_E2_BEFORE}  A: ${A_QU_E2_BEFORE}  B: ${B_QU_E2_BEFORE}"

step "Pool-Balances @E2-Start (GetDividendBalances + GetTotalDistributed)"
read -r RPA_E2 RPB_E2 QM_POOL_E2 QRWA_POOL_E2 <<< "$(get_dividend_balances)"
read -r QM_DIST_E2 QRWA_DIST_E2 <<< "$(get_total_distributed)"
info "E2 revenuePoolA=${RPA_E2}  revenuePoolB=${RPB_E2}"
info "E2 qmineDividendPool=${QM_POOL_E2}  qrwaDividendPool=${QRWA_POOL_E2}"
info "E2 totalQmineDistributed=${QM_DIST_E2}  totalQRWADistributed=${QRWA_DIST_E2}"

# Warte 3 Ticks — in diesem Fenster feuert END_TICK min. 1× und verteilt
# den gesamten qmineDividendPool an alle QMINE-Holder.
wait_n_ticks 3

step "Snapshot NACHHER (nach ≥1× END_TICK Payout)"
DEV_BAL_E2_AFTER=$(get_balance_of "$DEV_ID")
A_QU_E2_AFTER=$(get_balance_of "$ID_A")
B_QU_E2_AFTER=$(get_balance_of "$ID_B")
info "NACHHER — Dev: ${DEV_BAL_E2_AFTER}  A: ${A_QU_E2_AFTER}  B: ${B_QU_E2_AFTER}"

# Enge Deltas = eingehende Contract-Zahlung im Payout-Tick-Fenster
DELTA_DEV_PAYOUT=$((DEV_BAL_E2_AFTER  - DEV_BAL_E2_BEFORE))
DELTA_A_PAYOUT=$((A_QU_E2_AFTER       - A_QU_E2_BEFORE))
DELTA_B_PAYOUT=$((B_QU_E2_AFTER       - B_QU_E2_BEFORE))

# Zusätzlich: Pool-State nach Payout (zeigt ob Pool leergelaufen ist)
step "Pool-Balances nach Payout-Ticks"
read -r RPA_POST RPB_POST QM_POOL_POST QRWA_POOL_POST <<< "$(get_dividend_balances)"
read -r QM_DIST_POST QRWA_DIST_POST <<< "$(get_total_distributed)"
info "POST qmineDividendPool=${QM_POOL_POST}  totalQmineDistributed=${QM_DIST_POST}"

# Ring-Buffer abfragen: GetLatestPayouts (fn 11)
# Jeder erfolgreiche qpi.transfer() schreibt einen Eintrag mit recipient, amount, tick, payoutType.
# So können wir exakt sehen wer bezahlt wurde — ohne Balance-Delta-Unsicherheit.
step "Ring-Buffer abfragen (GetLatestPayouts fn 11)"
RING_RAW=$(get_latest_payouts_raw)
RING_PAYEES=$(echo "$RING_RAW" | grep -oE '[A-Z]{60}' | sort -u)
info "Adressen im Ring-Buffer:"
echo "$RING_PAYEES" | sed 's/^/    /'
B_IN_RING=$(echo "$RING_RAW" | grep -cF "$ID_B" || true)
DEV_IN_RING=$(echo "$RING_RAW" | grep -cF "$DEV_ID" || true)
A_IN_RING=$(echo "$RING_RAW" | grep -cF "$ID_A" || true)
info "Ring-Treffer: B=${B_IN_RING}  DEV=${DEV_IN_RING}  A=${A_IN_RING}"

# QMINE-Bestände in E2
A_QMINE_AFTER_E2=$(count_asset_shares "$ID_A" "$QMINE_NAME")
B_QMINE_AFTER_E2=$(count_asset_shares "$ID_B" "$QMINE_NAME")
A_QMINE_AFTER_E2=${A_QMINE_AFTER_E2:-0}
B_QMINE_AFTER_E2=${B_QMINE_AFTER_E2:-0}
info "QMINE in E2: A=${A_QMINE_AFTER_E2}, B=${B_QMINE_AFTER_E2}"

# Breiter Dev-Delta E0→E2 (als Sanity-Check)
DEV_BAL_E2=${DEV_BAL_E2_AFTER}
DELTA_E0_E2=$((DEV_BAL_E2 - DEV_BAL_E0))

header "Ergebnis"
echo "Dev balance E0 (breit):       ${DEV_BAL_E0}"
echo "Dev balance E2 (breit):       ${DEV_BAL_E2}"
echo "Delta Dev E0->E2 (breit):     ${DELTA_E0_E2}  (Sanity: diverse Faktoren enthalten)"
echo ""
echo "=== Enge Payout-Deltas (vor/nach Payout-Tick-Fenster in E2) ==="
echo "Delta Dev  (E2 eng):  ${DELTA_DEV_PAYOUT}  (erwartet: > 0 — A's Anteil)"
echo "Delta A QU (E2 eng):  ${DELTA_A_PAYOUT}    (erwartet: ≤ 0 — kein Payout, da EndBalance=0)"
echo "Delta B QU (E2 eng):  ${DELTA_B_PAYOUT}    (erwartet: > 0 — normaler QMINE-Payout)"
echo ""
echo "qmineDividendPool vor Payout: ${QM_POOL_E2}   nach: ${QM_POOL_POST}"
echo "totalQmineDistributed:        ${QM_DIST_E2} → ${QM_DIST_POST}  (Delta: $((QM_DIST_POST - QM_DIST_E2)))"
echo ""
echo "--- Pool B (qRWA-Holder) ---"
echo "revenuePoolB   E0→E2:         ${RPB_E0} → ${RPB_E2}"
echo "qrwaDividendPool E0→E2:       ${QRWA_POOL_E0} → ${QRWA_POOL_E2}"
echo "totalQRWADistributed E0→E2:   ${QRWA_DIST_E0} → ${QRWA_DIST_E2}"
DELTA_QRWA_DIST=$((QRWA_DIST_E2 - QRWA_DIST_E0))
echo "Delta totalQRWADistributed:   ${DELTA_QRWA_DIST}  (erwartet: > 0 wenn qRWA-Holder vorhanden)"

# Dev bekommt A's Anteil (enger Snapshot)
if [[ "$DELTA_DEV_PAYOUT" -gt 0 ]]; then
  pass "Dev income sichtbar im Payout-Fenster (eng: +${DELTA_DEV_PAYOUT})"
else
  fail "Dev income" "Keine Balance-Erhöhung im Payout-Tick-Fenster (delta=${DELTA_DEV_PAYOUT})"
fi

# A hat verkauft → EndBalance=0 → kein Payout
if [[ "$DELTA_A_PAYOUT" -le 0 ]]; then
  pass "Seed A kein Payout (EndBalance=0, delta=${DELTA_A_PAYOUT})"
else
  fail "Seed A Payout" "A erhielt trotz Null-EndBalance einen Payout: ${DELTA_A_PAYOUT}"
fi

# B hat gehalten → normaler Payout (enger Snapshot)
if [[ "$DELTA_B_PAYOUT" -gt 0 ]]; then
  pass "Seed B QMINE-Payout korrekt (eng: +${DELTA_B_PAYOUT})"
else
  fail "Seed B Payout" "B hat im Payout-Fenster keinen Payout erhalten (delta=${DELTA_B_PAYOUT})"
fi

# QMINE-Pool sollte nach Payout leer sein (oder kleiner als vorher)
QM_POOL_POST_INT=$(( QM_POOL_POST + 0 ))
QM_POOL_E2_INT=$(( QM_POOL_E2 + 0 ))
if [[ "$QM_POOL_POST_INT" -lt "$QM_POOL_E2_INT" ]]; then
  pass "qmineDividendPool wurde reduziert (${QM_POOL_E2_INT} → ${QM_POOL_POST_INT})"
else
  fail "Pool-Drain" "qmineDividendPool nicht reduziert (${QM_POOL_E2_INT} → ${QM_POOL_POST_INT})"
fi

if [[ "$A_QMINE_AFTER_E2" -lt "$A_QMINE_BEFORE" ]]; then
  pass "Seed A Shares wurden reduziert"
else
  fail "Share Reduktion" "Seed A wurde nicht reduziert"
fi

# Pool B: Revenue wurde empfangen (revenuePoolB oder qrwaDividendPool > 0 in E2, oder bereits verteilt)
QRWA_POOL_E2_INT=$(( QRWA_POOL_E2 + 0 ))
RPB_E2_INT=$(( RPB_E2 + 0 ))
if [[ "$((RPB_E2_INT + QRWA_POOL_E2_INT))" -lt "$REVENUE_SEND" ]]; then
  pass "Pool B Revenue wurde verarbeitet (Pools < REVENUE_SEND)"
else
  info "Pool B Pools E2: revenuePoolB=${RPB_E2_INT} + qrwaDividendPool=${QRWA_POOL_E2_INT} (Ausschüttung ggf. noch ausstehend)"
fi

# Ring-Buffer Assertions (GetLatestPayouts fn 11)
# Exakter Nachweis wer in diesem Payout-Fenster bezahlt wurde
echo ""
echo "=== Ring-Buffer Nachweis (GetLatestPayouts) ==="
echo "B_IN_RING=${B_IN_RING}  DEV_IN_RING=${DEV_IN_RING}  A_IN_RING=${A_IN_RING}"

if [[ "${DEV_IN_RING:-0}" -gt 0 ]]; then
  pass "DEV-Adresse im Payout-Ring (hat A's Reducer-Anteil erhalten)"
else
  fail "DEV Ring" "Dev-Adresse fehlt im Ring-Buffer — Payout nicht verbucht"
fi

if [[ "${B_IN_RING:-0}" -gt 0 ]]; then
  pass "Seed B im Payout-Ring (hat normalen QMINE-Payout erhalten)"
else
  fail "B Ring" "Seed B fehlt im Ring-Buffer — kein regulärer Payout verbucht"
fi

if [[ "${A_IN_RING:-0}" -eq 0 ]]; then
  pass "Seed A nicht im Payout-Ring (EndBalance=0, kein Payout)"
else
  fail "A Ring" "Seed A erscheint im Ring-Buffer obwohl EndBalance=0 war (${A_IN_RING}× gefunden)"
fi

echo ""
echo -e "${BOLD}Summary:${NC} PASS=${PASS}, FAIL=${FAIL}, TOTAL=${TOTAL}"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
