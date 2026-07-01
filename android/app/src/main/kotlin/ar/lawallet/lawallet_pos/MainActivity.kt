package ar.lawallet.lawallet_pos

import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.os.Handler
import android.os.Looper
import android.text.Layout
import android.util.Log
import com.zcs.sdk.DriverManager
import com.zcs.sdk.Printer
import com.zcs.sdk.SdkResult
import com.zcs.sdk.Sys
import com.zcs.sdk.print.PrnStrFormat
import com.zcs.sdk.print.PrnTextFont
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the ZCS SmartPos thermal printer to Flutter via a MethodChannel,
 * mirroring android-pos-wrapper's PrintThread (DriverManager -> Sys.sdkInit ->
 * Printer.setPrintAppendString/... -> setPrintStart).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "pos/printer"
    private var printer: Printer? = null
    private var initialized = false

    // NFC (Boltcard / LNURL-withdraw)
    private val nfcChannelName = "pos/nfc"
    private var pendingNfc: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())
    private var nfcTimeout: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(ensureInit())
                    "status" -> result.success(printerStatus())
                    "testPrint" -> handle(result) { testPrint() }
                    "print" -> handle(result) {
                        @Suppress("UNCHECKED_CAST")
                        printOrder(call.arguments as? Map<String, Any?> ?: emptyMap())
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nfcChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(nfcAvailable())
                    "read" -> startNfcRead(result)
                    "cancel" -> { stopNfcRead(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }

    // ---- NFC ----

    private fun nfcAvailable(): Boolean {
        val a = NfcAdapter.getDefaultAdapter(this)
        return a != null && a.isEnabled
    }

    /** Reads one NFC tag and returns its NDEF URL (e.g. lnurlw://…) to Dart. */
    private fun startNfcRead(result: MethodChannel.Result) {
        val adapter = NfcAdapter.getDefaultAdapter(this)
        if (adapter == null || !adapter.isEnabled) {
            result.error("NFC_UNAVAILABLE", "NFC no disponible o desactivado", null)
            return
        }
        pendingNfc?.let { runCatching { it.error("NFC_CANCELLED", "Reemplazado", null) } }
        pendingNfc = result
        val flags = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_NFC_V
        adapter.enableReaderMode(this, { tag -> onNfcTag(tag) }, flags, null)
        nfcTimeout = Runnable {
            val r = pendingNfc; pendingNfc = null
            runCatching { adapter.disableReaderMode(this) }
            r?.error("NFC_TIMEOUT", "Tiempo de espera agotado", null)
        }
        handler.postDelayed(nfcTimeout!!, 60000)
    }

    private fun stopNfcRead() {
        nfcTimeout?.let { handler.removeCallbacks(it) }
        nfcTimeout = null
        runCatching { NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this) }
        pendingNfc?.let { runCatching { it.error("NFC_CANCELLED", "Cancelado", null) } }
        pendingNfc = null
    }

    private fun onNfcTag(tag: Tag) {
        var url: String? = null
        var err: String? = null
        try {
            val ndef = Ndef.get(tag)
            if (ndef != null) {
                ndef.connect()
                val msg = runCatching { ndef.ndefMessage }.getOrNull() ?: ndef.cachedNdefMessage
                runCatching { ndef.close() }
                url = extractUrl(msg)
            }
            if (url == null) err = "Tarjeta sin datos NDEF"
        } catch (e: Throwable) {
            err = e.message ?: "Error leyendo la tarjeta"
        }
        val u = url
        runOnUiThread {
            nfcTimeout?.let { handler.removeCallbacks(it) }
            nfcTimeout = null
            val r = pendingNfc; pendingNfc = null
            runCatching { NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this) }
            if (u != null) r?.success(u) else r?.error("NFC_READ", err ?: "No se pudo leer", null)
        }
    }

    private fun extractUrl(msg: NdefMessage?): String? {
        if (msg == null) return null
        for (rec in msg.records) {
            val payload = rec.payload
            when {
                rec.tnf == NdefRecord.TNF_ABSOLUTE_URI ->
                    return String(rec.type, Charsets.UTF_8)
                rec.tnf == NdefRecord.TNF_WELL_KNOWN &&
                    rec.type.contentEquals(NdefRecord.RTD_URI) -> {
                    if (payload.isEmpty()) continue
                    val prefix = uriPrefix(payload[0].toInt() and 0xFF)
                    return prefix + String(payload, 1, payload.size - 1, Charsets.UTF_8)
                }
                rec.tnf == NdefRecord.TNF_WELL_KNOWN &&
                    rec.type.contentEquals(NdefRecord.RTD_TEXT) -> {
                    if (payload.isEmpty()) continue
                    val status = payload[0].toInt()
                    val langLen = status and 0x3F
                    val enc = if (status and 0x80 == 0) Charsets.UTF_8 else Charsets.UTF_16
                    return String(payload, 1 + langLen, payload.size - 1 - langLen, enc)
                }
            }
        }
        for (rec in msg.records) rec.toUri()?.let { return it.toString() }
        return null
    }

    private fun uriPrefix(code: Int): String = when (code) {
        0x01 -> "http://www."
        0x02 -> "https://www."
        0x03 -> "http://"
        0x04 -> "https://"
        else -> ""
    }

    private inline fun handle(result: MethodChannel.Result, block: () -> Int) {
        try {
            result.success(block())
        } catch (e: Throwable) {
            result.error("PRINT_ERROR", e.message ?: e.toString(), null)
        }
    }

    /** Initialize the ZCS SDK + printer once. Mirrors the wrapper (getInstance +
     *  getPrinter); sdkInit is best-effort since some devices auto-init. */
    private fun ensureInit(): Boolean {
        if (initialized && printer != null) return true
        return try {
            val dm = DriverManager.getInstance()
            try {
                val sys: Sys = dm.getBaseSysDevice()
                val st = sys.sdkInit()
                Log.i(TAG, "sdkInit=$st")
                if (st != SdkResult.SDK_OK) {
                    try { sys.sysPowerOn() } catch (e: Throwable) { Log.w(TAG, "sysPowerOn", e) }
                    Thread.sleep(800)
                    Log.i(TAG, "sdkInit retry=${sys.sdkInit()}")
                }
            } catch (e: Throwable) {
                Log.w(TAG, "sdkInit best-effort failed, continuing", e)
            }
            printer = dm.getPrinter()
            initialized = printer != null
            Log.i(TAG, "getPrinter available=$initialized")
            initialized
        } catch (e: Throwable) {
            Log.e(TAG, "printer init failed", e)
            initialized = false
            false
        }
    }

    private fun printerStatus(): Int {
        if (!ensureInit()) return STATUS_UNAVAILABLE
        return try {
            printer!!.getPrinterStatus()
        } catch (e: Throwable) {
            STATUS_ERROR
        }
    }

    private fun fmt(size: Int, ali: Layout.Alignment): PrnStrFormat {
        val f = PrnStrFormat()
        f.setTextSize(size)
        f.setAli(ali)
        f.setFont(PrnTextFont.MONOSPACE)
        return f
    }

    private fun testPrint(): Int {
        if (!ensureInit()) throw RuntimeException("Impresora no disponible")
        val p = printer!!
        val status = p.getPrinterStatus()
        if (status == SdkResult.SDK_PRN_STATUS_PAPEROUT) return status
        p.setPrintAppendString("LaWallet POS", fmt(30, Layout.Alignment.ALIGN_CENTER))
        p.setPrintAppendString("Prueba de impresora", fmt(24, Layout.Alignment.ALIGN_CENTER))
        p.setPrintAppendString("--------------------------------", fmt(22, Layout.Alignment.ALIGN_NORMAL))
        p.setPrintAppendString("Conexion OK", fmt(24, Layout.Alignment.ALIGN_CENTER))
        p.setPrintLine(10)
        p.setPrintAppendQRCode("https://lawallet.ar", 360, 360, Layout.Alignment.ALIGN_CENTER)
        p.setPrintLine(40)
        return p.setPrintStart()
    }

    private fun printOrder(order: Map<String, Any?>): Int {
        if (!ensureInit()) throw RuntimeException("Impresora no disponible")
        val p = printer!!
        val status = p.getPrinterStatus()
        if (status == SdkResult.SDK_PRN_STATUS_PAPEROUT) return status

        val normal = fmt(20, Layout.Alignment.ALIGN_NORMAL)
        p.setPrintAppendString("LaWallet POS", fmt(30, Layout.Alignment.ALIGN_CENTER))
        p.setPrintAppendString("--------------------------------", normal)

        val items = order["items"] as? List<*> ?: emptyList<Any>()
        for (it in items) {
            val m = it as? Map<*, *> ?: continue
            val name = m["name"]?.toString() ?: ""
            val qty = (m["qty"] as? Number)?.toInt() ?: 1
            val price = m["price"]?.toString() ?: ""
            p.setPrintAppendString("$name ($price) x $qty", normal)
            p.setPrintLine(1)
        }

        p.setPrintAppendString("--------------------------------", normal)
        p.setPrintLine(6)
        p.setPrintAppendString("***** TOTAL *****", fmt(34, Layout.Alignment.ALIGN_CENTER))
        val currency = order["currency"]?.toString() ?: "ARS"
        val total = order["total"]?.toString() ?: "0"
        val totalSats = order["totalSats"]?.toString() ?: "0"
        p.setPrintAppendString("$currency $total", fmt(34, Layout.Alignment.ALIGN_CENTER))
        p.setPrintAppendString("$totalSats sats", fmt(24, Layout.Alignment.ALIGN_CENTER))

        val qr = order["qrcode"]?.toString()
        if (!qr.isNullOrEmpty()) {
            p.setPrintLine(10)
            p.setPrintAppendQRCode(qr, 500, 500, Layout.Alignment.ALIGN_CENTER)
        }
        p.setPrintLine(40)
        return p.setPrintStart()
    }

    companion object {
        private const val TAG = "PosPrinter"
        private const val STATUS_UNAVAILABLE = -100
        private const val STATUS_ERROR = -101
    }
}
