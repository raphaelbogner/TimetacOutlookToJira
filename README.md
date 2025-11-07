# Timetac + Outlook → Jira Worklogs

Ein kompaktes Flutter-Tool, das **Arbeitszeiten aus Timetac (CSV)** mit **Outlook-Terminen (.ics)** und **GitLab-Commits** zusammenführt und daraus **Jira-Worklogs** erzeugt – exakt gesplittet nach Meetings, Pausen und (optionaler) Ticket-Automatik.

---

## Features

- **CSV-Import (Timetac)**  
  - Spalten frei konfigurierbar (Beginn, Ende, Dauer, Pausen gesamt & Einzelintervalle).
  - Pausen & Nichtleistungstätigkeiten (z. B. Arzt) werden vom Arbeitszeitfenster abgezogen.
  - Ganztägige Homeoffice-Standardblöcke (8:00–16:30 ±) werden ignoriert – es zählen die echten „Kommen/Gehen“-Buchungen.

- **Outlook-Import (.ics)**  
  - Berücksichtigt nur **aktive** Meetings: nicht „CANCELLED“, nicht „FREE/TENTATIVE/OOF“, mit Teilnehmern, und **dein eigener Status** ist *ACCEPTED* oder *NEEDS-ACTION*.  
  - All-day „Urlaub/Feiertag/Krank/Abwesend“ → Outlook wird für diesen Tag komplett ignoriert.  
  - Meetings >10 h oder über Mitternacht → ignoriert.  
  - Überlappende Meetings werden **nur bei echter Überlappung** gemerged (touching ≠ merge).  
  - Meeting-Titel wird im Plan angezeigt: `Meeting 10:00–10:30 – <Summary>`.

- **GitLab-Commit-Routing (optional)**  
  - Liest Commits aus mehreren Projekten per **Personal Access Token** (self-managed möglich).  
  - Filtert auf deine Author/Committer-E-Mail(s).  
  - Erkanntes Ticketpräfix am **Beginn** der Commit-Message: `KEY-123` oder `[KEY-123]`.  
  - „Rest-Zeit“ (Arbeitszeit minus Meetings) wird **chronologisch an Commit-Wechseln gesplittet** und immer mit dem **zuletzt bekannten Ticket** gebucht (Forward-Fill, auch über Tage).

- **Jira-Buchung**  
  - Zwei-Button-Flow: **Berechnen** → Vorschau → **Buchen (Jira)**.  
  - Meeting-Ticket und Fallback-Ticket frei definierbar.  
  - **Ticket-Titel** der Arbeits-Logs wird via **POST `/rest/api/3/search/jql`** nachgeladen und im Plan angezeigt:  
    `ABC-123  09:15–11:00  (1h 45m)  Arbeit – <Ticket Summary>`.

---

## Installation

Voraussetzungen:
- Flutter ≥ 3.19 (stable)  
- Dart ≥ 3.x  
- macOS/Windows/Linux mit Git  
- (Windows) Visual Studio Build Tools für Desktop-Build

```bash
flutter --version
git clone https://github.com/raphaelbogner/TimetacOutlookToJira.git
cd TimetacOutlookToJira
flutter pub get
flutter run -d windows   # oder macos / linux
```
> **Hinweis (Windows):**  
> Fehlermeldung `PathExistsException … .plugin_symlinks/file_picker` ⇒ `flutter clean` oder Ordner `windows/flutter/ephemeral/.plugin_symlinks` löschen, dann `flutter pub get`.

---

## Quick Start

1. **CSV laden** → „Timetac CSV laden“  
2. **ICS laden** → „Outlook .ics laden“  
3. **Zeitraum wählen**  
4. **Einstellungen** speichern (Jira, CSV-Spalten, GitLab optional)  
5. **Berechnen** → Vorschau prüfen  
6. **Buchen (Jira)**

---

## Einstellungen (wichtigste Felder)

### Jira
- **Base URL**: `https://<tenant>.atlassian.net` (ohne Slash am Ende)  
- **E-Mail**, **API Token**  
- **Meeting-Ticket** (für erkannte Meetings)  
- **Fallback-Ticket** (wird i. d. R. durch Commit-Routing ersetzt)

### CSV (Timetac)
Alle Felder sind frei konfigurierbar und werden am Header/Spaltennamen gematcht.

- **Delimiter**: *(Standard: `;`)*  
- **Header vorhanden**: *(Standard: `✓`)*
- **Beschreibung/Aktion** *(Standard: `Kommentar`)*  
- **Datum** *(Standard: `Datum`)*  
- **Beginn** *(z. B. `K`)*  
- **Ende** *(z. B. `G`)*  
- **Dauer** *(z. B. `GIBA`)*
- **Gesamtpause** *(Standard: `P`)* 
- **Pausen-Ranges** *(Standard: `Pausen`)*

**Klassifizierung (hart kodiert) (wird später konfigurierbar)**  
- **Abwesenheit** (führt zum Ignorieren von Outlook an diesem Tag):  
  `urlaub`, `feiertag`, `krank`, `abwesen` (case-insensitiv)  
- **Nichtleistung** (aus Arbeitszeit abziehen):  
  `pause`, `arzt`, `nichtleistung`, `nicht-leistung`  
- **Homeoffice-Standardblock** (ganzer Tag 8:00–16:30 ±): ignoriert – echte „Kommen/Gehen“ zählen

### Outlook / ICS
- Es werden nur Meetings gezählt, die
  - **nicht** `CANCELLED` sind,  
  - **BUSYSTATUS** ≠ `FREE/TENTATIVE/OOF/WORKINGELSEWHERE`,  
  - **mindestens 1 Teilnehmer** haben,  
  - für **deine E-Mail (Settings → Jira E-Mail)** `PARTSTAT` **ACCEPTED** oder **NEEDS-ACTION** tragen,  
  - nicht über Mitternacht gehen, ≤ 10 h dauern, und kein ganztägiger Block sind.  
- All-day „Homeoffice“/„An anderem Ort tätig“ zählt **nicht** als day off.  
- **Urlaub/Feiertag/Krank/Abwesend** (auch OOF) ⇒ Outlook komplett ignoriert.

### GitLab (optional)
- **Base URL**
- **PRIVATE-TOKEN** (Personal Access Token)  
- **Projekt-IDs**: kommasepariert/whitespace  
- **Author E-Mail**(s) zum Filtern (sonst Jira-E-Mail)  

**Commit-Parsing:**  
Ticketpräfix am Anfang der ersten Zeile wird erkannt:  
`KEY-123`, `[KEY-123]`, optional mit `:` – Emojis/Brackets davor werden ignoriert.

---

## Bedienlogik

1. **Arbeitsfenster** aus CSV pro Tag (Pausen/Arzt/… werden abgezogen).  
2. **Meetings** (aus ICS, gefiltert & gemerged) werden **in die Arbeitsfenster geschnitten** → Meeting-Drafts.  
3. **Restzeit** = Arbeitsfenster − Meetings → per **GitLab-Commits** in Segmente aufgeteilt (Wechsel bei neuem Ticket).  
   - Wenn vor einem Segment **kein** Commit liegt, wird zum **nächsten Commit** vorgefüllt (Forward-Fill).  
4. **Jira-Summaries**: Für alle Nicht-Meeting-Tickets werden die Titel via **POST `/rest/api/3/search/jql`** geholt und im Plan angezeigt.  
5. **Buchen** erstellt Worklogs über die Jira REST API (Issue-ID wird vorab aufgelöst).

---

## Datenschutz

- Alle Daten bleiben lokal auf deinem Rechner (CSV/ICS/Commits/Summaries).  
- Es werden nur die für die Jira-Buchung notwendigen Felder übertragen.  
- GitLab/Jira-Tokens liegen im lokalen App-Storage (SharedPreferences) – behandle sie wie Passwörter.

---

## Build & Release

```bash
# Windows
flutter build windows

# macOS
flutter build macos

# Linux
flutter build linux
```

Das erzeugte Artefakt findest du im jeweiligen `build/<platform>/…`-Ordner.

---

## Lizenz

Privat/Intern
