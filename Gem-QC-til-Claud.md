# Gemini QC-rapport: Arkitektur og Lade-deteksjon (Viper V2 Pro)

Dette dokumentet gir en fullstendig oversikt over Gemini CLI sin tekniske gjennomgang av Razer Battery Monitor (v1.3.2). Informasjonen er strukturert for å hjelpe Claude Code med å implementere en fiks for manglende lade-indikator.

## 1. Arkitektur og Flyt
Programmet er en profesjonelt oppbygd macOS-menylinjeapplikasjon med følgende kjennetegn:
* **Språk:** Objective-C++ (`main.mm`) for UI-et og C++17 (`RazerDevice.cpp`) for maskinvarekommunikasjon.
* **Gjengeteknikk:** USB-operasjoner kjører på en egen bakgrunns-kø (`no.ulfsec.battery`) for å hindre at menylinjen fryser. Det brukes `std::mutex` for å sikre trådsikker tilgang til USB-grensesnittet.
* **USB-kommunikasjon:** Benytter **IOKit** direkte for å sende "USB Control Requests" til musas **Interface 2**. Prosjektet har gått bort fra HIDAPI for å oppnå dypere systemintegrasjon og bedre kontroll.

## 2. Hvordan lade-deteksjon fungerer i dag
Basert på dokumentasjonen (`README.md` og `PROTOCOL_ANALYSIS.md`) finnes det to mekanismer:

1. **Produkt-ID Sjekk (Wired Mode):**
   - Hvis musa er koblet direkte til Mac-en med kabel, ser systemet en annen USB Product ID (f.eks. `0x00A5` i stedet for `0x00A6`).
   - Programmet oppdager dette umiddelbart via IOKit-notifikasjoner og setter `isCharging = true`.
   - **Status:** Dette fungerer, men feiler i brukerens nåværende scenario fordi musa lades fra en veggkontakt (Mac-en ser ikke kabelen).

2. **Protokoll-sjekk (Wireless Mode):**
   - Når musa er trådløs (via dongle), sender programmet en USB-forespørsel: **Command Class 0x07, Command ID 0x84**.
   - Hvis byte 11 i svaret er `0x01`, tolkes det som "Charging".
   - Hvis musa svarer med feilkode `0x04` (ikke støttet), antar programmet at den lader via kabel (da noen Razer-mus deaktiverer 0x84-kommandoen når kabelen er plugget i).

## 3. Hvorfor det ikke fungerer nå
Siden musa lades fra veggen, er Mac-en "blind" for den fysiske kabelen. Vi er 100% avhengige av at musa rapporterer sin interne lade-status trådløst til donglen.

* **Modell-spesifikk utfordring:** Viper V2 Pro (brukerens mus) er ikke offisielt dokumentert i de brukte kildene (`librazermacos`). Det er svært sannsynlig at kommando **0x84** er feil for denne modellen, eller at musa krever en spesifikk tilstand for å sende telemetri under lading.
* **Alternativ kommando:** `CommandScanner.cpp` lister opp **0x82** som en alternativ kandidat for "Charging Status" under Class 0x07.

## 4. Tekniske funn fra QC-analysen

### A. Ikon-logikk i `main.mm`
* **Funn:** Metoden `mouseIcon` returnerer **alltid** `computermouse.fill`.
* **Konsekvens:** Selv om koden detekterer lading (og viser ⚡ i teksten), endres aldri selve ikonet i menylinjen. Det bør byttes til `computermouse.and.bolt.fill`.

### B. Feilanalyse av CommandScanner
* **Funn:** Kjøring av `CommandScanner` ga bare `0x00` (tomme svar) på alle kommandoer.
* **Årsak:** Skanneren bruker `report[0] = 0x02` (Status: New Request). Hovedappen og standard Razer-protokoll bruker `report[0] = 0x00`. Dette er sannsynligvis årsaken til at musen ikke svarte under testen.

## 5. Konklusjon og Anbefaling
Programmet er teknisk svært solid etter v1.3.0-refaktoreringen (ingen minnelekkasjer eller race conditions). Den eneste gjenværende svakheten er at lade-deteksjonen er hardkodet til kommando 0x84, som ikke ser ut til å fungere for Viper V2 Pro i trådløs modus.

**Anbefalt tiltak til Claude:**
1. Oppdater `main.mm` slik at `mouseIcon` returnerer lade-ikon ved behov.
2. Oppdater `queryChargingStatus` til å prøve både **0x82** og **0x84**.
3. Verifiser om musa må tvinges i **Driver Mode (0x03)** for å rapportere lading trådløst.

---
*Rapporten er generert av Gemini CLI for overføring til Claude Code.*
