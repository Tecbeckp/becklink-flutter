package app.becklink.flutter

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import java.util.Locale

/**
 * The `getDeviceContext` answer (`doc/platform-channel.md`): app and device details for the
 * request `context` (contract section 7.1). Values are sent raw, or `null` when unreadable; Dart
 * trims them, cuts them to the contract's lengths and adds `platform`.
 *
 * Holds no identifier (contract section 12, §54.6): never `ANDROID_ID`, the advertising ID, the
 * serial number or the user-chosen device name. `Build.MODEL` names a product, shared by every
 * device of that model.
 */
internal object DeviceContextReader {
    private const val KEY_OS_VERSION = "os_version"
    private const val KEY_DEVICE_MODEL = "device_model"
    private const val KEY_LOCALE = "locale"
    private const val KEY_APP_VERSION = "app_version"
    private const val KEY_APP_BUILD = "app_build"

    // BCP 47 "undetermined": what toLanguageTag() reports for a locale without a language.
    private const val UNDETERMINED_LANGUAGE = "und"

    /** Asks the package manager, an IPC into the system: call it off the main thread. */
    fun read(context: Context): Map<String, String?> {
        val packageInfo = ownPackageInfo(context)
        return mapOf(
            KEY_OS_VERSION to osVersion(),
            KEY_DEVICE_MODEL to Build.MODEL,
            KEY_LOCALE to locale(),
            KEY_APP_VERSION to packageInfo?.versionName,
            KEY_APP_BUILD to packageInfo?.let { versionCode(it) },
        )
    }

    // RELEASE is the user-facing version ("15"); the API level is the fallback for a build that
    // leaves it empty.
    private fun osVersion(): String {
        val release: String? = Build.VERSION.RELEASE
        return if (release.isNullOrBlank()) Build.VERSION.SDK_INT.toString() else release
    }

    private fun locale(): String? {
        val tag: String? = Locale.getDefault().toLanguageTag()
        return if (tag.isNullOrEmpty() || tag == UNDETERMINED_LANGUAGE) null else tag
    }

    private fun ownPackageInfo(context: Context): PackageInfo? =
        try {
            val packageManager = context.packageManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val noFlags = PackageManager.PackageInfoFlags.of(0L)
                packageManager.getPackageInfo(context.packageName, noFlags)
            } else {
                legacyPackageInfo(packageManager, context.packageName)
            }
        } catch (e: Exception) {
            // NameNotFoundException cannot happen for the app itself; a dying system server
            // (DeadSystemException wrapped in a RuntimeException) can. The versions become null.
            null
        }

    @Suppress("DEPRECATION")
    private fun legacyPackageInfo(
        packageManager: PackageManager,
        packageName: String,
    ): PackageInfo = packageManager.getPackageInfo(packageName, 0)

    private fun versionCode(packageInfo: PackageInfo): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode.toString()
        } else {
            legacyVersionCode(packageInfo).toString()
        }

    @Suppress("DEPRECATION")
    private fun legacyVersionCode(packageInfo: PackageInfo): Int = packageInfo.versionCode
}
