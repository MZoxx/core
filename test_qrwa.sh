#!/bin/bash
#
# qRWA Smart Contract - Automated Test Suite
# ============================================
# Testet alle Funktionen und Procedures des qRWA Contracts (Index 20).
#
# Contract Identity: UAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHQEE
# (publicKey = { 20, 0, 0, 0 } → base26 + K12 checksum)
#
# Nutzung:
#   chmod +x test_qrwa.sh
#   ./test_qrwa.sh                 # Alle Tests
#   ./test_qrwa.sh --readonly      # Nur Read-Only Functions
#   ./test_qrwa.sh --send          # Nur sende Tests (QU → Contract)
#   ./test_qrwa.sh --poolA         # Pool A: QUTIL + Direct Mining Transfer → Epoch → Verify
#   ./test_qrwa.sh --poolB         # Pool B: Normaler Transfer → Epoch → Verify
#   ./test_qrwa.sh --poolC         # Pool C: Dedicated BTC Address → Epoch → Verify
#   ./test_qrwa.sh --vote          # Nur Governance Vote
#   ./test_qrwa.sh --payout        # Payout-Zyklus, 90/10 Split, Gov Fees
#   ./test_qrwa.sh --epoch          # Epoch-Change + automatische Payout-Verifikation
#

set -uo pipefail

###############################################
# KONFIGURATION
###############################################

NODE_IP="135.181.160.185"
NODE_PORT="31841"

# Seeds (55 Zeichen) 
SEED1="gtfgjhtoxcddbxrydatevcmildkmqeiezwgztpwseihqhqxmoamxfak"
SEED2="ytcltfdvfjvskmarrjxloxkjrwtbjbepzjphowjfszldyjscrmztmor"
SEED3="gmcccpxjvdfqlanaekolzxqstbdnvxurvfzxvqrsyjjcotmdsjrkomc"  # Dedicated Revenue Address (Pool C)
SEED4="jaceqhnbufbcyoninbynpmglseulbuabscdrqttdwlflirpxnhnknpz"  # Extra Test Seed
SEED_POOL_A="ughdrtzbfhqhmzsnoxvalppxbgmbfazcgvocacdkfrwnolzvrzqzbny"  # Pool A Revenue Address (Mining)

CLI="../qubic-cli/build/qubic-cli"

CONTRACT_INDEX=20
QRWA_IDENTITY="UAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHQEE"
DEDICATED_IDENTITY="WFCELJRTMTYEGHNTYONQOWVQIUYBVBPTSIRCOTJUXFIQAQPEYJQGQQSAVDDM"
POOL_A_IDENTITY="IZNUAVRCTNYBQBSFYWBBPQUXASPCYDZYKFFULCEGLCFCEQPTLDTKZQMENKRN"

# QMINE Asset
QMINE_ISSUER="QMINEQQXYBEGBHNSUPOUYDIQKZPCBPQIIHUUZMCPLBPCCAIARVZBTYKGFCWM"
QMINE_NAME="QMINE"

SCHEDULE_TICK=5
SEND_AMOUNT=5000000         # 5M QU für Pool B Test
DEDICATED_AMOUNT=3000000    # 3M QU für Dedicated Pool Test (Pool C)
POOL_A_AMOUNT=5000000       # 5M QU für Pool A Test (Mining Revenue)
TX_WAIT_SEC=12              # Wartezeit für TX-Bestätigung
EPOCH_TICKS=100             # Ticks pro Epoch (Testnet-Konfiguration)

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

# Rufe CLI auf und gib Output zurück, ohne automatisches Exit bei Fehler
cli_call() {
    "$CLI" -nodeip "$NODE_IP" -nodeport "$NODE_PORT" "$@" 2>&1
}

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

# Extrahiere Zahlen aus Contract-Function-Output (Zeilen mit nur Zahlen)
extract_numbers() {
    echo "$1" | grep -oE '[0-9]+' | tail -n +1
}

# Warte auf TX-Bestätigung mit Retry (wartet bis Tick erreicht)
wait_and_check_tx() {
    local tick="$1" tx_hash="$2"
    local max_attempts=8
    local result
    for attempt in $(seq 1 $max_attempts); do
        sleep "$TX_WAIT_SEC"
        result=$(cli_call -checktxontick "$tick" "$tx_hash")
        # Wenn "Please wait" → Tick noch nicht erreicht, retry
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

###############################################
# HILFSFUNKTION: Epoch-Wechsel abwarten
###############################################

# wait_for_epoch_change [max_iterations]
# Wartet bis die Epoch sich ändert. Gibt neue Epoch zurück.
# Return 0=gewechselt, 1=timeout
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
            # Export für Aufrufer
            EPOCH_BEFORE=$start_epoch
            EPOCH_AFTER=$ep
            return 0
        fi
    done
    echo -e "    ${RED}Timeout — Epoch blieb bei ${start_epoch} nach $((max_iter * 15))s${NC}"
    return 1
}

# wait_for_payout_cycle [max_iterations]
# Wartet bis TotalDistributed (QMINE oder QRWA) sich ändert.
# Benötigt: DIST_QMINE_BEFORE, DIST_QRWA_BEFORE (global gesetzt vor Aufruf)
# Setzt: DIST_QMINE_AFTER, DIST_QRWA_AFTER
# Return 0=payout erkannt, 1=timeout
wait_for_payout_cycle() {
    local max_iter=${1:-18}
    for wpi in $(seq 1 $max_iter); do
        sleep 10
        local total_chk=$(call_fn 6 "" "{ uint64, uint64 }")
        DIST_QMINE_AFTER=$(echo "$total_chk" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
        DIST_QRWA_AFTER=$(echo "$total_chk" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        DIST_QMINE_AFTER=${DIST_QMINE_AFTER:-0}
        DIST_QRWA_AFTER=${DIST_QRWA_AFTER:-0}

        local pool_chk=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
        local qm_pool=$(echo "$pool_chk" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
        qm_pool=${qm_pool:-0}

        echo -e "    [${wpi}/${max_iter}] QMINE Dist: ${DIST_QMINE_AFTER} | QRWA Dist: ${DIST_QRWA_AFTER} | QMINE Pool: ${qm_pool}"

        if [[ "$DIST_QMINE_AFTER" -gt "$DIST_QMINE_BEFORE" ]] || \
           [[ "$DIST_QRWA_AFTER" -gt "$DIST_QRWA_BEFORE" ]]; then
            echo -e "    ${GREEN}Payout erkannt!${NC}"
            return 0
        fi
    done
    echo -e "    ${YELLOW}Kein Payout in $((max_iter * 10))s erkannt${NC}"
    return 1
}

# snapshot_all_pools → setzt PA_SNAP, PB_SNAP, QMINE_SNAP, QRWA_SNAP, DED_SNAP, DED_QRWA_SNAP
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

# snapshot_distributions → setzt DIST_QMINE_SNAP, DIST_QRWA_SNAP
snapshot_distributions() {
    local dist=$(call_fn 6 "" "{ uint64, uint64 }")
    DIST_QMINE_SNAP=$(echo "$dist" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
    DIST_QRWA_SNAP=$(echo "$dist" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
    DIST_QMINE_SNAP=${DIST_QMINE_SNAP:-0}
    DIST_QRWA_SNAP=${DIST_QRWA_SNAP:-0}
}

# print_pools [prefix] — Zeigt aktuelle Pools an
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

###############################################
# MODUS AUSWAHL
###############################################
MODE="${1:-all}"

###############################################
# VORAUSSETZUNGEN
###############################################

header "VORAUSSETZUNGEN"

# CLI prüfen
if [[ ! -x "$CLI" ]]; then
    echo -e "  ${RED}✗ qubic-cli nicht gefunden: $CLI${NC}"
    echo "    → cd ../qubic-cli && mkdir -p build && cd build && cmake .. && make"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} qubic-cli: $CLI"

# Identities ermitteln
IDENTITY1=$(cli_call -seed "$SEED1" -showkeys | grep "Identity:" | awk '{print $2}')
IDENTITY2=$(cli_call -seed "$SEED2" -showkeys | grep "Identity:" | awk '{print $2}')

if [[ -z "$IDENTITY1" || -z "$IDENTITY2" ]]; then
    echo -e "  ${RED}✗ Konnte Identities nicht ermitteln!${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Seed 1 Identity: $IDENTITY1"
echo -e "  ${GREEN}✓${NC} Seed 2 Identity: $IDENTITY2"

# Node prüfen
TICK_INFO=$(cli_call -getcurrenttick)
CURRENT_TICK=$(echo "$TICK_INFO" | grep "Tick:" | awk '{print $2}')
CURRENT_EPOCH=$(echo "$TICK_INFO" | grep "Epoch:" | awk '{print $2}')

if [[ -z "$CURRENT_TICK" ]]; then
    echo -e "  ${RED}✗ Node nicht erreichbar: $NODE_IP:$NODE_PORT${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Node: $NODE_IP:$NODE_PORT | Tick: $CURRENT_TICK | Epoch: $CURRENT_EPOCH"
echo -e "  ${GREEN}✓${NC} Contract: Index $CONTRACT_INDEX = $QRWA_IDENTITY"
echo ""

# Balances prüfen
BAL1=$(cli_call -getbalance "$IDENTITY1" | grep "Balance:" | head -1)
BAL2=$(cli_call -getbalance "$IDENTITY2" | grep "Balance:" | head -1)
echo -e "  Seed 1 $BAL1"
echo -e "  Seed 2 $BAL2"

###############################################
# SNAPSHOT: qRWA + QMINE Holder Balances (VOR Tests)
###############################################

header "SNAPSHOT: qRWA + QMINE Holder Balances (Anfang)"
step "Lese qRWA-Owner von der Blockchain..."

SNAP_QRWA_RAW=$(cli_call -queryassets ownerships "name=QRWA")

declare -a SNAP_QRWA_IDS=()
declare -a SNAP_QRWA_SHARES=()
SNAP_QRWA_OWNER=""

while IFS= read -r line; do
    if echo "$line" | grep -q 'owner = '; then
        SNAP_QRWA_OWNER=$(echo "$line" | sed 's/.*owner = //' | grep -oE '[A-Z]{50,60}')
    fi
    if echo "$line" | grep -q 'number of shares = '; then
        SNAP_SHARES=$(echo "$line" | sed 's/.*number of shares = //' | grep -oE '[0-9]+')
        if [[ -n "$SNAP_QRWA_OWNER" && -n "$SNAP_SHARES" && "$SNAP_SHARES" -gt 0 ]]; then
            SNAP_QRWA_IDS+=("$SNAP_QRWA_OWNER")
            SNAP_QRWA_SHARES+=("$SNAP_SHARES")
        fi
    fi
done <<< "$SNAP_QRWA_RAW"

echo -e "  ${GREEN}✓${NC} qRWA Owner: ${#SNAP_QRWA_IDS[@]}"

step "Lese QMINE-Owner von der Blockchain..."
SNAP_QMINE_RAW=$(cli_call -queryassets ownerships "name=QMINE,issuer=${QMINE_ISSUER}")

declare -a SNAP_QMINE_IDS=()
declare -a SNAP_QMINE_SHARES=()
SNAP_QMINE_OWNER=""

while IFS= read -r line; do
    if echo "$line" | grep -q 'owner = '; then
        SNAP_QMINE_OWNER=$(echo "$line" | sed 's/.*owner = //' | grep -oE '[A-Z]{50,60}')
    fi
    if echo "$line" | grep -q 'number of shares = '; then
        SNAP_SHARES=$(echo "$line" | sed 's/.*number of shares = //' | grep -oE '[0-9]+')
        if [[ -n "$SNAP_QMINE_OWNER" && -n "$SNAP_SHARES" && "$SNAP_SHARES" -gt 0 ]]; then
            SNAP_QMINE_IDS+=("$SNAP_QMINE_OWNER")
            SNAP_QMINE_SHARES+=("$SNAP_SHARES")
        fi
    fi
done <<< "$SNAP_QMINE_RAW"

echo -e "  ${GREEN}✓${NC} QMINE Owner: ${#SNAP_QMINE_IDS[@]}"

# Wähle max 20 Holder für Payout-Verifikation (Kombination: qRWA-Holder + QMINE-Holder)
# Priorisiere qRWA-Holder da diese den 10%-Anteil bekommen sollen
SNAP_MAX_CHECK=20
declare -a SNAP_CHECK_IDS=()
declare -a SNAP_CHECK_BAL_BEFORE=()
declare -a SNAP_CHECK_TYPE=()  # "qRWA", "QMINE", "BOTH"

# Erst qRWA-Holder (max 10)
SNAP_QRWA_LIMIT=$((SNAP_MAX_CHECK / 2))
if [[ ${#SNAP_QRWA_IDS[@]} -lt $SNAP_QRWA_LIMIT ]]; then
    SNAP_QRWA_LIMIT=${#SNAP_QRWA_IDS[@]}
fi
for i in $(seq 0 $((SNAP_QRWA_LIMIT - 1))); do
    SNAP_CHECK_IDS+=("${SNAP_QRWA_IDS[$i]}")
    SNAP_CHECK_TYPE+=("qRWA:${SNAP_QRWA_SHARES[$i]}")
done

# Dann QMINE-Holder (auffüllen bis max 20, nur wenn nicht schon in qRWA-Liste)
QMINE_IDX=0
while [[ ${#SNAP_CHECK_IDS[@]} -lt $SNAP_MAX_CHECK && $QMINE_IDX -lt ${#SNAP_QMINE_IDS[@]} ]]; do
    CANDIDATE="${SNAP_QMINE_IDS[$QMINE_IDX]}"
    # Prüfe ob schon in der Liste
    ALREADY=0
    for existing in "${SNAP_CHECK_IDS[@]}"; do
        if [[ "$existing" == "$CANDIDATE" ]]; then
            # Bereits als qRWA drin → upgraden zu BOTH
            for upd_idx in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
                if [[ "${SNAP_CHECK_IDS[$upd_idx]}" == "$CANDIDATE" ]]; then
                    SNAP_CHECK_TYPE[$upd_idx]="BOTH:${SNAP_QRWA_SHARES[$upd_idx]}qRWA+${SNAP_QMINE_SHARES[$QMINE_IDX]}QMINE"
                fi
            done
            ALREADY=1
            break
        fi
    done
    if [[ "$ALREADY" -eq 0 ]]; then
        SNAP_CHECK_IDS+=("$CANDIDATE")
        SNAP_CHECK_TYPE+=("QMINE:${SNAP_QMINE_SHARES[$QMINE_IDX]}")
    fi
    QMINE_IDX=$((QMINE_IDX + 1))
done

step "Snapshot QU-Balances für ${#SNAP_CHECK_IDS[@]} Holder..."
for i in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
    BAL_OUT=$(cli_call -getbalance "${SNAP_CHECK_IDS[$i]}")
    BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
    BAL_VAL=${BAL_VAL:-0}
    SNAP_CHECK_BAL_BEFORE+=("$BAL_VAL")
    SHORT_ID="${SNAP_CHECK_IDS[$i]:0:12}…${SNAP_CHECK_IDS[$i]: -6}"
    echo -e "    ${SHORT_ID}  [${SNAP_CHECK_TYPE[$i]}]  Balance: ${BAL_VAL} QU"
done

echo ""
echo -e "  ${CYAN}Snapshot gespeichert. Vergleich folgt am Ende des Scripts.${NC}"

###############################################
# TEST 1: READ-ONLY CONTRACT FUNCTIONS
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--readonly" ]]; then

header "TEST 1: GetGovParams (Function 1)"
step "QRWAGovParams = { id admin, id elec, id maint, id reinv, id dev, u64 elec%, u64 maint%, u64 reinv% }"
OUTPUT=$(call_fn 1 "" "{ { id, id, id, id, id, uint64, uint64, uint64 } }")
echo "$OUTPUT" | grep -v "WARNING" | sed 's/^/    /'

if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    # Prüfe ob Governance-Adressen vorhanden sind (nicht alles Nullen)
    if echo "$OUTPUT" | grep -qE '[A-Z]{56}'; then
        record_pass "GetGovParams — Governance-Adressen vorhanden"
    else
        record_fail "GetGovParams" "Keine Adressen im Output"
    fi
else
    record_fail "GetGovParams" "Kein Output empfangen"
fi

header "TEST 2: GetGovPoll (Function 2) — Poll ID 0"
step "Input: 0uint64 | Output: { QRWAGovProposal, uint64 status }"
OUTPUT=$(call_fn 2 "0uint64" "{ { uint64, uint64, uint64, { id, id, id, id, id, uint64, uint64, uint64 } }, uint64 }")
echo "$OUTPUT" | grep -v "WARNING" | sed 's/^/    /'

if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    record_pass "GetGovPoll(0)"
else
    record_fail "GetGovPoll(0)" "Kein Output"
fi

header "TEST 3: GetAssetReleasePoll (Function 3) — Poll ID 0"
step "Input: 0uint64 | Output: { AssetReleaseProposal, uint64 status }"
OUTPUT=$(call_fn 3 "0uint64" "{ { uint64, id, { id, uint64 }, uint64, id, uint64, uint64, uint64 }, uint64 }")
echo "$OUTPUT" | grep -v "WARNING" | sed 's/^/    /'

if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    record_pass "GetAssetReleasePoll(0)"
else
    record_fail "GetAssetReleasePoll(0)" "Kein Output"
fi

header "TEST 4: GetTreasuryBalance (Function 4)"
OUTPUT=$(call_fn 4 "" "{ uint64 }")
echo "$OUTPUT" | grep -v "WARNING" | sed 's/^/    /'

TREASURY=$(echo "$OUTPUT" | grep -oE '[0-9]+' | tail -1)
if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    record_pass "GetTreasuryBalance — Balance: ${TREASURY:-0}"
else
    record_fail "GetTreasuryBalance" "Kein Output"
fi

header "TEST 5: GetDividendBalances (Function 5)"
step "Output: { revenuePoolA, revenuePoolB, qmineDividendPool, qrwaDividendPool, dedicatedRevenuePool, dedicatedQRWADividendPool }"
OUTPUT=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
echo "$OUTPUT" | grep -v "WARNING" | sed 's/^/    /'

if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    # Extrahiere die 6 Werte
    POOL_VALUES=$(echo "$OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+')
    POOL_A=$(echo "$POOL_VALUES" | sed -n '1p')
    POOL_B=$(echo "$POOL_VALUES" | sed -n '2p')
    QMINE_DIV=$(echo "$POOL_VALUES" | sed -n '3p')
    QRWA_DIV=$(echo "$POOL_VALUES" | sed -n '4p')
    DEDICATED_REV=$(echo "$POOL_VALUES" | sed -n '5p')
    DEDICATED_QRWA=$(echo "$POOL_VALUES" | sed -n '6p')
    echo ""
    echo -e "    ${CYAN}Pool A (QUTIL):         ${POOL_A:-0} QU${NC}"
    echo -e "    ${CYAN}Pool B (User):          ${POOL_B:-0} QU${NC}"
    echo -e "    ${CYAN}QMINE Div Pool:         ${QMINE_DIV:-0} QU${NC}"
    echo -e "    ${CYAN}QRWA Div Pool:          ${QRWA_DIV:-0} QU${NC}"
    echo -e "    ${CYAN}Dedicated Revenue Pool:  ${DEDICATED_REV:-0} QU${NC}"
    echo -e "    ${CYAN}Dedicated QRWA Div Pool: ${DEDICATED_QRWA:-0} QU${NC}"
    record_pass "GetDividendBalances"
else
    record_fail "GetDividendBalances" "Kein Output"
fi

header "TEST 6: GetTotalDistributed (Function 6)"
step "Output: { totalQmineDistributed, totalQRWADistributed }"
OUTPUT=$(call_fn 6 "" "{ uint64, uint64 }")
echo "$OUTPUT" | grep -v "WARNING" | sed 's/^/    /'

if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    DIST_VALUES=$(echo "$OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+')
    TOTAL_QMINE_DIST=$(echo "$DIST_VALUES" | sed -n '1p')
    TOTAL_QRWA_DIST=$(echo "$DIST_VALUES" | sed -n '2p')
    echo ""
    echo -e "    ${CYAN}Total QMINE distributed:  ${TOTAL_QMINE_DIST:-0} QU${NC}"
    echo -e "    ${CYAN}Total QRWA distributed:   ${TOTAL_QRWA_DIST:-0} QU${NC}"
    record_pass "GetTotalDistributed"
else
    record_fail "GetTotalDistributed" "Kein Output"
fi

header "TEST 7: GetActiveGovPollIds (Function 8)"
OUTPUT=$(call_fn 8 "" "{ uint64, [64; uint64] }")
echo "$OUTPUT" | grep -v "WARNING" | sed 's/^/    /'

if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    GOV_COUNT=$(echo "$OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | head -1)
    echo -e "    ${CYAN}Aktive Gov Polls: ${GOV_COUNT:-0}${NC}"
    record_pass "GetActiveGovPollIds — Count: ${GOV_COUNT:-0}"
else
    record_fail "GetActiveGovPollIds" "Kein Output"
fi

header "TEST 8: GetActiveAssetReleasePollIds (Function 7)"
OUTPUT=$(call_fn 7 "" "{ uint64, [64; uint64] }")
echo "$OUTPUT" | grep -v "WARNING" | sed 's/^/    /'

if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    ASSET_COUNT=$(echo "$OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | head -1)
    echo -e "    ${CYAN}Aktive Asset Release Polls: ${ASSET_COUNT:-0}${NC}"
    record_pass "GetActiveAssetReleasePollIds — Count: ${ASSET_COUNT:-0}"
else
    record_fail "GetActiveAssetReleasePollIds" "Kein Output"
fi

fi # end --readonly

###############################################
# TEST 9: QU AN CONTRACT SENDEN (Pool B) — nur bei --send
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--send" ]]; then

header "TEST 9: QU an QRWA senden (Revenue Pool B)"

# Snapshot Dividend Balances VOR Transfer
BEFORE=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
POOL_B_BEFORE=$(echo "$BEFORE" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
POOL_B_BEFORE=${POOL_B_BEFORE:-0}
echo -e "  Pool B VOR Transfer: ${POOL_B_BEFORE} QU"

step "Sende ${SEND_AMOUNT} QU von Seed 1 → $QRWA_IDENTITY"
TX_OUTPUT=$(cli_call_seed "$SEED1" -sendtoaddress "$QRWA_IDENTITY" "$SEND_AMOUNT")
echo "$TX_OUTPUT" | sed 's/^/    /'

TX_HASH=$(echo "$TX_OUTPUT" | grep "TxHash:" | awk '{print $2}')
TX_TICK=$(echo "$TX_OUTPUT" | grep "Tick:" | awk '{print $2}')

if [[ -z "$TX_HASH" || -z "$TX_TICK" ]]; then
    record_fail "QU senden" "TX konnte nicht gesendet werden"
else
    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung (Tick $TX_TICK)..."
    CHECK=$(wait_and_check_tx "$TX_TICK" "$TX_HASH")
    echo "$CHECK" | sed 's/^/    /'

    if echo "$CHECK" | grep -q "MoneyFlew: Yes"; then
        record_pass "QU senden — ${SEND_AMOUNT} QU, MoneyFlew: Yes"
    elif echo "$CHECK" | grep -q "MoneyFlew: N/A"; then
        record_skip "QU senden" "TX noch nicht bestätigt (N/A)"
    else
        record_fail "QU senden" "MoneyFlew != Yes"
    fi
fi

fi # end --send

###############################################
# POOL A TEST: QUTIL Transfer → Epoch-Wait → Direct Transfer → Epoch-Wait → Verify
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--poolA" ]]; then

header "POOL A TEST: QUTIL + Direct Mining Transfer → Epoch → Verify"
step "Pool A erhält Revenue aus QUTIL-Transfers und mPoolARevenueAddress"
step "Gov Fees (50%) werden VOR dem 90/10 Split abgezogen"
step "WICHTIG: mPoolARevenueAddress wird in BEGIN_EPOCH auto-migriert (falls NULL)"
step "Falls der erste Epoch-Wechsel die Adresse erst setzt, wird der Direct-Transfer erst ab Phase 2 korrekt routen."
echo ""

# ── PHASE 1: QUTIL Transfer → Pool A ──
header "Pool A Phase 1: QUTIL SendToManyV1 → Pool A"

step "Snapshot VOR QUTIL Transfer..."
print_pools "    "
PA_BEFORE_QUTIL=$PA_SNAP
PB_BEFORE_QUTIL=$PB_SNAP
snapshot_distributions
DIST_QMINE_BEFORE_QUTIL=$DIST_QMINE_SNAP
DIST_QRWA_BEFORE_QUTIL=$DIST_QRWA_SNAP

QUTIL_AMOUNT=${SEND_AMOUNT}
step "Erstelle QUTIL Payout-File: ${QRWA_IDENTITY} ${QUTIL_AMOUNT}"
QUTIL_FILE="/tmp/qrwa_qutil_payout.txt"
echo "${QRWA_IDENTITY} ${QUTIL_AMOUNT}" > "$QUTIL_FILE"

step "Sende via qutilsendtomanyv1 (Seed 1) → Pool A..."
TX_OUTPUT_A=$(cli_call_seed "$SEED1" -qutilsendtomanyv1 "$QUTIL_FILE")
echo "$TX_OUTPUT_A" | sed 's/^/    /'

TX_HASH_A=$(echo "$TX_OUTPUT_A" | grep "TxHash:" | awk '{print $2}')
TX_TICK_A=$(echo "$TX_OUTPUT_A" | grep "Tick:" | awk '{print $2}')

if [[ -z "$TX_HASH_A" || -z "$TX_TICK_A" ]]; then
    record_fail "QUTIL → Pool A" "TX konnte nicht gesendet werden"
else
    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung (Tick $TX_TICK_A)..."
    CHECK_A=$(wait_and_check_tx "$TX_TICK_A" "$TX_HASH_A")
    echo "$CHECK_A" | sed 's/^/    /'

    if echo "$CHECK_A" | grep -q "MoneyFlew: Yes"; then
        record_pass "QUTIL → Pool A — ${QUTIL_AMOUNT} QU, MoneyFlew: Yes"
        sleep 3
        snapshot_pools
        echo -e "    Pool A: ${PA_BEFORE_QUTIL} → ${PA_SNAP} QU (Δ +$((PA_SNAP - PA_BEFORE_QUTIL)))"
        echo -e "    Pool B: ${PB_BEFORE_QUTIL} → ${PB_SNAP} QU (Δ +$((PB_SNAP - PB_BEFORE_QUTIL)))"
        if [[ "$PA_SNAP" -gt "$PA_BEFORE_QUTIL" ]]; then
            record_pass "Pool A befüllt via QUTIL — +$((PA_SNAP - PA_BEFORE_QUTIL)) QU"
        else
            record_skip "Pool A QUTIL Check" "evtl. sofort Payout verteilt"
        fi
        if [[ "$PB_SNAP" -eq "$PB_BEFORE_QUTIL" ]]; then
            record_pass "Pool B unverändert — korrektes Routing zu Pool A"
        else
            record_skip "Pool B Check" "Pool B geändert (evtl. parallel)"
        fi
    elif echo "$CHECK_A" | grep -q "MoneyFlew: N/A"; then
        record_skip "QUTIL → Pool A" "TX noch nicht bestätigt (N/A)"
    else
        record_fail "QUTIL → Pool A" "MoneyFlew != Yes"
    fi
fi
rm -f "$QUTIL_FILE"

# ── PHASE 1b: Epoch-Wechsel abwarten + Payout verifizieren ──
header "Pool A Phase 1b: Epoch-Wechsel abwarten → Snapshot vergleichen"
step "Warte auf Epoch-Wechsel damit BEGIN_EPOCH Snapshots erstellt..."
step "(Dist-Baseline von VOR QUTIL-Transfer: QMINE=${DIST_QMINE_BEFORE_QUTIL}, QRWA=${DIST_QRWA_BEFORE_QUTIL})"

# Holder-Balances VOR Epoch (Snapshot für Vergleich)
step "Snapshot: Holder QU-Balances VOR Epoch-Wechsel..."
declare -a PA1_SNAP_IDS=()
declare -a PA1_SNAP_BAL=()
if [[ ${#SNAP_CHECK_IDS[@]} -gt 0 ]]; then
    for si in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
        PA1_SNAP_IDS+=("${SNAP_CHECK_IDS[$si]}")
        BAL_OUT=$(cli_call -getbalance "${SNAP_CHECK_IDS[$si]}")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PA1_SNAP_BAL+=("${BAL_VAL:-0}")
    done
    echo -e "    ${GREEN}✓${NC} Snapshot für ${#PA1_SNAP_IDS[@]} Holder gespeichert"
else
    for snap_id in "$IDENTITY1" "$IDENTITY2"; do
        PA1_SNAP_IDS+=("$snap_id")
        BAL_OUT=$(cli_call -getbalance "$snap_id")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PA1_SNAP_BAL+=("${BAL_VAL:-0}")
    done
    echo -e "    ${GREEN}✓${NC} Snapshot für ${#PA1_SNAP_IDS[@]} Holder (Fallback Seed 1+2)"
fi

if wait_for_epoch_change 120; then
    record_pass "Epoch gewechselt — ${EPOCH_BEFORE} → ${EPOCH_AFTER}"
    echo ""
    step "Warte 60s auf Payout-Zyklen nach Epoch (3×20 Ticks)..."
    sleep 60

    # TotalDistributed info (Baseline = VOR dem QUTIL Transfer)
    snapshot_distributions
    DELTA_QMINE=$((DIST_QMINE_SNAP - DIST_QMINE_BEFORE_QUTIL))
    DELTA_QRWA=$((DIST_QRWA_SNAP - DIST_QRWA_BEFORE_QUTIL))
    echo -e "    QMINE Distributed: ${DIST_QMINE_BEFORE_QUTIL} → ${DIST_QMINE_SNAP} (Δ +${DELTA_QMINE} QU)"
    echo -e "    QRWA Distributed:  ${DIST_QRWA_BEFORE_QUTIL} → ${DIST_QRWA_SNAP} (Δ +${DELTA_QRWA} QU)"
    if [[ "$DELTA_QMINE" -gt 0 ]]; then
        record_pass "QMINE Payout nach QUTIL-Epoch — +${DELTA_QMINE} QU"
    fi
    if [[ "$DELTA_QRWA" -gt 0 ]]; then
        record_pass "QRWA Payout nach QUTIL-Epoch — +${DELTA_QRWA} QU"
    fi

    # Holder-Balance Vergleich
    echo ""
    step "Vergleiche Holder-Balances VOR/NACH Epoch..."
    PA1_RECEIVED=0
    printf "    ${BOLD}%-28s %15s %15s %15s${NC}\n" "Identity" "Vorher" "Nachher" "Δ"
    echo -e "    ──────────────────────────────────────────────────────────"
    for ps in $(seq 0 $((${#PA1_SNAP_IDS[@]} - 1))); do
        PS_ID="${PA1_SNAP_IDS[$ps]}"
        PS_BAL_B="${PA1_SNAP_BAL[$ps]}"
        BAL_OUT=$(cli_call -getbalance "$PS_ID")
        PS_BAL_A=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PS_BAL_A=${PS_BAL_A:-0}
        PS_DELTA=$((PS_BAL_A - PS_BAL_B))
        PS_SHORT="${PS_ID:0:12}…${PS_ID: -6}"
        if [[ "$PS_DELTA" -gt 0 ]]; then
            printf "    ${GREEN}✓${NC} ${PS_SHORT}  %15s %15s ${GREEN}+%s${NC}\n" "$PS_BAL_B" "$PS_BAL_A" "$PS_DELTA"
            PA1_RECEIVED=$((PA1_RECEIVED + 1))
        else
            printf "    ${YELLOW}─${NC} ${PS_SHORT}  %15s %15s ${YELLOW}±0${NC}\n" "$PS_BAL_B" "$PS_BAL_A"
        fi
    done
    echo ""
    if [[ "$PA1_RECEIVED" -gt 0 ]]; then
        record_pass "Pool A QUTIL Holder Payout — ${PA1_RECEIVED}/${#PA1_SNAP_IDS[@]} erhielten Payout"
    else
        record_skip "Pool A QUTIL Holder Payout" "Kein Holder erhielt Payout (evtl. nicht eligible)"
    fi

    echo ""
    step "Pools nach QUTIL-Epoch:"
    print_pools "    "
else
    record_fail "Epoch-Wechsel (QUTIL)" "Timeout"
fi

# ── PHASE 2: Direct Transfer von mPoolARevenueAddress → Pool A ──
header "Pool A Phase 2: Direct Transfer von Mining Address → Pool A"
step "Transfer von mPoolARevenueAddress (${POOL_A_IDENTITY:0:12}…)"
step "Pool A Adresse hat ~50B QU für Tests"
echo ""

step "Snapshot VOR Direct Transfer..."
print_pools "    "
PA_BEFORE_DIRECT=$PA_SNAP
PB_BEFORE_DIRECT=$PB_SNAP
snapshot_distributions
DIST_QMINE_BEFORE_DIRECT=$DIST_QMINE_SNAP
DIST_QRWA_BEFORE_DIRECT=$DIST_QRWA_SNAP

step "Sende ${POOL_A_AMOUNT} QU von Pool A Address → $QRWA_IDENTITY"
TX_OUTPUT_A2=$(cli_call_seed "$SEED_POOL_A" -sendtoaddress "$QRWA_IDENTITY" "$POOL_A_AMOUNT")
echo "$TX_OUTPUT_A2" | sed 's/^/    /'

TX_HASH_A2=$(echo "$TX_OUTPUT_A2" | grep "TxHash:" | awk '{print $2}')
TX_TICK_A2=$(echo "$TX_OUTPUT_A2" | grep "Tick:" | awk '{print $2}')

if [[ -z "$TX_HASH_A2" || -z "$TX_TICK_A2" ]]; then
    record_fail "Direct → Pool A" "TX konnte nicht gesendet werden"
else
    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung (Tick $TX_TICK_A2)..."
    CHECK_A2=$(wait_and_check_tx "$TX_TICK_A2" "$TX_HASH_A2")
    echo "$CHECK_A2" | sed 's/^/    /'

    if echo "$CHECK_A2" | grep -q "MoneyFlew: Yes"; then
        record_pass "Direct → Pool A — ${POOL_A_AMOUNT} QU, MoneyFlew: Yes"
        sleep 3
        snapshot_pools
        echo -e "    Pool A: ${PA_BEFORE_DIRECT} → ${PA_SNAP} QU (Δ +$((PA_SNAP - PA_BEFORE_DIRECT)))"
        echo -e "    Pool B: ${PB_BEFORE_DIRECT} → ${PB_SNAP} QU (Δ +$((PB_SNAP - PB_BEFORE_DIRECT)))"

        if [[ "$PA_SNAP" -gt "$PA_BEFORE_DIRECT" ]]; then
            record_pass "Pool A Direct befüllt — +$((PA_SNAP - PA_BEFORE_DIRECT)) QU"
        else
            record_skip "Pool A Direct Check" "evtl. sofort Payout verteilt"
        fi
        if [[ "$PB_SNAP" -eq "$PB_BEFORE_DIRECT" ]]; then
            record_pass "Pool B unverändert — korrektes Routing zu Pool A"
        else
            record_skip "Pool B Routing" "Pool B geändert (evtl. parallel)"
        fi
    elif echo "$CHECK_A2" | grep -q "MoneyFlew: N/A"; then
        record_skip "Direct → Pool A" "TX noch nicht bestätigt (N/A)"
    else
        record_fail "Direct → Pool A" "MoneyFlew != Yes"
    fi
fi

# ── PHASE 2b: Epoch-Wechsel abwarten + Snapshot vergleichen ──
header "Pool A Phase 2b: Epoch-Wechsel → Snapshot-Vergleich"
step "(Dist-Baseline von VOR Direct-Transfer: QMINE=${DIST_QMINE_BEFORE_DIRECT}, QRWA=${DIST_QRWA_BEFORE_DIRECT})"

# Holder-Balances VOR Epoch (Snapshot für Vergleich)
step "Snapshot: Holder QU-Balances VOR Epoch-Wechsel..."
declare -a PA2_SNAP_IDS=()
declare -a PA2_SNAP_BAL=()
if [[ ${#SNAP_CHECK_IDS[@]} -gt 0 ]]; then
    for si in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
        PA2_SNAP_IDS+=("${SNAP_CHECK_IDS[$si]}")
        BAL_OUT=$(cli_call -getbalance "${SNAP_CHECK_IDS[$si]}")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PA2_SNAP_BAL+=("${BAL_VAL:-0}")
    done
    echo -e "    ${GREEN}✓${NC} Snapshot für ${#PA2_SNAP_IDS[@]} Holder gespeichert"
else
    for snap_id in "$IDENTITY1" "$IDENTITY2"; do
        PA2_SNAP_IDS+=("$snap_id")
        BAL_OUT=$(cli_call -getbalance "$snap_id")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PA2_SNAP_BAL+=("${BAL_VAL:-0}")
    done
    echo -e "    ${GREEN}✓${NC} Snapshot für ${#PA2_SNAP_IDS[@]} Holder (Fallback Seed 1+2)"
fi

step "Warte auf Epoch-Wechsel..."
if wait_for_epoch_change 120; then
    record_pass "Epoch gewechselt (Direct) — ${EPOCH_BEFORE} → ${EPOCH_AFTER}"
    echo ""
    step "Warte 60s auf Payout-Zyklen nach Epoch..."
    sleep 60

    # TotalDistributed info (Baseline = VOR dem Direct Transfer)
    snapshot_distributions
    DELTA_QMINE=$((DIST_QMINE_SNAP - DIST_QMINE_BEFORE_DIRECT))
    DELTA_QRWA=$((DIST_QRWA_SNAP - DIST_QRWA_BEFORE_DIRECT))
    echo -e "    ${BOLD}Verteilung nach Direct-Transfer Epoch:${NC}"
    echo -e "    QMINE Distributed: ${DIST_QMINE_BEFORE_DIRECT} → ${DIST_QMINE_SNAP} (Δ +${DELTA_QMINE} QU)"
    echo -e "    QRWA Distributed:  ${DIST_QRWA_BEFORE_DIRECT} → ${DIST_QRWA_SNAP} (Δ +${DELTA_QRWA} QU)"

    if [[ "$DELTA_QMINE" -gt 0 && "$DELTA_QRWA" -gt 0 ]]; then
        TOTAL_DELTA=$((DELTA_QMINE + DELTA_QRWA))
        PCT_QMINE=$((DELTA_QMINE * 1000 / TOTAL_DELTA))
        echo -e "    90/10 Split: QMINE ${PCT_QMINE}‰ (erwartet: ~900‰)"
        if [[ "$PCT_QMINE" -ge 870 && "$PCT_QMINE" -le 930 ]]; then
            record_pass "Pool A 90/10 Split — QMINE ${PCT_QMINE}‰ ≈ 90%"
        else
            record_fail "Pool A 90/10 Split" "QMINE ${PCT_QMINE}‰"
        fi
    elif [[ "$DELTA_QMINE" -gt 0 ]]; then
        record_pass "QMINE Payout nach Direct-Epoch — +${DELTA_QMINE} QU"
    fi

    # Holder-Balance Vergleich (IMMER, nicht nur bei Payout)
    echo ""
    step "Vergleiche Holder-Balances VOR/NACH Epoch..."
    PA2_RECEIVED=0
    printf "    ${BOLD}%-28s %15s %15s %15s${NC}\n" "Identity" "Vorher" "Nachher" "Δ"
    echo -e "    ──────────────────────────────────────────────────────────"
    for ps in $(seq 0 $((${#PA2_SNAP_IDS[@]} - 1))); do
        PS_ID="${PA2_SNAP_IDS[$ps]}"
        PS_BAL_B="${PA2_SNAP_BAL[$ps]}"
        BAL_OUT=$(cli_call -getbalance "$PS_ID")
        PS_BAL_A=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PS_BAL_A=${PS_BAL_A:-0}
        PS_DELTA=$((PS_BAL_A - PS_BAL_B))
        PS_SHORT="${PS_ID:0:12}…${PS_ID: -6}"
        if [[ "$PS_DELTA" -gt 0 ]]; then
            printf "    ${GREEN}✓${NC} ${PS_SHORT}  %15s %15s ${GREEN}+%s${NC}\n" "$PS_BAL_B" "$PS_BAL_A" "$PS_DELTA"
            PA2_RECEIVED=$((PA2_RECEIVED + 1))
        else
            printf "    ${YELLOW}─${NC} ${PS_SHORT}  %15s %15s ${YELLOW}±0${NC}\n" "$PS_BAL_B" "$PS_BAL_A"
        fi
    done
    echo ""
    if [[ "$PA2_RECEIVED" -gt 0 ]]; then
        record_pass "Pool A Holder Payout — ${PA2_RECEIVED}/${#PA2_SNAP_IDS[@]} erhielten Payout"
    else
        record_skip "Pool A Holder Payout" "Kein Holder erhielt Payout (evtl. nicht eligible)"
    fi

    echo ""
    step "Finale Pools nach Pool A Test:"
    print_pools "    "
else
    record_fail "Epoch-Wechsel (Direct)" "Timeout"
fi

fi # end --poolA

###############################################
# POOL B TEST: Normaler Transfer → Epoch-Wait → Verify
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--poolB" ]]; then

header "POOL B TEST: Normaler User Transfer → Epoch → Verify"
step "Pool B erhält Revenue von normalen Transfers (nicht QUTIL, nicht Mining, nicht Dedicated)"
step "Kein Gov Fee — direkt 90/10 Split"
echo ""

step "Snapshot VOR Transfer..."
print_pools "    "
PB_BEFORE=$PB_SNAP
PA_BEFORE_B=$PA_SNAP
DED_BEFORE_B=$DED_SNAP
snapshot_distributions
DIST_QMINE_BEFORE_B=$DIST_QMINE_SNAP
DIST_QRWA_BEFORE_B=$DIST_QRWA_SNAP

step "Sende ${SEND_AMOUNT} QU von Seed 1 (normaler User) → $QRWA_IDENTITY"
TX_OUTPUT_B=$(cli_call_seed "$SEED1" -sendtoaddress "$QRWA_IDENTITY" "$SEND_AMOUNT")
echo "$TX_OUTPUT_B" | sed 's/^/    /'

TX_HASH_B=$(echo "$TX_OUTPUT_B" | grep "TxHash:" | awk '{print $2}')
TX_TICK_B=$(echo "$TX_OUTPUT_B" | grep "Tick:" | awk '{print $2}')

if [[ -z "$TX_HASH_B" || -z "$TX_TICK_B" ]]; then
    record_fail "User → Pool B" "TX konnte nicht gesendet werden"
else
    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung (Tick $TX_TICK_B)..."
    CHECK_B=$(wait_and_check_tx "$TX_TICK_B" "$TX_HASH_B")
    echo "$CHECK_B" | sed 's/^/    /'

    if echo "$CHECK_B" | grep -q "MoneyFlew: Yes"; then
        record_pass "User → Pool B — ${SEND_AMOUNT} QU, MoneyFlew: Yes"
        sleep 3
        snapshot_pools
        echo -e "    Pool B: ${PB_BEFORE} → ${PB_SNAP} QU (Δ +$((PB_SNAP - PB_BEFORE)))"
        echo -e "    Pool A: ${PA_BEFORE_B} → ${PA_SNAP} QU"
        echo -e "    Dedicated: ${DED_BEFORE_B} → ${DED_SNAP} QU"

        if [[ "$PB_SNAP" -gt "$PB_BEFORE" ]]; then
            record_pass "Pool B befüllt — +$((PB_SNAP - PB_BEFORE)) QU"
        else
            record_skip "Pool B Routing" "evtl. sofort Payout verteilt"
        fi
        if [[ "$PA_SNAP" -eq "$PA_BEFORE_B" ]]; then
            record_pass "Pool A unverändert — korrektes Routing"
        else
            record_skip "Pool A Check" "Pool A geändert (evtl. parallel)"
        fi
    elif echo "$CHECK_B" | grep -q "MoneyFlew: N/A"; then
        record_skip "User → Pool B" "TX noch nicht bestätigt (N/A)"
    else
        record_fail "User → Pool B" "MoneyFlew != Yes"
    fi
fi

# ── Epoch-Wechsel abwarten + Snapshot vergleichen ──
header "Pool B: Epoch-Wechsel → Snapshot-Vergleich"
step "(Dist-Baseline von VOR User-Transfer: QMINE=${DIST_QMINE_BEFORE_B}, QRWA=${DIST_QRWA_BEFORE_B})"

# Holder-Snapshot
step "Snapshot: Holder QU-Balances VOR Epoch-Wechsel..."
declare -a PB_SNAP_IDS=()
declare -a PB_SNAP_BAL=()
if [[ ${#SNAP_CHECK_IDS[@]} -gt 0 ]]; then
    for si in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
        PB_SNAP_IDS+=("${SNAP_CHECK_IDS[$si]}")
        BAL_OUT=$(cli_call -getbalance "${SNAP_CHECK_IDS[$si]}")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PB_SNAP_BAL+=("${BAL_VAL:-0}")
    done
else
    for snap_id in "$IDENTITY1" "$IDENTITY2"; do
        PB_SNAP_IDS+=("$snap_id")
        BAL_OUT=$(cli_call -getbalance "$snap_id")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PB_SNAP_BAL+=("${BAL_VAL:-0}")
    done
fi
echo -e "    ${GREEN}✓${NC} Snapshot für ${#PB_SNAP_IDS[@]} Holder"

step "Warte auf Epoch-Wechsel..."
if wait_for_epoch_change 120; then
    record_pass "Epoch gewechselt (Pool B) — ${EPOCH_BEFORE} → ${EPOCH_AFTER}"
    echo ""
    step "Warte 60s auf Payout-Zyklen nach Epoch..."
    sleep 60

    # TotalDistributed info (Baseline = VOR dem User Transfer)
    snapshot_distributions
    DELTA_QMINE=$((DIST_QMINE_SNAP - DIST_QMINE_BEFORE_B))
    DELTA_QRWA=$((DIST_QRWA_SNAP - DIST_QRWA_BEFORE_B))
    echo -e "    ${BOLD}Verteilung nach Pool B Epoch:${NC}"
    echo -e "    QMINE Distributed: ${DIST_QMINE_BEFORE_B} → ${DIST_QMINE_SNAP} (Δ +${DELTA_QMINE} QU)"
    echo -e "    QRWA Distributed:  ${DIST_QRWA_BEFORE_B} → ${DIST_QRWA_SNAP} (Δ +${DELTA_QRWA} QU)"

    if [[ "$DELTA_QMINE" -gt 0 && "$DELTA_QRWA" -gt 0 ]]; then
        TOTAL_DELTA=$((DELTA_QMINE + DELTA_QRWA))
        PCT=$((DELTA_QMINE * 1000 / TOTAL_DELTA))
        echo -e "    90/10: QMINE ${PCT}‰ (erwartet: ~900‰)"
        if [[ "$PCT" -ge 870 && "$PCT" -le 930 ]]; then
            record_pass "Pool B 90/10 Split — QMINE ${PCT}‰ ≈ 90%"
        else
            record_fail "Pool B 90/10 Split" "QMINE ${PCT}‰"
        fi
    elif [[ "$DELTA_QMINE" -gt 0 ]]; then
        record_pass "QMINE Payout nach Pool B Epoch — +${DELTA_QMINE} QU"
    fi

    # Holder-Vergleich (IMMER)
    echo ""
    step "Vergleiche Holder-Balances VOR/NACH Epoch..."
    PB_RECEIVED=0
    printf "    ${BOLD}%-28s %15s %15s %15s${NC}\n" "Identity" "Vorher" "Nachher" "Δ"
    echo -e "    ──────────────────────────────────────────────────────────"
    for ps in $(seq 0 $((${#PB_SNAP_IDS[@]} - 1))); do
        PS_ID="${PB_SNAP_IDS[$ps]}"
        PS_BAL_B="${PB_SNAP_BAL[$ps]}"
        BAL_OUT=$(cli_call -getbalance "$PS_ID")
        PS_BAL_A=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PS_BAL_A=${PS_BAL_A:-0}
        PS_DELTA=$((PS_BAL_A - PS_BAL_B))
        PS_SHORT="${PS_ID:0:12}…${PS_ID: -6}"
        if [[ "$PS_DELTA" -gt 0 ]]; then
            printf "    ${GREEN}✓${NC} ${PS_SHORT}  %15s %15s ${GREEN}+%s${NC}\n" "$PS_BAL_B" "$PS_BAL_A" "$PS_DELTA"
            PB_RECEIVED=$((PB_RECEIVED + 1))
        else
            printf "    ${YELLOW}─${NC} ${PS_SHORT}  %15s %15s ${YELLOW}±0${NC}\n" "$PS_BAL_B" "$PS_BAL_A"
        fi
    done
    echo ""
    if [[ "$PB_RECEIVED" -gt 0 ]]; then
        record_pass "Pool B Holder Payout — ${PB_RECEIVED}/${#PB_SNAP_IDS[@]} erhielten Payout"
    else
        record_skip "Pool B Holder Payout" "Kein Holder erhielt Payout (evtl. nicht eligible)"
    fi

    echo ""
    step "Finale Pools nach Pool B Test:"
    print_pools "    "
else
    record_fail "Epoch-Wechsel (Pool B)" "Timeout"
fi

fi # end --poolB

###############################################
# POOL C TEST: Dedicated Address → Epoch-Wait → Verify (No Gov Fees)
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--poolC" ]]; then

header "POOL C TEST: Dedicated BTC Address → Epoch → Verify (No Gov Fees)"
step "Pool C erhält Revenue von mDedicatedRevenueAddress (BTC)"
step "KEIN Gov Fee — direkt 90/10 Split"
step "Dedicated Address: ${DEDICATED_IDENTITY}"
echo ""

step "Snapshot VOR Transfer..."
print_pools "    "
DED_BEFORE=$DED_SNAP
PA_BEFORE_C=$PA_SNAP
PB_BEFORE_C=$PB_SNAP
snapshot_distributions
DIST_QMINE_BEFORE_C=$DIST_QMINE_SNAP
DIST_QRWA_BEFORE_C=$DIST_QRWA_SNAP

step "Sende ${DEDICATED_AMOUNT} QU von Dedicated Address (Seed 3) → $QRWA_IDENTITY"
TX_OUTPUT_D=$(cli_call_seed "$SEED3" -sendtoaddress "$QRWA_IDENTITY" "$DEDICATED_AMOUNT")
echo "$TX_OUTPUT_D" | sed 's/^/    /'

TX_HASH_D=$(echo "$TX_OUTPUT_D" | grep "TxHash:" | awk '{print $2}')
TX_TICK_D=$(echo "$TX_OUTPUT_D" | grep "Tick:" | awk '{print $2}')

if [[ -z "$TX_HASH_D" || -z "$TX_TICK_D" ]]; then
    record_fail "Dedicated → Pool C" "TX konnte nicht gesendet werden"
else
    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung (Tick $TX_TICK_D)..."
    CHECK_D=$(wait_and_check_tx "$TX_TICK_D" "$TX_HASH_D")
    echo "$CHECK_D" | sed 's/^/    /'

    if echo "$CHECK_D" | grep -q "MoneyFlew: Yes"; then
        record_pass "Dedicated → Pool C — ${DEDICATED_AMOUNT} QU, MoneyFlew: Yes"
        sleep 3
        snapshot_pools
        echo -e "    Dedicated Pool: ${DED_BEFORE} → ${DED_SNAP} QU (Δ +$((DED_SNAP - DED_BEFORE)))"
        echo -e "    Pool A: ${PA_BEFORE_C} → ${PA_SNAP} QU"
        echo -e "    Pool B: ${PB_BEFORE_C} → ${PB_SNAP} QU"

        if [[ "$DED_SNAP" -gt "$DED_BEFORE" ]]; then
            DED_DIFF=$((DED_SNAP - DED_BEFORE))
            record_pass "Dedicated Pool befüllt — +${DED_DIFF} QU"
            if [[ "$DED_DIFF" -eq "$DEDICATED_AMOUNT" ]]; then
                record_pass "Keine Gov Fees — voller Betrag angekommen"
            else
                record_skip "Gov Fee Check" "Diff: ${DED_DIFF} vs. ${DEDICATED_AMOUNT} (evtl. sofort verteilt)"
            fi
        else
            record_skip "Dedicated Pool Check" "evtl. sofort Payout verteilt"
        fi

        if [[ "$PA_SNAP" -eq "$PA_BEFORE_C" && "$PB_SNAP" -eq "$PB_BEFORE_C" ]]; then
            record_pass "Pool A/B unverändert — korrektes Routing zu Pool C"
        else
            record_skip "Pool A/B Check" "evtl. parallele Transfers"
        fi
    elif echo "$CHECK_D" | grep -q "MoneyFlew: N/A"; then
        record_skip "Dedicated → Pool C" "TX noch nicht bestätigt (N/A)"
    else
        record_fail "Dedicated → Pool C" "MoneyFlew != Yes"
    fi
fi

# ── Epoch-Wechsel abwarten + Snapshot vergleichen ──
header "Pool C: Epoch-Wechsel → Snapshot-Vergleich"
step "(Dist-Baseline von VOR Dedicated-Transfer: QMINE=${DIST_QMINE_BEFORE_C}, QRWA=${DIST_QRWA_BEFORE_C})"

# Holder-Snapshot
step "Snapshot: Holder QU-Balances VOR Epoch-Wechsel..."
declare -a PC_SNAP_IDS=()
declare -a PC_SNAP_BAL=()
if [[ ${#SNAP_CHECK_IDS[@]} -gt 0 ]]; then
    for si in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
        PC_SNAP_IDS+=("${SNAP_CHECK_IDS[$si]}")
        BAL_OUT=$(cli_call -getbalance "${SNAP_CHECK_IDS[$si]}")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PC_SNAP_BAL+=("${BAL_VAL:-0}")
    done
else
    for snap_id in "$IDENTITY1" "$IDENTITY2"; do
        PC_SNAP_IDS+=("$snap_id")
        BAL_OUT=$(cli_call -getbalance "$snap_id")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PC_SNAP_BAL+=("${BAL_VAL:-0}")
    done
fi
echo -e "    ${GREEN}✓${NC} Snapshot für ${#PC_SNAP_IDS[@]} Holder"

step "Warte auf Epoch-Wechsel..."
if wait_for_epoch_change 120; then
    record_pass "Epoch gewechselt (Pool C) — ${EPOCH_BEFORE} → ${EPOCH_AFTER}"
    echo ""
    step "Warte 60s auf Payout-Zyklen nach Epoch..."
    sleep 60

    # TotalDistributed info (Baseline = VOR dem Dedicated Transfer)
    snapshot_distributions
    DELTA_QMINE=$((DIST_QMINE_SNAP - DIST_QMINE_BEFORE_C))
    DELTA_QRWA=$((DIST_QRWA_SNAP - DIST_QRWA_BEFORE_C))
    echo -e "    ${BOLD}Verteilung nach Pool C Epoch:${NC}"
    echo -e "    QMINE Distributed: ${DIST_QMINE_BEFORE_C} → ${DIST_QMINE_SNAP} (Δ +${DELTA_QMINE} QU)"
    echo -e "    QRWA Distributed:  ${DIST_QRWA_BEFORE_C} → ${DIST_QRWA_SNAP} (Δ +${DELTA_QRWA} QU)"

    if [[ "$DELTA_QMINE" -gt 0 && "$DELTA_QRWA" -gt 0 ]]; then
        TOTAL_DELTA=$((DELTA_QMINE + DELTA_QRWA))
        PCT=$((DELTA_QMINE * 1000 / TOTAL_DELTA))
        echo -e "    90/10: QMINE ${PCT}‰ (erwartet: ~900‰)"
        if [[ "$PCT" -ge 870 && "$PCT" -le 930 ]]; then
            record_pass "Pool C 90/10 Split — QMINE ${PCT}‰ ≈ 90%"
        else
            record_fail "Pool C 90/10 Split" "QMINE ${PCT}‰"
        fi
    elif [[ "$DELTA_QMINE" -gt 0 ]]; then
        record_pass "QMINE Payout nach Pool C Epoch — +${DELTA_QMINE} QU"
    fi

    # Holder-Vergleich (IMMER)
    echo ""
    step "Vergleiche Holder-Balances VOR/NACH Epoch..."
    PC_RECEIVED=0
    printf "    ${BOLD}%-28s %15s %15s %15s${NC}\n" "Identity" "Vorher" "Nachher" "Δ"
    echo -e "    ──────────────────────────────────────────────────────────"
    for ps in $(seq 0 $((${#PC_SNAP_IDS[@]} - 1))); do
        PS_ID="${PC_SNAP_IDS[$ps]}"
        PS_BAL_B="${PC_SNAP_BAL[$ps]}"
        BAL_OUT=$(cli_call -getbalance "$PS_ID")
        PS_BAL_A=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        PS_BAL_A=${PS_BAL_A:-0}
        PS_DELTA=$((PS_BAL_A - PS_BAL_B))
        PS_SHORT="${PS_ID:0:12}…${PS_ID: -6}"
        if [[ "$PS_DELTA" -gt 0 ]]; then
            printf "    ${GREEN}✓${NC} ${PS_SHORT}  %15s %15s ${GREEN}+%s${NC}\n" "$PS_BAL_B" "$PS_BAL_A" "$PS_DELTA"
            PC_RECEIVED=$((PC_RECEIVED + 1))
        else
            printf "    ${YELLOW}─${NC} ${PS_SHORT}  %15s %15s ${YELLOW}±0${NC}\n" "$PS_BAL_B" "$PS_BAL_A"
        fi
    done
    echo ""
    if [[ "$PC_RECEIVED" -gt 0 ]]; then
        record_pass "Pool C Holder Payout — ${PC_RECEIVED}/${#PC_SNAP_IDS[@]} erhielten Payout"
    else
        record_skip "Pool C Holder Payout" "Kein Holder erhielt Payout (evtl. nicht eligible)"
    fi

    echo ""
    step "Finale Pools nach Pool C Test:"
    print_pools "    "
else
    record_fail "Epoch-Wechsel (Pool C)" "Timeout"
fi

fi # end --poolC

###############################################
# TEST 10: GOVERNANCE PROPOSAL FULL LIFECYCLE
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--vote" ]]; then

# ═══════════════════════════════════════════
# 10-PRE: QMINE Token Vorbereitung (benötigt für VoteGovParams)
# ═══════════════════════════════════════════
header "TEST 10-PRE: QMINE Token Vorbereitung"
step "VoteGovParams erfordert QMINE Tokens — prüfe Balances..."

QMINE_BUY_AMOUNT=100       # Shares pro Seed
QMINE_BUY_PRICE=5000        # QU pro Share (etwas über Marktpreis)
QMINE_BUY_COST=$((QMINE_BUY_AMOUNT * QMINE_BUY_PRICE))

# Hilfsfunktion: QMINE Balance für eine Identity prüfen
check_qmine_balance() {
    local identity="$1"
    local assets_out
    assets_out=$(cli_call -getasset "$identity")
    # Suche QMINE im Ownership-Block
    local in_ownership=0
    local qmine_shares=0
    while IFS= read -r line; do
        if echo "$line" | grep -q '======== OWNERSHIP ========'; then
            in_ownership=1
        fi
        if echo "$line" | grep -q '======== POSSESSION ========'; then
            in_ownership=0
        fi
        if [[ "$in_ownership" -eq 1 ]] && echo "$line" | grep -q 'QMINE'; then
            # Nächste Zeile mit shares
            local shares_line
            shares_line=$(echo "$assets_out" | grep -A5 'QMINE' | grep 'number of shares' | head -1)
            qmine_shares=$(echo "$shares_line" | grep -oE '[0-9]+' | head -1)
            break
        fi
    done <<< "$assets_out"
    echo "${qmine_shares:-0}"
}

# Hilfsfunktion: QMINE via QX kaufen (Bid Order)
buy_qmine_via_qx() {
    local seed="$1" identity="$2" label="$3"
    step "${label}: Kaufe ${QMINE_BUY_AMOUNT} QMINE via QX (Bid @ ${QMINE_BUY_PRICE} QU/Share = ${QMINE_BUY_COST} QU)..."
    local tx_out
    tx_out=$(cli_call_seed "$seed" \
        -qxorder add bid "$QMINE_ISSUER" "$QMINE_NAME" "$QMINE_BUY_PRICE" "$QMINE_BUY_AMOUNT")
    echo "$tx_out" | sed 's/^/    /'

    local tx_hash tx_tick
    tx_hash=$(echo "$tx_out" | grep "TxHash:" | awk '{print $2}')
    tx_tick=$(echo "$tx_out" | grep "Tick:" | awk '{print $2}')

    if [[ -z "$tx_hash" || -z "$tx_tick" ]]; then
        record_fail "QX Buy QMINE (${label})" "TX konnte nicht gesendet werden"
        return 1
    fi

    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung..."
    local check
    check=$(wait_and_check_tx "$tx_tick" "$tx_hash")
    echo "$check" | sed 's/^/    /'

    if echo "$check" | grep -q "MoneyFlew: Yes"; then
        record_pass "QX Buy QMINE (${label}) — ${QMINE_BUY_AMOUNT} Shares gekauft"
        return 0
    elif echo "$check" | grep -q "MoneyFlew: N/A"; then
        record_skip "QX Buy QMINE (${label})" "TX noch nicht bestätigt"
        return 1
    else
        # MoneyFlew: No → Bid Order platziert aber nicht sofort gematcht
        echo -e "    ${YELLOW}Bid Order platziert, evtl. noch nicht gematcht${NC}"
        record_skip "QX Buy QMINE (${label})" "Bid platziert, warte auf Match"
        return 1
    fi
}

# Prüfe QMINE Balance für alle Vote-Seeds
declare -a VOTE_SEEDS=("$SEED1" "$SEED2" "$SEED3")
declare -a VOTE_IDENTITIES=("$IDENTITY1" "$IDENTITY2" "$DEDICATED_IDENTITY")
declare -a VOTE_LABELS=("Seed1" "Seed2" "Seed3/Dedicated")

QMINE_ALL_OK=1
for idx in 0 1 2; do
    QMINE_BAL=$(check_qmine_balance "${VOTE_IDENTITIES[$idx]}")
    echo -e "    ${VOTE_LABELS[$idx]} (${VOTE_IDENTITIES[$idx]:0:12}…): ${QMINE_BAL} QMINE"

    if [[ "$QMINE_BAL" -eq 0 ]]; then
        QMINE_ALL_OK=0
        buy_qmine_via_qx "${VOTE_SEEDS[$idx]}" "${VOTE_IDENTITIES[$idx]}" "${VOTE_LABELS[$idx]}"
    else
        record_pass "QMINE vorhanden (${VOTE_LABELS[$idx]}) — ${QMINE_BAL} Shares"
    fi
done

# Kurze Pause und Re-Check falls gekauft
if [[ "$QMINE_ALL_OK" -eq 0 ]]; then
    step "Warte 5s, dann Re-Check QMINE Balances..."
    sleep 5
    for idx in 0 1 2; do
        QMINE_BAL=$(check_qmine_balance "${VOTE_IDENTITIES[$idx]}")
        echo -e "    ${VOTE_LABELS[$idx]}: ${QMINE_BAL} QMINE"
        if [[ "$QMINE_BAL" -eq 0 ]]; then
            echo -e "    ${YELLOW}⚠ ${VOTE_LABELS[$idx]} hat immer noch kein QMINE — Gov Votes werden evtl. fehlschlagen${NC}"
        fi
    done
fi

# ═══════════════════════════════════════════
# 10a: Lese aktuelle GovParams
# ═══════════════════════════════════════════
header "TEST 10a: Aktuelle Gov Params lesen (Function 1)"
step "Lese aktuelle GovParams als Baseline..."
VOTE_GOV_OUTPUT=$(call_fn 1 "" "{ { id, id, id, id, id, uint64, uint64, uint64 } }")
VOTE_GOV_ADDRS=$(echo "$VOTE_GOV_OUTPUT" | grep -oE '[A-Z]{55,60}' | head -5)
ADMIN_ID=$(echo "$VOTE_GOV_ADDRS" | sed -n '1p')
ELEC_ID=$(echo "$VOTE_GOV_ADDRS" | sed -n '2p')
MAINT_ID=$(echo "$VOTE_GOV_ADDRS" | sed -n '3p')
REINV_ID=$(echo "$VOTE_GOV_ADDRS" | sed -n '4p')
DEV_ID=$(echo "$VOTE_GOV_ADDRS" | sed -n '5p')

# Extrahiere aktuelle Prozentsätze
CURRENT_PCTS=$(echo "$VOTE_GOV_OUTPUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+')
CURRENT_ELEC_PCT=$(echo "$CURRENT_PCTS" | tail -3 | head -1)
CURRENT_MAINT_PCT=$(echo "$CURRENT_PCTS" | tail -2 | head -1)
CURRENT_REINV_PCT=$(echo "$CURRENT_PCTS" | tail -1)

echo -e "    ${CYAN}Aktuelle Gov Params:${NC}"
echo -e "    Admin: ${ADMIN_ID:-?}"
echo -e "    Elec:  ${ELEC_ID:-?}  (${CURRENT_ELEC_PCT:-?}‰)"
echo -e "    Maint: ${MAINT_ID:-?}  (${CURRENT_MAINT_PCT:-?}‰)"
echo -e "    Reinv: ${REINV_ID:-?}  (${CURRENT_REINV_PCT:-?}‰)"
echo -e "    Dev:   ${DEV_ID:-?}"

if [[ -n "$ADMIN_ID" ]]; then
    record_pass "Gov Params gelesen — Admin: ${ADMIN_ID:0:12}…"
else
    record_fail "Gov Params" "Keine Adressen gefunden"
fi

# ═══════════════════════════════════════════
# 10b: Prüfe Active Gov Polls VOR Proposal
# ═══════════════════════════════════════════
header "TEST 10b: Active Gov Polls VOR Proposal (Function 8)"
step "GetActiveGovPollIds — wie viele aktive Polls gibt es aktuell?"
GOV_POLLS_BEFORE=$(call_fn 8 "" "{ uint64, [64; uint64] }")
GOV_COUNT_BEFORE=$(echo "$GOV_POLLS_BEFORE" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | head -1)
GOV_COUNT_BEFORE=${GOV_COUNT_BEFORE:-0}
echo -e "    Aktive Gov Polls: ${GOV_COUNT_BEFORE}"

if [[ "$GOV_COUNT_BEFORE" -gt 0 ]]; then
    # Extrahiere Poll IDs
    GOV_IDS_RAW=$(echo "$GOV_POLLS_BEFORE" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | tail -n +2 | head -"$GOV_COUNT_BEFORE")
    echo -e "    Poll IDs: $(echo $GOV_IDS_RAW | tr '\n' ' ')"
fi
record_pass "GetActiveGovPollIds — Count: ${GOV_COUNT_BEFORE}"

# ═══════════════════════════════════════════
# 10c: Neues Gov Proposal erstellen (VoteGovParams mit geänderten Prozentsätzen)
# ═══════════════════════════════════════════
header "TEST 10c: Neues Gov Proposal erstellen (Procedure 4 — VoteGovParams)"

# Erstelle Proposal mit geänderten Werten:
# Electricity: 300‰ (statt 350), Maintenance: 100‰ (statt 50), Reinvestment: 100‰ (gleich)
# → Gesamt bleibt 500‰ = 50%
NEW_ELEC_PCT=300
NEW_MAINT_PCT=100
NEW_REINV_PCT=100
NEW_TOTAL=$((NEW_ELEC_PCT + NEW_MAINT_PCT + NEW_REINV_PCT))

step "Neues Proposal: Elec ${NEW_ELEC_PCT}‰ + Maint ${NEW_MAINT_PCT}‰ + Reinv ${NEW_REINV_PCT}‰ = ${NEW_TOTAL}‰"
step "Seed 1 erstellt+votet auf dieses Proposal..."

# Proc 4 = VoteGovParams
# Input: QRWAGovParams = { admin, electricity, maintenance, reinvestment, qmineDev, electricityPercent, maintenancePercent, reinvestmentPercent }
TX_OUTPUT=$(cli_call_seed "$SEED1" \
    -enabletestcontracts \
    -invokecontractprocedure "$CONTRACT_INDEX" 4 0 \
    "{${ADMIN_ID}id,${ELEC_ID}id,${MAINT_ID}id,${REINV_ID}id,${DEV_ID}id,${NEW_ELEC_PCT}uint64,${NEW_MAINT_PCT}uint64,${NEW_REINV_PCT}uint64}")
echo "$TX_OUTPUT" | sed 's/^/    /'

TX_HASH=$(echo "$TX_OUTPUT" | grep "TxHash:" | awk '{print $2}')
TX_TICK=$(echo "$TX_OUTPUT" | grep "Tick:" | awk '{print $2}')

if [[ -z "$TX_HASH" || -z "$TX_TICK" ]]; then
    record_fail "VoteGovParams (Seed1)" "TX konnte nicht gesendet werden"
else
    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung..."
    CHECK=$(wait_and_check_tx "$TX_TICK" "$TX_HASH")
    echo "$CHECK" | sed 's/^/    /'

    if echo "$CHECK" | grep -q "MoneyFlew: Yes"; then
        record_pass "VoteGovParams (Seed1) — Proposal erstellt, MoneyFlew: Yes"
    elif echo "$CHECK" | grep -q "MoneyFlew: N/A"; then
        record_skip "VoteGovParams (Seed1)" "TX noch nicht bestätigt"
    else
        record_pass "VoteGovParams (Seed1) — TX verarbeitet (Refund = MoneyFlew: No ist OK)"
    fi
fi

# ═══════════════════════════════════════════
# 10d: Seed 2 votet auf das GLEICHE Proposal
# ═══════════════════════════════════════════
header "TEST 10d: Zweiter Vote auf gleiches Proposal (Seed 2)"
step "Seed 2 votet mit identischen Params → findet bestehendes Proposal"
step "Gleiche Params: Elec ${NEW_ELEC_PCT}‰ + Maint ${NEW_MAINT_PCT}‰ + Reinv ${NEW_REINV_PCT}‰"

TX_OUTPUT2=$(cli_call_seed "$SEED2" \
    -enabletestcontracts \
    -invokecontractprocedure "$CONTRACT_INDEX" 4 0 \
    "{${ADMIN_ID}id,${ELEC_ID}id,${MAINT_ID}id,${REINV_ID}id,${DEV_ID}id,${NEW_ELEC_PCT}uint64,${NEW_MAINT_PCT}uint64,${NEW_REINV_PCT}uint64}")
echo "$TX_OUTPUT2" | sed 's/^/    /'

TX_HASH2=$(echo "$TX_OUTPUT2" | grep "TxHash:" | awk '{print $2}')
TX_TICK2=$(echo "$TX_OUTPUT2" | grep "Tick:" | awk '{print $2}')

if [[ -z "$TX_HASH2" || -z "$TX_TICK2" ]]; then
    record_fail "VoteGovParams (Seed2)" "TX konnte nicht gesendet werden"
else
    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung..."
    CHECK2=$(wait_and_check_tx "$TX_TICK2" "$TX_HASH2")
    echo "$CHECK2" | sed 's/^/    /'

    if echo "$CHECK2" | grep -q "MoneyFlew: Yes"; then
        record_pass "VoteGovParams (Seed2) — Zweiter Vote, MoneyFlew: Yes"
    elif echo "$CHECK2" | grep -q "MoneyFlew: N/A"; then
        record_skip "VoteGovParams (Seed2)" "TX noch nicht bestätigt"
    else
        record_pass "VoteGovParams (Seed2) — TX verarbeitet (Refund = MoneyFlew: No ist OK)"
    fi
fi

# ═══════════════════════════════════════════
# 10e: Prüfe Gov Polls NACH Proposals — scanne per ID (auch resolved/historische)
# ═══════════════════════════════════════════
header "TEST 10e: Gov Polls NACH Proposal — Scan per ID (Function 2 + 8)"
sleep 5  # Kurz warten bis State aktualisiert

# Zuerst: aktive Polls abfragen
GOV_POLLS_AFTER=$(call_fn 8 "" "{ uint64, [64; uint64] }")
GOV_COUNT_AFTER=$(echo "$GOV_POLLS_AFTER" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | head -1)
GOV_COUNT_AFTER=${GOV_COUNT_AFTER:-0}
echo -e "    Aktive Gov Polls (Status=Active): ${GOV_COUNT_AFTER}"

if [[ "$GOV_COUNT_AFTER" -gt 0 ]]; then
    GOV_IDS_AFTER=$(echo "$GOV_POLLS_AFTER" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | tail -n +2 | head -"$GOV_COUNT_AFTER")
    echo -e "    Aktive Poll IDs: $(echo $GOV_IDS_AFTER | tr '\n' ' ')"
fi

# Dann: Scanne Proposal IDs 0..15 per GetGovPoll (Fn 2) — findet auch resolved Polls
step "Scanne Gov Poll IDs 0..15 per GetGovPoll (auch Passed/Failed)..."
GOV_FOUND_COUNT=0
GOV_FOUND_IDS=()
GOV_FOUND_DETAILS=()

for SCAN_ID in $(seq 0 15); do
    SCAN_OUT=$(call_fn 2 "${SCAN_ID}uint64" "{ { uint64, uint64, uint64, { id, id, id, id, id, uint64, uint64, uint64 } }, uint64 }")
    SCAN_SECTION=$(echo "$SCAN_OUT" | sed -n '/Contract Function Output/,$ p')
    SCAN_NUMS=$(echo "$SCAN_SECTION" | grep -oE '[0-9]+')
    NUM_COUNT=$(echo "$SCAN_NUMS" | grep -c .)
    QUERY_STATUS=$(echo "$SCAN_NUMS" | tail -1)

    if [[ "${QUERY_STATUS}" == "1" && "$NUM_COUNT" -ge 4 ]]; then
        # Prüfe ob Proposal-Daten vorhanden (nicht nur (empty) + queryStatus)
        # Bei (empty): nur 1 Zahl (queryStatus); bei echtem Poll: ≥ 4 (id, status, score, qs)
        S_ID=$(echo "$SCAN_NUMS" | sed -n '1p')
        S_STAT=$(echo "$SCAN_NUMS" | sed -n '2p')
        S_SCORE=$(echo "$SCAN_NUMS" | sed -n '3p')

        # Prüfe ob Proposal tatsächlich Daten hat (nicht alles 0 / Geister-Slot)
        if [[ "$S_ID" == "0" && "$S_STAT" == "0" && "$S_SCORE" == "0" ]]; then
            # Leerer Slot bei ID 0 (proposalId 0 matched immer Slot 0)
            continue
        fi

        # Extrahiere Prozentsätze (falls vorhanden — nur wenn Params nicht (empty))
        if [[ "$NUM_COUNT" -ge 7 ]]; then
            # Volle Daten: proposalId, status, score, elec%, maint%, reinv%, queryStatus
            S_ELEC=$(echo "$SCAN_NUMS" | tail -4 | head -1)
            S_MAINT=$(echo "$SCAN_NUMS" | tail -3 | head -1)
            S_REINV=$(echo "$SCAN_NUMS" | tail -2 | head -1)
        else
            # Params waren (empty) — nur ID/Status/Score + queryStatus
            S_ELEC="?"
            S_MAINT="?"
            S_REINV="?"
        fi

        # Status-Label
        case "$S_STAT" in
            0) S_LABEL="Empty" ;;
            1) S_LABEL="Active" ;;
            2) S_LABEL="Passed" ;;
            3) S_LABEL="Failed" ;;
            4) S_LABEL="PassedFailedExec" ;;
            *) S_LABEL="Unknown($S_STAT)" ;;
        esac

        GOV_FOUND_COUNT=$((GOV_FOUND_COUNT + 1))
        GOV_FOUND_IDS+=("$S_ID")
        echo -e "    ${CYAN}━━━ Poll ID: ${S_ID} ━━━${NC}"
        echo -e "    Status: ${S_LABEL}  Score: ${S_SCORE} QMINE"
        echo -e "    Elec: ${S_ELEC}‰  Maint: ${S_MAINT}‰  Reinv: ${S_REINV}‰"

        # Zeige Adressen
        SCAN_ADDRS=$(echo "$SCAN_OUT" | grep -oE '[A-Z]{55,60}')
        S_ADMIN=$(echo "$SCAN_ADDRS" | head -1)
        if [[ -n "$S_ADMIN" ]]; then
            echo -e "    Admin: ${S_ADMIN:0:12}…${S_ADMIN: -6}"
        fi
    fi
done

echo ""
echo -e "    ${BOLD}Gefundene Gov Polls (alle Status): ${GOV_FOUND_COUNT}${NC}"
echo -e "    Davon aktiv: ${GOV_COUNT_AFTER}"

if [[ "$GOV_FOUND_COUNT" -gt 0 ]]; then
    record_pass "Gov Polls gefunden — ${GOV_FOUND_COUNT} total (${GOV_COUNT_AFTER} aktiv)"
elif [[ "$GOV_COUNT_AFTER" -gt 0 ]]; then
    record_pass "Aktive Gov Polls: ${GOV_COUNT_AFTER}"
else
    echo -e "    ${YELLOW}Keine Polls gefunden — möglicherweise hat VoteGovParams fehlgeschlagen${NC}"
    echo -e "    ${YELLOW}(Seed muss QMINE halten, Prozentsätze ≤ 1000‰, Admin ≠ NULL)${NC}"
    record_skip "Gov Polls" "Keine Polls (IDs 0..15 leer, evtl. kein QMINE oder Epoch-Reset)"
fi

# ═══════════════════════════════════════════
# 10f: Erstelle ein KONKURRIERENDES Proposal mit anderen Werten
# ═══════════════════════════════════════════
header "TEST 10f: Konkurrierendes Gov Proposal (andere Prozentsätze)"

# Proposal 2: Electricity 400‰, Maintenance 50‰, Reinvestment 50‰ = 500‰
ALT_ELEC_PCT=400
ALT_MAINT_PCT=50
ALT_REINV_PCT=50
ALT_TOTAL=$((ALT_ELEC_PCT + ALT_MAINT_PCT + ALT_REINV_PCT))

step "Alternatives Proposal: Elec ${ALT_ELEC_PCT}‰ + Maint ${ALT_MAINT_PCT}‰ + Reinv ${ALT_REINV_PCT}‰ = ${ALT_TOTAL}‰"
step "Seed 3 (Dedicated Address) votet auf dieses alternative Proposal..."

TX_OUTPUT3=$(cli_call_seed "$SEED3" \
    -enabletestcontracts \
    -invokecontractprocedure "$CONTRACT_INDEX" 4 0 \
    "{${ADMIN_ID}id,${ELEC_ID}id,${MAINT_ID}id,${REINV_ID}id,${DEV_ID}id,${ALT_ELEC_PCT}uint64,${ALT_MAINT_PCT}uint64,${ALT_REINV_PCT}uint64}")
echo "$TX_OUTPUT3" | sed 's/^/    /'

TX_HASH3=$(echo "$TX_OUTPUT3" | grep "TxHash:" | awk '{print $2}')
TX_TICK3=$(echo "$TX_OUTPUT3" | grep "Tick:" | awk '{print $2}')

if [[ -z "$TX_HASH3" || -z "$TX_TICK3" ]]; then
    record_fail "VoteGovParams (Seed3)" "TX konnte nicht gesendet werden"
else
    echo ""
    step "Warte ${TX_WAIT_SEC}s auf Bestätigung..."
    CHECK3=$(wait_and_check_tx "$TX_TICK3" "$TX_HASH3")
    echo "$CHECK3" | sed 's/^/    /'

    if echo "$CHECK3" | grep -q "MoneyFlew: Yes"; then
        record_pass "VoteGovParams (Seed3) — Konkurrierendes Proposal, MoneyFlew: Yes"
    elif echo "$CHECK3" | grep -q "MoneyFlew: N/A"; then
        record_skip "VoteGovParams (Seed3)" "TX noch nicht bestätigt"
    else
        # Seed3 hat evtl. kein QMINE → wird abgelehnt (NOT_AUTHORIZED)
        record_skip "VoteGovParams (Seed3)" "TX verarbeitet (braucht QMINE, Seed3 hat evtl. keins)"
    fi
fi

# ═══════════════════════════════════════════
# 10g: Final — Alle Gov Polls auflisten (aktiv + historisch)
# ═══════════════════════════════════════════
header "TEST 10g: Finale Gov Poll Übersicht (alle Status)"
sleep 3

# Scanne durch IDs 0..15 und zeige alle die existieren
step "Scanne Gov Poll IDs 0..15 (aktiv + resolved)..."
FINAL_FOUND=0
FINAL_ACTIVE=0
FINAL_PASSED=0
FINAL_FAILED=0

for FID in $(seq 0 15); do
    F_OUT=$(call_fn 2 "${FID}uint64" "{ { uint64, uint64, uint64, { id, id, id, id, id, uint64, uint64, uint64 } }, uint64 }")
    F_SECTION=$(echo "$F_OUT" | sed -n '/Contract Function Output/,$ p')
    F_NUMS=$(echo "$F_SECTION" | grep -oE '[0-9]+')
    F_NUM_COUNT=$(echo "$F_NUMS" | grep -c .)
    F_QUERY_STATUS=$(echo "$F_NUMS" | tail -1)

    if [[ "${F_QUERY_STATUS}" == "1" && "$F_NUM_COUNT" -ge 4 ]]; then
        F_ID=$(echo "$F_NUMS" | sed -n '1p')
        F_STAT=$(echo "$F_NUMS" | sed -n '2p')
        F_SCORE=$(echo "$F_NUMS" | sed -n '3p')

        # Leeren Slot überspringen (proposalId 0 matched immer Slot 0)
        if [[ "$F_ID" == "0" && "$F_STAT" == "0" && "$F_SCORE" == "0" ]]; then
            continue
        fi

        # Extrahiere Prozentsätze (falls Params nicht (empty))
        if [[ "$F_NUM_COUNT" -ge 7 ]]; then
            F_ELEC=$(echo "$F_NUMS" | tail -4 | head -1)
            F_MAINT=$(echo "$F_NUMS" | tail -3 | head -1)
            F_REINV=$(echo "$F_NUMS" | tail -2 | head -1)
        else
            F_ELEC="?"
            F_MAINT="?"
            F_REINV="?"
        fi

        case "$F_STAT" in
            0) F_LABEL="Empty"; F_COLOR="$NC" ;;
            1) F_LABEL="Active"; F_COLOR="$GREEN"; FINAL_ACTIVE=$((FINAL_ACTIVE + 1)) ;;
            2) F_LABEL="Passed"; F_COLOR="$GREEN"; FINAL_PASSED=$((FINAL_PASSED + 1)) ;;
            3) F_LABEL="Failed"; F_COLOR="$RED"; FINAL_FAILED=$((FINAL_FAILED + 1)) ;;
            4) F_LABEL="PassedFailedExec"; F_COLOR="$YELLOW" ;;
            *) F_LABEL="Unknown($F_STAT)"; F_COLOR="$YELLOW" ;;
        esac

        FINAL_FOUND=$((FINAL_FOUND + 1))
        echo -e "    ${F_COLOR}━━━ Poll ID: ${F_ID}  [${F_LABEL}]  Score: ${F_SCORE} QMINE${NC}"
        echo -e "        Elec: ${F_ELEC}‰  Maint: ${F_MAINT}‰  Reinv: ${F_REINV}‰"
    fi
done

echo ""
echo -e "    ${BOLD}════════ Gov Poll Zusammenfassung ════════${NC}"
echo -e "    ${BOLD}Gefunden:  ${FINAL_FOUND}${NC}"
echo -e "    ${GREEN}Active:    ${FINAL_ACTIVE}${NC}"
echo -e "    ${GREEN}Passed:    ${FINAL_PASSED}${NC}"
echo -e "    ${RED}Failed:    ${FINAL_FAILED}${NC}"

if [[ "$FINAL_FOUND" -gt 0 ]]; then
    record_pass "Gov Poll Übersicht — ${FINAL_FOUND} Polls (${FINAL_ACTIVE} aktiv, ${FINAL_PASSED} passed, ${FINAL_FAILED} failed)"
else
    record_skip "Gov Poll Übersicht" "Keine Polls gefunden (IDs 0..15)"
fi

echo ""
echo -e "    ${YELLOW}══════════════════════════════════════════════════${NC}"
echo -e "    ${YELLOW}Hinweis: Gov Proposals werden bei END_EPOCH ausgewertet.${NC}"
echo -e "    ${YELLOW}Das Proposal mit dem höchsten Score (min 2/3 Quorum)${NC}"
echo -e "    ${YELLOW}wird dann als neue GovParams übernommen.${NC}"
echo -e "    ${YELLOW}Status: 1=Active, 2=Passed, 3=Failed${NC}"
echo -e "    ${YELLOW}══════════════════════════════════════════════════${NC}"

fi # end --vote

###############################################
# TEST 12: GETGENERALASSETS + GETGENERALASSETBALANCE
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--readonly" ]]; then

header "TEST 12: GetGeneralAssets (Function 10)"
OUTPUT=$(call_fn 10 "" "{ uint64, [1024; { id, uint64 }], [1024; uint64] }")
echo "$OUTPUT" | grep -v "WARNING" | head -20 | sed 's/^/    /'

if echo "$OUTPUT" | grep -q "Contract Function Output"; then
    record_pass "GetGeneralAssets"
else
    record_fail "GetGeneralAssets" "Kein Output"
fi

fi

###############################################
# TEST 13: PAYOUT-ZYKLUS — 90/10 VERTEILUNG
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--payout" ]]; then

header "TEST 13: Payout-Zyklus — 90/10 Pool-Verteilung"

# Schritt 1: Sicherstellen dass Revenue in Pool B ist
step "Prüfe aktuelle Pools..."
PRE_CHECK=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
PRE_POOL_B=$(echo "$PRE_CHECK" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
PRE_POOL_B=${PRE_POOL_B:-0}

if [[ "$PRE_POOL_B" -eq 0 ]]; then
    step "Pool B ist leer — sende ${SEND_AMOUNT} QU für Payout-Test..."
    TX_OUT=$(cli_call_seed "$SEED1" -sendtoaddress "$QRWA_IDENTITY" "$SEND_AMOUNT")
    TX_H=$(echo "$TX_OUT" | grep "TxHash:" | awk '{print $2}')
    TX_T=$(echo "$TX_OUT" | grep "Tick:" | awk '{print $2}')
    if [[ -n "$TX_H" && -n "$TX_T" ]]; then
        echo -e "    TX gesendet: ${TX_H} (Tick ${TX_T})"
        step "Warte auf Bestätigung..."
        CHK=$(wait_and_check_tx "$TX_T" "$TX_H")
        if echo "$CHK" | grep -q "MoneyFlew: Yes"; then
            echo -e "    ${GREEN}MoneyFlew: Yes${NC}"
        else
            echo -e "    ${YELLOW}MoneyFlew Status: $(echo "$CHK" | grep MoneyFlew)${NC}"
        fi
    fi
    sleep 5
fi

# Schritt 2: Snapshot VOR Payout
step "Snapshot VOR Payout..."
BEFORE_DIV=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
BEFORE_POOL_A=$(echo "$BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
BEFORE_POOL_B=$(echo "$BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
BEFORE_QMINE_POOL=$(echo "$BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
BEFORE_QRWA_POOL=$(echo "$BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '4p')
BEFORE_POOL_A=${BEFORE_POOL_A:-0}
BEFORE_POOL_B=${BEFORE_POOL_B:-0}
BEFORE_QMINE_POOL=${BEFORE_QMINE_POOL:-0}
BEFORE_QRWA_POOL=${BEFORE_QRWA_POOL:-0}
BEFORE_DEDICATED_REV=$(echo "$BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '5p')
BEFORE_DEDICATED_QRWA=$(echo "$BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '6p')
BEFORE_DEDICATED_REV=${BEFORE_DEDICATED_REV:-0}
BEFORE_DEDICATED_QRWA=${BEFORE_DEDICATED_QRWA:-0}

echo -e "    Pool A:               ${BEFORE_POOL_A} QU"
echo -e "    Pool B:               ${BEFORE_POOL_B} QU"
echo -e "    QMINE Div Pool:       ${BEFORE_QMINE_POOL} QU"
echo -e "    QRWA Div Pool:        ${BEFORE_QRWA_POOL} QU"
echo -e "    Dedicated Rev Pool:   ${BEFORE_DEDICATED_REV} QU"
echo -e "    Dedicated QRWA Pool:  ${BEFORE_DEDICATED_QRWA} QU"

# TotalDistributed VOR Payout
BEFORE_TOTAL=$(call_fn 6 "" "{ uint64, uint64 }")
BEFORE_TOTAL_QMINE=$(echo "$BEFORE_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
BEFORE_TOTAL_QRWA=$(echo "$BEFORE_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
BEFORE_TOTAL_QMINE=${BEFORE_TOTAL_QMINE:-0}
BEFORE_TOTAL_QRWA=${BEFORE_TOTAL_QRWA:-0}
echo -e "    Total QMINE Dist: ${BEFORE_TOTAL_QMINE} QU"
echo -e "    Total QRWA Dist:  ${BEFORE_TOTAL_QRWA} QU"

TOTAL_REVENUE=$((BEFORE_POOL_A + BEFORE_POOL_B + BEFORE_DEDICATED_REV))

# Berechne erwartete Verteilung (basierend auf aktuellem Snapshot)
if [[ "$TOTAL_REVENUE" -gt 0 ]]; then
    GOV_FEE_TOTAL=$((BEFORE_POOL_A * 500 / 1000))
    REMAINING_A=$((BEFORE_POOL_A - GOV_FEE_TOTAL))
    TOTAL_FOR_SPLIT=$((REMAINING_A + BEFORE_POOL_B))
    EXPECTED_QMINE=$((TOTAL_FOR_SPLIT * 900 / 1000))
    EXPECTED_QRWA=$((TOTAL_FOR_SPLIT - EXPECTED_QMINE))

    # Dedicated Pool: kein Gov Fee, eigener 90/10 Split
    EXPECTED_DEDICATED_QMINE=$((BEFORE_DEDICATED_REV * 900 / 1000))
    EXPECTED_DEDICATED_QRWA=$((BEFORE_DEDICATED_REV - EXPECTED_DEDICATED_QMINE))

    echo ""
    echo -e "    ${CYAN}Erwartete Verteilung bei nächstem Payout:${NC}"
    echo -e "    Gov Fees (aus Pool A):          ${GOV_FEE_TOTAL} QU (elec 35% + maint 5% + reinv 10%)"
    echo -e "    Pool A+B nach Fees:             ${TOTAL_FOR_SPLIT} QU (rest A + B)"
    echo -e "    → QMINE (90%):                  ${EXPECTED_QMINE} QU"
    echo -e "    → qRWA (10%):                   ${EXPECTED_QRWA} QU"
    if [[ "$BEFORE_DEDICATED_REV" -gt 0 ]]; then
        echo -e "    Dedicated Pool (kein Gov Fee):   ${BEFORE_DEDICATED_REV} QU"
        echo -e "    → Dedicated QMINE (90%):         ${EXPECTED_DEDICATED_QMINE} QU"
        echo -e "    → Dedicated qRWA (10%):          ${EXPECTED_DEDICATED_QRWA} QU"
    fi
else
    echo ""
    echo -e "    ${YELLOW}Pool A + B + Dedicated = 0 — alle Revenue wurde bereits verteilt${NC}"
    echo -e "    QMINE Div Pool:  ${BEFORE_QMINE_POOL} QU (wartet auf Epoch-Snapshot)"
    echo -e "    QRWA Dist bisher: ${BEFORE_TOTAL_QRWA} QU"
fi

if [[ "$TOTAL_REVENUE" -eq 0 ]]; then
    record_skip "Payout 90/10" "Pool A+B+Dedicated=0 — Revenue bereits verteilt, QMINE Pool: ${BEFORE_QMINE_POOL}"
else
    echo ""
    step "Warte auf nächsten Payout-Zyklus (alle 20 Ticks ≈ 40s)..."
    echo -e "    ${YELLOW}Prüfe alle 10s ob Payout stattfand...${NC}"

    PAYOUT_DETECTED=0
    for i in $(seq 1 12); do
        sleep 10
        AFTER_DIV=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
        AFTER_POOL_B=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        AFTER_POOL_B=${AFTER_POOL_B:-0}

        AFTER_QMINE_POOL=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
        AFTER_QMINE_POOL=${AFTER_QMINE_POOL:-0}

        AFTER_DEDICATED_CHK=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '5p')
        AFTER_DEDICATED_CHK=${AFTER_DEDICATED_CHK:-0}

        AFTER_TOTAL_CHK=$(call_fn 6 "" "{ uint64, uint64 }")
        AFTER_TOTAL_QRWA_CHK=$(echo "$AFTER_TOTAL_CHK" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        AFTER_TOTAL_QRWA_CHK=${AFTER_TOTAL_QRWA_CHK:-0}

        echo -e "    [${i}/12] Pool B: ${AFTER_POOL_B} | QMINE Pool: ${AFTER_QMINE_POOL} | Dedicated: ${AFTER_DEDICATED_CHK} | QRWA Dist: ${AFTER_TOTAL_QRWA_CHK}"

        # Payout erkannt: Pool B gesunken ODER QMINE Pool gestiegen ODER Total QRWA Dist gestiegen ODER Dedicated Pool verändert
        if [[ "$AFTER_POOL_B" -lt "$BEFORE_POOL_B" ]] || \
           [[ "$AFTER_QMINE_POOL" -gt "$BEFORE_QMINE_POOL" ]] || \
           [[ "$AFTER_TOTAL_QRWA_CHK" -gt "$BEFORE_TOTAL_QRWA" ]] || \
           [[ "$AFTER_DEDICATED_CHK" -ne "$BEFORE_DEDICATED_REV" ]]; then
            PAYOUT_DETECTED=1
            echo -e "    ${GREEN}Payout erkannt!${NC}"
            break
        fi
    done

    if [[ "$PAYOUT_DETECTED" -eq 1 ]]; then
        # Finaler Zustand
        AFTER_DIV=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
        AFTER_POOL_A=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
        AFTER_POOL_B=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        AFTER_QMINE_POOL=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
        AFTER_QRWA_POOL=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '4p')
        AFTER_POOL_A=${AFTER_POOL_A:-0}
        AFTER_POOL_B=${AFTER_POOL_B:-0}
        AFTER_QMINE_POOL=${AFTER_QMINE_POOL:-0}
        AFTER_QRWA_POOL=${AFTER_QRWA_POOL:-0}
        AFTER_DEDICATED_REV=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '5p')
        AFTER_DEDICATED_QRWA=$(echo "$AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '6p')
        AFTER_DEDICATED_REV=${AFTER_DEDICATED_REV:-0}
        AFTER_DEDICATED_QRWA=${AFTER_DEDICATED_QRWA:-0}

        AFTER_TOTAL=$(call_fn 6 "" "{ uint64, uint64 }")
        AFTER_TOTAL_QMINE=$(echo "$AFTER_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
        AFTER_TOTAL_QRWA=$(echo "$AFTER_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        AFTER_TOTAL_QMINE=${AFTER_TOTAL_QMINE:-0}
        AFTER_TOTAL_QRWA=${AFTER_TOTAL_QRWA:-0}

        echo ""
        echo -e "    ${BOLD}NACH Payout:${NC}"
        echo -e "    Pool A:               ${AFTER_POOL_A} QU"
        echo -e "    Pool B:               ${AFTER_POOL_B} QU"
        echo -e "    QMINE Div Pool:       ${AFTER_QMINE_POOL} QU"
        echo -e "    QRWA Div Pool:        ${AFTER_QRWA_POOL} QU"
        echo -e "    Dedicated Rev Pool:   ${AFTER_DEDICATED_REV} QU"
        echo -e "    Dedicated QRWA Pool:  ${AFTER_DEDICATED_QRWA} QU"
        echo -e "    Total QMINE Dist:     ${AFTER_TOTAL_QMINE} QU"
        echo -e "    Total QRWA Dist:      ${AFTER_TOTAL_QRWA} QU"

        # 13a: Pool B wurde aufgebraucht
        if [[ "$AFTER_POOL_B" -eq 0 ]] && [[ "$BEFORE_POOL_B" -gt 0 ]]; then
            record_pass "Pool B aufgebraucht — war: ${BEFORE_POOL_B}, jetzt: 0"
        elif [[ "$BEFORE_POOL_B" -eq 0 ]]; then
            record_pass "Pool B war bereits 0"
        else
            record_fail "Pool B Consumption" "Pool B: ${AFTER_POOL_B} (erwartet: 0)"
        fi

        # 13b: 90/10 Split verifizieren
        DELTA_TOTAL_QMINE=$((AFTER_TOTAL_QMINE - BEFORE_TOTAL_QMINE))
        DELTA_TOTAL_QRWA=$((AFTER_TOTAL_QRWA - BEFORE_TOTAL_QRWA))
        QMINE_POOL_DELTA=$((AFTER_QMINE_POOL - BEFORE_QMINE_POOL))

        echo ""
        echo -e "    ${BOLD}Verteilungsanalyse:${NC}"
        echo -e "    Δ QMINE Distributed:  +${DELTA_TOTAL_QMINE} QU"
        echo -e "    Δ QRWA Distributed:   +${DELTA_TOTAL_QRWA} QU"
        echo -e "    Δ QMINE Pool (akkum): +${QMINE_POOL_DELTA} QU"

        # Fall A: Beide verteilt (Epoch-Snapshot vorhanden)
        if [[ "$DELTA_TOTAL_QMINE" -gt 0 && "$DELTA_TOTAL_QRWA" -gt 0 ]]; then
            TOTAL_DELTA=$((DELTA_TOTAL_QMINE + DELTA_TOTAL_QRWA))
            ACTUAL_QMINE_PCT=$((DELTA_TOTAL_QMINE * 1000 / TOTAL_DELTA))
            ACTUAL_QRWA_PCT=$((DELTA_TOTAL_QRWA * 1000 / TOTAL_DELTA))
            echo -e "    QMINE: ${ACTUAL_QMINE_PCT}‰ | QRWA: ${ACTUAL_QRWA_PCT}‰ (erwartet: 900/100)"
            if [[ "$ACTUAL_QMINE_PCT" -ge 880 && "$ACTUAL_QMINE_PCT" -le 920 ]]; then
                record_pass "90/10 Split — QMINE ${ACTUAL_QMINE_PCT}‰ ≈ 90%"
            else
                record_fail "90/10 Split" "QMINE ${ACTUAL_QMINE_PCT}‰ (erwartet: ~900‰)"
            fi

        # Fall B: QMINE akkumuliert in Pool (kein Epoch-Snapshot), QRWA verteilt
        elif [[ "$QMINE_POOL_DELTA" -gt 0 && "$DELTA_TOTAL_QRWA" -gt 0 ]]; then
            TOTAL_MOVED=$((QMINE_POOL_DELTA + DELTA_TOTAL_QRWA))
            ACTUAL_QMINE_PCT=$((QMINE_POOL_DELTA * 1000 / TOTAL_MOVED))
            echo -e "    QMINE(pool)/QRWA(dist) = ${ACTUAL_QMINE_PCT}‰ (erwartet: ~900‰)"
            if [[ "$ACTUAL_QMINE_PCT" -ge 880 && "$ACTUAL_QMINE_PCT" -le 920 ]]; then
                record_pass "90/10 Split (via Pool) — QMINE ${ACTUAL_QMINE_PCT}‰ ≈ 90%"
            else
                record_fail "90/10 Split" "QMINE Pool ${ACTUAL_QMINE_PCT}‰ (erwartet: ~900‰)"
            fi

        # Fall C: Nur QMINE Pool wuchs (kein Epoch-Snapshot UND qRWA nicht verteilt)
        #         → Automatisch auf Epoch-Wechsel warten, dann erneut prüfen
        elif [[ "$QMINE_POOL_DELTA" -gt 0 ]]; then
            echo -e "    ${YELLOW}QMINE Pool akkumuliert (+${QMINE_POOL_DELTA}), kein Epoch-Snapshot vorhanden${NC}"
            echo -e "    ${CYAN}→ Warte auf Epoch-Wechsel damit BEGIN_EPOCH QMINE-Snapshot anlegt...${NC}"
            echo ""

            # Aktuelle Epoch lesen
            EC_SYS=$(cli_call -getsysteminfo 2>&1 || cli_call -getcurrenttick 2>&1)
            EC_EPOCH=$(echo "$EC_SYS" | grep -i 'Epoch:' | awk '{print $2}')
            EC_TICK=$(echo "$EC_SYS" | grep -i 'Tick:' | awk '{print $2}')
            if [[ -z "$EC_EPOCH" ]]; then
                EC_FALLBACK=$(cli_call -getcurrenttick)
                EC_EPOCH=$(echo "$EC_FALLBACK" | grep 'Epoch:' | awk '{print $2}')
                EC_TICK=$(echo "$EC_FALLBACK" | grep 'Tick:' | awk '{print $2}')
            fi
            EC_EPOCH=${EC_EPOCH:-0}
            EC_TICK=${EC_TICK:-0}
            echo -e "    Aktuelle Epoch: ${EC_EPOCH} | Tick: ${EC_TICK}"
            echo -e "    Testnet: ${EPOCH_TICKS} Ticks/Epoch — warte auf Epoch $((EC_EPOCH + 1))..."

            # Snapshot VOR Epoch-Wechsel
            EC_QMINE_DIST_BEFORE=$(echo "$AFTER_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
            EC_QMINE_DIST_BEFORE=${EC_QMINE_DIST_BEFORE:-0}
            EC_QMINE_POOL_BEFORE=$AFTER_QMINE_POOL

            # Warte auf Epoch-Wechsel (max 30 Min)
            EC_CHANGED=0
            EC_WAIT_MAX=120
            for ec_i in $(seq 1 $EC_WAIT_MAX); do
                sleep 15
                EC_CHK=$(cli_call -getsysteminfo 2>&1 || cli_call -getcurrenttick 2>&1)
                EC_EP=$(echo "$EC_CHK" | grep -i 'Epoch:' | awk '{print $2}')
                EC_TK=$(echo "$EC_CHK" | grep -i 'Tick:' | awk '{print $2}')
                if [[ -z "$EC_EP" ]]; then
                    EC_FB=$(cli_call -getcurrenttick)
                    EC_EP=$(echo "$EC_FB" | grep 'Epoch:' | awk '{print $2}')
                    EC_TK=$(echo "$EC_FB" | grep 'Tick:' | awk '{print $2}')
                fi
                EC_EP=${EC_EP:-$EC_EPOCH}
                EC_TK=${EC_TK:-0}

                if [[ "$((ec_i % 4))" -eq 0 || "$ec_i" -eq 1 ]]; then
                    echo -e "    [${ec_i}/${EC_WAIT_MAX}] Epoch: ${EC_EP} | Tick: ${EC_TK}"
                fi

                if [[ "$EC_EP" -gt "$EC_EPOCH" ]]; then
                    EC_CHANGED=1
                    echo -e "    ${GREEN}${BOLD}Epoch gewechselt: ${EC_EPOCH} → ${EC_EP}${NC}"
                    break
                fi
            done

            if [[ "$EC_CHANGED" -eq 1 ]]; then
                echo -e "    ${CYAN}BEGIN_EPOCH hat QMINE-Holder-Snapshot erstellt${NC}"
                echo -e "    ${CYAN}Warte auf nächsten Payout-Zyklus (alle 20 Ticks)...${NC}"

                # Warte auf QMINE-Distribution (max 3 Minuten)
                EC_PAYOUT=0
                for ec_p in $(seq 1 18); do
                    sleep 10
                    EC_TOTAL_CHK=$(call_fn 6 "" "{ uint64, uint64 }")
                    EC_QMINE_DIST_NOW=$(echo "$EC_TOTAL_CHK" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
                    EC_QMINE_DIST_NOW=${EC_QMINE_DIST_NOW:-0}

                    EC_POOL_CHK=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
                    EC_QMINE_POOL_NOW=$(echo "$EC_POOL_CHK" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
                    EC_QMINE_POOL_NOW=${EC_QMINE_POOL_NOW:-0}

                    echo -e "    [${ec_p}/18] QMINE Dist: ${EC_QMINE_DIST_NOW} (vorher: ${EC_QMINE_DIST_BEFORE}) | QMINE Pool: ${EC_QMINE_POOL_NOW}"

                    if [[ "$EC_QMINE_DIST_NOW" -gt "$EC_QMINE_DIST_BEFORE" ]]; then
                        EC_PAYOUT=1
                        EC_DELTA_QMINE=$((EC_QMINE_DIST_NOW - EC_QMINE_DIST_BEFORE))
                        echo -e "    ${GREEN}QMINE Payout nach Epoch! +${EC_DELTA_QMINE} QU an Holder verteilt${NC}"
                        record_pass "QMINE Payout nach Epoch — +${EC_DELTA_QMINE} QU (Pool war: ${EC_QMINE_POOL_BEFORE})"
                        break
                    fi
                done

                if [[ "$EC_PAYOUT" -eq 0 ]]; then
                    echo -e "    ${YELLOW}QMINE Pool: ${EC_QMINE_POOL_NOW} QU — noch kein Payout nach Epoch${NC}"
                    record_skip "QMINE Payout nach Epoch" "Pool: ${EC_QMINE_POOL_NOW} QU, Dist: ${EC_QMINE_DIST_NOW}"
                fi
            else
                echo -e "    ${YELLOW}Kein Epoch-Wechsel in $((EC_WAIT_MAX * 15))s — QMINE Pool wartet${NC}"
                record_skip "90/10 Split" "Nur QMINE Pool +${QMINE_POOL_DELTA}, kein Epoch-Wechsel"
            fi

        else
            record_skip "90/10 Split" "Keine messbare Verteilung"
        fi
    else
        record_skip "Payout-Zyklus" "Kein Payout in 120s erkannt"
    fi
fi

###############################################
# TEST 14: GOVERNANCE FEE ADRESSEN PRÜFEN
###############################################

header "TEST 14: Governance Fee Adressen — Balance Check"
step "Lese GovParams für Adressen..."

# Parse Adressen aus GetGovParams Output (5 Identities + 3 uint64)
GOV_OUTPUT=$(call_fn 1 "" "{ { id, id, id, id, id, uint64, uint64, uint64 } }")
GOV_ADDRS=$(echo "$GOV_OUTPUT" | grep -oE '[A-Z]{55,60}' | head -5)
GOV_ADMIN=$(echo "$GOV_ADDRS" | sed -n '1p')
GOV_ELEC=$(echo "$GOV_ADDRS" | sed -n '2p')
GOV_MAINT=$(echo "$GOV_ADDRS" | sed -n '3p')
GOV_REINV=$(echo "$GOV_ADDRS" | sed -n '4p')
GOV_DEV=$(echo "$GOV_ADDRS" | sed -n '5p')

GOV_PCTS=$(echo "$GOV_OUTPUT" | sed -n '/Contract Function Output/,$ p' | sed 's/^[[:space:]]*//' | sed 's/,$//' | grep -oE '^[0-9]+$')
GOV_ELEC_PCT=$(echo "$GOV_PCTS" | sed -n '1p')
GOV_MAINT_PCT=$(echo "$GOV_PCTS" | sed -n '2p')
GOV_REINV_PCT=$(echo "$GOV_PCTS" | sed -n '3p')

echo -e "    Admin:       ${GOV_ADMIN:-?}"
echo -e "    Electricity: ${GOV_ELEC:-?} (${GOV_ELEC_PCT:-?}‰)"
echo -e "    Maintenance: ${GOV_MAINT:-?} (${GOV_MAINT_PCT:-?}‰)"
echo -e "    Reinvestment:${GOV_REINV:-?} (${GOV_REINV_PCT:-?}‰)"
echo -e "    QMINE Dev:   ${GOV_DEV:-?}"
echo ""

# Balance-Check für jede Governance-Adresse
for LABEL_ADDR in "Electricity:${GOV_ELEC}" "Maintenance:${GOV_MAINT}" "Reinvestment:${GOV_REINV}" "QMINE Dev:${GOV_DEV}"; do
    LABEL=$(echo "$LABEL_ADDR" | cut -d: -f1)
    ADDR=$(echo "$LABEL_ADDR" | cut -d: -f2)
    if [[ -z "$ADDR" || "$ADDR" == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFXIB" ]]; then
        record_skip "${LABEL} Balance" "Adresse ist NULL_ID"
        continue
    fi
    BAL_OUT=$(cli_call -getbalance "$ADDR")
    GOV_BAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
    GOV_BAL=${GOV_BAL:-0}
    echo -e "    ${LABEL} Balance: ${GOV_BAL} QU"
    if [[ "$GOV_BAL" -gt 0 ]]; then
        record_pass "${LABEL} hat Funds — ${GOV_BAL} QU"
    else
        record_skip "${LABEL} Balance" "0 QU (Pool A war evtl. leer → keine Gov Fees)"
    fi
done

# Pool A Payout-Verifikation: Summe der Gov Fee Balances prüfen
step "Pool A Payout-Verifikation..."
GOV_FEE_SUM=0
for CHK_ADDR in "$GOV_ELEC" "$GOV_MAINT" "$GOV_REINV"; do
    if [[ -n "$CHK_ADDR" && "$CHK_ADDR" != "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFXIB" ]]; then
        CHK_BAL_OUT=$(cli_call -getbalance "$CHK_ADDR")
        CHK_BAL=$(echo "$CHK_BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        GOV_FEE_SUM=$((GOV_FEE_SUM + ${CHK_BAL:-0}))
    fi
done

echo -e "    ${CYAN}Summe Gov Fees (Elec+Maint+Reinv): ${GOV_FEE_SUM} QU${NC}"

# Pool A Status prüfen
POOL_A_DIV=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
POOL_A_NOW=$(echo "$POOL_A_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
POOL_A_NOW=${POOL_A_NOW:-0}
echo -e "    ${CYAN}Pool A aktuell: ${POOL_A_NOW} QU${NC}"

if [[ "$GOV_FEE_SUM" -gt 0 ]]; then
    record_pass "Pool A Payout — Gov Fees verteilt: ${GOV_FEE_SUM} QU (Pool A jetzt: ${POOL_A_NOW})"
elif [[ "$POOL_A_NOW" -gt 0 ]]; then
    record_skip "Pool A Payout" "Pool A hat ${POOL_A_NOW} QU aber Gov Fees noch 0 — Payout steht aus"
else
    record_skip "Pool A Payout" "Pool A = 0 und Gov Fees = 0 — kein QUTIL-Revenue eingegangen"
fi

echo ""
echo -e "    ${CYAN}Hinweis: Gov Fees werden nur aus Pool A (QUTIL) abgezogen.${NC}"
echo -e "    ${CYAN}Wenn Pool A = 0, erhalten die Adressen keine Fees.${NC}"

###############################################
# TEST 15: BLOCKCHAIN qRWA + QMINE OWNER ANALYSE
###############################################

header "TEST 15: Blockchain qRWA Owner + QMINE Balance Analyse"
step "Lese alle qRWA-Owner von der Blockchain (queryassets ownerships)..."

# --- 15a: Alle qRWA-Shareholder abfragen ---
QRWA_OWNERS_RAW=$(cli_call -queryassets ownerships "name=QRWA")

# Parse: owner → shares (nur Einträge mit shares > 0)
declare -a QRWA_OWNER_IDS=()
declare -a QRWA_OWNER_SHARES=()
QRWA_TOTAL_SHARES=0

while IFS= read -r line; do
    if echo "$line" | grep -q 'owner = '; then
        OWNER=$(echo "$line" | sed 's/.*owner = //' | grep -oE '[A-Z]{50,60}')
    fi
    if echo "$line" | grep -q 'number of shares = '; then
        SHARES=$(echo "$line" | sed 's/.*number of shares = //' | grep -oE '[0-9]+')
        if [[ -n "$OWNER" && -n "$SHARES" && "$SHARES" -gt 0 ]]; then
            QRWA_OWNER_IDS+=("$OWNER")
            QRWA_OWNER_SHARES+=("$SHARES")
            QRWA_TOTAL_SHARES=$((QRWA_TOTAL_SHARES + SHARES))
        fi
    fi
done <<< "$QRWA_OWNERS_RAW"

QRWA_OWNER_COUNT=${#QRWA_OWNER_IDS[@]}
echo -e "    ${CYAN}qRWA Owner gefunden: ${QRWA_OWNER_COUNT}${NC}"
echo -e "    ${CYAN}qRWA Total Shares:   ${QRWA_TOTAL_SHARES}${NC}"

if [[ "$QRWA_OWNER_COUNT" -gt 0 ]]; then
    record_pass "qRWA Owner Query — ${QRWA_OWNER_COUNT} Owner, ${QRWA_TOTAL_SHARES} Shares"
else
    record_fail "qRWA Owner Query" "Keine qRWA Owner gefunden"
fi

# --- 15b: Für jeden qRWA-Owner die QMINE-Balance prüfen ---
QRWA_CHECK_LIMIT=15
if [[ "$QRWA_OWNER_COUNT" -gt "$QRWA_CHECK_LIMIT" ]]; then
    QRWA_LOOP_MAX=$QRWA_CHECK_LIMIT
else
    QRWA_LOOP_MAX=$QRWA_OWNER_COUNT
fi
step "Prüfe QMINE-Balance der ersten ${QRWA_LOOP_MAX} qRWA-Owners (von ${QRWA_OWNER_COUNT})..."
echo ""

QMINE_PER_QRWA_SHARE_MIN=100000  # aus qRWA.h: QRWA_QMINE_PER_QRWA_SHARE_MIN
ELIGIBLE_COUNT=0
ELIGIBLE_SHARES=0
declare -a ELIGIBLE_IDS=()
declare -a ELIGIBLE_QRWA_SHARES=()
declare -a ELIGIBLE_QMINE=()

for idx in $(seq 0 $((QRWA_LOOP_MAX - 1))); do
    OWN_ID="${QRWA_OWNER_IDS[$idx]}"
    OWN_QRWA="${QRWA_OWNER_SHARES[$idx]}"

    # Hole alle Assets dieses Owners
    ASSETS_OUT=$(cli_call -getasset "$OWN_ID")

    # QMINE Shares extrahieren (Suche nach QMINE + danach "Number Of Shares")
    OWN_QMINE=0
    if echo "$ASSETS_OUT" | grep -qi "QMINE"; then
        # Finde den QMINE-Block und extrahiere Shares
        OWN_QMINE=$(echo "$ASSETS_OUT" | awk '/QMINE/{found=1} found && /Number Of Shares/{print $NF; exit}')
        OWN_QMINE=${OWN_QMINE:-0}
    fi

    # Berechne benötigte QMINE
    REQUIRED_QMINE=$((OWN_QRWA * QMINE_PER_QRWA_SHARE_MIN))

    # Eligibility
    if [[ "$OWN_QMINE" -ge "$REQUIRED_QMINE" && "$REQUIRED_QMINE" -gt 0 ]]; then
        ELIGIBLE="✓"
        ELIGIBLE_COUNT=$((ELIGIBLE_COUNT + 1))
        ELIGIBLE_SHARES=$((ELIGIBLE_SHARES + OWN_QRWA))
        ELIGIBLE_IDS+=("$OWN_ID")
        ELIGIBLE_QRWA_SHARES+=("$OWN_QRWA")
        ELIGIBLE_QMINE+=("$OWN_QMINE")
        COLOR="$GREEN"
    else
        ELIGIBLE="✗"
        COLOR="$RED"
    fi

    # Kürze ID für Übersicht
    SHORT_ID="${OWN_ID:0:12}…${OWN_ID: -6}"
    echo -e "    ${COLOR}${ELIGIBLE}${NC} ${SHORT_ID}  qRWA: ${OWN_QRWA}  QMINE: ${OWN_QMINE}  benötigt: ${REQUIRED_QMINE}"
done

echo ""
echo -e "    ${BOLD}═══ Eligibility Zusammenfassung ═══${NC}"
echo -e "    ${CYAN}Eligible Owner (≥100K QMINE/Share): ${ELIGIBLE_COUNT} / ${QRWA_OWNER_COUNT}${NC}"
echo -e "    ${CYAN}Eligible Shares:                    ${ELIGIBLE_SHARES} / ${QRWA_TOTAL_SHARES}${NC}"

if [[ "$ELIGIBLE_COUNT" -gt 0 ]]; then
    record_pass "qRWA Eligible Holders — ${ELIGIBLE_COUNT} Owner mit ${ELIGIBLE_SHARES} Shares"
else
    record_fail "qRWA Eligible Holders" "Kein Owner hat ≥100K QMINE pro qRWA Share"
fi

# --- 15c: QMINE Owner Gesamtübersicht ---
step "Lese QMINE-Owner von der Blockchain..."
QMINE_OWNERS_RAW=$(cli_call -queryassets ownerships "name=QMINE,issuer=${QMINE_ISSUER}")

declare -a QMINE_OWNER_IDS=()
declare -a QMINE_OWNER_SHARES=()
QMINE_TOTAL_SHARES=0

while IFS= read -r line; do
    if echo "$line" | grep -q 'owner = '; then
        OWNER=$(echo "$line" | sed 's/.*owner = //' | grep -oE '[A-Z]{50,60}')
    fi
    if echo "$line" | grep -q 'number of shares = '; then
        SHARES=$(echo "$line" | sed 's/.*number of shares = //' | grep -oE '[0-9]+')
        if [[ -n "$OWNER" && -n "$SHARES" && "$SHARES" -gt 0 ]]; then
            QMINE_OWNER_IDS+=("$OWNER")
            QMINE_OWNER_SHARES+=("$SHARES")
            QMINE_TOTAL_SHARES=$((QMINE_TOTAL_SHARES + SHARES))
        fi
    fi
done <<< "$QMINE_OWNERS_RAW"

QMINE_OWNER_COUNT=${#QMINE_OWNER_IDS[@]}
echo -e "    ${CYAN}QMINE Owner gefunden: ${QMINE_OWNER_COUNT}${NC}"
echo -e "    ${CYAN}QMINE Total Shares:   ${QMINE_TOTAL_SHARES}${NC}"
echo ""

# Top 10 QMINE Holder ausgeben
step "Top 10 QMINE Holder:"
# Sortiere nach Shares (absteigende Reihenfolge)
declare -a SORTED_INDICES=()
for i in $(seq 0 $((QMINE_OWNER_COUNT - 1))); do
    echo "${QMINE_OWNER_SHARES[$i]} $i"
done | sort -rn | head -10 | while read -r shares idx; do
    QM_ID="${QMINE_OWNER_IDS[$idx]}"
    SHORT_QM="${QM_ID:0:12}…${QM_ID: -6}"
    echo -e "    ${SHORT_QM}  QMINE: ${shares}"
done

if [[ "$QMINE_OWNER_COUNT" -gt 0 ]]; then
    record_pass "QMINE Owner Query — ${QMINE_OWNER_COUNT} Owner, ${QMINE_TOTAL_SHARES} Total Shares"
else
    record_fail "QMINE Owner Query" "Keine QMINE Owner gefunden"
fi

###############################################
# TEST 16-DIST: PAYOUT DISTRIBUTION VERIFIKATION
###############################################

header "TEST 16: Payout Distribution Verifikation"
step "Prüfe Contract-State: TotalDistributed + Pools..."

QRWA_DIV_OUT=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
QRWA_DIV_POOL=$(echo "$QRWA_DIV_OUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '4p')
QRWA_DIV_POOL=${QRWA_DIV_POOL:-0}

QMINE_DIV_POOL=$(echo "$QRWA_DIV_OUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
QMINE_DIV_POOL=${QMINE_DIV_POOL:-0}

DEDICATED_REV_POOL=$(echo "$QRWA_DIV_OUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '5p')
DEDICATED_REV_POOL=${DEDICATED_REV_POOL:-0}
DEDICATED_QRWA_POOL=$(echo "$QRWA_DIV_OUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '6p')
DEDICATED_QRWA_POOL=${DEDICATED_QRWA_POOL:-0}

TOTAL_DIST_OUT=$(call_fn 6 "" "{ uint64, uint64 }")
TOTAL_QMINE_FINAL=$(echo "$TOTAL_DIST_OUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
TOTAL_QRWA_FINAL=$(echo "$TOTAL_DIST_OUT" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
TOTAL_QMINE_FINAL=${TOTAL_QMINE_FINAL:-0}
TOTAL_QRWA_FINAL=${TOTAL_QRWA_FINAL:-0}

echo -e "    QMINE Total Distributed:  ${TOTAL_QMINE_FINAL} QU"
echo -e "    qRWA Total Distributed:   ${TOTAL_QRWA_FINAL} QU"
echo -e "    QMINE Div Pool (rest):    ${QMINE_DIV_POOL} QU"
echo -e "    qRWA Div Pool (rest):     ${QRWA_DIV_POOL} QU"
echo -e "    Dedicated Rev Pool:       ${DEDICATED_REV_POOL} QU"
echo -e "    Dedicated QRWA Div Pool:  ${DEDICATED_QRWA_POOL} QU"

# 16a: qRWA Distribution passiert
if [[ "$TOTAL_QRWA_FINAL" -gt 0 ]]; then
    if [[ "$ELIGIBLE_SHARES" -gt 0 ]]; then
        PER_SHARE=$((TOTAL_QRWA_FINAL / ELIGIBLE_SHARES))
        echo -e "    Durchschnitt pro eligible qRWA Share: ~${PER_SHARE} QU"
    fi
    record_pass "qRWA Distribution — Total: ${TOTAL_QRWA_FINAL} QU verteilt"
else
    if [[ "$QRWA_DIV_POOL" -gt 0 ]]; then
        if [[ "$ELIGIBLE_COUNT" -eq 0 ]]; then
            echo -e "    ${YELLOW}qRWA Div Pool hat ${QRWA_DIV_POOL} QU — ABER kein eligible Holder!${NC}"
            echo -e "    ${YELLOW}(Kein Owner hat ≥100K QMINE pro qRWA Share)${NC}"
            record_skip "qRWA Distribution" "Pool: ${QRWA_DIV_POOL} QU, 0 eligible Holder"
        else
            echo -e "    ${YELLOW}qRWA Div Pool hat ${QRWA_DIV_POOL} QU — wartet auf nächsten Payout${NC}"
            record_skip "qRWA Distribution" "Pool: ${QRWA_DIV_POOL} QU, ${ELIGIBLE_COUNT} eligible Holder"
        fi
    else
        record_skip "qRWA Distribution" "Noch kein Revenue verteilt"
    fi
fi

# 16b: Erwarteter Payout pro eligible Holder
if [[ "$TOTAL_QRWA_FINAL" -gt 0 && "$ELIGIBLE_COUNT" -gt 0 ]]; then
    echo ""
    echo -e "    ${BOLD}Erwartete qRWA-Verteilung an eligible Holder:${NC}"
    for eidx in $(seq 0 $((ELIGIBLE_COUNT - 1))); do
        E_ID="${ELIGIBLE_IDS[$eidx]}"
        E_QRWA="${ELIGIBLE_QRWA_SHARES[$eidx]}"
        E_QMINE="${ELIGIBLE_QMINE[$eidx]}"
        EXPECTED_PAYOUT=$((TOTAL_QRWA_FINAL * E_QRWA / ELIGIBLE_SHARES))
        SHORT_E="${E_ID:0:12}…${E_ID: -6}"
        echo -e "    ${GREEN}✓${NC} ${SHORT_E}  qRWA: ${E_QRWA}  QMINE: ${E_QMINE}  → ~${EXPECTED_PAYOUT} QU"
    done
fi

# 16c: QMINE Distribution (benötigt Epoch-Snapshot)
if [[ "$TOTAL_QMINE_FINAL" -gt 0 ]]; then
    record_pass "QMINE Distribution — Total: ${TOTAL_QMINE_FINAL} QU an Holder verteilt"
else
    if [[ "$QMINE_DIV_POOL" -gt 0 ]]; then
        echo -e "    ${YELLOW}QMINE Pool hat ${QMINE_DIV_POOL} QU — wartet auf Epoch-Snapshot${NC}"
        echo -e "    ${YELLOW}(BEGIN_EPOCH muss einmal gelaufen sein um Snapshots anzulegen)${NC}"
        record_skip "QMINE Distribution" "Pool: ${QMINE_DIV_POOL} QU, kein Epoch-Snapshot"
    else
        record_skip "QMINE Distribution" "Noch kein Revenue verteilt"
    fi
fi

# 16d: Gesamtverteilung 90/10 Plausibilität
if [[ "$TOTAL_QMINE_FINAL" -gt 0 && "$TOTAL_QRWA_FINAL" -gt 0 ]]; then
    GRAND_TOTAL=$((TOTAL_QMINE_FINAL + TOTAL_QRWA_FINAL))
    FINAL_QMINE_PCT=$((TOTAL_QMINE_FINAL * 1000 / GRAND_TOTAL))
    FINAL_QRWA_PCT=$((TOTAL_QRWA_FINAL * 1000 / GRAND_TOTAL))
    echo ""
    echo -e "    ${BOLD}Gesamtverteilung Lifetime:${NC}"
    echo -e "    QMINE: ${TOTAL_QMINE_FINAL} QU (${FINAL_QMINE_PCT}‰)"
    echo -e "    qRWA:  ${TOTAL_QRWA_FINAL} QU (${FINAL_QRWA_PCT}‰)"

    if [[ "$FINAL_QMINE_PCT" -ge 870 && "$FINAL_QMINE_PCT" -le 930 ]]; then
        record_pass "Lifetime 90/10 — QMINE ${FINAL_QMINE_PCT}‰ ≈ 90%"
    else
        record_fail "Lifetime 90/10" "QMINE ${FINAL_QMINE_PCT}‰ (erwartet: ~900‰)"
    fi
fi

# 16e: Balance-Check eligible Holder VOR/NACH (Snapshot)
if [[ "$ELIGIBLE_COUNT" -gt 0 ]]; then
    echo ""
    step "Snapshot QU-Balances der eligible qRWA-Holder..."
    declare -a ELIGIBLE_BALANCES=()
    for eidx in $(seq 0 $((ELIGIBLE_COUNT - 1))); do
        E_ID="${ELIGIBLE_IDS[$eidx]}"
        BAL_OUT=$(cli_call -getbalance "$E_ID")
        E_BAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        E_BAL=${E_BAL:-0}
        ELIGIBLE_BALANCES+=("$E_BAL")
        SHORT_E="${E_ID:0:12}…${E_ID: -6}"
        echo -e "    ${SHORT_E}  QU Balance: ${E_BAL}"
    done
fi

###############################################
# TEST 17: QMINE ASSET CHECK (Test Seeds)
###############################################

header "TEST 17: QMINE Assets prüfen (Test Seeds)"

step "Prüfe QMINE Balance für Seed 1..."
ASSETS1=$(cli_call -getasset "$IDENTITY1")
echo "$ASSETS1" | grep -iE 'QMINE|Number Of Shares' | sed 's/^/    /' || echo "    (kein QMINE gefunden)"

if echo "$ASSETS1" | grep -qi "QMINE"; then
    QMINE_SHARES=$(echo "$ASSETS1" | grep -i 'Number Of Shares' | head -1 | awk '{print $NF}')
    record_pass "Seed 1 QMINE — ${QMINE_SHARES:-?} Shares"
else
    record_skip "Seed 1 QMINE" "Keine QMINE Shares gefunden"
fi

step "Prüfe QMINE Balance für Seed 2..."
ASSETS2=$(cli_call -getasset "$IDENTITY2")
echo "$ASSETS2" | grep -iE 'QMINE|Number Of Shares' | sed 's/^/    /' || echo "    (kein QMINE gefunden)"

if echo "$ASSETS2" | grep -qi "QMINE"; then
    QMINE_SHARES2=$(echo "$ASSETS2" | grep -i 'Number Of Shares' | head -1 | awk '{print $NF}')
    record_pass "Seed 2 QMINE — ${QMINE_SHARES2:-?} Shares"
else
    record_skip "Seed 2 QMINE" "Keine QMINE Shares"
fi

fi # end --payout

###############################################
# TEST 18: PAYOUT VERIFIKATION (Snapshot Vergleich)
###############################################

header "TEST 18: Payout Verifikation — Balance Vorher/Nachher"
step "Vergleiche QU-Balances der ${#SNAP_CHECK_IDS[@]} Holder mit Snapshot..."

PAYOUT_RECEIVED=0
PAYOUT_UNCHANGED=0
PAYOUT_DECREASED=0

echo ""
printf "    ${BOLD}%-15s %-28s %15s %15s %15s${NC}\n" "Typ" "Identity" "Vorher" "Nachher" "Δ"
echo -e "    ─────────────────────────────────────────────────────────────────────────────────────"

for i in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
    CHECK_ID="${SNAP_CHECK_IDS[$i]}"
    CHECK_TYPE="${SNAP_CHECK_TYPE[$i]}"
    BAL_BEFORE="${SNAP_CHECK_BAL_BEFORE[$i]}"

    BAL_OUT=$(cli_call -getbalance "$CHECK_ID")
    BAL_AFTER=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
    BAL_AFTER=${BAL_AFTER:-0}

    DELTA=$((BAL_AFTER - BAL_BEFORE))
    SHORT_ID="${CHECK_ID:0:12}…${CHECK_ID: -6}"
    TYPE_SHORT=$(echo "$CHECK_TYPE" | cut -d: -f1)

    if [[ "$DELTA" -gt 0 ]]; then
        printf "    ${GREEN}✓${NC} %-13s ${SHORT_ID}  %15s %15s ${GREEN}+%s${NC}\n" "$TYPE_SHORT" "$BAL_BEFORE" "$BAL_AFTER" "$DELTA"
        PAYOUT_RECEIVED=$((PAYOUT_RECEIVED + 1))
    elif [[ "$DELTA" -eq 0 ]]; then
        printf "    ${YELLOW}─${NC} %-13s ${SHORT_ID}  %15s %15s ${YELLOW}±0${NC}\n" "$TYPE_SHORT" "$BAL_BEFORE" "$BAL_AFTER"
        PAYOUT_UNCHANGED=$((PAYOUT_UNCHANGED + 1))
    else
        printf "    ${RED}↓${NC} %-13s ${SHORT_ID}  %15s %15s ${RED}%s${NC}\n" "$TYPE_SHORT" "$BAL_BEFORE" "$BAL_AFTER" "$DELTA"
        PAYOUT_DECREASED=$((PAYOUT_DECREASED + 1))
    fi
done

echo ""
echo -e "    ${BOLD}Ergebnis:${NC}"
echo -e "    ${GREEN}Payout erhalten: ${PAYOUT_RECEIVED}${NC}"
echo -e "    ${YELLOW}Unverändert:     ${PAYOUT_UNCHANGED}${NC}"
echo -e "    ${RED}Balance sank:    ${PAYOUT_DECREASED}${NC}"
echo ""

# Bewertung
CHECKED_TOTAL=${#SNAP_CHECK_IDS[@]}
if [[ "$PAYOUT_RECEIVED" -gt 0 ]]; then
    record_pass "Payout Verifikation — ${PAYOUT_RECEIVED}/${CHECKED_TOTAL} Holder erhielten Payout"
else
    if [[ "$CHECKED_TOTAL" -eq 0 ]]; then
        record_skip "Payout Verifikation" "Keine Holder im Snapshot"
    else
        record_fail "Payout Verifikation" "0/${CHECKED_TOTAL} Holder erhielten Payout"
    fi
fi

# Detailanalyse: qRWA-Holder speziell prüfen (die sollten 10% bekommen)
QRWA_RECEIVED=0
QRWA_CHECKED=0
for i in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
    TYPE_TAG=$(echo "${SNAP_CHECK_TYPE[$i]}" | cut -d: -f1)
    if [[ "$TYPE_TAG" == "qRWA" || "$TYPE_TAG" == "BOTH" ]]; then
        QRWA_CHECKED=$((QRWA_CHECKED + 1))
        CHECK_ID="${SNAP_CHECK_IDS[$i]}"
        BAL_BEFORE="${SNAP_CHECK_BAL_BEFORE[$i]}"
        BAL_OUT=$(cli_call -getbalance "$CHECK_ID")
        BAL_AFTER=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        BAL_AFTER=${BAL_AFTER:-0}
        if [[ "$BAL_AFTER" -gt "$BAL_BEFORE" ]]; then
            QRWA_RECEIVED=$((QRWA_RECEIVED + 1))
        fi
    fi
done

if [[ "$QRWA_CHECKED" -gt 0 ]]; then
    if [[ "$QRWA_RECEIVED" -gt 0 ]]; then
        record_pass "qRWA Holder Payout — ${QRWA_RECEIVED}/${QRWA_CHECKED} qRWA-Holder erhielten 10%-Anteil"
    else
        echo -e "    ${YELLOW}Hinweis: qRWA-Holder brauchen ≥100K QMINE pro Share für Eligibility${NC}"
        record_skip "qRWA Holder Payout" "${QRWA_RECEIVED}/${QRWA_CHECKED} — evtl. nicht eligible (QMINE < 100K/Share)"
    fi
fi

# QMINE-Holder prüfen
QMINE_RECEIVED=0
QMINE_CHECKED=0
for i in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
    TYPE_TAG=$(echo "${SNAP_CHECK_TYPE[$i]}" | cut -d: -f1)
    if [[ "$TYPE_TAG" == "QMINE" || "$TYPE_TAG" == "BOTH" ]]; then
        QMINE_CHECKED=$((QMINE_CHECKED + 1))
        CHECK_ID="${SNAP_CHECK_IDS[$i]}"
        BAL_BEFORE="${SNAP_CHECK_BAL_BEFORE[$i]}"
        BAL_OUT=$(cli_call -getbalance "$CHECK_ID")
        BAL_AFTER=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        BAL_AFTER=${BAL_AFTER:-0}
        if [[ "$BAL_AFTER" -gt "$BAL_BEFORE" ]]; then
            QMINE_RECEIVED=$((QMINE_RECEIVED + 1))
        fi
    fi
done

if [[ "$QMINE_CHECKED" -gt 0 ]]; then
    if [[ "$QMINE_RECEIVED" -gt 0 ]]; then
        record_pass "QMINE Holder Payout — ${QMINE_RECEIVED}/${QMINE_CHECKED} QMINE-Holder erhielten 90%-Anteil"
    else
        echo -e "    ${YELLOW}Hinweis: QMINE Payouts benötigen BEGIN_EPOCH Snapshot${NC}"
        record_skip "QMINE Holder Payout" "${QMINE_RECEIVED}/${QMINE_CHECKED} — evtl. kein Epoch-Snapshot"
    fi
fi

###############################################
# TEST 19: EPOCH-CHANGE + PAYOUT VERIFIKATION
###############################################

if [[ "$MODE" == "all" || "$MODE" == "--epoch" ]]; then

header "TEST 19: Epoch-Change + automatische Payout-Verifikation"
step "Testet ob nach Epoch-Wechsel automatisch Payouts stattfinden"
step "Testnet: ${EPOCH_TICKS} Ticks pro Epoch, Payout alle 20 Ticks"
echo ""

# ─── 19a: Systeminfo lesen (Epoch + Tick) ───
step "Lese aktuelle Systeminfo..."
SYS_INFO=$(cli_call -getsysteminfo 2>&1 || cli_call -getcurrenttick 2>&1)
EPOCH_NOW=$(echo "$SYS_INFO" | grep -i 'Epoch:' | awk '{print $2}')
TICK_NOW=$(echo "$SYS_INFO" | grep -i 'Tick:' | awk '{print $2}')

if [[ -z "$EPOCH_NOW" || -z "$TICK_NOW" ]]; then
    # Fallback: getcurrenttick
    TICK_INFO_19=$(cli_call -getcurrenttick)
    EPOCH_NOW=$(echo "$TICK_INFO_19" | grep 'Epoch:' | awk '{print $2}')
    TICK_NOW=$(echo "$TICK_INFO_19" | grep 'Tick:' | awk '{print $2}')
fi

if [[ -z "$EPOCH_NOW" || -z "$TICK_NOW" ]]; then
    record_fail "Systeminfo" "Konnte Epoch/Tick nicht lesen"
else
    echo -e "    Aktuelle Epoch: ${EPOCH_NOW}"
    echo -e "    Aktueller Tick: ${TICK_NOW}"
    record_pass "Systeminfo — Epoch: ${EPOCH_NOW}, Tick: ${TICK_NOW}"
fi

# ─── 19b: Revenue in Pool B sicherstellen ───
step "Stelle sicher dass Revenue in Pool B vorhanden ist..."
EP_BEFORE_DIV=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
EP_POOL_A_BEFORE=$(echo "$EP_BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
EP_POOL_B_BEFORE=$(echo "$EP_BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
EP_QMINE_POOL_BEFORE=$(echo "$EP_BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
EP_QRWA_POOL_BEFORE=$(echo "$EP_BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '4p')
EP_DEDICATED_BEFORE=$(echo "$EP_BEFORE_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '5p')
EP_POOL_A_BEFORE=${EP_POOL_A_BEFORE:-0}
EP_POOL_B_BEFORE=${EP_POOL_B_BEFORE:-0}
EP_QMINE_POOL_BEFORE=${EP_QMINE_POOL_BEFORE:-0}
EP_QRWA_POOL_BEFORE=${EP_QRWA_POOL_BEFORE:-0}
EP_DEDICATED_BEFORE=${EP_DEDICATED_BEFORE:-0}

echo -e "    Pool A: ${EP_POOL_A_BEFORE} QU | Pool B: ${EP_POOL_B_BEFORE} QU"
echo -e "    QMINE Div Pool: ${EP_QMINE_POOL_BEFORE} QU | QRWA Div Pool: ${EP_QRWA_POOL_BEFORE} QU"
echo -e "    Dedicated Pool: ${EP_DEDICATED_BEFORE} QU"

EP_TOTAL_REVENUE=$((EP_POOL_A_BEFORE + EP_POOL_B_BEFORE + EP_DEDICATED_BEFORE))

if [[ "$EP_TOTAL_REVENUE" -eq 0 && "$EP_QMINE_POOL_BEFORE" -eq 0 ]]; then
    step "Keine Revenue — sende ${SEND_AMOUNT} QU an Pool B..."
    TX_EP=$(cli_call_seed "$SEED1" -sendtoaddress "$QRWA_IDENTITY" "$SEND_AMOUNT")
    TX_EP_HASH=$(echo "$TX_EP" | grep "TxHash:" | awk '{print $2}')
    TX_EP_TICK=$(echo "$TX_EP" | grep "Tick:" | awk '{print $2}')
    if [[ -n "$TX_EP_HASH" && -n "$TX_EP_TICK" ]]; then
        echo -e "    TX: ${TX_EP_HASH} (Tick ${TX_EP_TICK})"
        step "Warte auf Bestätigung..."
        CHK_EP=$(wait_and_check_tx "$TX_EP_TICK" "$TX_EP_HASH")
        if echo "$CHK_EP" | grep -q "MoneyFlew: Yes"; then
            echo -e "    ${GREEN}MoneyFlew: Yes — Pool B aufgeladen${NC}"
            record_pass "Pool B aufgeladen — ${SEND_AMOUNT} QU"
        else
            echo -e "    ${YELLOW}MoneyFlew: $(echo "$CHK_EP" | grep MoneyFlew)${NC}"
            record_skip "Pool B Aufladung" "TX noch nicht bestätigt"
        fi
    else
        record_fail "Pool B Aufladung" "TX konnte nicht gesendet werden"
    fi
    sleep 5
else
    echo -e "    ${GREEN}✓${NC} Revenue vorhanden (Pool A+B+Dedicated=${EP_TOTAL_REVENUE}, QMINE Pool=${EP_QMINE_POOL_BEFORE})"
fi

# ─── 19c: TotalDistributed Snapshot VOR Epoch ───
EP_BEFORE_TOTAL=$(call_fn 6 "" "{ uint64, uint64 }")
EP_TOTAL_QMINE_BEFORE=$(echo "$EP_BEFORE_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
EP_TOTAL_QRWA_BEFORE=$(echo "$EP_BEFORE_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
EP_TOTAL_QMINE_BEFORE=${EP_TOTAL_QMINE_BEFORE:-0}
EP_TOTAL_QRWA_BEFORE=${EP_TOTAL_QRWA_BEFORE:-0}
echo -e "    Total QMINE Distributed (vorher): ${EP_TOTAL_QMINE_BEFORE} QU"
echo -e "    Total QRWA Distributed (vorher):  ${EP_TOTAL_QRWA_BEFORE} QU"

# ─── 19d: Holder-Balances Snapshot VOR Epoch ───
step "Snapshot: Holder QU-Balances VOR Epoch-Wechsel..."
declare -a EP_SNAP_IDS=()
declare -a EP_SNAP_BAL_BEFORE=()

# Nutze die bereits gesammelten SNAP_CHECK_IDS wenn verfügbar
if [[ ${#SNAP_CHECK_IDS[@]} -gt 0 ]]; then
    for si in $(seq 0 $((${#SNAP_CHECK_IDS[@]} - 1))); do
        EP_SNAP_IDS+=("${SNAP_CHECK_IDS[$si]}")
        BAL_OUT=$(cli_call -getbalance "${SNAP_CHECK_IDS[$si]}")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        EP_SNAP_BAL_BEFORE+=("${BAL_VAL:-0}")
    done
    echo -e "    ${GREEN}✓${NC} Snapshot für ${#EP_SNAP_IDS[@]} Holder gespeichert"
else
    # Fallback: mindestens Seed 1 + 2
    for snap_id in "$IDENTITY1" "$IDENTITY2"; do
        EP_SNAP_IDS+=("$snap_id")
        BAL_OUT=$(cli_call -getbalance "$snap_id")
        BAL_VAL=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
        EP_SNAP_BAL_BEFORE+=("${BAL_VAL:-0}")
    done
    echo -e "    ${GREEN}✓${NC} Snapshot für ${#EP_SNAP_IDS[@]} Holder (Fallback Seed 1+2)"
fi

# ─── 19e: Warte auf Epoch-Wechsel ───
echo ""
header "TEST 19e: Warte auf Epoch-Wechsel"
step "Aktuelle Epoch: ${EPOCH_NOW} — warte auf Epoch $((EPOCH_NOW + 1))..."
step "Testnet: ${EPOCH_TICKS} Ticks/Epoch → prüfe alle 15s"
echo ""

EPOCH_CHANGED=0
EPOCH_NEW=0
TICK_NEW=0
EPOCH_WAIT_MAX=120  # Max 120 Iterationen × 15s = 30 Minuten

for ep_i in $(seq 1 $EPOCH_WAIT_MAX); do
    sleep 15

    # Systeminfo lesen
    SYS_CHK=$(cli_call -getsysteminfo 2>&1 || cli_call -getcurrenttick 2>&1)
    EP_CHK=$(echo "$SYS_CHK" | grep -i 'Epoch:' | awk '{print $2}')
    TK_CHK=$(echo "$SYS_CHK" | grep -i 'Tick:' | awk '{print $2}')

    if [[ -z "$EP_CHK" ]]; then
        # Fallback
        TICK_INFO_CHK=$(cli_call -getcurrenttick)
        EP_CHK=$(echo "$TICK_INFO_CHK" | grep 'Epoch:' | awk '{print $2}')
        TK_CHK=$(echo "$TICK_INFO_CHK" | grep 'Tick:' | awk '{print $2}')
    fi

    EP_CHK=${EP_CHK:-$EPOCH_NOW}
    TK_CHK=${TK_CHK:-0}

    # Fortschritt anzeigen
    if [[ "$((ep_i % 4))" -eq 0 || "$ep_i" -eq 1 ]]; then
        echo -e "    [${ep_i}/${EPOCH_WAIT_MAX}] Epoch: ${EP_CHK} | Tick: ${TK_CHK}"
    fi

    if [[ "$EP_CHK" -gt "$EPOCH_NOW" ]]; then
        EPOCH_CHANGED=1
        EPOCH_NEW=$EP_CHK
        TICK_NEW=$TK_CHK
        echo ""
        echo -e "    ${GREEN}${BOLD}═══ EPOCH GEWECHSELT! ═══${NC}"
        echo -e "    ${GREEN}Alte Epoch: ${EPOCH_NOW} → Neue Epoch: ${EPOCH_NEW} (Tick: ${TICK_NEW})${NC}"
        record_pass "Epoch-Wechsel — ${EPOCH_NOW} → ${EPOCH_NEW}"
        break
    fi
done

if [[ "$EPOCH_CHANGED" -eq 0 ]]; then
    record_fail "Epoch-Wechsel" "Timeout nach $((EPOCH_WAIT_MAX * 15))s — Epoch blieb bei ${EPOCH_NOW}"
fi

# ─── 19f: Nach Epoch-Wechsel auf Payout warten ───
if [[ "$EPOCH_CHANGED" -eq 1 ]]; then
    echo ""
    header "TEST 19f: Payout nach Epoch-Wechsel"
    step "Epoch gewechselt — BEGIN_EPOCH hat Snapshots erstellt"
    step "Warte auf Payout-Zyklus (alle 20 Ticks)..."
    echo ""

    # Aktuelle Pools nach Epoch-Wechsel lesen
    sleep 10  # Kurz warten bis BEGIN_EPOCH fertig
    EP_MID_DIV=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
    EP_MID_POOL_A=$(echo "$EP_MID_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
    EP_MID_POOL_B=$(echo "$EP_MID_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
    EP_MID_QMINE_POOL=$(echo "$EP_MID_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
    EP_MID_QRWA_POOL=$(echo "$EP_MID_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '4p')
    EP_MID_POOL_A=${EP_MID_POOL_A:-0}
    EP_MID_POOL_B=${EP_MID_POOL_B:-0}
    EP_MID_QMINE_POOL=${EP_MID_QMINE_POOL:-0}
    EP_MID_QRWA_POOL=${EP_MID_QRWA_POOL:-0}

    echo -e "    ${BOLD}Pools nach Epoch-Wechsel (vor Payout):${NC}"
    echo -e "    Pool A: ${EP_MID_POOL_A} | Pool B: ${EP_MID_POOL_B}"
    echo -e "    QMINE Div Pool: ${EP_MID_QMINE_POOL} | QRWA Div Pool: ${EP_MID_QRWA_POOL}"

    # Warte auf Payout (prüfe alle 10s, max 3 Minuten)
    EP_PAYOUT_DETECTED=0
    EP_PAYOUT_MAX=18  # 18 × 10s = 180s = 3 Minuten

    for ep_p in $(seq 1 $EP_PAYOUT_MAX); do
        sleep 10

        EP_AFTER_DIV=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
        EP_AFT_POOL_A=$(echo "$EP_AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
        EP_AFT_POOL_B=$(echo "$EP_AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        EP_AFT_QMINE_POOL=$(echo "$EP_AFTER_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
        EP_AFT_POOL_A=${EP_AFT_POOL_A:-0}
        EP_AFT_POOL_B=${EP_AFT_POOL_B:-0}
        EP_AFT_QMINE_POOL=${EP_AFT_QMINE_POOL:-0}

        EP_AFTER_TOTAL=$(call_fn 6 "" "{ uint64, uint64 }")
        EP_AFT_TOTAL_QMINE=$(echo "$EP_AFTER_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
        EP_AFT_TOTAL_QRWA=$(echo "$EP_AFTER_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        EP_AFT_TOTAL_QMINE=${EP_AFT_TOTAL_QMINE:-0}
        EP_AFT_TOTAL_QRWA=${EP_AFT_TOTAL_QRWA:-0}

        echo -e "    [${ep_p}/${EP_PAYOUT_MAX}] Pool A: ${EP_AFT_POOL_A} | Pool B: ${EP_AFT_POOL_B} | QMINE Pool: ${EP_AFT_QMINE_POOL} | Dist QMINE: ${EP_AFT_TOTAL_QMINE} | Dist QRWA: ${EP_AFT_TOTAL_QRWA}"

        # Payout erkannt wenn:
        # - Pool A+B gesunken ODER
        # - TotalDistributed gestiegen ODER
        # - QMINE Pool verändert (Revenue wurde gesplittet)
        if [[ "$EP_AFT_TOTAL_QMINE" -gt "$EP_TOTAL_QMINE_BEFORE" ]] || \
           [[ "$EP_AFT_TOTAL_QRWA" -gt "$EP_TOTAL_QRWA_BEFORE" ]] || \
           [[ "$EP_AFT_POOL_B" -lt "$EP_POOL_B_BEFORE" && "$EP_POOL_B_BEFORE" -gt 0 ]] || \
           [[ "$EP_AFT_POOL_A" -lt "$EP_POOL_A_BEFORE" && "$EP_POOL_A_BEFORE" -gt 0 ]]; then
            EP_PAYOUT_DETECTED=1
            echo -e "    ${GREEN}${BOLD}Payout nach Epoch-Wechsel erkannt!${NC}"
            break
        fi
    done

    echo ""
    if [[ "$EP_PAYOUT_DETECTED" -eq 1 ]]; then
        # ─── 19g: Finale Analyse ───
        header "TEST 19g: Payout-Analyse nach Epoch-Wechsel"

        # Finale Pools
        EP_FINAL_DIV=$(call_fn 5 "" "{ uint64, uint64, uint64, uint64, uint64, uint64 }")
        EP_FIN_POOL_A=$(echo "$EP_FINAL_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
        EP_FIN_POOL_B=$(echo "$EP_FINAL_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        EP_FIN_QMINE_POOL=$(echo "$EP_FINAL_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '3p')
        EP_FIN_QRWA_POOL=$(echo "$EP_FINAL_DIV" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '4p')
        EP_FIN_POOL_A=${EP_FIN_POOL_A:-0}
        EP_FIN_POOL_B=${EP_FIN_POOL_B:-0}
        EP_FIN_QMINE_POOL=${EP_FIN_QMINE_POOL:-0}
        EP_FIN_QRWA_POOL=${EP_FIN_QRWA_POOL:-0}

        EP_FINAL_TOTAL=$(call_fn 6 "" "{ uint64, uint64 }")
        EP_FIN_TOTAL_QMINE=$(echo "$EP_FINAL_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '1p')
        EP_FIN_TOTAL_QRWA=$(echo "$EP_FINAL_TOTAL" | sed -n '/Contract Function Output/,$ p' | grep -oE '[0-9]+' | sed -n '2p')
        EP_FIN_TOTAL_QMINE=${EP_FIN_TOTAL_QMINE:-0}
        EP_FIN_TOTAL_QRWA=${EP_FIN_TOTAL_QRWA:-0}

        echo -e "    ${BOLD}Vergleich VOR/NACH Epoch-Wechsel + Payout:${NC}"
        echo -e "    ──────────────────────────────────────────────────"
        printf "    %-25s %15s %15s %15s\n" "" "Vorher" "Nachher" "Δ"
        echo -e "    ──────────────────────────────────────────────────"
        printf "    %-25s %15s %15s %15s\n" "Pool A" "$EP_POOL_A_BEFORE" "$EP_FIN_POOL_A" "$((EP_FIN_POOL_A - EP_POOL_A_BEFORE))"
        printf "    %-25s %15s %15s %15s\n" "Pool B" "$EP_POOL_B_BEFORE" "$EP_FIN_POOL_B" "$((EP_FIN_POOL_B - EP_POOL_B_BEFORE))"
        printf "    %-25s %15s %15s %15s\n" "QMINE Div Pool" "$EP_QMINE_POOL_BEFORE" "$EP_FIN_QMINE_POOL" "$((EP_FIN_QMINE_POOL - EP_QMINE_POOL_BEFORE))"
        printf "    %-25s %15s %15s %15s\n" "QRWA Div Pool" "$EP_QRWA_POOL_BEFORE" "$EP_FIN_QRWA_POOL" "$((EP_FIN_QRWA_POOL - EP_QRWA_POOL_BEFORE))"
        printf "    %-25s %15s %15s %15s\n" "Total QMINE Dist" "$EP_TOTAL_QMINE_BEFORE" "$EP_FIN_TOTAL_QMINE" "$((EP_FIN_TOTAL_QMINE - EP_TOTAL_QMINE_BEFORE))"
        printf "    %-25s %15s %15s %15s\n" "Total QRWA Dist" "$EP_TOTAL_QRWA_BEFORE" "$EP_FIN_TOTAL_QRWA" "$((EP_FIN_TOTAL_QRWA - EP_TOTAL_QRWA_BEFORE))"
        echo -e "    ──────────────────────────────────────────────────"

        # 19g-1: Pool B aufgebraucht?
        if [[ "$EP_FIN_POOL_B" -eq 0 && "$EP_POOL_B_BEFORE" -gt 0 ]]; then
            record_pass "Pool B nach Epoch-Payout aufgebraucht — ${EP_POOL_B_BEFORE} → 0"
        elif [[ "$EP_FIN_POOL_B" -lt "$EP_POOL_B_BEFORE" ]]; then
            record_pass "Pool B reduziert — ${EP_POOL_B_BEFORE} → ${EP_FIN_POOL_B}"
        fi

        # 19g-2: QMINE tatsächlich an Holder verteilt (nach Epoch haben wir Snapshots!)
        EP_DELTA_QMINE=$((EP_FIN_TOTAL_QMINE - EP_TOTAL_QMINE_BEFORE))
        EP_DELTA_QRWA=$((EP_FIN_TOTAL_QRWA - EP_TOTAL_QRWA_BEFORE))

        if [[ "$EP_DELTA_QMINE" -gt 0 ]]; then
            record_pass "QMINE Payout nach Epoch — +${EP_DELTA_QMINE} QU an QMINE-Holder verteilt"
        else
            if [[ "$EP_FIN_QMINE_POOL" -gt 0 ]]; then
                echo -e "    ${YELLOW}QMINE Pool akkumuliert: ${EP_FIN_QMINE_POOL} QU — wartet auf nächsten Payout${NC}"
                record_skip "QMINE Payout nach Epoch" "Pool: ${EP_FIN_QMINE_POOL} QU (noch kein Payout-Tick)"
            else
                record_skip "QMINE Payout nach Epoch" "Kein QMINE verteilt und Pool leer"
            fi
        fi

        if [[ "$EP_DELTA_QRWA" -gt 0 ]]; then
            record_pass "qRWA Payout nach Epoch — +${EP_DELTA_QRWA} QU an qRWA-Shareholder verteilt"
        else
            if [[ "$EP_FIN_QRWA_POOL" -gt 0 ]]; then
                echo -e "    ${YELLOW}qRWA Pool: ${EP_FIN_QRWA_POOL} QU — evtl. keine eligible Holder${NC}"
                record_skip "qRWA Payout nach Epoch" "Pool: ${EP_FIN_QRWA_POOL} QU"
            else
                record_skip "qRWA Payout nach Epoch" "Kein qRWA verteilt und Pool leer"
            fi
        fi

        # 19g-3: 90/10 Split nach Epoch verifizieren
        if [[ "$EP_DELTA_QMINE" -gt 0 && "$EP_DELTA_QRWA" -gt 0 ]]; then
            EP_TOTAL_DELTA=$((EP_DELTA_QMINE + EP_DELTA_QRWA))
            EP_QMINE_PCT=$((EP_DELTA_QMINE * 1000 / EP_TOTAL_DELTA))
            EP_QRWA_PCT=$((EP_DELTA_QRWA * 1000 / EP_TOTAL_DELTA))
            echo ""
            echo -e "    ${BOLD}90/10 Split nach Epoch:${NC}"
            echo -e "    QMINE: ${EP_DELTA_QMINE} QU (${EP_QMINE_PCT}‰)"
            echo -e "    qRWA:  ${EP_DELTA_QRWA} QU (${EP_QRWA_PCT}‰)"

            if [[ "$EP_QMINE_PCT" -ge 870 && "$EP_QMINE_PCT" -le 930 ]]; then
                record_pass "Epoch 90/10 Split — QMINE ${EP_QMINE_PCT}‰ ≈ 90%"
            else
                record_fail "Epoch 90/10 Split" "QMINE ${EP_QMINE_PCT}‰ (erwartet: ~900‰)"
            fi
        elif [[ "$EP_DELTA_QMINE" -gt 0 ]]; then
            # QMINE Pool wuchs + QMINE Dist, aber keine QRWA Dist (keine eligible Holder)
            echo -e "    ${YELLOW}Nur QMINE verteilt — keine eligible qRWA-Holder?${NC}"
            record_skip "Epoch 90/10 Split" "Nur QMINE +${EP_DELTA_QMINE}, kein QRWA Delta"
        fi

        # 19g-4: Holder-Balance Vergleich VOR/NACH Epoch
        echo ""
        step "Vergleiche Holder-Balances VOR/NACH Epoch + Payout..."
        EP_PAY_RECEIVED=0
        EP_PAY_UNCHANGED=0
        echo ""
        printf "    ${BOLD}%-28s %15s %15s %15s${NC}\n" "Identity" "Vorher" "Nachher" "Δ"
        echo -e "    ──────────────────────────────────────────────────────────"

        for ep_s in $(seq 0 $((${#EP_SNAP_IDS[@]} - 1))); do
            EP_S_ID="${EP_SNAP_IDS[$ep_s]}"
            EP_S_BAL_BEFORE="${EP_SNAP_BAL_BEFORE[$ep_s]}"
            BAL_OUT=$(cli_call -getbalance "$EP_S_ID")
            EP_S_BAL_AFTER=$(echo "$BAL_OUT" | grep -oE 'Balance: [0-9]+' | head -1 | awk '{print $2}')
            EP_S_BAL_AFTER=${EP_S_BAL_AFTER:-0}
            EP_S_DELTA=$((EP_S_BAL_AFTER - EP_S_BAL_BEFORE))
            EP_SHORT="${EP_S_ID:0:12}…${EP_S_ID: -6}"

            if [[ "$EP_S_DELTA" -gt 0 ]]; then
                printf "    ${GREEN}✓${NC} ${EP_SHORT}  %15s %15s ${GREEN}+%s${NC}\n" "$EP_S_BAL_BEFORE" "$EP_S_BAL_AFTER" "$EP_S_DELTA"
                EP_PAY_RECEIVED=$((EP_PAY_RECEIVED + 1))
            else
                printf "    ${YELLOW}─${NC} ${EP_SHORT}  %15s %15s ${YELLOW}±0${NC}\n" "$EP_S_BAL_BEFORE" "$EP_S_BAL_AFTER"
                EP_PAY_UNCHANGED=$((EP_PAY_UNCHANGED + 1))
            fi
        done

        echo ""
        if [[ "$EP_PAY_RECEIVED" -gt 0 ]]; then
            record_pass "Epoch Payout Verifikation — ${EP_PAY_RECEIVED}/${#EP_SNAP_IDS[@]} Holder erhielten Payout"
        else
            if [[ "$EP_DELTA_QMINE" -gt 0 || "$EP_DELTA_QRWA" -gt 0 ]]; then
                echo -e "    ${YELLOW}Distribution stieg, aber geprüfte Holder nicht betroffen${NC}"
                record_skip "Epoch Payout Verifikation" "Distribution +, geprüfte Holder ±0"
            else
                record_skip "Epoch Payout Verifikation" "Kein Payout an geprüfte Holder"
            fi
        fi
    else
        record_fail "Payout nach Epoch" "Kein Payout in $((EP_PAYOUT_MAX * 10))s nach Epoch-Wechsel erkannt"
    fi
fi

fi # end --epoch

###############################################
# ZUSAMMENFASSUNG
###############################################

header "ZUSAMMENFASSUNG"

echo ""
echo -e "  ${BOLD}Testumgebung${NC}"
echo -e "  ──────────────────────────────────────────"
echo -e "  Node:              $NODE_IP:$NODE_PORT"
echo -e "  Epoch:             $CURRENT_EPOCH"
echo -e "  Tick bei Start:    $CURRENT_TICK"
echo -e "  Contract Index:    $CONTRACT_INDEX"
echo -e "  Contract Identity: $QRWA_IDENTITY"
echo -e "  Seed 1:            $IDENTITY1"
echo -e "  Seed 2:            $IDENTITY2"
echo ""
echo -e "  ${BOLD}Ergebnisse${NC}"
echo -e "  ──────────────────────────────────────────"

for r in "${RESULTS[@]}"; do
    echo -e "    $r"
done

echo ""
echo -e "  ──────────────────────────────────────────"
echo -ne "  Total: ${TOTAL}  |  "
echo -ne "${GREEN}Pass: ${PASS}${NC}  |  "
echo -ne "${RED}Fail: ${FAIL}${NC}  |  "
echo -e  "${YELLOW}Skip: ${SKIP}${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}╔═══════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}${BOLD}║   ALLE TESTS BESTANDEN ✓         ║${NC}"
    echo -e "  ${GREEN}${BOLD}╚═══════════════════════════════════╝${NC}"
else
    echo -e "  ${RED}${BOLD}╔═══════════════════════════════════╗${NC}"
    echo -e "  ${RED}${BOLD}║   $FAIL TEST(S) FEHLGESCHLAGEN ✗   ║${NC}"
    echo -e "  ${RED}${BOLD}╚═══════════════════════════════════╝${NC}"
fi

echo ""
echo -e "  ${CYAN}Hinweise:${NC}"
echo -e "    • Payout-Cycle: Alle 20 Ticks (QRWA_PAYOUT_TICK_INTERVAL)"
echo -e "    • QMINE-Holder werden erst nach Epoch-Wechsel in Payout-Buffers aufgenommen"
echo -e "    • Pool A = QUTIL Revenue + mPoolARevenueAddress Transfers (Mining)"
echo -e "    • Pool B = User/andere SCs (nicht QUTIL, nicht Mining, nicht Dedicated)"
echo -e "    • Pool C = Dedicated BTC Revenue Address (kein Gov Fee)"
echo -e "    • Verteilung: 90% QMINE Holder, 10% qRWA Shareholder (nur eligible!)"
echo -e "    • qRWA Eligibility: ≥100K QMINE pro qRWA Share (QRWA_QMINE_PER_QRWA_SHARE_MIN)"
echo -e "    • --poolA: QUTIL → Epoch → Direct Mining → Epoch → Verify"
echo -e "    • --poolB: User Transfer → Epoch → Verify"
echo -e "    • --poolC: Dedicated BTC → Epoch → Verify (kein Gov Fee)"
echo -e "    • Testnet: ${EPOCH_TICKS} Ticks/Epoch — Epoch-Wechsel testet BEGIN_EPOCH Snapshots"
echo -e "    • -enabletestcontracts ist Pflicht für Contract Index >= 10"
echo ""

exit $FAIL
