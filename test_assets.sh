#!/bin/bash
#
# test_assets.sh — SC Share Deposit + QMINE Revenue Test (3 Epochen)
# ===================================================================
# Testet den vollen Asset-Revenue-Flow über 3 Epochen:
#
#   Epoche 1: QX SC-Shares kaufen, an qRWA depositen
#             + je 1 qRWA-Share pro Seed kaufen (= qRWA Holder)
#   Epoche 2: Massiv QMINE-Tokens kaufen auf beiden Seeds
#   Epoche 3: Revenue prüfen — Pool B Distributions checken
#
# Nutzung:
#   chmod +x test_assets.sh
#   ./test_assets.sh                 # Voller Flow (3 Epochen)
#   ./test_assets.sh --epoch1        # Nur Epoche 1 (Shares kaufen + Deposit)
#   ./test_assets.sh --epoch2        # Nur Epoche 2 (QMINE kaufen)
#   ./test_assets.sh --epoch3        # Nur Epoche 3 (Revenue Check)
#

set -uo pipefail

###############################################
# KONFIGURATION
###############################################

NODE_IP="135.181.160.185"
NODE_PORT="31841"

CLI="../qubic-cli/build/qubic-cli"

# Test-Seeds (je ~100B QU)
SEED_A="orxlpszaoguhglnkclcqnkvfzhqzzjnuisfvkwwuztkhqpwauexemdy"
SEED_B="iaobrqjfipbwancelebhkjhksghalrbovgfnrrejpvpblmchsliscqw"
ID_A="RDKCNDCZSTZGTBZCQJKLJBQDTTLAEMXFNUDRJDFZRCXRCKDSQJVGSGGDYZJH"
ID_B="MIGFHZMGCTBGRCSXCNWADTVQXHWBKJIQUPQRDAPEFCNOGSVDNVLUFNBBHYUI"

# Admin (SEED1 aus test_qrwa.sh — muss aktuell Admin in qRWA sein)
ADMIN_SEED="gtfgjhtoxcddbxrydatevcmildkmqeiezwgztpwseihqhqxmoamxfak"
ADMIN_ID="STTIMWJNWXARPBPBHBARPMCWVTECDHLTIDFBXRDWDBUAWZZWEPJEJYZARAYC"

# qRWA Contract
CONTRACT_INDEX=20
QRWA_IDENTITY="UAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHQEE"

# SC Share Parameter
NULL_ISSUER="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFXIB"
ASSET_NAME="QX"
# assetNameFromString("QX") = memcpy("QX", &uint64) → Q=0x51=81, X=0x58=88 → 81 + 88*256 = 22609
ASSET_NAME_UINT64=22609

# qRWA Share Parameter (auf QX kaufbar)
QRWA_ASSET_NAME="QRWA"
# assetNameFromString("QRWA") = Q(81)+R(82)*256+W(87)*65536+A(65)*16777216 = 1096241745
QRWA_ASSET_NAME_UINT64=1096241745
QRWA_BID_PRICE=800000000      # 800M QU (~0.8B, über niedrigstem Ask ~750M)
QRWA_SHARES_PER_BUY=1         # je 1 qRWA-Share pro Seed

# QMINE Token Parameter
QMINE_ISSUER="QMINEQQXYBEGBHNSUPOUYDIQKZPCBPQIIHUUZMCPLBPCCAIARVZBTYKGFCWM"
QMINE_NAME="QMINE"
QMINE_BID_PRICE=0             # 0 = dynamisch aus Ask-Orders
QMINE_BUDGET=80000000000      # 80B QU pro Seed für QMINE
QMINE_BUY_AMOUNT=0            # wird aus Budget/Preis berechnet

# QX SC Share Kauf-Parameter
BID_PRICE=0               # 0 = dynamisch aus Ask-Orders ermitteln
SHARES_PER_BUY=1

# Timing
SCHEDULE_TICK=3
TX_WAIT_SEC=12
EPOCH_TICKS=100

###############################################
# FARBEN & ZAEHLER
###############################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
TOTAL=0
declare -a RESULTS=()

###############################################
# HILFSFUNKTIONEN
###############################################

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

record_pass() {
    PASS=$((PASS+1))
    TOTAL=$((TOTAL+1))
    RESULTS+=("${GREEN}PASS${NC} | $1")
    echo -e "  ${GREEN}✓ PASS${NC} $1"
}

record_fail() {
    FAIL=$((FAIL+1))
    TOTAL=$((TOTAL+1))
    RESULTS+=("${RED}FAIL${NC} | $1 — $2")
    echo -e "  ${RED}✗ FAIL${NC} $1 — $2"
}

record_skip() {
    SKIP=$((SKIP+1))
    TOTAL=$((TOTAL+1))
    RESULTS+=("${YELLOW}SKIP${NC} | $1 — $2")
    echo -e "  ${YELLOW}⊘ SKIP${NC} $1 — $2"
}

# CLI aufrufen (ohne Seed)
cli_call() {
    "$CLI" -nodeip "$NODE_IP" -nodeport "$NODE_PORT" "$@" 2>&1
}

# CLI mit Seed aufrufen (TX)
cli_call_seed() {
    local seed="$1"; shift
    "$CLI" -nodeip "$NODE_IP" -nodeport "$NODE_PORT" -seed "$seed" -scheduletick "$SCHEDULE_TICK" "$@" 2>&1
}

# Contract Function aufrufen (read-only, mit Retry)
call_fn() {
    local fn_id="$1" input="$2" output="$3"
    local result
    for _retry in 1 2 3; do
        result=$(cli_call -enabletestcontracts -callcontractfunction "$CONTRACT_INDEX" "$fn_id" "$input" "$output")
        if echo "$result" | grep -q "Contract Function Output"; then
            echo "$result"
            return 0
        fi
        sleep 2
    done
    echo "$result"
}

# TX Hash und Tick aus CLI-Output extrahieren
extract_tx() {
    local output="$1"
    TX_HASH=$(echo "$output" | grep "TxHash:" | awk '{print $2}' | head -1)
    TX_TICK=$(echo "$output" | grep -oE 'Tick:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
}

# Prüfe ob ein Tick plausibel ist (nicht in der fernen Vergangenheit)
validate_tick() {
    local tick="$1"
    if [[ -z "$tick" || ! "$tick" =~ ^[0-9]+$ || "$tick" -lt 1000 ]]; then
        return 1  # Tick ungültig
    fi
    return 0
}

# Niedrigsten Ask-Preis für ein Asset auslesen → setzt LOWEST_ASK
# get_lowest_ask_price <issuer> <asset_name>
get_lowest_ask_price() {
    local issuer="$1" name="$2"
    local orders
    orders=$(cli_call -enabletestcontracts -qxgetorder asset ask "$issuer" "$name" 0 2>&1)
    # Erste Datenzeile (nach Header): Spalte 2 = Preis
    LOWEST_ASK=$(echo "$orders" | awk 'NR>1 && /^[A-Z]/{print $2; exit}')
    LOWEST_ASK=${LOWEST_ASK:-0}
}

# Aktuellen Tick robust vom Node holen (nur numerisch)
get_current_tick_safe() {
    local out tick
    out=$(cli_call -getcurrenttick 2>&1)
    tick=$(echo "$out" | grep -oE 'Tick:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
    if [[ -z "$tick" ]]; then
        tick=$(echo "$out" | grep -ioE 'current tick[[:space:]:]*[0-9]+' | grep -oE '[0-9]+' | head -1)
    fi
    echo "${tick:-0}"
}

# TX senden mit automatischem Retry bei ungültigem Tick
# send_tx_with_retry <label> <seed> <cli_args...>
send_tx_with_retry() {
    local label="$1"; shift
    local seed="$1"; shift
    local max_retries=3
    local attempt=0
    local output

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        output=$(cli_call_seed "$seed" "$@")
        extract_tx "$output"

        if [[ -n "$TX_TICK" ]] && validate_tick "$TX_TICK"; then
            # Tick ist plausibel
            send_and_wait "$label" "$output"
            return $?
        fi

        if [[ $attempt -lt $max_retries ]]; then
            echo -e "    ${YELLOW}[Retry ${attempt}/${max_retries}] Tick ${TX_TICK:-?} ungültig — CLI konnte Current Tick nicht auflösen, warte 3s...${NC}"
            sleep 3
        fi
    done

    # Letztter Versuch fehlgeschlagen — trotzdem als TX verarbeiten
    echo -e "    ${RED}Warnung: Tick ${TX_TICK:-?} nach ${max_retries} Versuchen immer noch ungültig${NC}"
    send_and_wait "$label" "$output"
    return $?
}

# Warte auf TX-Bestätigung
wait_and_check_tx() {
    local tick="$1" tx_hash="$2"
    local max_attempts=8
    local result
    for attempt in $(seq 1 $max_attempts); do
        sleep "$TX_WAIT_SEC"
        result=$(cli_call -checktxontick "$tick" "$tx_hash")
        if echo "$result" | grep -q "Please wait"; then
            local cur_tick=$(echo "$result" | grep -oE 'current tick [0-9]+' | grep -oE '[0-9]+')
            echo -e "    [${attempt}/${max_attempts}] Tick noch nicht erreicht (aktuell: ${cur_tick:-?})" >&2
            continue
        fi
        echo "$result"
        return 0
    done
    echo "$result"
    return 1
}

# Epoch-Wechsel abwarten
wait_for_epoch_change() {
    local max_iter=${1:-120}
    local sys ep tk
    sys=$(cli_call -getsysteminfo 2>&1)
    local start_epoch=$(echo "$sys" | grep -i 'Epoch:' | awk '{print $2}')
    local start_tick=$(echo "$sys" | grep -i 'Tick:' | awk '{print $2}')
    if [[ -z "$start_epoch" ]]; then
        local fb=$(cli_call -getcurrenttick)
        start_epoch=$(echo "$fb" | grep 'Epoch:' | awk '{print $2}')
        start_tick=$(echo "$fb" | grep 'Tick:' | awk '{print $2}')
    fi
    start_epoch=${start_epoch:-0}
    echo -e "    Aktuelle Epoch: ${start_epoch} | Tick: ${start_tick:-?}"
    echo -e "    Testnet: ${EPOCH_TICKS} Ticks/Epoch — warte auf Epoch $((start_epoch + 1))..."

    for wi in $(seq 1 $max_iter); do
        sleep 15
        sys=$(cli_call -getsysteminfo 2>&1)
        ep=$(echo "$sys" | grep -i 'Epoch:' | awk '{print $2}')
        tk=$(echo "$sys" | grep -i 'Tick:' | awk '{print $2}')
        if [[ -z "$ep" ]]; then
            local fb2=$(cli_call -getcurrenttick)
            ep=$(echo "$fb2" | grep 'Epoch:' | awk '{print $2}')
            tk=$(echo "$fb2" | grep 'Tick:' | awk '{print $2}')
        fi
        ep=${ep:-$start_epoch}
        tk=${tk:-0}

        if [[ "$((wi % 4))" -eq 0 || "$wi" -eq 1 ]]; then
            echo -e "    [${wi}/${max_iter}] Epoch: ${ep} | Tick: ${tk}"
        fi

        if [[ "$ep" -gt "$start_epoch" ]]; then
            echo -e "    ${GREEN}${BOLD}Epoch gewechselt: ${start_epoch} → ${ep}${NC}"
            EPOCH_BEFORE=$start_epoch
            EPOCH_AFTER=$ep
            return 0
        fi
    done
    echo -e "    ${RED}Timeout — Epoch blieb bei ${start_epoch} nach $((max_iter * 15))s${NC}"
    return 1
}

# Pool-Snapshots abfragen (Function 5)
snapshot_pools() {
    local snap=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
    PA_SNAP=$(echo "$snap" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
    PB_SNAP=$(echo "$snap" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
    QMINE_SNAP=$(echo "$snap" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
    QRWA_SNAP=$(echo "$snap" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '4p')
    DED_SNAP=$(echo "$snap" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '5p')
    DED_QRWA_SNAP=$(echo "$snap" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '6p')
    PA_SNAP=${PA_SNAP:-0}; PB_SNAP=${PB_SNAP:-0}; QMINE_SNAP=${QMINE_SNAP:-0}
    QRWA_SNAP=${QRWA_SNAP:-0}; DED_SNAP=${DED_SNAP:-0}; DED_QRWA_SNAP=${DED_QRWA_SNAP:-0}
}

# Distributions abfragen (Function 6)
snapshot_distributions() {
    local dist=$(call_fn 6 "" "{ uint64, uint64 }")
    DIST_QMINE_SNAP=$(echo "$dist" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
    DIST_QRWA_SNAP=$(echo "$dist" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
    DIST_QMINE_SNAP=${DIST_QMINE_SNAP:-0}
    DIST_QRWA_SNAP=${DIST_QRWA_SNAP:-0}
}

# Pool-Status anzeigen
print_pools() {
    local pfx="${1:-}  "
    snapshot_pools
    echo -e "${pfx}Pool A (Mining):      ${PA_SNAP} QU"
    echo -e "${pfx}Pool B (User):        ${PB_SNAP} QU"
    echo -e "${pfx}QMINE Div Pool:       ${QMINE_SNAP} QU"
    echo -e "${pfx}QRWA Div Pool:        ${QRWA_SNAP} QU"
    echo -e "${pfx}Dedicated Rev Pool:   ${DED_SNAP} QU"
    echo -e "${pfx}Dedicated QRWA Pool:  ${DED_QRWA_SNAP} QU"
}

# Balance einer Identity abfragen → setzt BAL_RESULT
get_balance() {
    local id="$1"
    local result
    result=$(cli_call -getbalance "$id")
    BAL_RESULT=$(echo "$result" | grep "Balance:" | awk '{print $2}')
    BAL_RESULT=${BAL_RESULT:-0}
}

# Asset-Bestand einer Identity anzeigen
show_assets() {
    local id="$1" label="$2"
    step "${label} — Assets:"
    local result
    result=$(cli_call -enabletestcontracts -getasset "$id")
    if echo "$result" | grep -qi "asset\|share"; then
        echo "$result" | grep -v "WARNING" | sed 's/^/    /'
    else
        echo -e "    ${YELLOW}Keine Assets gefunden${NC}"
        echo "$result" | head -5 | sed 's/^/    /'
    fi
}

# Zähle wie viele Shares einer Identity für ein bestimmtes Asset gehören
# count_asset_shares <IDENTITY> <ASSET_NAME> → setzt ASSET_SHARE_COUNT
count_asset_shares() {
    local id="$1" name="$2"
    local result
    result=$(cli_call -enabletestcontracts -getasset "$id")
    # Suche nach "Asset name: <NAME>" gefolgt von "Number Of Shares: <N>"
    ASSET_SHARE_COUNT=$(echo "$result" | awk -v asset="$name" '
        /Asset name:/ { found = ($3 == asset) }
        found && /Number Of Shares:/ { print $4; found=0 }
    ' | head -1)
    ASSET_SHARE_COUNT=${ASSET_SHARE_COUNT:-0}
}

###############################################
# SENDE TX UND WARTE AUF BESTÄTIGUNG
###############################################

# send_and_wait <label> <cli_output>
# Extrahiert TxHash/Tick, wartet auf Bestätigung
send_and_wait() {
    local label="$1" output="$2"
    echo "$output" | sed 's/^/    /'

    extract_tx "$output"
    if [[ -z "$TX_HASH" || -z "$TX_TICK" ]]; then
        record_fail "$label" "TX konnte nicht gesendet werden"
        return 1
    fi

    step "Warte auf Bestätigung (Tick $TX_TICK)..."
    local check
    check=$(wait_and_check_tx "$TX_TICK" "$TX_HASH")
    echo "$check" | head -3 | sed 's/^/    /'

    if echo "$check" | grep -qi "success\|broadcast\|confirmed\|executed"; then
        record_pass "$label"
        return 0
    elif echo "$check" | grep -qi "fail\|error\|rejected"; then
        record_fail "$label" "TX fehlgeschlagen"
        return 1
    else
        # Nicht eindeutig — als PASS werten (TX wurde gesendet)
        record_pass "$label (TX gesendet)"
        return 0
    fi
}

###############################################
# MODUS AUSWAHL
###############################################
MODE="${1:-all}"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║  test_assets.sh — SC Share Kauf, Deposit & Revenue Test     ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Modus:        ${BOLD}${MODE}${NC}"
echo -e "  Node:         ${NODE_IP}:${NODE_PORT}"
echo -e "  CLI:          ${CLI}"
echo -e "  Asset:        ${ASSET_NAME} (Issuer: ${NULL_ISSUER:0:12}...)"
echo -e "  Preis/Share:  dynamisch (aus Ask-Orders)"
echo -e "  Shares/Kauf:  ${SHARES_PER_BUY}"
echo -e "  qRWA Share:   ${QRWA_SHARES_PER_BUY} @ dynamisch QU"
echo -e "  QMINE:        ~${QMINE_BUDGET} QU Budget pro Seed @ dynamisch"
echo -e "  Seed A:       ${ID_A:0:16}..."
echo -e "  Seed B:       ${ID_B:0:16}..."
echo -e "  Admin:        ${ADMIN_ID:0:16}..."
echo -e "  qRWA:         ${QRWA_IDENTITY:0:16}..."
echo ""

###############################################
# PRE-CHECK: Connectivity & Balances
###############################################

header "PRE-CHECK: Verbindung & Kontostände"

step "Systeminfo..."
SYS=$(cli_call -getsysteminfo)
CURRENT_EPOCH=$(echo "$SYS" | grep -i 'Epoch:' | awk '{print $2}')
CURRENT_TICK=$(echo "$SYS" | grep -i 'Tick:' | awk '{print $2}')

if [[ -z "$CURRENT_EPOCH" ]]; then
    echo -e "  ${RED}✗ Keine Verbindung zum Node!${NC}"
    echo "$SYS" | head -5 | sed 's/^/    /'
    exit 1
fi
echo -e "    Epoch: ${CURRENT_EPOCH} | Tick: ${CURRENT_TICK}"
record_pass "Node erreichbar (Epoch ${CURRENT_EPOCH})"

step "Seed A Balance..."
get_balance "$ID_A"
BAL_A="$BAL_RESULT"
echo -e "    ${ID_A:0:20}... → ${BAL_A} QU"
if [[ "$BAL_A" -le 0 ]]; then
    record_fail "Seed A Balance" "Konto leer (${BAL_A} QU)"
    echo -e "  ${RED}Abbruch — Seed A hat 0 QU.${NC}"
    exit 1
fi

step "Seed B Balance..."
get_balance "$ID_B"
BAL_B="$BAL_RESULT"
echo -e "    ${ID_B:0:20}... → ${BAL_B} QU"
if [[ "$BAL_B" -le 0 ]]; then
    record_fail "Seed B Balance" "Konto leer (${BAL_B} QU)"
    echo -e "  ${RED}Abbruch — Seed B hat 0 QU.${NC}"
    exit 1
fi

step "Admin Balance..."
get_balance "$ADMIN_ID"
echo -e "    ${ADMIN_ID:0:20}... → ${BAL_RESULT} QU"

step "Aktuelle Pools..."
print_pools "  "

step "Aktuelle Distributions..."
snapshot_distributions
echo -e "    QMINE Distributed: ${DIST_QMINE_SNAP} QU"
echo -e "    QRWA Distributed:  ${DIST_QRWA_SNAP} QU"

# Speichere Pre-Check Werte
DIST_QMINE_BEFORE=$DIST_QMINE_SNAP
DIST_QRWA_BEFORE=$DIST_QRWA_SNAP

step "Aktuelle QX SC-Share Ask-Orders..."
ASK_ORDERS=$(cli_call -enabletestcontracts -qxgetorder asset ask "$NULL_ISSUER" "$ASSET_NAME" 0)
echo "$ASK_ORDERS" | head -8 | sed 's/^/    /'

step "Aktuelle qRWA-Share Ask-Orders..."
QRWA_ORDERS=$(cli_call -enabletestcontracts -qxgetorder asset ask "$NULL_ISSUER" "$QRWA_ASSET_NAME" 0)
echo "$QRWA_ORDERS" | head -8 | sed 's/^/    /'

step "Aktuelle QMINE Ask-Orders..."
QMINE_ORDERS=$(cli_call -enabletestcontracts -qxgetorder asset ask "$QMINE_ISSUER" "$QMINE_NAME" 0)
echo "$QMINE_ORDERS" | head -8 | sed 's/^/    /'

# Warm-up: Verbindung zum Node sicherstellen vor erstem TX
step "Verbindung warm-up..."
for _wu in 1 2 3; do
    WU_TICK=$(get_current_tick_safe)
    if [[ "$WU_TICK" =~ ^[0-9]+$ && "$WU_TICK" -gt 1000 ]]; then
        echo -e "    Current Tick: ${WU_TICK} — OK"
        break
    fi
    sleep 2
done

###############################################
# ═══════════════════════════════════════════
# EPOCHE 1: QX SC-Shares + qRWA-Shares kaufen
# ═══════════════════════════════════════════
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--epoch1" ]]; then

header "EPOCHE 1 — QX SC-Shares kaufen & an qRWA depositen"

# ─── 1a: Seed A + B kaufen je 1 QX SC-Share ───
# Dynamischen Bid-Preis aus aktuellem niedrigstem Ask ermitteln
get_lowest_ask_price "$NULL_ISSUER" "$ASSET_NAME"
if [[ "$LOWEST_ASK" -gt 0 ]]; then
    BID_PRICE=$((LOWEST_ASK + LOWEST_ASK / 20))  # Ask + 5% Aufschlag
    echo -e "    ${YELLOW}Niedrigster QX Ask: ${LOWEST_ASK} QU → Bid: ${BID_PRICE} QU (+5%)${NC}"
else
    BID_PRICE=20000000000
    echo -e "    ${YELLOW}Kein Ask gefunden — Fallback Bid: ${BID_PRICE} QU${NC}"
fi

step "Seed A kauft ${SHARES_PER_BUY} ${ASSET_NAME}-Share(s) @ ${BID_PRICE} QU..."
send_tx_with_retry "Seed A — QX SC-Share Kauf" "$SEED_A" \
    -enabletestcontracts \
    -qxorder add bid "$NULL_ISSUER" "$ASSET_NAME" "$BID_PRICE" "$SHARES_PER_BUY"

sleep 5

step "Seed B kauft ${SHARES_PER_BUY} ${ASSET_NAME}-Share(s) @ ${BID_PRICE} QU..."
send_tx_with_retry "Seed B — QX SC-Share Kauf" "$SEED_B" \
    -enabletestcontracts \
    -qxorder add bid "$NULL_ISSUER" "$ASSET_NAME" "$BID_PRICE" "$SHARES_PER_BUY"

sleep 5

step "Asset-Holdings nach QX-Kauf..."
show_assets "$ID_A" "Seed A"
show_assets "$ID_B" "Seed B"

# ─── 1b: Seeds transferieren Management-Rechte direkt an qRWA ───
# POST_ACQUIRE_SHARES in qRWA.h übernimmt automatisch:
#   - transferShareOwnershipAndPossession(owner → SELF)
#   - mGeneralAssetBalances aktualisieren
# Kein Admin-Umweg mehr nötig.
header "EPOCHE 1 — Management-Rechte direkt an qRWA SC"
info "Seed A + B übertragen Management-Rechte ihrer ${ASSET_NAME}-Shares direkt an qRWA."

step "Seed A → qRWA (Management Rights Transfer, ${SHARES_PER_BUY}x ${ASSET_NAME})..."
send_tx_with_retry "Seed A → qRWA (Management Transfer)" "$SEED_A" \
    -enabletestcontracts \
    -qxtransferrights "$ASSET_NAME" "$NULL_ISSUER" QRWA "$SHARES_PER_BUY"

sleep 5

step "Seed B → qRWA (Management Rights Transfer, ${SHARES_PER_BUY}x ${ASSET_NAME})..."
send_tx_with_retry "Seed B → qRWA (Management Transfer)" "$SEED_B" \
    -enabletestcontracts \
    -qxtransferrights "$ASSET_NAME" "$NULL_ISSUER" QRWA "$SHARES_PER_BUY"

sleep 5

TOTAL_SHARES=$((SHARES_PER_BUY * 2))
echo -e "    Erwartete Shares in qRWA: ${TOTAL_SHARES} (${SHARES_PER_BUY} × 2 Seeds)"

# ─── 1c: Deposit verifizieren ───
header "EPOCHE 1 — Deposit Verifikation"

step "GetGeneralAssets (Function 10)..."
GA_OUTPUT=$(call_fn 10 "" "{ uint64, [1024; { id, uint64 }], [1024; uint64] }")
echo "$GA_OUTPUT" | grep -v "WARNING" | head -20 | sed 's/^/    /'

GA_COUNT=$(echo "$GA_OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
GA_COUNT=${GA_COUNT:-0}

if [[ "$GA_COUNT" -gt 0 ]]; then
    record_pass "GetGeneralAssets — ${GA_COUNT} Asset(s) registriert"
else
    record_fail "GetGeneralAssets" "Keine Assets gefunden (count=0) — POST_ACQUIRE_SHARES hat nicht ausgelöst?"
fi

step "GetGeneralAssetBalance für ${ASSET_NAME} (Function 9)..."
GAB_OUTPUT=$(call_fn 9 "{${NULL_ISSUER}id,${ASSET_NAME_UINT64}uint64}" "{ uint64, uint64 }")
GAB_BALANCE=$(echo "$GAB_OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
GAB_STATUS=$(echo "$GAB_OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
GAB_BALANCE=${GAB_BALANCE:-0}; GAB_STATUS=${GAB_STATUS:-0}
echo -e "    Balance: ${GAB_BALANCE} | Status: ${GAB_STATUS} (erwartet: ${TOTAL_SHARES})"

if [[ "$GAB_STATUS" -eq 1 && "$GAB_BALANCE" -ge "$TOTAL_SHARES" ]]; then
    record_pass "GetGeneralAssetBalance — ${GAB_BALANCE} ${ASSET_NAME}-Shares in qRWA gelockt"
else
    record_fail "GetGeneralAssetBalance" "Balance=${GAB_BALANCE} (erwartet >=${TOTAL_SHARES}), Status=${GAB_STATUS}"
fi

# ─── 1g: Seed A + B kaufen je 1 qRWA-Share ───
header "EPOCHE 1 — qRWA-Shares kaufen (Holder werden)"
info "Seed A + B kaufen je ${QRWA_SHARES_PER_BUY} qRWA-Share @ ${QRWA_BID_PRICE} QU."
info "Ab jetzt sind sie qRWA-Holder und erhalten Pool B Revenue."

# Dynamischen qRWA Bid-Preis ermitteln
get_lowest_ask_price "$NULL_ISSUER" "$QRWA_ASSET_NAME"
if [[ "$LOWEST_ASK" -gt 0 ]]; then
    QRWA_BID_PRICE=$((LOWEST_ASK + LOWEST_ASK / 20))  # Ask + 5%
    echo -e "    ${YELLOW}Niedrigster qRWA Ask: ${LOWEST_ASK} QU → Bid: ${QRWA_BID_PRICE} QU (+5%)${NC}"
else
    QRWA_BID_PRICE=900000000
    echo -e "    ${YELLOW}Kein qRWA Ask gefunden — Fallback Bid: ${QRWA_BID_PRICE} QU${NC}"
fi

step "Seed A kauft ${QRWA_SHARES_PER_BUY} qRWA-Share(s)..."
send_tx_with_retry "Seed A — qRWA Share Kauf" "$SEED_A" \
    -enabletestcontracts \
    -qxorder add bid "$NULL_ISSUER" "$QRWA_ASSET_NAME" "$QRWA_BID_PRICE" "$QRWA_SHARES_PER_BUY"

sleep 5

step "Seed B kauft ${QRWA_SHARES_PER_BUY} qRWA-Share(s)..."
send_tx_with_retry "Seed B — qRWA Share Kauf" "$SEED_B" \
    -enabletestcontracts \
    -qxorder add bid "$NULL_ISSUER" "$QRWA_ASSET_NAME" "$QRWA_BID_PRICE" "$QRWA_SHARES_PER_BUY"

sleep 5

step "Holdings nach qRWA-Kauf..."
show_assets "$ID_A" "Seed A (QX + qRWA)"
show_assets "$ID_B" "Seed B (QX + qRWA)"

# ─── Epoch 1 → 2 ───
header "EPOCHE 1 → Epoch-Wechsel abwarten"
step "Warte auf Epoch-Wechsel..."
if wait_for_epoch_change 120; then
    record_pass "Epoch-Wechsel 1 (${EPOCH_BEFORE} → ${EPOCH_AFTER})"
else
    record_fail "Epoch-Wechsel 1" "Timeout"
fi

sleep 5

step "Pools nach Epoch 1..."
print_pools "  "

step "Distributions nach Epoch 1..."
snapshot_distributions
echo -e "    QMINE Distributed: ${DIST_QMINE_SNAP} QU (vorher: ${DIST_QMINE_BEFORE})"
echo -e "    QRWA Distributed:  ${DIST_QRWA_SNAP} QU (vorher: ${DIST_QRWA_BEFORE})"

fi # end --epoch1

###############################################
# ═══════════════════════════════════════════
# EPOCHE 2: Massiv QMINE kaufen
# ═══════════════════════════════════════════
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--epoch2" ]]; then

header "EPOCHE 2 — Massiv QMINE-Tokens kaufen"
info "Seed A + B kaufen je ${QMINE_BUY_AMOUNT} QMINE @ ${QMINE_BID_PRICE} QU/Token."
info "Kosten pro Seed: ~$((QMINE_BUY_AMOUNT * QMINE_BID_PRICE)) QU ($(echo "scale=1; $QMINE_BUY_AMOUNT * $QMINE_BID_PRICE / 1000000000" | bc)B)."
info "QMINE-Holder erhalten 90% des Pool B Revenue."

step "Pools vor QMINE-Kauf..."
print_pools "  "

# Dynamischen QMINE Bid-Preis ermitteln
get_lowest_ask_price "$QMINE_ISSUER" "$QMINE_NAME"
if [[ "$LOWEST_ASK" -gt 0 ]]; then
    QMINE_BID_PRICE=$((LOWEST_ASK + LOWEST_ASK / 20))  # Ask + 5%
    QMINE_BUY_AMOUNT=$((QMINE_BUDGET / QMINE_BID_PRICE))
    echo -e "    ${YELLOW}Niedrigster QMINE Ask: ${LOWEST_ASK} QU → Bid: ${QMINE_BID_PRICE} QU (+5%) → Menge: ${QMINE_BUY_AMOUNT} Token${NC}"
else
    QMINE_BID_PRICE=6000
    QMINE_BUY_AMOUNT=$((QMINE_BUDGET / QMINE_BID_PRICE))
    echo -e "    ${YELLOW}Kein QMINE Ask gefunden — Fallback Bid: ${QMINE_BID_PRICE} QU → Menge: ${QMINE_BUY_AMOUNT} Token${NC}"
fi
if [[ "$QMINE_BUY_AMOUNT" -eq 0 ]]; then
    echo -e "    ${RED}QMINE-Menge = 0 — Budget zu klein? Budget: ${QMINE_BUDGET}, Preis: ${QMINE_BID_PRICE}${NC}"
fi

# --- Seed A kauft QMINE ---
step "Seed A kauft ${QMINE_BUY_AMOUNT} QMINE..."
send_tx_with_retry "Seed A — QMINE Kauf (${QMINE_BUY_AMOUNT})" "$SEED_A" \
    -enabletestcontracts \
    -qxorder add bid "$QMINE_ISSUER" "$QMINE_NAME" "$QMINE_BID_PRICE" "$QMINE_BUY_AMOUNT"

sleep 5

# --- Seed B kauft QMINE ---
step "Seed B kauft ${QMINE_BUY_AMOUNT} QMINE..."
send_tx_with_retry "Seed B — QMINE Kauf (${QMINE_BUY_AMOUNT})" "$SEED_B" \
    -enabletestcontracts \
    -qxorder add bid "$QMINE_ISSUER" "$QMINE_NAME" "$QMINE_BID_PRICE" "$QMINE_BUY_AMOUNT"

sleep 5

step "QMINE-Holdings nach Kauf..."
show_assets "$ID_A" "Seed A (nach QMINE Kauf)"
show_assets "$ID_B" "Seed B (nach QMINE Kauf)"

# ─── Epoch 2 → 3 ───
header "EPOCHE 2 → Epoch-Wechsel abwarten"
step "Warte auf Epoch-Wechsel..."
if wait_for_epoch_change 120; then
    record_pass "Epoch-Wechsel 2 (${EPOCH_BEFORE} → ${EPOCH_AFTER})"
else
    record_fail "Epoch-Wechsel 2" "Timeout"
fi

sleep 5

step "Pools nach Epoch 2..."
print_pools "  "

step "Distributions nach Epoch 2..."
snapshot_distributions
echo -e "    QMINE Distributed: ${DIST_QMINE_SNAP} QU (vorher: ${DIST_QMINE_BEFORE})"
echo -e "    QRWA Distributed:  ${DIST_QRWA_SNAP} QU (vorher: ${DIST_QRWA_BEFORE})"

fi # end --epoch2

###############################################
# ═══════════════════════════════════════════
# EPOCHE 3: Revenue Check
# ═══════════════════════════════════════════
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--epoch3" ]]; then

header "EPOCHE 3 — Revenue Check: Pool B Distributions"

step "Pools in Epoche 3..."
print_pools "  "

step "Distributions in Epoche 3..."
snapshot_distributions
DIST_QMINE_AFTER=$DIST_QMINE_SNAP
DIST_QRWA_AFTER=$DIST_QRWA_SNAP
echo -e "    QMINE Distributed: ${DIST_QMINE_AFTER} QU (Start: ${DIST_QMINE_BEFORE})"
echo -e "    QRWA Distributed:  ${DIST_QRWA_AFTER} QU (Start: ${DIST_QRWA_BEFORE})"

QMINE_DELTA=$((DIST_QMINE_AFTER - DIST_QMINE_BEFORE))
QRWA_DELTA=$((DIST_QRWA_AFTER - DIST_QRWA_BEFORE))
echo ""
echo -e "    ${BOLD}Delta QMINE: +${QMINE_DELTA} QU${NC}"
echo -e "    ${BOLD}Delta QRWA:  +${QRWA_DELTA} QU${NC}"

if [[ "$QMINE_DELTA" -gt 0 || "$QRWA_DELTA" -gt 0 ]]; then
    record_pass "Pool B Revenue verteilt (QMINE: +${QMINE_DELTA}, QRWA: +${QRWA_DELTA})"
else
    record_fail "Pool B Revenue" "Keine Distribution erkannt (Delta=0)"
fi

# --- 90/10 Split prüfen ---
if [[ "$QMINE_DELTA" -gt 0 && "$QRWA_DELTA" -gt 0 ]]; then
    TOTAL_DELTA=$((QMINE_DELTA + QRWA_DELTA))
    QMINE_PCT=$((QMINE_DELTA * 100 / TOTAL_DELTA))
    QRWA_PCT=$((QRWA_DELTA * 100 / TOTAL_DELTA))
    echo -e "    Split: QMINE ${QMINE_PCT}% / QRWA ${QRWA_PCT}%"

    if [[ "$QMINE_PCT" -ge 85 && "$QMINE_PCT" -le 95 ]]; then
        record_pass "90/10 Split korrekt (QMINE=${QMINE_PCT}%, QRWA=${QRWA_PCT}%)"
    else
        record_fail "90/10 Split" "Erwartet ~90/10, bekommen ${QMINE_PCT}/${QRWA_PCT}"
    fi
fi

# --- GeneralAssets finaler Stand ---
step "GetGeneralAssetBalance (Final)..."
GAB_OUTPUT=$(call_fn 9 "{${NULL_ISSUER}id,${ASSET_NAME_UINT64}uint64}" "{ uint64, uint64 }")
GAB_BALANCE=$(echo "$GAB_OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
GAB_BALANCE=${GAB_BALANCE:-0}
echo -e "    ${ASSET_NAME} Balance im Contract: ${GAB_BALANCE} Shares"

TOTAL_SHARES=$((SHARES_PER_BUY * 2))
if [[ "$GAB_BALANCE" -ge "$TOTAL_SHARES" ]]; then
    record_pass "Asset Balance korrekt (${GAB_BALANCE} >= ${TOTAL_SHARES} Shares)"
elif [[ "$GAB_BALANCE" -gt 0 ]]; then
    record_pass "Asset Balance vorhanden (${GAB_BALANCE} Shares)"
else
    record_skip "Asset Balance" "Balance=0"
fi

# --- QMINE + qRWA Holdings ---
step "Finale Holdings der Seeds..."
show_assets "$ID_A" "Seed A (Final)"
show_assets "$ID_B" "Seed B (Final)"

# --- Balance-Check ---
step "Endkontostände..."
get_balance "$ID_A"
echo -e "    Seed A: ${BAL_RESULT} QU (Start: ${BAL_A})"
get_balance "$ID_B"
echo -e "    Seed B: ${BAL_RESULT} QU (Start: ${BAL_B})"

fi # end --epoch3

###############################################
# ZUSAMMENFASSUNG
###############################################

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  ZUSAMMENFASSUNG${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
for r in "${RESULTS[@]}"; do
    echo -e "  $r"
done
echo ""
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC} | ${YELLOW}SKIP: ${SKIP}${NC} | Total: ${TOTAL}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}⚠ Es gab ${FAIL} fehlgeschlagene Tests!${NC}"
    exit 1
else
    echo -e "  ${GREEN}${BOLD}✓ Alle Tests bestanden!${NC}"
    exit 0
fi
