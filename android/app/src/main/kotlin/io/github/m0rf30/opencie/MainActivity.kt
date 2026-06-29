// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

package io.github.m0rf30.opencie

import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.os.Bundle
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.CompletableFuture

/**
 * Main activity for the OpenCIE Flutter app.
 *
 * Bridges the Android NFC stack to the Flutter/Dart layer via a MethodChannel.
 * Uses [NfcAdapter.enableReaderMode] for reliable CIE (IsoDep) tag discovery,
 * forwarding raw Tag objects to [CieNfcBridge] which passes them to the
 * native PKCS#11 library via JNI.
 *
 * Also hosts a second MethodChannel for Storage Access Framework (SAF)
 * operations so the app can write signed documents to user-selected folders
 * without requesting broad storage permissions.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val NFC_CHANNEL = "io.github.m0rf30.opencie/nfc"
        private const val STORAGE_CHANNEL = "io.github.m0rf30.opencie/storage"
        private const val REQ_CODE_OPEN_DOCUMENT_TREE = 42

        // NfcAdapter.FLAG_READER_NFC_A covers IsoDep (ISO 14443-4A) used by CIE.
        // FLAG_READER_SKIP_NDEF_CHECK avoids NDEF dispatch delay.
        // FLAG_READER_NO_PLATFORM_SOUNDS suppresses the OS "ding" on tag detect
        // so the app can play its own cue tied to actual session start (PACE
        // success), not to mere field entry — better UX feedback alignment.
        private const val READER_FLAGS =
            NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
    }

    private var nfcAdapter: NfcAdapter? = null
    private var nfcMethodChannel: MethodChannel? = null
    private var storageMethodChannel: MethodChannel? = null
    private var pendingTreePicker: CompletableFuture<String?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        nfcAdapter = NfcAdapter.getDefaultAdapter(this)

        nfcMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NFC_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isNfcAvailable" -> {
                        result.success(nfcAdapter?.isEnabled == true)
                    }

                    "startNfcSession" -> {
                        val started = startReaderMode()
                        result.success(started)
                    }

                    "stopNfcSession" -> {
                        stopReaderMode()
                        result.success(true)
                    }

                    "clearTag" -> {
                        CieNfcBridge.clearTag()
                        result.success(true)
                    }

                    "isTagConnected" -> {
                        result.success(CieNfcBridge.isTagConnected)
                    }

                    "openNfcSettings" -> {
                        val intent = android.content.Intent(
                            android.provider.Settings.ACTION_NFC_SETTINGS
                        )
                        startActivity(intent)
                        result.success(true)
                    }

                    "scanMediaFile" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            MediaScannerConnection.scanFile(
                                applicationContext,
                                arrayOf(path),
                                null
                            ) { _, _ -> }
                            result.success(true)
                        } else {
                            result.error("INVALID_PATH", "path argument is null", null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
        }

        storageMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDefaultOutputDir" -> {
                        result.success(filesDir.absolutePath)
                    }

                    "pickOutputFolder" -> {
                        val future = CompletableFuture<String?>()
                        pendingTreePicker = future
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        startActivityForResult(intent, REQ_CODE_OPEN_DOCUMENT_TREE)
                        future.thenAccept { uri ->
                            runOnUiThread { result.success(uri) }
                        }
                    }

                    "writeFileToTreeUri" -> {
                        val treeUriStr = call.argument<String>("treeUri")
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType")

                        if (treeUriStr == null || sourcePath == null || fileName == null) {
                            result.error("INVALID_ARGS", "Missing required arguments", null)
                            return@setMethodCallHandler
                        }

                        val treeUri = Uri.parse(treeUriStr)
                        val tree = DocumentFile.fromTreeUri(this, treeUri)
                        if (tree == null || !tree.canWrite()) {
                            result.error("NO_ACCESS", "Cannot write to selected folder", null)
                            return@setMethodCallHandler
                        }

                        val newFile = tree.createFile(mimeType ?: "application/octet-stream", fileName)
                        if (newFile == null) {
                            result.error("CREATE_FAILED", "Failed to create file in SAF tree", null)
                            return@setMethodCallHandler
                        }

                        try {
                            contentResolver.openOutputStream(newFile.uri)?.use { output ->
                                FileInputStream(File(sourcePath)).use { input ->
                                    input.copyTo(output)
                                }
                            }
                            result.success(newFile.uri.toString())
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", e.message, null)
                        }
                    }

                    "canWriteToSafTree" -> {
                        val treeUriStr = call.argument<String>("treeUri")
                        if (treeUriStr == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val tree = DocumentFile.fromTreeUri(this, Uri.parse(treeUriStr))
                        result.success(tree != null && tree.canWrite())
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_CODE_OPEN_DOCUMENT_TREE) {
            val future = pendingTreePicker
            pendingTreePicker = null
            if (resultCode == RESULT_OK && data != null) {
                val uri = data.data
                if (uri != null) {
                    // Persist permission across reboots
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                    // Cache in SharedPreferences for quick recovery
                    getSharedPreferences("opencie_storage", MODE_PRIVATE)
                        .edit()
                        .putString("saf_output_uri", uri.toString())
                        .apply()
                    future?.complete(uri.toString())
                } else {
                    future?.complete(null)
                }
            } else {
                future?.complete(null)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Start reader mode eagerly so the manifest intent filter never fires
        // while the wizard is open (prevents activity restart mid-flow).
        startReaderMode()
    }

    override fun onPause() {
        super.onPause()
        // Stop reader mode when the activity is not visible to save power.
        stopReaderMode()
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        // All NFC tag events are handled via enableReaderMode; nothing to do here.
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        nfcMethodChannel?.setMethodCallHandler(null)
        nfcMethodChannel = null
        storageMethodChannel?.setMethodCallHandler(null)
        storageMethodChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Enable NFC reader mode. When a tag is detected, [onTagDiscovered] fires
     * on a binder thread — we forward it to [CieNfcBridge] and notify Dart.
     */
    private fun startReaderMode(): Boolean {
        val adapter = nfcAdapter ?: return false
        if (!adapter.isEnabled) return false

        // Ensure the native library is loaded before we can receive tags.
        CieNfcBridge.ensureLibraryLoaded()

        adapter.enableReaderMode(
            this,
            { tag -> onTagDiscovered(tag) },
            READER_FLAGS,
            Bundle().apply {
                // Debounce: wait 500ms before reporting tag removed.
                putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 500)
            }
        )
        return true
    }

    private fun stopReaderMode() {
        nfcAdapter?.disableReaderMode(this)
        CieNfcBridge.clearTag()
    }

    /**
     * Called on a binder thread when an NFC tag enters the field.
     * Forwards the tag to the JNI bridge and notifies Dart of the result.
     */
    private fun onTagDiscovered(tag: Tag) {
        val success = CieNfcBridge.onTagDiscovered(tag)

        // Notify Dart on the main (UI) thread.
        runOnUiThread {
            nfcMethodChannel?.invokeMethod(
                "onTagDiscovered",
                mapOf("success" to success)
            )
        }
    }
}
