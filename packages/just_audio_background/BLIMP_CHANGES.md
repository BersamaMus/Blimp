# Changes made for Blimp

This is just_audio_background 0.0.1-beta.17 (MIT, see LICENSE), copied in so
the app can offer its library to Android Auto and other media browsers, which
the published package doesn't allow. Everything marked "Blimp" in
`lib/just_audio_background.dart` is the change:

- `MediaBrowserDelegate` and `JustAudioBackground.browser`, which the app sets.
- `_PlayerAudioHandler`, and `_BrowsingAudioHandler` before it takes over,
  pass `getChildren`, `playFromMediaId`, `search` and
  `playFromSearch` on to it.

The example app was left out.
