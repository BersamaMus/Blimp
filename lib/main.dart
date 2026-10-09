import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'screens/app_shell.dart';
import 'services/car_browser.dart';
import 'services/desktop_library.dart';
import 'services/home_widgets.dart';
import 'services/music_controller.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) {
    // just_audio has no player of its own on desktop; media_kit's plays there.
    JustAudioMediaKit.ensureInitialized();
  } else {
    // Runs playback in a foreground service, so music keeps going with the
    // app in the background, and adds the notification, lock-screen and
    // headset controls. Must run before the first AudioPlayer is created.
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.blimp.app.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationChannelDescription: "Controls for the song that's playing",
      androidNotificationIcon: 'drawable/ic_stat_music',
      notificationColor: AppColors.accent,
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    );
  }
  // Decoded covers are the app's biggest memory cost. Artwork is decoded at
  // display size, so this holds a few screens' worth while staying modest on
  // low-RAM phones (Flutter's default is 100 MB / 1000 images).
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 48 << 20
    ..maximumSize = 300;
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  final controller = MusicController();
  // Android Auto and other media browsers show the library through this.
  if (!isDesktop) JustAudioBackground.browser = CarBrowser(controller);
  controller.init();
  runApp(BetterMusicPlayerApp(controller: controller));
}

class BetterMusicPlayerApp extends StatefulWidget {
  const BetterMusicPlayerApp({super.key, required this.controller});

  final MusicController controller;

  @override
  State<BetterMusicPlayerApp> createState() => _BetterMusicPlayerAppState();
}

class _BetterMusicPlayerAppState extends State<BetterMusicPlayerApp> {
  @override
  void initState() {
    super.initState();
    // In case the home screen widgets were last coloured by an older version.
    HomeWidgets.setColors(AppColors.accent, AppColors.onAccent);
  }

  @override
  Widget build(BuildContext context) {
    return MusicScope(
      controller: widget.controller,
      child: MaterialApp(
        title: 'Blimp',
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        theme: buildTheme(),
        home: AppShell(),
      ),
    );
  }
}
