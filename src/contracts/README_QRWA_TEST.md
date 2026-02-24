# Qubic Smart Contract – Entwicklungs-Checkliste & Testreferenz

## Schnellübersicht: Was den Node crashen kann

| Problem | Symptom | Lösung |
|---------|---------|--------|
| `struct XXXX2 {}` fehlt | Node startet nicht / Crash | Leere Struct vor der Haupt-Struct definieren |
| State > 1 GB | Node startet nicht | HashMap-Kapazitäten reduzieren |
| Verbotene C++ Features | Kompiliert evtl., crasht zur Laufzeit | Siehe Verbotsliste unten |
| Falsche Adress-Länge in `ID()` | Kompiliert nicht (Parameteranzahl) | Genau 56 Zeichen (ohne 4-Char Checksum) |

---

## 1. Dateistruktur

```
src/contracts/YourContract.h    ← Der Contract (eine einzige .h Datei)
src/contract_core/contract_def.h ← Registrierung (3 Stellen)
test/contract_yourcontract.cpp   ← GoogleTest Tests
```

### Contract-Datei Grundgerüst

```cpp
using namespace QPI;

// Globale Konstanten – MÜSSEN mit Contract-Name prefixed sein
constexpr uint64 MYCONTRACT_SOME_VALUE = 42;

// WICHTIG: Sekundäre State-Struct (für zukünftige EXPAND Events)
struct MYCONTRACT2
{
};

// Haupt-State-Struct
struct MYCONTRACT : public ContractBase
{
    // ... State Members, Procedures, Functions ...
};
```

### Registrierung in `contract_def.h` (3 Stellen!)

**Stelle 1** – Contract Index & Include:
```cpp
#undef CONTRACT_INDEX
#undef CONTRACT_STATE_TYPE
#undef CONTRACT_STATE2_TYPE

#define MYCONTRACT_CONTRACT_INDEX 20
#define CONTRACT_INDEX MYCONTRACT_CONTRACT_INDEX
#define CONTRACT_STATE_TYPE MYCONTRACT
#define CONTRACT_STATE2_TYPE MYCONTRACT2          // ← MUSS existieren!
#include "contracts/MyContract.h"
```

**Stelle 2** – Contract Description:
```cpp
{"MYCON", 197, 10000, sizeof(MYCONTRACT)},
// Format: {"ASSET_NAME", CONSTRUCTION_EPOCH, DESTRUCTION_EPOCH, sizeof(STATE)}
// Asset-Name: max 7 Zeichen, erster Buchstabe A-Z, danach A-Z oder 0-9
```

**Stelle 3** – Registrierung:
```cpp
REGISTER_CONTRACT_FUNCTIONS_AND_PROCEDURES(MYCONTRACT);
```

---

## 2. Verbotene C++ Features (Crashverursacher!)

### Absolut verboten – kein einziges Vorkommen erlaubt

| Verboten | Grund | Alternative |
|----------|-------|-------------|
| `*` (Pointer) | Sicherheitsrisiko | `*` nur für Multiplikation erlaubt |
| `[` und `]` | Low-Level Arrays ohne Bounds-Check | `Array<T, L>` aus QPI verwenden |
| `#` (Preprocessor) | `#include`, `#define`, `#ifdef` etc. | Keine – nur `constexpr` für Konstanten |
| `"string"` | Sprung zu zufälligem Speicher | `STATIC_ASSERT` Macro statt `static_assert("msg")` |
| `'c'` (Char-Literal) | Wie Strings | Nicht verwenden |
| `float` / `double` | Nicht deterministische Arithmetik | `uint64`, `sint64`, `uint128` |
| `/` (Division) | Inkonsistentes Verhalten bei /0 | `div<uint64>(a, b)` – gibt 0 bei /0 |
| `%` (Modulo) | Inkonsistentes Verhalten bei %0 | `mod(a, b)` – gibt 0 bei %0 |
| `...` (Variadic) | Verboten | Keine |
| `__` (Doppel-Underscore) | Compiler-Interna | Einfachen Underscore verwenden |
| `union` | Täuschung bei Code-Audit | `struct` verwenden |
| `typedef` (global) | Nur lokal erlaubt | `using` nur in Structs/Funktionen |
| `const_cast` | Sicherheitsrisiko | Nicht verwenden |
| `QpiContext` | Interne Klasse | Nicht referenzieren |
| `::` (Scope Resolution) | Nur für Structs/Enums aus Contract & qpi.h | Kein Zugriff auf fremde Namespaces |

### Einzige erlaubte Ausnahme bei `using`:
```cpp
using namespace QPI;  // ← OK am Dateianfang
```

---

## 3. Variablen-Regeln

### ❌ VERBOTEN: Lokale Variablen auf dem Stack
```cpp
PUBLIC_PROCEDURE(Bad)
{
    uint64 counter = 0;        // ❌ VERBOTEN - Stack-Variable
    for (uint64 i = 0; ...)    // ❌ VERBOTEN - Loop-Variable auf Stack
}
```

### ✅ RICHTIG: Alles in `_locals` Struct
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

### Verfügbare Variablen in Procedures/Functions

| Variable | Verfügbar in | Beschreibung |
|----------|-------------|--------------|
| `state` | Procedures: read/write, Functions: read-only | Contract State |
| `input` | Beide | Eingabedaten |
| `output` | Beide | Ausgabedaten (mit 0 initialisiert) |
| `locals` | `_WITH_LOCALS` Varianten | Lokale Variablen (mit 0 initialisiert) |
| `qpi` | Beide | QPI-Funktionen (`qpi.transfer()`, `qpi.tick()`, etc.) |

---

## 4. ID() Macro – Adressformat

### ❌ FALSCH: 60 Zeichen (mit Checksum)
```
JHUIZPGZNMTHPCZBAMSZQGBJCAAOGDAQVFHWYKLEGGRM JEJSXTREUVCPYHS
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^    ^^^^
56 Zeichen Basis-Adresse                                    4 Checksum
```

### ✅ RICHTIG: Genau 56 Zeichen (ohne Checksum)
```cpp
state.mAdminAddress = ID(
    _J, _H, _U, _I, _Z, _P, _G, _Z, _N, _M, _T, _H, _P, _C, _Z, _I,
    _B, _A, _M, _S, _Z, _Q, _G, _B, _J, _C, _O, _A, _O, _G, _D, _A,
    _Q, _V, _F, _H, _W, _Y, _K, _L, _E, _G, _G, _R, _M, _J, _E, _J,
    _S, _X, _T, _R, _E, _U, _V, _C    // ← 56 Parameter, KEINE Checksum
);
```

**Tipp:** Qubic-Adressen sind immer 60 Zeichen lang (56 Basis + 4 Checksum). Im Code die **letzten 4 Zeichen abschneiden**.

---

## 5. State-Größenlimit

**Maximum: 1 GB (1.073.741.824 Bytes)**

### HashMap Speicherverbrauch berechnen

```
HashMap<KeyT, ValueT, L> ≈ L × (sizeof(KeyT) + sizeof(ValueT)) + L/32 × 8 + 16
```

| Beispiel | Größe |
|----------|-------|
| `HashMap<id, uint64, 2097152>` | ~80.5 MB |
| `HashMap<id, uint64, 1048576>` | ~40.3 MB |
| `HashMap<id, uint64, 65536>` | ~2.5 MB |

### qRWA State-Berechnung (aktuell)

| Komponente | Anzahl | Größe |
|-----------|--------|-------|
| HashMap<id, uint64, 2097152> | 5× | ~403 MB |
| HashMap<id, bit_64, 2097152> | 2× | ~161 MB |
| Sonstige (Arrays, Skalare) | - | ~0.1 MB |
| **Gesamt** | | **~564 MB (55% vom Limit)** |

---

## 6. Procedure & Function Typen

### System Procedures (automatisch vom Core aufgerufen)

| Macro | Wann | Zweck |
|-------|------|-------|
| `INITIALIZE()` | Einmal nach IPO | State initialisieren |
| `BEGIN_EPOCH()` | Jede Epoch | Snapshots, Resets |
| `END_EPOCH()` | Jede Epoch | Voting auswerten, Daten kopieren |
| `BEGIN_TICK()` | Jeder Tick | Vor Transaktionen |
| `END_TICK()` | Jeder Tick | **Vorsicht: läuft JEDEN Tick!** |
| `POST_INCOMING_TRANSFER()` | Bei QU-Eingang | Revenue-Tracking |
| `PRE_ACQUIRE_SHARES()` | Asset-Transfer | Erlaubnis prüfen |
| `POST_ACQUIRE_SHARES()` | Nach Asset-Transfer | Buchführung |

### User Procedures (durch Transaktionen aufgerufen)

```cpp
struct MyProc_input { uint64 value; };
struct MyProc_output { uint64 status; };
PUBLIC_PROCEDURE(MyProc) { /* kann state ändern */ }
PRIVATE_PROCEDURE(MyProc) { /* nicht von anderen Contracts aufrufbar */ }
```

### User Functions (read-only Abfragen)

```cpp
struct MyFunc_input {};
struct MyFunc_output { uint64 result; };
PUBLIC_FUNCTION(MyFunc) { /* state ist const, nur lesen */ }
```

### Input/Output Struct Regeln

Erlaubte Typen in `_input` und `_output`:
- `uint8`, `uint16`, `uint32`, `uint64`, `sint8`, `sint16`, `sint32`, `sint64`
- `bit`, `id`
- `Array<T, L>`, `BitArray<L>`
- Eigene Structs die nur erlaubte Typen enthalten

**Verboten** in Input/Output: `Collection`, `HashMap`, `HashSet` (inkonsistenter interner State)

---

## 7. Verfügbare Container-Typen

| Typ | Beschreibung | Hinweis |
|-----|-------------|---------|
| `Array<T, L>` | Feste Größe, L muss 2^N sein | Bounds-geprüft |
| `BitArray<L>` | Bit-Array, L muss 2^N sein | Min. 8 Bytes |
| `HashMap<K, V, L>` | Key-Value Store | `cleanup()` am Epochenende! |
| `HashSet<K, L>` | Nur Keys | `cleanup()` am Epochenende! |
| `Collection<T, L>` | Priority Queues pro ID | `cleanup()` am Epochenende! |

**Wichtig:** Nach Entfernen von Elementen aus HashMap/HashSet/Collection → `cleanupIfNeeded()` oder `cleanup()` am `END_EPOCH` aufrufen!

---

## 8. QPI Wichtige Funktionen

```cpp
// Informationen
qpi.tick()                    // Aktueller Tick
qpi.epoch()                   // Aktuelle Epoch
qpi.now()                     // Aktuelle Zeit (DateAndTime)
qpi.invocator()               // Wer hat aufgerufen (User-ID oder Contract-ID)
qpi.invocationReward()        // Wie viel QU wurde gesendet
qpi.originator()              // Ursprünglicher Transaktions-Ersteller

// Transfers
qpi.transfer(dest, amount)    // QU senden
qpi.burn(amount)              // QU verbrennen (füllt Fee-Reserve)

// Assets
qpi.issueAsset(name, issuer, numberOfShares, unitOfMeasurement, ...)
qpi.numberOfShares(asset, ownershipSelect, possessionSelect)
qpi.transferShareOwnershipAndPossession(name, issuer, owner, possessor, amount, newOwnerAndPossessor)
qpi.releaseShares(asset, owner, possessor, amount, destOwnership, destPossession, fee)
qpi.distributeDividends(amountPerShare)   // Dividende an Contract-Shareholder

// Mathematik (statt / und %)
div<uint64>(a, b)             // Division (gibt 0 bei b==0)
mod(a, b)                     // Modulo (gibt 0 bei b==0)
sadd(a, b)                    // Saturating Add (kein Overflow)
smul(a, b)                    // Saturating Multiply
```

---

## 9. Verifikations-Tool

### Automatisch in GitHub Actions (für PRs zu develop/main):
Das [Qubic Contract Verification Tool](https://github.com/Franziska-Mueller/qubic-contract-verify) prüft automatisch alle Regeln.

### Manuell ausführen:
```bash
# Als GitHub Action in eigenem Repo:
- uses: Franziska-Mueller/qubic-contract-verify@v1.0.4
  with:
    filepaths: 'src/contracts/qRWA.h'

# Oder lokal bauen:
git clone https://github.com/Franziska-Mueller/qubic-contract-verify
cd qubic-contract-verify
cd deps/CppParser && mkdir builds && cd builds && cmake .. && make && cd ../../..
mkdir build && cd build && cmake .. && make
./src/Release/contractverify /path/to/qRWA.h
```

---

## 10. Test-Checkliste vor Deployment

- [ ] `struct XXXX2 {}` vorhanden (für `CONTRACT_STATE2_TYPE`)
- [ ] Keine verbotenen C++ Features (siehe Abschnitt 2)
- [ ] Alle Variablen in `_locals` Structs (keine Stack-Variablen)
- [ ] `ID()` Macro: genau 56 Zeichen pro Adresse
- [ ] State-Größe < 1 GB
- [ ] `REGISTER_USER_FUNCTIONS_AND_PROCEDURES()` implementiert
- [ ] Registrierung in `contract_def.h` an allen 3 Stellen
- [ ] `div<>()` und `mod()` statt `/` und `%`
- [ ] Keine `#include` im finalen Code
- [ ] Input/Output Structs nur erlaubte Typen
- [ ] HashMap/HashSet `cleanup()` am Epochenende
- [ ] Globale Konstanten mit Contract-Name prefixed (`QRWA_...`)
- [ ] Tests in GoogleTest Framework geschrieben
- [ ] Kompiliert ohne Warnings
- [ ] Contract Verification Tool bestanden
- [ ] Testnet mit mehreren Nodes stabil

---

## 11. qRWA-spezifische Notizen

### Aktuelle Test-Konfiguration
- Branch: `qrwa-dedicated-pool`
- Contract Index: 20
- Construction Epoch: 197
- Payout-Trigger: `qpi.tick() >= 44602200` (Test-Modus)
- 6 Governance-Adressen in `INITIALIZE()` (alle 56 Chars)

### Bekannte Fixes (bereits angewendet)
1. **`struct QRWA2 {}`** hinzugefügt – fehlte komplett, crashte den Node
2. **Adressen auf 56 Zeichen** getrimmt – `ID()` Macro erwartet exakt 56 Parameter

### Für Production zurücksetzen
```cpp
// In END_TICK: Test-Bedingungen ersetzen durch:
if (qpi.dayOfWeek(...) == QRWA_PAYOUT_DAY && locals.now.getHour() == QRWA_PAYOUT_HOUR)
// und:
if (locals.msSinceLastPayout >= QRWA_MIN_PAYOUT_INTERVAL_MS)
```
