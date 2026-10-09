package com.blimp.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceRecordingsTest {
    @Test
    fun recorderFoldersAreRecordings() {
        assertTrue(VoiceRecordings.isRecording("/storage/emulated/0/Recordings/Meeting.m4a"))
        assertTrue(VoiceRecordings.isRecording("/storage/emulated/0/MIUI/sound_recorder/call_rec/Mum.mp3"))
        assertTrue(VoiceRecordings.isRecording("/storage/emulated/0/Sounds/Voice Recorder/Note 1.m4a"))
        assertTrue(VoiceRecordings.isRecording("/storage/1A2B-3C4D/recordings/Lecture.mp3"))
    }

    @Test
    fun messagingVoiceNotesAreRecordings() {
        assertTrue(VoiceRecordings.isRecording(
            "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Voice Notes/202641/PTT-20261008-WA0003.opus"))
        assertTrue(VoiceRecordings.isRecording(
            "/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Voice Notes/202641/PTT-1.opus"))
        assertTrue(VoiceRecordings.isRecording("/storage/emulated/0/WhatsApp/Media/WhatsApp Voice Notes/PTT-2.opus"))
        assertTrue(VoiceRecordings.isRecording("/storage/emulated/0/Telegram/Telegram Voice/123.ogg"))
    }

    @Test
    fun musicIsNot() {
        assertFalse(VoiceRecordings.isRecording("/storage/emulated/0/Music/Recordings/Live.mp3"))
        assertFalse(VoiceRecordings.isRecording("/storage/emulated/0/Records/Album/01.flac"))
        assertFalse(VoiceRecordings.isRecording("/storage/emulated/0/Download/Song.mp3"))
        // Songs people send stay.
        assertFalse(VoiceRecordings.isRecording(
            "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Audio/AUD-20261008-WA0001.mp3"))
        assertFalse(VoiceRecordings.isRecording("/storage/emulated/0/Telegram/Telegram Audio/song.mp3"))
        // A song named like a voice note folder isn't one.
        assertFalse(VoiceRecordings.isRecording("/storage/emulated/0/Music/Voice Notes.mp3"))
        assertFalse(VoiceRecordings.isRecording(null))
    }
}
