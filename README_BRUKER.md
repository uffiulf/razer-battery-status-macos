# Razer Battery Monitor - Enkel Bruksanvisning

## Oppsett på 1-2-3

### 1. Installer appen
- Kopier `RazerBatteryMonitor.app` til `/Applications`-mappen
- Start appen fra Programmer-mappen
- Første gang: Høyreklikk appen og velg "Åpne"

### 2. Aktiver rullefunksjoner (valgfritt)
Hvis du vil bruke egendefinerte rullefunksjoner:

1. **Klikk på museikonet** i menylinjen
2. **Gå til "Scroll Settings"**
3. **Klikk "Enable Scroll Features (1-click setup…)"**
4. **Følg instruksjonene:**
   - Klikk "OK, Open Settings"
   - Gå til "Personvern & sikkerhet" > "Tilgjengelighet"
   **Slå på "Razer Battery Monitor"**
   - Lukk Innstillinger
   - Rullefunksjoner virker med en gang!

### Hva fungerer uten tilgjengelighetstilkjennelse?
- **Batteri-overvåking** (fungerer alltid)
- **Muse-ikon i menylinjen** (viser batteristatus)
- **Fargeindikatorer** for lading/nivå

### Hva krever tilgjengelighetstilkjennelse?
- **Egendefinert rullefart**
- **Akselerasjonskurver** 
- **Utsmurt rulling**
- **Bak-knapp navigasjon** (museknapp 4)

### Tips for brukere
- Appen kjører i bakgrunnen og bruker minimalt med ressurser
- Batteristatus oppdateres hvert 5. sekund
- Ved lavt batteri (<20%) får du varsel
- Appen støtter alle Razer-mus med USB-C-kobling

### Feilsøking
Hvis rullefunksjoner ikke virker:
1. Sjekk at du fulgte steg 2 over
2. Prøv å starte appen på nytt med `sudo open /Applications/RazerBatteryMonitor.app`
3. Sjekk at appen har tilgjengelighetstilgang i Innstillinger

### Avinstaller
- Bare slett `RazerBatteryMonitor.app` fra Programmer-mappen

---

Teknisk info: Appen krever administratorrettigheter for USB-tilgang for å lese batteristatus fra Razer-musen.