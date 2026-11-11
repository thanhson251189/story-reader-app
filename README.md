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

```
lib/
  core/       # model chung + Riverpod providers (override trong main)
  adapters/   # AdapterRepository: domain → adapter, nạp từ registry
  fetcher/    # HeadlessInAppWebView tải trang + inject JS bóc text; WebView fallback
  reader/     # màn hình đọc, mục lục, cỡ chữ/nền, highlight câu đang đọc
  tts/        # chia câu, synthesizeToFile + just_audio, foreground service (audio_service)
  data/       # SQLite: vị trí đọc, cache chương, thư viện, mục lục, settings
  sources/    # registry index.json ngoài GitHub, cài/cập nhật adapter
  local/      # nhập sách EPUB/MOBI/FB2/TXT có sẵn trong máy
  update/     # kiểm tra bản mới qua GitHub Release
```

Adapter không đóng gói trong APK; nguồn truyện cài qua màn "Nguồn truyện" (registry). Bản cá nhân build với `--dart-define=PERSONAL=true` để có sẵn link index mặc định.