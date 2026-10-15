# Changes made for Blimp

This is just_audio_media_kit 2.1.0 (public domain, see LICENSE), copied in so
the Windows player can set an mpv option the published package doesn't let
apps set, and to fix a bug. The lines marked "Blimp" in `lib/mediakit_player.dart`
are the changes:

- `sub-auto` is set to `no`. By default mpv opens a `.lrc` file named like the
  song as a subtitle track, and a plain one (lyrics without timestamps) leaves
  the song stuck loading at 0:00 / 0:00. The app reads lyrics itself
  (`DesktopLibrary.lyrics`), so mpv doesn't need them.

- Inserting songs partway through the queue (Play next, say) moved each new
  song from index `length`, one past the end, which mpv refuses, so the songs
  stayed at the end of mpv's playlist while just_audio had them where they
  were put; and every song of a batch went to the same index, which would
  have reversed them. Each is now moved from the last entry to its own place
  (`concatenatingInsertAll`).

The example app was left out.
