package com.blimp.app

/**
 * Whether a song is hi-res: lossless and better than CD quality (more than
 * 16 bits, or faster than 48 kHz), as stores label it, or DSD. Worked out
 * from the start of the file, so a whole library can be checked quickly.
 */
object HiRes {
    /** Formats that can be lossless; anything else (MP3, AAC, Opus...) never is hi-res. */
    val CANDIDATE_EXTENSIONS = setOf("flac", "wav", "wave", "aif", "aiff", "aifc", "m4a", "alac", "dsf", "dff", "wv", "ape")

    fun isCandidate(path: String?): Boolean =
        path?.substringAfterLast('.', "")?.lowercase() in CANDIDATE_EXTENSIONS

    /** Sample rate and bit depth from a FLAC or WAV header; null for other files. */
    fun readHeader(source: ByteSource): Pair<Int, Int>? {
        val head = source.read(0, 64)
        if (head.size < 12) return null
        val magic = String(head, 0, 4, Charsets.ISO_8859_1)
        return when {
            magic == "fLaC" -> flac(head)
            magic == "RIFF" && String(head, 8, 4, Charsets.ISO_8859_1) == "WAVE" -> wav(source)
            else -> null
        }
    }

    fun isHiRes(sampleRate: Int, bitsPerSample: Int) = bitsPerSample > 16 || sampleRate > 48000

    /**
     * STREAMINFO is always the first block: after "fLaC" and a 4-byte block
     * header come 10 bytes of block and frame sizes, then 20 bits of sample
     * rate, 3 of channels - 1 and 5 of bits per sample - 1.
     */
    private fun flac(head: ByteArray): Pair<Int, Int>? {
        if (head.size < 22 || head[4].toInt() and 0x7F != 0) return null
        val b = { i: Int -> head[i].toInt() and 0xFF }
        val sampleRate = (b(18) shl 12) or (b(19) shl 4) or (b(20) ushr 4)
        val bits = (((b(20) and 0x01) shl 4) or (b(21) ushr 4)) + 1
        return if (sampleRate > 0) sampleRate to bits else null
    }

    /** The "fmt " chunk: its sample rate at 4 and bits per sample at 14. */
    private fun wav(source: ByteSource): Pair<Int, Int>? {
        var pos = 12L
        while (pos + 8 <= minOf(source.size, 1L shl 20)) {
            val header = source.read(pos, 8)
            if (header.size < 8) return null
            val size = le32(header, 4).toLong() and 0xFFFFFFFFL
            if (String(header, 0, 4, Charsets.ISO_8859_1) == "fmt ") {
                val fmt = source.read(pos + 8, 16)
                if (fmt.size < 16) return null
                val format = le16(fmt, 0)
                // 3 is floating point: 32-bit, so hi-res whatever the rate.
                val bits = if (format == 3) 32 else le16(fmt, 14)
                return le32(fmt, 4) to bits
            }
            pos += 8 + size + (size and 1)
        }
        return null
    }

    private fun le16(b: ByteArray, at: Int) = (b[at].toInt() and 0xFF) or (b[at + 1].toInt() and 0xFF shl 8)

    private fun le32(b: ByteArray, at: Int) =
        (b[at].toInt() and 0xFF) or (b[at + 1].toInt() and 0xFF shl 8) or
            (b[at + 2].toInt() and 0xFF shl 16) or (b[at + 3].toInt() and 0xFF shl 24)
}
