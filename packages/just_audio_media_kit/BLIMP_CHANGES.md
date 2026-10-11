# Changes made for Blimp

This is just_audio_media_kit 2.1.0 (public domain, see LICENSE), copied in so
the Windows player can set an mpv option the published package doesn't let
apps set. The line marked "Blimp" in `lib/mediakit_player.dart` is the change:

- `sub-auto` is set to `no`. By default mpv opens a `.lrc` file named like the
  song as a subtitle track, and a plain one (lyrics without timestamps) leaves
  the song stuck loading at 0:00 / 0:00. The app reads lyrics itself
  (`DesktopLibrary.lyrics`), so mpv doesn't need them.

The example app was left out.
