package dev.storyreader.story_reader

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.KeyEvent
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
        val updater = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "story_reader/updater"
        )
        updater.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.arguments as? String
                    if (path == null) {
                        result.error("BAD_ARGS", "Thiếu đường dẫn APK", null)
                    } else {
                        try {
                            result.success(installApk(path))
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // Mở trình cài hệ thống cho APK đã tải về. targetSdk >= 24 bắt buộc dùng
    // FileProvider (content://) vì hệ thống chặn file:// giữa các app.
    // Trả về false khi thiếu quyền "cài ứng dụng không rõ nguồn" — đã mở sẵn
    // màn hình cấp quyền để người dùng bật rồi bấm Cài đặt lần nữa.
    private fun installApk(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("File APK không còn, hãy tải lại")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName")
                    )
                )
            } catch (_: Exception) {}
            return false
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return true
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