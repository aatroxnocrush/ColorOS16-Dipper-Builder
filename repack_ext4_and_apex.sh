#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Xiaomi Mi 8 (dipper) Standalone Full ROM Packager (boot + vendor + system)
# ==============================================================================
# Builds a 100% standalone TWRP/OrangeFox flashable .zip ROM for Xiaomi Mi 8:
#   1. Converts all EROFS .apex / .capex in ColorOS 16 to EXT4
#   2. Patches clean dipper Base Vendor (vendor.img) with ColorOS 16 group,
#      passwd, and oplus_avb.pubkey (per Coolapk #ProjectTreble# guide)
#   3. Builds EXT4 system.img for sda25
#   4. Packages boot.img + vendor.img + system.img + META-INF updater-script
#      into a single standalone flashable zip: ColorOS16_Mi8_dipper_FULL.zip
# ==============================================================================

WORK_DIR="$(realpath -m "${1:-./work_c16_dipper}")"
BASE_DIR="$(realpath -m "${2:-./base_dipper}")"
OUT_ZIP="$(realpath -m "${3:-./ColorOS16_Mi8_dipper_FULL.zip}")"

SYS_ROOT="${WORK_DIR}/system"
DONOR_BLOBS="${WORK_DIR}/donor_blobs"

echo "[1/5] Converting ColorOS 16 EROFS APEX packages to EXT4..."
TMP_APEX="$(mktemp -d)"
find "${SYS_ROOT}/system/apex" "${SYS_ROOT}/system/system_ext/apex" -type f \( -name "*.apex" -o -name "*.capex" \) 2>/dev/null | while read -r apex_file; do
    rm -rf "${TMP_APEX:?}"/*
    unzip -q "${apex_file}" -d "${TMP_APEX}" || continue

    if [ -f "${TMP_APEX}/original_apex" ]; then
        mkdir -p "${TMP_APEX}/inner"
        unzip -q "${TMP_APEX}/original_apex" -d "${TMP_APEX}/inner" || continue
        PAYLOAD="${TMP_APEX}/inner/apex_payload.img"
        IS_CAPEX=1
    else
        PAYLOAD="${TMP_APEX}/apex_payload.img"
        IS_CAPEX=0
    fi

    if [ -f "${PAYLOAD}" ]; then
        MAGIC=$(xxd -s 1024 -l 4 -p "${PAYLOAD}" 2>/dev/null || true)
        if [ "${MAGIC}" = "e2e1f5e0" ]; then
            echo "  -> Converting EROFS APEX to EXT4: $(basename "${apex_file}")"
            mkdir -p "${TMP_APEX}/payload_fs"
            fsck.erofs --extract="${TMP_APEX}/payload_fs" --force "${PAYLOAD}" >/dev/null 2>&1
            SIZE_KB=$(du -sk "${TMP_APEX}/payload_fs" | cut -f1)
            IMG_KB=$(( SIZE_KB + 16384 ))
            rm -f "${PAYLOAD}"
            mke2fs -t ext4 -b 4096 -d "${TMP_APEX}/payload_fs" -O ^has_journal,^metadata_csum "${PAYLOAD}" "${IMG_KB}K" >/dev/null 2>&1
            rm -rf "${TMP_APEX}/payload_fs"

            if [ "${IS_CAPEX}" -eq 1 ]; then
                rm -f "${TMP_APEX}/original_apex"
                (cd "${TMP_APEX}/inner" && zip -q -0 -r "${TMP_APEX}/original_apex" .)
                rm -rf "${TMP_APEX}/inner"
            fi
            rm -f "${apex_file}"
            (cd "${TMP_APEX}" && zip -q -0 -r "${apex_file}" .)
        fi
    fi
done
rm -rf "${TMP_APEX}"

echo "[2/5] Patching Xiaomi Mi 8 Base vendor.img with ColorOS 16 group, passwd & oplus_avb.pubkey..."
VENDOR_IMG="${BASE_DIR}/vendor.img"
if [ -f "${VENDOR_IMG}" ]; then
    e2fsck -fy "${VENDOR_IMG}" || true
    resize2fs "${VENDOR_IMG}" 1536M || true
    e2fsck -E unshare_blocks -fy "${VENDOR_IMG}" || true
    MNT_V="$(mktemp -d)"
    mount -o loop,rw "${VENDOR_IMG}" "${MNT_V}"
    for b in group passwd oplus_avb.pubkey; do
        if [ -f "${DONOR_BLOBS}/vendor_${b}" ]; then
            cp -f "${DONOR_BLOBS}/vendor_${b}" "${MNT_V}/etc/${b}"
            chmod 0644 "${MNT_V}/etc/${b}"
            echo "  -> Injected donor vendor/etc/${b} into dipper vendor.img"
        elif [ -f "${DONOR_BLOBS}/odm_${b}" ]; then
            cp -f "${DONOR_BLOBS}/odm_${b}" "${MNT_V}/etc/${b}"
            chmod 0644 "${MNT_V}/etc/${b}"
            echo "  -> Injected donor odm/etc/${b} into dipper vendor.img"
        fi
    done
    # Inject ColorOS 16 Power Button Wake Delay Fix into vendor if present
    if [ -d "./device_dipper/power_delay_fix" ]; then
        cp -rf ./device_dipper/power_delay_fix/bin/* "${MNT_V}/bin/" 2>/dev/null || true
        cp -rf ./device_dipper/power_delay_fix/etc/init/* "${MNT_V}/etc/init/" 2>/dev/null || true
        chmod 0755 "${MNT_V}/bin/init.button.sh" "${MNT_V}/bin/resetprop" 2>/dev/null || true
        chmod 0644 "${MNT_V}/etc/init/init.button.rc" 2>/dev/null || true
        echo "  -> Injected ColorOS 16 Power Button Wake Delay Fix into dipper vendor.img"
    fi
    sync
    umount "${MNT_V}"
    rmdir "${MNT_V}"
    e2fsck -fy "${VENDOR_IMG}" || true
    resize2fs -M "${VENDOR_IMG}" || true
fi

echo "[3/5] Building standalone EXT4 system.img for Xiaomi Mi 8 (sda25 <= 8.0 GiB)..."
USED_MB=$(du -sm "${SYS_ROOT}" | cut -f1)
echo "  -> SYS_ROOT size after Python debloat: ${USED_MB} MiB"

# Safety guard: if SYS_ROOT is still > 6800 MiB, trim additional non-essential media/heytap bloat
if [ "${USED_MB}" -gt 6800 ]; then
    echo "  -> Trimming extra large bloat apps to ensure strict < 7500 MiB EXT4 image..."
    rm -rf "${SYS_ROOT}/my_heytap/app"/* "${SYS_ROOT}/my_bigball/app"/* \
           "${SYS_ROOT}/my_bigball/priv-app"/* "${SYS_ROOT}/my_preload"/* \
           "${SYS_ROOT}/my_product/media/wallpaper"/* 2>/dev/null || true
    USED_MB=$(du -sm "${SYS_ROOT}" | cut -f1)
    echo "  -> SYS_ROOT size after safety trim: ${USED_MB} MiB"
fi

IMG_MB=$(( USED_MB + (USED_MB * 6 / 100) + 128 ))
if [ "${IMG_MB}" -gt 7500 ]; then
    IMG_MB=7500
fi
NUM_INODES=$(( $(find "${SYS_ROOT}" | wc -l) + 16384 ))
SYS_IMG="${BASE_DIR}/system.img"
rm -f "${SYS_IMG}"
mke2fs -t ext4 -b 4096 -L "/" -I 256 -m 0 -N "${NUM_INODES}" -d "${SYS_ROOT}" -O ^metadata_csum,^64bit,^has_journal "${SYS_IMG}" "${IMG_MB}M"
e2fsck -fy "${SYS_IMG}" || true
resize2fs -M "${SYS_IMG}" || true
FINAL_SYS_MB=$(du -sm "${SYS_IMG}" | cut -f1)
echo "  -> Final system.img size: ${FINAL_SYS_MB} MiB (Target sda25 partition: 8192 MiB)"
rm -rf "${SYS_ROOT}"

echo "[4/5] Building Permissive Kernel 4.9.337 boot.img & TWRP/OrangeFox META-INF installer scripts..."
if [ -f "./device_dipper/KernelImage" ] && [ -f "./device_dipper/ramdisk.cpio.gz" ] && [ -f "./device_dipper/dipper_mp_v2_1.dtb" ]; then
    python3 - << 'PYEOF' "${BASE_DIR}/boot.img"
import sys, struct, gzip, hashlib

out_boot = sys.argv[1]
with open("./device_dipper/KernelImage", "rb") as f:
    raw_img = f.read()
with open("./device_dipper/dipper_mp_v2_1.dtb", "rb") as f:
    dtb = f.read()
with open("./device_dipper/ramdisk.cpio.gz", "rb") as f:
    ramdisk = f.read()

gz_img = gzip.compress(raw_img, compresslevel=9)
kernel = gz_img + dtb
page_size = 4096

def pad_page(data):
    rem = len(data) % page_size
    return data if rem == 0 else data + b"\x00" * (page_size - rem)

cmdline = (
    b"console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xA84000 "
    b"androidboot.hardware=qcom androidboot.console=ttyMSM0 "
    b"video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 "
    b"ehci-hcd.park=3 lpm_levels.sleep_disabled=1 service_locator.enable=1 "
    b"swiotlb=2048 androidboot.configfs=true loop.max_part=7 "
    b"androidboot.usbcontroller=a600000.dwc3 androidboot.selinux=permissive"
)

os_version = (15 << 25) | (25 << 4) | 2
hdr = bytearray(page_size)
struct.pack_into(
    "<8s10I",
    hdr,
    0,
    b"ANDROID!",
    len(kernel),
    0x00008000,
    len(ramdisk),
    0x01000000,
    0,
    0x00F00000,
    0x00000100,
    page_size,
    1,
    os_version,
)
hdr[64 : 64 + len(cmdline)] = cmdline

sha = hashlib.sha1()
sha.update(kernel)
sha.update(struct.pack("<I", len(kernel)))
sha.update(ramdisk)
sha.update(struct.pack("<I", len(ramdisk)))
sha.update(struct.pack("<I", 0))
hdr[576 : 576 + 20] = sha.digest()
struct.pack_into("<I", hdr, 1632, 1648)

with open(out_boot, "wb") as f:
    f.write(hdr)
    f.write(pad_page(kernel))
    f.write(pad_page(ramdisk))
print(f"  -> Built permissive Kernel 4.9.337 boot.img: {out_boot} ({len(kernel)}B kernel + {len(ramdisk)}B ramdisk)")
PYEOF
fi

PKG_STAGE="$(mktemp -d)"
mkdir -p "${PKG_STAGE}/META-INF/com/google/android"

cat << 'EOF' > "${PKG_STAGE}/META-INF/com/google/android/update-binary"
#!/sbin/sh
OUTFD=$2
ZIPFILE=$3

ui_print() {
  echo "ui_print $1" > /proc/self/fd/$OUTFD
  echo "ui_print" > /proc/self/fd/$OUTFD
}

ui_print "=============================================="
ui_print "   ColorOS 16 Standalone Full ROM (CN)        "
ui_print "   Target Device: Xiaomi Mi 8 (dipper)        "
ui_print "=============================================="

umount /system_root 2>/dev/null || true
umount /system 2>/dev/null || true
umount /vendor 2>/dev/null || true

ui_print "[1/3] Flashing Permissive Kernel (boot.img)..."
unzip -p "$ZIPFILE" "boot.img" > /dev/block/bootdevice/by-name/boot

ui_print "[2/3] Flashing Patched Dipper Vendor (vendor.img)..."
unzip -p "$ZIPFILE" "vendor.img" > /dev/block/bootdevice/by-name/vendor

ui_print "[3/3] Flashing Merged ColorOS 16 System (sda25 <= 8.0GB)..."
unzip -p "$ZIPFILE" "system.img" > /dev/block/bootdevice/by-name/system
e2fsck -fy /dev/block/bootdevice/by-name/system >/dev/null 2>&1 || true
resize2fs /dev/block/bootdevice/by-name/system >/dev/null 2>&1 || true

ui_print "=============================================="
ui_print " Installation Complete! Format Data if needed "
ui_print "=============================================="
exit 0
EOF
chmod 0755 "${PKG_STAGE}/META-INF/com/google/android/update-binary"
echo "# Dummy updater-script" > "${PKG_STAGE}/META-INF/com/google/android/updater-script"

cat << 'BATEOF' > "${PKG_STAGE}/Flash_Fastboot_Windows.bat"
@echo off
title ColorOS 16 - Xiaomi Mi 8 (dipper) Fastboot Installer
cd /d "%~dp0"

set "FB=fastboot"
if exist "C:\Users\ManhPhongg\Downloads\platform-tools\fastboot.exe" (
    set "FB=C:\Users\ManhPhongg\Downloads\platform-tools\fastboot.exe"
)

echo ========================================================
echo   ColorOS 16 Standalone ROM - Xiaomi Mi 8 (dipper)
echo   Che do: Flash truc tiep qua Fastboot (Khong can TWRP)
echo ========================================================
echo.
echo [1/3] Dang flash boot.img...
"%FB%" flash boot boot.img
echo [2/3] Dang flash vendor.img...
"%FB%" flash vendor vendor.img
echo [3/3] Dang flash system.img vao sda25...
"%FB%" flash system system.img
echo.
echo ========================================================
echo   FLASH THANH CONG! Neu moi chuyen ROM, hay Format Data
echo   trong Recovery hoac chay: "%FB%" -w
echo ========================================================
pause
BATEOF

mv "${SYS_IMG}" "${PKG_STAGE}/system.img"
if [ -f "${VENDOR_IMG}" ]; then
    mv "${VENDOR_IMG}" "${PKG_STAGE}/vendor.img"
fi
if [ -f "${BASE_DIR}/boot.img" ]; then
    mv "${BASE_DIR}/boot.img" "${PKG_STAGE}/boot.img"
fi

echo "[5/5] Packaging Full Flashable TWRP + Fastboot ROM: ${OUT_ZIP}..."
rm -f "${OUT_ZIP}"
if command -v 7z >/dev/null 2>&1; then
    (cd "${PKG_STAGE}" && 7z a -tzip -mx=5 -mmt=on "${OUT_ZIP}" .)
else
    (cd "${PKG_STAGE}" && zip -r -6 "${OUT_ZIP}" .)
fi
rm -rf "${PKG_STAGE}"

echo "=== FULL STANDALONE ROM READY: ${OUT_ZIP} ($(du -h "${OUT_ZIP}" | cut -f1)) ==="
