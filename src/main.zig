//! twintape V1 "esqueleto visible": a menu-bar app that proves out the
//! Native SDK shapes twintape needs before any audio capture exists.
//!
//! Two windows: `main` (close_policy = .hide, the Spotify-shaped
//! menu-bar lifecycle from docs/tray) and a model-declared `overlay`
//! (transparent + always_on_top + click_through + activate_on_show =
//! false, the heads-up shape from docs/windows) whose presence in
//! `windows_fn` IS its visibility. The status item's "Grabar"/"Detener"
//! row toggles `Model.recording`, which the view derives both the
//! overlay's presence and its red border from - no audio, no window
//! chrome, just the skeleton.
//!
//! Known gap (see README): the SDK has no screen-bounds query, so the
//! overlay's frame defaults to a hardcoded oversized rect. `dev.sh`
//! works around it by measuring the real screen size and passing it in
//! via TWINTAPE_SCREEN_W/H env vars (see loadOverlayGeometryFromEnv).

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "main-canvas";
pub const window_label = "main";
pub const overlay_label = "overlay";
pub const overlay_canvas_label = "overlay-canvas";
const window_width: f32 = 320;
// 160 clips "Grabando"/"Detener" (taller status line + wider button
// than the idle "Listo"/"Grabar" pair) - zero_canvas_layout warned
// about a 20.3px vertical overflow at 160; 190 clears it with margin.
const window_height: f32 = 190;

// No SDK API returns the real primary-display frame (see README gap
// note), so the overlay defaults to a hardcoded oversized rect anchored
// at the origin. `dev.sh` measures the real screen size in points
// (AppleScript `bounds of window of desktop`) and exports
// TWINTAPE_SCREEN_W/TWINTAPE_SCREEN_H so the overlay actually matches
// the display instead of overshooting it - this dies the day the SDK
// exposes screen bounds directly.
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

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Twintape status", .accessibility_label = "Twintape status", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = window_label,
    .title = "Twintape",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    // The menu-bar-app shape: the red close button HIDES the window
    // instead of quitting; the tray "Grabar/Detener" row keeps working
    // and only the tray "Salir" row (fx.quitApp) really quits. See
    // docs/tray#the-menu-bar-app-lifecycle and examples/menu-bar.
    .close_policy = .hide,
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

    pub const view_unbound = .{ "tick", "capture_event" };
};

const TwintapeApp = native_sdk.UiApp(Model, Msg);
pub const Effects = TwintapeApp.Effects;

pub const elapsed_timer_key: u64 = 1;
/// Capture keys are their own namespace (see docs/audio-capture), so
/// this may share the number with the timer without colliding.
pub const capture_key: u64 = 1;

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
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);

pub fn view(ui: *AppUi, model: *const Model) AppUi.Node {
    const status_text = switch (model.state) {
        .idle => "Listo",
        .recording => "Grabando",
    };
    const elapsed_text = blk: {
        if (model.state != .recording) break :blk "00:00";
        const parts = model.elapsedParts();
        break :blk ui.fmt("{d:0>2}:{d:0>2}", .{ parts.mins, parts.secs });
    };
    return ui.column(.{ .gap = 12, .padding = 16, .style_tokens = .{ .background = .background } }, .{
        ui.text(.{ .size = .lg }, status_text),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, elapsed_text),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = if (model.state == .recording) .destructive else .primary, .on_press = .toggle_recording }, if (model.state == .recording) "Detener" else "Grabar"),
        }),
        ui.spacer(1),
        ui.statusBar(.{}, "Esqueleto visible V1 - cierra esta ventana, sigue viva en la menu bar."),
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
pub fn overlayView(ui: *AppUi, model: *const Model, window_label_arg: []const u8) AppUi.Node {
    _ = model;
    _ = window_label_arg;
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

// -------------------------------------------------------- secondary window

pub fn windows(model: *const Model, scratch: *TwintapeApp.WindowsScratch) []const TwintapeApp.WindowDescriptor {
    if (model.state != .recording) return &.{};
    scratch.windows[0] = .{
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
    return scratch.windows[0..1];
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
        .window_view = overlayView,
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
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
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
