# Codex Konten

Eine native macOS-Menüleisten-App für gespeicherte Codex-Konten, verfügbare Limits und den bestätigten Kontowechsel. Die Oberfläche zeigt Kontoname und E-Mail, folgt dem hellen oder dunklen Erscheinungsbild und verwendet unter macOS 26 und neuer die nativen Glas-Bedienelemente. Mindestversion: macOS 14.

[Aktuelle Version herunterladen](https://github.com/LoggeL/codex-konten/releases/latest)

Dieses Projekt ist unabhängig und wird nicht von OpenAI entwickelt oder unterstützt.

## Installation und Updates

Das ZIP aus den Releases entpacken und `Codex Konten.app` nach `/Applications` kopieren. Die derzeitigen Builds sind lokal ad hoc signiert und nicht von Apple notarisiert. Gatekeeper kann den ersten Start deshalb blockieren. Hinweise zum bewussten Öffnen einer solchen App stehen bei [Apple](https://support.apple.com/102445).

Im Menü mit den drei Punkten steht **Nach Updates suchen …**. Dort lässt sich auch die automatische Update-Prüfung ein- und ausschalten. [Sparkle](https://sparkle-project.org/) lädt den öffentlichen [Update-Feed](https://raw.githubusercontent.com/LoggeL/codex-konten/main/appcast.xml) und überprüft die Ed25519-Signatur eines Update-Pakets vor der Installation. Diese Signatur ersetzt keine Apple-Notarisierung. Ein Update darf keinen laufenden Kontovorgang durch einen Neustart unterbrechen.

Die Update-Prüfung benötigt keine Codex-Zugangsdaten. Die App verwendet keine eigene Telemetrie. Update-Anfragen gehen an GitHub; GitHub sieht dabei die üblichen Verbindungsdaten einer HTTP-Anfrage.

## Bedienung

Das Personen-Symbol in der Menüleiste öffnet die Kontenübersicht. Daneben steht der verbleibende Prozentsatz des aktiven Kontos: das Wochenlimit oder, wenn dieses fehlt, das 5-Stunden-Limit. Die Werte laden beim Start und aktualisieren sich alle fünf Minuten sowie nach einem Kontowechsel. **Aktiv** bezeichnet die tatsächlich gelesene Codex-Anmeldung. Es erscheinen nur Limits, die Codex liefert, mit verbleibendem Prozentsatz und Rücksetzzeit. Ein Wochenlimit bedeutet nicht, dass zusätzlich ein 5-Stunden-Limit verfügbar sein muss. Daten nach mehr als 15 Minuten sind als veraltet markiert; Fehler lassen vorhandene Werte sichtbar.

**Konten verwalten** öffnet ein dauerhaftes Fenster. **Konto hinzufügen** startet die Browser-Anmeldung für ein benanntes Profil. Eine laufende Anmeldung kann abgebrochen werden. Ein inaktives Konto kann erneut angemeldet oder aus der Liste entfernt werden. Die geschützte Profildatei bleibt beim Entfernen erhalten; das aktive Konto lässt sich nicht entfernen.

**Wechseln** verlangt eine Bestätigung. Codex wird regulär geschlossen, die Zielanmeldung geprüft und Codex anschließend neu geöffnet. Laufende Aufgaben werden dabei unterbrochen. Bleibt Codex nach 30 Sekunden noch geöffnet, wird die aktive Anmeldung nicht verändert. Scheitert nur der abschließende Start, steht **Codex öffnen** auch separat bereit.

## Lokale Kontodaten

Die App verwendet den bestehenden Speicher von Codex Account Switcher unter `~/Library/Application Support/Codex Account Switcher/` sowie die aktive Dateianmeldung unter `~/.codex/auth.json`. Neue Nutzer können ihre Konten dort über die App anlegen. Profildateien werden nur lokal gelesen und geschrieben. Eigene Anmeldedateien erhalten Dateimodus `0600`, die Verzeichnisse `0700`.

Der bisherige Codex Account Switcher muss beendet sein, bevor Codex Konten einen Kontovorgang ausführt. Die App erkennt außerdem eine zweite eigene Instanz per Dateisperre. Codex-Konfigurationen mit `cli_auth_credentials_store = "keyring"` oder `"auto"` werden beim Umschalten abgewiesen: Hier wird ausschließlich die Dateianmeldung unterstützt. Es gibt keinen automatischen Kontowechsel.

Die Release-App enthält sowohl Apple-Silicon- als auch Intel-Code. Automatische Prüfungen sind zunächst ausgeschaltet; sie lassen sich im Menü aktivieren. Die Installation einer angebotenen Version bleibt eine ausdrückliche Aktion.

## Entwickeln

Swift 6.2 oder neuer und ein macOS-26-SDK oder neuer werden zum Bauen benötigt. Sparkle ist als genaue SwiftPM-Version festgelegt.

```sh
xcrun swift test
bash scripts/package-app.sh "$PWD/dist"
```

Das Paketier-Skript erstellt und prüft das App-Bundle. Es installiert oder startet die App nicht. GitHub Actions führt Tests und Paketprüfung aus; der private Update-Signierschlüssel bleibt im macOS-Schlüsselbund des Veröffentlichers.

Für Layoutprüfungen ohne echte Konten:

```sh
xcrun swift build
"$(xcrun swift build --show-bin-path)/CodexAccounts" --preview /tmp/konten-hell.png
"$(xcrun swift build --show-bin-path)/CodexAccounts" --preview /tmp/konten-dunkel.png --dark
"$(xcrun swift build --show-bin-path)/CodexAccounts" --preview /tmp/konten-fehler.png --preview-error --manage
```

`--preview` liest keine Anmeldedaten. Die Offscreen-Bilder zeigen das Layout, nicht die GPU-gerenderten Glasflächen. Das paketierte Bundle lässt sich mit `open dist/"Codex Konten.app" --args --demo` als echte Menüleisten-App mit Beispielkonten starten. In diesem Modus werden weder Kontodienst noch Updater gestartet. `--dark` erzwingt nur für diese Demo das dunkle Erscheinungsbild.

## Releases vorbereiten

`config/release.env` enthält Versionsnummer, aufsteigende Buildnummer und den öffentlichen Prüfschlüssel. Der private Schlüssel liegt unter dem Sparkle-Keychain-Konto `de.logge.codex-konten`; er wird weder exportiert noch in GitHub Actions hinterlegt. Für eine neue Veröffentlichung Version und Buildnummer ändern, testen und paketieren:

```sh
xcrun swift test
bash scripts/package-app.sh "$PWD/dist"
bash scripts/prepare-release.sh "$PWD/dist/release" "$PWD/dist/Codex Konten.app"
```

Das zweite Skript erzeugt ein Universal-ZIP, `SHA256SUMS` und einen Appcast mit Ed25519-Signatur. Zuerst ZIP und Prüfsumme als GitHub-Release zum passenden `v`-Tag veröffentlichen, dann die erzeugte `appcast.xml` ins Repository übernehmen und pushen. Bereits veröffentlichte Versionspakete bleiben unverändert. Nach der Veröffentlichung die Download-Adresse und den Feed abrufen und die Signatur des heruntergeladenen ZIPs prüfen. Auf einem anderen Mac kann aus dem Quellcode gebaut werden; offizielle Updates lassen sich nur mit dem vorhandenen Signierschlüssel veröffentlichen.

## Design und Lizenz

Die Oberfläche orientiert sich an [Apples Material-Richtlinien](https://developer.apple.com/design/human-interface-guidelines/materials) und [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass). macOS übernimmt die Popover-Fläche und wichtige Bedienelemente. Ältere macOS-Versionen verwenden Standard-Bedienelemente.

Der eigene Quellcode steht unter der [MIT-Lizenz](LICENSE). Sparkle und seine Komponenten behalten ihre eigenen Lizenzen, die im eingebetteten Framework enthalten sind.
