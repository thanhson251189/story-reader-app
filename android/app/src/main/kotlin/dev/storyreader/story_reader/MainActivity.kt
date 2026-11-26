package dev.storyreader.story_reader

import android.content.ClipData
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
                "canInstallApks" -> result.success(canInstallApks())
                "openInstallPermissionSettings" -> {
                    result.success(openInstallPermissionSettings())
                }
                "shareFile" -> {
                    val path = call.arguments as? String
                    if (path == null) {
                        result.error("BAD_ARGS", "Thiếu đường dẫn file", null)
                    } else {
                        try {
                            result.success(shareFile(path))
                        } catch (e: Exception) {
                            result.error("SHARE_ERROR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // Đủ quyền "cài ứng dụng không rõ nguồn" chưa? Android < 8 không cần.
    private fun canInstallApks(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    // Mở màn hình hệ thống cấp quyền cài ứng dụng không rõ nguồn cho app.
    // false = máy không có màn đó hoặc không mở được — người dùng phải thấy
    // câu báo, không được im lặng.
    private fun openInstallPermissionSettings(): Boolean {
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            )
            true
        } catch (_: Exception) {
            false
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
        if (!canInstallApks()) {
            openInstallPermissionSettings()
            return false
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        // ACTION_INSTALL_PACKAGE deprecated từ API 29; ACTION_VIEW + MIME APK
        // vẫn mở đúng trình cài hệ thống trên mọi bản Android.
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return true
    }

    // File phải nằm trong đường dẫn FileProvider (cache/backup). Bảng chia sẻ
    // là cách người dùng gửi file sang máy khác mà không phải lần trong
    // trình chọn thư mục.
    private fun shareFile(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("File không còn, hãy sao lưu lại")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "application/json"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("backup", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(send, "Chia sẻ file sao lưu"))
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