# Story Reader

App Android đọc/nghe truyện từ web truyện dịch (mục tiêu đầu tiên: truyendich.space). WebView thật tải trang như người dùng, inject JS bóc text chương, hiển thị trong giao diện đọc sạch; TTS tiếng Việt tự chuyển chương. Kế hoạch chi tiết: [Ke-Hoach-App-Doc-Truyen.md](Ke-Hoach-App-Doc-Truyen.md).

## Môi trường đã cài (máy này)

| Thành phần | Vị trí |
|---|---|
| Flutter SDK 3.47.9 (stable) | `D:\dev\flutter` |
| Android SDK (platform 36, build-tools 36.0.0) | `D:\Android\Sdk` |
| Android Studio 2026.2.2 + JBR | `C:\Program Files\Android\Android Studio` |

`PATH` user và `ANDROID_HOME` đã set; Flutter trỏ tới SDK/JBR qua `flutter config`. Mở terminal mới là dùng được `flutter`, `adb`.

## Chạy app

```bash
flutter run                # chạy trên điện thoại cắm USB (bật USB debugging)
flutter build apk --debug  # build APK debug
flutter doctor -v          # kiểm tra môi trường
```

## Cấu trúc hiện tại

Mới là khung Flutter mặc định (`lib/main.dart` — app đếm số mẫu). Cấu trúc lõi theo kế hoạch (core/adapters/fetcher/reader/tts/data) sẽ dựng từ Giai đoạn 1.