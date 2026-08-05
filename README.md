# VintageTunes

Companion **macOS** per gestire la libreria di un **iPod Classic / Video / nano 2G** senza passare da Music.app / iTunes.

Importa brani (anche FLAC e altri formati non nativi), li prepara per il firmware stock, aggiorna **iTunesDB**, playlist e copertine, gestisce **foto** e **video** sul Video 5.5G e permette di ascoltare i file direttamente dal dispositivo montato.

Versione attuale: **1.6.0** ([release](https://github.com/Blackink90/VintageTunes/releases/tag/v1.6.0)).

---

## ⚠️ Avviso importante / Disclaimer

**VintageTunes è software sperimentale, offerto “così com’è”, senza alcuna garanzia.**

- L’uso è **a proprio rischio e pericolo**.
- Scrivere su un iPod (database, file audio, ArtworkDB, Photo Database) può in rari casi **corrompere la libreria**, richiedere un ripristino o, in scenari estremi, rendere il dispositivo inutilizzabile finché non viene ripristinato.
- Gli autori **non sono responsabili** di perdite di dati, danni al dispositivo, al computer o a terzi derivanti dall’uso (o dall’impossibilità di usare) questo programma.
- **Fai sempre un backup** della volume dell’iPod (o almeno di `iPod_Control` e, se usi le foto, `Photos/`) prima di sincronizzare in massa. In Impostazioni puoi creare un **backup totale** `.vbk`.
- Non è un prodotto Apple e non è affiliato ad Apple Inc.

Usando VintageTunes dichiari di aver compreso questi rischi.

---

## Compatibilità testata

| Dispositivo | Firmware | Stato |
|---|---|---|
| **iPod Video 5.5G** (es. 80GB MA450) | Stock Apple | **Testato** — target principale (musica + foto + video sperimentale) |
| **iPod nano 2G** | Stock Apple | Supporto musica/cover da dump; **nessun test su dispositivo reale**; niente Foto / Video |
| iPod Classic 6G+ | Stock | Musica / cover Classic; Video sperimentale |
| Altri iPod Classic / Video | Stock | Non verificato in modo sistematico |
| iPod con **Rockbox** | Rockbox | Supporto parziale / sperimentale |

> **In sintesi:** musica e cover su **Video 5.5G** (test approfondito); **nano 2G** supportato da dump di riferimento, **senza test su dispositivi reali**; **foto** e **video** sul Video. Classic: musica/cover + video sperimentale. Altri modelli non sono garantiti.

Requisiti Mac: **macOS 14+** (Intel o Apple Silicon), Xcode per compilare dal sorgente. Per i video serve anche **ffmpeg**. Volume iPod tipicamente **HFS+** con cartella `iPod_Control`.

---

## Novità in 1.6.0

- **Impostazioni conversione FLAC**: Sempre / Chiedi / No, e destinazione **AAC 256** o **ALAC** (con “Solo per questo file” / “Applica a tutti”)
- **Riallinea size/durate e ripulisci M4A…**: ricalcola size e durata dai file, riscrive iTunesDB, toglie JPEG/cover embedded enormi che sul 5.5G possono causare stridii
- Scrittura iTunesDB: campi **gapless** azzerati (niente residui del template Music.app che tagliavano i brani)

## Novità in 1.5.0

- **Backup / ripristino totale** in Impostazioni: archivio `.vbk` con tutto il contenuto utente del volume (musica, video, foto, database, play count, Artwork, preferenze, Rockbox se presente) e il **nome** dell’iPod
- Ideale prima di migrare HDD → SD: ripristino 1:1 dei dati

## Novità in 1.4.0

- Sezione **Video** (Film) su iPod Video / Classic stock
- Drag & drop: conversione H.264/AAC → `.m4v` iPod-safe e scrittura in iTunesDB (`mediaType` Film)
- Barra di progresso durante la conversione video (durata anche via **ffprobe**, utile per webm/mkv)
- Feedback **Espulsione in corso…** e conferma prima di eliminare brani dall’iPod
- Cleanup On-The-Go vuote / nome normalizzato in sidebar

## Novità in 1.3.0

- **Cache locale** della libreria: alla riconnessione, lista e cover partono subito se l’iPod non è cambiato
- Fingerprint su iTunesDB/ArtworkDB: sync da altro Mac invalida la cache e la ricostruisce
- Import/delete/playlist aggiornano iPod e cache insieme

## Novità in 1.2.0

- Supporto **iPod nano 2G**: musica, playlist, stelle, cover dedicate (da dump; senza test su dispositivi reali); niente Foto
- Fix lista **Canzoni** all’apertura (prima a volte compariva una sola traccia finché non cambiavi sezione)

---

## Cosa fa

- **Rileva** l’iPod collegato (o usa un iPod simulato per provare l’interfaccia)
- **Sfoglia** Canzoni, Artisti, Album, Generi, Playlist, Video, Foto
- **Importa** file o cartelle (drag & drop o selezione cartella)
- **Converte** formati non supportati dal firmware stock (es. FLAC, OGG, Opus, WAV…) in **M4A AAC** o **ALAC** (impostabile)
- **Video**: converte con ffmpeg in H.264 Baseline + AAC (barra di progresso in app; serve anche **ffprobe**) e li marca come Film in iTunesDB
- **Scrive** tracce in `iPod_Control/Music`, aggiorna **iTunesDB** e (su stock) **ArtworkDB**
- **Playlist** utente: crea, aggiungi, rimuovi brani (senza eliminarli dall’iPod)
- **Copertine**: da tag, ricerca online, file locale o incolla URL; sull’iPod scrive ArtworkDB (Video F1028/F1029, Classic F1061/…, **nano 2G F1027/F1031**)
- **Foto** (solo **iPod Video 5G/5.5G** stock): sezione dedicata in sidebar — elenco, aggiunta (drag & drop o file) ed eliminazione; scrive `Photos/Photo Database` e le thumb in `Photos/Thumbs/` come Music.app
- **Backup totale** / **ripristino totale** (`.vbk`) dalle Impostazioni
- **Modifica metadati** (titolo, artista, album, genere, traccia, anno, stelle, cover)
- **Stelle e conteggi** riproduzioni: legge anche il file **Play Counts** scritto dall’iPod
- **Riproduzione sul Mac** dei file presenti sul dispositivo (anteprima)
- **Auto-sync** opzionale da una cartella osservata (mentre l’app è aperta)

---

## Come si usa (panoramica)

1. Collega l’iPod e attendi che macOS lo monti.
2. Apri VintageTunes: dovrebbe comparire il dispositivo nella sidebar.
3. Alla prima sessione l’app completa metadati mancanti e cover se serve — lascia finire le operazioni. Le durate dei file si aggiornano in **import** (non viene più riscandita tutta la libreria a ogni collegamento).
4. Trascina brani/cartelle sull’area di import, oppure usa **Scegli cartella…**.
5. Per le playlist: crea dalla sidebar, poi **Aggiungi a playlist** dal menu contestuale; in playlist usa **Rimuovi dalla playlist** (non “Elimina dall’iPod”).
6. Per le **foto** (Video 5.5G): apri **Foto** nella sidebar, aggiungi immagini o eliminale; sul dispositivo compaiono nel menu Foto. Dopo modifiche grosse, espelli e ricollega l’iPod.
7. Per i **video** (Video / Classic): apri **Video**, trascina un file (serve `ffmpeg`); espelli e sul device apri Film/Video.
8. Prima di cambiare disco: Impostazioni → **Backup totale…** (`.vbk`); sulla nuova SD → **Ripristino totale da .vbk…**.
9. Espelli l’iPod dall’app o da Finder quando hai finito.

### Formati (firmware stock)

| Sul Mac | Sull’iPod stock |
|---|---|
| MP3, M4A/AAC, WAV, AIFF, ALAC | Copia / preparazione |
| FLAC, OGG, Opus, WMA, … | Conversione → **M4A AAC** (256 kbps) o **ALAC** (Impostazioni) |
| MP4, M4V, MOV, MKV, … | Conversione → **M4V** H.264/AAC (sezione Video; richiede ffmpeg) |

Rockbox: percorso diverso (es. playlist `.m3u`); il supporto FLAC nativo in-app non è ancora completo.

### Foto (Video 5G / 5.5G)

- La voce **Foto** in sidebar compare solo se il modello è riconosciuto come Video stock.
- Formati thumb allineati a Music.app: F1036 / F1015 / F1024 (RGB565) e F1019 (UYVY TV-out).
- Non sincronizza cartelle del Mac né salva JPEG full-resolution in `Full Resolution/` / DCIM (come nel sync “solo thumbs” di Music.app sul 5.5G).
- Classic, nano e Rockbox: sezione foto **non** disponibile.
- **nano 2G**: stessa gestione musica/playlist/stelle del Video; cover con thumb dedicate (non usa i formati Video). **Nessun test su dispositivo reale** (solo dump di riferimento).

---

## Compilare

```bash
open VintageTunes.xcodeproj
```

Esegui lo scheme **VintageTunes** su un Mac con **macOS 14+**.

Note:

- L’app richiede accesso ai **volumi rimovibili**.
- Con firma ad-hoc, macOS può chiedere i permessi a ogni avvio; una firma con Apple ID / Team di sviluppo aiuta a mantenerli.

Scarica i binari pronti dalla [release 1.6.0](https://github.com/Blackink90/VintageTunes/releases/tag/v1.6.0) (al primo avvio: tasto destro → **Apri**).

---

## Limiti noti

- Test approfondito su **iPod Video 5.5G**. **nano 2G**: nessun test su dispositivi reali (solo dump di riferimento per musica/cover).
- Non sostituisce un backup completo né un ripristino ufficiale Apple.
- Database, artwork e foto seguono i layout Music.app per famiglia (Video / Classic / nano); altre generazioni possono differire.
- Foto: solo Video 5G/5.5G; niente Classic/nano, niente originali full-res.
- Rockbox e Classic più recenti oltre al profilo già gestito: supporto incompleto o non validato.

---

## Licenza e responsabilità

Il codice è pubblicato per uso personale e sperimentale.  
**Nessuna garanzia di idoneità, continuità o assenza di difetti.**  
Chi lo usa, lo modifica o lo distribuisce lo fa sotto la propria responsabilità.

---

## Crediti

Progetto **VintageTunes** — companion non ufficiale per iPod vintage.  
Apple, iPod, iTunes e Music sono marchi di Apple Inc.
