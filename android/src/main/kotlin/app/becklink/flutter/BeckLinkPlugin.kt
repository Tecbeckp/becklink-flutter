package app.becklink.flutter

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Android entry point of the becklink_flutter plugin; implements the wire contract in
 * `doc/platform-channel.md`.
 *
 * Deliberately thin: the Dart layer owns networking, storage and attribution, so this class only
 * exposes what Dart cannot reach on Android. Flutter calls it on the main thread and every reply is
 * sent from there; blocking work (disk, package manager, Play Store IPC) runs in the background
 * ([NativeThreads]). Reads no identifier: no `ANDROID_ID`, no advertising ID (§54.6).
 */
class BeckLinkPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {
    private var applicationContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private var linkChannel: EventChannel? = null
    private var incomingLinks: IncomingLinks? = null
    private var activityBinding: ActivityPluginBinding? = null

    // The saved state marks an activity this plugin has seen: when Android recreates it from that
    // state, its launch intent was already reported (doc/platform-channel.md, getInitialLink).
    private val saveStateListener =
        object : ActivityPluginBinding.OnSaveInstanceStateListener {
            override fun onSaveInstanceState(bundle: Bundle) {
                bundle.putBoolean(STATE_LAUNCH_LINK_SEEN, true)
            }

            override fun onRestoreInstanceState(bundle: Bundle?) {
                if (bundle?.getBoolean(STATE_LAUNCH_LINK_SEEN, false) == true) {
                    incomingLinks?.onActivityRecreated()
                }
            }
        }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        val stream = LinkStreamHandler()
        incomingLinks = IncomingLinks(stream)
        linkChannel =
            EventChannel(binding.binaryMessenger, LINK_CHANNEL).also {
                it.setStreamHandler(stream)
            }
        methodChannel =
            MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
                it.setMethodCallHandler(this)
            }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        linkChannel?.setStreamHandler(null)
        linkChannel = null
        incomingLinks?.dispose()
        incomingLinks = null
        applicationContext = null
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val context = applicationContext
        val links = incomingLinks
        if (context == null || links == null) {
            // Only a call racing the engine's detach gets here; Dart treats it as no plugin.
            result.notImplemented()
            return
        }
        when (call.method) {
            "getInitialLink" -> links.getInitialLink(result)
            "getStorageDirectory" -> answerStorageDirectory(context, result)
            // Android keeps nothing outside the app container that survives an uninstall (no
            // Keychain equivalent), so there is no seed and nothing to save.
            "getInstallIdSeed" -> result.success(null)
            "saveInstallIdSeed" -> result.success(false)
            "getInstallReferrer" -> InstallReferrerReader.forProcess(context).read(result)
            // The pasteboard deferred link is iOS only (IOS-005).
            "readPasteboardUrl" -> result.success(null)
            "getDeviceContext" -> answerDeviceContext(context, result)
            // Answered so Dart never waits for a reply that would not come.
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        observeActivity(binding)
        incomingLinks?.onActivityAttached(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        stopObservingActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        // The same engine on the activity recreated for a configuration change: its launch intent
        // is the one already handled, so only the listeners move to the new instance.
        observeActivity(binding)
    }

    override fun onDetachedFromActivity() {
        stopObservingActivity()
    }

    override fun onNewIntent(intent: Intent): Boolean {
        incomingLinks?.onNewIntent(intent)
        // Observe, never claim: Flutter may stop at the first listener that returns true, which
        // would hide OAuth callbacks and other URLs from other plugins.
        return false
    }

    private fun observeActivity(binding: ActivityPluginBinding) {
        stopObservingActivity()
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        binding.addOnSaveStateListener(saveStateListener)
    }

    private fun stopObservingActivity() {
        activityBinding?.let {
            it.removeOnNewIntentListener(this)
            it.removeOnSaveStateListener(saveStateListener)
        }
        activityBinding = null
    }

    private fun answerStorageDirectory(
        context: Context,
        result: MethodChannel.Result,
    ) {
        NativeThreads.runInBackground {
            val path = SdkStorage.directoryPath(context)
            NativeThreads.onMain {
                if (path != null) {
                    result.success(path)
                } else {
                    // Dart then keeps its state in memory for this process.
                    result.error(STORAGE_UNAVAILABLE, STORAGE_UNAVAILABLE_MESSAGE, null)
                }
            }
        }
    }

    private fun answerDeviceContext(
        context: Context,
        result: MethodChannel.Result,
    ) {
        NativeThreads.runInBackground {
            val deviceContext = DeviceContextReader.read(context)
            NativeThreads.onMain { result.success(deviceContext) }
        }
    }

    private companion object {
        const val METHOD_CHANNEL = "app.becklink.flutter/methods"
        const val LINK_CHANNEL = "app.becklink.flutter/links"
        const val STORAGE_UNAVAILABLE = "storage_unavailable"
        const val STORAGE_UNAVAILABLE_MESSAGE = "The SDK storage folder could not be created"
        const val STATE_LAUNCH_LINK_SEEN = "app.becklink.flutter.launch_link_seen"
    }
}
