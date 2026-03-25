#!/bin/bash
# =============================================================================
# qRacel Testnet - Mass Bet Placement Script
# Places bets from multiple seeds on the active 10m round
# =============================================================================

NODE="135.181.160.185"
PORT="31841"
CONTRACT="25"
CLI="./qubic-cli/build-macos-aarch64/qubic-cli"
SCHEDULE_TICK=20

# Seeds (1-19, skip 20 = admin)
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

# Defaults
BET_AMOUNT=1000000000  # 1B QU
DURATION="10m"
ROUND_ID=""
MODE="auto"  # auto = get active round, manual = use provided round id

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -r, --round ID        Round ID to bet on (default: auto-detect active/pending round)"
  echo "  -a, --amount NUM      Bet amount per seed (default: 1000000000 = 1B QU)"
  echo "  -d, --duration TYPE   Duration type: 10m|60m|6h|24h (default: 10m)"
  echo "  -s, --side SIDE       Force all bets to one side: up|down (default: alternating)"
  echo "  -n, --count NUM       Number of seeds to use, 1-19 (default: all 19)"
  echo "  --status              Just show active round status, don't bet"
  echo "  --config              Show contract config"
  echo "  --claim-all           Claim winnings for all bet IDs 0..betCount-1"
  echo "  --create-future NUM   Create NUM future 10m rounds starting from next boundary"
  echo "  --setup               Fund contract (10B QU) + set autoCreate mask=3"
  echo "  -h, --help            Show this help"
  exit 0
}

# Parse args
FORCE_SIDE=""
SEED_COUNT=19
STATUS_ONLY=false
CONFIG_ONLY=false
CLAIM_ALL=false
CREATE_FUTURE=0
SETUP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--round) ROUND_ID="$2"; MODE="manual"; shift 2;;
    -a|--amount) BET_AMOUNT="$2"; shift 2;;
    -d|--duration) DURATION="$2"; shift 2;;
    -s|--side) FORCE_SIDE="$2"; shift 2;;
    -n|--count) SEED_COUNT="$2"; shift 2;;
    --status) STATUS_ONLY=true; shift;;
    --config) CONFIG_ONLY=true; shift;;
    --claim-all) CLAIM_ALL=true; shift;;
    --create-future) CREATE_FUTURE="$2"; shift 2;;
    --setup) SETUP=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

# --- Config ---
if $CONFIG_ONLY; then
  echo "=== Contract Config ==="
  $CLI -nodeip $NODE -nodeport $PORT -qracelgetconfig $CONTRACT
  exit 0
fi

# --- Status ---
show_status() {
  echo "=== Active Round ($DURATION) ==="
  $CLI -nodeip $NODE -nodeport $PORT -qracelgetactiveround $CONTRACT "$DURATION"
}

if $STATUS_ONLY; then
  show_status
  exit 0
fi

# --- Setup (fund + autoCreate) ---
if $SETUP; then
  echo "=== Setup: Fund 10B QU ==="
  $CLI -nodeip $NODE -nodeport $PORT -seed "$ADMIN_SEED" -scheduletick $SCHEDULE_TICK -enabletestcontracts -qracelfund $CONTRACT 10000000000
  echo "Waiting 20s for TX..."
  sleep 20
  echo "=== Setup: Set autoCreate mask=3 (10m+60m) ==="
  $CLI -nodeip $NODE -nodeport $PORT -seed "$ADMIN_SEED" -scheduletick $SCHEDULE_TICK -qracelsetautocreate $CONTRACT 3
  echo "Waiting 20s for TX..."
  sleep 20
  echo "=== Config after setup ==="
  $CLI -nodeip $NODE -nodeport $PORT -qracelgetconfig $CONTRACT
  exit 0
fi

# --- Create Future Rounds ---
if [ "$CREATE_FUTURE" -gt 0 ] 2>/dev/null; then
  echo "=== Creating $CREATE_FUTURE future 10m rounds ==="
  
  # Get current UTC time
  CURRENT_HOUR=$(date -u +%H | sed 's/^0//')
  CURRENT_MIN=$(date -u +%M | sed 's/^0//')
  
  # Calculate next 10-minute boundary
  NEXT_MIN=$(( ((CURRENT_MIN / 10) + 1) * 10 ))
  NEXT_HOUR=$CURRENT_HOUR
  if [ $NEXT_MIN -ge 60 ]; then
    NEXT_MIN=$((NEXT_MIN - 60))
    NEXT_HOUR=$((NEXT_HOUR + 1))
  fi
  NEXT_HOUR=$((NEXT_HOUR % 24))
  
  echo "Current UTC: $(printf '%02d:%02d' $CURRENT_HOUR $CURRENT_MIN)"
  echo "First round starts at: $(printf '%02d:%02d' $NEXT_HOUR $NEXT_MIN)"
  echo ""
  
  for ((r=0; r<CREATE_FUTURE; r++)); do
    ROUND_HOUR=$NEXT_HOUR
    ROUND_MIN=$((NEXT_MIN + r * 10))
    
    # Handle minute/hour overflow
    while [ $ROUND_MIN -ge 60 ]; do
      ROUND_MIN=$((ROUND_MIN - 60))
      ROUND_HOUR=$((ROUND_HOUR + 1))
    done
    ROUND_HOUR=$((ROUND_HOUR % 24))
    
    TIME_STR=$(printf '%02d:%02d' $ROUND_HOUR $ROUND_MIN)
    echo -n "Creating future round #$((r+1)) at $TIME_STR ... "
    
    OUTPUT=$($CLI -nodeip $NODE -nodeport $PORT -seed "$ADMIN_SEED" -scheduletick $SCHEDULE_TICK -qracelcreateround $CONTRACT 10m 0 "$TIME_STR" 2>&1)
    
    if echo "$OUTPUT" | grep -q "has been sent"; then
      echo "TX sent"
    else
      echo "FAILED"
      echo "  $OUTPUT" | head -3
    fi
    
    sleep 2
  done
  
  echo ""
  echo "Waiting 25s for TXs to confirm..."
  sleep 25
  echo ""
  echo "=== Config after creation ==="
  $CLI -nodeip $NODE -nodeport $PORT -qracelgetconfig $CONTRACT
  exit 0
fi

# --- Claim All ---
if $CLAIM_ALL; then
  echo "=== Claiming all winnings ==="
  # Get bet count from config
  BET_COUNT=$($CLI -nodeip $NODE -nodeport $PORT -qracelgetconfig $CONTRACT 2>&1 | grep "betCount:" | awk '{print $2}')
  if [ -z "$BET_COUNT" ] || [ "$BET_COUNT" = "0" ]; then
    echo "No bets to claim."
    exit 0
  fi
  echo "Total bets: $BET_COUNT"
  for ((bid=0; bid<BET_COUNT; bid++)); do
    # Cycle through seeds
    idx=$((bid % SEED_COUNT))
    SEED="${SEEDS[$idx]}"
    echo "Claiming bet #$bid with seed #$((idx+1))..."
    $CLI -nodeip $NODE -nodeport $PORT -seed "$SEED" -qracelclaim $CONTRACT $bid -scheduletick $SCHEDULE_TICK
    sleep 1
  done
  exit 0
fi

# --- Auto-detect round ---
if [ "$MODE" = "auto" ]; then
  echo "=== Detecting active $DURATION round ==="
  ACTIVE_OUTPUT=$($CLI -nodeip $NODE -nodeport $PORT -qracelgetactiveround $CONTRACT "$DURATION" 2>&1)
  echo "$ACTIVE_OUTPUT"
  
  ROUND_ID=$(echo "$ACTIVE_OUTPUT" | grep "RoundId:" | awk '{print $2}')
  if [ -z "$ROUND_ID" ] || [ "$ROUND_ID" = "0" ]; then
    echo "ERROR: No active round found for $DURATION. Wait for auto-create or create manually."
    exit 1
  fi
  echo ""
  echo "Detected Round ID: $ROUND_ID"
fi

# --- Place bets ---
echo ""
echo "=== Placing bets ==="
echo "Round: $ROUND_ID | Amount: $BET_AMOUNT | Seeds: $SEED_COUNT"
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
  
  echo -n "Seed #$((i+1)) betting $SIDE ($BET_AMOUNT QU) on round $ROUND_ID ... "
  OUTPUT=$($CLI -nodeip $NODE -nodeport $PORT -seed "$SEED" -qracelbet $CONTRACT $ROUND_ID $SIDE $BET_AMOUNT -scheduletick $SCHEDULE_TICK 2>&1)
  
  if echo "$OUTPUT" | grep -q "has been stored"; then
    echo "TX submitted"
    ((SUCCESS++))
  else
    echo "FAILED"
    echo "  $OUTPUT" | head -3
    ((FAIL++))
  fi
  
  # Small delay to avoid overwhelming the node
  sleep 1
done

echo ""
echo "=== Done ==="
echo "Submitted: $SUCCESS | Failed: $FAIL"
echo ""
echo "Wait ~20 ticks, then check round status:"
echo "  $CLI -nodeip $NODE -nodeport $PORT -qracelgetround $CONTRACT $ROUND_ID"
