# The home screen widgets' buttons reach audio_service's running playback
# service and its media session by reflection (HomeWidgets.mediaController in
# NowPlayingWidgets.kt). Release builds shrink and rename code, so the names
# looked up there are kept.
-keepclassmembers class com.ryanheise.audioservice.AudioService {
    static ** instance;
}
-keepclassmembers class androidx.media.MediaBrowserServiceCompat {
    public ** getSessionToken();
}
-keepclassmembers class android.support.v4.media.session.MediaSessionCompat$Token {
    public ** getToken();
}
