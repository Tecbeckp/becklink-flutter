package app.becklink.flutter

import android.content.Context
import java.io.File

/**
 * The SDK's own storage folder for `getStorageDirectory` (`doc/platform-channel.md`), where Dart
 * keeps `state.json` and `events.json`.
 *
 * It lives in `noBackupFilesDir`, which Auto Backup never copies: a restored or migrated device is
 * a new install (contract P26, §42), so the install ID must not travel with a backup.
 */
internal object SdkStorage {
    private const val FOLDER_NAME = "becklink"

    /**
     * The folder's absolute path, created if missing, or `null` when it cannot be created. Disk
     * work: call it off the main thread.
     */
    fun directoryPath(context: Context): String? {
        try {
            // A null parent would turn the folder into a path relative to the process's working
            // directory, so it is checked although Android always reports this directory.
            val noBackup: File = context.noBackupFilesDir ?: return null
            val folder = File(noBackup, FOLDER_NAME)
            // isDirectory once more after mkdirs: a concurrent call may have created it meanwhile.
            val exists = folder.isDirectory || folder.mkdirs() || folder.isDirectory
            return if (exists) folder.absolutePath else null
        } catch (e: SecurityException) {
            return null
        }
    }
}
