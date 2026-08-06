# Tích hợp Cloudflare bypass (từ repo1) vào revanced-magisk-module

Logic bypass được **port nguyên vẹn** từ `Revanced-And-Revanced-Extended-Non-Root`
(`src/build/utils.sh`): FlareSolverr là lớp chính, CloudflareBypassForScraping (CFB)
là lớp dự phòng, điều phối bởi `_cf_get`. Cookie + User-Agent lấy được truyền vào
lệnh tải file.

## Những gì đã thay đổi

1. **`cf_bypass.sh`** (mới) — chứa `_fs_get` / `_cfb_get` / `_cf_get` giữ 100% từ
   repo1, cộng bộ shim đăng ký nguồn tải mới tên `apkmirror_cf` cho khung
   `revanced-magisk-module` (các hàm `get_apkmirror_cf_resp`,
   `get_apkmirror_cf_pkg_name`, `get_apkmirror_cf_vers`, `dl_apkmirror_cf`).
   Nguồn này dùng `pup` để parse HTML — đúng như repo1 — nên có mang theo bước tự
   tải `pup`.
2. **`utils.sh`** — thêm `apkmirror_cf` vào `DL_SRCS`; source `cf_bypass.sh` ở cuối file.
3. **`.github/workflows/build.yml`** — thêm 3 bước: cài deps (`jq/curl/wget/unzip`),
   dựng FlareSolverr (cổng 8191) và CFB (cổng 8000) bằng Docker trước khi build.

`build.sh` **không cần sửa**: nó tự lặp qua `DL_SRCS` để đọc khóa `<src>-dlurl`.

## Cách dùng trong config.toml

Thêm khóa `apkmirror_cf-dlurl` cho app cần bypass, trỏ tới trang **uploads** của
APKMirror (giống `apkmirror-dlurl`). Ví dụ:

```toml
[YouTube]
apkmirror_cf-dlurl = "https://www.apkmirror.com/apk/google-inc/youtube"
arch = "arm64-v8a"
# dpi = "nodpi"   # tùy chọn
```

Thứ tự thử nguồn theo `DL_SRCS`: `direct → archive → apkmirror → apkmirror_cf → uptodown`.
Nếu chỉ muốn ép dùng bypass, chỉ khai `apkmirror_cf-dlurl` và bỏ trống các khóa dlurl khác.

## Yêu cầu môi trường

- **GitHub Actions**: đã cấu hình sẵn trong `build.yml` (runner có Docker). Không cần làm gì thêm.
- **Máy Linux/PC**: cần Docker; tự chạy 2 lệnh `docker run` như trong `build.yml`.
- **Termux/điện thoại**: KHÔNG chạy được (không có Docker). Dùng nguồn `uptodown`/`archive` thay thế.

## Ghi chú

- Bypass phụ thuộc dịch vụ ngoài (FlareSolverr/CFB) — đây là bản chất của cơ chế
  repo1, không thể bỏ mà vẫn giải được challenge Cloudflare.
- Nếu APKMirror đổi cấu trúc HTML, cần cập nhật selector `pup` trong `dl_apkmirror_cf`.
