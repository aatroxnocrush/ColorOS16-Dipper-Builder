#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Xiaomi Mi 8 (dipper - Kernel 4.9.337) EXT4 Repacker & EROFS-APEX Converter
# ==============================================================================
# Why this script is essential for Xiaomi Mi 8:
#   We extracted IKCFG_ST from your Mi 8's Kernel 4.9.337-perf-g003ed80d3907:
#   - CONFIG_EROFS_FS is NOT enabled in Kernel 4.9.337!
#   - ColorOS 16 packs /system/apex/*.apex payloads as EROFS by default.
#   This script:
#   1. Scans all .apex / .capex files in ColorOS 16, extracts any EROFS
#      apex_payload.img, and converts it to EXT4 so apexd mounts on Kernel 4.9!
#   2. Packs the merged ColorOS 16 root directory into an EXT4 system.img
#      ready to flash to /dev/block/bootdevice/by-name/system (sda25).
# ==============================================================================

SYS_ROOT="${1:-./work_c16_dipper/system}"
OUT_IMG="${2:-./ColorOS16_dipper_system_ext4.img}"

echo "[1/3] Scanning APEX packages in ${SYS_ROOT} for EROFS payloads..."
TMP_APEX="$(mktemp -d)"

find "${SYS_ROOT}/system/apex" "${SYS_ROOT}/system/system_ext/apex" -type f \( -name "*.apex" -o -name "*.capex" \) 2>/dev/null | while read -r apex_file; do
    rm -rf "${TMP_APEX:?}"/*
    unzip -q "${apex_file}" -d "${TMP_APEX}" || continue

    # If it's a compressed .capex containing original_apex, unpack that too
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
        # Check EROFS magic (0xE0F5E1E2 at offset 1024)
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

echo "[2/3] Calculating EXT4 partition size for Xiaomi Mi 8 (sda25)..."
USED_MB=$(du -sm "${SYS_ROOT}" | cut -f1)
IMG_MB=$(( USED_MB + 350 ))
echo "  -> Unpacked rootfs: ${USED_MB} MB | Target EXT4 image: ${IMG_MB} MB"

echo "[3/3] Building EXT4 system.img at ${OUT_IMG}..."
rm -f "${OUT_IMG}"
mke2fs -t ext4 -b 4096 -L "/" -d "${SYS_ROOT}" -O ^metadata_csum,^64bit "${OUT_IMG}" "${IMG_MB}M"
e2fsck -fy "${OUT_IMG}" || true
resize2fs -M "${OUT_IMG}" || true

echo "=== DONE! Output image: ${OUT_IMG} ==="
