package io.github.m0rf30.opencie

import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * JNI bridge between Android NFC stack and libopencie-pkcs11.
 *
 * The native library exports both plain-C entry points and JNI-named
 * wrappers (Java_it_m0rf30_opencie_CieNfcBridge_*) for the methods below,
 * so a single System.loadLibrary("opencie-pkcs11") is sufficient.
 *
 * Load order (MUST be respected):
 *   1. System.loadLibrary("opencie-pkcs11")  → JNI_OnLoad caches JavaVM*
 *   2. onTagDiscovered(tag)                  → connect IsoDep + setNfcTag
 *   3. ... PKCS#11 operations via Dart FFI ...
 *   4. clearNfcTag() + close IsoDep
 *
 * CRITICAL: Dart FFI must NOT call dlopen("libopencie-pkcs11.so") before
 * step 1 above has completed. JNI_OnLoad must run first so the library's
 * JNIEnv is properly initialized. Kotlin owns the load order; Dart opens
 * the same library later for direct FFI calls (including cie_set_data_dir).
 */
object CieNfcBridge {

    private const val TAG = "CieNfcBridge"

    private var currentIsoDep: IsoDep? = null
    private var libraryLoaded = false
    private val processingTag = AtomicBoolean(false)

    /**
     * Load the native library. Called once at app startup.
     * Returns true if the library was loaded successfully.
     */
    fun ensureLibraryLoaded(): Boolean {
        if (libraryLoaded) return true
        return try {
            System.loadLibrary("opencie-pkcs11")
            libraryLoaded = true
            Log.i(TAG, "Native library loaded successfully")
            true
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Failed to load native library: ${e.message}")
            false
        }
    }

    /**
     * Called when an NFC tag (CIE card) is discovered.
     * Connects the IsoDep technology and passes it to the native library.
     */
    fun onTagDiscovered(tag: Tag): Boolean {
        // Guard against re-entry during a wobbly tap (binder thread can
        // deliver multiple discovery events before the first one finishes).
        // Released after connect()+nativeSetNfcTag() — protects the connect
        // phase only. The actual CIE session (PACE + sign) runs later from
        // Dart; subsequent taps during the session are guarded by IsoDep
        // already being busy with a different Tag object.
        if (!processingTag.compareAndSet(false, true)) {
            Log.w(TAG, "Tag discovery already in progress, ignoring duplicate")
            return false
        }
        try {
            if (!ensureLibraryLoaded()) return false

            val isoDep = IsoDep.get(tag)
            if (isoDep == null) {
                Log.w(TAG, "Tag does not support IsoDep")
                return false
            }

            // Per-APDU transceive timeout. RSA-2048 sign on the chip's
            // coprocessor + secure-messaging wrap can take 2–4s on slow
            // phones with weak coupling; 15s leaves ~3× headroom over the
            // worst legitimate single APDU without delaying real failures.
            // (Removed-tag detection runs on a separate presence-check
            // thread, so a larger value here doesn't slow that down.)
            isoDep.timeout = 15_000
            isoDep.connect()

            // Pass to native library
            nativeSetNfcTag(isoDep)
            currentIsoDep = isoDep

            Log.i(TAG, "CIE NFC tag connected and passed to native library")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to connect NFC tag: ${e.message}")
            return false
        } finally {
            processingTag.set(false)
        }
    }

    /**
     * Called when the NFC operation completes or the tag is lost.
     * Clears the native reference and closes the IsoDep connection.
     */
    fun clearTag() {
        try {
            if (libraryLoaded) {
                nativeClearNfcTag()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error clearing native NFC tag: ${e.message}")
        }

        try {
            currentIsoDep?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing IsoDep: ${e.message}")
        }
        currentIsoDep = null
    }

    /**
     * Whether an NFC tag is currently connected.
     */
    val isTagConnected: Boolean
        get() = currentIsoDep?.isConnected == true

    // JNI native methods — implemented directly inside libopencie-pkcs11.so
    // (the upstream library exports both plain-C and JNI-named entry points).
    @JvmStatic
    private external fun nativeSetNfcTag(isoDep: Any)
    @JvmStatic
    private external fun nativeClearNfcTag()
}
