#!/vendor/bin/sh

NIGGA="/vendor/bin/resetprop"

sleep 0.5

if [ -f "$NIGGA" ]; then
    # Hook properties
    $NIGGA vendor.display.fence_timeout 50
    $NIGGA debug.sf.fence_timeout 50
    $NIGGA vendor.gralloc.fence_timeout 50
    $NIGGA vendor.display.panel_cmd_timeout 50

    # Force SurfaceFlinger to wake instantly
    $NIGGA debug.sf.latch_unsignaled 1
    $NIGGA debug.sf.disable_backpressure 1
    $NIGGA debug.sf.enable_gl_backpressure 0

    # ColorOS / Oplus specific wake delay killers
    $NIGGA persist.sys.oplus.display.wake_delay 0
    $NIGGA ro.surface_flinger.set_display_power_timer_ms 0
    $NIGGA debug.sf.early_phase_offset_ns 0
    $NIGGA debug.sf.early_app_phase_offset_ns 0
    $NIGGA debug.sf.early_gl_phase_offset_ns 0
    $NIGGA debug.sf.early_gl_app_phase_offset_ns 0
fi
