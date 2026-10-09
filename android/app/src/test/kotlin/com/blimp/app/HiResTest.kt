package com.blimp.app

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HiResTest {
    /** A FLAC file's start: "fLaC" and STREAMINFO for [rate] Hz at [bits] bits. */
    private fun flac(rate: Int, bits: Int): ByteArray {
        val info = ByteArray(34)
        info[10] = (rate ushr 12).toByte()
        info[11] = (rate ushr 4).toByte()
        // Rate's last 4 bits, 2 channels (1), and the top bit of bits - 1.
        info[12] = (((rate and 0xF) shl 4) or (1 shl 1) or ((bits - 1) ushr 4)).toByte()
        info[13] = (((bits - 1) and 0xF) shl 4).toByte()
        return "fLaC".toByteArray() + byteArrayOf(0, 0, 0, 34) + info
    }

    private fun le(n: Int, bytes: Int) = ByteArray(bytes) { (n ushr (8 * it)).toByte() }

    /** A WAV file's start, with a "LIST" chunk before "fmt " as some have. */
    private fun wav(rate: Int, bits: Int, format: Int = 1): ByteArray {
        val out = ByteArrayOutputStream()
        out.write("RIFF".toByteArray()); out.write(le(1000, 4)); out.write("WAVE".toByteArray())
        out.write("LIST".toByteArray()); out.write(le(3, 4)); out.write(byteArrayOf(1, 2, 3, 0))
        out.write("fmt ".toByteArray()); out.write(le(16, 4))
        out.write(le(format, 2)); out.write(le(2, 2)); out.write(le(rate, 4))
        out.write(le(rate * 2 * bits / 8, 4)); out.write(le(2 * bits / 8, 2)); out.write(le(bits, 2))
        return out.toByteArray()
    }

    private fun read(bytes: ByteArray) = HiRes.readHeader(ArrayByteSource(bytes))

    @Test
    fun readsFlacAndWavHeaders() {
        assertEquals(96000 to 24, read(flac(96000, 24)))
        assertEquals(44100 to 16, read(flac(44100, 16)))
        assertEquals(192000 to 24, read(wav(192000, 24)))
        assertEquals(48000 to 32, read(wav(48000, 32, format = 3)))
        assertNull(read("ID3".toByteArray() + ByteArray(40)))
    }

    @Test
    fun hiResIsBetterThanCd() {
        assertTrue(HiRes.isHiRes(96000, 24))
        assertTrue(HiRes.isHiRes(44100, 24))
        assertTrue(HiRes.isHiRes(88200, 16))
        assertFalse(HiRes.isHiRes(44100, 16))
        assertFalse(HiRes.isHiRes(48000, 16))
    }

    @Test
    fun onlyLosslessFormatsAreChecked() {
        assertTrue(HiRes.isCandidate("/storage/emulated/0/Music/a.FLAC"))
        assertTrue(HiRes.isCandidate("/storage/emulated/0/Music/a.m4a"))
        assertFalse(HiRes.isCandidate("/storage/emulated/0/Music/a.mp3"))
        assertFalse(HiRes.isCandidate(null))
    }
}
