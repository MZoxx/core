#!/bin/bash
# =============================================================================
# qRacel Testnet - Full E2E: Fund + Create Future Round + Place Bets
# Default (no args): fund contract, create 1 future 10m round, place bets on it
# =============================================================================
set -euo pipefail

NODE="135.181.160.185"
PORT="31841"
CONTRACT="25"
CLI="./qubic-cli/build-macos-aarch64/qubic-cli"
SCHEDULE_TICK=20

SEEDS=(
  "gtfgjhtoxcddbxrydatevcmildkmqeiezwgztpwseihqhqxmoamxfak"
  "ytcltfdvfjvskmarrjxloxkjrwtbjbepzjphowjfszldyjscrmztmor"
  "ahbpfnqltlotcyyaljwjouoheepykysdsokuazxlwecrwkuesxhahrx"
  "ouyxwcntrhdkmqrjvvpuhpakdjtvcmwihaezumfqkdlhfdfpwxkhttf"
  "nqgjkedtrfrvjessgckewozmjyvzzqkpblzbkistgimvtsdqezykpfh"
  "otdnmvfolpdmchvtlqxviekibqtmngecsabuuhlseqwjzouevdniwft"
  "ulprhzbvzxvpkcigfdiqghrjrcarowfkviwnyciwrcykbhrpjxomvlt"
  "mziquwzssfckwvhusrvqowtoljeulqalnzlrvovhbemikzrowxoeaig"
  "orxlpszaoguhglnkclcqnkvfzhqzzjnuisfvkwwuztkhqpwauexemdy"
  "iaobrqjfipbwancelebhkjhksghalrbovgfnrrejpvpblmchsliscqw"
  "slmvcerjvoncdlluydvilhuddusewxgoshuhgwelljzjykfllywlhon"
  "jaceqhnbufbcyoninbynpmglseulbuabscdrqttdwlflirpxnhnknpz"
  "pyvsehwfkqwihkhynsqggnewzbuiheoqaozlxdosmvcoayaauyrqtuu"
  "ughdrtzbfhqhmzsnoxvalppxbgmbfazcgvocacdkfrwnolzvrzqzbny"
  "krmnalawaxnhqvruzumckiefwbelpbvsyivvprfmsnhyfdwgxxvjsfr"
  "uggcbsmkggyynepudfecjnuhmrguihspdcojltjgvkcowtrviatzajv"
  "gmcccpxjvdfqlanaekolzxqstbdnvxurvfzxvqrsyjjcotmdsjrkomc"
  "kxpsjbvgaahjzltbnqdhehzdinicvxnvvutliqifadbiyqldgayhfzy"
  "hluajlytdqztjtefcbzcwkrdaopvaaaruaexfcnptuolussvepekjbx"
)

ADMIN_SEED="vyvymjcxxstbzthfflpsgjvgjlbxrctmorynuelhnwkghuwxmbszdqf"

BET_AMOUNT=1000000000  # 1B QU
DURATION="10m"
ROUND_ID=""
FORCE_SIDE=""
SEED_COUNT=19
MODE="full"  # full = fund+create+bet, manual = bet on given round, config/status/claim
SKIP_FUND=false
FUTURE_COUNT=1
CONFIG_ONLY=false
STATUS_ONLY=false
CLAIM_ALL=false

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Default: Fund contract + create future 10m round + place bets (full E2E)"
  echo ""
  echo "Options:"
  echo "  -r, --round ID        Bet on specific round ID (skip fund+create)"
  echo "  -a, --amount NUM      Bet amount per seed (default: 1B QU)"
  echo "  -d, --duration TYPE   Duration: 10m|60m|6h|24h (default: 10m)"
  echo "  -s, --side SIDE       Force all bets: up|down (default: alternating)"
  echo "  -n, --count NUM       Number of seeds 1-19 (default: all 19)"
  echo "  -f, --future NUM      Number of future rounds to create (default: 1)"
  echo "  --skip-fund           Skip funding step"
  echo "  --status              Show active round status"
  echo "  --config              Show contract config"
  echo "  --claim-all           Claim winnings for all bets"
  echo "  -h, --help            Show this help"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--round) ROUND_ID="$2"; MODE="manual"; shift 2;;
    -a|--amount) BET_AMOUNT="$2"; shift 2;;
    -d|--duration) DURATION="$2"; shift 2;;
    -s|--side) FORCE_SIDE="$2"; shift 2;;
    -n|--count) SEED_COUNT="$2"; shift 2;;
    -f|--future) FUTURE_COUNT="$2"; shift 2;;
    --skip-fund) SKIP_FUND=true; shift;;
    --status) STATUS_ONLY=true; shift;;
    --config) CONFIG_ONLY=true; shift;;
    --claim-all) CLAIM_ALL=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

cli() { $CLI -nodeip $NODE -nodeport $PORT "$@"; }
cli_admin() { cli -seed "$ADMIN_SEED" -scheduletick $SCHEDULE_TICK "$@"; }

# --- Config ---
if $CONFIG_ONLY; then
  cli -qracelgetconfig $CONTRACT
  exit 0
fi

# --- Status ---
if $STATUS_ONLY; then
  cli -qracelgetactiveround $CONTRACT "$DURATION"
  exit 0
fi

# --- Claim All ---
if $CLAIM_ALL; then
  echo "=== Claiming all winnings ==="
  BET_COUNT=$(cli -qracelgetconfig $CONTRACT 2>&1 | grep "Bet count:" | awk '{print $3}')
  if [ -z "$BET_COUNT" ] || [ "$BET_COUNT" = "0" ]; then
    echo "No bets found."; exit 0
  fi
  echo "Total bets: $BET_COUNT"
  for ((bid=0; bid<BET_COUNT; bid++)); do
    idx=$((bid % SEED_COUNT))
    echo -n "Claiming bet #$bid (seed #$((idx+1)))... "
    cli -seed "${SEEDS[$idx]}" -scheduletick $SCHEDULE_TICK -qracelclaim $CONTRACT $bid 2>&1 | grep -o "has been sent\|Error\|failed" || echo "sent"
    sleep 1
  done
  exit 0
fi

# =========================================================================
# FULL E2E: Fund → Create Future Round → Place Bets
# =========================================================================
if [ "$MODE" = "full" ]; then
  echo "======================================"
  echo " qRacel E2E: Fund + Future Round + Bets"
  echo "======================================"
  echo ""

  # --- Step 1: Fund contract ---
  if ! $SKIP_FUND; then
    echo "[1/4] Funding contract with 10B QU..."
    cli_admin -enabletestcontracts -qracelfund $CONTRACT 10000000000 2>&1 | grep -E "has been sent|MoneyFlew|Error" || true
    echo "     Waiting 15s for confirmation..."
    sleep 15

    echo "[1/4] Setting autoCreate mask=3 (10m+60m)..."
    cli_admin -qracelsetautocreate $CONTRACT 3 2>&1 | grep -E "has been sent|Error" || true
    echo "     Waiting 10s..."
    sleep 10
    echo ""
  else
    echo "[1/4] Skipping fund (--skip-fund)"
    echo ""
  fi

  # --- Step 2: Create future round(s) ---
  CURRENT_HOUR=$(date -u +%-H)
  CURRENT_MIN=$(date -u +%-M)
  NEXT_MIN=$(( ((CURRENT_MIN / 10) + 1) * 10 ))
  NEXT_HOUR=$CURRENT_HOUR
  if [ $NEXT_MIN -ge 60 ]; then
    NEXT_MIN=$((NEXT_MIN - 60))
    NEXT_HOUR=$(((NEXT_HOUR + 1) % 24))
  fi

  echo "[2/4] Creating $FUTURE_COUNT future $DURATION round(s)..."
  echo "      Current UTC: $(printf '%02d:%02d' $CURRENT_HOUR $CURRENT_MIN)"

  FIRST_ROUND_ID=""
  for ((r=0; r<FUTURE_COUNT; r++)); do
    RH=$NEXT_HOUR
    RM=$((NEXT_MIN + r * 10))
    while [ $RM -ge 60 ]; do RM=$((RM - 60)); RH=$(((RH + 1) % 24)); done
    TIME_STR=$(printf '%02d:%02d' $RH $RM)

    echo -n "      Round #$((r+1)) at $TIME_STR ... "
    OUTPUT=$(cli_admin -qracelcreateround $CONTRACT "$DURATION" 0 "$TIME_STR" 2>&1)

    if echo "$OUTPUT" | grep -q "has been sent"; then
      echo "TX sent"
    else
      echo "FAILED"
      echo "        $OUTPUT" | head -2
    fi
    sleep 2
  done

  echo "      Waiting 20s for round creation TXs..."
  sleep 20
  echo ""

  # --- Step 3: Get round ID ---
  echo "[3/4] Fetching config to find round ID..."
  CONFIG_OUT=$(cli -qracelgetconfig $CONTRACT 2>&1)
  echo "$CONFIG_OUT"
  echo ""

  NEXT_ROUND_ID=$(echo "$CONFIG_OUT" | grep "nextRoundId:" | awk '{print $2}')
  if [ -z "$NEXT_ROUND_ID" ] || [ "$NEXT_ROUND_ID" = "0" ]; then
    echo "ERROR: Could not determine round ID from config. Check contract state."
    exit 1
  fi

  # If we created N rounds, the first one is nextRoundId - (N-1)
  FIRST_ROUND_ID=$((NEXT_ROUND_ID - FUTURE_COUNT + 1))
  ROUND_ID=$FIRST_ROUND_ID
  echo "      Betting on round ID: $ROUND_ID (first of $FUTURE_COUNT created)"
  echo ""

  # Verify round exists
  echo "      Round details:"
  cli -qracelgetround $CONTRACT $ROUND_ID 2>&1 | head -15
  echo ""

fi  # end full mode

# =========================================================================
# Place Bets (shared by full + manual mode)
# =========================================================================
if [ -z "$ROUND_ID" ]; then
  echo "ERROR: No round ID. Use -r <ID> or run without args for full E2E."
  exit 1
fi

echo "[4/4] Placing bets on round $ROUND_ID"
echo "      Amount: $BET_AMOUNT QU | Seeds: $SEED_COUNT"
echo ""

SIDES=("up" "down")
SUCCESS=0
FAIL=0

for ((i=0; i<SEED_COUNT; i++)); do
  SEED="${SEEDS[$i]}"
  if [ -n "$FORCE_SIDE" ]; then
    SIDE="$FORCE_SIDE"
  else
    SIDE="${SIDES[$((i % 2))]}"
  fi

  echo -n "  Seed #$((i+1)) $SIDE ... "
  OUTPUT=$(cli -seed "$SEED" -scheduletick $SCHEDULE_TICK -qracelbet $CONTRACT $ROUND_ID $SIDE $BET_AMOUNT 2>&1)

  if echo "$OUTPUT" | grep -q "has been sent"; then
    echo "OK"
    ((SUCCESS++))
  else
    echo "FAIL"
    echo "    $(echo "$OUTPUT" | head -2)"
    ((FAIL++))
  fi
  sleep 1
done

echo ""
echo "======================================"
echo " Done: $SUCCESS sent, $FAIL failed"
echo "======================================"
echo ""
echo "Check round: cli -qracelgetround $CONTRACT $ROUND_ID"
echo "Check config: cli -qracelgetconfig $CONTRACT"
