//! twintape: a menu-bar app with a chromeless pill HUD instead of a
//! titled window.
//!
//! Three windows. `main` (label "main") IS the pill: the OS-required
//! startup window, shrunk from V1's 320x190 titled window to a thin
//! (120x8) chromeless, transparent, always-on-top, never-activated
//! strip anchored bottom-center - gray idle, red recording. `overlay`
//! is the recording border (transparent + always_on_top +
//! click_through + activate_on_show = false), unchanged from before.
//! `panel` is the expanded control surface (220x64: status, elapsed,
//! Grabar/Detener, "Abrir grabaciones"), a model-declared secondary
//! window that appears "presence = visibility" style (see the overlay)
//! only while `model.hud_hovering` - hovering the pill
//! (`on_hover_enter`) sets that flag, which shows `panel`. The STARTUP
//! window is NEVER un-declared (only `windows_fn`-declared windows can
//! be), so it stays alive and hoverable underneath while the panel is
//! open. Closing is NOT `on_hover_leave` (see `hud_collapse_timer_key`
//! for why that handler is dead on macOS): a timer armed off every
//! raw pointer event seen in either canvas collapses the panel after
//! `hud_collapse_grace_ms` of quiet. Both the pill and the panel are
//! click_through = false so they receive the hover/press events the
//! mechanic needs - unlike the overlay border, which stays
//! click-through so it never steals clicks from whatever is under it.
//!
//! Known SDK gaps (see README), the second found the hard way (a
//! screenshot showing nothing where the pill should be, twice, for two
//! different reasons):
//! - No screen-bounds query, so window geometry that must match the
//!   display defaults to a hardcoded oversized/centered guess. `dev.sh`
//!   measures the real screen size and passes it in via
//!   TWINTAPE_SCREEN_W/H env vars (see loadOverlayGeometryFromEnv),
//!   which the overlay AND `panel`'s anchor read - but NOT the pill
//!   (next point).
//! - The pill's position cannot be env-computed at all, because it is
//!   the STARTUP window and app.zon declares `.shell.windows`: on that
//!   path `native dev` resolves the whole create-time frame - x, y,
//!   width, height, and every overlay flag - from app.zon alone,
//!   comptime (`app_runner/root.zig`'s `manifestWindow`, called from
//!   `RunOptions.appInfo`'s `windows.len > 0` branch). `main()`'s own
//!   `RunOptions.default_frame`/`.restore_state` are DEAD on this path
//!   - they only apply in the OTHER branch, when app.zon declares NO
//!   `.windows` at all. This one cost two real, wrong screenshots
//!   before landing: first the STARTUP window kept its stale V1
//!   1x1/click-through/not-always-on-top flags because app.zon was
//!   never updated after the pill/panel redesign (an invisible 1x1
//!   window sitting BEHIND ordinary windows, confirmed via
//!   `CGWindowListCopyWindowInfo`'s `kCGWindowLayer = 0` instead of the
//!   floating level `always_on_top` should have produced); after fixing
//!   that, the pill appeared at the top of the screen instead of the
//!   bottom, because `hudY` returned `overlay_height - height` under a
//!   wrong top-left-origin assumption for a bottom-left-origin AppKit
//!   window (`y` grows UP from the screen's bottom, so "near the
//!   bottom" is a SMALL y, not a large one) - AND that function's
//!   result was being read into a `RunOptions.default_frame` argument
//!   that this whole gap makes unreachable in the first place. app.zon
//!   below hardcodes `x`/`y` for a 1512x982 screen (this machine's
//!   primary display in points) as the honest, static, correct-today
//!   fallback: no live substitution channel exists for a manifest
//!   field the way TWINTAPE_SCREEN_W/H patches the border overlay's
//!   RUNTIME geometry, so a different screen size ships this
//!   off-anchor until the SDK grows either manifest env-substitution
//!   or a runtime window-move call.
//! - Separately, and still real for `panel`: on macOS a
//!   `windows_fn`-declared window's `x`/`y` is only honored when
//!   `restore_state = true` - appkit_host.m's `createWindowWithId:`
//!   builds `NSMakeRect(0, 0, w, h)` and cascades the frame off the
//!   current key window whenever `restoreFrame` is false, silently
//!   discarding `x`/`y`. `windows_fn`'s reconcile (`ui_app.zig`
//!   `createWindowSlot`) hardcodes `restore_state = false` for EVERY
//!   model-declared window with no override in `WindowDescriptor` - so
//!   THAT path can never honor a computed x/y on macOS at all. `panel`
//!   still rides it and would cascade if opened cold; it reads fine in
//!   practice only because it always opens flush against the pill's
//!   already-correct bottom edge, so nothing ever depends on its own
//!   descriptor x/y landing where declared.
//! - No way to reposition or resize an already-created
//!   `windows_fn`-declared window from Zig at all: the reconcile only
//!   creates newly-declared windows and closes ones leaving the set -
//!   a window whose label stays declared keeps its creation-time frame
//!   forever even if the descriptor's width/height/x/y change on a
//!   later rebuild. This is why `panel` is its own window rather than
//!   the pill resized in place on hover.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const twintape_log = std.log.scoped(.twintape);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "main-canvas";
// The startup window ("main") IS the pill (see file doc) - one label,
// one identity, so `pill_label` is `window_label`, not a second window.
pub const window_label = "main";
pub const pill_label = window_label;
pub const pill_canvas_label = canvas_label;
pub const overlay_label = "overlay";
pub const overlay_canvas_label = "overlay-canvas";
pub const panel_label = "panel";
pub const panel_canvas_label = "panel-canvas";

// No SDK API returns the real primary-display frame (see README gap
// note), so window geometry that must match the display defaults to a
// hardcoded oversized/centered guess anchored at the origin. `dev.sh`
// measures the real screen size in points (AppleScript `bounds of
// window of desktop`) and exports TWINTAPE_SCREEN_W/TWINTAPE_SCREEN_H;
// `overlay_width`/`overlay_height` already hold that real screen size
// (the border overlay spans the whole display), so the pill/panel
// anchor below reuses them directly instead of a second env read.
const default_overlay_width: f32 = 3000;
const default_overlay_height: f32 = 2000;
const default_border_thickness: f32 = 3;

var overlay_width: f32 = default_overlay_width;
var overlay_height: f32 = default_overlay_height;
var border_thickness: f32 = default_border_thickness;

// Pill: a small stadium peeking up from the bottom edge, resting flush
// against the bottom of the screen. Panel: the expanded control
// surface, sharing the pill's horizontal center and its bottom edge,
// growing upward on hover. Both are stadiums (radius = height / 2,
// never less) - maca's FloatingPill language, ported to canvas: black
// 0.95 + a 1px white-15% hairline stands in for glass/backdrop-blur,
// which this GPU canvas has no primitive for.
pub const pill_width: f32 = 64;
pub const pill_height: f32 = 12;
pub const pill_radius: f32 = pill_height / 2;
pub const panel_width: f32 = 260;
pub const panel_height: f32 = 32;
pub const panel_radius: f32 = panel_height / 2;

fn hudX(width: f32) f32 {
    return (overlay_width - width) / 2;
}

// Both windows share the same bottom edge (the screen's bottom, plus a
// small margin so the pill's rounded corners are not clipped by the
// display edge) so the panel visually grows UP from the pill's seam
// instead of the anchor jumping between the two sizes. AppKit's window
// origin is BOTTOM-left (y grows upward), so "near the bottom edge"
// means a SMALL y, not `overlay_height - height` (that lands near the
// TOP - the sign flip a top-left-origin mental model gets wrong; caught
// by an actual screenshot showing the pill at y=33 from the top instead
// of the bottom, see README).
const hud_bottom_margin: f32 = 4;

fn hudY(height: f32) f32 {
    _ = height;
    return hud_bottom_margin;
}

// ------------------------------------------------------- session storage
//
// V3 writes two WAV tracks per recording into a timestamped session
// directory. Both the `Io` and the home directory come from
// `std.process.Init` in `main` (an `update` only receives `fx`, which
// exposes neither), so they are captured at startup the same way the
// overlay geometry above is. Tests leave them null and drive
// `update` directly: `sessionDirFor` then falls back to a temp root,
// so no test touches the real Application Support tree.
var process_io: ?std.Io = null;
var home_dir: ?[]const u8 = null;

/// Where a session directory is rooted. Real runs put it under
/// Application Support (the macOS convention for app-owned data the
/// user did not choose a location for); without a HOME it degrades to
/// /tmp rather than failing the recording.
pub fn sessionRoot(buffer: []u8) []const u8 {
    const home = home_dir orelse return std.fmt.bufPrint(buffer, "/tmp/twintape", .{}) catch "/tmp/twintape";
    return std.fmt.bufPrint(buffer, "{s}/Library/Application Support/twintape", .{home}) catch "/tmp/twintape";
}

/// `YYYY-MM-DD-HHMMSS` for `wall_ms`, the SDK clock's reading (never
/// `std.time.timestamp()` — the whole point of `fx.wallMs` is that a
/// session replay feeds back the recorded value). Local time: this
/// names a folder a human browses, so it should match the wall clock
/// they were looking at while recording.
pub fn formatSessionStamp(buffer: []u8, wall_ms: i64) []const u8 {
    const epoch_s: i64 = @divFloor(wall_ms, 1000);
    const local_s = epoch_s + localUtcOffsetSeconds(epoch_s);
    const day_s: i64 = @divFloor(local_s, std.time.s_per_day);
    const secs_into_day: u64 = @intCast(local_s - day_s * std.time.s_per_day);
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(day_s) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        @divTrunc(secs_into_day, 3600),
        @divTrunc(@mod(secs_into_day, 3600), 60),
        @mod(secs_into_day, 60),
    }) catch "session";
}

// POSIX `struct tm` and `localtime_r`, declared here because Zig 0.16's
// std exposes no timezone API and no `tm` binding. Only `tm_gmtoff` is
// read (seconds east of UTC, including DST), so the layout matters only
// up to that field - it is declared in full anyway to keep the struct
// the size libc expects to write into.
const CTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(timer: *const i64, result: *CTm) ?*CTm;

/// Seconds to add to a UTC epoch second to get local wall time, for the
/// epoch second `utc_s`. Zig 0.16's `std.time` is constants and epoch
/// math only - no clock reader and no timezone - so the offset comes
/// from libc against a moment the caller already has (the SDK clock's
/// reading), never from a second clock source.
pub fn localUtcOffsetSeconds(utc_s: i64) i64 {
    var when: i64 = utc_s;
    var tm: CTm = std.mem.zeroes(CTm);
    if (localtime_r(&when, &tm) == null) return 0;
    return @intCast(tm.tm_gmtoff);
}

/// The outcome of naming (and, in a real run, creating) a session
/// directory. `unbound` is the test path: no `Io` was ever bound, so
/// nothing was attempted and nothing failed - only a real `mkdir`
/// refusal is a `failed`, which is what stops a recording.
pub const SessionDirStatus = enum { created, unbound, failed };

/// Builds `<root>/<stamp>` and creates it on disk when a real `Io` is
/// bound. Returns the path in every case so the model can always name
/// where a recording was meant to land.
pub fn sessionDirFor(buffer: []u8, wall_ms: i64) struct { path: []const u8, status: SessionDirStatus } {
    var root_buffer: [512]u8 = undefined;
    var stamp_buffer: [32]u8 = undefined;
    const root = sessionRoot(&root_buffer);
    const stamp = formatSessionStamp(&stamp_buffer, wall_ms);
    const path = std.fmt.bufPrint(buffer, "{s}/{s}", .{ root, stamp }) catch return .{ .path = "", .status = .failed };
    const io = process_io orelse return .{ .path = path, .status = .unbound };
    std.Io.Dir.cwd().createDirPath(io, path) catch return .{ .path = path, .status = .failed };
    return .{ .path = path, .status = .created };
}

fn parseEnvF32(environ_map: *const std.process.Environ.Map, key: []const u8) ?f32 {
    const raw = environ_map.get(key) orelse return null;
    return std.fmt.parseFloat(f32, raw) catch null;
}

/// Reads TWINTAPE_SCREEN_W/H and TWINTAPE_BORDER from `init.environ_map`
/// (std.process.Init) into the module-level overlay geometry, falling
/// back to the hardcoded defaults when unset or unparsable.
pub fn loadOverlayGeometryFromEnv(environ_map: *const std.process.Environ.Map) void {
    overlay_width = parseEnvF32(environ_map, "TWINTAPE_SCREEN_W") orelse default_overlay_width;
    overlay_height = parseEnvF32(environ_map, "TWINTAPE_SCREEN_H") orelse default_overlay_height;
    border_thickness = parseEnvF32(environ_map, "TWINTAPE_BORDER") orelse default_border_thickness;
}

pub const toggle_command = "app.toggle_recording";
pub const quit_command = "app.quit";

// Transparent (premultiplied alpha, matching the auto-selection
// `UiApp.WindowDescriptor` applies for secondary windows - see
// docs/windows#overlay-windows) so only the pill's own painted shape
// shows, not a rectangular canvas.
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Twintape status", .accessibility_label = "Twintape status", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .premultiplied, .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = window_label,
    .title = "Twintape",
    .width = pill_width,
    .height = pill_height,
    // Position comes from `main()`'s `RunOptions.default_frame` /
    // `.restore_state`, not from here (see file doc's position gap) -
    // `restore_state` below is a separate host-side flag from the one
    // in RunOptions and stays false; app.zon mirrors these create-time
    // fields for the host's pre-scene create per docs/app-zon.
    .restore_state = false,
    // The menu-bar-app shape: the red close button HIDES the window
    // instead of quitting; the tray "Grabar/Detener" row keeps working
    // and only the tray "Salir" row (fx.quitApp) really quits. See
    // docs/tray#the-menu-bar-app-lifecycle and examples/menu-bar.
    .close_policy = .hide,
    // The V1 titled window is gone: this IS the pill now (see file
    // doc) - chromeless, transparent, always-on-top, never activated.
    // click_through stays false (unlike the border overlay) because
    // the pill must receive the hover that opens the panel.
    .titlebar = .chromeless,
    .transparent = true,
    .always_on_top = true,
    .click_through = false,
    .activate_on_show = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const RecordingState = enum { idle, recording };

/// How the last capture ended, for the status item. `.none` while
/// nothing has gone wrong; a failure parks here so the menu-bar title
/// can say so instead of leaving a stale recording indicator up.
pub const CaptureFault = enum {
    none,
    permission_denied,
    device_busy,
    disk_full,
    unsupported,
    rejected,
    no_session_dir,

    pub fn label(fault: CaptureFault) []const u8 {
        return switch (fault) {
            .none => "twintape",
            .permission_denied => "twintape (sin permiso)",
            .device_busy => "twintape (micro ocupado)",
            .disk_full => "twintape (disco lleno)",
            .unsupported => "twintape (no soportado)",
            .rejected => "twintape (rechazado)",
            .no_session_dir => "twintape (sin carpeta)",
        };
    }
};

pub const Model = struct {
    state: RecordingState = .idle,
    started_at_ms: i64 = 0,
    now_ms: i64 = 0,
    /// The session directory of the capture in flight, and the two
    /// track paths inside it. Owned inline (not a slice into scratch)
    /// because `fx.audioCapture` copies at call time but the status
    /// item and the tests read them afterwards.
    session_dir_buffer: [640]u8 = undefined,
    session_dir_len: usize = 0,
    mic_path_buffer: [640]u8 = undefined,
    mic_path_len: usize = 0,
    system_path_buffer: [640]u8 = undefined,
    system_path_len: usize = 0,
    capture_started: bool = false,
    fault: CaptureFault = .none,
    last_bytes_written: u64 = 0,
    last_duration_ms: u64 = 0,
    /// The pill/panel swap: false shows the pill, true shows the
    /// expanded panel. Set by `on_hover_enter`; cleared by
    /// `hud_collapse_timer_key` firing (see that key's doc) - never by
    /// `on_hover_leave`, which macOS never delivers for either window.
    hud_hovering: bool = false,
    /// The recording dot's pulse phase: true = full opacity, false =
    /// dimmed. Flips on every `elapsed_timer_key` tick (1000ms), which
    /// is already running the whole time recording is active - no
    /// second timer for a purely decorative animation. A 1000ms half-
    /// cycle (2000ms full cycle) rather than the visual spec's 1.6s:
    /// close enough for a glance-only cue, and free.
    dot_pulse_bright: bool = true,

    pub fn sessionDir(model: *const Model) []const u8 {
        return model.session_dir_buffer[0..model.session_dir_len];
    }
    pub fn micPath(model: *const Model) []const u8 {
        return model.mic_path_buffer[0..model.mic_path_len];
    }
    pub fn systemPath(model: *const Model) []const u8 {
        return model.system_path_buffer[0..model.system_path_len];
    }

    pub fn elapsedMs(model: *const Model) i64 {
        if (model.state != .recording) return 0;
        const delta = model.now_ms - model.started_at_ms;
        return if (delta > 0) delta else 0;
    }

    /// Minutes/seconds pair for the elapsed time, always non-negative -
    /// formatting is the caller's job (a view formats through the
    /// arena via `ui.fmt`; `statusItem` formats into its own
    /// app-owned scratch buffer - neither borrows a stack local, whose
    /// lifetime does not survive to when the tree is finalized).
    pub fn elapsedParts(model: *const Model) struct { mins: u64, secs: u64 } {
        const total_s = @divTrunc(model.elapsedMs(), 1000);
        return .{
            .mins = @intCast(@divTrunc(total_s, 60)),
            .secs = @intCast(@mod(total_s, 60)),
        };
    }
};

pub const Msg = union(enum) {
    toggle_recording,
    quit,
    tick: native_sdk.EffectTimer,
    capture_event: native_sdk.EffectAudioCapture,
    hud_hover_enter,
    hud_hover_leave,
    /// A raw pointer event landed inside the pill or panel's canvas
    /// (see `globalHotkeyEventFn`, the interception seam this rides).
    /// Re-arms `hud_collapse_timer_key` — see that key's doc for why
    /// this exists at all: `on_hover_leave` never fires for either
    /// window on macOS.
    hud_pointer_seen,
    hud_collapse_timer: native_sdk.EffectTimer,
    open_recordings,
    open_recordings_exit: native_sdk.EffectExit,

    pub const view_unbound = .{ "tick", "capture_event", "hud_collapse_timer", "open_recordings_exit" };
};

const TwintapeApp = native_sdk.UiApp(Model, Msg);
pub const Effects = TwintapeApp.Effects;

pub const elapsed_timer_key: u64 = 1;
/// Capture keys are their own namespace (see docs/audio-capture), so
/// this may share the number with the timer without colliding.
pub const capture_key: u64 = 1;
/// Spawn keys share the same namespace as capture/timer keys but are a
/// separate effect kind, so 1 is free here too.
pub const open_recordings_key: u64 = 1;
/// Timer keys are their own namespace too, so this may share the
/// number with `elapsed_timer_key` without colliding.
///
/// SDK gap: neither the pill nor the panel window ever becomes macOS
/// key window (`activate_on_show = false`, required so hovering the
/// pill never steals focus from whatever app the user is in). AppKit's
/// `NSTrackingArea` mouse-exited notifications are gated by
/// `NSTrackingActiveInKeyWindow` (appkit_host.m's
/// `updateSurfaceTrackingArea`), so `mouseExited:` — the ONLY source
/// of `pointer_cancel` on this host — never fires for a non-key
/// window. `on_hover_leave` (bound on the panel's whole surface, see
/// `panelView`) is consequently dead code on macOS for this app: it
/// never dispatches, `hud_hovering` never clears, and the panel stays
/// expanded forever once opened (confirmed live: moved the pointer to
/// a corner of the screen, waited, panel still open). `mouseMoved:`
/// has no such gate (`acceptsMouseMovedEvents` is set directly on the
/// window), so `.hover`-phase pointer events keep arriving normally —
/// this timer is armed from THOSE, not from any leave signal, because
/// no leave signal reaches the app at all.
///
/// Plan B: every raw pointer event this app's `canvas_widget_pointer`
/// interception sees inside the pill or panel canvas re-arms this
/// ONE-SHOT timer for `hud_collapse_grace_ms` (`startTimer` on an
/// already-active key replaces it — the SDK's own debounce
/// primitive). No fresh pointer activity in the HUD for that long
/// collapses it unconditionally. This trades a strict "leave the
/// exact hit region" edge for "went quiet" — a stationary hover for
/// longer than the grace period also collapses, which is the explicit
/// tradeoff the mission asked for over ever staying stuck open.
pub const hud_collapse_timer_key: u64 = 2;
pub const hud_collapse_grace_ms: u64 = 600;

/// (Re-)arms the collapse timer. `startTimer` on an already-active key
/// replaces it in place (see the SDK doc on `StartTimerOptions.key`),
/// so calling this on every `hud_hover_enter` AND every observed
/// pointer event pushes the deadline out instead of stacking timers.
fn armHudCollapseTimer(fx: *Effects) void {
    fx.startTimer(.{
        .key = hud_collapse_timer_key,
        .interval_ms = hud_collapse_grace_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.hud_collapse_timer),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .toggle_recording => {
            switch (model.state) {
                .idle => {
                    model.state = .recording;
                    model.started_at_ms = fx.wallMs();
                    model.now_ms = model.started_at_ms;
                    model.fault = .none;
                    model.capture_started = false;
                    model.last_bytes_written = 0;
                    model.last_duration_ms = 0;
                    model.dot_pulse_bright = true;

                    // One session directory per recording, named by the
                    // SDK clock so a replay reproduces the same name.
                    const session = sessionDirFor(&model.session_dir_buffer, model.started_at_ms);
                    model.session_dir_len = session.path.len;
                    const mic = std.fmt.bufPrint(&model.mic_path_buffer, "{s}/mic.wav", .{session.path}) catch "";
                    model.mic_path_len = mic.len;
                    const system = std.fmt.bufPrint(&model.system_path_buffer, "{s}/system.wav", .{session.path}) catch "";
                    model.system_path_len = system.len;

                    if (session.status == .failed) {
                        // The directory could not be created, so the
                        // two tracks have nowhere to land. Fail here
                        // rather than ask the platform to write into a
                        // missing path and then sit "recording" while
                        // nothing is captured.
                        model.state = .idle;
                        model.fault = .no_session_dir;
                        return;
                    }

                    fx.startTimer(.{
                        .key = elapsed_timer_key,
                        .interval_ms = 1000,
                        .mode = .repeating,
                        .on_fire = Effects.timerMsg(.tick),
                    });
                    fx.audioCapture(.{
                        .key = capture_key,
                        .mic_path = model.micPath(),
                        .system_path = model.systemPath(),
                        .on_event = Effects.audioCaptureMsg(.capture_event),
                    });
                },
                .recording => {
                    model.state = .idle;
                    fx.cancelTimer(elapsed_timer_key);
                    // The `.stopped` event reports the totals; the
                    // model goes idle now so the overlay drops on the
                    // keypress rather than a flush later.
                    fx.stopAudioCapture(capture_key);
                },
            }
        },
        .quit => fx.quitApp(),
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            if (model.state != .recording) return;
            model.now_ms = fx.wallMs();
            model.dot_pulse_bright = !model.dot_pulse_bright;
        },
        .capture_event => |event| {
            switch (event.kind) {
                .started => model.capture_started = true,
                // Meters are for a level UI twintape does not draw yet.
                .level => {},
                .stopped => {
                    model.capture_started = false;
                    model.last_bytes_written = event.bytes_written;
                    model.last_duration_ms = event.duration_ms;
                },
                // A capture that failed is not a recording. Drop the
                // model back to idle (which also drops the overlay, so
                // the border never outlives the capture) and park the
                // reason where the status item shows it.
                .failed => {
                    model.state = .idle;
                    model.capture_started = false;
                    model.fault = switch (event.reason) {
                        .permission_denied => .permission_denied,
                        .device_busy => .device_busy,
                        .disk_full => .disk_full,
                        .unsupported => .unsupported,
                    };
                    fx.cancelTimer(elapsed_timer_key);
                },
                .rejected => {
                    model.state = .idle;
                    model.capture_started = false;
                    model.fault = .rejected;
                    fx.cancelTimer(elapsed_timer_key);
                },
            }
        },
        .hud_hover_enter => {
            model.hud_hovering = true;
            armHudCollapseTimer(fx);
        },
        .hud_hover_leave => {
            // Dead on macOS today (see `hud_collapse_timer_key`'s
            // doc), kept as the correct handler for a host that DOES
            // deliver the leave, and exercised directly by the test
            // harness's `dispatchPlatformEvent` (which sends the Msg
            // through the same widget-hover pipeline `on_hover_leave`
            // wires to, not a raw platform mouse-exit).
            model.hud_hovering = false;
            fx.cancelTimer(hud_collapse_timer_key);
        },
        .hud_pointer_seen => armHudCollapseTimer(fx),
        .hud_collapse_timer => |timer| {
            if (timer.outcome != .fired) return;
            model.hud_hovering = false;
        },
        .open_recordings => {
            var root_buffer: [512]u8 = undefined;
            const root = sessionRoot(&root_buffer);
            fx.spawn(.{
                .key = open_recordings_key,
                .argv = &.{ "open", root },
                .on_exit = Effects.exitMsg(.open_recordings_exit),
            });
        },
        // Fire-and-forget: `open` succeeding or failing changes nothing
        // in the model, but the arm exists (rather than dropping the
        // exit silently) so a stalled/duplicate spawn shows up in logs
        // instead of the effect looking unhandled.
        .open_recordings_exit => |exit| {
            if (exit.reason != .exited or exit.code != 0) {
                twintape_log.warn("open recordings folder failed: {s} (code {d})", .{ @tagName(exit.reason), exit.code });
            }
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);

/// The startup window's content: the pill itself (see file doc).
/// `ui.panel` (not `.column`) so the SDK's own control chrome draws the
/// fill + hairline stroke (`widget_render_surfaces.emitPanelWidgetChrome`
/// - fillRoundedRect then strokeRect, both at `widget.style.radius`);
/// a stack-layout container centers its one child (the dot) with no
/// extra row/column nesting needed at this size. `on_hover_enter` on
/// the panel widget itself is the entire hover-open mechanic: the
/// runtime hit-tests the window's full content, so hovering anywhere
/// on the pill dispatches the switch to the expanded panel.
pub fn view(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.panel(.{
        .on_hover_enter = .hud_hover_enter,
        .main = .center,
        .cross = .center,
        .style = hud_material,
    }, .{
        statusDot(ui, model, dot_diameter),
    });
}

/// The overlay's whole content: a red frame `border_thickness` points
/// thick around the transparent window. A `stack` panel paints its
/// FULL area regardless of children (children never punch a hole in an
/// ancestor's fill), so the frame is built as four painted bands
/// (nine-slice) around one truly EMPTY center cell - no widget there
/// at all, so the transparent window's alpha-zero clear shows through
/// (docs/windows: `UiApp.WindowDescriptor` selects an alpha-zero canvas
/// clear automatically for a transparent window).
///
/// `WidgetStyle.radius` is a single scalar applied to all four corners
/// of ITS OWN widget (no per-corner control in this SDK version), so
/// the top band cannot just get a radius - that would round its
/// bottom-inner corners too, notching into the frame. Instead the top
/// band splits into a straight middle strip plus two small rounded
/// corner squares (radius = corner_size, a quarter circle) at each
/// end; the left/right/bottom bands stay straight rows/columns, giving
/// rounded top corners and sharp bottom corners as requested.
fn overlayContent(ui: *AppUi) AppUi.Node {
    const corner_size = border_thickness * 4;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .height = corner_size, .gap = 0 }, .{
            ui.column(.{ .width = corner_size, .height = corner_size, .style_tokens = .{ .background = .destructive }, .style = .{ .radius = corner_size } }, .{}),
            ui.column(.{ .grow = 1, .height = border_thickness, .style_tokens = .{ .background = .destructive } }, .{}),
            ui.column(.{ .width = corner_size, .height = corner_size, .style_tokens = .{ .background = .destructive }, .style = .{ .radius = corner_size } }, .{}),
        }),
        ui.row(.{ .grow = 1, .gap = 0 }, .{
            ui.column(.{ .width = border_thickness, .style_tokens = .{ .background = .destructive } }, .{}),
            ui.spacer(1),
            ui.column(.{ .width = border_thickness, .style_tokens = .{ .background = .destructive } }, .{}),
        }),
        ui.row(.{ .height = border_thickness, .style_tokens = .{ .background = .destructive } }, .{}),
    });
}

const pill_idle_color = canvas.Color.rgba8(120, 120, 128, 235);
const pill_recording_color = canvas.Color.rgba8(220, 38, 38, 235);
const pill_radius: f32 = 6;

/// The expanded panel: status, elapsed, the Grabar/Detener toggle, and
/// "Abrir grabaciones". `on_hover_leave` on the whole surface switches
/// back to the pill the instant the pointer exits (see file doc) - no
/// dwell, no dedicated close button, matching how the pill opened it.
fn panelView(ui: *AppUi, model: *const Model) AppUi.Node {
    const status_text = switch (model.state) {
        .idle => "Listo",
        .recording => "Grabando",
    };
    const elapsed_text = blk: {
        if (model.state != .recording) break :blk "00:00";
        const parts = model.elapsedParts();
        break :blk ui.fmt("{d:0>2}:{d:0>2}", .{ parts.mins, parts.secs });
    };
    return ui.column(.{
        .gap = 8,
        .padding = 12,
        .on_hover_leave = .hud_hover_leave,
        .style = .{ .background = canvas.Color.rgba8(24, 24, 27, 245), .radius = 14 },
    }, .{
        ui.row(.{ .gap = 8 }, .{
            ui.text(.{ .style = .{ .foreground = canvas.Color.rgb8(255, 255, 255) } }, status_text),
            ui.spacer(1),
            ui.text(.{ .style = .{ .foreground = canvas.Color.rgb8(161, 161, 170) } }, elapsed_text),
        }),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = if (model.state == .recording) .destructive else .primary, .size = .sm, .on_press = .toggle_recording }, if (model.state == .recording) "Detener" else "Grabar"),
            ui.button(.{ .variant = .outline, .size = .sm, .on_press = .open_recordings }, "Abrir grabaciones"),
        }),
    });
}

/// Dispatches each declared SECONDARY window's content by label (the
/// pill is the startup window and uses `view` above, not this). Only
/// `panel` and `overlay` are ever `windows_fn`-declared.
pub fn windowView(ui: *AppUi, model: *const Model, window_label_arg: []const u8) AppUi.Node {
    if (std.mem.eql(u8, window_label_arg, panel_label)) return panelView(ui, model);
    return overlayContent(ui);
}

// -------------------------------------------------------- secondary window

/// The panel plus the recording border - the pill is the startup
/// window (see file doc) and is never declared here; it is always
/// alive on its own. Presence is visibility for both of these (like
/// the pill/panel split itself): the panel only while
/// `model.hud_hovering`, the border only while recording. click_through
/// stays false on the panel - like the pill, it must receive the
/// hover/press events the mechanic runs on - unlike the overlay.
pub fn windows(model: *const Model, scratch: *TwintapeApp.WindowsScratch) []const TwintapeApp.WindowDescriptor {
    var count: usize = 0;

    if (model.hud_hovering) {
        scratch.windows[count] = .{
            .label = panel_label,
            .canvas_label = panel_canvas_label,
            .title = "Twintape",
            .width = panel_width,
            .height = panel_height,
            .x = hudX(panel_width),
            .y = hudY(panel_height),
            .resizable = false,
            .titlebar = .chromeless,
            .transparent = true,
            .always_on_top = true,
            .click_through = false,
            .activate_on_show = false,
        };
        count += 1;
    }

    if (model.state == .recording) {
        scratch.windows[count] = .{
            .label = overlay_label,
            .canvas_label = overlay_canvas_label,
            .title = "Twintape Overlay",
            .width = overlay_width,
            .height = overlay_height,
            .x = 0,
            .y = 0,
            .resizable = false,
            .titlebar = .chromeless,
            .transparent = true,
            .always_on_top = true,
            .click_through = true,
            .activate_on_show = false,
        };
        count += 1;
    }

    return scratch.windows[0..count];
}

// -------------------------------------------------------------- commands

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, toggle_command)) return .toggle_recording;
    if (std.mem.eql(u8, name, quit_command)) return .quit;
    return null;
}

/// Model-driven status item: the line of state, the Grabar/Detener
/// toggle, and Salir. Title carries the elapsed time while recording so
/// the menu bar itself is the always-visible indicator (the overlay
/// border is the screen-wide one).
pub fn statusItem(model: *const Model, scratch: *TwintapeApp.StatusItemScratch) TwintapeApp.StatusItemState {
    const title = switch (model.state) {
        // A fault outranks the plain idle title: a capture that failed
        // must not look like a clean stop.
        .idle => std.fmt.bufPrint(&scratch.title_buffer, "{s}", .{model.fault.label()}) catch "twintape",
        .recording => blk: {
            const parts = model.elapsedParts();
            break :blk std.fmt.bufPrint(&scratch.title_buffer, "\u{25CF} {d:0>2}:{d:0>2}", .{ parts.mins, parts.secs }) catch "twintape";
        },
    };
    scratch.items[0] = .{ .id = 1, .label = switch (model.state) {
        .idle => "Grabar",
        .recording => "Detener",
    }, .command = toggle_command };
    scratch.items[1] = .{ .separator = true };
    scratch.items[2] = .{ .id = 2, .label = "Salir", .command = quit_command };
    return .{ .title = title, .items = scratch.items[0..3] };
}

pub const status_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Grabar", .command = toggle_command },
    .{ .separator = true },
    .{ .id = 2, .label = "Salir", .command = quit_command },
};

pub fn options() TwintapeApp.Options {
    return .{
        .name = "twintape",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .view = view,
        .on_command = command,
        .windows_fn = windows,
        .window_view = windowView,
        .status_item = .{
            .title = "twintape",
            .tooltip = "Twintape",
            .items = &status_items,
        },
        .status_item_fn = statusItem,
    };
}

// -------------------------------------------------------------------- app

pub fn initialModel() Model {
    return .{};
}

pub const global_hotkey_toggle_id = "toggle-rec";

/// `UiApp` has no `on_global_hotkey` hook (global hotkeys are not
/// window-addressed, so they cannot ride the `on_command` seam the way
/// shortcuts do - see docs/global-hotkeys). This thin wrapper around
/// `TwintapeApp.app()` is the seam instead: it intercepts
/// `Event.global_hotkey` and dispatches straight into the same
/// `toggle_recording` Msg the tray's Grabar/Detener row already sends.
///
/// It is also the seam `hud_collapse_timer_key` rides (see that key's
/// doc for the why): every `Event.canvas_widget_pointer` landing on
/// the pill or panel's canvas dispatches `hud_pointer_seen` here
/// BEFORE falling through, so the collapse timer re-arms off the same
/// raw event stream `UiApp`'s own hover/press handling consumes right
/// after — this never competes with or replaces that handling, it
/// only observes it. Every other event falls through to the inner
/// `event_fn` unchanged.
pub fn hudEventFn(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
    const app_state: *TwintapeApp = @ptrCast(@alignCast(context));
    switch (event_value) {
        .global_hotkey => |hotkey| {
            if (std.mem.eql(u8, hotkey.id, global_hotkey_toggle_id)) {
                try app_state.dispatch(runtime, app_state.canvas_window_id, .toggle_recording);
                return;
            }
        },
        .canvas_widget_pointer => |pointer_event| {
            if (isHudCanvasLabel(pointer_event.view_label)) {
                try app_state.dispatch(runtime, pointer_event.window_id, .hud_pointer_seen);
            }
        },
        else => {},
    }
    const inner = app_state.app();
    try inner.event(runtime, event_value);
}

fn isHudCanvasLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, pill_canvas_label) or std.mem.eql(u8, label, panel_canvas_label);
}

pub fn main(init: std.process.Init) !void {
    loadOverlayGeometryFromEnv(init.environ_map);
    // The session-directory writer needs an `Io` and a HOME, and an
    // `update` receives neither - bind them here, once, from the
    // process init the runner hands us.
    process_io = init.io;
    home_dir = init.environ_map.get("HOME");

    const app_state = try std.heap.page_allocator.create(TwintapeApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = TwintapeApp.init(std.heap.page_allocator, .{}, options());
    defer app_state.deinit();

    var app = app_state.app();
    app.context = app_state;
    app.event_fn = hudEventFn;

    // `default_frame`/`restore_state` below are DEAD on this run
    // path (see file doc's position gap): app.zon declares
    // `.shell.windows`, so `native dev` resolves the startup window's
    // whole create-time frame - including x/y - from THAT manifest,
    // comptime (`app_runner/root.zig`'s `manifestWindow`), and never
    // looks at `RunOptions.default_frame` at all for an app shaped
    // like this one. They stay set to the right values anyway as the
    // honest fallback for the branch that WOULD read them (an app.zon
    // with no `.windows` declared), and so this call never lies about
    // where the pill is meant to sit.
    try runner.runWithOptions(app, .{
        .app_name = "twintape",
        .window_title = "Twintape",
        .bundle_id = "dev.native_sdk.twintape",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(hudX(pill_width), hudY(pill_height), pill_width, pill_height),
        .restore_state = true,
        .js_window_api = false,
        .security = .{
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
