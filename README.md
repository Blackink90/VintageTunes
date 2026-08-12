# VintageTunes

**macOS** companion for managing an **iPod Classic / Video / nano 2G** library without Music.app / iTunes.

Import tracks (including FLAC and other non-native formats), prepare them for stock firmware, update **iTunesDB**, playlists and artwork, manage **photos** and **videos** on Video 5.5G, and play files directly from the mounted device.

Current version: **1.8.0** ([release](https://github.com/Blackink90/VintageTunes/releases/tag/v1.8.0)).

> Italian README: [README.it.md](README.it.md)

---

## Important notice / Disclaimer

**VintageTunes is experimental software, provided “as is”, with no warranty of any kind.**

- Use is **at your own risk**.
- Writing to an iPod (database, audio files, ArtworkDB, Photo Database) can in rare cases **corrupt the library**, require a restore, or, in extreme scenarios, leave the device unusable until restored.
- The authors are **not responsible** for data loss, damage to the device, computer, or third parties arising from use (or inability to use) this software.
- **Always back up** the iPod volume (or at least `iPod_Control` and, if you use photos, `Photos/`) before large syncs. In Settings you can create a full **`.vbk` backup**.
- This is not an Apple product and is not affiliated with Apple Inc.

By using VintageTunes you acknowledge these risks.

---

## Tested compatibility

| Device | Firmware | Status |
|---|---|---|
| **iPod Video 5.5G** (e.g. 80GB MA450) | Stock Apple | **Tested** — primary target (music + photos + experimental video) |
| **iPod nano 2G** | Stock Apple | Music/artwork support from dumps; **no real-device testing**; no Photos / Video |
| iPod Classic 6G+ | Stock | Classic music / artwork; experimental Video |
| Other Classic / Video iPods | Stock | Not systematically verified |
| iPods with **Rockbox** | Rockbox | Partial / experimental support |

> **In short:** music and artwork on **Video 5.5G** (thoroughly tested); **nano 2G** supported from reference dumps, **without real-device testing**; **photos** and **video** on Video. Classic: music/artwork + experimental video. Other models are not guaranteed.

Mac requirements: **macOS 14+** (Intel or Apple Silicon), Xcode to build from source. **ffmpeg** is also required for video and for **MP3** conversion. iPod volume is typically **HFS+** with an `iPod_Control` folder.

The app UI is available in **English** and **Italian** (Settings → Language: System / English / Italiano).

---

## What’s new in 1.8.0

- **English / Italian UI**: full app localization with **Settings → Language** (System / English / Italiano)
- **Settings without iPod**: gear button on the welcome screen and localized settings window title
- **README**: English default; Italian in [README.it.md](README.it.md)

## What’s new in 1.7.0

- **Eject + reconnect without unplugging**: after Eject the iPod becomes usable again; **Scan for devices** forces a USB re-enumerate and remounts the volume
- **Audio conversion**: destination **M4A AAC 256**, **ALAC**, **MP3 192 CBR**, or **MP3 320 CBR** (Settings → Audio Conversion; raw MP3 without Xing/ID3, requires ffmpeg)
- M4A/MP3 coexistence: with “Always” you can also reformat on import; tracks already on the iPod are left alone

## What’s new in 1.6.0

- **FLAC conversion settings**: Always / Ask / No, and destination **AAC 256** or **ALAC** (with “This file only” / “Apply to all”)
- **Realign sizes/durations and clean M4A…**: recalculates size and duration from files, rewrites iTunesDB, strips huge embedded JPEG covers that can crackle on 5.5G
- iTunesDB writing: **gapless** fields zeroed (no Music.app template leftovers that truncated tracks)

## What’s new in 1.5.0

- **Full backup / restore** in Settings: `.vbk` archive with all user volume content (music, video, photos, databases, play counts, Artwork, prefs, Rockbox if present) and the iPod **name**
- Ideal before migrating HDD → SD: 1:1 restore of data

## What’s new in 1.4.0

- **Videos** (Movies) section on stock iPod Video / Classic
- Drag & drop: H.264/AAC → iPod-safe `.m4v` and write to iTunesDB (`mediaType` Movie)
- Progress bar during video conversion (duration via **ffprobe** as well, useful for webm/mkv)
- **Ejecting…** feedback and confirmation before deleting tracks from the iPod
- Empty On-The-Go cleanup / normalized name in the sidebar

## What’s new in 1.3.0

- **Local library cache**: on reconnect, list and artwork appear immediately if the iPod hasn’t changed
- Fingerprint on iTunesDB/ArtworkDB: sync from another Mac invalidates the cache and rebuilds it
- Import/delete/playlist update iPod and cache together

## What’s new in 1.2.0

- **iPod nano 2G** support: music, playlists, ratings, dedicated artwork (from dumps; no real-device testing); no Photos
- Fix **Songs** list on open (sometimes only one track appeared until you changed section)

---

## What it does

- **Detects** a connected iPod (or uses a simulated iPod to try the UI)
- **Browses** Songs, Artists, Albums, Genres, Playlists, Videos, Photos
- **Imports** files or folders (drag & drop or folder picker)
- **Converts** formats unsupported by stock firmware (e.g. FLAC, OGG, Opus, WAV…) to **M4A AAC**, **ALAC**, or **MP3** 192/320 CBR (configurable; MP3 requires ffmpeg)
- **Reconnects** after eject with **Scan for devices** without unplugging (USB re-enumerate)
- **Video**: converts with ffmpeg to H.264 Baseline + AAC (in-app progress; **ffprobe** also needed) and marks them as Movies in iTunesDB
- **Writes** tracks under `iPod_Control/Music`, updates **iTunesDB** and (on stock) **ArtworkDB**
- **User playlists**: create, add, remove tracks (without deleting them from the iPod)
- **Artwork**: from tags, online lookup, local file, or paste URL; writes ArtworkDB on the iPod (Video F1028/F1029, Classic F1061/…, **nano 2G F1027/F1031**)
- **Photos** (**iPod Video 5G/5.5G** stock only): dedicated sidebar section — list, add (drag & drop or files), delete; writes `Photos/Photo Database` and thumbs in `Photos/Thumbs/` like Music.app
- **Full backup** / **full restore** (`.vbk`) from Settings
- **Edit metadata** (title, artist, album, genre, track, year, rating, artwork)
- **Ratings and play counts**: also reads the **Play Counts** file written by the iPod
- **Playback on the Mac** of files on the device (preview)
- Optional **auto-sync** from a watched folder (while the app is open)

---

## How to use (overview)

1. Connect the iPod and wait for macOS to mount it.
2. Open VintageTunes: the device should appear in the sidebar.
3. On the first session the app may complete missing metadata and artwork — let it finish. File durations are updated on **import** (the whole library is no longer rescanned on every connect).
4. Drop tracks/folders on the import area, or use **Choose Folder…**.
5. For playlists: create from the sidebar, then **Add to Playlist** from the context menu; in a playlist use **Remove from Playlist** (not “Delete from iPod”).
6. For **photos** (Video 5.5G): open **Photos** in the sidebar, add or delete images; they appear in the device Photos menu. After large changes, eject and reconnect.
7. For **videos** (Video / Classic): open **Videos**, drop a file (needs `ffmpeg`); eject and open Movies/Videos on the device.
8. Before changing the disk: Settings → **Full Backup…** (`.vbk`); on the new SD → **Full Restore from .vbk…**.
9. **Eject** from the app when done (the iPod leaves “Do not disconnect” and is usable). To work again without unplugging: **Scan for devices**.

### Formats (stock firmware)

| On the Mac | On the stock iPod |
|---|---|
| MP3, M4A/AAC, WAV, AIFF, ALAC | Copy / light prep |
| FLAC, OGG, Opus, WMA, … | Convert → **M4A AAC** (256), **ALAC**, **MP3 192**, or **MP3 320** CBR (Settings; MP3 requires ffmpeg) |
| MP4, M4V, MOV, MKV, … | Convert → **M4V** H.264/AAC (Videos section; requires ffmpeg) |

Rockbox: different path (e.g. `.m3u` playlists); in-app native FLAC support is not complete yet.

### Photos (Video 5G / 5.5G)

- The **Photos** sidebar item appears only if the model is recognized as stock Video.
- Thumb formats aligned with Music.app: F1036 / F1015 / F1024 (RGB565) and F1019 (UYVY TV-out).
- Does not sync Mac folders or store full-resolution JPEGs in `Full Resolution/` / DCIM (same as Music.app’s “thumbs only” sync on 5.5G).
- Classic, nano, and Rockbox: Photos section **not** available.
- **nano 2G**: same music/playlist/rating handling as Video; artwork with dedicated thumbs (not Video formats). **No real-device testing** (reference dumps only).

---

## Building

```bash
open VintageTunes.xcodeproj
```

Run the **VintageTunes** scheme on a Mac with **macOS 14+**.

Notes:

- The app needs access to **removable volumes**.
- With ad-hoc signing, macOS may ask for permission on every launch; signing with an Apple ID / development Team helps keep consent.

Download ready binaries from [release 1.8.0](https://github.com/Blackink90/VintageTunes/releases/tag/v1.8.0) (first launch: right-click → **Open**).

---

## Known limitations

- Thorough testing on **iPod Video 5.5G**. **nano 2G**: no real-device testing (music/artwork from reference dumps only).
- Does not replace a full backup or an official Apple restore.
- Database, artwork, and photos follow Music.app layouts per family (Video / Classic / nano); other generations may differ.
- Photos: Video 5G/5.5G only; no Classic/nano, no full-res originals.
- Rockbox and newer Classics beyond the handled profile: incomplete or unvalidated support.

---

## License and liability

The code is published for personal and experimental use.  
**No warranty of fitness, continuity, or freedom from defects.**  
Anyone who uses, modifies, or distributes it does so at their own responsibility.

---

## Credits

**VintageTunes** — unofficial companion for vintage iPods.  
Apple, iPod, iTunes, and Music are trademarks of Apple Inc.
