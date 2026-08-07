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
//! - A `windows_fn`-declared window's `x`/`y` (`WindowDescriptor.x/y`)
//!   is DEAD on macOS, unconditionally - `ui_app.zig`'s
//!   `createWindowSlot` hardcodes `.restore_state = false` for every
//!   `windows_fn` window (no app-level knob reaches it), and
//!   appkit_host.m's `createWindowWithId:` only honors `x`/`y` when
//!   `restoreFrame` is true; otherwise it builds `NSMakeRect(0, 0, w,
//!   h)`, calls `[window center]`, then - because `windows_fn` windows
//!   are ALSO always created with `makeMain: NO` (the C bridge's
//!   `native_sdk_appkit_create_window` never threads a `makeMain`
//!   param through at all) - immediately overwrites that centered
//!   frame with a cascade off `NSApp.keyWindow ?: self.window`
//!   whenever a reference window exists. `WindowRestorePolicy.
//!   center_on_primary` looks like the fix but is a second dead end:
//!   it is defined in `app_manifest`/`platform` types and threaded
//!   into `ShellWindow.restore_policy`, but macOS's own
//!   `native_sdk_appkit_create_window` extern (platform/macos/root.zig)
//!   has no `restore_policy` parameter in its signature - the value
//!   never crosses the FFI boundary into appkit_host.m, so it is inert
//!   on this platform regardless of what an app sets it to. No
//!   exposed primitive re-positions a window after creation either
//!   (only view/webview frames get a `set*Frame` call - see
//!   `platform/types.zig`'s `PlatformServices`). Moot for `overlay`
//!   (it is always at 0,0 - the whole screen, so miscentering cannot
//!   show), but real - and now hit - for `naming`: `self.window` (the
//!   startup sliver, id 1, the app's one `makeMain: YES` window) is
//!   itself always exactly screen-centered ([window center] DOES run
//!   for it, since `makeMain` skips the cascade branch), so the
//!   cascade's fixed `+24/-24` offset from the sliver's frame lands
//!   `naming` a deterministic ~200pt right and ~90pt below true
//!   center on a 1512x982pt display - visibly off-center, exactly
//!   Hunter's report. Filed as an issue candidate: either honor `x`/
//!   `y` for `windows_fn` windows independent of `restore_state`, or
//!   make macOS's `create_window` actually read `restore_policy` and
//!   implement `center_on_primary`, or expose a post-creation
//!   set-window-frame call. Until one of those ships, no code fix
//!   inside this app can center `naming` - do not spend another
//!   session trying to solve it in `main.zig`.
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
//!
//! V4.5 adds the post-stop flow: a naming dialog, on-disk rename, and
//! a copied `trx` command. Stopping opens `naming`, a THIRD
//! `windows_fn`-declared window (present only while `model.naming !=
//! null`, the same presence-is-visibility shape `overlay` already
//! uses): a real `text_field` pre-loaded with the session's timestamp,
//! Guardar/Omitir buttons, Enter submits, Esc skips. Both paths land
//! on `finishNaming`, which slugifies the typed text (empty or
//! whitespace-only counts as skipped), renames the session directory
//! via `std.Io.Dir.renameAbsolute` when a name was given, and writes
//! the two-line `trx transcribe` command for both tracks to the
//! clipboard via `fx.writeClipboard` (see docs/effects#clipboard - the
//! SAME effect the SDK's own clipboard-effect tests exercise against
//! the null platform, so this app needed no new SDK capability). Esc
//! reaches `finishNaming` through a manifest `Shortcut` (`app.zon`'s
//! `.shortcuts`, `Event.shortcut` in `globalHotkeyEventFn`'s outer
//! `event_fn`), not `Options.on_key`: `on_key` is a FALLBACK that a
//! focused text-entry widget swallows before it ever fires
//! (`canvas.isWidgetTextEntry`, see `ui_app.zig`'s `handleKeyboard`),
//! but `.shortcut` is a distinct platform event the runtime dispatches
//! straight through `dispatchCommand`/`dispatchEvent` - it never
//! enters that widget-focus gate at all, so it fires even while the
//! naming field holds real keyboard focus. The docs' key list allows a
//! bare `escape` shortcut with no modifier (only `enter`/`tab`/
//! `space`/`backspace` require one, to protect normal typing), which
//! is what makes this the right seam instead of a second widget-level
//! Esc handler.

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
pub const naming_label = "naming";
pub const naming_canvas_label = "naming-canvas";

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

// The naming dialog's fixed size. `x`/`y` on `WindowDescriptor` are
// dead for `windows_fn` windows on macOS (see the file doc's SDK-gaps
// note): AppKit's own `[window center]` runs first but is always
// overwritten by a cascade off the startup sliver (the app's one
// `makeMain` window, which - unlike `naming` - IS exactly centered),
// landing this dialog visibly off true center with no code-level fix
// available. Filed as an issue candidate in the gaps note; no
// env-measured geometry can work around it either, since the
// miscentering comes from AppKit's cascade math, not from this app's
// guessed screen size.
const naming_window_width: f32 = 380;
const naming_window_height: f32 = 140;

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
var trx_output_root: ?[]const u8 = null;
/// Formatting scratch for the tray's "Última grabación: <name>" label
/// (see `statusItem`) - outside `StatusItemScratch` because that SDK
/// type has no per-item label buffer, only the status title's.
var last_session_label_buffer: [96]u8 = undefined;

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

// -------------------------------------------------------------- naming

/// Lowercase, spaces (and any other whitespace/punctuation run) to a
/// single hyphen, `[a-z0-9-]` only, leading/trailing hyphens trimmed.
/// Writes into `buffer` and returns the slice actually used - never
/// more than `buffer.len` bytes, so a caller with a fixed-size stack
/// buffer stays safe against an arbitrarily long typed name. An
/// all-punctuation or empty `raw` slugifies to "" (the caller's cue to
/// treat the save as a skip - see `finishNaming`).
pub fn slugify(buffer: []u8, raw: []const u8) []const u8 {
    var len: usize = 0;
    var pending_hyphen = false;
    for (raw) |c| {
        if (len >= buffer.len) break;
        const lower = std.ascii.toLower(c);
        const is_alnum = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');
        if (is_alnum) {
            if (pending_hyphen and len > 0) {
                buffer[len] = '-';
                len += 1;
                if (len >= buffer.len) break;
            }
            pending_hyphen = false;
            buffer[len] = lower;
            len += 1;
        } else {
            pending_hyphen = true;
        }
    }
    return buffer[0..len];
}

/// Where transcripts land for one named (or skipped) session:
/// `$TWINTAPE_TRX_OUTPUT_DIR/<name>` when that env var is set (see
/// `scripts/dev.sh`, which points it at the vault inbox by default),
/// otherwise the session directory itself.
pub fn trxOutputDirFor(buffer: []u8, session_dir: []const u8, name: []const u8) []const u8 {
    const root = trx_output_root orelse return session_dir;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ root, name }) catch session_dir;
}

/// The two-line `trx transcribe` command copied to the clipboard after
/// a save or skip - one call per track, each writing into `out_dir`.
/// `buffer` must be large enough for both paths and `out_dir`
/// (`clipboard_command_buffer_bytes` on `Model`); returns "" on
/// overflow rather than a truncated, half-written shell command.
pub fn buildTrxCommand(buffer: []u8, mic_path: []const u8, system_path: []const u8, out_dir: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "trx transcribe \"{s}\" --output-dir \"{s}\" && trx transcribe \"{s}\" --output-dir \"{s}\"",
        .{ mic_path, out_dir, system_path, out_dir },
    ) catch "";
}

/// Reads TWINTAPE_SCREEN_W/H and TWINTAPE_BORDER from `init.environ_map`
/// (std.process.Init) into the module-level overlay geometry, falling
/// back to the hardcoded defaults when unset or unparsable.
pub fn loadOverlayGeometryFromEnv(environ_map: *const std.process.Environ.Map) void {
    overlay_width = parseEnvF32(environ_map, "TWINTAPE_SCREEN_W") orelse default_overlay_width;
    overlay_height = parseEnvF32(environ_map, "TWINTAPE_SCREEN_H") orelse default_overlay_height;
    border_thickness = parseEnvF32(environ_map, "TWINTAPE_BORDER") orelse default_border_thickness;
    trx_output_root = environ_map.get("TWINTAPE_TRX_OUTPUT_DIR");
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

/// Max typed bytes in the naming field. A session name is a filename
/// component, not prose - generous enough for a long meeting title,
/// bounded so `TextBuffer` stays a fixed-size inline field.
pub const naming_field_capacity: usize = 200;
pub const naming_slug_capacity: usize = 200;
/// `mic_path` + `system_path` + `out_dir`, each up to `session_dir`'s
/// own 640-byte budget, plus the fixed command text around them.
pub const clipboard_command_buffer_bytes: usize = 2200;

/// Live while the naming dialog is up (`model.naming != null` is the
/// window's presence check - see `windows()`). Holds only what the
/// dialog itself needs; the session paths it acts on stay on `Model`
/// (`session_dir`/`mic_path`/`system_path`), same as every other
/// post-stop reader of them.
pub const NamingState = struct {
    field: native_sdk.canvas.TextBuffer(naming_field_capacity) = .{},
    /// The session timestamp, shown as the field's PLACEHOLDER rather
    /// than as pre-loaded text: a text_field that mounts autofocused
    /// WITH content paints a full-selection black bar over the glyphs
    /// (SDK render bug, documented as an upstream issue candidate), so
    /// the field starts empty and an empty submit keeps the timestamp.
    hint: native_sdk.canvas.TextBuffer(naming_field_capacity) = .{},
    /// Set once Guardar/Omitir/Enter/Esc resolves the dialog, so the
    /// "Comando trx copiado" confirmation can hold the window up for
    /// `confirmation_hold_ms` before `windows()` drops it.
    resolved: bool = false,
};

/// What the tray's "Última grabación" section reports. Populated once
/// a naming dialog resolves (`finishNaming`); absent (`Model.
/// last_session_name_len == 0`) until the first recording of this app
/// session finishes naming, per the spec's "only appears if there is
/// at least one recording in the current app session" rule.
pub const last_session_name_capacity: usize = naming_field_capacity;

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

    /// Non-null while the naming dialog is up - `windows()` reads this
    /// for presence, same shape as `overlay`/`state == .recording`.
    naming: ?NamingState = null,
    /// The name (slug, or the bare timestamp when skipped) the tray's
    /// "Última grabación" row shows and the "Copiar comando trx" item
    /// re-copies. Empty until the first naming dialog resolves.
    last_session_name_buffer: [last_session_name_capacity]u8 = undefined,
    last_session_name_len: usize = 0,
    /// The clipboard command last written, kept so "Copiar comando
    /// trx" can re-copy it without recomputing paths already gone
    /// (the dialog closed, `naming` is null again).
    last_clipboard_command_buffer: [clipboard_command_buffer_bytes]u8 = undefined,
    last_clipboard_command_len: usize = 0,

    pub fn sessionDir(model: *const Model) []const u8 {
        return model.session_dir_buffer[0..model.session_dir_len];
    }
    pub fn micPath(model: *const Model) []const u8 {
        return model.mic_path_buffer[0..model.mic_path_len];
    }
    pub fn systemPath(model: *const Model) []const u8 {
        return model.system_path_buffer[0..model.system_path_len];
    }
    pub fn lastSessionName(model: *const Model) []const u8 {
        return model.last_session_name_buffer[0..model.last_session_name_len];
    }
    pub fn hasLastSession(model: *const Model) bool {
        return model.last_session_name_len > 0;
    }
    pub fn lastClipboardCommand(model: *const Model) []const u8 {
        return model.last_clipboard_command_buffer[0..model.last_clipboard_command_len];
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
    naming_field_edit: native_sdk.canvas.TextInputEvent,
    naming_save,
    naming_skip,
    naming_close_tick: native_sdk.EffectTimer,
    clipboard_written: native_sdk.EffectClipboardResult,
    copy_last_command,

    pub const view_unbound = .{ "tick", "capture_event", "open_recordings_exit", "naming_close_tick", "clipboard_written" };
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
/// A second timer key, distinct from `elapsed_timer_key` (both share
/// the timer namespace, so they must differ from each other, not from
/// the capture/spawn keys above).
pub const naming_close_timer_key: u64 = 2;
/// Clipboard keys are their own namespace (see docs/effects#clipboard),
/// so this may share the number with every key above.
pub const clipboard_key: u64 = 1;
/// How long the "Comando trx copiado" confirmation holds the naming
/// window up after Guardar/Omitir/Enter/Esc resolves it.
pub const naming_confirmation_hold_ms: u64 = 1500;

/// Opens the naming dialog for the session that just stopped. The
/// session directory's basename (the bare timestamp) goes into the
/// field's PLACEHOLDER, not its text - see `NamingState.hint` for the
/// SDK render bug this sidesteps. Called once, right after
/// `stopAudioCapture` on the idle-bound Detener path.
fn openNamingDialog(model: *Model) void {
    var naming = NamingState{};
    naming.hint.set(std.fs.path.basename(model.sessionDir()));
    model.naming = naming;
}

/// Slugifies the naming field's current text and resolves the
/// dialog: an empty/all-punctuation slug is a skip (the bare
/// timestamp stays as the name, nothing renamed on disk); a non-empty
/// slug renames the session directory to `<timestamp>-<slug>` via
/// `std.Io.Dir.renameAbsolute` when a real `Io` is bound (tests leave
/// it unbound and only exercise the naming/slug logic). Either path
/// records the resolved name on `Model` (`last_session_name`, for the
/// tray's "Última grabación" row) and fires the clipboard write.
/// Shared by Guardar (Enter), Omitir (Esc), and the dialog's own
/// on-submit - every resolution path funnels through here so the tray
/// name and the clipboard command can never diverge from what the
/// dialog actually did.
fn finishNaming(model: *Model, fx: *Effects) void {
    var naming = model.naming orelse return;
    var slug_buffer: [naming_slug_capacity]u8 = undefined;
    const slug = slugify(&slug_buffer, naming.field.text());

    const timestamp = std.fs.path.basename(model.sessionDir());
    var final_name_buffer: [last_session_name_capacity]u8 = undefined;
    var final_name: []const u8 = timestamp;

    if (slug.len > 0) {
        final_name = std.fmt.bufPrint(&final_name_buffer, "{s}-{s}", .{ timestamp, slug }) catch timestamp;
        renameSessionDir(model, final_name);
    }

    const copied_len = @min(final_name.len, last_session_name_capacity);
    @memcpy(model.last_session_name_buffer[0..copied_len], final_name[0..copied_len]);
    model.last_session_name_len = copied_len;

    writeTrxClipboardCommand(model, fx, model.lastSessionName());

    naming.resolved = true;
    model.naming = naming;
    fx.startTimer(.{
        .key = naming_close_timer_key,
        .interval_ms = naming_confirmation_hold_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.naming_close_tick),
    });
}

/// Renames `model.sessionDir()` in place to `<root>/<final_name>`.
/// The model's own path bookkeeping (`session_dir`/`mic_path`/
/// `system_path`) always repoints to the new location - the same
/// "compute the intended path regardless of `Io`" shape `sessionDirFor`
/// uses for the create side of this pair - but the actual
/// `renameAbsolute` syscall only runs when a real `Io` is bound. Tests
/// leave `process_io` null, so they exercise the naming/slug/model
/// logic without ever touching disk, same as every other test in this
/// suite.
fn renameSessionDir(model: *Model, final_name: []const u8) void {
    var root_buffer: [512]u8 = undefined;
    const root = sessionRoot(&root_buffer);
    var new_path_buffer: [640]u8 = undefined;
    const new_path = std.fmt.bufPrint(&new_path_buffer, "{s}/{s}", .{ root, final_name }) catch return;

    if (process_io) |io| {
        std.Io.Dir.renameAbsolute(model.sessionDir(), new_path, io) catch |err| {
            twintape_log.warn("session rename failed: {s}", .{@errorName(err)});
            return;
        };
    }

    // The rename moved (or, unbound, would move) the directory the
    // mic/system paths still point into: repoint them so a later
    // "Copiar comando trx" (and the command this same call is about
    // to write) names the NEW location, not the pre-rename one.
    const new_session_dir = std.fmt.bufPrint(&model.session_dir_buffer, "{s}", .{new_path}) catch return;
    model.session_dir_len = new_session_dir.len;
    const new_mic_path: []const u8 = std.fmt.bufPrint(&model.mic_path_buffer, "{s}/mic.wav", .{new_path}) catch &.{};
    model.mic_path_len = new_mic_path.len;
    const new_system_path: []const u8 = std.fmt.bufPrint(&model.system_path_buffer, "{s}/system.wav", .{new_path}) catch &.{};
    model.system_path_len = new_system_path.len;
}

/// Builds the two-line `trx transcribe` command for the session's
/// current mic/system paths and writes it to the clipboard. `name` is
/// the resolved session name (slug or bare timestamp), used only to
/// build the output directory when `$TWINTAPE_TRX_OUTPUT_DIR` is set.
/// The output directory is created on disk first when a real `Io` is
/// bound: `trx transcribe --output-dir` does not mkdir for itself (a
/// missing dir fails ffmpeg's write with ENOENT), and this app already
/// creates the session directory the same way, so the copied command
/// runs as-is rather than failing on a directory nobody made yet.
fn writeTrxClipboardCommand(model: *Model, fx: *Effects, name: []const u8) void {
    var out_dir_buffer: [640]u8 = undefined;
    const out_dir = trxOutputDirFor(&out_dir_buffer, model.sessionDir(), name);

    if (process_io) |io| {
        std.Io.Dir.cwd().createDirPath(io, out_dir) catch |err| {
            twintape_log.warn("trx output dir create failed: {s}", .{@errorName(err)});
        };
    }

    const trx_command = buildTrxCommand(&model.last_clipboard_command_buffer, model.micPath(), model.systemPath(), out_dir);
    model.last_clipboard_command_len = trx_command.len;

    fx.writeClipboard(.{
        .key = clipboard_key,
        .text = trx_command,
        .on_result = Effects.clipboardMsg(.clipboard_written),
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
                    openNamingDialog(model);
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
        .naming_field_edit => |edit| {
            if (model.naming) |*naming| naming.field.apply(edit);
        },
        .naming_save => finishNaming(model, fx),
        .naming_skip => {
            // Omitir clears the field first: an empty field slugifies
            // to "", which `finishNaming` treats as skip - the typed
            // timestamp default never leaks into a name the user
            // explicitly chose to drop.
            if (model.naming) |*naming| naming.field.clear();
            finishNaming(model, fx);
        },
        .naming_close_tick => |timer| {
            if (timer.outcome != .fired) return;
            model.naming = null;
        },
        // Fire-and-forget: the confirmation label ("Comando trx
        // copiado") is shown from `naming.resolved` alone, not from
        // this outcome, so a clipboard failure here does not block the
        // dialog closing - it only means the trx command silently
        // never made it to the pasteboard, which the log line is for.
        .clipboard_written => |result| {
            if (result.outcome != .ok) {
                twintape_log.warn("clipboard write failed: {s}", .{@tagName(result.outcome)});
            }
        },
        .copy_last_command => {
            fx.writeClipboard(.{
                .key = clipboard_key,
                .text = model.lastClipboardCommand(),
                .on_result = Effects.clipboardMsg(.clipboard_written),
            });
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
    if (std.mem.eql(u8, window_label_arg, naming_label)) return namingContent(ui, model);
    std.debug.assert(std.mem.eql(u8, window_label_arg, overlay_label));
    return overlayContent(ui);
}

/// The naming dialog: title, the timestamp-prefilled name field
/// (autofocus - a real editable text widget, see the file doc's
/// Gate-0 note), and Guardar/Omitir. Enter on the field submits
/// (`on_submit`); Esc is NOT wired here - it reaches `finishNaming`
/// through the app-level `.shortcut` seam instead (see the file doc),
/// because a focused text-entry widget swallows an unbound app-level
/// key before any widget-local Esc binding this element could carry
/// would even get the chance to. Once `naming.resolved` is true the
/// field/buttons give way to the "Comando trx copiado" confirmation
/// for `naming_confirmation_hold_ms` before `windows()` drops the
/// window.
fn namingContent(ui: *AppUi, model: *const Model) AppUi.Node {
    const naming = model.naming orelse return ui.column(.{}, .{});
    if (naming.resolved) {
        return ui.column(.{ .padding = 16, .gap = 8, .grow = 1, .style_tokens = .{ .background = .background } }, .{
            ui.spacer(1),
            ui.text(.{ .semantics = .{ .label = "Comando trx copiado" } }, "Comando trx copiado"),
            ui.spacer(1),
        });
    }
    return ui.column(.{ .padding = 16, .gap = 8, .grow = 1, .style_tokens = .{ .background = .background } }, .{
        ui.text(.{ .semantics = .{ .label = "Guardar grabación" } }, "Guardar grabación"),
        ui.el(.text_field, .{
            .width = naming_window_width - 32,
            .height = 32,
            .text = naming.field.text(),
            .placeholder = naming.hint.text(),
            .autofocus = true,
            .on_input = AppUi.inputMsg(.naming_field_edit),
            .on_submit = .naming_save,
            .semantics = .{ .label = "Nombre de la grabación" },
        }, .{}),
        ui.row(.{ .gap = 8 }, .{
            ui.spacer(1),
            ui.button(.{ .variant = .ghost, .on_press = .naming_skip, .semantics = .{ .label = "Omitir" } }, "Omitir"),
            ui.button(.{ .variant = .primary, .on_press = .naming_save, .semantics = .{ .label = "Guardar" } }, "Guardar"),
        }),
    });
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

    if (model.naming != null) {
        scratch.windows[count] = .{
            .label = naming_label,
            .canvas_label = naming_canvas_label,
            .title = "Guardar grabación",
            .width = naming_window_width,
            .height = naming_window_height,
            .resizable = false,
            .titlebar = .chromeless,
            // A real dialog, unlike the click-through overlay: it must
            // take focus (the whole point is typing a name), so this
            // is the one window in the app that keeps the SDK's
            // default `activate_on_show = true`.
        };
        count += 1;
    }

    return scratch.windows[0..count];
}

// -------------------------------------------------------------- commands

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, toggle_command)) return .toggle_recording;
    if (std.mem.eql(u8, name, open_recordings_command)) return .open_recordings;
    if (std.mem.eql(u8, name, copy_last_command_command)) return .copy_last_command;
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
    var count: usize = 3;

    // "Última grabación" only once a naming dialog has resolved at
    // least once this app session (see `NamingState`/`finishNaming`) -
    // before that there is nothing to name or re-copy.
    if (model.hasLastSession()) {
        scratch.items[count] = .{ .separator = true };
        count += 1;
        // `StatusItemScratch` (an SDK type) has only `title_buffer`, no
        // slot for a menu item's label - this module-level buffer is
        // the same "app-owned scratch, not a stack local" shape the
        // status item's own formatting already follows (see
        // `elapsedParts`'s doc comment), just outside the SDK struct.
        scratch.items[count] = .{ .id = 4, .label = std.fmt.bufPrint(&last_session_label_buffer, "Última grabación: {s}", .{model.lastSessionName()}) catch "Última grabación", .enabled = false };
        count += 1;
        scratch.items[count] = .{ .id = 5, .label = "Copiar comando trx", .command = copy_last_command_command };
        count += 1;
    }

    scratch.items[count] = .{ .separator = true };
    count += 1;
    scratch.items[count] = .{ .id = 3, .label = "Salir", .command = quit_command, .key = "q", .modifiers = .{ .primary = true } };
    count += 1;
    return .{ .title = title, .icon_visible = model.state != .recording, .items = scratch.items[0..count] };
}

pub const open_recordings_command = "app.open_recordings";
pub const copy_last_command_command = "app.copy_last_command";

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
pub const naming_skip_shortcut_id = "naming-skip";

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
        // Esc, scoped to the naming dialog's own window (see app.zon's
        // `.shortcuts` and the file doc): only meaningful while
        // `model.naming` is up, so an Esc that reaches here with no
        // dialog open (there is no path to that today, but a future
        // window could add one) is silently ignored rather than
        // dispatched into a Msg the model would no-op on anyway.
        .shortcut => |shortcut| {
            if (std.mem.eql(u8, shortcut.id, naming_skip_shortcut_id) and app_state.model.naming != null) {
                try app_state.dispatch(runtime, shortcut.window_id, .naming_skip);
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
