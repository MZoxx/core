# qRWA Smart Contract – Benutzerhandbuch

## Überblick

Der **qRWA Smart Contract** (Contract Index: 20) verwaltet die Einnahmenverteilung aus verschiedenen Mining-Quellen an die Inhaber von **QMINE**- und **qRWA**-Token. Alle Einnahmen fließen über drei getrennte Pools, werden automatisch nach festen Regeln aufgeteilt und regelmäßig an berechtigte Halter ausgeschüttet.

---

## Die drei Revenue-Pools

### Pool A – Qubic Mining (Mined Funds)

- **Herkunft:** Einnahmen aus dem Qubic-Mining-Betrieb
- **Quellen:** Transfers vom QUTIL-Contract (`SendToMany`) oder von der konfigurierten Pool-A-Revenue-Adresse (QMINE-Issuer / Mining-Wallet)
- **Besonderheit:** Vor der Ausschüttung werden zuerst **Governance-Gebühren** (Strom, Wartung, Reinvestment) abgezogen

### Pool B – Nutzer & Sonstige

- **Herkunft:** Alle anderen Einzahlungen, die nicht Pool A oder Pool C zugeordnet sind
- **Quellen:** Transfers von Nutzer-Wallets, sonstigen Contracts oder Spenden
- **Keine Gebühren:** Auf Pool B werden keine Governance-Gebühren erhoben

### Pool C – Dedicated BTC Mining

- **Herkunft:** Einnahmen aus dediziertem BTC-Mining
- **Quelle:** Transfers von einer festgelegten **Dedicated Revenue Address**
- **Besonderheit:** Der qRWA-Anteil aus Pool C geht nur an Halter, die eine Mindestmenge QMINE pro qRWA-Share besitzen (Premium-Anforderung, 100k qmine/qRWA)

---

## Einnahmen-Routing (POST_INCOMING_TRANSFER)

Jede Einzahlung an den Smart Contract wird automatisch dem richtigen Pool zugeordnet:

| Absender | Ziel-Pool |
|---|---|
| Dedicated Revenue Address | **Pool C** (BTC Mining) |
| QUTIL-Contract oder Pool-A-Revenue-Adresse | **Pool A** (Qubic Mining) |
| Alle anderen Adressen | **Pool B** (Nutzer & Sonstige) |

---

## Wann werden Payouts ausgeschüttet?

Payouts werden **vollautomatisch** vom Smart Contract ausgeführt — kein Mensch muss einen Knopf drücken.

| Modus | Wann? | Wie oft? |
|---|---|---|
| **Produktion (Mainnet)** | Jeden **Freitag um 12:00 UTC** | Maximal 1× pro Woche, mindestens 6 Tage Abstand |
| **Testnet** | Automatisch alle **20 Ticks** (~wenige Sekunden) | Sehr häufig, zum Testen |

> **Wichtig:** Es gibt keinen manuellen Auszahlungsknopf. Wenn der Zeitpunkt erreicht ist und Geld in den Pools liegt, wird automatisch verteilt. Wenn kein Geld in den Pools liegt, passiert nichts.

---

## Werden Payouts sofort ausgezahlt?

**Ja** — sobald der Smart Contract die Verteilung ausführt, landen die QU **direkt auf deiner Wallet-Adresse**. Es gibt keine Wartezeit, kein Claiming, kein manuelles Abholen. Der Transfer passiert on-chain im selben Tick.

Allerdings: **Nicht jeder bekommt automatisch etwas.** Es gelten klare Regeln, wer berechtigt ist (siehe unten).

---

## Die Snapshot-Mechanik: Warum zählt nicht dein aktueller Bestand?

Der Smart Contract verwendet ein **Epoch-Snapshot-System**, um faire Ausschüttungen zu gewährleisten und Manipulationen zu verhindern.

### Was ist eine Epoche?

Eine Epoche ist eine feste Zeitperiode im Qubic-Netzwerk (ca. 1 Woche). Jede Epoche hat einen Anfang (`BEGIN_EPOCH`) und ein Ende (`END_EPOCH`). Zwischen diesen Zeitpunkten erstellt der Smart Contract automatisch **Momentaufnahmen** (Snapshots) deines QMINE-Bestands.

### Der Ablauf in 4 Phasen:

```
┌─────────────────── Epoche N ───────────────────┐
│                                                 │
│  Phase 1: BEGIN_EPOCH                           │
│  ───────────────────                            │
│  SC fotografiert alle QMINE-Halter              │
│  → "So viel QMINE hatte jeder am Anfang"        │
│  → Gespeichert als Begin-Balance                │
│                                                 │
│  Phase 2: Während der Epoche                    │
│  ───────────────────────────                    │
│  Du kannst normal handeln (kaufen/verkaufen).   │
│  Einnahmen fließen in die Revenue-Pools.        │
│  Payouts werden aus den Pools verteilt.         │
│                                                 │
│  Phase 3: END_EPOCH                             │
│  ──────────────────                             │
│  SC fotografiert erneut alle QMINE-Halter       │
│  → "So viel QMINE hat jeder am Ende"            │
│  → Gespeichert als End-Balance                  │
│                                                 │
└───────────────────────┬─────────────────────────┘
                        │
                        ▼
┌─────────────────── Epoche N+1 ─────────────────┐
│                                                 │
│  Phase 4: BEGIN_EPOCH (von Epoche N+1)          │
│  ─────────────────────────────────────          │
│  Die Snapshots aus Epoche N werden jetzt        │
│  in die Payout-Buffer kopiert.                  │
│  → Ab jetzt zählen diese für Auszahlungen.      │
│                                                 │
│  Gleichzeitig: Neue Snapshots für Epoche N+1    │
│  werden erstellt.                               │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Was bedeutet das für dich?

- **Du musst QMINE mindestens eine volle Epoche lang halten**, bevor du Payouts bekommst
- Wer QMINE erst kurz vor dem Payout kauft, ist noch in keinem Snapshot → kein Payout
- Das verhindert, dass jemand kurz vor Freitag QMINE kauft, den Payout kassiert und sofort wieder verkauft

---

## Wer bekommt was? — Die Berechtigungsregeln

### Regel 1: QMINE-Halter (Payout-Typ 0)

Du bekommst einen Anteil am **QMINE-Dividenden-Pool** (90% aller Einnahmen), wenn:

| Bedingung | Erklärung |
|---|---|
| ✅ Du hattest QMINE am **Anfang** der Epoche | Dein Begin-Balance ist > 0 |
| ✅ Du hast QMINE **nicht reduziert** während der Epoche | End-Balance ≥ Begin-Balance |
| ✅ Du bist nicht die Fundraising-Adresse | Diese ist immer ausgeschlossen |

**Dein Anteil wird so berechnet:**
```
Dein Payout = (Dein Begin-Balance × Dividenden-Pool) ÷ Gesamt-QMINE-Begin-Balance
```

> **Einfach gesagt:** Wer 1% aller QMINE am Epochen-Anfang hatte und nichts verkauft hat, bekommt 1% des Pools.

**Was passiert wenn du verkauft hast?**
Wer QMINE während der Epoche **reduziert** hat (End-Balance < Begin-Balance), bekommt **gar nichts**. Der Anteil, der diesen Haltern zugestanden hätte, geht stattdessen an die **QMINE-Dev-Adresse** (z.B. für Projektentwicklung).

> **QMINE dazukaufen ist erlaubt** — solange du nicht unter deinen Anfangsbestand fällst, bist du voll berechtigt.

### Regel 2: qRWA-Halter (Payout-Typ 2)

Du bekommst einen Anteil am **qRWA-Dividenden-Pool** (10% aus Pool A+B), wenn:

| Bedingung | Erklärung |
|---|---|
| ✅ Du besitzt mindestens **1 qRWA-Share** | Aktueller Besitz, kein Snapshot nötig |
| ✅ Du bist nicht der Contract selbst | SELF ist ausgeschlossen |
| ✅ Du bist nicht die Fundraising-Adresse | Diese ist immer ausgeschlossen |

**Kein QMINE nötig!** Jeder qRWA-Halter bekommt proportional zu seinen Shares.

### Regel 3: Dedicated qRWA-Halter — Pool C Premium (Payout-Typ 3)

Du bekommst einen Anteil am **Dedicated qRWA-Pool** (10% aus Pool C), wenn:

| Bedingung | Erklärung |
|---|---|
| ✅ Du besitzt mindestens **1 qRWA-Share** | Aktueller Besitz |
| ✅ Du besitzt **≥ 100.000 QMINE pro qRWA-Share** | Premium-Anforderung |
| ✅ Du bist nicht der Contract selbst oder die Fundraising-Adresse | Ausgeschlossen |

**Beispiele:**

| qRWA-Shares | Benötigte QMINE | Berechtigt? |
|---|---|---|
| 1 | 100.000 | Ja, wenn du ≥ 100.000 QMINE hast |
| 5 | 500.000 | Ja, wenn du ≥ 500.000 QMINE hast |
| 10 | 1.000.000 | Ja, wenn du ≥ 1.000.000 QMINE hast |
| 5 (mit nur 300K QMINE) | 500.000 | **Nein** — zu wenig QMINE |

> **Was passiert mit nicht-verteiltem Geld?** Wenn niemand die Premium-Anforderung erfüllt, bleibt das Geld im Pool und wird in der nächsten Runde erneut versucht zu verteilen.

### Regel 4: QMINE-Dev (Payout-Typ 1)

Die **Dev-Adresse** bekommt den **Restbetrag** des QMINE-Dividenden-Pools, nachdem alle berechtigten Halter bezahlt wurden. Das umfasst:
- Anteile von Haltern, die während der Epoche verkauft haben
- Rundungsdifferenzen
- Anteile von Haltern, bei denen der Transfer fehlgeschlagen ist

---

## Ausschüttung im Detail — Die 6 Schritte

Die Ausschüttung läuft in mehreren Schritten ab, alle automatisch und in einem einzigen Tick:

### Schritt 1: Governance-Gebühren von Pool A abziehen

Aus Pool A werden zuerst die Betriebskosten-Gebühren bezahlt:

| Gebühr | Standard-Wert | Beschreibung |
|---|---|---|
| Strom (Electricity) | 350‰ (35,0%) | Stromkosten des Mining-Betriebs |
| Wartung (Maintenance) | 50‰ (5,0%) | Wartung & Infrastruktur |
| Reinvestment | 100‰ (10,0%) | Rücklagen für Neuanschaffungen |
| **Gesamt** | **500‰ (50,0%)** | **Abzug von Pool A vor Verteilung** |

> Die Gebühren werden direkt an die konfigurierten Adressen überwiesen — sofort, on-chain.
> Diese Werte sind per Governance-Abstimmung durch QMINE-Halter änderbar.

### Schritt 2: Pool A + Pool B zusammenführen → 90/10-Split

Nach Abzug der Gebühren wird der **Rest von Pool A** mit **Pool B** zusammengeführt:

```
Gesamtverteilung = (Pool A nach Gebühren) + Pool B
```

Diese Summe wird aufgeteilt:

| Empfänger | Anteil | Ziel-Pool |
|---|---|---|
| **QMINE-Halter** | **90%** | → QMINE-Dividenden-Pool |
| **qRWA-Halter** | **10%** | → qRWA-Dividenden-Pool |

### Schritt 3: Pool C separat → 90/10-Split

Pool C wird **getrennt** von Pool A+B verteilt, ebenfalls im 90/10-Verhältnis:

| Empfänger | Anteil | Ziel-Pool |
|---|---|---|
| **QMINE-Halter** | **90%** | → QMINE-Dividenden-Pool (**gemeinsam** mit Pool A+B) |
| **Dedicated qRWA-Halter** | **10%** | → Dedicated qRWA-Pool (eigener Pool, nur Premium) |

### Schritt 4: QMINE-Halter-Ausschüttung (Typ 0 + Typ 1)

Der gesamte **QMINE-Dividenden-Pool** (Schritt 2 + Schritt 3 zusammen) wird verteilt:

1. Jeder berechtigte QMINE-Halter bekommt seinen proportionalen Anteil (Typ 0)
2. Wer reduziert hat, bekommt nichts — sein Anteil geht an Dev (Typ 1)
3. Der gesamte Restbetrag (auch Rundungsdifferenzen) geht an die Dev-Adresse

> **Transfers passieren sofort** — `qpi.transfer()` sendet die QU direkt an die Wallet-Adresse des Halters.

### Schritt 5: qRWA-Halter-Ausschüttung (Typ 2)

Der **qRWA-Dividenden-Pool** (10% aus Pool A+B) wird an **alle qRWA-Halter** proportional zu ihren Shares verteilt.

- Jeder qRWA-Halter mit mindestens 1 Share ist berechtigt
- **Keine QMINE-Anforderung** für diesen Pool
- Der Contract selbst (SELF) und die Fundraising-Adresse sind ausgeschlossen

### Schritt 6: Dedicated qRWA-Halter-Ausschüttung (Typ 3)

Der **Dedicated qRWA-Pool** (10% aus Pool C) wird **nur** an qualifizierte qRWA-Halter verteilt:

> **Mindestens 100.000 QMINE pro qRWA-Share**

- Wer die Anforderung nicht erfüllt, wird übersprungen
- Nicht-verteiltes Geld bleibt im Pool für die nächste Ausschüttungsrunde

---

## Zusammenfassung des Geldflusses

```
Einzahlung an qRWA SC
       │
       ├── Dedicated Address ──────────► Pool C (BTC Mining)
       ├── QUTIL / Pool-A-Adresse ─────► Pool A (Qubic Mining)
       └── Alle anderen (SC holdings) ───────────────► Pool B (Nutzer)

Am Ausschüttungstag:
       │
       ├── Pool A: Governance-Gebühren abziehen (Strom + Wartung + Reinvest)
       │   └── Rest von Pool A + Pool B zusammenführen
       │       ├── 90% ──► QMINE-Dividenden-Pool
       │       └── 10% ──► qRWA-Dividenden-Pool
       │
       └── Pool C: Separater Split
           ├── 90% ──► QMINE-Dividenden-Pool (gemeinsam mit oben)
           └── 10% ──► Dedicated qMine/qRWA-Pool (nur ≥100K QMINE/Share)

Auszahlung:
       │
       ├── QMINE-Dividenden-Pool ──► Alle berechtigten QMINE-Halter
       │                              (proportional zum Begin-Epoch-Balance)
       │                              (Rest → QMINE Dev-Adresse)
       │
       ├── qRWA-Dividenden-Pool ───► Alle qRWA-Share-Halter
       │                              (proportional zu Shares, kein QMINE nötig)
       │
       └── Dedicated qRWA-Pool ────► Nur qRWA-Halter mit ≥100K QMINE/Share
                                      (proportional zu qualifizierten Shares)
```

---

## Governance – Abstimmung durch QMINE-Halter

QMINE-Halter können über die Betriebsparameter des Smart Contracts abstimmen.

### Abstimmbare Parameter

- Strom-Prozentsatz und -Adresse
- Wartungs-Prozentsatz und -Adresse
- Reinvestment-Prozentsatz und -Adresse
- Admin-Adresse
- QMINE-Dev-Adresse

### Abstimmungsregeln

- **Stimmberechtigt:** Alle QMINE-Halter
- **Stimmgewicht:** `min(Begin-Epoch-Balance, End-Epoch-Balance)` – wer während der Epoche QMINE verkauft hat, stimmt mit dem niedrigeren Bestand ab
- **Erforderliche Mehrheit:** Einfache Mehrheit – der Vorschlag mit den **meisten Stimmen** (>50% des gesamten Stimmgewichts) gewinnt
- **Auswertung:** Am Ende jeder Epoche (`END_EPOCH`)
- **Maximal 8 neue Governance-Abstimmungen pro Epoche**

### Asset-Release-Abstimmungen

QMINE-Halter können auch über die **Freigabe von Assets** (z.B. SC-Shares) aus dem Treasury abstimmen:

- **Erstellt durch:** Admin-Adresse
- **Abstimmung:** JA/NEIN (Bitfeld-basiert, bis zu 64 gleichzeitige Polls)
- **Erforderliche Mehrheit:** JA-Stimmen > NEIN-Stimmen (einfache Mehrheit)
- **Maximal 8 neue Asset-Release-Abstimmungen pro Epoche**

---

## Asset-Management (Treasury)

Der Smart Contract kann verschiedene Assets halten und verwalten:

### Assets einzahlen

Jeder Nutzer kann SC-Shares oder andere Assets in den qRWA-Contract einzahlen:
1. Shares auf QX kaufen
2. Management-Rechte an den qRWA-Contract übertragen → Die Shares werden automatisch permanent gesperrt und im internen Bilanzbuch erfasst

### Assets freigeben

Assets können nur per erfolgreicher **Asset-Release-Abstimmung** freigegeben werden. Der Admin erstellt einen Freigabe-Antrag, und die QMINE-Halter stimmen darüber ab.

### Treasury-Spenden

Jeder kann QU an das Treasury spenden (Procedure `DonateToTreasury`). Diese Mittel stehen für Governance-gesteuerte Verwendung zur Verfügung.

---

## Fundraising-Adresse

Eine konfigurierte Fundraising-Adresse wird von **allen Ausschüttungen ausgeschlossen**:
- Keine QMINE-Halter-Ausschüttung
- Keine qRWA-Halter-Ausschüttung  
- Keine Dedicated qRWA-Ausschüttung
- Kein Stimmrecht bei der QMINE-Snapshot-Erfassung

Dies verhindert, dass während einer Fundraising-Phase unverteilte Token Ausschüttungen kassieren.

---

## Wichtige Konstanten

| Konstante | Wert | Bedeutung |
|---|---|---|
| QMINE-Halter-Anteil | 90% | Anteil für QMINE-Halter an der Gesamtverteilung |
| qRWA-Halter-Anteil | 10% | Anteil für qRWA-Halter an der Gesamtverteilung |
| QMINE pro qRWA-Share (Pool C) | 100.000 | Mindestanforderung für Dedicated qRWA-Ausschüttung |
| Max. QMINE-Halter | 131.072 | Maximale Anzahl eindeutiger QMINE-Adressen |
| Max. Governance-Polls | 64 | Maximale Gesamtanzahl Governance-Abstimmungen |
| Max. Asset-Polls | 64 | Maximale Gesamtanzahl Asset-Release-Abstimmungen |
| Payout-Ringpuffer (je Pool) | 1.024 | Einträge pro Ring-Buffer (QMINE / qRWA / Dedicated) |
| Release-Management-Gebühr | 100 QU | Gebühr für Freigabe von Asset-Management-Rechten |

---

## Payout-Typen & Per-Pool Ring-Buffer

Es gibt **3 separate Ring-Buffer** — jeder speichert die letzten 1.024 Ausschüttungen eines Payout-Pfads:

| Function | Name | Payout-Typen | Beschreibung |
|---|---|---|---|
| fn 11 | `GetPayoutsQmine` | 0, 1 | QMINE-Halter + Dev (90%-Bein aller Pools) |
| fn 13 | `GetPayoutsQrwa` | 2 | qRWA-Halter (10%-Bein von Pool A+B) |
| fn 14 | `GetPayoutsDedicated` | 3 | Dedicated qRWA (10%-Bein von Pool C) |

### Typ-Codes

| Typ-Code | Beschreibung |
|---|---|
| 0 | QMINE-Halter-Auszahlung |
| 1 | QMINE-Dev-Auszahlung (Rest von Haltern, die während der Epoche verkauft haben) |
| 2 | qRWA-Halter-Auszahlung (Pool A+B, 10%-Anteil) |
| 3 | Dedicated qRWA-Auszahlung (Pool C, 10%-Anteil, Premium) |

---

## Rechenbeispiel

**Annahme:** In einer Epoche fließen folgende Einnahmen ein:

- Pool A (Qubic Mining): **1.000.000 QU**
- Pool B (Nutzer): **200.000 QU**
- Pool C (BTC Mining): **500.000 QU**

**Schritt 1 – Governance-Gebühren von Pool A:**
```
Strom (35%):        350.000 QU → Strom-Adresse
Wartung (5%):        50.000 QU → Wartungs-Adresse
Reinvestment (10%): 100.000 QU → Reinvestment-Adresse
Pool A Rest:        500.000 QU
```

**Schritt 2 – Pool A+B zusammenführen und aufteilen:**
```
Gesamt: 500.000 + 200.000 = 700.000 QU
QMINE-Halter (90%): 630.000 QU
qRWA-Halter (10%):   70.000 QU
```

**Schritt 3 – Pool C separat aufteilen:**
```
QMINE-Halter (90%): 450.000 QU
Dedicated qRWA (10%): 50.000 QU
```

**Schritt 4 – Gesamtausschüttung:**
```
QMINE-Halter gesamt:         630.000 + 450.000 = 1.080.000 QU
qRWA-Halter (alle):                                70.000 QU
Dedicated qRWA (≥100K QMINE/Share):                50.000 QU
Governance-Gebühren:                               500.000 QU
─────────────────────────────────────────────────────────────
Gesamt:                                          1.700.000 QU ✓
```
