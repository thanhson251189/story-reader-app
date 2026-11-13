package dev.storyreader.story_reader

import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var volumePageTurn = false
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "story_reader/volume_keys"
        )
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    volumePageTurn = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Tiêu thụ phím âm lượng ngay ở tầng native để hệ thống không chỉnh tiếng,
    // rồi chuyển xuống Flutter lật trang. HardwareKeyboard của Flutter nhận
    // bất đồng bộ nên không chặn được hệ thống (ColorOS hiện hộp thoại volume).
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val isVolume = event.keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        if (volumePageTurn && isVolume) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                channel?.invokeMethod(
                    "volumeKey",
                    if (event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) "down" else "up"
                )
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}