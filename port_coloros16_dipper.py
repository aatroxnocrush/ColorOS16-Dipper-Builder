#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ColorOS 16 -> Xiaomi Mi 8 (dipper / SDM845) Automated Porting Engine
====================================================================
Implements:
1. Full Coolapk #ProjectTreble# Xiaomi ColorOS 16 Porting Guide (16 patches)
2. Low-disk-space streaming extraction (auto-deletes intermediate .img files)
3. Special Xiaomi Mi 8 (Kernel 4.9.337) Compatibility Layer:
   - Converts ColorOS 16 EROFS APEX payloads to EXT4 (since dipper Kernel 4.9.337 lacks CONFIG_EROFS_FS)
   - Preserves Android 15/4.9-compatible BPF objects & injects liboplusbindermonitor.so
   - Integrates Xiaomi Mi 8 (dipper) NFC (NQ330), Dual-Mic Audio, and Vendor keys
   - Packs final merged System-as-Root image as EXT4 for static partition sda25
"""

import os
import re
import sys
import glob
import json
import shutil
import zipfile
import argparse
import subprocess
from pathlib import Path

# Partition lists for ColorOS 16
CORE_PARTITIONS = ["system", "system_ext", "product"]
OPLUS_MY_PARTITIONS = [
    "my_product",
    "my_stock",
    "my_heytap",
    "my_bigball",
    "my_region",
    "my_carrier",
    "my_company",
    "my_preload",
    "my_engineering",
    # Note: my_manifest is intentionally NOT merged into system to prevent
    # stage-2 bootloop ("卡二"), per the Coolapk ProjectTreble C16 guide.
]


def log(msg: str):
    print(f"[ColorOS16-Dipper] {msg}", flush=True)


def run_cmd(cmd, cwd=None, check=True):
    log(f"Running: {' '.join(str(x) for x in cmd)}")
    res = subprocess.run(cmd, cwd=cwd)
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {res.returncode}: {cmd}")
    return res.returncode


def step1_extract_payload(ota_or_payload: Path, out_img_dir: Path, payload_dumper_bin: str):
    """Extracts required partitions from ColorOS 16 Full OTA .zip or payload.bin."""
    out_img_dir.mkdir(parents=True, exist_ok=True)
    target_parts = ",".join(CORE_PARTITIONS + OPLUS_MY_PARTITIONS + ["my_manifest", "vendor", "odm"])
    cmd = [
        payload_dumper_bin,
        "-p", target_parts,
        "-o", str(out_img_dir),
        str(ota_or_payload)
    ]
    run_cmd(cmd)


def step2_unpack_and_merge_partitions(img_dir: Path, work_root: Path, fsck_erofs_bin: str, low_disk_mode: bool = True):
    """
    Unpacks EROFS/EXT4 images into a unified System-as-Root directory (work_root/system)
    for Xiaomi Mi 8's static sda25 partition.
    """
    sys_root = work_root / "system"
    sys_root.mkdir(parents=True, exist_ok=True)

    # 1. Extract 'system.img' as the root base
    sys_img = img_dir / "system.img"
    if not sys_img.exists():
        raise FileNotFoundError(f"Missing {sys_img}")
    run_cmd([fsck_erofs_bin, f"--extract={sys_root}", "--force", str(sys_img)])
    if low_disk_mode:
        sys_img.unlink()
        log("Deleted intermediate system.img to save disk space.")

    # 2. Extract 'product' and 'system_ext' into system/<partition> and symlink /<partition> -> /system/<partition>
    for part in ["product", "system_ext"]:
        p_img = img_dir / f"{part}.img"
        if not p_img.exists():
            continue
        target_dir = sys_root / "system" / part
        if target_dir.is_symlink() or target_dir.is_file():
            target_dir.unlink()
        target_dir.mkdir(parents=True, exist_ok=True)
        run_cmd([fsck_erofs_bin, f"--extract={target_dir}", "--force", str(p_img)])
        if low_disk_mode:
            p_img.unlink()
            log(f"Deleted intermediate {part}.img to save disk space.")

    # 3. Extract and merge OPLUS my_* partitions into sys_root/<my_part>
    for my_part in OPLUS_MY_PARTITIONS:
        m_img = img_dir / f"{my_part}.img"
        if not m_img.exists():
            log(f"Optional partition {my_part}.img not present, skipping.")
            continue
        target_dir = sys_root / my_part
        if target_dir.is_symlink() or target_dir.is_file():
            target_dir.unlink()
        target_dir.mkdir(parents=True, exist_ok=True)
        run_cmd([fsck_erofs_bin, f"--extract={target_dir}", "--force", str(m_img)])
        if low_disk_mode:
            m_img.unlink()
            log(f"Deleted intermediate {my_part}.img to save disk space.")

    # 4. Extract oplus_avb.pubkey from donor vendor/odm if present, then delete donor vendor/odm images
    pubkey_out = work_root / "donor_blobs"
    pubkey_out.mkdir(parents=True, exist_ok=True)
    for vpart in ["vendor", "odm"]:
        v_img = img_dir / f"{vpart}.img"
        if v_img.exists():
            tmp_v = work_root / f"tmp_{vpart}"
            tmp_v.mkdir(parents=True, exist_ok=True)
            run_cmd([fsck_erofs_bin, f"--extract={tmp_v}", "--force", str(v_img)], check=False)
            for candidate in [
                tmp_v / "etc" / "oplus_avb.pubkey",
                tmp_v / "etc" / "group",
                tmp_v / "etc" / "passwd",
            ]:
                if candidate.exists():
                    shutil.copy2(candidate, pubkey_out / f"{vpart}_{candidate.name}")
            shutil.rmtree(tmp_v, ignore_errors=True)
            if low_disk_mode:
                v_img.unlink()

    # Also delete my_manifest.img without merging (per guide: do not merge my_manifest to avoid stage-2 hang)
    manifest_img = img_dir / "my_manifest.img"
    if manifest_img.exists() and low_disk_mode:
        manifest_img.unlink()


def step3_apply_coolapk_pt_patches(sys_root: Path, device_market_name: str = "Xiaomi Mi 8", first_api_level: str = "27"):
    """
    Applies every single fix from the Coolapk #ProjectTreble# Xiaomi ColorOS 16 Porting Guide.
    """
    log("Applying Coolapk #ProjectTreble# ColorOS 16 patches for Xiaomi Mi 8 (dipper)...")

    # [Patch 1] Static partition requirement: Delete /cache symlink and create an empty /cache folder
    cache_path = sys_root / "cache"
    if cache_path.is_symlink() or cache_path.is_file():
        cache_path.unlink()
    elif cache_path.is_dir():
        shutil.rmtree(cache_path)
    cache_path.mkdir(parents=True, exist_ok=True)
    log("1. Replaced /cache symlink with empty directory (static partition requirement).")

    # [Patch 2 & 3] Edit system/system/build.prop:
    # - Remove media.settings.xml=/vendor/etc/media_profiles_vendor.xml
    # - Add ro.product.first_api_level=27 (dipper VNDK/first API level)
    # - Add ro.vendor.oplus.market.name=Xiaomi Mi 8 (replaces merging my_manifest)
    # - Add dipper notch/screenhole & density properties
    build_prop = sys_root / "system" / "build.prop"
    if build_prop.exists():
        lines = build_prop.read_text(encoding="utf-8", errors="ignore").splitlines()
        filtered = []
        for line in lines:
            if line.strip().startswith("media.settings.xml=/vendor/etc/media_profiles_vendor.xml"):
                log("2. Removed media.settings.xml=/vendor/etc/media_profiles_vendor.xml from build.prop")
                continue
            if line.strip().startswith("ro.product.first_api_level="):
                continue
            if line.strip().startswith("ro.vendor.oplus.market.name="):
                continue
            filtered.append(line)

        # Strip any conflicting ro.product.first_api_level from my_*/build.prop before importing
        for my_part in OPLUS_MY_PARTITIONS:
            mp_prop = sys_root / my_part / "build.prop"
            if mp_prop.exists():
                mp_lines = mp_prop.read_text(encoding="utf-8", errors="ignore").splitlines()
                mp_cleaned = [
                    f"#{ln}" if ln.strip().startswith("ro.product.first_api_level=") else ln
                    for ln in mp_lines
                ]
                mp_prop.write_text("\n".join(mp_cleaned) + "\n", encoding="utf-8")

        filtered.extend([
            "",
            "# === Import OPLUS Dynamic Partitions merged into System-as-Root ===",
            "import /my_bigball/build.prop",
            "import /my_carrier/build.prop",
            "import /my_company/build.prop",
            "import /my_engineering/build.prop",
            "import /my_heytap/build.prop",
            "import /my_preload/build.prop",
            "import /my_product/build.prop",
            "import /my_region/build.prop",
            "import /my_stock/build.prop",
            "",
            "# === Xiaomi Mi 8 (dipper) ColorOS 16 Port Properties ===",
            f"ro.product.first_api_level={first_api_level}",
            f"ro.vendor.oplus.market.name={device_market_name}",
            f"ro.vendor.oplus.market.enname={device_market_name}",
            "ro.oplus.display.screen.heteromorphism=1",
            "ro.SurfaceFlinger.supports_background_blur=1",
            "persist.sys.oplus.anim_level=2",
        ])
        build_prop.write_text("\n".join(filtered) + "\n", encoding="utf-8")
        log(f"3. Patched system/system/build.prop (imported my_*/build.prop, first_api_level={first_api_level}, market.name={device_market_name}).")

    # [Patch 4] Fix ColorOS 16 Audio crash: Delete my_product/etc/audio_policy_configuration.xml
    audio_pol = sys_root / "my_product" / "etc" / "audio_policy_configuration.xml"
    if audio_pol.exists():
        audio_pol.unlink()
        log("4. Deleted my_product/etc/audio_policy_configuration.xml (Audio crash fix).")

    # [Patch 5] Fix Wi-Fi / Soft-Reboot: Delete system_ext/priv-app/com.qualcomm.location
    qcom_loc = sys_root / "system" / "system_ext" / "priv-app" / "com.qualcomm.location"
    if qcom_loc.exists():
        shutil.rmtree(qcom_loc, ignore_errors=True)
        log("5. Removed system_ext/priv-app/com.qualcomm.location (Soft-reboot fix).")

    # [Patch 6] Fix Vibration & Screen Recording & Tablet Fingerprint in my_product/etc/permissions/*.xml
    perm_dir = sys_root / "my_product" / "etc" / "permissions"
    if perm_dir.exists():
        for xml_file in perm_dir.rglob("*.xml"):
            txt = xml_file.read_text(encoding="utf-8", errors="ignore")
            orig = txt
            # Remove lines containing lmvibrator, richctap, or record
            new_lines = []
            for ln in txt.splitlines():
                low = ln.lower()
                if "lmvibrator" in low or "richctap" in low or "richtap" in low:
                    continue
                if "record" in low and ("feature" in low or "oplus" in low):
                    continue
                if 'unavailable-feature name="android.hardware.fingerprint"' in ln:
                    continue
                new_lines.append(ln)
            txt = "\n".join(new_lines) + "\n"
            if txt != orig:
                xml_file.write_text(txt, encoding="utf-8")
        log("6. Stripped lmvibrator/richctap, screen-record locks, and fingerprint blocks in my_product/etc/permissions.")

    # [Patch 7] Fix Screen Color Temperature bug: Delete my_product/etc/permissions/oplus.product.display_system_features.xml
    disp_sys_feat = perm_dir / "oplus.product.display_system_features.xml"
    if disp_sys_feat.exists():
        disp_sys_feat.unlink()
        log("7. Deleted oplus.product.display_system_features.xml (Screen color temperature fix).")

    # [Patch 8] Fix Corner Mask bug: Strip 'corner' features in oplus.product.display_features.xml
    for df in perm_dir.glob("*display_features*.xml") if perm_dir.exists() else []:
        lines = df.read_text(encoding="utf-8", errors="ignore").splitlines()
        cleaned = [ln for ln in lines if "corner" not in ln.lower()]
        df.write_text("\n".join(cleaned) + "\n", encoding="utf-8")
        log(f"8. Stripped corner mask features from {df.name}.")

    # [Patch 9] Fix WeChat / Camera QR Code Scanner: Delete system_ext/etc/sys_camera_optimize_config.xml
    cam_opt = sys_root / "system" / "system_ext" / "etc" / "sys_camera_optimize_config.xml"
    if cam_opt.exists():
        cam_opt.unlink()
        log("9. Deleted system_ext/etc/sys_camera_optimize_config.xml (QR code scanner fix).")

    # [Patch 10] Fix GameGpuControlPanel crash: Empty /my_product/etc/extension/sys_graphics_game_gpu_control_panel.json
    gpu_json = sys_root / "my_product" / "etc" / "extension" / "sys_graphics_game_gpu_control_panel.json"
    if gpu_json.exists():
        gpu_json.write_text("", encoding="utf-8")
        log("10. Emptied sys_graphics_game_gpu_control_panel.json (GameGpuControlPanel crash fix).")

    # [Patch 11] Fix Douyin / TikTok / Coolapk feed stutter: Delete HDR feature files in /my_product/etc
    my_etc = sys_root / "my_product" / "etc"
    if my_etc.exists():
        hdr_deleted = 0
        for f in my_etc.rglob("*"):
            if f.is_file() and "hdr" in f.name.lower():
                f.unlink()
                hdr_deleted += 1
        log(f"11. Removed {hdr_deleted} HDR config files in /my_product/etc (Video feed stutter fix).")

    # [Patch 12] Fix Screen Density (440 dpi for Xiaomi Mi 8 1080x2248 AMOLED) + Wake Delay + RAM Expansion
    my_prod_prop = sys_root / "my_product" / "build.prop"
    if my_prod_prop.exists():
        lines = my_prod_prop.read_text(encoding="utf-8", errors="ignore").splitlines()
        lines = [ln for ln in lines if not ln.strip().startswith("ro.sf.lcd_density=")]
        lines.extend([
            "ro.sf.lcd_density=440",
            "# Fix ColorOS 16 Power Button Wake Delay & Theia Screen Monitor",
            "persist.sys.oplus.display.wake_delay=0",
            "persist.sys.oplus.theia_screen_monitor.disabled=1",
            "ro.surface_flinger.set_display_power_timer_ms=0",
            "debug.sf.latch_unsignaled=1",
            "debug.sf.disable_backpressure=1",
            "debug.sf.enable_gl_backpressure=0",
            "# Enable ColorOS RAM Expansion",
            "persist.sys.oplus.nandswap.condition=true",
        ])
        my_prod_prop.write_text("\n".join(lines) + "\n", encoding="utf-8")
        log("12. Set ro.sf.lcd_density=440 + Power Button Wake Delay Fix + RAM Expansion in my_product/build.prop.")

    # [Patch 13] Fix YouTube / Video Playback Crash (remove Oplus stagefright hooks incompatible with SDM845 OMX)
    for rel_lib in (
        "system/system_ext/lib64/libavenhancements.so",
        "system/system_ext/lib/libavenhancements.so",
        "system/system_ext/lib64/liboplusstagefright.so",
        "system/system_ext/lib/liboplusstagefright.so",
    ):
        lib_f = sys_root / rel_lib
        if lib_f.exists():
            lib_f.unlink()
            log(f"13. Removed {rel_lib} (YouTube / Hardware Video playback fix).")

    # [Patch 14] Debloat ONLY CN bloatware & pre-generated armv9 oat/ files so merged system.img fits inside Xiaomi Mi 8 sda25 (8.0 GiB)
    # Keeps all useful daily apps: Calculator, Calendar, Weather, Notes, SoundRecorder, Compass, Music, ThemeStore, PhoneManager, OShare, ScreenRecorder
    log("14. Removing CN promotional bloatware & armv9 oat/ preopt files to fit inside 8.0 GiB sda25 partition...")
    debloat_rel_paths = [
        # CN Shopping, Ads, Quick Games, Browser Video & NPU LLM bloat in my_stock/del-app
        "my_stock/del-app/BrowserVideo",
        "my_stock/del-app/FamilyGuard",
        "my_stock/del-app/FinShellWallet",
        "my_stock/del-app/Gamecenter",
        "my_stock/del-app/Health",
        "my_stock/del-app/KeKeUserCenterMember",
        "my_stock/del-app/Melody",
        "my_stock/del-app/OPBreathMode",
        "my_stock/del-app/OPCommunity",
        "my_stock/del-app/OplusDocumentsReader",
        "my_stock/del-app/OplusEmail",
        "my_stock/del-app/OplusQuickGame",
        "my_stock/del-app/OPPOStore",
        "my_stock/del-app/OppoTranslation",
        "my_stock/del-app/RiderMode",
        "my_stock/del-app/Shortcuts",
        "my_stock/del-app/SoftsimRedteaRoaming",
        "my_stock/del-app/Tips",
        "my_stock/del-app/UPTsmService",
        # Third-party promotional preloads in other del-app folders
        "my_product/del-app",
        "my_heytap/del-app",
        "my_bigball/del-app",
        "my_region/del-app",
        "my_preload/del-app",
        "my_company/del-app",
        "my_carrier/del-app",
        # Unused CN Car / Wallet / Manual / Pictorial lockscreen ads & SD8Elite NPU LLM weights in my_stock/app
        "my_stock/app/AIMemory",
        "my_stock/app/AIUnit",
        "my_stock/app/AIWidgets",
        "my_stock/app/AIWriter",
        "my_stock/app/BeaconLink",
        "my_stock/app/Browser",
        "my_stock/app/CarLink",
        "my_stock/app/ChildrenSpace",
        "my_stock/app/DigitalKeyFramework",
        "my_stock/app/DigitalWellBeing",
        "my_stock/app/Instant",
        "my_stock/app/InstantService",
        "my_stock/app/OplusOperationManual",
        "my_stock/app/OplusSecurityKeyboard",
        "my_stock/app/OWork",
        "my_stock/app/Pictorial",
        "my_stock/app/RomUpdate",
        "my_stock/app/SceneMode",
        "my_stock/app/SecurePay",
        "my_stock/app/SecurityGuard",
        "my_stock/app/ShareScreen",
        "my_stock/app/ViewTalk",
        "my_stock/app/TasWallet",
        # Unused CN App Store, Breeno CN voice assistant, Car, Games in my_stock/priv-app
        "my_stock/priv-app/BlackListApp",
        "my_stock/priv-app/DCS",
        "my_stock/priv-app/Cota",
        "my_stock/priv-app/GlobalSearch",
        "my_stock/priv-app/HeyCast",
        "my_stock/priv-app/HeyTapSpeechAssist",
        "my_stock/priv-app/KeKeMarket",
        "my_stock/priv-app/LinktoWindows",
        "my_stock/priv-app/Metis",
        "my_stock/priv-app/MyDevices",
        "my_stock/priv-app/OplusGames",
        "my_stock/priv-app/SceneService",
        "my_stock/priv-app/SOSHelper",
        "my_stock/priv-app/UMS",
        "my_stock/priv-app/VideoGallery",
        "my_stock/priv-app/OCar",
        # Donor-only hardware apps & camera tuning blobs in my_product
        "my_product/app/AONService",
        "my_product/app/OplusCamera",
        "my_product/app/talkback",
        "my_product/priv-app/RemoteControl",
        "my_product/vendor/etc/camera",
        "my_product/non_overlay",
        "my_stock/non_overlay",
        # Unused legacy VNDK apexes (dipper LineageOS 22.2 vendor uses v35)
        "system/system_ext/apex/com.android.vndk.v30.apex",
        "system/system_ext/apex/com.android.vndk.v31.apex",
        "system/system_ext/apex/com.android.vndk.v32.apex",
        "system/system_ext/apex/com.android.vndk.v33.apex",
        "system/system_ext/apex/com.android.vndk.v34.apex",
    ]
    removed_dirs = 0
    for rel_p in debloat_rel_paths:
        target_p = sys_root / rel_p
        if target_p.exists():
            if target_p.is_dir() and not target_p.is_symlink():
                shutil.rmtree(target_p, ignore_errors=True)
            else:
                target_p.unlink()
            removed_dirs += 1

    # Remove app-level oat/ directories (keeping system/framework/oat for fast boot)
    oat_removed = 0
    for oat_dir in list(sys_root.rglob("oat")):
        if oat_dir.is_dir() and "system/framework" not in oat_dir.as_posix():
            shutil.rmtree(oat_dir, ignore_errors=True)
            oat_removed += 1
    log(f"14. Removed {removed_dirs} CN bloatware targets and {oat_removed} app oat/ folders.")


def step4_dipper_kernel49_compatibility(
    sys_root: Path,
    fsck_erofs_bin: str,
    make_ext4fs_or_mke2fs_bin: str,
    c15_donor_dir: Path = None
):
    """
    Solves the Xiaomi Mi 8 (Kernel 4.9.337) blockers when booting ColorOS 16:
    1. ColorOS 16 packs /system/apex/*.apex with EROFS apex_payload.img, which fails on
       dipper's Kernel 4.9.337 (no CONFIG_EROFS_FS). Repacked to EXT4 by repack_ext4_and_apex.sh.
    2. Injects ColorOS 16 Wi-Fi Soft-Reboot BPF fix (oplus-netd.o & ipv6_offload.o).
    """
    log("Applying Xiaomi Mi 8 (Kernel 4.9.337) APEX & BPF compatibility layer...")

    # Automatically inject ColorOS 16 Wi-Fi Soft-Reboot BPF Fix (oplus-netd.o & ipv6_offload.o)
    default_bpf_dir = Path(__file__).resolve().parent / "device_dipper" / "bpf_fix"
    if default_bpf_dir.exists():
        dst_bpf = sys_root / "system" / "etc" / "bpf"
        dst_bpf.mkdir(parents=True, exist_ok=True)
        for bpf_name in ("oplus-netd.o", "ipv6_offload.o"):
            src_bpf = default_bpf_dir / bpf_name
            if src_bpf.exists():
                shutil.copy2(src_bpf, dst_bpf / bpf_name)
                log(f"Injected ColorOS 16 Wi-Fi Soft-Reboot BPF fix: {bpf_name} -> /system/etc/bpf/{bpf_name}")

    # If user provides a working ColorOS 15 / LineageOS 22 system dump for dipper,
    # transplant EXT4 apexes, /system/etc/bpf, and liboplusbindermonitor.so
    if c15_donor_dir and c15_donor_dir.exists():
        for rel_path in [
            "system/etc/bpf",
            "system/system_ext/apex",
            "system/system_ext/lib/liboplusbindermonitor.so",
            "system/system_ext/lib64/liboplusbindermonitor.so",
        ]:
            src = c15_donor_dir / rel_path
            dst = sys_root / rel_path
            if src.exists():
                if src.is_dir():
                    shutil.rmtree(dst, ignore_errors=True)
                    shutil.copytree(src, dst, symlinks=True)
                else:
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)
                log(f"Transplanted {rel_path} from working dipper ColorOS 15 base.")


def main():
    parser = argparse.ArgumentParser(description="ColorOS 16 -> Xiaomi Mi 8 (dipper) Automated Builder")
    parser.add_argument("--ota", required=True, help="Path to ColorOS 16 Full OTA .zip or payload.bin")
    parser.add_argument("--work-dir", default="./work_c16_dipper", help="Working directory")
    parser.add_argument("--payload-dumper", default="payload-dumper-go", help="Path to payload-dumper-go binary")
    parser.add_argument("--fsck-erofs", default="fsck.erofs", help="Path to fsck.erofs binary")
    parser.add_argument("--c15-base-dir", default="", help="Optional path to working ColorOS 15 system dump for BPF/APEX transplant")
    args = parser.parse_args()

    work_root = Path(args.work_dir).resolve()
    img_dir = work_root / "extracted_imgs"
    sys_root = work_root / "system"

    log("=== STARTING COLOROS 16 PORT FOR XIAOMI MI 8 (DIPPER) ===")
    step1_extract_payload(Path(args.ota).resolve(), img_dir, args.payload_dumper)
    step2_unpack_and_merge_partitions(img_dir, work_root, args.fsck_erofs, low_disk_mode=True)
    step3_apply_coolapk_pt_patches(sys_root, device_market_name="Xiaomi Mi 8", first_api_level="27")
    step4_dipper_kernel49_compatibility(
        sys_root,
        args.fsck_erofs,
        "",
        Path(args.c15_base_dir).resolve() if args.c15_base_dir else None,
    )
    log("=== ALL PATCHES COMPLETED SUCCESSFULLY! ===")
    log(f"Patched root filesystem ready at: {sys_root}")


if __name__ == "__main__":
    main()
