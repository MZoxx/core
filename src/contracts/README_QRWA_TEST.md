# Qubic Smart Contract – Development Checklist & Test Reference

## Quick Reference: What Can Crash the Node

| Problem | Symptom | Solution |
|---------|---------|----------|
| `struct XXXX2 {}` missing | Node won't start / crash | Define empty struct before main struct |
| State > 1 GB | Node won't start | Reduce HashMap capacities |
| Forbidden C++ features | May compile, crashes at runtime | See forbidden list below |
| Wrong address length in `ID()` | Won't compile (parameter count) | Exactly 56 characters (without 4-char checksum) |

---

## 1. File Structure

```
src/contracts/YourContract.h     ← The contract (a single .h file)
src/contract_core/contract_def.h ← Registration (3 locations)
test/contract_yourcontract.cpp   ← GoogleTest tests
```

### Contract File Skeleton

```cpp
using namespace QPI;

// Global constants – MUST be prefixed with contract name
constexpr uint64 MYCONTRACT_SOME_VALUE = 42;

// IMPORTANT: Secondary state struct (for future EXPAND events)
struct MYCONTRACT2
{
};

// Main state struct
struct MYCONTRACT : public ContractBase
{
    // ... State Members, Procedures, Functions ...
};
```

### Registration in `contract_def.h` (3 locations!)

**Location 1** – Contract Index & Include:
```cpp
#undef CONTRACT_INDEX
#undef CONTRACT_STATE_TYPE
#undef CONTRACT_STATE2_TYPE

#define MYCONTRACT_CONTRACT_INDEX 20
#define CONTRACT_INDEX MYCONTRACT_CONTRACT_INDEX
#define CONTRACT_STATE_TYPE MYCONTRACT
#define CONTRACT_STATE2_TYPE MYCONTRACT2          // ← MUST exist!
#include "contracts/MyContract.h"
```

**Location 2** – Contract Description:
```cpp
{"MYCON", 197, 10000, sizeof(MYCONTRACT)},
// Format: {"ASSET_NAME", CONSTRUCTION_EPOCH, DESTRUCTION_EPOCH, sizeof(STATE)}
// Asset name: max 7 chars, first char A-Z, then A-Z or 0-9
```

**Location 3** – Registration:
```cpp
REGISTER_CONTRACT_FUNCTIONS_AND_PROCEDURES(MYCONTRACT);
```

---

## 2. Forbidden C++ Features (Crash Causes!)

### Absolutely forbidden – not a single occurrence allowed

| Forbidden | Reason | Alternative |
|-----------|--------|-------------|
| `*` (Pointer) | Security risk | `*` only allowed for multiplication |
| `[` and `]` | Low-level arrays without bounds check | Use `Array<T, L>` from QPI |
| `#` (Preprocessor) | `#include`, `#define`, `#ifdef` etc. | None – use `constexpr` for constants |
| `"string"` | Jump to random memory | Use `STATIC_ASSERT` macro instead of `static_assert("msg")` |
| `'c'` (Char literal) | Same as strings | Do not use |
| `float` / `double` | Non-deterministic arithmetic | `uint64`, `sint64`, `uint128` |
| `/` (Division) | Inconsistent behavior on /0 | `div<uint64>(a, b)` – returns 0 on /0 |
| `%` (Modulo) | Inconsistent behavior on %0 | `mod(a, b)` – returns 0 on %0 |
| `...` (Variadic) | Forbidden | None |
| `__` (Double underscore) | Compiler internals | Use single underscore |
| `union` | Deceptive for code audit | Use `struct` |
| `typedef` (global) | Only allowed locally | `using` only inside structs/functions |
| `const_cast` | Security risk | Do not use |
| `QpiContext` | Internal class | Do not reference |
| `::` (Scope resolution) | Only for structs/enums from contract & qpi.h | No access to foreign namespaces |

### Only allowed exception for `using`:
```cpp
using namespace QPI;  // ← OK at top of file
```

---

## 3. Variable Rules

### ❌ FORBIDDEN: Local variables on the stack
```cpp
PUBLIC_PROCEDURE(Bad)
{
    uint64 counter = 0;        // ❌ FORBIDDEN - stack variable
    for (uint64 i = 0; ...)    // ❌ FORBIDDEN - loop variable on stack
}
```

### ✅ CORRECT: Everything in `_locals` struct
```cpp
struct MyProc_locals
{
    uint64 counter;
    uint64 i;
};
PUBLIC_PROCEDURE_WITH_LOCALS(MyProc)
{
    locals.counter = 0;                    // ✅ OK
    for (locals.i = 0; locals.i < 10; locals.i++)  // ✅ OK
    {
        // ...
    }
}
```

### Available Variables in Procedures/Functions

| Variable | Available in | Description |
|----------|-------------|-------------|
| `state` | Procedures: read/write, Functions: read-only | Contract state |
| `input` | Both | Input data |
| `output` | Both | Output data (zero-initialized) |
| `locals` | `_WITH_LOCALS` variants | Local variables (zero-initialized) |
| `qpi` | Both | QPI functions (`qpi.transfer()`, `qpi.tick()`, etc.) |

---

## 4. ID() Macro – Address Format

### ❌ WRONG: 60 characters (with checksum)
```
JHUIZPGZNMTHPCZBAMSZQGBJCAAOGDAQVFHWYKLEGGRM JEJSXTREUVCPYHS
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^    ^^^^
56 characters base address                                  4 checksum
```

### ✅ CORRECT: Exactly 56 characters (without checksum)
```cpp
state.mAdminAddress = ID(
    _J, _H, _U, _I, _Z, _P, _G, _Z, _N, _M, _T, _H, _P, _C, _Z, _I,
    _B, _A, _M, _S, _Z, _Q, _G, _B, _J, _C, _O, _A, _O, _G, _D, _A,
    _Q, _V, _F, _H, _W, _Y, _K, _L, _E, _G, _G, _R, _M, _J, _E, _J,
    _S, _X, _T, _R, _E, _U, _V, _C    // ← 56 parameters, NO checksum
);
```

**Tip:** Qubic addresses are always 60 characters long (56 base + 4 checksum). In code, **strip the last 4 characters**.

---

## 5. State Size Limit

**Maximum: 1 GB (1,073,741,824 bytes)**

### Calculating HashMap Memory Usage

```
HashMap<KeyT, ValueT, L> ≈ L × (sizeof(KeyT) + sizeof(ValueT)) + L/32 × 8 + 16
```

| Example | Size |
|---------|------|
| `HashMap<id, uint64, 2097152>` | ~80.5 MB |
| `HashMap<id, uint64, 1048576>` | ~40.3 MB |
| `HashMap<id, uint64, 65536>` | ~2.5 MB |

### qRWA State Calculation (current)

| Component | Count | Size |
|-----------|-------|------|
| HashMap<id, uint64, 2097152> | 5× | ~403 MB |
| HashMap<id, bit_64, 2097152> | 2× | ~161 MB |
| Other (Arrays, scalars) | - | ~0.1 MB |
| **Total** | | **~564 MB (55% of limit)** |

---

## 6. Procedure & Function Types

### System Procedures (called automatically by the core)

| Macro | When | Purpose |
|-------|------|--------|
| `INITIALIZE()` | Once after IPO | Initialize state |
| `BEGIN_EPOCH()` | Every epoch | Snapshots, resets |
| `END_EPOCH()` | Every epoch | Evaluate voting, copy data |
| `BEGIN_TICK()` | Every tick | Before transactions |
| `END_TICK()` | Every tick | **Caution: runs EVERY tick!** |
| `POST_INCOMING_TRANSFER()` | On QU receipt | Revenue tracking |
| `PRE_ACQUIRE_SHARES()` | Asset transfer | Permission check |
| `POST_ACQUIRE_SHARES()` | After asset transfer | Bookkeeping |

### User Procedures (invoked by transactions)

```cpp
struct MyProc_input { uint64 value; };
struct MyProc_output { uint64 status; };
PUBLIC_PROCEDURE(MyProc) { /* can modify state */ }
PRIVATE_PROCEDURE(MyProc) { /* not callable by other contracts */ }
```

### User Functions (read-only queries)

```cpp
struct MyFunc_input {};
struct MyFunc_output { uint64 result; };
PUBLIC_FUNCTION(MyFunc) { /* state is const, read-only */ }
```

### Input/Output Struct Rules

Allowed types in `_input` and `_output`:
- `uint8`, `uint16`, `uint32`, `uint64`, `sint8`, `sint16`, `sint32`, `sint64`
- `bit`, `id`
- `Array<T, L>`, `BitArray<L>`
- Custom structs containing only allowed types

**Forbidden** in Input/Output: `Collection`, `HashMap`, `HashSet` (inconsistent internal state)

---

## 7. Available Container Types

| Type | Description | Note |
|------|------------|------|
| `Array<T, L>` | Fixed size, L must be 2^N | Bounds-checked |
| `BitArray<L>` | Bit array, L must be 2^N | Min. 8 bytes |
| `HashMap<K, V, L>` | Key-value store | `cleanup()` at epoch end! |
| `HashSet<K, L>` | Keys only | `cleanup()` at epoch end! |
| `Collection<T, L>` | Priority queues per ID | `cleanup()` at epoch end! |

**Important:** After removing elements from HashMap/HashSet/Collection → call `cleanupIfNeeded()` or `cleanup()` at `END_EPOCH`!

---

## 8. QPI Important Functions

```cpp
// Information
qpi.tick()                    // Current tick
qpi.epoch()                   // Current epoch
qpi.now()                     // Current time (DateAndTime)
qpi.invocator()               // Who called (user ID or contract ID)
qpi.invocationReward()        // How much QU was sent
qpi.originator()              // Original transaction creator

// Transfers
qpi.transfer(dest, amount)    // Send QU
qpi.burn(amount)              // Burn QU (fills fee reserve)

// Assets
qpi.issueAsset(name, issuer, numberOfShares, unitOfMeasurement, ...)
qpi.numberOfShares(asset, ownershipSelect, possessionSelect)
qpi.transferShareOwnershipAndPossession(name, issuer, owner, possessor, amount, newOwnerAndPossessor)
qpi.releaseShares(asset, owner, possessor, amount, destOwnership, destPossession, fee)
qpi.distributeDividends(amountPerShare)   // Dividend to contract shareholders

// Math (instead of / and %)
div<uint64>(a, b)             // Division (returns 0 on b==0)
mod(a, b)                     // Modulo (returns 0 on b==0)
sadd(a, b)                    // Saturating add (no overflow)
smul(a, b)                    // Saturating multiply
```

---

## 9. Verification Tool

### Automatic in GitHub Actions (for PRs to develop/main):
The [Qubic Contract Verification Tool](https://github.com/Franziska-Mueller/qubic-contract-verify) automatically checks all rules.

### Run manually:
```bash
# As a GitHub Action in your own repo:
- uses: Franziska-Mueller/qubic-contract-verify@v1.0.4
  with:
    filepaths: 'src/contracts/qRWA.h'

# Or build locally:
git clone https://github.com/Franziska-Mueller/qubic-contract-verify
cd qubic-contract-verify
cd deps/CppParser && mkdir builds && cd builds && cmake .. && make && cd ../../..
mkdir build && cd build && cmake .. && make
./src/Release/contractverify /path/to/qRWA.h
```

---

## 10. Pre-Deployment Checklist

- [ ] `struct XXXX2 {}` present (for `CONTRACT_STATE2_TYPE`)
- [ ] No forbidden C++ features (see section 2)
- [ ] All variables in `_locals` structs (no stack variables)
- [ ] `ID()` macro: exactly 56 characters per address
- [ ] State size < 1 GB
- [ ] `REGISTER_USER_FUNCTIONS_AND_PROCEDURES()` implemented
- [ ] Registration in `contract_def.h` at all 3 locations
- [ ] `div<>()` and `mod()` instead of `/` and `%`
- [ ] No `#include` in final code
- [ ] Input/Output structs use only allowed types
- [ ] HashMap/HashSet `cleanup()` at epoch end
- [ ] Global constants prefixed with contract name (`QRWA_...`)
- [ ] Tests written in GoogleTest framework
- [ ] Compiles without warnings
- [ ] Contract verification tool passed
- [ ] Testnet stable with multiple nodes

---

## 11. qRWA-Specific Notes

### Current Test Configuration
- Branch: `qrwa-dedicated-pool`
- Contract Index: 20
- Construction Epoch: 197
- Payout trigger: `qpi.tick() >= 44602200` (test mode)
- 6 governance addresses in `INITIALIZE()` (all 56 chars)

### Known Fixes (already applied)
1. **`struct QRWA2 {}`** added – was completely missing, crashed the node
2. **Addresses trimmed to 56 characters** – `ID()` macro expects exactly 56 parameters

### Reset for Production
```cpp
// In END_TICK: replace test conditions with:
if (qpi.dayOfWeek(...) == QRWA_PAYOUT_DAY && locals.now.getHour() == QRWA_PAYOUT_HOUR)
// and:
if (locals.msSinceLastPayout >= QRWA_MIN_PAYOUT_INTERVAL_MS)
```

---

## 12. Pool System & Revenue Distribution

### Overview: 3 Revenue Inputs → 6 Internal Pools → 3 Recipient Groups

```
                    ┌─────────────────────────┐
  QUTIL Transfer ──►│   Revenue Pool A        │──► Gov Fees (50%) ──► Electricity (35%)
  (SC source)       │   mRevenuePoolA         │                      Maintenance (5%)
                    └────────────┬────────────┘                      Reinvestment (10%)
                                 │ Remainder (50%)
                                 ▼
                    ┌─────────────────────────┐
  User Transfer ───►│   Revenue Pool B        │
  (wallet source)   │   mRevenuePoolB         │
                    └────────────┬────────────┘
                                 │
                    Pool A (after fees) + Pool B = totalDistribution
                                 │
                    ┌────────────┴────────────┐
                    │                         │
                    ▼ 90%                     ▼ 10%
           ┌───────────────┐         ┌───────────────┐
           │ QMINE Div Pool│         │ qRWA Div Pool │
           │ mQmineDividend│         │ mQRWADividend │
           │ Pool          │         │ Pool          │
           └───────┬───────┘         └───────┬───────┘
                   │                         │
                   ▼                         ▼
           QMINE Holders             qRWA Holders
           (Epoch Snapshot)          (Live, ≥100K QMINE/Share)

                    ┌─────────────────────────┐
  Dedicated Addr ──►│ Dedicated Revenue Pool  │
  (configured)      │ mDedicatedRevenuePool   │
                    └────────────┬────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
                    ▼ 90%                     ▼ 10%
           ┌───────────────┐         ┌───────────────┐
           │ → QMINE Div   │         │ Dedicated     │
           │   Pool (above)│         │ qRWA Div Pool │
           └───────────────┘         │ mDedicatedQRWA│
                                     │ DividendPool  │
                                     └───────┬───────┘
                                             │
                                             ▼
                                     qRWA Holders
                                     (Live, ≥100K QMINE/Share)
```

### Revenue Inputs (POST_INCOMING_TRANSFER)

Every incoming QU transfer is routed to one of three revenue pools based on `sourceId`:

| Source | Condition | Target Pool | Gov Fees? |
|--------|-----------|-------------|-----------|
| QUTIL Contract | `sourceId == id(QUTIL_CONTRACT_INDEX)` | **Pool A** (`mRevenuePoolA`) | ✅ Yes (50%) |
| Dedicated Address | `sourceId == mDedicatedRevenueAddress` | **Dedicated** (`mDedicatedRevenuePool`) | ❌ No |
| Everything else (User/SC) | `sourceId != NULL_ID` | **Pool B** (`mRevenuePoolB`) | ❌ No |

**Important:** Direct `sendtoaddress` transfers from a wallet **always go to Pool B** — for Pool A the transfer must go through QUTIL (e.g., `SendToManyV1`). **Exception:** Transfers from the Dedicated Revenue Address (`PDQTKKIRSIGAGAOLJWZWTCBSFCYAIZIRYCHEBKHBJHHBJNJHWLYGXSVEQEFC`) go to the **Dedicated Pool** (no Gov Fees).

### Governance Fees (Pool A only)

Before the 90/10 split, governance fees are deducted from Pool A:

```
Gov Fee Total = electricityPercent + maintenancePercent + reinvestmentPercent
```

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `electricityPercent` | 350‰ (35%) | Mining farm electricity costs |
| `maintenancePercent` | 50‰ (5%) | Maintenance & operations |
| `reinvestmentPercent` | 100‰ (10%) | Hardware reinvestment |
| **Total** | **500‰ (50%)** | **Maximum 1000‰ (100%)** |

These percentages are changeable via governance voting by QMINE holders. Each percentage is applied individually to `mRevenuePoolA`:

```cpp
electricityPayout = (mRevenuePoolA × electricityPercent) / 1000
maintenancePayout = (mRevenuePoolA × maintenancePercent) / 1000
reinvestmentPayout = (mRevenuePoolA × reinvestmentPercent) / 1000
mRevenuePoolA -= (electricityPayout + maintenancePayout + reinvestmentPayout)
```

### 90/10 Split (QMINE vs. qRWA)

After deducting gov fees, Pool A (remainder) + Pool B are combined:

```
totalDistribution = remainingPoolA + poolB

QMINE share = totalDistribution × 900 / 1000  (90%)
qRWA share  = totalDistribution - QMINE share (10%, rounding remainder goes here)
```

| Constant | Value | Meaning |
|----------|-------|---------|
| `QRWA_QMINE_HOLDER_PERCENT` | 900 | 90% for QMINE holders |
| `QRWA_QRWA_HOLDER_PERCENT` | 100 | 10% for qRWA holders |
| `QRWA_PERCENT_DENOMINATOR` | 1000 | Base (= 100%) |

The Dedicated Pool is split identically: 90% → QMINE Div Pool, 10% → **separate** Dedicated qRWA Div Pool.

### QMINE Holder Distribution

**Data source:** Epoch snapshots (NOT live)

```
BEGIN_EPOCH: Snapshot of all QMINE holders → mBeginEpochBalances
END_EPOCH:   Snapshot of all QMINE holders → mEndEpochBalances
             Copy to mPayoutBeginBalances / mPayoutEndBalances
END_TICK:    Distribution from mPayoutBeginBalances
```

**Eligibility:**
- `eligibleBalance = min(beginBalance, endBalance)` — holders who sold QMINE during the epoch only receive based on the lower balance
- Prevents "epoch hopping" (buy → snapshot → sell)

**Per-holder calculation:**
```
payout = (eligibleBalance × qmineDividendPool) / payoutTotalQmineBegin
```

**Important — First Epoch:** `mPayoutTotalQmineBegin` is 0 until the first `END_EPOCH` has run. QMINE holders **only receive payouts starting from the 2nd epoch**. The QMINE share accumulates in `mQmineDividendPool` and is distributed in one lump sum after the epoch transition.

**QMINE Dev (Remainder):** After distributing to all eligible holders, the `qmineDevAddress` receives the entire remaining balance of the pool. This captures rounding differences and the shares of holders who lost QMINE between begin/end epoch.

### qRWA Holder Distribution

**Data source:** Live `AssetPossessionIterator` (works immediately from epoch 1)

**Eligibility:** Each qRWA holder must hold ≥100,000 QMINE per qRWA share:
```
requiredQmine = qrwaShares × 100,000
eligible = (actualQmine ≥ requiredQmine)
```

| qRWA Shares | Required QMINE |
|-------------|----------------|
| 1 | 100,000 |
| 3 | 300,000 |
| 10 | 1,000,000 |
| 50 | 5,000,000 |

**Calculation (2-pass method):**

1. **Pass 1:** Count all eligible shares → `eligibleShares`
2. **Pass 2:** Distribute proportionally:
```
amountPerShare = qRWADividendPool / eligibleShares
payout = amountPerShare × holderShares
```

**Ineligible holders** are completely skipped — their share is automatically distributed proportionally to the qualified holders.

**Rounding remainder:** At most `eligibleShares - 1` QU remain in the pool and are distributed with the next payout.

**Dedicated qRWA Pool:** Identical logic, but from the separate `mDedicatedQRWADividendPool` — distributed independently from the regular qRWA pool.

### Payout Timing

| Mode | Trigger | Configuration |
|------|---------|---------------|
| **Testing** | Every 20 ticks | `QRWA_PAYOUT_TICK_INTERVAL = 20` |
| **Production** | Friday 12:00 UTC, min. 6 days apart | `QRWA_PAYOUT_DAY`, `QRWA_PAYOUT_HOUR`, `QRWA_MIN_PAYOUT_INTERVAL_MS` |

### Query Functions

| Function | Index | Output | Description |
|----------|-------|--------|-------------|
| `GetDividendBalances` | 5 | `{ revenuePoolA, revenuePoolB, qmineDividendPool, qrwaDividendPool, dedicatedRevenuePool, dedicatedQRWADividendPool }` | Current pool balances (incl. dedicated) |
| `GetTotalDistributed` | 6 | `{ totalQmineDistributed, totalQRWADistributed }` | Cumulative distributions |
| `GetGovParams` | 1 | `{ admin, electricity, maintenance, reinvestment, qmineDev, elecPct, maintPct, reinvPct }` | Gov addresses & percentages |

### Worked Example

Incoming: 10,000,000 QU via QUTIL → Pool A

```
1) Gov Fees (from Pool A):
   Electricity:  10M × 350/1000 = 3,500,000 QU
   Maintenance:  10M × 50/1000  =   500,000 QU
   Reinvestment: 10M × 100/1000 = 1,000,000 QU
   → Gov Total: 5,000,000 QU

2) Remaining Pool A: 10M - 5M = 5,000,000 QU
   Pool B: 0 (no user transfer)
   → totalDistribution = 5,000,000 QU

3) 90/10 Split:
   QMINE Div Pool: 5M × 900/1000 = 4,500,000 QU
   qRWA Div Pool:  5M - 4.5M     =   500,000 QU

4) qRWA Distribution (example: 50 eligible shares out of 676 total):
   amountPerShare = 500,000 / 50 = 10,000 QU/share
   Holder with 3 shares: 3 × 10,000 = 30,000 QU
   Holder with 1 share:  1 × 10,000 = 10,000 QU
```
