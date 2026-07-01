package ar.lawallet.lawallet_pos

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
