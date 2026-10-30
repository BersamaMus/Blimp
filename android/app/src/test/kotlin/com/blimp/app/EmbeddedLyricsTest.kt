package com.blimp.app

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class EmbeddedLyricsTest {
    private fun bytes(vararg parts: Any): ByteArray {
        val out = ByteArrayOutputStream()
        for (part in parts) {
            when (part) {
                is String -> out.write(part.toByteArray(Charsets.ISO_8859_1))
                is ByteArray -> out.write(part)
                is Int -> out.write(part)
            }
        }
        return out.toByteArray()
    }

    private fun be32(n: Int) = byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte())
    private fun le32(n: Int) = byteArrayOf(n.toByte(), (n ushr 8).toByte(), (n ushr 16).toByte(), (n ushr 24).toByte())
    private fun syncsafe(n: Int) =
        byteArrayOf((n shr 21 and 0x7F).toByte(), (n shr 14 and 0x7F).toByte(), (n shr 7 and 0x7F).toByte(), (n and 0x7F).toByte())

    private fun read(file: ByteArray) = EmbeddedLyrics.read(ArrayByteSource(file))

    private fun id3(version: Int, vararg frames: ByteArray): ByteArray {
        val body = bytes(*frames)
        return bytes("ID3", version, 0, 0, syncsafe(body.size), body, "audio data")
    }

    private fun frame(version: Int, id: String, data: ByteArray) =
        bytes(id, if (version == 4) syncsafe(data.size) else be32(data.size), 0, 0, data)

    @Test
    fun readsUsltInUtf16FromId3v23() {
        val text = "[00:01.00]Hello\n[00:02.00]Wörld"
        val uslt = bytes(1, "eng", byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0, 0), text.toByteArray(Charsets.UTF_16))
        val file = id3(3, frame(3, "TIT2", bytes(0, "Title")), frame(3, "USLT", uslt))
        assertEquals(text, read(file))
    }

    @Test
    fun readsUsltInUtf8FromId3v24() {
        val uslt = bytes(3, "eng", "desc", 0, "Línea uno".toByteArray(Charsets.UTF_8))
        assertEquals("Línea uno", read(id3(4, frame(4, "USLT", uslt))))
    }

    @Test
    fun readsLyricsFromTxxx() {
        val txxx = bytes(3, "LYRICS", 0, "From TXXX".toByteArray(Charsets.UTF_8))
        assertEquals("From TXXX", read(id3(3, frame(3, "TXXX", txxx))))
    }

    private fun readStrict(file: ByteArray) = EmbeddedLyrics.readStrict(ArrayByteSource(file))

    @Test
    fun strictReadFindsLyricsAndNone() {
        val uslt = bytes(0, "eng", 0, "Words")
        assertEquals("Words", readStrict(id3(3, frame(3, "USLT", uslt))))
        assertNull(readStrict(id3(3, frame(3, "TIT2", bytes(0, "Title")))))
    }

    @Test
    fun strictReadThrowsOnDamagedTag() {
        val good = frame(3, "TIT2", bytes(0, "Title"))
        val tooLong = bytes("USLT", be32(5000), 0, 0, 0, "eng", 0, "Words")
        val file = id3(3, good, tooLong)
        assertNull(read(file))
        assertThrows(IllegalStateException::class.java) { readStrict(file) }
    }

    @Test
    fun strictReadThrowsOnCompressedLyrics() {
        val compressed = bytes("USLT", be32(9), 0, 0x80, 0, "eng", 0, "Words")
        val file = id3(3, compressed)
        assertNull(read(file))
        assertThrows(IllegalStateException::class.java) { readStrict(file) }
    }

    @Test
    fun strictReadThrowsOnCompressedUserText() {
        val compressed = bytes("TXXX", be32(10), 0, 0x80, 0, "LYRICS", 0, "W")
        assertThrows(IllegalStateException::class.java) { readStrict(id3(3, compressed)) }
    }

    @Test
    fun v24TagsWithPlainSizesAreRead() {
        // A cover over 127 bytes: its plain size isn't valid read as syncsafe.
        val cover = bytes(0, "image/png", 0, 3, 0, ByteArray(300) { 7 })
        val file = id3(4, frame(3, "APIC", cover), frame(3, "USLT", bytes(3, "eng", 0, "Words")))
        assertEquals("Words", read(file))
        assertEquals("Words", readStrict(file))
    }

    @Test
    fun strictReadThrowsOnFramesNeitherWayFits() {
        val file = id3(3, frame(3, "TIT2", bytes(0, "Title")), frame(3, "bad!", bytes(0, "x")))
        assertThrows(IllegalStateException::class.java) { readStrict(file) }
    }

    @Test
    fun emptyFramesAreSkipped() {
        val file = id3(3, frame(3, "TCOM", ByteArray(0)), frame(3, "USLT", bytes(0, "eng", 0, "Words")))
        assertEquals("Words", read(file))
        assertEquals("Words", readStrict(file))
    }

    @Test
    fun noLyricsInId3IsNull() {
        assertNull(read(id3(3, frame(3, "TIT2", bytes(0, "Title")))))
    }

    private fun vorbisComments(vararg comments: String): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(le32(6)); out.write("vendor".toByteArray())
        out.write(le32(comments.size))
        for (c in comments) {
            val b = c.toByteArray(Charsets.UTF_8)
            out.write(le32(b.size)); out.write(b)
        }
        return out.toByteArray()
    }

    @Test
    fun readsFlacVorbisComment() {
        val streamInfo = ByteArray(34)
        val comments = vorbisComments("TITLE=x", "lyrics=Flac words")
        val file = bytes(
            "fLaC",
            0, 0, 0, 34, streamInfo,
            0x84, 0, (comments.size shr 8) and 0xFF, comments.size and 0xFF, comments,
        )
        assertEquals("Flac words", read(file))
    }

    private fun oggPage(granule: Long, payload: ByteArray): ByteArray {
        val segments = mutableListOf<Int>()
        var left = payload.size
        while (left >= 255) { segments.add(255); left -= 255 }
        segments.add(left)
        val out = ByteArrayOutputStream()
        out.write("OggS".toByteArray()); out.write(0); out.write(0)
        for (i in 0 until 8) out.write((granule shr (8 * i)).toInt() and 0xFF)
        out.write(ByteArray(12)); out.write(segments.size)
        for (s in segments) out.write(s)
        out.write(payload)
        return out.toByteArray()
    }

    @Test
    fun readsOpusTagsSpanningPages() {
        val comments = bytes("OpusTags", vorbisComments("ARTIST=y", "UNSYNCEDLYRICS=" + "la ".repeat(200).trim()))
        val half = comments.size / 2
        val file = bytes(
            oggPage(0, bytes("OpusHead", ByteArray(11))),
            oggPage(0, comments.copyOfRange(0, half)),
            oggPage(0, comments.copyOfRange(half, comments.size)),
            oggPage(960, ByteArray(20)),
        )
        assertEquals("la ".repeat(200).trim(), read(file))
    }

    private fun atom(type: String, vararg content: ByteArray): ByteArray {
        val body = bytes(*content)
        return bytes(be32(body.size + 8), type, body)
    }

    @Test
    fun readsMp4Lyrics() {
        val data = atom("data", be32(1), be32(0), "M4A words".toByteArray(Charsets.UTF_8))
        val ilst = atom("ilst", atom("©nam", atom("data", be32(1), be32(0), "T".toByteArray())), atom("©lyr", data))
        val meta = atom("meta", be32(0), atom("hdlr", ByteArray(25)), ilst)
        val file = bytes(atom("ftyp", "M4A ".toByteArray()), atom("mdat", ByteArray(100)), atom("moov", atom("udta", meta)))
        assertEquals("M4A words", read(file))
    }

    @Test
    fun otherFilesAndDamagedTagsAreNull() {
        assertNull(read("RIFF....WAVEfmt ".toByteArray()))
        assertNull(read(bytes("ID3", 3, 0, 0, syncsafe(1000), "USLT")))
    }

    @Test
    fun readsReplayGainFromId3AndVorbisComments() {
        val txxx = bytes(0, "REPLAYGAIN_TRACK_GAIN", 0, "-7.25 dB")
        assertEquals(-7.25, EmbeddedLyrics.readTags(ArrayByteSource(id3(3, frame(3, "TXXX", txxx)))).trackGain!!, 1e-9)

        val comments = vorbisComments("replaygain_track_gain=+2.10 dB", "LYRICS=words")
        val flac = bytes("fLaC", 0x84, 0, (comments.size shr 8) and 0xFF, comments.size and 0xFF, comments)
        val tags = EmbeddedLyrics.readTags(ArrayByteSource(flac))
        assertEquals(2.10, tags.trackGain!!, 1e-9)
        assertEquals("words", tags.lyrics)
    }

    @Test
    fun readsReleaseTypeFromId3AndVorbisComments() {
        val picard = bytes(0, "MusicBrainz Album Type", 0, "single")
        assertEquals("single", EmbeddedLyrics.readTags(ArrayByteSource(id3(4, frame(4, "TXXX", picard)))).releaseType)

        val comments = vorbisComments("RELEASETYPE=album; compilation")
        val flac = bytes("fLaC", 0x84, 0, (comments.size shr 8) and 0xFF, comments.size and 0xFF, comments)
        assertEquals("album", EmbeddedLyrics.readTags(ArrayByteSource(flac)).releaseType)
    }

    @Test
    fun releaseTypesOtherThanAlbumEpAndSingleAreNull() {
        assertEquals("ep", EmbeddedLyrics.parseReleaseType(" EP "))
        assertEquals("album", EmbeddedLyrics.parseReleaseType("Album/Live"))
        assertNull(EmbeddedLyrics.parseReleaseType("broadcast"))
        assertNull(EmbeddedLyrics.parseReleaseType(""))
        assertNull(EmbeddedLyrics.parseReleaseType(null))
    }
}
