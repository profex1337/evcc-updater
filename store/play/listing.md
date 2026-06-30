# Play Store — Listing & Einreichung (evcc Pi-Tool)

Alles hier ist vorbereitet. Was nur **du** machen kannst, ist unten unter „Checkliste" markiert.

## Assets (in diesem Ordner)
- App-Icon 512×512: `icon-512.png`
- Feature-Graphic 1024×500: `feature-graphic-1024x500.png`
- Screenshots: **fehlen** — bitte 2–8 Handy-Screenshots der laufenden App machen (Play will min. 2).

## Texte

**App-Name (max. 30):**
```
evcc Pi-Tool
```

**Kurzbeschreibung (max. 80):**
```
evcc auf dem Raspberry Pi per SSH aktualisieren und installieren – ein Knopfdruck.
```

**Vollbeschreibung (max. 4000):**
```
evcc Pi-Tool aktualisiert und installiert evcc auf deinem Raspberry Pi – bequem per SSH, mit einem Knopfdruck.

Funktionen:
• evcc aktualisieren (apt) – mit Versions-Diff vorher/nachher
• Probelauf (Dry-Run) – zeigt gefahrlos, ob ein Update verfügbar ist
• Verbindung testen – prüft Host/Port/Benutzer/Passwort in Sekunden
• evcc neu installieren – richtet das offizielle apt-Repo ein und installiert evcc
• Optionales komplettes System-Upgrade
• Live-Log der SSH-Ausgabe, Versions-Badge
• Schnellzugriff auf die evcc-Weboberfläche (http://<Pi>:7070)

Sicherheit & Datenschutz:
• Deine Zugangsdaten bleiben verschlüsselt auf dem Gerät (Android Keystore)
• Keine Konten, keine Werbung, kein Tracking, keine Cloud
• Das Passwort wird nur über deine eigene SSH-Verbindung an deinen Pi gesendet

Hinweis: Dies ist ein inoffizielles Community-Tool und steht in keiner Verbindung zum evcc-Projekt.
Für die tägliche Lade-Steuerung gibt es die offizielle evcc-App.

Haftungsausschluss: Die App führt sudo-Befehle (apt, systemctl, reboot) auf deinem Gerät aus.
Nutzung auf eigene Gefahr – keine Haftung für Schäden an System, Daten oder Hardware.

Voraussetzungen: ein per SSH erreichbarer Raspberry Pi (oder Linux/Debian-Gerät) mit deinen Zugangsdaten.
```

**Was ist neu (Release Notes):** siehe jeweiliges GitHub-Release.

## Kategorie / Kontakt
- Kategorie: **Tools** (Productivity ginge auch)
- Tags: evcc, Raspberry Pi, SSH
- Website: https://profex1337.github.io/evcc-pi-tool/
- Datenschutz-URL: **https://profex1337.github.io/evcc-pi-tool/privacy.html**
- Kontakt-E-Mail: **hello@kyth.systems**
- Impressum-URL: **https://profex1337.github.io/evcc-pi-tool/impressum.html**

## Data Safety (Formular-Antworten)
- Werden Daten erfasst/geteilt? **Nein** – nichts wird an uns oder Dritte übertragen.
- Lokale Speicherung von Zugangsdaten (Host/Port/User/Passwort): verschlüsselt auf dem Gerät, verlässt das Gerät nicht.
- Datenverschlüsselung bei Übertragung: **Ja** (SSH zum eigenen Server).
- Löschung: durch Deinstallation.
- (Falls das Formular „App-Funktionalität / Credentials" abfragt: lokal, nicht geteilt.)

## Content Rating
- IARC-Fragebogen ausfüllen: keine Gewalt/Sexualität/Glücksspiel etc. → Ergebnis voraussichtlich **USK 0 / PEGI 3**.

## Signing
- **Play App Signing** aktivieren. Unser Release-Keystore wird zum **Upload-Key**
  (Secrets `KEYSTORE_*` sind schon gesetzt; der CI-Build erzeugt das `.aab`).

## Artefakt
- Das `app-release.aab` kommt aus dem GitHub-Actions-Lauf (Artifact **evcc-pi-tool-playstore-aab**)
  des jeweiligen `v*`-Tags. Herunterladen → in der Play Console als Bundle hochladen.

## Checkliste (nur du)
- [ ] Google-Play-Developer-Account (einmalig 25 $)
- [ ] Neuer Privat-Account: **Closed Test mit 12+ Testern über 14 Tage** vor Produktiv-Release
- [ ] 2–8 Screenshots erstellen
- [ ] Kontakt-E-Mail in der Console setzen
- [ ] `.aab` aus dem CI-Artifact hochladen, Data-Safety + Content-Rating ausfüllen, Datenschutz-URL eintragen
- [ ] (Empfohlen) im Listing klar „inoffiziell, nicht mit evcc affiliiert" erwähnen (steht schon in der Beschreibung)
```
