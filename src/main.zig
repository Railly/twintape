//! twintape: a menu-bar-first meeting recorder. No visible window,
//! ever.
//!
//! Two windows, same shape V3 verified working. `main` (label "main")
//! is the OS-required startup window, shrunk to an 8x8 sliver -
//! chromeless, transparent, always-on-top, click_through = true,
//! never activated. `overlay` is the recording border, a
//! `windows_fn`-declared secondary window (presence = visibility: it
//! exists only while `model.state == .recording`) - chromeless,
//! transparent, always-on-top, click_through = true, oversized
//! (overlay_width x overlay_height, a TWINTAPE_SCREEN_W/H-patched
//! guess spanning the whole display - see loadOverlayGeometryFromEnv),
//! drawing the red frame while it exists.
//!
//! A later revision tried merging these into ONE window (the startup
//! window doubling as the always-present, oversized overlay, painting
//! nothing while idle) to dodge the SDK's lack of a "start hidden"
//! primitive more cleverly. It reproduced, live, a real regression
//! this shape does not have: the merged window came up FRONTMOST with
//! full opaque black content and real Cocoa chrome (File/Edit/View/
//! Window menu, `System Events`' own frontmost-process query naming
//! twintape) despite `activate_on_show = false` on both app.zon and
//! `shell_windows`. Root cause, read in appkit_host.m: the STARTUP
//! window is always created with `makeMain: YES`
//! (`initWithAppName:...` hardcodes it), and `createWindowWithId:`'s
//! own comment says `orderWindowForImplicitShow` - the ONLY place that
//! reads `activate_on_show` - only runs `else if (showPolicy != 1)`,
//! i.e. NEVER when `makeMain` is true. `activate_on_show` is real for
//! `windows_fn`-declared secondary windows (which never set
//! `makeMain`); it is dead for the one window the OS forces into
//! existence at launch, and separately, macOS's own default
//! Cocoa-app-launch activation (`NSApplication` activating itself on
//! process start) does not route through this manifest flag at all -
//! two independent reasons the merge could never have honored it. This
//! two-window split is the fallback that avoids depending on that gap
//! entirely: the tiny 8x8 sliver at `activate_on_show = false` is
//! genuinely inert (confirmed working in every prior version of this
//! file back through V3), and the overlay's own activation moot
//! either way (it never had a chrome-bearing makeMain window).
//!
//! Control lives ENTIRELY in the menu bar: a template icon
//! (assets/tray-icon.png, two facing crescents/reels joined by two
//! rungs - a DNA-ladder reading, same motif as assets/logo.svg) is
//! the constant identity, and the status item's title layers state on
//! top of it - empty idle (the icon alone), a fault label if the last
//! capture failed, "● MM:SS" while recording. Its menu carries
//! Grabar/Detener, "Abrir grabaciones" (open the session root in
//! Finder), and Salir, and `cmd+shift+r` is the global hotkey twin of
//! the Grabar/Detener row.
//!
//! Known SDK gaps (see README):
//! - No screen-bounds query, so window geometry that must match the
//!   display defaults to a hardcoded oversized/centered guess.
//!   `dev.sh` measures the real screen size in points (AppleScript
//!   `bounds of window of desktop`) and exports
//!   TWINTAPE_SCREEN_W/TWINTAPE_SCREEN_H (see
//!   loadOverlayGeometryFromEnv), which the overlay reads at runtime.
//! - No way to start the mandatory startup window HIDDEN, and no way
//!   for `activate_on_show = false` to apply to it either (see the
//!   merge post-mortem above) - it always activates the app on
//!   launch, a plain macOS/Cocoa behavior this SDK's manifest has no
//!   flag for yet. Filed as an issue candidate: either a real
//!   "start hidden" primitive, or documentation that the startup
//!   window's activation is NEVER manifest-controllable, so nobody
//!   spends another session trying to merge a chrome-bearing surface
//!   into it like this file did once.
//! - A `windows_fn`-declared window's `x`/`y` is only honored on macOS
//!   when `restore_state = true` - appkit_host.m's
//!   `createWindowWithId:` builds `NSMakeRect(0, 0, w, h)` and cascades
//!   the frame off the current key window whenever `restoreFrame` is
//!   false. Moot for `overlay` here (it is always at 0,0 - the whole
//!   screen), but real for anything sized less than the full display
//!   that a future `windows_fn` window might add.
//! - A status item's icon can now be shown or hidden per rebuild via
//!   `StatusItemState.icon_visible` (mirrors the title seam: patches
//!   `statusItem.button.image` in place, no re-create, no flicker; the
//!   host caches the image from install so toggling never re-reads the
//!   icon file). This app uses it: idle shows the constant icon
//!   (assets/tray-icon.png) alone, recording hides it and shows only
//!   "● MM:SS" so the menu bar reads as a plain live clock, and a
//!   fault keeps the icon visible with its label beside it. The icon's
//!   PIXELS are still fixed at install time (no runtime swap to a red
//!   variant) - only its visibility is model-driven.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const twintape_log = std.log.scoped(.twintape);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "main-canvas";
pub const window_label = "main";
pub const overlay_label = "overlay";
pub const overlay_canvas_label = "overlay-canvas";

// No SDK API returns the real primary-display frame (see file doc's
// gap note), so window geometry that must match the display defaults
// to a hardcoded oversized/centered guess. `dev.sh` measures the real
// screen size in points (AppleScript `bounds of window of desktop`)
// and exports TWINTAPE_SCREEN_W/TWINTAPE_SCREEN_H (see
// loadOverlayGeometryFromEnv), read into these at startup.
const default_overlay_width: f32 = 3000;
const default_overlay_height: f32 = 2000;
const default_border_thickness: f32 = 3;

var overlay_width: f32 = default_overlay_width;
var overlay_height: f32 = default_overlay_height;
var border_thickness: f32 = default_border_thickness;

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
// docs/windows#overlay-windows) so only the sliver's own (empty)
// content shows - moot at 8x8, kept for correctness/consistency with
// `overlay`'s own view.
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Twintape", .accessibility_label = "Twintape", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .premultiplied, .gpu_color_space = .srgb, .gpu_vsync = true },
};
// The mandatory startup window, shrunk to a barely-there sliver (see
// file doc for why it cannot just BE the always-present overlay): 8x8
// is small enough that even if some future macOS build ever DID
// activate it, there is nothing on screen big enough to notice.
const startup_sliver_size: f32 = 8;
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = window_label,
    .title = "Twintape",
    .width = startup_sliver_size,
    .height = startup_sliver_size,
    .restore_state = false,
    // The menu-bar-app shape: the red close button HIDES the window
    // instead of quitting (moot here - nothing ever shows a close
    // button on this chromeless surface - kept for parity with
    // docs/tray#the-menu-bar-app-lifecycle's convention). Only the
    // tray "Salir" row (fx.quitApp) really quits.
    .close_policy = .hide,
    .titlebar = .chromeless,
    .transparent = true,
    .always_on_top = true,
    .click_through = true,
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
            // Empty: the status item's icon (assets/tray-icon.png, the
            // static status_item.icon_path) carries idle identity on
            // its own - no text needed beside it.
            .none => "",
            .permission_denied => "sin permiso",
            .device_busy => "micro ocupado",
            .disk_full => "disco lleno",
            .unsupported => "no soportado",
            .rejected => "rechazado",
            .no_session_dir => "sin carpeta",
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
    /// formatting is the caller's job (`statusItem` formats into its
    /// own app-owned scratch buffer, never a stack local whose lifetime
    /// does not survive to when the status item is finalized).
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
    open_recordings,
    open_recordings_exit: native_sdk.EffectExit,

    pub const view_unbound = .{ "tick", "capture_event", "open_recordings_exit" };
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

/// The startup sliver's own content: always empty (see file doc - it
/// is never meant to show anything, `overlay` carries the border).
pub fn view(ui: *AppUi, model: *const Model) AppUi.Node {
    _ = model;
    return ui.column(.{}, .{});
}

/// Dispatches `overlay`'s content by label (the sliver is the startup
/// window and uses `view` above, not this - `overlay` is the only
/// `windows_fn`-declared window, so the label check is a guard against
/// a future second entry silently falling through).
pub fn windowView(ui: *AppUi, model: *const Model, window_label_arg: []const u8) AppUi.Node {
    _ = model;
    std.debug.assert(std.mem.eql(u8, window_label_arg, overlay_label));
    return overlayContent(ui);
}

/// The border: a red frame `border_thickness` points thick around the
/// transparent window. A `stack`-style panel paints its FULL area
/// regardless of children (children never punch a hole in an
/// ancestor's fill), so the frame is built as four painted bands
/// (nine-slice) around one truly EMPTY center cell - no widget there
/// at all, so the transparent window's alpha-zero clear shows through
/// there too (docs/windows: `UiApp.WindowDescriptor` selects an
/// alpha-zero canvas clear automatically for a transparent window).
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

/// The recording border - the sliver is the startup window (see file
/// doc) and is never declared here; it is always alive on its own.
/// Presence is visibility: the border only while recording.
pub fn windows(model: *const Model, scratch: *TwintapeApp.WindowsScratch) []const TwintapeApp.WindowDescriptor {
    var count: usize = 0;

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
    if (std.mem.eql(u8, name, open_recordings_command)) return .open_recordings;
    if (std.mem.eql(u8, name, quit_command)) return .quit;
    return null;
}

/// Model-driven status item: the line of state, the Grabar/Detener
/// toggle, "Abrir grabaciones", and Salir. Idle shows the icon alone
/// (no title). Recording hides the icon and shows only "● MM:SS" - the
/// menu bar itself is the always-visible indicator (the border overlay
/// is the screen-wide one) - the ONLY visible control surface this app
/// has (see file doc). A fault keeps the icon visible and adds its
/// label so a failed capture never looks like a clean stop.
pub fn statusItem(model: *const Model, scratch: *TwintapeApp.StatusItemScratch) TwintapeApp.StatusItemState {
    const title = switch (model.state) {
        .idle => std.fmt.bufPrint(&scratch.title_buffer, "{s}", .{model.fault.label()}) catch "",
        .recording => blk: {
            const parts = model.elapsedParts();
            break :blk std.fmt.bufPrint(&scratch.title_buffer, "\u{25CF} {d:0>2}:{d:0>2}", .{ parts.mins, parts.secs }) catch "";
        },
    };
    scratch.items[0] = .{ .id = 1, .label = switch (model.state) {
        .idle => "Grabar",
        .recording => "Detener",
    }, .command = toggle_command, .key = "r", .modifiers = .{ .primary = true, .shift = true } };
    scratch.items[1] = .{ .separator = true };
    scratch.items[2] = .{ .id = 2, .label = "Abrir grabaciones", .command = open_recordings_command };
    scratch.items[3] = .{ .separator = true };
    scratch.items[4] = .{ .id = 3, .label = "Salir", .command = quit_command, .key = "q", .modifiers = .{ .primary = true } };
    return .{ .title = title, .icon_visible = model.state != .recording, .items = scratch.items[0..5] };
}

pub const open_recordings_command = "app.open_recordings";

// Static fallback (rendered before the model-driven statusItem() above
// takes over on the first frame - see docs/tray#model-driven-title-icon-
// visibility-and-menu). Mirrors its structure and shortcuts exactly: two
// sections divided by separators, ⌘⇧R on the primary action, ⌘Q on Salir,
// so a future "Grabar pantalla/ventana/area" row slots in as its own
// section without touching the shape either declaration already has.
pub const status_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Grabar", .command = toggle_command, .key = "r", .modifiers = .{ .primary = true, .shift = true } },
    .{ .separator = true },
    .{ .id = 2, .label = "Abrir grabaciones", .command = open_recordings_command },
    .{ .separator = true },
    .{ .id = 3, .label = "Salir", .command = quit_command, .key = "q", .modifiers = .{ .primary = true } },
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
            // Template image, set once (Options.status_item is static -
            // see docs/tray#model-driven-title-and-menu: "The static
            // status_item still provides the icon and tooltip"; there is
            // no per-rebuild icon update in the SDK, see the file doc's
            // SDK-gaps note). No static title: the icon alone carries
            // idle identity, statusItem() below drives the live title
            // (empty idle, "MM:SS" recording, a fault label on capture
            // failure).
            .icon_path = "assets/tray-icon@2x.png",
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
/// `toggle_recording` Msg the tray's Grabar/Detener row already sends,
/// then falls through to the inner `event_fn` for every other event so
/// nothing else about `UiApp`'s dispatch changes.
pub fn globalHotkeyEventFn(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
    const app_state: *TwintapeApp = @ptrCast(@alignCast(context));
    switch (event_value) {
        .global_hotkey => |hotkey| {
            if (std.mem.eql(u8, hotkey.id, global_hotkey_toggle_id)) {
                try app_state.dispatch(runtime, app_state.canvas_window_id, .toggle_recording);
                return;
            }
        },
        else => {},
    }
    const inner = app_state.app();
    try inner.event(runtime, event_value);
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
    app.event_fn = globalHotkeyEventFn;

    try runner.runWithOptions(app, .{
        .app_name = "twintape",
        .window_title = "Twintape",
        .bundle_id = "dev.native_sdk.twintape",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, startup_sliver_size, startup_sliver_size),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
