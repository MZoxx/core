#!/bin/bash
#
# test_qrwa_pools.sh — qRWA Pool Payout Tests (Pool A / B / C + Reducer)
# =======================================================================
# Prüft alle Payout-Pfade des qRWA-Contracts mittels Per-Pool Ring-Buffer:
#   fn 11 = GetPayoutsQmine   (types 0+1: QMINE-Holder + Dev)
#   fn 13 = GetPayoutsQrwa    (type 2: qRWA-Holder, Pool A+B 10%)
#   fn 14 = GetPayoutsDedicated (type 3: Dedicated qRWA, Pool C 10%)
#
#   Pool A  → mPoolARevenueAddress sendet QU → type 0 (QMINE-Holder) + type 2 (qRWA-Holder)
#   Pool B  → beliebige Adresse sendet QU   → type 0 (QMINE-Holder) + type 2 (qRWA-Holder)
#   Pool C  → mDedicatedRevenueAddress      → type 0 (QMINE-Holder) + type 3 (Dedicated qRWA)
#   Reducer → Holder reduziert QMINE auf 0  → type 1 (Dev), type 0 NICHT für Reducer
#
# Payouts finden in BEGIN_EPOCH statt.
# Snapshot-Strategie: E_N-End (vor Epoch-Wechsel) → E_{N+1}-Start (nach BEGIN_EPOCH)
#
# Nutzung:
#   chmod +x test_qrwa_pools.sh
#   cd core && ./test_qrwa_pools.sh [pool_b|pool_a|pool_c|reducer|all]
#
# Seeds konfigurieren (oben im Skript oder per Env):
#   SEED_QMINE_HOLDER="..."  # Seed der QMINE hält (für type 0 / type 1 tests)
#   SEED_POOL_B="..."        # Beliebiger Seed mit QU (für Pool B revenue)
#   SEED_POOL_A="..."        # Seed der mPoolARevenueAddress kontrolliert
#   SEED_POOL_C="..."        # Seed der mDedicatedRevenueAddress kontrolliert

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# ── Konfiguration ─────────────────────────────────────────────────────────────
NODE_IP="${NODE_IP:-135.181.160.185}"
NODE_PORT="${NODE_PORT:-31841}"

# CLI-Pfad: SCRIPT_DIR/qubic-cli oder SCRIPT_DIR/../qubic-cli (wenn aus core/ gestartet)
if [[ -x "${SCRIPT_DIR}/qubic-cli/build/qubic-cli" ]]; then
  CLI="${SCRIPT_DIR}/qubic-cli/build/qubic-cli"
elif [[ -x "${SCRIPT_DIR}/../qubic-cli/build/qubic-cli" ]]; then
  CLI="${SCRIPT_DIR}/../qubic-cli/build/qubic-cli"
else
  CLI="${CLI:-qubic-cli}"
fi

CONTRACT_INDEX=20
QRWA_IDENTITY="UAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHQEE"
QMINE_ISSUER="QMINEQQXYBEGBHNSUPOUYDIQKZPCBPQIIHUUZMCPLBPCCAIARVZBTYKGFCWM"
QMINE_NAME="QMINE"
QRWA_ASSET_NAME="QRWA"

# Seeds — bitte anpassen oder per ENV überschreiben
SEED_QMINE_HOLDER="${SEED_QMINE_HOLDER:-gtfgjhtoxcddbxrydatevcmildkmqeiezwgztpwseihqhqxmoamxfak}"  # Seed A
SEED_POOL_B="${SEED_POOL_B:-ytcltfdvfjvskmarrjxloxkjrwtbjbepzjphowjfszldyjscrmztmor}"              # Seed B (Pool B revenue)
SEED_POOL_A="${SEED_POOL_A:-ughdrtzbfhqhmzsnoxvalppxbgmbfazcgvocacdkfrwnolzvrzqzbny}"   # Pool A Revenue Address (Mining)
SEED_POOL_C="${SEED_POOL_C:-gmcccpxjvdfqlanaekolzxqstbdnvxurvfzxvqrsyjjcotmdsjrkomc}"   # Dedicated Revenue Address (Pool C)

# Revenue-Beträge
REVENUE_POOL_B=${REVENUE_POOL_B:-20000000000}   # 20B QU
REVENUE_POOL_A=${REVENUE_POOL_A:-20000000000}   # 20B QU
REVENUE_POOL_C=${REVENUE_POOL_C:-20000000000}   # 20B QU

QMINE_BUDGET=${QMINE_BUDGET:-100000000000}      # 100B buy budget

SCHEDULE_TICK=3
TX_WAIT_SEC=12

# ── Farben ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; TOTAL=0

step()   { echo -e "  ${CYAN}▶ $1${NC}"; }
info()   { echo -e "    ${YELLOW}$1${NC}"; }
pass()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "  ${GREEN}✓ PASS${NC} $1"; }
fail()   { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "  ${RED}✗ FAIL${NC} $1 — $2"; }
skip()   { echo -e "  ${YELLOW}⏭ SKIP${NC} $1 — $2"; }
header() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── CLI-Helpers ────────────────────────────────────────────────────────────────
cli_call() { "$CLI" -nodeip "$NODE_IP" -nodeport "$NODE_PORT" "$@" 2>&1; }
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
    if validate_tick "$tick"; then echo "$tick"; return 0; fi
    echo -e "    ${YELLOW}No connection — retry in 5s...${NC}" >&2
    sleep 5
  done
}

extract_tx() {
  local output="$1"
  TX_HASH=$(echo "$output" | grep "TxHash:" | awk '{print $2}' | head -1)
  TX_TICK=$(echo "$output" | grep -oE 'Tick:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
}

wait_and_check_tx() {
  local tick="$1" tx_hash="$2" result attempt=0
  while true; do
    attempt=$((attempt + 1))
    sleep "$TX_WAIT_SEC"
    result=$(cli_call -checktxontick "$tick" "$tx_hash")
    if echo "$result" | grep -qi "No connection"; then
      wait_for_node_online >/dev/null; continue
    fi
    if echo "$result" | grep -q "Please wait"; then
      continue
    fi
    echo "$result"; return 0
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
    echo -e "    Node @ Tick ${online_tick} — TX (Versuch ${attempt})..."
    output=$(cli_call_seed "$seed" "$@")
    echo "$output" | head -4 | sed 's/^/    /'
    extract_tx "$output"
    if [[ -n "${TX_HASH:-}" && -n "${TX_TICK:-}" ]] && validate_tick "$TX_TICK"; then
      step "Warte auf Bestätigung (Tick $TX_TICK)..."
      local check
      check=$(wait_and_check_tx "$TX_TICK" "$TX_HASH")
      echo "$check" | head -2 | sed 's/^/    /'
      if echo "$check" | grep -qi "fail\|error\|rejected"; then
        fail "$label" "TX fehlgeschlagen"; return 1
      fi
      pass "$label"; return 0
    fi
    if echo "$output" | grep -qi "No connection"; then sleep 3; continue; fi
    fail "$label" "TX konnte nicht gesendet werden"; return 1
  done
}

get_identity_from_seed() {
  local seed out id
  seed=$(echo "$1" | tr 'A-Z' 'a-z')
  out=$(cli_call -seed "$seed" -showkeys)
  id=$(echo "$out" | grep -E "Identity:" | awk '{print $2}' | head -1)
  echo "${id:-}"
}

get_balance_of() {
  local out bal attempt
  for attempt in 1 2 3 4 5; do
    out=$(cli_call -getbalance "$1")
    if echo "$out" | grep -qi "no connection\|error\|timeout"; then
      [[ "$attempt" -lt 5 ]] && sleep 3
      continue
    fi
    bal=$(echo "$out" | grep -E "Balance:" | awk '{print $2}' | head -1)
    if [[ -n "$bal" && "$bal" =~ ^[0-9]+$ ]]; then
      echo "$bal"; return
    fi
    [[ "$attempt" -lt 5 ]] && sleep 3
  done
  echo ""  # Leerer String statt 0 → Aufrufer kann erkennen dass Abfrage fehlschlug
}

count_asset_shares() {
  local id="$1" name="$2" result shares attempt
  for attempt in 1 2 3; do
    result=$(cli_call -enabletestcontracts -getasset "$id")
    shares=$(echo "$result" | awk -v asset="$name" '
        /Asset name:/ { found = ($3 == asset) }
        found && /Number Of Shares:/ { print $4; found=0 }
    ' | head -1)
    if [[ -n "$shares" && "$shares" =~ ^[0-9]+$ && "$shares" -gt 0 ]]; then
      echo "$shares"; return
    fi
    [[ "$attempt" -lt 3 ]] && sleep 2
  done
  echo "0"
}

get_lowest_ask_price() {
  local orders ask
  orders=$(cli_call -enabletestcontracts -qxgetorder asset ask "$1" "$2" 0)
  ask=$(echo "$orders" | awk 'NR>1 && /^[A-Z]/ && $2 ~ /^[0-9]+$/{print $2; exit}')
  echo "${ask:-0}"
}

get_epoch_tick() {
  local sys ep tk
  sys=$(cli_call -getsysteminfo)
  ep=$(echo "$sys" | grep -i 'Epoch:' | awk '{print $2}' | head -1)
  tk=$(echo "$sys" | grep -i 'Tick:' | awk '{print $2}' | head -1)
  if [[ -z "$ep" || -z "$tk" ]]; then
    local fb; fb=$(cli_call -getcurrenttick)
    ep=$(echo "$fb" | grep -i 'Epoch:' | awk '{print $2}' | head -1)
    tk=$(echo "$fb" | grep -i 'Tick:' | awk '{print $2}' | head -1)
  fi
  echo "${ep:-0} ${tk:-0}"
}

wait_for_next_epoch() {
  local cur_ep cur_tk new_ep new_tk wi=0
  read -r cur_ep cur_tk <<< "$(get_epoch_tick)"
  info "Warte auf Epoch $((cur_ep + 1)) (aktuell: ${cur_ep}, Tick: ${cur_tk})..."
  while true; do
    wi=$((wi + 1)); sleep 15
    read -r new_ep new_tk <<< "$(get_epoch_tick)"
    if [[ "$new_ep" =~ ^[0-9]+$ && "$new_ep" -gt "$cur_ep" ]]; then
      echo "$cur_ep $new_ep"; return 0
    fi
    if [[ "$((wi % 4))" -eq 0 ]]; then
      info "Epoch=${new_ep:-?}, Tick=${new_tk:-?}"
    fi
  done
}

wait_n_epoch_changes() {
  local n="$1"
  local i
  for ((i=1; i<=n; i++)); do
    step "Warte auf Epoch-Wechsel (${i}/${n})..."
    read -r _ _ <<< "$(wait_for_next_epoch)"
  done
}

wait_for_distribution_delta() {
  local before_qm="$1" before_qrwa="$2" mode="$3"
  local max_wait_sec="${4:-900}"
  local waited=0 cur_qm cur_qrwa dqm dqr

  while true; do
    read -r cur_qm cur_qrwa <<< "$(get_total_distributed)"
    dqm=$((cur_qm - before_qm))
    dqr=$((cur_qrwa - before_qrwa))

    case "$mode" in
      qmine)
        if [[ "$dqm" -gt 0 ]]; then
          echo "$cur_qm $cur_qrwa"
          return 0
        fi
        ;;
      qrwa)
        if [[ "$dqr" -gt 0 ]]; then
          echo "$cur_qm $cur_qrwa"
          return 0
        fi
        ;;
      any)
        if [[ "$dqm" -gt 0 || "$dqr" -gt 0 ]]; then
          echo "$cur_qm $cur_qrwa"
          return 0
        fi
        ;;
      *)
        echo "$cur_qm $cur_qrwa"
        return 1
        ;;
    esac

    sleep 5
    waited=$((waited + 5))
    if [[ "$waited" -ge "$max_wait_sec" ]]; then
      echo "$cur_qm $cur_qrwa"
      return 1
    fi
  done
}

get_dividend_balances() {
  local out vals
  out=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 5 "" \
    "{ {uint64, uint64, uint64, uint64, uint64, uint64} }")
  vals=$(echo "$out" | awk '/Contract Function Output/{flag=1; next} flag' | grep -oE '\b[0-9]+\b')
  local rpa rpb qm qrwa ded_rev ded_qrwa
  rpa=$(echo "$vals"      | sed -n '1p')
  rpb=$(echo "$vals"      | sed -n '2p')
  qm=$(echo "$vals"       | sed -n '3p')
  qrwa=$(echo "$vals"     | sed -n '4p')
  ded_rev=$(echo "$vals"  | sed -n '5p')
  ded_qrwa=$(echo "$vals" | sed -n '6p')
  echo "${rpa:-0} ${rpb:-0} ${qm:-0} ${qrwa:-0} ${ded_rev:-0} ${ded_qrwa:-0}"
}

get_total_distributed() {
  local out vals
  out=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 6 "" \
    "{ {uint64, uint64} }")
  vals=$(echo "$out" | awk '/Contract Function Output/{flag=1; next} flag' | grep -oE '\b[0-9]+\b')
  local qm_dist qrwa_dist
  qm_dist=$(echo "$vals"   | sed -n '1p')
  qrwa_dist=$(echo "$vals" | sed -n '2p')
  echo "${qm_dist:-0} ${qrwa_dist:-0}"
}

# Query contract addresses (fn 12): dedicatedRevenueAddress, poolARevenueAddress, fundraisingAddress
# Each id = 32 bytes = 4 x uint64, so 3 addresses = 12 uint64
get_contract_addresses_raw() {
  local out
  out=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 12 "" \
    "{ {uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64} }")
  echo "$out"
}

# Check if an id (4 uint64 values) is NULL (all zeros)
check_address_set() {
  local label="$1" q0="$2" q1="$3" q2="$4" q3="$5"
  if [[ "$q0" -eq 0 && "$q1" -eq 0 && "$q2" -eq 0 && "$q3" -eq 0 ]]; then
    info "$label: NULL_ID (nicht gesetzt!)"
    return 1
  else
    info "$label: gesetzt (qwords: $q0 $q1 $q2 $q3)"
    return 0
  fi
}

# Diagnostic: print all configured addresses
diagnose_contract_addresses() {
  step "Diagnose: Contract Addresses abfragen (fn 12)"
  local raw vals
  raw=$(get_contract_addresses_raw)
  vals=$(echo "$raw" | awk '/Contract Function Output/{flag=1; next} flag' | grep -oE '\b[0-9]+\b')
  if [[ -z "$vals" ]]; then
    info "fn 12 nicht verfügbar — Node-Binary hat GetContractAddresses nicht"
    return 1
  fi
  local q0 q1 q2 q3 q4 q5 q6 q7 q8 q9 q10 q11
  q0=$(echo "$vals" | sed -n '1p');  q1=$(echo "$vals" | sed -n '2p')
  q2=$(echo "$vals" | sed -n '3p');  q3=$(echo "$vals" | sed -n '4p')
  q4=$(echo "$vals" | sed -n '5p');  q5=$(echo "$vals" | sed -n '6p')
  q6=$(echo "$vals" | sed -n '7p');  q7=$(echo "$vals" | sed -n '8p')
  q8=$(echo "$vals" | sed -n '9p');  q9=$(echo "$vals" | sed -n '10p')
  q10=$(echo "$vals" | sed -n '11p'); q11=$(echo "$vals" | sed -n '12p')
  check_address_set "mDedicatedRevenueAddress" "${q0:-0}" "${q1:-0}" "${q2:-0}" "${q3:-0}"
  check_address_set "mPoolARevenueAddress"     "${q4:-0}" "${q5:-0}" "${q6:-0}" "${q7:-0}"
  check_address_set "mFundraisingAddress"       "${q8:-0}" "${q9:-0}" "${q10:-0}" "${q11:-0}"
}

get_ring_raw() {
  local fn_num="${1:-11}"
  local attempt raw pid tmpf
  tmpf="/tmp/qrwa_ring_raw_${fn_num}_$$.txt"
  for attempt in 1 2 3; do
    rm -f "$tmpf"
    cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" "$fn_num" "" \
      '{ [1024; {id, uint64, uint32, uint8, uint8, uint8, uint8}], uint16 }' > "$tmpf" 2>&1 &
    pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1; waited=$((waited + 1))
      if [[ "$waited" -ge 60 ]]; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        echo -e "    ${YELLOW}Ring-Buffer Timeout (Versuch ${attempt}/3)...${NC}" >&2
        break
      fi
    done
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      raw=$(cat "$tmpf" 2>/dev/null)
      # Check if we got meaningful data (at least one 60-char address)
      if echo "$raw" | grep -qE '[A-Z]{60}'; then
        rm -f "$tmpf"
        echo "$raw"
        return 0
      fi
    fi
    sleep 2
  done
  rm -f "$tmpf"
  echo -e "    ${YELLOW}Ring-Buffer nicht verfügbar nach 3 Versuchen${NC}" >&2
  echo ""
}

ring_to_tsv() {
  # Output: addr\tamount\ttick\ttype (eine Zeile pro Eintrag)
  awk '
    BEGIN { addr=""; n=0; amount=""; tick=""; type="" }
    /^[[:space:]]*[A-Z]{60},?[[:space:]]*$/ {
      addr=$1; gsub(/,/, "", addr);
      n=0; amount=""; tick=""; type="";
      next;
    }
    addr != "" {
      line=$0;
      while (match(line, /[0-9]+/)) {
        num=substr(line, RSTART, RLENGTH);
        n++;
        if (n==1) amount=num;
        else if (n==2) tick=num;
        else if (n==3) {
          type=num;
          print addr "\t" amount "\t" tick "\t" type;
          addr="";
          n=0;
          break;
        }
        line=substr(line, RSTART+RLENGTH);
      }
    }
  '
}

payout_reason_from_type() {
  case "$1" in
    0) echo "QMINE_HOLDER (Pool A/B/C QMINE-Leg)" ;;
    1) echo "QMINE_DEV (Reducer-Rest an Dev)" ;;
    2) echo "QRWA_HOLDER (Pool A/B qRWA-Leg)" ;;
    3) echo "DEDICATED_QRWA (Pool C qRWA-Leg)" ;;
    *) echo "UNKNOWN" ;;
  esac
}

payout_event_log_type_from_type() {
  case "$1" in
    0) echo "12" ;; # QRWA_LOG_TYPE_PAYOUT_QMINE_HOLDER
    2) echo "13" ;; # QRWA_LOG_TYPE_PAYOUT_QRWA_HOLDER
    3) echo "14" ;; # QRWA_LOG_TYPE_PAYOUT_DEDICATED_QRWA
    *) echo "-" ;;
  esac
}

payout_reason_count_from_type() {
  local payout_type="$1" qmine_count="$2" qrwa_count="$3"
  case "$payout_type" in
    0) echo "$qmine_count" ;; # eligible QMINE count
    2|3) echo "$qrwa_count" ;; # qRWA shares
    *) echo "-" ;;
  esac
}

build_holdings_cache() {
  local raw="$1"
  local tsv_tmp="/tmp/qrwa_bhc_tsv_$$.tsv"
  echo "$raw" | ring_to_tsv > "$tsv_tmp"
  build_holdings_cache_from_tsv "$tsv_tmp"
  rm -f "$tsv_tmp"
}

build_holdings_cache_from_tsv() {
  local tsv_file="$1"
  HOLDINGS_CACHE_FILE="/tmp/qrwa_holdings_cache_$$.tsv"
  : > "$HOLDINGS_CACHE_FILE"

  # Collect unique addresses with non-zero amounts
  local addrs
  addrs=$(awk -F'\t' '$2>0{print $1}' "$tsv_file" | sort -u)
  [[ -z "$addrs" ]] && return 0

  local addr qmine_count qrwa_count
  while read -r addr; do
    [[ -z "$addr" ]] && continue
    qmine_count=$(count_asset_shares "$addr" "$QMINE_NAME")
    qrwa_count=$(count_asset_shares "$addr" "$QRWA_ASSET_NAME")
    qmine_count=${qmine_count:-0}
    qrwa_count=${qrwa_count:-0}
    printf '%s\t%s\t%s\n' "$addr" "$qmine_count" "$qrwa_count" >> "$HOLDINGS_CACHE_FILE"
  done <<< "$addrs"
}

get_cached_counts() {
  local addr="$1"
  if [[ -z "${HOLDINGS_CACHE_FILE:-}" || ! -f "$HOLDINGS_CACHE_FILE" ]]; then
    echo "0 0"
    return 0
  fi
  local row
  row=$(grep -m1 "^${addr}[[:space:]]" "$HOLDINGS_CACHE_FILE" 2>/dev/null || true)
  if [[ -z "$row" ]]; then
    echo "0 0"
  else
    echo "$row" | awk -F'\t' '{print $2+0, $3+0}'
  fi
}

print_payout_explain_addr() {
  local raw="$1" addr="$2"
  [[ -z "$addr" ]] && return 0

  # Parse ring_to_tsv once into temp file
  local tsv_file="/tmp/qrwa_explain_tsv_$$.tsv"
  echo "$raw" | ring_to_tsv > "$tsv_file"

  local rows
  rows=$(awk -F'\t' -v a="$addr" '$1==a && $2>0' "$tsv_file")
  if [[ -z "$rows" ]]; then
    echo ""
    echo "--- Explain Address ---"
    echo "ADDR: ${addr}"
    echo "Keine Einträge im Ring gefunden."
    rm -f "$tsv_file"
    return 0
  fi

  # Pre-compute tick+type totals once
  local tt_file="/tmp/qrwa_explain_tt_$$.tsv"
  awk -F'\t' '$2>0{ key=$3"\t"$4; sums[key]+=$2 } END{ for(k in sums) print k"\t"sums[k] }' "$tsv_file" > "$tt_file"

  local qmine_count qrwa_count
  qmine_count=$(count_asset_shares "$addr" "$QMINE_NAME")
  qrwa_count=$(count_asset_shares "$addr" "$QRWA_ASSET_NAME")
  qmine_count=${qmine_count:-0}
  qrwa_count=${qrwa_count:-0}

  local last_amount last_tick last_type last_reason total_count total_amount
  total_count=$(echo "$rows" | wc -l | tr -d ' ')
  total_amount=$(echo "$rows" | awk -F'\t' '{s+=$2} END{print s+0}')
  read -r last_amount last_tick last_type <<< "$(echo "$rows" | tail -1 | awk -F'\t' '{print $2, $3, $4}')"
  last_reason=$(payout_reason_from_type "$last_type")

  echo ""
  echo "--- Explain Address ---"
  echo "ADDR: ${addr}"
  echo "Ring-Einträge: ${total_count}  Total_QU: ${total_amount}"
  echo "Letzter Eintrag: amount=${last_amount} tick=${last_tick} type=${last_type}"
  echo "Grund: ${last_reason}"
  echo "Aktuelle Holdings: QMINE_COUNT=${qmine_count}  QRWA_COUNT=${qrwa_count}"
  echo ""
  echo "Berechnungs-Kontext je Ring-Eintrag (rekonstruiert):"
  echo "AMOUNT_QU       TICK       TYPE  EVT_LOGTYPE  REASON_COUNT  TICK_TYPE_TOTAL  QMINE_COUNT  QRWA_COUNT   REASON"

  while IFS=$'\t' read -r r_addr r_amount r_tick r_type; do
    [[ -z "$r_addr" ]] && continue
    local tt_total reason row_qmine row_qrwa log_type reason_count
    tt_total=$(awk -F'\t' -v t="$r_tick" -v ty="$r_type" '$1==t && $2==ty{print $3; exit}' "$tt_file")
    tt_total=${tt_total:-0}
    reason=$(payout_reason_from_type "$r_type")
    read -r row_qmine row_qrwa <<< "$(get_cached_counts "$r_addr")"
    log_type=$(payout_event_log_type_from_type "$r_type")
    reason_count=$(payout_reason_count_from_type "$r_type" "$row_qmine" "$row_qrwa")
    printf "%-13s  %-9s  %-4s  %-11s  %-12s  %-15s  %-11s  %-11s  %s\n" \
      "$r_amount" "$r_tick" "$r_type" "$log_type" "$reason_count" "$tt_total" "$row_qmine" "$row_qrwa" "$reason"
  done < <(echo "$rows")

  rm -f "$tsv_file" "$tt_file"

  echo ""
  echo "Hinweis: Exakte on-chain Berechnung nutzt Epoch-Snapshots (begin/end)."
  echo "TICK_TYPE_TOTAL zeigt die Summe gleicher tick+type; Counts sind aktuelle Holdings laut -getasset."
}

print_ring_payouts() {
  local raw="$1"
  # Parse ring_to_tsv ONCE into a temp file (avoid O(n²) re-parsing)
  local tsv_file="/tmp/qrwa_ring_tsv_$$.tsv"
  echo "$raw" | ring_to_tsv > "$tsv_file"

  # Pre-compute tick+type totals in a single awk pass
  local tt_file="/tmp/qrwa_tt_totals_$$.tsv"
  awk -F'\t' '$2>0{ key=$3"\t"$4; sums[key]+=$2 } END{ for(k in sums) print k"\t"sums[k] }' "$tsv_file" > "$tt_file"

  # Skip expensive holdings cache — only load for EXPLAIN_ADDR
  if [[ -n "${EXPLAIN_ADDR:-}" ]]; then
    build_holdings_cache_from_tsv "$tsv_file"
  fi
  echo ""
  echo "--- Letzte Payouts aus Ring-Buffer ---"
  echo "ADDR                                                          AMOUNT_QU       TICK       TYPE  EVT_LOGTYPE  REASON          TICK_TYPE_TOTAL"
  while IFS=$'\t' read -r addr amount tick type; do
    [[ -z "$addr" || "$amount" -le 0 ]] && continue
    local reason tt_total row_qmine row_qrwa log_type reason_count
    reason=$(payout_reason_from_type "$type")
    tt_total=$(awk -F'\t' -v t="$tick" -v ty="$type" '$1==t && $2==ty{print $3; exit}' "$tt_file")
    tt_total=${tt_total:-0}
    log_type=$(payout_event_log_type_from_type "$type")
    printf "%-60s  %-13s  %-9s  %-4s  %-11s  %-14s  %-15s\n" \
      "$addr" "$amount" "$tick" "$type" "$log_type" "$reason" "$tt_total"
  done < "$tsv_file"

  if [[ -n "${EXPLAIN_ADDR:-}" ]]; then
    print_payout_explain_addr "$raw" "$EXPLAIN_ADDR"
  fi

  rm -f "$tsv_file" "$tt_file"
  if [[ -n "${HOLDINGS_CACHE_FILE:-}" && -f "$HOLDINGS_CACHE_FILE" ]]; then
    rm -f "$HOLDINGS_CACHE_FILE"
  fi
}

# Zählt wie oft eine Adresse im Ring-Buffer vorkommt
ring_count_addr() {
  local addr="$1" raw="$2"
  echo "$raw" | ring_to_tsv | awk -F'\t' -v a="$addr" '$1==a{c++} END{print c+0}'
}

# Liest den payoutType aus dem Ring-Buffer-Rohtext für eine bestimmte Adresse.
# Gibt die payoutType-Werte aller Einträge dieser Adresse zurück (eine Zahl pro Zeile).
ring_types_for_addr() {
  local addr="$1" raw="$2"
  echo "$raw" | ring_to_tsv | awk -F'\t' -v a="$addr" '$1==a{print $4}'
}

# Prüft ob im Ring-Buffer mindestens ein Eintrag mit payoutType=T für Adresse A vorkommt
assert_ring_type() {
  local label="$1" addr="$2" expected_type="$3" raw="$4"
  local count types
  count=$(ring_count_addr "$addr" "$raw")
  if [[ "$count" -eq 0 ]]; then
    fail "$label" "Adresse ${addr:0:16}… nicht im Ring-Buffer (type ${expected_type} erwartet)"
    return 1
  fi
  types=$(ring_types_for_addr "$addr" "$raw")
  if echo "$types" | grep -qx "$expected_type"; then
    pass "$label"
  else
    fail "$label" "Adresse im Ring (${count}×), aber kein type=${expected_type} (gefunden: $(echo "$types" | tr '\n' ','))"
  fi
}

assert_ring_absent() {
  local label="$1" addr="$2" raw="$3"
  local count
  count=$(ring_count_addr "$addr" "$raw")
  if [[ "$count" -eq 0 ]]; then
    pass "$label"
  else
    fail "$label" "Adresse ${addr:0:16}… erscheint ${count}× im Ring — sollte fehlen"
  fi
}

assert_ring_type_absent() {
  local label="$1" addr="$2" forbidden_type="$3" raw="$4"
  local hits
  hits=$(echo "$raw" | ring_to_tsv | awk -F'\t' -v a="$addr" -v t="$forbidden_type" '$1==a && $4==t{c++} END{print c+0}')
  if [[ "$hits" -eq 0 ]]; then
    pass "$label"
  else
    fail "$label" "Adresse ${addr:0:16}… hat ${hits}× type=${forbidden_type} im Ring — sollte fehlen"
  fi
}

# Snapshot: E_N-End → E_{N+1}-Start, gibt delta_qmine delta_qrwa zurück
snapshot_total_distributed_delta() {
  local before_qm="$1" before_qrwa="$2"
  local after_qm after_qrwa
  read -r after_qm after_qrwa <<< "$(get_total_distributed)"
  echo "$((after_qm - before_qm)) $((after_qrwa - before_qrwa))"
}

# ── QMINE-Setup: sicherstellen dass SEED_QMINE_HOLDER QMINE hat ───────────────
ensure_qmine_holder() {
  local id_holder
  id_holder=$(get_identity_from_seed "$SEED_QMINE_HOLDER")
  local shares
  shares=$(count_asset_shares "$id_holder" "$QMINE_NAME")
  if [[ "$shares" -gt 0 ]]; then
    echo -e "    ${YELLOW}QMINE-Holder hat bereits ${shares} QMINE — kein Kauf nötig${NC}" >&2
    echo "$shares"
    return
  fi

  echo -e "  ${CYAN}▶ QMINE kaufen für Holder...${NC}" >&2
  local ask bid amount
  ask=$(get_lowest_ask_price "$QMINE_ISSUER" "$QMINE_NAME")
  if [[ "$ask" -le 0 ]]; then
    echo -e "${RED}Kein QMINE-Ask im Orderbuch. Bitte Asks platzieren.${NC}" >&2
    exit 1
  fi
  bid=$((ask + ask / 20))
  amount=$((QMINE_BUDGET / bid))
  if [[ "$amount" -lt 1 ]]; then amount=1; fi
  echo -e "    ${YELLOW}Ask=${ask}, Bid=${bid}, Menge=${amount}${NC}" >&2
  send_tx_with_retry "QMINE-Holder kauft" "$SEED_QMINE_HOLDER" \
    -enabletestcontracts -qxorder add bid "$QMINE_ISSUER" "$QMINE_NAME" "$bid" "$amount" >&2

  local fill_wait=0 fill_max=180
  while true; do
    shares=$(count_asset_shares "$id_holder" "$QMINE_NAME")
    if [[ "$shares" -gt 0 ]]; then
      echo -e "    ${YELLOW}Bid gefüllt: ${shares} QMINE${NC}" >&2
      echo "$shares"
      return
    fi
    fill_wait=$((fill_wait + 1))
    if [[ "$fill_wait" -ge "$fill_max" ]]; then
      echo -e "${RED}Timeout: Bid nicht gefüllt nach $((fill_max * 5))s${NC}" >&2; exit 1
    fi
    if [[ "$((fill_wait % 12))" -eq 0 ]]; then
      echo -e "    ${YELLOW}[${fill_wait}/${fill_max}] Warte auf Bid-Fill...${NC}" >&2
    fi
    sleep 5
  done
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Pool B — beliebige Adresse sendet QU → type 0 + type 2
# ═══════════════════════════════════════════════════════════════════════════════
test_pool_b() {
  header "Test Pool B — Revenue von beliebiger Adresse → type 0 + type 2"

  local id_holder
  id_holder=$(get_identity_from_seed "$SEED_QMINE_HOLDER")
  info "QMINE-Holder: ${id_holder}"

  local holder_shares_before
  holder_shares_before=$(count_asset_shares "$id_holder" "$QMINE_NAME")
  holder_shares_before=${holder_shares_before:-0}

  # Prüfe ob bereits Payouts gelaufen sind (= Holder im Snapshot)
  local dist_check_qm dist_check_qrwa
  read -r dist_check_qm dist_check_qrwa <<< "$(get_total_distributed)"

  if [[ "$holder_shares_before" -gt 0 && "$dist_check_qm" -gt 0 ]]; then
    info "QMINE-Holder bereits im Snapshot (${holder_shares_before} Shares, totalQmineDistributed=${dist_check_qm}) — kein Epoch-Wait nötig"
  else
    step "QMINE-Holder sicherstellen"
    local qmine_shares
    qmine_shares=$(ensure_qmine_holder)
    info "QMINE-Shares: ${qmine_shares}"

    if [[ "$holder_shares_before" -eq 0 ]]; then
      wait_n_epoch_changes 2
    else
      wait_n_epoch_changes 1
    fi
  fi

  step "E_N-End Snapshot"
  local bal_holder_before dist_qm_before dist_qrwa_before
  bal_holder_before=$(get_balance_of "$id_holder")
  bal_holder_before="${bal_holder_before:-0}"
  read -r dist_qm_before dist_qrwa_before <<< "$(get_total_distributed)"
  info "Holder QU: ${bal_holder_before}  totalQmineDistributed: ${dist_qm_before}  totalQRWADistributed: ${dist_qrwa_before}"

  step "Pool B Revenue senden (${REVENUE_POOL_B} QU von Seed B)"
  send_tx_with_retry "Pool B Revenue send" "$SEED_POOL_B" \
    -sendtoaddress "$QRWA_IDENTITY" "$REVENUE_POOL_B"

  step "Warte auf Payout-Ausführung (END_TICK, bis totalQmineDistributed steigt)..."
  if ! wait_for_distribution_delta "$dist_qm_before" "$dist_qrwa_before" qmine 900 >/dev/null; then
    read -r cur_qm cur_qrwa <<< "$(get_total_distributed)"
    info "Timeout beim Warten auf qmine payout — letzte Werte: qm=${cur_qm}, qrwa=${cur_qrwa}"
  fi

  step "E_{N+1}-Start Snapshot"
  local bal_holder_after dist_qm_after dist_qrwa_after
  bal_holder_after=$(get_balance_of "$id_holder")
  bal_holder_after="${bal_holder_after:-}"
  read -r dist_qm_after dist_qrwa_after <<< "$(get_total_distributed)"
  local delta_holder delta_qm_dist delta_qrwa_dist
  if [[ -n "$bal_holder_after" && -n "$bal_holder_before" && "$bal_holder_before" -gt 0 ]]; then
    delta_holder=$((bal_holder_after - bal_holder_before))
  else
    delta_holder=""
  fi
  delta_qm_dist=$((dist_qm_after - dist_qm_before))
  delta_qrwa_dist=$((dist_qrwa_after - dist_qrwa_before))
  info "Holder QU Delta: ${delta_holder:-N/A (Node nicht erreichbar)}"
  info "totalQmineDistributed Delta: ${delta_qm_dist}"
  info "totalQRWADistributed Delta: ${delta_qrwa_dist}"

  # totalQmineDistributed muss gestiegen sein
  if [[ "$delta_qm_dist" -gt 0 ]]; then
    pass "Pool B → totalQmineDistributed gestiegen (+${delta_qm_dist})"
  else
    fail "Pool B drain" "totalQmineDistributed unverändert"
  fi

  # Holder-Balance muss gestiegen sein
  if [[ -z "$delta_holder" ]]; then
    info "Pool B → QMINE-Holder Balance konnte nicht geprüft werden (Node-Verbindung fehlgeschlagen)"
  elif [[ "$delta_holder" -gt 0 ]]; then
    pass "Pool B → QMINE-Holder Balance gestiegen (+${delta_holder})"
  else
    fail "Pool B → QMINE-Holder Balance" "Kein Payout erhalten (delta=${delta_holder})"
  fi

  step "QMINE Ring-Buffer abfragen (fn 11)"
  local ring_raw
  ring_raw=$(get_ring_raw 11)
  if [[ -n "$ring_raw" ]]; then
    print_ring_payouts "$ring_raw"
    assert_ring_type "Pool B → type 0 (QMINE-Holder payout)" "$id_holder" "0" "$ring_raw"
  else
    info "QMINE Ring-Buffer nicht verfügbar — Assertions übersprungen"
  fi

  step "qRWA Ring-Buffer abfragen (fn 13)"
  local ring_raw_qrwa
  ring_raw_qrwa=$(get_ring_raw 13)
  if [[ -n "$ring_raw_qrwa" ]]; then
    local type2_count
    type2_count=$(echo "$ring_raw_qrwa" | ring_to_tsv | awk -F'\t' '$4==2{c++} END{print c+0}')
    if [[ "$type2_count" -gt 0 ]]; then
      pass "Pool B → type 2 (qRWA-Holder) Einträge vorhanden (${type2_count})"
    else
      info "Pool B → type 2 nicht im Ring — kein qRWA-Holder in diesem Test"
    fi
  else
    info "qRWA Ring-Buffer nicht verfügbar — Assertions übersprungen"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Pool A — mPoolARevenueAddress sendet QU → type 0 + type 2
# ═══════════════════════════════════════════════════════════════════════════════
test_pool_a() {
  header "Test Pool A — Revenue von mPoolARevenueAddress → type 0 + type 2"

  if [[ -z "$SEED_POOL_A" ]]; then
    skip "Pool A Test" "SEED_POOL_A nicht konfiguriert — bitte setzen und neu starten"
    return
  fi

  local id_pool_a id_holder
  id_pool_a=$(get_identity_from_seed "$SEED_POOL_A")
  id_holder=$(get_identity_from_seed "$SEED_QMINE_HOLDER")
  info "Pool A Sender: ${id_pool_a}"
  info "QMINE-Holder:  ${id_holder}"

  local holder_shares_before
  holder_shares_before=$(count_asset_shares "$id_holder" "$QMINE_NAME")
  holder_shares_before=${holder_shares_before:-0}

  step "Pool A Revenue Address prüfen (fn 12)"
  local pool_a_addr
  pool_a_addr=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 12 "" \
    "{id, id, id}" | grep -oE '[A-Z]{60}' | sed -n '2p')
  info "mPoolARevenueAddress: ${pool_a_addr:-NICHT GESETZT}"
  if [[ -n "$pool_a_addr" && "$pool_a_addr" == "$id_pool_a" ]]; then
    pass "SEED_POOL_A entspricht mPoolARevenueAddress"
  else
    fail "Pool A Adress-Check" "SEED_POOL_A (${id_pool_a}) != mPoolARevenueAddress (${pool_a_addr:-leer})"
    info "Bitte SEED_POOL_A anpassen oder mPoolARevenueAddress im Contract setzen"
    return
  fi

  # Prüfe ob bereits Payouts gelaufen sind (= Holder im Snapshot)
  local dist_check_qm dist_check_qrwa
  read -r dist_check_qm dist_check_qrwa <<< "$(get_total_distributed)"

  if [[ "$holder_shares_before" -gt 0 && "$dist_check_qm" -gt 0 ]]; then
    info "QMINE-Holder bereits im Snapshot (${holder_shares_before} Shares, totalQmineDistributed=${dist_check_qm}) — kein Epoch-Wait nötig"
  else
    step "QMINE-Holder sicherstellen"
    local qmine_shares
    qmine_shares=$(ensure_qmine_holder)
    info "QMINE-Shares: ${qmine_shares}"

    if [[ "$holder_shares_before" -eq 0 ]]; then
      wait_n_epoch_changes 2
    else
      wait_n_epoch_changes 1
    fi
  fi

  step "E_N-End Snapshot"
  local dist_qm_before dist_qrwa_before bal_holder_before
  read -r dist_qm_before dist_qrwa_before <<< "$(get_total_distributed)"
  bal_holder_before=$(get_balance_of "$id_holder")
  read -r RPA_BEFORE _ _ _ _ _ <<< "$(get_dividend_balances)"
  info "revenuePoolA vor Send: ${RPA_BEFORE}  totalQmineDistributed: ${dist_qm_before}"

  step "Pool A Revenue senden (${REVENUE_POOL_A} QU von mPoolARevenueAddress)"
  send_tx_with_retry "Pool A Revenue send" "$SEED_POOL_A" \
    -sendtoaddress "$QRWA_IDENTITY" "$REVENUE_POOL_A"

  # Kurz warten und dann Pool-State lesen (sollte in revenuePoolA sein)
  sleep 10
  read -r RPA_AFTER _ _ _ _ _ <<< "$(get_dividend_balances)"
  info "revenuePoolA nach Send: ${RPA_AFTER}"
  if [[ "$RPA_AFTER" -gt "$RPA_BEFORE" ]]; then
    pass "Pool A Revenue in revenuePoolA sichtbar (+$((RPA_AFTER - RPA_BEFORE)))"
  else
    info "revenuePoolA noch 0 — END_TICK hat sie ggf. bereits verarbeitet (wird via totalQmineDistributed validiert)"
  fi

  step "Warte auf Payout-Ausführung (END_TICK, bis totalQmineDistributed steigt)..."
  if ! wait_for_distribution_delta "$dist_qm_before" "$dist_qrwa_before" qmine 900 >/dev/null; then
    read -r cur_qm cur_qrwa <<< "$(get_total_distributed)"
    info "Timeout beim Warten auf qmine payout — letzte Werte: qm=${cur_qm}, qrwa=${cur_qrwa}"
  fi

  step "E_{N+1}-Start Snapshot"
  local dist_qm_after dist_qrwa_after bal_holder_after
  read -r dist_qm_after dist_qrwa_after <<< "$(get_total_distributed)"
  bal_holder_after=$(get_balance_of "$id_holder")
  info "totalQmineDistributed Delta: $((dist_qm_after - dist_qm_before))"
  info "QMINE-Holder Balance Delta: $((bal_holder_after - bal_holder_before))"

  if [[ "$((dist_qm_after - dist_qm_before))" -gt 0 ]]; then
    pass "Pool A → totalQmineDistributed gestiegen (+$((dist_qm_after - dist_qm_before)))"
  else
    fail "Pool A drain" "totalQmineDistributed unverändert"
  fi

  step "QMINE Ring-Buffer abfragen (fn 11)"
  local ring_raw
  ring_raw=$(get_ring_raw 11)
  if [[ -n "$ring_raw" ]]; then
    print_ring_payouts "$ring_raw"
    assert_ring_type "Pool A → type 0 (QMINE-Holder payout)" "$id_holder" "0" "$ring_raw"
  else
    info "QMINE Ring-Buffer nicht verfügbar — Assertions übersprungen"
  fi

  step "qRWA Ring-Buffer abfragen (fn 13)"
  local ring_raw_qrwa
  ring_raw_qrwa=$(get_ring_raw 13)
  if [[ -n "$ring_raw_qrwa" ]]; then
    local type2_count
    type2_count=$(echo "$ring_raw_qrwa" | ring_to_tsv | awk -F'\t' '$4==2{c++} END{print c+0}')
    if [[ "$type2_count" -gt 0 ]]; then
      pass "Pool A → type 2 (qRWA-Holder) Einträge vorhanden"
    else
      info "Pool A → type 2 nicht im Ring — kein qRWA-Holder in diesem Test"
    fi
  else
    info "qRWA Ring-Buffer nicht verfügbar — Assertions übersprungen"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Pool C (BTC Mining) — mDedicatedRevenueAddress sendet QU → type 0 + type 3
# ═══════════════════════════════════════════════════════════════════════════════
test_pool_c() {
  header "Test Pool C (BTC Mining) — Revenue von mDedicatedRevenueAddress → type 0 + type 3"

  if [[ -z "$SEED_POOL_C" ]]; then
    skip "Pool C Test" "SEED_POOL_C nicht konfiguriert — bitte setzen und neu starten"
    return
  fi

  local id_pool_c id_holder
  id_pool_c=$(get_identity_from_seed "$SEED_POOL_C")
  id_holder=$(get_identity_from_seed "$SEED_QMINE_HOLDER")
  info "Pool C Sender:  ${id_pool_c}"
  info "QMINE-Holder:   ${id_holder}"

  # Diagnostic: check if mDedicatedRevenueAddress is actually set on the running node
  diagnose_contract_addresses

  # Pool C braucht QMINE-Holder:
  #   - Type 0 (QMINE-Payout) braucht mPayoutTotalQmineBegin > 0
  #   - Type 3 (Dedicated qRWA) braucht qRWA-Holder mit >= 100K QMINE/Share
  local holder_shares_before prev_qm_dist
  holder_shares_before=$(count_asset_shares "$id_holder" "$QMINE_NAME")
  holder_shares_before=${holder_shares_before:-0}
  read -r prev_qm_dist _ <<< "$(get_total_distributed)"

  step "QMINE-Holder sicherstellen (nötig für type 0 + type 3)"
  local qmine_shares
  qmine_shares=$(ensure_qmine_holder)
  info "QMINE-Shares: ${qmine_shares}"

  if [[ "$holder_shares_before" -gt 0 && "$prev_qm_dist" -gt 0 ]]; then
    info "Holder bereits gesnapshotted (totalQmineDistributed=${prev_qm_dist}) — kein Epoch-Wechsel nötig"
  elif [[ "$holder_shares_before" -gt 0 ]]; then
    step "Warte auf 1 Epoch-Wechsel (Holder vorhanden, aber noch kein Payout-Snapshot)"
    wait_n_epoch_changes 1
  else
    step "Warte auf 2 Epoch-Wechsel (neuer Holder → Snapshot → Payout-Buffer)"
    wait_n_epoch_changes 2
  fi

  step "E_N-End Snapshot"
  local dist_qm_before dist_qrwa_before
  read -r dist_qm_before dist_qrwa_before <<< "$(get_total_distributed)"
  local DED_REV_BEFORE DED_QRWA_BEFORE
  read -r _ _ _ _ DED_REV_BEFORE DED_QRWA_BEFORE <<< "$(get_dividend_balances)"
  info "dedicatedRevenuePool: ${DED_REV_BEFORE}  dedicatedQRWADividendPool: ${DED_QRWA_BEFORE}"
  info "totalQRWADistributed: ${dist_qrwa_before}"

  step "Pool C Revenue senden (${REVENUE_POOL_C} QU von mDedicatedRevenueAddress)"
  send_tx_with_retry "Pool C Revenue send" "$SEED_POOL_C" \
    -sendtoaddress "$QRWA_IDENTITY" "$REVENUE_POOL_C"

  # Kurz warten und Pool C State prüfen
  sleep 10
  local DED_REV_AFTER DED_QRWA_AFTER
  read -r _ _ _ _ DED_REV_AFTER DED_QRWA_AFTER <<< "$(get_dividend_balances)"
  info "dedicatedRevenuePool nach Send: ${DED_REV_AFTER}"
  if [[ "$DED_REV_AFTER" -gt "$DED_REV_BEFORE" ]]; then
    pass "Pool C Revenue in dedicatedRevenuePool sichtbar (+$((DED_REV_AFTER - DED_REV_BEFORE)))"
  else
    info "dedicatedRevenuePool noch 0 — END_TICK hat sie ggf. bereits verarbeitet (wird via totalDistributed validiert)"
  fi

  step "Warte auf Payout-Ausführung (END_TICK, bis totalQmineDistributed ODER totalQRWADistributed steigt)..."
  if ! wait_for_distribution_delta "$dist_qm_before" "$dist_qrwa_before" any 900 >/dev/null; then
    read -r cur_qm cur_qrwa <<< "$(get_total_distributed)"
    info "Timeout beim Warten auf qrwa payout — letzte Werte: qm=${cur_qm}, qrwa=${cur_qrwa}"
  fi

  step "E_{N+1}-Start Snapshot"
  local dist_qm_after dist_qrwa_after
  read -r dist_qm_after dist_qrwa_after <<< "$(get_total_distributed)"
  info "totalQmineDistributed Delta: $((dist_qm_after - dist_qm_before))"
  info "totalQRWADistributed Delta: $((dist_qrwa_after - dist_qrwa_before))"

  if [[ "$((dist_qm_after - dist_qm_before))" -gt 0 ]]; then
    pass "Pool C → totalQmineDistributed gestiegen (+$((dist_qm_after - dist_qm_before)))"
  else
    fail "Pool C drain" "totalQmineDistributed unverändert — keine QMINE-Holder beteiligt?"
  fi

  if [[ "$((dist_qrwa_after - dist_qrwa_before))" -gt 0 ]]; then
    pass "Pool C → totalQRWADistributed gestiegen (+$((dist_qrwa_after - dist_qrwa_before)))"
  else
    fail "Pool C drain" "totalQRWADistributed unverändert — keine Dedicated qRWA Holder vorhanden?"
  fi

  step "QMINE Ring-Buffer abfragen (fn 11)"
  local ring_raw
  ring_raw=$(get_ring_raw 11)
  if [[ -n "$ring_raw" ]]; then
    local type0_count
    print_ring_payouts "$ring_raw"
    type0_count=$(echo "$ring_raw" | ring_to_tsv | awk -F'\t' '$4==0{c++} END{print c+0}')
    local payees
    payees=$(echo "$ring_raw" | grep -oE '[A-Z]{60}' | sort -u)
    info "Adressen im QMINE Ring: $(echo "$payees" | wc -l)"

    if [[ "$type0_count" -gt 0 ]]; then
      pass "Pool C → type 0 (QMINE-Holder) Einträge im Ring (${type0_count})"
    else
      fail "Pool C → type 0" "Keine type-0 Einträge im Ring gefunden"
    fi
  else
    info "QMINE Ring-Buffer nicht verfügbar — Assertions übersprungen"
  fi

  step "Dedicated Ring-Buffer abfragen (fn 14)"
  local ring_raw_ded
  ring_raw_ded=$(get_ring_raw 14)
  if [[ -n "$ring_raw_ded" ]]; then
    local type3_count
    type3_count=$(echo "$ring_raw_ded" | ring_to_tsv | awk -F'\t' '$4==3{c++} END{print c+0}')

    if [[ "$type3_count" -gt 0 ]]; then
      pass "Pool C → type 3 (BTC Mining / Dedicated qRWA) Einträge im Ring (${type3_count})"
    else
      fail "Pool C → type 3" "Keine type-3 Einträge im Ring gefunden"
    fi
  else
    info "Dedicated Ring-Buffer nicht verfügbar — Assertions übersprungen"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Reducer → type 1 (Dev) im Ring, type 0 NICHT für Reducer
# ═══════════════════════════════════════════════════════════════════════════════
test_reducer() {
  header "Test Reducer — Holder reduziert QMINE auf 0 → type 1 (Dev), kein type 0 für Reducer"

  local id_holder dev_id
  id_holder=$(get_identity_from_seed "$SEED_QMINE_HOLDER")
  dev_id=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" 1 "" \
    "{ {id, id, id, id, id, uint64, uint64, uint64} }" | grep -oE '[A-Z]{60}' | sed -n '5p')
  info "QMINE-Holder (Reducer): ${id_holder}"
  info "Dev-Adresse:            ${dev_id}"

  if [[ -z "$dev_id" ]]; then
    fail "Reducer Test" "Dev-Adresse konnte nicht aus GovParams geladen werden"; return
  fi

  step "QMINE-Holder sicherstellen"
  local qmine_shares
  qmine_shares=$(ensure_qmine_holder)
  info "QMINE-Shares vor Transfer: ${qmine_shares}"

  # BEGIN_EPOCH E+1 müssen wir sicherstellen dass der Holder eine beginBalance hat.
  # Wir warten falls nötig auf den nächsten Epoch-Wechsel.
  step "Warte auf Epoch-Wechsel (damit beginBalance gesetzt wird)..."
  read -r _ _ <<< "$(wait_for_next_epoch)"

  # Bestand nach Epoch-Wechsel nochmals lesen
  qmine_shares=$(count_asset_shares "$id_holder" "$QMINE_NAME")
  qmine_shares=${qmine_shares:-0}
  info "QMINE-Shares nach BEGIN_EPOCH: ${qmine_shares}"

  if [[ "$qmine_shares" -lt 1 ]]; then
    fail "Reducer Test" "Holder hat keine QMINE nach Epoch-Wechsel"; return
  fi

  step "E_N-End Snapshot (Baseline)"
  local dist_qm_before bal_dev_before bal_holder_before
  read -r dist_qm_before _ <<< "$(get_total_distributed)"
  bal_dev_before=$(get_balance_of "$dev_id")
  bal_holder_before=$(get_balance_of "$id_holder")
  info "Dev QU: ${bal_dev_before}  Holder QU: ${bal_holder_before}"

  step "Revenue senden (damit Pool nicht leer ist)"
  send_tx_with_retry "Revenue Pool B (für Reducer-Test)" "$SEED_POOL_B" \
    -sendtoaddress "$QRWA_IDENTITY" "$REVENUE_POOL_B"

  step "ALLE ${qmine_shares} QMINE von Holder transferieren (EndBalance→0)"
  # Ziel = eine beliebige Adresse die keine beginBalance hat
  local burn_addr="${QMINE_ISSUER}"
  info "Burn-Ziel: ${burn_addr}"
  send_tx_with_retry "Holder transferiert ALLE QMINE → Burn" "$SEED_QMINE_HOLDER" \
    -enabletestcontracts -qxtransferasset "$QMINE_NAME" "$QMINE_ISSUER" "$burn_addr" "$qmine_shares"

  step "Warte auf Epoch-Wechsel (BEGIN_EPOCH zahlt Payout)..."
  read -r _ _ <<< "$(wait_for_next_epoch)"

  step "Warte auf Payout-Ausführung (END_TICK, bis totalQmineDistributed steigt)..."
  if ! wait_for_distribution_delta "$dist_qm_before" 0 qmine 900 >/dev/null; then
    read -r cur_qm _ <<< "$(get_total_distributed)"
    info "Timeout beim Warten auf qmine payout — letzter totalQmineDistributed=${cur_qm}"
  fi

  step "E_{N+1}-Start Snapshot"
  local dist_qm_after bal_dev_after bal_holder_after
  read -r dist_qm_after _ <<< "$(get_total_distributed)"
  bal_dev_after=$(get_balance_of "$dev_id")
  bal_holder_after=$(get_balance_of "$id_holder")
  info "Dev QU Delta:    $((bal_dev_after - bal_dev_before))"
  info "Holder QU Delta: $((bal_holder_after - bal_holder_before))"
  info "totalQmineDistributed Delta: $((dist_qm_after - dist_qm_before))"

  step "QMINE Ring-Buffer abfragen (fn 11)"
  local ring_raw
  ring_raw=$(get_ring_raw 11)
  if [[ -n "$ring_raw" ]]; then
    print_ring_payouts "$ring_raw"
    info "Adressen im Ring (unique): $(echo "$ring_raw" | grep -oE '[A-Z]{60}' | sort -u | wc -l)"

    # Dev muss type 1 (Reducer-Anteil) bekommen haben
    assert_ring_type "Reducer → type 1 (Dev) im Ring" "$dev_id" "1" "$ring_raw"

    # Holder darf NICHT type 0 bekommen haben (endBalance = 0)
    assert_ring_type_absent "Reducer → Holder hat KEIN type 0 (kein QMINE-Payout)" "$id_holder" "0" "$ring_raw"
  else
    info "QMINE Ring-Buffer nicht verfügbar — Ring-Assertions übersprungen"
  fi

  # totalQmineDistributed muss gestiegen sein
  if [[ "$((dist_qm_after - dist_qm_before))" -gt 0 ]]; then
    pass "Reducer → totalQmineDistributed gestiegen (+$((dist_qm_after - dist_qm_before)))"
  else
    fail "Reducer drain" "totalQmineDistributed unverändert"
  fi

  # Dev Balance muss gestiegen sein
  if [[ "$((bal_dev_after - bal_dev_before))" -gt 0 ]]; then
    pass "Reducer → Dev Balance gestiegen (+$((bal_dev_after - bal_dev_before)))"
  else
    fail "Reducer → Dev Balance" "Dev hat nichts erhalten"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
header "test_qrwa_pools.sh — qRWA Pool Payout Tests"

if [[ ! -x "$CLI" ]]; then
  echo -e "${RED}CLI nicht gefunden: ${CLI}${NC}"; exit 1
fi

TESTS="${1:-all}"

case "$TESTS" in
  pool_b)   test_pool_b ;;
  pool_a)   test_pool_a ;;
  pool_c)   test_pool_c ;;
  reducer)  test_reducer ;;
  all)
    test_pool_b
    test_pool_a
    test_pool_c
    test_reducer
    ;;
  *)
    echo "Nutzung: $0 [pool_b|pool_a|pool_c|reducer|all]"
    exit 1
    ;;
esac

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo -e "PASS=${GREEN}${PASS}${NC}  FAIL=${RED}${FAIL}${NC}  TOTAL=${TOTAL}"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
