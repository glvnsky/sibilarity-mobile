package com.example.music_remote_app

import android.content.Context
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private lateinit var audioManager: AudioManager
    private var volumeObserver: ContentObserver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        volumeControlStream = AudioManager.STREAM_MUSIC

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "music_remote_app/system_volume",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getVolumePercent" -> result.success(currentVolumePercent())
                "setVolumePercent" -> {
                    val rawValue = call.argument<Number>("value")?.toDouble()
                    if (rawValue == null) {
                        result.error("invalid_args", "Missing volume value", null)
                    } else {
                        result.success(setVolumePercent(rawValue))
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "music_remote_app/system_volume/events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                    override fun onChange(selfChange: Boolean) {
                        super.onChange(selfChange)
                        events.success(currentVolumePercent())
                    }
                }
                volumeObserver = observer
                contentResolver.registerContentObserver(
                    Settings.System.CONTENT_URI,
                    true,
                    observer,
                )
                events.success(currentVolumePercent())
            }

            override fun onCancel(arguments: Any?) {
                volumeObserver?.let { contentResolver.unregisterContentObserver(it) }
                volumeObserver = null
            }
        })
    }

    private fun currentVolumePercent(): Double {
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC).coerceIn(0, maxVolume)
        return (currentVolume.toDouble() / maxVolume.toDouble()) * 100.0
    }

    private fun setVolumePercent(percent: Double): Double {
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val clampedPercent = percent.coerceIn(0.0, 100.0)
        val targetVolume = ((clampedPercent / 100.0) * maxVolume.toDouble()).roundToInt()
            .coerceIn(0, maxVolume)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, targetVolume, 0)
        return currentVolumePercent()
    }
}
