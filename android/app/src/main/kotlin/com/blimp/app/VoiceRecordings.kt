package com.blimp.app

/**
 * Tells voice recordings and voice notes from music by where they're saved:
 * Android 12 and later mark recordings themselves, but older versions don't,
 * phone makers' recorder apps save to folders of their own, and messaging
 * apps' voice notes are only hidden from music apps while their folders
 * keep a .nomedia file, which cleaners and backups can lose.
 */
object VoiceRecordings {
    /**
     * Folders at the top of a storage volume that recorder apps save into:
     * Android's own, then Xiaomi's, Samsung's, OnePlus' and Oppo's, and call
     * recorders'. Their subfolders count too.
     */
    private val RECORDER_FOLDERS = listOf(
        "Recordings",
        "MIUI/sound_recorder",
        "Voice Recorder",
        "Sounds/Voice Recorder",
        "Record",
        "Recorder",
        "Call",
        "CallRecordings",
        "Call recordings",
    )

    /**
     * Folder names, anywhere in a path, that messaging apps keep voice notes
     * in: WhatsApp's and WhatsApp Business' ("WhatsApp Voice Notes",
     * "WhatsApp Business Voice Notes", and the same in modded versions) and
     * Telegram's. Not their audio folders, which hold songs people send.
     */
    private val VOICE_NOTE_FOLDER = Regex("(?i)^(?:.* voice notes|telegram voice)$")

    /** /storage/emulated/0/ on the phone, /storage/1A2B-3C4D/ on an SD card. */
    private val VOLUME_ROOT = Regex("^/storage/(?:emulated/\\d+|[^/]+)/")

    fun isRecording(path: String?): Boolean {
        if (path == null) return false
        val folders = path.split('/').dropLast(1)
        if (folders.any { VOICE_NOTE_FOLDER.matches(it) }) return true
        val root = VOLUME_ROOT.find(path) ?: return false
        val inVolume = path.substring(root.range.last + 1)
        return RECORDER_FOLDERS.any { inVolume.startsWith("$it/", ignoreCase = true) }
    }
}
