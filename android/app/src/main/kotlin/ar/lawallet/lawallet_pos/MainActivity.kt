package ar.lawallet.lawallet_pos

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
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
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Bridges the ZCS SmartPos thermal printer to Flutter via a MethodChannel,
 * mirroring android-pos-wrapper's PrintThread (DriverManager -> Sys.sdkInit ->
 * Printer.setPrintAppendString/... -> setPrintStart).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "pos/printer"
    private var printer: Printer? = null
    private var initialized = false

    // All printer I/O runs off the UI thread on a single background thread. Single
    // thread = jobs are serialized (the ZCS printer handles one job at a time) and
    // the UI never blocks on sdkInit / bitmap append / setPrintStart.
    private val printExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // NFC (Boltcard / LNURL-withdraw) — reader mode stays on for the whole time the
    // app is foregrounded (any screen), so an accidental tap is always captured here
    // and never redirects to the system Tag viewer. Each tag's URL is streamed to
    // Dart; the payment screen decides when to act on it.
    private val nfcChannelName = "pos/nfc"
    private val nfcEventsName = "pos/nfc/tags"
    private var nfcEvents: EventChannel.EventSink? = null
    private var nfcActive = false

    override fun onResume() {
        super.onResume()
        enableReader() // always capture every tap while foregrounded
    }

    override fun onPause() {
        super.onPause()
        // Reader mode is tied to the resumed activity; drop it while backgrounded.
        runCatching { NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this) }
    }

    override fun onDestroy() {
        printExecutor.shutdown()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> runAsync(result) { ensureInit() }
                    "status" -> runAsync(result) { printerStatus() }
                    "testPrint" -> runAsync(result) { testPrint() }
                    "print" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as? Map<String, Any?> ?: emptyMap()
                        runAsync(result) { printOrder(args) }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nfcChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(nfcAvailable())
                    // Reader mode is global (enabled in onResume); these just report
                    // state / ensure it's armed. stopSession is intentionally a no-op
                    // so leaving the payment screen never drops global tap capture.
                    "startSession" -> { enableReader(); result.success(nfcActive) }
                    "stopSession" -> result.success(null)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, nfcEventsName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    nfcEvents = sink
                }

                override fun onCancel(args: Any?) {
                    nfcEvents = null
                }
            })
    }

    // ---- NFC ----

    private fun nfcAvailable(): Boolean {
        val a = NfcAdapter.getDefaultAdapter(this)
        return a != null && a.isEnabled
    }

    /** Enable reader mode (exclusive) so the system's Tag viewer never intercepts a
     *  tap; each tag is streamed to Dart. Idempotent — safe to call on every resume. */
    private fun enableReader() {
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return
        if (!adapter.isEnabled) return
        val flags = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_NFC_V or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
        adapter.enableReaderMode(this, { tag -> onNfcTag(tag) }, flags, null)
        nfcActive = true
    }

    private fun onNfcTag(tag: Tag) {
        var url: String? = null
        try {
            val ndef = Ndef.get(tag)
            if (ndef != null) {
                ndef.connect()
                val msg = runCatching { ndef.ndefMessage }.getOrNull() ?: ndef.cachedNdefMessage
                runCatching { ndef.close() }
                url = extractUrl(msg)
            }
        } catch (e: Throwable) {
            url = null
        }
        val u = url ?: return
        // Keep reader mode active for subsequent taps; just stream this one.
        runOnUiThread { nfcEvents?.success(u) }
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

    /** Run [block] on the background print thread; deliver its result (or error)
     *  back on the UI thread, as Flutter requires for channel replies. */
    private fun <T> runAsync(result: MethodChannel.Result, block: () -> T) {
        printExecutor.execute {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (e: Throwable) {
                Log.e(TAG, "printer op failed", e)
                runOnUiThread {
                    result.error("PRINT_ERROR", e.message ?: e.toString(), null)
                }
            }
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

    private fun logoBitmap(): Bitmap? =
        runCatching { BitmapFactory.decodeResource(resources, R.drawable.receipt_logo) }.getOrNull()

    private fun printLogo(p: Printer) {
        logoBitmap()?.let {
            p.setPrintAppendBitmap(it, Layout.Alignment.ALIGN_CENTER)
            p.setPrintLine(30) // tiny blank margin below the logo
        }
    }

    private fun testPrint(): Int {
        if (!ensureInit()) throw RuntimeException("Impresora no disponible")
        val p = printer!!
        val status = p.getPrinterStatus()
        if (status == SdkResult.SDK_PRN_STATUS_PAPEROUT) return status
        printLogo(p)
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
        printLogo(p) // includes a tiny bottom margin

        // Market info: BTC price (right) + current block, then the date.
        val btcPrice = order["btcPrice"]?.toString().orEmpty()
        val blockNumber = order["blockNumber"]?.toString().orEmpty()
        if (btcPrice.isNotEmpty()) {
            p.setPrintAppendString(
                "BTC/USD $btcPrice", fmt(22, Layout.Alignment.ALIGN_OPPOSITE))
        }
        if (blockNumber.isNotEmpty()) {
            p.setPrintAppendString(
                "Bloque: #$blockNumber", fmt(22, Layout.Alignment.ALIGN_NORMAL))
        }
        p.setPrintAppendString(currentDate(), fmt(22, Layout.Alignment.ALIGN_NORMAL))
        p.setPrintAppendString("--------------------------------", normal)
        p.setPrintLine(1)

        // Line items: "name (price) x qty".
        val items = order["items"] as? List<*> ?: emptyList<Any>()
        for (it in items) {
            val m = it as? Map<*, *> ?: continue
            val name = m["name"]?.toString() ?: ""
            val qty = (m["qty"] as? Number)?.toInt() ?: 1
            val price = m["price"]?.toString() ?: ""
            p.setPrintAppendString("$name ($price) x $qty", normal)
            p.setPrintLine(1)
        }

        p.setPrintLine(6)
        p.setPrintAppendString("***** TOTAL *****", fmt(34, Layout.Alignment.ALIGN_CENTER))
        val currency = order["currency"]?.toString() ?: "ARS"
        val total = order["total"]?.toString() ?: "0"
        val currencyB = order["currencyB"]?.toString().orEmpty()
        val totalB = order["totalB"]?.toString().orEmpty()
        val totalSats = order["totalSats"]?.toString() ?: "0"
        if (currencyB.isNotEmpty() && totalB.isNotEmpty() && totalB != "-") {
            p.setPrintAppendString(
                "$currencyB $totalB", fmt(28, Layout.Alignment.ALIGN_CENTER))
        }
        p.setPrintAppendString("$currency $total", fmt(34, Layout.Alignment.ALIGN_CENTER))
        p.setPrintAppendString("$totalSats sats", fmt(24, Layout.Alignment.ALIGN_CENTER))
        p.setPrintAppendString("--------------------------------", normal)

        val message = order["message"]?.toString().orEmpty()
        if (message.isNotEmpty()) {
            p.setPrintLine(6)
            p.setPrintAppendString(message, fmt(26, Layout.Alignment.ALIGN_CENTER))
        }

        val qr = order["qrcode"]?.toString()
        if (!qr.isNullOrEmpty()) {
            p.setPrintLine(10)
            p.setPrintAppendQRCode(qr, 500, 500, Layout.Alignment.ALIGN_CENTER)
        }
        p.setPrintLine(40)
        return p.setPrintStart()
    }

    private fun currentDate(): String =
        java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.getDefault())
            .format(java.util.Date())

    companion object {
        private const val TAG = "PosPrinter"
        private const val STATUS_UNAVAILABLE = -100
        private const val STATUS_ERROR = -101
    }
}
