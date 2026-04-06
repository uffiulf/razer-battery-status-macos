# TODO for v1.3.5

## Kjente problemer å fikse

- [ ] **Tooltip viser feil status når appen kjører med sudo**: AXIsProcessTrusted() sjekker root-tilganger, ikke brukerens. Må cache permission-status ved oppstart eller kjøre sjekk i bruker-kontekst.

## Forbedringer

- [ ] Optimalisere appens oppstartsprosess
- [ ] Forbedre feilhåndtering ved USB-tilkobling

## Annet

- [ ] Oppdatere dokumentasjon ved release
