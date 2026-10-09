# Blimp Music Player: Microsoft Store listing

Upload `build/msix/Blimp.msix` (build it with `dart run msix:create`).
Images are in `store_listing/windows/`.

## Pricing and availability

- Markets: all
- Pricing: Free
- Visibility: Public

## Properties

- Category: Music
- Privacy policy URL: https://bersamamus.github.io/Blimp/privacy.html
- Website: https://bersamamus.github.io/Blimp/
- Support contact: https://github.com/BersamaMus/Blimp/issues
- Product declarations: none of the boxes apply (no in-app purchases, no
  accessibility claims unless you've tested them).
- System requirements: leave the defaults.

## Age ratings

Answer the IARC questionnaire as a "Music / audio player" (not a game):
no violence, no user-to-user communication, no sharing of location or
personal information, no purchases, no unrestricted internet access. It
should come out rated 3+ / Everyone. The app plays the user's own files, so
any explicit lyrics come from their music, not the app.

## Store listing (English)

### Description

Blimp plays the music already on your PC, and makes it look and sound great.
No accounts, no ads, no internet. Your music and your listening stay on your PC.

LIVE VISUALIZER
Watch your music move with a real-time visualizer that reacts to every beat.
Choose from five styles: Bars, Mirror, Wave, Radial and Pulse.

LYRICS
Read along with synced lyrics that light up line by line, and click any line to
jump to it. Blimp reads lyrics embedded in your files or from .lrc files stored
next to them.

SOUNDS RIGHT
• Hi-res badges show which of your songs are better than CD quality
• Volume normalisation plays every song at about the same loudness
• Smooth fades between songs
• Waveform seek bar
• Playback speed from 0.5× to 2×

YOUR LIBRARY, YOUR WAY
• Point Blimp at your music folder (Music by default) and it does the rest
• Browse by songs, albums, artists, playlists, genres or folders
• Filter albums into Albums, EPs, Singles and Compilations
• A sortable song table for big libraries
• Search that ignores accents and punctuation, so "beyonce" finds Beyoncé
• Create playlists, and import or export them as M3U files

MADE FOR THE DESKTOP
• Media keys and the Windows media controls
• Keeps playing in the system tray when you close the window
• Pauses when your headphones are unplugged
• Keyboard shortcuts: Space to play and pause, Ctrl+Left/Right to skip, Ctrl+F to search
• Remembers its size and place on screen, and scales with the window

LISTENING STATS
See how much you listened today, this week, this month or of all time, with
your top songs, artists and genres.

YOURS TO KEEP
Back up your playlists, favourites, history, stats and settings to a single
file, and restore them on another PC or phone.

PRIVATE BY DESIGN
Blimp has no internet access. It doesn't collect, share or upload anything.

Black and yellow throughout, with a true black background.

### What's new in this version

First release on the Microsoft Store.

### Product features (one per line, up to 20)

Live visualizer with five styles
Synced lyrics from your files or .lrc files
Hi-res badges and volume normalisation
Smooth fades between songs and a waveform seek bar
Albums, EPs, Singles and Compilations sorted for you
Playlists with M3U import and export
Media keys and Windows media controls
Keeps playing in the system tray
Listening stats: top songs, artists and genres
Fully offline: no accounts, no ads, no tracking

### Screenshots (Desktop), in this order, with captions

1. `01_home.png`: Quick picks and your recent albums, ready to play
2. `02_player.png`: A now playing screen with a waveform seek bar
3. `03_lyrics.png`: Synced lyrics that light up as they're sung
4. `04_library.png`: Your albums, sorted into Albums, EPs, Singles and Compilations
5. `05_stats.png`: See how much you listen, and to what

### Store logos

- 1:1 App tile icon (300 x 300): `tile_300.png`

### Search terms (up to 7)

music player, offline music, mp3 player, flac player, lyrics, visualizer, audio player

### Copyright and trademark info

© 2026 BersamaMus

## Submission options

### Notes for certification

Blimp is an offline music player for audio files already on the PC. It reads
the user's Music folder (changeable in Settings > Library & storage). To test,
put a few MP3 or FLAC files in the Music folder of the test account before
launching; with no audio files there the library is empty. No account or
sign-in is needed. Closing the window may ask whether to keep playing in the
system tray or quit.

### Restricted capability: runFullTrust

Blimp is a desktop (Win32) app built with Flutter. It needs full trust to scan
the music folder the user chooses, play files with its bundled audio engine,
show the song in the Windows media controls, and keep playing from the system
tray when the window is closed.
