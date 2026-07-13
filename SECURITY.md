# Security notes

- IPA Payload Lab chỉ xử lý file người dùng chủ động nhập trong sandbox của ứng dụng.
- ZIP/TAR entry có đường dẫn tuyệt đối, `..`, backslash, symlink trong IPA hoặc kích thước bất thường sẽ bị từ chối.
- Load path/RPATH chỉ chấp nhận `@rpath`, `@executable_path` và `@loader_path`; không nhận đường dẫn hệ thống tuyệt đối.
- Patcher lập kế hoạch cho mọi slice trước rồi mới ghi, do đó lỗi header slack ở bất kỳ slice nào sẽ dừng toàn bộ thao tác.
- Output luôn được mô tả là chưa ký. Dự án không chứa chứng thư, provisioning profile, khóa riêng hay logic bỏ qua xác minh chữ ký.

Nếu phát hiện file hợp lệ làm app crash hoặc vượt kiểm tra đường dẫn/kích thước, hãy mở issue kèm mẫu tối giản không chứa dữ liệu nhạy cảm.
