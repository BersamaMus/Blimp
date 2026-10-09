import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/home_widgets.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/shelf.dart';
import 'collection_screen.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'now_playing_screen.dart';
import 'stats_screen.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<_AppShellState>();

/// Opens [page] in the current tab, closing the player or any sheet first,
/// so album and artist pages keep the tab bar and mini player.
void openPage(Widget page) => openRoute(MaterialPageRoute(builder: (_) => page));

/// [openPage], for a route built elsewhere.
void openRoute(Route<void> route) => _shellKey.currentState?.openRoute(route);

/// Switches to the Stats tab, closing the player or any sheet first.
void openStatsTab() => _shellKey.currentState?._showTab(2);

class AppShell extends StatefulWidget {
  AppShell() : super(key: _shellKey);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _tabs = [
    (label: 'Home', icon: Icons.home_outlined, selectedIcon: Icons.home_rounded, root: HomeScreen()),
    (
      label: 'Library',
      icon: Icons.library_music_outlined,
      selectedIcon: Icons.library_music_rounded,
      root: LibraryScreen(),
    ),
    (label: 'Stats', icon: Icons.insights_outlined, selectedIcon: Icons.insights_rounded, root: StatsScreen()),
  ];

  final _navigatorKeys = [for (final _ in _tabs) GlobalKey<NavigatorState>()];
  int _tab = 0;

  NavigatorState get _currentNavigator => _navigatorKeys[_tab].currentState!;

  @override
  void initState() {
    super.initState();
    HomeWidgets.onRequest(_onWidgetRequest);
  }

  /// A home screen widget opened the app: does what it asked once the last
  /// queue is back, and shows the player.
  ///
  /// The Favourites shortcut opens Favourites instead.
  Future<void> _onWidgetRequest(WidgetRequest request) async {
    if (request == WidgetRequest.favourites) return openPage(CollectionScreen.favourites());
    await MusicScope.read(context).handleWidgetRequest(request);
    _openPlayer();
  }

  /// Shows the player, as a home screen widget asks when tapped: closes
  /// whatever's over it if it's already open, or opens it.
  void _openPlayer() {
    if (!mounted || MusicScope.read(context).currentSong == null) return;
    var open = false;
    rootNavigatorKey.currentState!.popUntil((route) {
      if (route.settings.name == nowPlayingRoute) open = true;
      return open || route.isFirst;
    });
    if (!open) openNowPlaying(context);
  }

  void openRoute(Route<void> route) {
    rootNavigatorKey.currentState!.popUntil((route) => route.isFirst);
    _currentNavigator.push(route);
  }

  void _showTab(int index) {
    rootNavigatorKey.currentState!.popUntil((route) => route.isFirst);
    setState(() => _tab = index);
  }

  void _selectTab(int index) {
    if (index == _tab) {
      // Tapping the current tab again returns to its first page.
      _currentNavigator.popUntil((route) => route.isFirst);
    } else {
      setState(() => _tab = index);
    }
  }

  void _handleBack(bool didPop, Object? _) {
    if (didPop) return;
    if (_currentNavigator.canPop()) {
      _currentNavigator.pop();
    } else if (_tab != 0) {
      setState(() => _tab = 0);
    } else {
      SystemNavigator.pop();
    }
  }

  /// Asks again; once Android stops showing the request (after it's been
  /// refused twice), the app's settings page is the only way to allow it.
  Future<void> _requestAccess() async {
    final music = MusicScope.read(context);
    await music.load();
    if (music.status == LibraryStatus.permissionDenied) await openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library});

    // Keep showing the tabs during a rescan so their pages aren't thrown away.
    final Widget body = switch (music.status) {
      _ when music.songs.isNotEmpty => IndexedStack(
          index: _tab,
          children: [
            for (final (i, tab) in _tabs.indexed)
              HeroControllerScope.none(
                child: Navigator(
                  key: _navigatorKeys[i],
                  onGenerateRoute: (settings) =>
                      MaterialPageRoute(settings: settings, builder: (_) => tab.root),
                ),
              ),
          ],
        ),
      LibraryStatus.loading => const Center(child: CircularProgressIndicator()),
      LibraryStatus.permissionDenied => MessageView(
          icon: Icons.lock_outline,
          text: 'Allow access to your music to play the songs on this device.',
          actionLabel: 'Allow access',
          onAction: _requestAccess,
        ),
      // Everything found is hidden by the library's filters, so Settings
      // (behind the tabs) is out of reach: offer to undo them here.
      LibraryStatus.ready when music.allSongsHidden => MessageView(
          icon: Icons.filter_alt_off_outlined,
          text: 'All your songs are hidden by your hidden folders or the short files setting.',
          actionLabel: 'Show all songs',
          onAction: music.showAllSongs,
        ),
      LibraryStatus.ready => MessageView(
          icon: Icons.music_off,
          text: 'No songs found on this device.\nAdd some music files, then rescan.',
          actionLabel: 'Rescan',
          onAction: music.load,
        ),
    };

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handleBack,
      child: Scaffold(
        body: body,
        // The mini player and a pill-shaped tab bar float above the bottom edge.
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MiniPlayer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: MediaQuery.removePadding(
                    // The SafeArea above already handles the system bar inset.
                    // This context is above the Scaffold, so it still carries
                    // the status bar's inset too, which NavigationBar's own
                    // SafeArea would add above the icons.
                    context: context,
                    removeTop: true,
                    removeBottom: true,
                    // A little room above the icons, to balance the label
                    // below the selected one.
                    child: Container(
                      color: AppColors.surfaceHigh,
                      padding: const EdgeInsets.only(top: 6),
                      child: NavigationBar(
                        selectedIndex: _tab,
                        onDestinationSelected: _selectTab,
                        destinations: [
                          for (final tab in _tabs)
                            NavigationDestination(
                              icon: Icon(tab.icon),
                              selectedIcon: Icon(tab.selectedIcon),
                              label: tab.label,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
