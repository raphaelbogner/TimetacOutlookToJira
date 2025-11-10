# Timetac + Outlook → Jira Worklogs

Ein kompaktes Flutter-Tool, das **Arbeitszeiten aus Timetac (CSV)** mit **Outlook-Terminen (.ics)** und **GitLab-Commits** zusammenführt und daraus **Jira-Worklogs** erzeugt – exakt gesplittet nach Meetings, Pausen, Arztterminen und optional per Commit erkannten Tickets.

---

## Features

- **CSV-Import (Timetac)**
  - Spalten frei konfigurierbar (Beginn, Ende, Dauer, Pausen gesamt & Einzelintervalle).
  - Ganztägige Homeoffice-Standardblöcke werden ignoriert. Es zählen die echten „Kommen/Gehen“-Buchungen.
  - Wochenenden ohne Arbeit/Abwesenheit werden in der Vorschau ausgeblendet.

- **Outlook-Import (.ics)**
  - Berücksichtigt nur **aktive Meetings**: nicht „CANCELLED“, nicht „FREE/TENTATIVE/OOF/WORKINGELSEWHERE“, mit Teilnehmern.
  - Eigener Teilnahme-Status muss **ACCEPTED** oder **NEEDS-ACTION** sein.
  - All-day „Urlaub/Feiertag/Krank/Abwesend“ → Outlook wird für diesen Tag ignoriert.
  - Meetings > 10 h oder über Mitternacht → ignoriert.
  - Überlappungen werden nur bei **echter Überlappung** gemerged (touching ≠ merge).
  - Meeting-Titel erscheint in geplanten Worklogs: `Meeting 10:00–10:30 – <Summary>`.
  - **Konfigurierbare Meeting-Ausschlüsse**: Schlüsselwörter wie „homeoffice“, „focus time“, „reise“ etc. sind in den **Settings** editierbar. Default-Begriffe können **deaktiviert (durchgestrichen)** und wieder **reaktiviert** werden; eigene Begriffe können hinzugefügt oder entfernt werden.

- **GitLab-Commit-Routing (optional)**
  - Liest Commits aus mehreren Projekten per **Personal Access Token**.
  - Filtert auf Author/Committer-E-Mail(s).
  - Erkanntes Ticketpräfix am **Beginn** der Commit-Message: `KEY-123` oder `[KEY-123]`.
  - **Restzeit** (Arbeitszeit minus Meetings) wird über Commit-Wechsel **chronologisch gesplittet**. Forward-Fill nutzt das letzte bekannte Ticket.

- **Jira-Integration**
  - Zwei-Button-Flow: **Berechnen** → Vorschau → **Buchen (Jira)**.
  - Meeting-Ticket und Fallback-Ticket definierbar.
  - Ticket-Titel für Arbeits-Logs werden via **`POST /rest/api/3/search/jql`** geladen und in der Vorschau angezeigt.
  - **Ticket-Picker** in der Worklog-Vorschau: Ticket pro Zeile schnell wechseln. Suche nach `KEY-123` **oder** nach Teilen des Titels; die Auswahl überschreibt das automatisch erkannte Ticket. Der **originale Treffer** wird im Picker stets angezeigt.

- **UI/UX**
  - **AppBar**: Live-Status-Icons (Jira/Timetac/GitLab), **Theme-Toggle** mit Text, Settings-Button.
  - **Lock-Overlay**: Ist eine Hauptkonfiguration rot, wird die App gesperrt; Overlay erklärt die fehlenden Bereiche.
  - **Busy-Overlay**: Bei Berechnen und beim Import von CSV/ICS.
  - **Bottom Navigation**: Umschalten zwischen **Vorschau**, **Geplanten Worklogs** und **Logs**. Oberer Bereich mit Importen, Zeitraum und Buttons bleibt konstant.
  - **Settings-Dialog**: Tabs für **Jira**, **Timetac**, **GitLab** inkl. Live-Status-Icon je Tab. Externe Links (Jira/GitLab) öffnen im Browser.

- **Performance**
  - Schneller **Range-Cache** für Meetings im gewählten Datumsbereich.
  - Einzeltage nutzen den Cache, nicht das gesamte ICS.
  - Arzttermine werden beim Segmentieren als „Abzug von hinten“ auf die Arbeitsfenster angewandt.

---

## Installation

Voraussetzungen
- Flutter ≥ 3.19 (stable)
- Dart ≥ 3.x
- macOS/Windows/Linux mit Git
- (Windows) Visual Studio Build Tools für Desktop-Build

```bash
flutter --version
git clone <dein-repo>
cd TimetacOutlookToJira
flutter pub get
flutter run -d windows   # oder macos / linux
```
> **Hinweis (Windows):** `PathExistsException … .plugin_symlinks/file_picker` ⇒ `flutter clean` oder Ordner `windows/flutter/ephemeral/.plugin_symlinks` löschen, dann `flutter pub get`.

---

## Quick Start

1. **CSV laden** → „Timetac CSV laden“  
2. **ICS laden** → „Outlook .ics laden“  
3. **Zeitraum wählen**  
4. In **Einstellungen** Meeting- & Fallback-Ticket setzen und speichern  
5. **Berechnen** → Vorschau prüfen  
6. Optional: **Ticket-Picker** benutzen, um Tickets pro Zeile zu ändern  
7. **Buchen (Jira)**

---

## Anleitungen

### Timetac CSV-Datei bekommen
Die App zeigt diese Anleitung über den Info-Button direkt neben dem CSV-Import:

1. Öffne Timetac.  
2. Wechsle zum Tab **„Stundenabrechnung“**.  
3. Gib in die Datumsfelder **Start- und Enddatum** ein für den Zeitraum, den du buchen willst (am besten gleich wie bei Outlook).  
4. Klicke auf **„Aktualisieren“**.  
5. Klicke rechts auf **„Exportieren als CSV-Datei“**.  
6. Klicke im geöffneten Dialog auf **„Herunterladen“**.  
7. In dieser Anwendung die **CSV-Datei importieren** und kurz warten.

### Outlook ICS-Datei bekommen (Outlook Classic)
Die App zeigt diese Anleitung über den Info-Button neben dem ICS-Import. **Wichtig: Outlook Classic verwenden.**

1. Outlook (**Classic**) öffnen.  
2. Links auf den **Kalender**-Tab wechseln.  
3. Oben auf den Reiter **„Datei“** klicken.  
4. Links im Menü **„Kalender speichern“** auswählen.  
5. Im Explorer-Fenster unten auf **„Weitere Optionen“** klicken.  
6. Bei **Datumsbereich** „**Datum angeben…**“ auswählen und gewünschtes Beginn- und Enddatum festlegen (am besten gleich wie bei Timetac).  
7. Bei **Detail** „**Alle Details**“ auswählen.  
8. Bei **Erweitert** auf **„>> Einblenden“** klicken.  
9. **„Details von als privat markierten Elementen einschließen“** aktivieren.  
10. Mit **„OK“** bestätigen, Datei speichern und warten bis Outlook exportiert hat.  
11. In dieser Anwendung die **ICS-Datei importieren** und etwas länger warten. Ein kurzes „Einfrieren“ ist normal; das Busy-Overlay wird angezeigt.

---

## Einstellungen

### Jira
- **Base URL**: `https://<tenant>.atlassian.net` (ohne Slash am Ende)
- **E-Mail**, **API Token**
- **Meeting-Ticket** und **Fallback-Ticket**. Der **Berechnen**-Button bleibt deaktiviert, bis beide Felder gespeichert sind.
- Direktlink zum Token-Portal in den Settings.

### Timetac (CSV)
- **Delimiter** (`;`), **Header vorhanden** ✓/✗
- Spalten: **Beschreibung**, **Datum**, **Beginn**, **Ende**, **Dauer**, **Gesamtpause**, **Pausen-Ranges**
- Abwesenheiten (KT/FT/UT/ZA) werden angezeigt;
  - **BNA ohne KT/FT/UT/ZA** ⇒ **Arzttermin** und wird von der Arbeitszeit abgezogen.
- **Nicht-Meeting-Hinweise**: Liste editierbar. Defaults können **deaktiviert** (durchgestrichen) werden und bleiben rekonfigurierbar; eigene Einträge können **hinzugefügt** oder **gelöscht** werden.

### GitLab (optional)
- **Base URL**, **PRIVATE-TOKEN**
- **Projekt-IDs** (Komma/Whitespace getrennt)
- **Author E-Mail**(s) zum Filtern; sonst wird die Jira-E-Mail verwendet
- Links zu **Projektübersicht** und **Token-Erstellung** öffnen im Browser.

---

## Bedienlogik im Detail

1. **Arbeitsfenster** je Tag aus CSV, Nichtleistung und Pausen werden abgezogen.  
2. **Meetings** aus ICS werden gefiltert und in die Arbeitsfenster geschnitten → **Meeting-Drafts**.  
3. **Arzttermine** aus BNA (sofern kein KT/FT/UT/ZA) werden wie Pausen behandelt und vom Rest **von hinten** abgezogen.  
4. **Reststücke** werden mit GitLab-Commits pro Ticket segmentiert; bei Ticketwechsel wird gesplittet, sonst Forward-Fill.  
5. **Jira-Summaries** für Nicht-Meeting-Tickets werden via `POST /rest/api/3/search/jql` geladen und in der Vorschau angezeigt.  
6. **Ticket-Picker** kann das Ticket eines Drafts überschreiben. Die Auswahl wird für die Buchung übernommen; der Originaltreffer bleibt einsehbar.

---

## Datenschutz

- CSV/ICS/Commits/Summaries bleiben lokal.  
- Für die Jira-Buchung werden nur notwendige Felder übertragen.  
- GitLab/Jira-Tokens liegen lokal (SharedPreferences).

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

Artefakt liegt unter `build/<platform>/…`.

---

## Lizenz

Privat, zur internen Verwendung
