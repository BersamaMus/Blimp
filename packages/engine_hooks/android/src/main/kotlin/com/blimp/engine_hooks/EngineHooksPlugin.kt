package com.blimp.engine_hooks

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Flutter registers plugins on every engine it starts, including the one the
 * playback service starts when there's no app screen. The app sets
 * [onEngineStarted] to set its own channels up on each of them.
 */
class EngineHooksPlugin : FlutterPlugin {
    companion object {
        var onEngineStarted: ((FlutterPlugin.FlutterPluginBinding) -> Unit)? = null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onEngineStarted?.invoke(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
