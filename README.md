# Windows 11   Audio Settings Recovery Manager

# 📋 Zusammenfassung: Enforce-AudioSettings.ps1

## Pfade Anpassen:

### Ganz oben am Anfang des Skripts könnt ihr den Pfad anpassen.
-     `[string]$ConfigPath = "C:\Skripts\AudioRecovery\AudioConfig.json",
      `[string]$LogPath    = "C:\Logs\audio-enforce.csv",

### Das müsst ihr auch anpassen in dem AutoStartTaskSchedulerAudioRecover.ps1
-     `$ScriptPath = "C:\Skripts\AudioRecovery\Enforce-AudioSettings.ps1"


## 🎯 Zweck

Ein Windows-Audio-Manager, der bei jedem Lauf den kompletten Audio-Zustand auf einen in einer JSON-Config definierten Soll-Zustand zurücksetzt. Robust gegen Windows-Updates, USB-Umsteckereignisse und Nutzermanipulation.

## 🔧 Was das Skript macht – nach Abschnitten

### Abschnitt 0: Core-Audio-API (C#-Block)
- Baut die Windows Core Audio API als COM-Interop-Brücke in PowerShell ein
- `CoreAudioApiV4`: Lese/Schreibe Zugriff auf Lautstärke, Mute, Device-State und Enumerierung **pro Gerät**
- `PolicyConfigClient`: Steuert die Sichtbarkeit von Audio-Endpoints (`SetVisibility`)
- `PrivilegeHelper`: Aktiviert SeTakeOwnership/SeRestore/SeBackup für geschützte Registry-Keys

### Abschnitt 1: Hilfsfunktionen
- `Write-Log`: Konsolen- und CSV-Logging
- `Set-ProtectedRegistryValue`: Umgeht TrustedInstaller-Schutz auf `MMDevices\Audio\...`-Keys
- `Set-AudioEndpointFriendlyName`: Ändert den Anzeigenamen in den Sound-Einstellungen
- `Get/Set-PerDeviceVolume` + `Get/Set-PerDeviceMute`: Lautstärke/Mute pro Gerät
- `Get-ShortDeviceName`: Entfernt den Adapter-Suffix (`"Line (Realtek USB2.0)"` → `"Line"`)

### Abschnitt 3: Config-Verwaltung
- **`-Mode CaptureConfig`**: Friert den aktuellen Zustand als neuen Soll-Zustand ein
  - Liest sichtbare Geräte → `AllowedDevices` (mit Volume + Mute)
  - Vergleicht mit Registry-Liste → alles Unsichtbare wird `DisabledDevices`
  - Behält `ExceptionDevices` bei (falls vorhanden)
- **Automatische Erstellung** beim ersten Lauf, wenn keine Config existiert

### Abschnitt 4: IST-Zustand + Config-Reparatur
- **PRE-ENABLE-Trigger**: Wenn Config-Geräte nicht sichtbar sind oder IDs stale sind → alle Endpoints sichtbar machen + Service-Neustart + 15s Retry-Loop
- **`Repair-ConfigDeviceIds`**: Repariert nach Windows-Updates alle ID-Änderungen
  - Allowed, Disabled und Exception-Listen werden gegen Registry geprüft
  - Name-Match als Fallback, wenn die ID nicht mehr existiert
- **Sicherheitsbremse**: Wenn mehr als 50% der Allowed-Geräte nicht zuordenbar sind → Abbruch mit Exit 3 (verhindert versehentliches Verstecken aller Geräte)

### Abschnitt 5 + 6: Standard-Geräte
- Prüft, ob das konfigurierte Standard-Wiedergabe- und Aufnahmegerät noch aktiv ist
- Bei Abweichung: setzt sie per `Set-AudioDevice` zurück
- Doppelte Absicherung: Repair-Result + Name-Match-Fallback

### Abschnitt 7: Allowed-Geräte durchsetzen
- Für jedes erlaubte Wiedergabe-/Aufnahmegerät:
  - **Lautstärke**: Toleranz 1%, sonst auf Config-Wert zurücksetzen
  - **Mute**: Stummschaltung aufheben, falls Soll = aktiv
  - **Name**: Wenn der Anzeigename abweicht → Registry-Properties-Key überschreiben

### Abschnitt 8: Disabled + Exceptions
- **Disabled-Geräte**: Iteriert direkt über die Disabled-Listen und ruft immer `SetVisibility($false)` auf
  - Idempotent – auch bereits unsichtbare Geräte werden erneut ausgeblendet
  - `$isReallyVisible` (State 0x1) verhindert Endlos-Re-Disabling bei UNPLUGGED-Geräten
- **Neue Geräte**: Alles, was in der Registry existiert, aber weder Allowed noch Disabled noch Exception ist, wird als **Exception** eingetragen (bleibt unangetastet)

### Abschnitt 9: Zusammenfassung
- Tabellarische Ausgabe aller Änderungen nach Kategorie

## 🛡️ Schutzmechanismen

| Mechanismus | Wirkung |
|---|---|
| **Mutex** | Verhindert parallele Läufe |
| **Sicherheitsbremse** | Bricht ab bei >50% nicht-zuordenbaren Allowed-Geräten |
| **PRE-ENABLE** | Macht alles sichtbar, wenn Config-Geräte versteckt sind |
| **Repair-Pipeline** | Repariert ID-Änderungen nach Windows-Updates |
| **Notfall-Trigger** | Stellt bei Totalausfall alles wieder her |
| **Log-Rotation** | 200 KB Schwelle, dann `.old`-Archiv |
| **Idempotenz** | Disabled-Geräte werden mehrfach ausgeblendet, ohne zu schaden |
| **Privilege-Helper** | Aktiviert benötigte Token-Privilegien zur Laufzeit |
| **ACL-Cleanup** | Nur die eigene ACE wird nach Registry-Write wieder entfernt |

## 📁 Config-Struktur (`AudioConfig.json`)

```json
{
  "DefaultPlaybackDeviceID":   "...",
  "DefaultPlaybackDeviceName": "Gaming Headset",
  "DefaultRecordingDeviceID":  "...",
  "DefaultRecordingDeviceName":"Microphone (Current)",
  "DefaultPlaybackVolume":  80,
  "DefaultRecordingVolume": 80,
  "AllowedPlaybackDevices":   [{ "ID": "...", "Name": "Alerts", "Volume": 80, "Muted": false }],
  "AllowedRecordingDevices":  [...],
  "DisabledPlaybackDevices":  [{ "ID": "...", "Name": "SPDIF Interface" }],
  "DisabledRecordingDevices": [...],
  "ExceptionPlaybackDevices":  [...],
  "ExceptionRecordingDevices": [...]
}
```

## 🚀 Modi

| Modus | Aufruf | Wirkung |
|---|---|---|
| **Enforce** | `-Mode Enforce` (Standard) | Erzwingt Soll-Zustand inkl. Schreibzugriffe |
| **Check** | `-Mode Check` | Zeigt Änderungen ohne Schreibzugriffe |
| **CaptureConfig** | `-Mode CaptureConfig` | Friert aktuellen Zustand als neuen Soll-Zustand ein |

## 🔄 Was passiert bei typischen Szenarien

| Ereignis | Reaktion |
|---|---|
| Normaler Lauf, alles OK | Keine Änderungen, kein Restart |
| Lautstärke verstellt | Wird auf Config-Wert zurückgesetzt |
| Gerät manuell umbenannt | Registry-Name wird auf Soll-Wert gebracht |
| Gerät manuell deaktiviert | Wird als Disabled erkannt (via CaptureConfig) |
| Windows-Update regeneriert GUIDs | Repair-Pipeline mappt alte auf neue IDs |
| Neue USB-Soundkarte angesteckt | Wird als Exception erfasst, bleibt unangetastet |
| Alle Config-Geräte versteckt | PRE-ENABLE macht sie sichtbar, dann Repair |
| Mehr als 50% Allowed fehlen | Sicherheitsbremse → Exit 3, nichts wird versteckt |

## 📌 Betriebs-Empfehlungen

- **Scheduled Task** als `SYSTEM` mit `RunLevel Highest`
- **Trigger**: Bei Anmeldung (+ alle 15 Minuten Optional)
- **Config-Backup** unter `AudioConfig.json.golden` aufbewahren (Optional)
- **Logs** unter `C:\Logs\audio-enforce.csv` mit automatischer Rotation (200KB)

---

**Kurzfassung:** Ein selbstheilender Audio-Zustands-Manager mit 4-Schichten-Schutz (Config → Repair → Enforce → Notfall), der auch nach Windows-Updates, Hardware-Wechseln und Nutzermanipulation den definierten Soll-Zustand zuverlässig wiederherstellt. 🏁
