import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/desktop_window.dart';
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

/// The tab showing; shared with [DesktopFrame]'s side tabs, which are
/// outside the shell.
final _currentTab = ValueNotifier<int>(0);

/// Opens [page] in the current tab, closing the player or any sheet first,
/// so album and artist pages keep the tab bar and mini player.
void openPage(Widget page) => openRoute(MaterialPageRoute(builder: (_) => page));

/// [openPage], for a route built elsewhere.
void openRoute(Route<void> route) => _shellKey.currentState?.openRoute(route);

/// From this window width up, the desktop app's tabs run down the side
/// (Material's "expanded" size). Phones and tablets keep the bottom bar.
const wideLayoutWidth = 840.0;

/// How wide pages and the mini player get in a wide window, so lines stay
/// readable. Wide enough to fill a 16:9 screen once WindowScale has zoomed
/// the UI; only wider windows, like ultrawides, leave space at the sides.
const readableWidth = 1400.0;

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
  @override
  void dispose() {
    _currentTab.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() => setState(() {});

  int get _tab => _currentTab.value;

  NavigatorState get _currentNavigator => _navigatorKeys[_tab].currentState!;

  @override
  void initState() {
    super.initState();
    HomeWidgets.onRequest(_onWidgetRequest);
    _currentTab.addListener(_onTab);
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
    _currentTab.value = index;
  }

  void _selectTab(int index) {
    // From the side tabs, which stay clickable with the player or a sheet
    // open: that closes, and the tab shows as it was left.
    final root = rootNavigatorKey.currentState!;
    if (root.canPop()) {
      root.popUntil((route) => route.isFirst);
      _currentTab.value = index;
    } else if (index == _tab) {
      // Tapping the current tab again returns to its first page.
      _currentNavigator.popUntil((route) => route.isFirst);
    } else {
      _currentTab.value = index;
    }
  }

  void _handleBack(bool didPop, Object? _) {
    if (didPop) return;
    if (_currentNavigator.canPop()) {
      _currentNavigator.pop();
    } else if (_tab != 0) {
      _currentTab.value = 0;
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
      child: DesktopFrame.showsTabs(context) ? _wideLayout(body) : _narrowLayout(context, body),
    );
  }

  /// A wide desktop window: the pages and mini player kept to a readable
  /// width, beside [DesktopFrame]'s tabs.
  Widget _wideLayout(Widget body) {
    Widget readable(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: readableWidth),
        child: child,
      ),
    );
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: readable(body)),
          Padding(padding: const EdgeInsets.only(top: 8, bottom: 4), child: readable(const MiniPlayer())),
        ],
      ),
    );
  }

  /// A phone: the mini player and a pill-shaped tab bar float above the
  /// bottom edge.
  Widget _narrowLayout(BuildContext context, Widget body) {
    return Scaffold(
      body: body,
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
    );
  }
}

/// Around the app's navigator on desktop. In a wide window the tabs run down
/// the left side out here, so the player, sheets and dialogs open beside
/// them rather than over them, and they can always be clicked.
class DesktopFrame extends StatelessWidget {
  const DesktopFrame({super.key, required this.child});

  final Widget child;

  /// Whether the tabs are down the side: pages lay out for a wide window.
  static bool showsTabs(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SideTabs>()?.shown ?? false;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= wideLayoutWidth;
        // The same shape either way, with the tabs added or taken away, so
        // the app below isn't rebuilt as the window crosses the width.
        return Material(
          color: AppColors.background,
          child: Row(
            children: [
              if (wide)
                // Its own overlay for the Quit button's tooltip: the frame
                // is above the Navigator, whose overlay the pages use.
                Overlay.wrap(
                  child: ValueListenableBuilder(
                    valueListenable: _currentTab,
                    builder: (context, tab, _) => NavigationRail(
                      selectedIndex: tab,
                      onDestinationSelected: (i) => _shellKey.currentState?._selectTab(i),
                      groupAlignment: -0.9,
                      // At the bottom, away from the tabs.
                      trailing: Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: IconButton(
                              tooltip: 'Quit',
                              icon: const Icon(Icons.power_settings_new_rounded),
                              color: AppColors.textSecondary,
                              onPressed: DesktopWindow.quit,
                            ),
                          ),
                        ),
                      ),
                      destinations: [
                        for (final tab in _AppShellState._tabs)
                          NavigationRailDestination(
                            icon: Icon(tab.icon),
                            selectedIcon: Icon(tab.selectedIcon),
                            label: Text(tab.label),
                          ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  // Pages see the room beside the tabs as the window.
                  builder: (context, area) => MediaQuery(
                    data: media.copyWith(size: area.biggest),
                    child: _SideTabs(shown: wide, child: child),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Tells what's beside [DesktopFrame] whether its tabs are showing.
class _SideTabs extends InheritedWidget {
  const _SideTabs({required this.shown, required super.child});

  final bool shown;

  @override
  bool updateShouldNotify(_SideTabs old) => old.shown != shown;
}
