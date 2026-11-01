# Bộ Công Cụ Tự Động Build & Port ColorOS 16 Cho Xiaomi Mi 8 (`dipper`)

Bộ công cụ này được thiết kế **đo ni đóng giày riêng cho chiếc Xiaomi Mi 8 (`dipper`) của bạn**, dựa trên cấu hình thực tế trích xuất từ máy bạn:
* **Đáy nền hiện tại trên máy bạn:** LineageOS 22.1 Android 15 (`vendor` trên `sde47`, `ro.product.first_api_level=27`) + **Kernel `4.9.337-perf-g003ed80d3907` (KernelSU)**.
* **Phôi đang chạy trên máy bạn:** OnePlus 13T (`PKX110_15.0.2.107(CN01)`), gộp toàn bộ vào phân vùng tĩnh `system` (`sda25`).

---

## 🔍 Phát hiện cực kỳ quan trọng từ Kernel `4.9.337` của máy bạn

Khi giải mã cấu hình `IKCFG_ST` nằm trong file `Image` (`4.9.337`) của chiếc Mi 8 của bạn:
1. **`CONFIG_EROFS_FS` chưa được bật!** (Kernel hiện tại của bạn chỉ đọc được phân vùng định dạng **`EXT4`**, không đọc được **`EROFS`**).
2. **BPF đang ở chuẩn Kernel 4.9** (`CONFIG_BPF=y`, `CONFIG_CGROUP_BPF=y`), chưa có `BPF_JIT` hay `5.10 BPF`.

Do đó, nếu lấy bản ColorOS 16 gốc nạp thẳng vào sẽ bị treo logo ngay lập tức vì **từ ColorOS 16 trở đi, các file `/system/apex/*.apex` bị đóng gói bằng `EROFS`**.

Bộ builder này giải quyết triệt để bằng cách:
1. **Tự động bung toàn bộ các file `.apex` / `.capex` của ColorOS 16**, kiểm tra magic byte `0xE0F5E1E2` (EROFS) của `apex_payload.img`, giải nén ra và **đóng gói lại thành `EXT4`** để Kernel `4.9.337` của bạn mount được 100%!
2. **Tự động áp dụng toàn bộ 12 bản vá trong bí kíp `#ProjectTreble#` Coolapk:**
   * Xóa symlink `/cache` và tạo thư mục `/cache` rỗng cho phân vùng tĩnh `sda25`.
   * Xóa `media.settings.xml=/vendor/etc/media_profiles_vendor.xml` trong `build.prop`.
   * Gộp `product`, `system_ext`, `my_product`, `my_stock`, `my_heytap`, `my_bigball`, `my_region`, `my_carrier`, `my_company`, `my_preload` vào `system` (và **bỏ qua `my_manifest`** để chống lỗi kẹt logo thứ 2 - *卡二*).
   * Điền `ro.product.first_api_level=27`, `ro.vendor.oplus.market.name=Xiaomi Mi 8`, mật độ màn hình `440 dpi`.
   * Xóa `my_product/etc/audio_policy_configuration.xml` (Fix tạch âm thanh C16).
   * Xóa `/system_ext/priv-app/com.qualcomm.location` (Fix lỗi Wi-Fi Soft-Reboot).
   * Lọc bỏ `lmvibrator` / `richctap` (Fix mất rung), `record` (Fix quay màn hình), `unavailable-feature fingerprint` (Mở khóa vân tay).
   * Xóa `oplus.product.display_system_features.xml` (Fix sai tông màu màn hình) và `corner` (Fix viền đen).
   * Xóa `sys_camera_optimize_config.xml` (Fix lỗi quét QR WeChat/Zalo).
   * Làm rỗng `sys_graphics_game_gpu_control_panel.json` (Fix văng Game Space).
   * Xóa toàn bộ cấu hình `HDR` trong `my_product/etc` (Fix giật lag khi lướt TikTok/Douyin).
3. **Tích hợp sẵn gói `Mi8_ColorOS15_NFC_WiFi_AllInOne_Fix_v2.0.zip`** (trong thư mục `device_dipper/`) để giữ nguyên fix NFC `NQ330`, Dual-Mic và Wi-Fi cho Mi 8.

---

## 🚀 Cách chạy Build ra file `system.img` (Khuyên dùng GitHub Actions)

Vì quá trình tải ROM gốc ColorOS 16 (`~7 GB`) + bung EROFS (`~11 GB`) + đóng gói lại EXT4 (`~9 GB`) rất nặng, cách nhanh và nhàn nhất là dùng **GitHub Actions** (đã viết sẵn trong `.github/workflows/build_coloros16_dipper.yml`):

1. Đẩy thư mục `ColorOS16_Dipper_Builder` này lên một Repository trên GitHub của bạn.
2. Vào trang **https://yun.daxiaamu.com/** $\rightarrow$ chọn **一加 13T (`PKX110`)** (cùng mã máy với bản ColorOS 15 bạn đang chạy!) hoặc **一加 12 / 13** $\rightarrow$ copy đường link tải trực tiếp bản **ColorOS 16.0 Full OTA (`.zip`)**.
3. Trên GitHub Repository của bạn, bấm tab **Actions** $\rightarrow$ chọn **Build ColorOS 16 for Xiaomi Mi 8 (dipper)** $\rightarrow$ bấm **Run workflow** và dán link OTA vào ô `coloros16_ota_url`.
4. Đợi ~15 phút, tải file `ColorOS16_dipper_system_ext4.img.zst` về, giải nén ra `.img` và vào TWRP/OrangeFox chọn **Install Image $\rightarrow$ `ColorOS16_dipper_system_ext4.img` $\rightarrow$ tích chọn phân vùng `System` (`sda25`)**!
