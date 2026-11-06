package ar.lawallet.lawallet_pos

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

/**
 * Tap-to-pay for phones: while the charge screen shows an invoice, the till
 * emulates an NFC Forum Type 4 tag holding `lightning:<bolt11>`, the convention
 * wallets (LaWallet, WoS, Zeus, Blink…) read in reader mode. MainActivity sets
 * [Type4Tag.ndefFile]; null answers "no such app", so a phone sees no tag.
 */
class InvoiceTagService : HostApduService() {
    override fun processCommandApdu(apdu: ByteArray, extras: Bundle?): ByteArray = Type4Tag.respond(apdu)
    override fun onDeactivated(reason: Int) = Type4Tag.reset()
}

/** The Type 4 Tag APDU state machine (NFC Forum T4T 2.0), JVM-testable. */
object Type4Tag {
    @Volatile var ndefFile: ByteArray? = null
    private var selected: ByteArray? = null // the file READ BINARY reads

    private val OK = byteArrayOf(0x90.toByte(), 0x00)
    private val NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())
    private val WRONG_P1P2 = byteArrayOf(0x6B, 0x00)
    private val NDEF_AID = hex("D2760000850101")
    private val CC_ID = hex("E103")
    private val NDEF_ID = hex("E104")
    private const val MAX_FILE = 0x7FFF

    /** The NDEF file: 2-byte length, then the message. */
    fun ndefFileOf(message: ByteArray): ByteArray =
        byteArrayOf((message.size shr 8).toByte(), message.size.toByte()) + message

    // Capability Container: version 2.0, MLe 0x00F6 (fits short APDUs), MLc 0x00F6,
    // one NDEF file control TLV — id E104, max size, read open, write never.
    private val CC = hex("000F2000F600F6") + hex("0406E104") +
        byteArrayOf((MAX_FILE shr 8).toByte(), MAX_FILE.toByte()) + hex("00FF")

    fun reset() { selected = null }

    fun respond(apdu: ByteArray): ByteArray {
        if (apdu.size < 4) return NOT_FOUND
        val ins = apdu[1].toInt() and 0xFF
        val p1 = apdu[2].toInt() and 0xFF
        return when (ins) {
            0xA4 -> select(apdu, p1)
            0xB0 -> read(apdu)
            else -> byteArrayOf(0x6D, 0x00) // INS not supported
        }
    }

    private fun select(apdu: ByteArray, p1: Int): ByteArray {
        val lc = if (apdu.size > 4) apdu[4].toInt() and 0xFF else 0
        if (apdu.size < 5 + lc) return NOT_FOUND
        val data = apdu.copyOfRange(5, 5 + lc)
        val file = ndefFile
        return when {
            p1 == 0x04 && data.contentEquals(NDEF_AID) -> if (file == null) NOT_FOUND else { selected = null; OK }
            p1 == 0x00 && data.contentEquals(CC_ID) -> { selected = CC; OK }
            p1 == 0x00 && data.contentEquals(NDEF_ID) && file != null -> { selected = file; OK }
            else -> NOT_FOUND
        }
    }

    private fun read(apdu: ByteArray): ByteArray {
        val file = selected ?: return NOT_FOUND
        val offset = ((apdu[2].toInt() and 0xFF) shl 8) or (apdu[3].toInt() and 0xFF)
        if (offset > file.size) return WRONG_P1P2
        val le = if (apdu.size > 4) apdu[4].toInt() and 0xFF else 0
        val len = minOf(if (le == 0) 256 else le, file.size - offset)
        return file.copyOfRange(offset, offset + len) + OK
    }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
