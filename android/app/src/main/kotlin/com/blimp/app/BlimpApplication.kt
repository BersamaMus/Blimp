package com.blimp.app

import com.blimp.engine_hooks.EngineHooksPlugin
import io.flutter.app.FlutterApplication

/**
 * Sets the app's channels to Android up on each Flutter engine as it starts,
 * whether the app's screen started it or the playback service did (as when
 * Android Auto opens the app with no screen).
 */
class BlimpApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        EngineHooksPlugin.onEngineStarted = { binding ->
            AppChannels.register(binding.applicationContext, binding.binaryMessenger)
        }
    }
}
