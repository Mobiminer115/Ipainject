# IPA Payload Lab

IPA Payload Lab là ứng dụng SwiftUI chạy trên iPhone/iPad để nhúng một `dylib`, `framework` hoặc payload lấy từ `deb` vào **bản sao IPA do người dùng tự chọn**. Ứng dụng không truy cập hay sửa app đang cài, không vượt sandbox và không né cơ chế code-signing của iOS.

## Chức năng

- Nhập IPA từ Files, kiểm tra ZIP path traversal, số entry và kích thước giải nén trước khi xử lý.
- Tự tìm executable chính và executable của các app extension (`.appex`) để người dùng chọn.
- Nhận `dylib`, thư mục `.framework`, hoặc `deb` chứa `data.tar`, `data.tar.gz`, `data.tar.xz`.
- Chọn vị trí nhúng: cạnh executable hoặc trong `Frameworks` của đúng bundle đích.
- Chọn load reference: `@rpath`, `@executable_path`, `@loader_path`.
- Chọn RPATH tự động, preset, tùy chỉnh hoặc không thêm.
- Chọn strong/weak load và chính sách ghi đè.
- Patch toàn bộ slice Mach-O 64-bit trong executable, chỉ khi header có đủ chỗ trống.
- Đọc lại và xác minh load command trên đĩa trước khi đóng gói IPA.
- Xuất IPA chưa ký qua Share Sheet và thư mục Documents/Exports.

## Giới hạn quan trọng

1. IPA đầu ra **chưa ký hợp lệ** vì mọi thay đổi executable đều làm chữ ký cũ mất hiệu lực. Bạn phải ký lại app, extension, framework và dylib bằng chứng thư/provisioning profile của mình trước khi cài.
2. Công cụ không “inject trực tiếp” vào app đã cài. App Store/iOS sandbox không cho một app bình thường sửa bundle của app khác.
3. Patcher chỉ hỗ trợ Mach-O 64-bit little-endian và không nới rộng header. Nếu không đủ header slack, tiến trình dừng trước khi ghi để tránh làm hỏng binary.
4. DEB dùng `data.tar.zst` chưa được hỗ trợ; hãy đóng gói lại data archive bằng gzip hoặc xz.
5. Payload phải có đủ kiến trúc của executable đích. Kiểm tra kiến trúc không thay thế việc kiểm tra ABI, dependency hay entitlement.

## Build bằng GitHub Actions

1. Tạo repository mới và đưa toàn bộ nội dung thư mục này lên nhánh `main`.
2. Mở tab **Actions** → **Build and verify iOS app** → **Run workflow**.
3. Workflow sẽ chạy unit test lõi, compile cho iOS Simulator, compile Release cho iPhone, kiểm tra bundle/ZIP rồi đăng artifact `IPAPayloadLab-unsigned`.
4. Tải artifact và giải nén để lấy `IPAPayloadLab-unsigned.ipa`.

Workflow nằm tại `.github/workflows/main.yml`. Các đường dẫn tạm chỉ được mở rộng bên trong shell step, sau khi runner đã khởi tạo; vì vậy file không dùng context `runner` trong `env` cấp workflow hoặc job.

Workflow cố ý không nhận hoặc lưu chứng thư ký. Muốn có IPA cài được, hãy ký artifact bằng tài khoản Apple Developer và provisioning profile của chính bạn trong môi trường ký tin cậy.

## Build cục bộ

Yêu cầu: Xcode 16.4+, XcodeGen 2.45.4+.

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open IPAPayloadLab.xcodeproj
```

Chọn Team và Bundle Identifier của bạn trong target `IPAPayloadLab`, sau đó build lên thiết bị. Hai dependency được khóa trong `project.yml`:

- ZIPFoundation 0.9.20
- SWCompression 4.9.0

## Kiểm thử

Lõi không phụ thuộc UIKit nên có thể test riêng:

```bash
swift test --parallel
```

Test bao phủ patch Mach-O thin/fat, idempotency, trường hợp thiếu header slack, đọc ar/TAR và từ chối path traversal. GitHub Actions còn compile toàn bộ giao diện và pipeline cho Simulator lẫn iphoneos.

Ma trận kiểm tra chi tiết nằm tại [docs/VALIDATION.md](docs/VALIDATION.md).

## Luồng sử dụng

1. Chọn IPA mà bạn có quyền sửa.
2. Chọn executable đích.
3. Chọn dylib/framework/deb. Với DEB, các dylib/framework tìm được sẽ hiện thành danh sách bật/tắt.
4. Chọn vị trí, load reference và RPATH.
5. Xác nhận quyền sửa và bấm **Tạo IPA đã nhúng**.
6. Chia sẻ IPA chưa ký, sau đó ký lại toàn bộ bundle trước khi cài.

## An toàn

Chỉ sử dụng cho app của bạn, build nội bộ, nghiên cứu tương thích hoặc kiểm thử đã được cho phép. Xem thêm [SECURITY.md](SECURITY.md).
