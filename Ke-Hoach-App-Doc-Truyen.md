# Kế hoạch app đọc/nghe truyện (Flutter, Android)

> File này dùng để lưu lại và dán cho AI mỗi lần làm việc. Làm từng giai đoạn nhỏ, giai đoạn nào chạy được rồi mới sang giai đoạn sau.

## 1. Mục tiêu

App Android cho phép đọc và nghe truyện từ các web truyện dịch (bắt đầu với `truyendich.space`):

- Mở truyện, đọc chương trong giao diện sạch (chỉnh cỡ chữ, nền tối, không quảng cáo).
- Nghe bằng TTS tiếng Việt, hết chương tự sang chương sau.
- Lưu vị trí đọc, cache chương đã đọc để đọc lại không cần mạng.
- Danh sách nguồn hỗ trợ tự cập nhật: có nguồn mới thì hiện trong app.
- Tự kiểm tra phiên bản app mới.

**Lộ trình sử dụng:** dùng cá nhân trước, nếu ổn thì phát hành sau. Vì vậy thiết kế phải tách lõi và nguồn truyện ngay từ đầu.

## 2. Công nghệ

| Việc | Dùng |
|---|---|
| Ngôn ngữ / khung | Flutter (Dart), chỉ build Android |
| Lấy nội dung (vượt chặn bot) | `flutter_inappwebview` (WebView thật, có `HeadlessInAppWebView` để tải ngầm) |
| Đọc thành tiếng | `flutter_tts` |
| Nghe khi tắt màn hình | `audio_service` + `wakelock_plus` |
| Lưu dữ liệu cục bộ | `sqflite` (SQLite) |
| Quản lý trạng thái | Riverpod |
| Đọc số phiên bản app | `package_info_plus` |
| Mở link / cài bản cập nhật | `url_launcher` hoặc `ota_update` |

**Vì sao không dùng Rust:** không biết lập trình và nhờ AI viết code nên cần ngôn ngữ AI viết ổn định, lỗi dễ đọc, có sẵn thư viện WebView/TTS. Flutter đáp ứng, còn Rust phải viết thêm lớp keo Kotlin/Swift cho WebView và TTS. Chỗ tốn tài nguyên nhất là WebView, không phải code của app, nên đổi ngôn ngữ không làm app nhẹ hơn đáng kể.

## 3. Ý tưởng cốt lõi: WebView trên máy người dùng

Web chặn bot thường chặn theo Cloudflare/JS challenge, user-agent, rate limit theo IP. Cách bền nhất là **không scrape từ server**, mà dùng WebView ngay trên điện thoại:

1. App mở trang bằng WebView thật (có cookie, JS, fingerprint trình duyệt thật) nên qua được kiểm tra như người đọc bình thường.
2. Trang load xong thì inject JS để lấy text chương, link chương trước/sau theo CSS selector.
3. Hiển thị lại trong giao diện đọc của app.
4. Sang chương: lấy link chương kế, tải ngầm bằng WebView ẩn.

## 4. Kiến trúc thư mục

```
lib/
  core/            # model chung: Novel, Chapter, ChapterContent
  adapters/        # đọc file cấu hình của từng nguồn
  fetcher/         # WebView: tải trang, chạy JS, trả text
  reader/          # màn hình đọc, cỡ chữ, nền sáng/tối
  tts/             # chia câu, đọc, highlight, hẹn giờ
  data/            # SQLite: truyện, chương cache, vị trí đọc
  sources/registry/# tải index nguồn, cài/cập nhật nguồn
  updater/         # kiểm tra phiên bản app
```

**Quy tắc sống còn:** lõi (reader, tts, data, fetcher) không được chứa chữ `truyendich` ở bất kỳ đâu. Mọi thứ riêng của từng site nằm trong adapter. Adapter chỉ trả về ba thứ: danh sách chương, nội dung chương, link chương kế.

### Mẫu file adapter (chỉ chứa dữ liệu, không chứa code chạy)

```json
{
  "id": "truyendich",
  "domain": "truyendich.space",
  "version": 1,
  "selectors": {
    "title": "...",
    "content": "...",
    "nextLink": "...",
    "prevLink": "...",
    "chapterList": "..."
  },
  "removeSelectors": ["...quảng cáo..."],
  "textCleanup": ["...regex xoá dòng rác..."]
}
```

Các dấu `...` điền sau khi có HTML thật của trang (chuột phải, Inspect, copy phần chứa nội dung và nút chương sau, dán cho AI).

## 5. Các giai đoạn

### Giai đoạn 0: Cài môi trường
- Cài Flutter SDK và Android Studio.
- Bật Developer options + USB debugging trên điện thoại.
- Chạy `flutter create` và chạy app mẫu trên điện thoại thật qua cáp USB.
- **Xong khi:** app mẫu hiện trên điện thoại thật.

### Giai đoạn 1: Lấy được chữ
- Màn hình có ô nhập link chương và nút "Mở".
- Mở link bằng WebView, đợi `onLoadStop`, chạy JS lấy text theo selector, in ra màn hình.
- **Xong khi:** dán link một chương là thấy đúng nội dung chương, không quảng cáo.
- Việc của mày: gửi HTML trang chương cho AI để viết selector.

### Giai đoạn 2: Đọc và chuyển chương
- Màn hình đọc: cỡ chữ, giãn dòng, nền sáng/tối/vàng.
- Nút chương trước/sau, lấy link từ selector `nextLink` / `prevLink`.
- Lưu vị trí đọc (link chương + đoạn thứ mấy) vào SQLite, mở lại app là đọc tiếp.
- **Xong khi:** bấm "chương sau" liên tục được 10 chương.

### Giai đoạn 3: Nghe truyện
- Chia text thành câu, gom thành đoạn dưới khoảng 3000 ký tự (Android giới hạn độ dài mỗi lần đọc).
- Đặt ngôn ngữ `vi-VN`, chỉnh tốc độ, highlight câu đang đọc.
- Đọc xong câu cuối thì tự tải chương sau và đọc tiếp.
- **Xong khi:** để điện thoại nghe liền 5 chương không chạm vào.

### Giai đoạn 4: Nghe khi tắt màn hình
- Chạy TTS trong foreground service với notification điều khiển (play/pause/chương sau). Android mới yêu cầu khai báo loại service là media playback trong manifest.
- Thêm hẹn giờ tắt (15/30/60 phút).
- **Xong khi:** khoá màn hình mà vẫn nghe được, notification bấm tạm dừng được.

### Giai đoạn 5: Cache và mục lục
- Lưu text chương đã đọc vào SQLite để đọc lại không cần mạng.
- "Tải trước N chương" (giải pháp cho nhu cầu tải truyện ban đầu).
- Prefetch đúng một chương kế tiếp khi đọc tới giữa chương.
- Màn hình danh sách chương, thư viện truyện đang đọc.
- **Xong khi:** tắt mạng vẫn đọc được các chương đã tải.

### Giai đoạn 6: Tách adapter ra ngoài và danh sách nguồn
- Chuyển adapter thành file JSON để ngoài, đọc qua `sources/registry`.
- Viết cơ chế tải `index.json`, cài và cập nhật nguồn (xem mục 6).
- Thêm site thứ hai chỉ bằng cách viết thêm file adapter. Nếu phải sửa lõi thì quay lại tách cho sạch.
- **Xong khi:** thêm một nguồn mới chỉ bằng cách sửa `index.json` trên GitHub rồi bấm "Làm mới" trong app là thấy nguồn mới xuất hiện và đọc được.

### Giai đoạn 7: Kiểm tra cập nhật app
- Xem mục 7.
- **Xong khi:** tạo Release `1.0.1` trên GitHub, app đang chạy bản `1.0.0` hiện thông báo cập nhật, bấm vào cài được.

## 6. Danh sách nguồn hỗ trợ tự cập nhật

Danh sách nguồn không nằm cứng trong app mà là file `index.json` để ngoài, app tải về mỗi lần mở.

**Chỗ đặt:** trong repo GitHub, thư mục `sources/`, app đọc qua link raw (miễn phí, có lịch sử sửa).

```
sources/
  index.json
  truyendich.json
  nguon-moi.json
```

`index.json`:

```json
{
  "schema": 1,
  "sources": [
    {
      "id": "truyendich",
      "name": "TruyenDich",
      "domain": "truyendich.space",
      "version": 3,
      "minAppVersion": "1.0.0",
      "url": "https://raw.githubusercontent.com/<user>/<repo>/main/sources/truyendich.json"
    }
  ]
}
```

**Cách app dùng:**

1. Mở app, tải `index.json` (có timeout và cache, mất mạng thì dùng bản đã lưu).
2. Màn hình "Nguồn truyện" liệt kê tất cả nguồn trong index.
3. Nguồn chưa cài có nhãn **"Mới"** và nút "Thêm": bấm thì tải adapter về, lưu cục bộ.
4. Nguồn đã cài mà `version` trong index cao hơn bản đang giữ thì hiện nhãn **"Có bản cập nhật"** (site đổi HTML thì sửa selector một lần, mọi máy tự nhận).
5. `minAppVersion`: adapter đòi tính năng mới hơn app đang có thì báo "cần cập nhật app trước".

**An toàn:** adapter chỉ chứa dữ liệu (selector, regex), không chứa code chạy. Nếu sau này cho adapter chứa JS thì chỉ chạy với index do chính mày kiểm soát.

## 7. Kiểm tra cập nhật app

**Bản dùng cá nhân (không qua Play Store):**

1. Tạo repo GitHub cho app. Mỗi bản mới tạo một **Release**, đính kèm file APK, ghi số phiên bản (ví dụ `1.2.0`) và nội dung thay đổi.
2. Khi mở app (hoặc bấm "Kiểm tra cập nhật" trong cài đặt), gọi API `releases/latest` của GitHub, lấy số phiên bản mới nhất.
3. So với phiên bản đang chạy (đọc bằng `package_info_plus`). Mới hơn thì hiện hộp thoại: số phiên bản, changelog, nút "Cập nhật".
4. Bấm cập nhật thì tải APK và mở trình cài đặt (`ota_update`, hoặc đơn giản hơn là mở link tải bằng `url_launcher`). Lần đầu Android sẽ hỏi bật quyền cài ứng dụng từ nguồn này.

**Lưu ý quan trọng:**
- APK phải **ký bằng cùng một khoá** mỗi lần. Khác khoá thì Android từ chối cài đè, phải gỡ app cũ và mất dữ liệu. Tạo khoá một lần, sao lưu cẩn thận, đừng làm mất.
- `versionCode` trong `pubspec.yaml` phải tăng mỗi bản.

**Nếu sau này lên Google Play:** bỏ cách trên, dùng gói `in_app_update` để Google lo việc cập nhật.

## 8. Chuyện bị chặn bot

- `HeadlessInAppWebView` thường vượt được kiểm tra JS thông thường vì là trình duyệt thật.
- Nếu site hiện challenge cần tương tác (kiểu tích "tôi không phải robot"), app mở WebView hiện hẳn lên một lần để bấm qua, sau đó cookie được giữ lại và các lần sau chạy ngầm tiếp.
- Đừng tải dồn dập. Mỗi lần một chương, có cache, vừa ít bị chặn vừa tử tế với site.
- Giữ app nhẹ: dùng WebView chỉ để lấy text chương rồi hủy ngay, phần đọc hiển thị bằng widget native; khi đang nghe mà tắt màn hình thì đừng giữ WebView sống.

## 9. Rủi ro cần nhớ

1. **Bản quyền:** nội dung truyện dịch có thể chưa được phép đăng. Dùng cá nhân thường chấp nhận được, nhưng nếu có server lưu và phân phối lại nội dung thì rủi ro lớn.
2. **Điều khoản site:** app bỏ quảng cáo có thể khiến site đổi giao diện hoặc chặn thêm.
3. **Phát hành lên store:** app kiểu này dễ bị gỡ khỏi Google Play/App Store.
4. **Bảo trì:** site đổi HTML thì adapter hỏng, nên adapter phải là config để sửa nhanh.

## 10. Khi muốn phát hành

- Bản phát hành để app **trống**, người dùng tự nhập nguồn. Bản của mày mới cài sẵn adapter.
- **Địa chỉ index là một ô cài đặt:** bản của mày mặc định trỏ tới index của mày; bản phát hành để trống, người dùng tự dán link index mình tin tưởng.
- Mọi dữ liệu nằm trên máy người dùng, mày không có server lưu hay phân phối truyện.
- Nếu làm đồng bộ giữa các máy thì chỉ đồng bộ tiến độ đọc, không đồng bộ nội dung.

## 11. Cách làm việc với AI

Dán đoạn này vào đầu mỗi phiên làm việc:

```
Tôi đang làm app đọc/nghe truyện bằng Flutter, chỉ Android.
Cấu trúc thư mục hiện tại: [dán cây thư mục].
Đang ở giai đoạn [số]. Mục tiêu giai đoạn: [copy dòng "Xong khi" của giai đoạn đó].
Chỉ viết đúng phần của giai đoạn này, giải thích cách chạy và cách kiểm tra.
Không đổi cấu trúc hiện có. Lõi không được chứa tên site cụ thể.
```

Nguyên tắc:

- Mỗi lần app chạy được thì `git commit`. Khi AI sửa hỏng thì quay lại bản cũ.
- Có lỗi thì dán **nguyên văn** thông báo lỗi và file liên quan, đừng tóm tắt.
- Mỗi lần chỉ nhờ một việc nhỏ. Đừng bảo "viết cả app".
- AI đề xuất thêm thư viện lạ thì hỏi vì sao cần trước khi cài.
- Có thể dùng Claude Code để AI tự đọc, sửa file và chạy lệnh trong thư mục dự án; mày mô tả và kiểm tra kết quả trên điện thoại.

## 12. Việc cần làm ngay

1. Cài Flutter và Android Studio, chạy app mẫu trên điện thoại (giai đoạn 0).
2. Mở một trang chương trên `truyendich.space`, Inspect, copy HTML phần nội dung và nút chương sau.
3. Gửi HTML cho AI để viết adapter đầu tiên (giai đoạn 1).
