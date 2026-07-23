# VintageTunes

Companion **macOS** per gestire la libreria di un **iPod Classic / Video** senza passare da Music.app / iTunes.

Importa brani (anche FLAC e altri formati non nativi), li prepara per il firmware stock, aggiorna **iTunesDB**, playlist e copertine, e permette di ascoltare i file direttamente dal dispositivo montato.

---

## ⚠️ Avviso importante / Disclaimer

**VintageTunes è software sperimentale, offerto “così com’è”, senza alcuna garanzia.**

- L’uso è **a proprio rischio e pericolo**.
- Scrivere su un iPod (database, file audio, ArtworkDB) può in rari casi **corrompere la libreria**, richiedere un ripristino o, in scenari estremi, rendere il dispositivo inutilizzabile finché non viene ripristinato.
- Gli autori **non sono responsabili** di perdite di dati, danni al dispositivo, al computer o a terzi derivanti dall’uso (o dall’impossibilità di usare) questo programma.
- **Fai sempre un backup** della volume dell’iPod (o almeno di `iPod_Control`) prima di sincronizzare in massa.
- Non è un prodotto Apple e non è affiliato ad Apple Inc.

Usando VintageTunes dichiari di aver compreso questi rischi.

---

## Compatibilità testata

| Dispositivo | Firmware | Stato |
|---|---|---|
| **iPod Video 5.5G** (es. 80GB MA450) | Stock Apple | **Testato** — target principale |
| Altri iPod Classic / Video | Stock | Non verificato in modo sistematico |
| iPod con **Rockbox** | Rockbox | Supporto parziale / sperimentale |

> **In sintesi:** l’app è stata sviluppata e provata in modo concreto solo su **iPod 5.5G (Video)**. Altri modelli possono funzionare, ma non sono garantiti.

Requisiti Mac: **macOS 14+**, Xcode per compilare dal sorgente. Volume iPod tipicamente **HFS+** con cartella `iPod_Control`.

---

## Cosa fa

- **Rileva** l’iPod collegato (o usa un iPod simulato per provare l’interfaccia)
- **Sfoglia** Canzoni, Artisti, Album, Generi, Playlist
- **Importa** file o cartelle (drag & drop o selezione cartella)
- **Converte** formati non supportati dal firmware stock (es. FLAC, OGG, Opus, WAV…) in **M4A AAC** adatto all’iPod
- **Scrive** tracce in `iPod_Control/Music`, aggiorna **iTunesDB** e (su stock) **ArtworkDB**
- **Playlist** utente: crea, aggiungi, rimuovi brani (senza eliminarli dall’iPod)
- **Copertine**: da tag, ricerca online, file locale o incolla URL
- **Modifica metadati** (titolo, artista, album, genere, traccia, anno, stelle, cover)
- **Stelle e conteggi** riproduzioni: legge anche il file **Play Counts** scritto dall’iPod
- **Riproduzione sul Mac** dei file presenti sul dispositivo (anteprima)
- **Auto-sync** opzionale da una cartella osservata (mentre l’app è aperta)

---

## Come si usa (panoramica)

1. Collega l’iPod e attendi che macOS lo monti.
2. Apri VintageTunes: dovrebbe comparire il dispositivo nella sidebar.
3. Alla prima sessione (o dopo aggiornamenti importanti) l’app può **allineare durate** e riscrivere parti del database — lascia finire le operazioni.
4. Trascina brani/cartelle sull’area di import, oppure usa **Scegli cartella…**.
5. Per le playlist: crea dalla sidebar, poi **Aggiungi a playlist** dal menu contestuale; in playlist usa **Rimuovi dalla playlist** (non “Elimina dall’iPod”).
6. Espelli l’iPod dall’app o da Finder quando hai finito.

### Formati (firmware stock)

| Sul Mac | Sull’iPod stock |
|---|---|
| MP3, M4A/AAC, WAV, AIFF, ALAC | Copia / preparazione |
| FLAC, OGG, Opus, WMA, … | Conversione → **M4A AAC** (tipicamente 256 kbps, 44.1 kHz) |

Rockbox: percorso diverso (es. playlist `.m3u`); il supporto FLAC nativo in-app non è ancora completo.

---

## Compilare

```bash
open VintageTunes.xcodeproj
```

Esegui lo scheme **VintageTunes** su un Mac con **macOS 14+**.

Note:

- L’app richiede accesso ai **volumi rimovibili**.
- Con firma ad-hoc, macOS può chiedere i permessi a ogni avvio; una firma con Apple ID / Team di sviluppo aiuta a mantenerli.

---

## Limiti noti

- Test approfondito solo su **iPod Video 5.5G**.
- Non sostituisce un backup completo né un ripristino ufficiale Apple.
- Database e artwork seguono il layout tipico di Music.app sul Video 5.5G; altre generazioni possono differire.
- Rockbox e Classic più recenti: supporto incompleto o non validato.

---

## Licenza e responsabilità

Il codice è pubblicato per uso personale e sperimentale.  
**Nessuna garanzia di idoneità, continuità o assenza di difetti.**  
Chi lo usa, lo modifica o lo distribuisce lo fa sotto la propria responsabilità.

---

## Crediti

Progetto **VintageTunes** — companion non ufficiale per iPod vintage.  
Apple, iPod, iTunes e Music sono marchi di Apple Inc.
