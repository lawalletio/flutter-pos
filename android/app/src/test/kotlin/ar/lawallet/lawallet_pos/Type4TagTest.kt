package ar.lawallet.lawallet_pos

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/** Walks the read sequence Android's Ndef tech sends a Type 4 tag. */
class Type4TagTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun sw(r: ByteArray) = "%02X%02X".format(r[r.size - 2], r[r.size - 1])

    @Test fun servesNdefFileAndHidesWithoutInvoice() {
        Type4Tag.ndefFile = null
        assertEquals("6A82", sw(Type4Tag.respond(hex("00A4040007D276000085010100"))))

        val msg = "lightning:lnbc1test".toByteArray()
        Type4Tag.ndefFile = Type4Tag.ndefFileOf(msg)
        Type4Tag.reset()
        assertEquals("9000", sw(Type4Tag.respond(hex("00A4040007D276000085010100"))))
        assertEquals("9000", sw(Type4Tag.respond(hex("00A4000C02E103"))))
        val cc = Type4Tag.respond(hex("00B000000F"))
        assertEquals(17, cc.size)
        assertArrayEquals(hex("E104"), cc.copyOfRange(9, 11))
        assertEquals("9000", sw(Type4Tag.respond(hex("00A4000C02E104"))))
        val nlen = Type4Tag.respond(hex("00B0000002"))
        assertEquals(msg.size, ((nlen[0].toInt() and 0xFF) shl 8) or (nlen[1].toInt() and 0xFF))
        val body = Type4Tag.respond(hex("00B00002" + "%02X".format(msg.size)))
        assertArrayEquals(msg, body.copyOfRange(0, body.size - 2))
        assertEquals("6B00", sw(Type4Tag.respond(hex("00B0FFFF01"))))
        Type4Tag.ndefFile = null
    }
}
