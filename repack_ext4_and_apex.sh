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

WORK_DIR="${1:-./work_c16_dipper}"
BASE_DIR="${2:-./base_dipper}"
OUT_ZIP="${3:-./ColorOS16_Mi8_dipper_FULL.zip}"

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
                (cd "${TMP_APEX}/inner" && zip -q -0 -r "${TMP_APEX}/original_apex" .)
                rm -rf "${TMP_APEX}/inner"
            fi
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
    # Ensurefstab/overlay directories exist for ColorOS
    mkdir -p "${MNT_V}/odm"
    sync
    umount "${MNT_V}"
    rmdir "${MNT_V}"
    e2fsck -fy "${VENDOR_IMG}" || true
    resize2fs -M "${VENDOR_IMG}" || true
fi

echo "[3/5] Building standalone EXT4 system.img for Xiaomi Mi 8 (sda25)..."
USED_MB=$(du -sm "${SYS_ROOT}" | cut -f1)
IMG_MB=$(( USED_MB + 350 ))
SYS_IMG="${BASE_DIR}/system.img"
rm -f "${SYS_IMG}"
mke2fs -t ext4 -b 4096 -L "/" -d "${SYS_ROOT}" -O ^metadata_csum,^64bit "${SYS_IMG}" "${IMG_MB}M"
e2fsck -fy "${SYS_IMG}" || true
resize2fs -M "${SYS_IMG}" || true
rm -rf "${SYS_ROOT}"

echo "[4/5] Creating TWRP/OrangeFox META-INF installer scripts..."
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

ui_print "[1/3] Flashing Permissive Kernel (boot.img)..."
unzip -p "$ZIPFILE" "boot.img" > /dev/block/bootdevice/by-name/boot

ui_print "[2/3] Flashing Patched Dipper Vendor (vendor.img)..."
unzip -p "$ZIPFILE" "vendor.img" > /dev/block/bootdevice/by-name/vendor

ui_print "[3/3] Flashing Merged ColorOS 16 System (system.img)..."
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

mv "${SYS_IMG}" "${PKG_STAGE}/system.img"
[ -f "${VENDOR_IMG}" ] && mv "${VENDOR_IMG}" "${PKG_STAGE}/vendor.img"
[ -f "${BASE_DIR}/boot.img" ] && mv "${BASE_DIR}/boot.img" "${PKG_STAGE}/boot.img"

echo "[5/5] Packaging Full Flashable TWRP ROM: ${OUT_ZIP}..."
(cd "${PKG_STAGE}" && zip -r -1 "${OLDPWD}/${OUT_ZIP}" .)
rm -rf "${PKG_STAGE}"

echo "=== FULL STANDALONE ROM READY: ${OUT_ZIP} ==="
