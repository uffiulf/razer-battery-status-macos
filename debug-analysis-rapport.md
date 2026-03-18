# Debug-analyse: Razer Battery Monitor (v1.3.2+)

Denne rapporten gir en dyp teknisk analyse av programmets nåværende tilstand, nylige utbedringer og identifiserte sårbarheter.

## 1. Oppsummering av "Smart Polling" & Lade-fix
Den nyeste koden (master-branch) har implementert en svært robust løsning for lade-deteksjon:

*   **Protokoll-fix:** Lade-status hentes nå fra **byte 9** (`response[9]`) i stedet for byte 11. Dette er bekreftet fungerende for Viper V2 Pro.
*   **Smart Polling:** 
    *   Lading: **3.0s** intervall (rask respons).
    *   Normal: **10.0s** intervall (balansert).
*   **Debounce-logikk:** Programmet krever **3 påfølgende** "ikke-lader"-svar fra musa før ladeikonet fjernes. Dette eliminerer "flimring" fra ustabil firmware.

## 2. Visuell Debug: Vertikal Typografi
UI-oppdateringen er løst på en profesjonell måte for å sikre perfekt sentrering i menylinjen:
*   **Metode:** Bruker `NSAttributedString` med to linjer (`\n`).
*   **Typografi:** `systemFontOfSize:8.5` med `NSFontWeightMedium`.
*   **Justering:** 
    *   `lineSpacing = -4.0` (presser linjene sammen).
    *   `NSBaselineOffsetAttributeName: @(-3.5)` (senker teksten for å sentrere den mot ikonet).
*   **Resultat:** En visuelt polert menylinje som ser ut som en integrert del av macOS.

## 3. Identifiserte sårbarheter (Runtime Debug)

### A. Krasj ved Notifikasjoner (`Abort trap: 6`)
*   **Symptom:** Appen krasjer ved oppstart eller ved lavt batteri når den kjøres manuelt fra terminalen.
*   **Årsak:** `UNUserNotificationCenter` kaster en exception hvis appen mangler en **Bundle Identifier** eller ikke er skikkelig pakket som en `.app`. 
*   **Løsning:** Appen **MÅ** startes som `RazerBatteryMonitor.app` for at notifikasjonssystemet skal initialiseres korrekt av macOS.

### B. Blokkering av hovedtråden (Main Thread Blocking)
*   **Funn:** `RazerDevice::setDeviceMode` bruker `usleep(300000)` (0.3 sekunder).
*   **Problem:** Siden `connect()` kalles fra hovedtråden i `main.mm`, vil UI-et (menylinjen) fryse i 0.3 sekunder hver gang musa kobles til eller våkner fra dvale.
*   **Anbefaling:** Flytt `setDeviceMode` til bakgrunns-køen (`batteryQueue_`) for å unngå "beachball".

### C. Privilegie-konflikter
*   **Funn:** Loggen viser at appen ofte kjøres med `sudo`. 
*   **Problem:** Loggfiler i `/tmp/RazerBatteryMonitor.log` fungerer bra, men `UNUserNotificationCenter` kan få problemer med å vise varsler til den påloggede brukeren hvis appen eies av `root`.

## 4. Logg-analyse (Sanntid)
Loggen i `/tmp/RazerBatteryMonitor.log` bekrefter følgende:
*   `charging=1` detekteres korrekt ved vegglading.
*   `notChargingCount` teller opp korrekt ved frakobling.
*   `success=1` bekrefter at USB-kommunikasjonen er stabil.

---
**Status:** Appen er nå funksjonelt komplett og visuelt overlegen tidligere versjoner. De gjenværende "bugsene" er hovedsakelig knyttet til hvordan macOS håndterer sikkerhet og rettigheter for notifikasjoner.

*Rapport generert av Gemini CLI - 18. mars 2026*
