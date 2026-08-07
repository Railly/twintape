//! Menu-bar-first twintape through the real dispatch paths: the
//! status item installs with Grabar/Abrir grabaciones/Salir, the
//! Grabar row starts a repeating elapsed timer AND flips the ONE
//! window's content to the recording border (`view` picks border vs
//! empty from `model.state` - there is no second window to declare or
//! drop, see main.zig's file doc), the Detener row cancels the timer
//! and drops the border back to an empty (invisible) tree, the
//! startup window's close_policy stays pinned to .hide, and
//! cmd+shift+r drives the same toggle unfocused-safe.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const TwintapeApp = native_sdk.UiApp(Model, Msg);

fn createApp() !*TwintapeApp {
    const app_state = try testing.allocator.create(TwintapeApp);
    app_state.* = TwintapeApp.init(std.heap.page_allocator, .{}, main.options());
    return app_state;
}

fn startedHarness(app_state: *TwintapeApp) !*native_sdk.TestHarness() {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    errdefer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    return harness;
}

test "the scene declares the hide-on-close main window, chromeless/transparent/always-on-top/click-through" {
    const scene_window = main.shell_scene.windows[0];
    try testing.expectEqual(native_sdk.app_manifest.WindowClosePolicy.hide, scene_window.close_policy);
    try testing.expectEqualStrings(main.window_label, scene_window.label);
    try testing.expectEqual(native_sdk.app_manifest.WindowTitlebarStyle.chromeless, scene_window.titlebar);
    try testing.expect(scene_window.transparent);
    try testing.expect(scene_window.always_on_top);
    // This window is ALWAYS present (the OS-mandatory startup window)
    // and must never steal a click, idle or recording - the opposite
    // of every pill/panel build this file went through, where the HUD
    // needed real hover/press.
    try testing.expect(scene_window.click_through);
    try testing.expect(!scene_window.activate_on_show);
}

test "the startup sliver's view is always an empty tree, idle or recording" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (.{ Model{}, Model{ .state = .recording } }) |model_value| {
        var model = model_value;
        var ui = main.AppUi.init(arena);
        const tree = try ui.finalize(main.view(&ui, &model));

        var nodes: [16]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 400, 300), &nodes);
        // The root column itself lays out (1 node), but nothing inside
        // it: no background, no children - the transparent window's
        // alpha-zero clear is genuinely all there is to see (see file
        // doc). The border lives on `overlay`, a separate
        // `windows_fn`-declared window - never on this one.
        try testing.expectEqual(@as(usize, 1), layout.nodes.len);
        try testing.expect(tree.root.style.background == null);
        try testing.expectEqual(@as(usize, 0), tree.root.children.len);
    }
}

test "windowView renders the red border frame for the overlay label" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .state = .recording };
    var ui = main.AppUi.init(arena);
    const tree = try ui.finalize(main.windowView(&ui, &model, main.overlay_label));

    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 400, 300), &nodes);
    try testing.expect(layout.nodes.len > 1);
    try testing.expect(tree.root.children.len > 0);
}

test "the overlay window is declared only while recording, click-through and non-activating" {
    var scratch: TwintapeApp.WindowsScratch = undefined;

    const idle_model = Model{};
    try testing.expectEqual(@as(usize, 0), main.windows(&idle_model, &scratch).len);

    const recording_model = Model{ .state = .recording };
    const declared = main.windows(&recording_model, &scratch);
    try testing.expectEqual(@as(usize, 1), declared.len);
    try testing.expectEqualStrings(main.overlay_label, declared[0].label);
    try testing.expect(declared[0].transparent);
    try testing.expect(declared[0].always_on_top);
    try testing.expect(declared[0].click_through);
    try testing.expect(!declared[0].activate_on_show);
}

test "the status item installs with Grabar/Abrir grabaciones/Salir" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    try testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try testing.expectEqual(@as(usize, main.status_items.len), harness.null_platform.trayItems().len);
    // Idle title is empty and the icon stays visible - the status
    // item's icon (assets/tray-icon.png, the static
    // status_item.icon_path) carries identity, not the title.
    try testing.expectEqualStrings("", harness.null_platform.lastTrayTitle());
    try testing.expect(harness.null_platform.lastTrayIconVisible());

    var item_scratch: TwintapeApp.StatusItemScratch = undefined;
    const state = main.statusItem(&app_state.model, &item_scratch);
    try testing.expectEqualStrings("Grabar", state.items[0].label);
    try testing.expectEqualStrings("Abrir grabaciones", state.items[2].label);
    try testing.expectEqualStrings("Salir", state.items[4].label);
    try testing.expect(state.icon_visible);

    // Grabar/Detener and Salir carry the same chord as their keyboard
    // path (global_hotkey_toggle_id / Cmd+Q), rendered visibly at the
    // trailing edge of the row (see docs/tray - key/modifiers).
    try testing.expectEqualStrings("r", state.items[0].key);
    try testing.expect(state.items[0].modifiers.primary);
    try testing.expect(state.items[0].modifiers.shift);
    try testing.expectEqualStrings("q", state.items[4].key);
    try testing.expect(state.items[4].modifiers.primary);
    try testing.expect(!state.items[4].modifiers.shift);
}

test "tray Grabar starts the model, the elapsed timer, and swaps the view to the border" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);

    // "Grabar" (id 1): tray selection -> command name -> on_command ->
    // .toggle_recording -> state flips, timer arms.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(main.RecordingState.recording, app_state.model.state);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingTimerCount());
    const request = app_state.effects.pendingTimerAt(0).?;
    try testing.expectEqual(main.elapsed_timer_key, request.key);
    try testing.expectEqual(@as(u64, 1000), request.interval_ms);
    // Recording hides the icon - the menu bar shows only "● MM:SS".
    try testing.expect(!harness.null_platform.lastTrayIconVisible());
}

test "tray Detener stops the model and cancels the timer" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(main.RecordingState.recording, app_state.model.state);
    try testing.expect(!harness.null_platform.lastTrayIconVisible());

    // Toggling again lands on id 1 again (Grabar became Detener, same
    // slot) through the model-driven status item, not a second id.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingTimerCount());
    // Stop restores the icon.
    try testing.expect(harness.null_platform.lastTrayIconVisible());
}

test "tray Abrir grabaciones spawns open against the session root" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    // id 2 is "Abrir grabaciones" (see statusItem/status_items).
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 2 });
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingSpawnCount());
    const request = app_state.effects.pendingSpawnAt(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(main.open_recordings_key, request.key);
    try testing.expectEqual(@as(usize, 2), request.argv.len);
    try testing.expectEqualStrings("open", request.argv[0]);
}

test "the toggle-rec global hotkey starts the model, unfocused-safe" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    var app = app_state.app();
    app.context = app_state;
    app.event_fn = main.globalHotkeyEventFn;

    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);

    // Same event a global hotkey firing while twintape is unfocused
    // produces: no window_id, delivered as a raw event (see
    // docs/global-hotkeys) rather than through on_command.
    try harness.runtime.dispatchPlatformEvent(app, .{ .global_hotkey = .{
        .id = main.global_hotkey_toggle_id,
        .key = "r",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try testing.expectEqual(main.RecordingState.recording, app_state.model.state);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingTimerCount());

    // Firing again toggles back off, same as the tray row.
    try harness.runtime.dispatchPlatformEvent(app, .{ .global_hotkey = .{
        .id = main.global_hotkey_toggle_id,
        .key = "r",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);
}

test "a global hotkey with an unrelated id is ignored, not routed to toggle_recording" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    var app = app_state.app();
    app.context = app_state;
    app.event_fn = main.globalHotkeyEventFn;

    try harness.runtime.dispatchPlatformEvent(app, .{ .global_hotkey = .{
        .id = "some.other.hotkey",
        .key = "q",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);
}

// ------------------------------------------------------- V3 audio capture

test "toggling to recording fires a capture with both session track paths" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(main.RecordingState.recording, app_state.model.state);

    // The capture really was requested, against the two paths the model
    // derived - not a recording state with no capture behind it.
    const request = app_state.effects.audioCaptureRequest().?;
    try testing.expectEqual(main.capture_key, request.key);
    try testing.expectEqualStrings(app_state.model.micPath(), request.mic_path);
    try testing.expectEqualStrings(app_state.model.systemPath(), request.system_path);

    // Both tracks live inside the one session directory, and they are
    // two different files (a shared path is a rejection, see
    // docs/audio-capture).
    const dir = app_state.model.sessionDir();
    try testing.expect(dir.len > 0);
    try testing.expect(std.mem.startsWith(u8, request.mic_path, dir));
    try testing.expect(std.mem.startsWith(u8, request.system_path, dir));
    try testing.expect(std.mem.endsWith(u8, request.mic_path, "/mic.wav"));
    try testing.expect(std.mem.endsWith(u8, request.system_path, "/system.wav"));
    try testing.expect(!std.mem.eql(u8, request.mic_path, request.system_path));
}

test "toggling back to idle stops the capture" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expect(app_state.effects.audioCaptureRequest() != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);
    // The stop released the channel: no capture is occupying it.
    try testing.expect(!app_state.effects.audioCaptureSnapshot().active);
}

test "a failed capture returns the model to idle instead of a false recording" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(main.RecordingState.recording, app_state.model.state);

    // The shape a TCC refusal takes: asynchronous, after the request
    // was accepted (see docs/audio-capture#permissions).
    try harness.runtime.dispatchPlatformEvent(app, .{ .audio_capture = .{
        .key = main.capture_key,
        .kind = .failed,
        .reason = .permission_denied,
    } });

    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);
    try testing.expectEqual(main.CaptureFault.permission_denied, app_state.model.fault);
    try testing.expect(!app_state.model.capture_started);

    // The border must not outlive the capture: a failure that left it
    // up would claim a recording that is not happening. `windows()`
    // reads model.state directly (presence = visibility), so this is
    // the same assertion "the overlay window is declared only while
    // recording" makes, run against the post-failure model.
    var scratch: TwintapeApp.WindowsScratch = undefined;
    try testing.expectEqual(@as(usize, 0), main.windows(&app_state.model, &scratch).len);

    // And the menu bar says so rather than showing a clean (empty) idle
    // title - the icon stays visible too, same as plain idle.
    var item_scratch: TwintapeApp.StatusItemScratch = undefined;
    const state = main.statusItem(&app_state.model, &item_scratch);
    try testing.expect(std.mem.indexOf(u8, state.title, "permiso") != null);
    try testing.expect(state.icon_visible);
}

test "a started event marks the capture live and stopped records the totals" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expect(!app_state.model.capture_started);

    // `.started` means both tracks are really recording, not that the
    // request was accepted.
    try harness.runtime.dispatchPlatformEvent(app, .{ .audio_capture = .{
        .key = main.capture_key,
        .kind = .started,
    } });
    try testing.expect(app_state.model.capture_started);
    try testing.expectEqual(main.RecordingState.recording, app_state.model.state);

    try harness.runtime.dispatchPlatformEvent(app, .{ .audio_capture = .{
        .key = main.capture_key,
        .kind = .stopped,
        .bytes_written = 768_000,
        .duration_ms = 8_000,
    } });
    try testing.expect(!app_state.model.capture_started);
    try testing.expectEqual(@as(u64, 768_000), app_state.model.last_bytes_written);
    try testing.expectEqual(@as(u64, 8_000), app_state.model.last_duration_ms);
}

test "the session stamp formats the SDK clock reading, not the host clock" {
    // 2026-08-06T12:34:56Z with the offset pinned to UTC, so the
    // assertion does not move with the machine's timezone.
    var buffer: [32]u8 = undefined;
    const stamp = main.formatSessionStamp(&buffer, 1_785_933_296_000);
    try testing.expectEqual(@as(usize, 17), stamp.len);
    try testing.expectEqual(@as(u8, '-'), stamp[4]);
    try testing.expectEqual(@as(u8, '-'), stamp[7]);
    try testing.expectEqual(@as(u8, '-'), stamp[10]);
    // Every other character is a digit: this names a directory.
    for (stamp, 0..) |c, i| {
        if (i == 4 or i == 7 or i == 10) continue;
        try testing.expect(std.ascii.isDigit(c));
    }
}

// -------------------------------------------------------- V4.5 post-stop

test "slugify lowercases, hyphenates, and strips non-alnum" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("standup-with-anthony", main.slugify(&buffer, "Standup with Anthony"));
    try testing.expectEqualStrings("q3-planning", main.slugify(&buffer, "  Q3   Planning!! "));
    try testing.expectEqualStrings("", main.slugify(&buffer, "   ---   "));
    try testing.expectEqualStrings("", main.slugify(&buffer, ""));
}

test "buildTrxCommand writes the two-line transcribe command for both tracks" {
    var buffer: [512]u8 = undefined;
    const cmd = main.buildTrxCommand(&buffer, "/tmp/twintape/s/mic.wav", "/tmp/twintape/s/system.wav", "/tmp/out");
    try testing.expectEqualStrings(
        "trx transcribe \"/tmp/twintape/s/mic.wav\" --fields text,srt --output-dir \"/tmp/out\" && trx transcribe \"/tmp/twintape/s/system.wav\" --fields text,srt --output-dir \"/tmp/out\"",
        cmd,
    );
}

test "stopping a recording opens the naming dialog with the session timestamp as placeholder" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try testing.expectEqual(@as(?main.NamingState, null), app_state.model.naming);

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Grabar
    try testing.expectEqual(@as(?main.NamingState, null), app_state.model.naming);

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Detener
    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);
    try testing.expect(app_state.model.naming != null);

    const naming = app_state.model.naming.?;
    const session_stamp = std.fs.path.basename(app_state.model.sessionDir());
    // The timestamp rides the PLACEHOLDER (hint), never the field's
    // text: a prefilled autofocused text_field paints a glyphless
    // full-selection bar (SDK render bug, see main.zig NamingState).
    try testing.expectEqualStrings(session_stamp, naming.hint.text());
    try testing.expectEqualStrings("", naming.field.text());
    try testing.expect(!naming.resolved);

    // The window is declared while naming is up, chromeless and
    // focusable (unlike the click-through overlay).
    var scratch: TwintapeApp.WindowsScratch = undefined;
    const declared = main.windows(&app_state.model, &scratch);
    try testing.expectEqual(@as(usize, 1), declared.len);
    try testing.expectEqualStrings(main.naming_label, declared[0].label);
    try testing.expect(declared[0].activate_on_show);
}

test "Guardar slugifies the typed name and renames the session directory" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Grabar
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Detener

    const original_dir_buffer = app_state.model.sessionDir();
    var original_dir_owned: [640]u8 = undefined;
    @memcpy(original_dir_owned[0..original_dir_buffer.len], original_dir_buffer);
    const original_dir = original_dir_owned[0..original_dir_buffer.len];
    const stamp = std.fs.path.basename(original_dir);

    try app_state.dispatch(&harness.runtime, 1, .{ .naming_field_edit = .clear });
    try app_state.dispatch(&harness.runtime, 1, .{ .naming_field_edit = .{ .insert_text = "Standup With Anthony" } });
    try app_state.dispatch(&harness.runtime, 1, .naming_save);

    try testing.expect(app_state.model.naming != null);
    try testing.expect(app_state.model.naming.?.resolved);

    var expected_buffer: [128]u8 = undefined;
    const expected_name = try std.fmt.bufPrint(&expected_buffer, "{s}-standup-with-anthony", .{stamp});
    try testing.expectEqualStrings(expected_name, app_state.model.lastSessionName());
    try testing.expect(std.mem.endsWith(u8, app_state.model.sessionDir(), expected_name));
    try testing.expect(!std.mem.eql(u8, app_state.model.sessionDir(), original_dir));

    // The clipboard write fired with the RENAMED paths, not the
    // pre-rename ones.
    const request = app_state.effects.pendingClipboardAt(0).?;
    try testing.expect(std.mem.indexOf(u8, request.text, expected_name) != null);
    try testing.expect(std.mem.indexOf(u8, request.text, "trx transcribe") != null);
    try testing.expect(std.mem.indexOf(u8, request.text, "mic.wav") != null);
    try testing.expect(std.mem.indexOf(u8, request.text, "system.wav") != null);

    // Auto-close timer armed for the "Comando trx copiado" hold.
    try testing.expect(app_state.effects.pendingTimerCount() > 0);
}

test "Omitir (empty name) skips the rename but still copies the trx command for the bare timestamp" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Grabar
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Detener

    const stamp_buffer = app_state.model.sessionDir();
    var stamp_owned: [640]u8 = undefined;
    @memcpy(stamp_owned[0..stamp_buffer.len], stamp_buffer);
    const original_dir = stamp_owned[0..stamp_buffer.len];
    const stamp = std.fs.path.basename(original_dir);

    try app_state.dispatch(&harness.runtime, 1, .naming_skip);

    try testing.expectEqualStrings(stamp, app_state.model.lastSessionName());
    try testing.expectEqualStrings(original_dir, app_state.model.sessionDir());

    const request = app_state.effects.pendingClipboardAt(0).?;
    try testing.expect(std.mem.indexOf(u8, request.text, stamp) != null);
}

test "the naming-skip shortcut dispatches naming_skip through the app-level event seam" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    var app = app_state.app();
    app.context = app_state;
    app.event_fn = main.globalHotkeyEventFn;

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Grabar
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Detener
    try testing.expect(app_state.model.naming != null);
    try testing.expect(!app_state.model.naming.?.resolved);

    try harness.runtime.dispatchPlatformEvent(app, .{ .shortcut = .{
        .id = main.naming_skip_shortcut_id,
        .key = "escape",
        .window_id = 1,
    } });

    try testing.expect(app_state.model.naming.?.resolved);
}

test "the naming close tick drops the dialog window" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try app_state.dispatch(&harness.runtime, 1, .naming_skip);
    try testing.expect(app_state.model.naming != null);

    try app_state.dispatch(&harness.runtime, 1, .{ .naming_close_tick = .{ .key = main.naming_close_timer_key, .outcome = .fired } });
    try testing.expectEqual(@as(?main.NamingState, null), app_state.model.naming);

    var scratch: TwintapeApp.WindowsScratch = undefined;
    try testing.expectEqual(@as(usize, 0), main.windows(&app_state.model, &scratch).len);
}

test "the tray shows Última grabación and Copiar comando trx only after a naming dialog has resolved" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    var item_scratch: TwintapeApp.StatusItemScratch = undefined;
    var state = main.statusItem(&app_state.model, &item_scratch);
    for (state.items) |item| {
        try testing.expect(std.mem.indexOf(u8, item.label, "Última grabación") == null);
        try testing.expect(!std.mem.eql(u8, item.command, main.copy_last_command_command));
    }

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Grabar
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 }); // Detener
    try app_state.dispatch(&harness.runtime, 1, .naming_skip);

    state = main.statusItem(&app_state.model, &item_scratch);
    var found_last_session = false;
    var found_copy_command = false;
    var last_session_enabled = true;
    for (state.items) |item| {
        if (std.mem.indexOf(u8, item.label, "Última grabación") != null) {
            found_last_session = true;
            last_session_enabled = item.enabled;
        }
        if (std.mem.eql(u8, item.command, main.copy_last_command_command)) found_copy_command = true;
    }
    try testing.expect(found_last_session);
    try testing.expect(found_copy_command);
    try testing.expect(!last_session_enabled);
}

test "Copiar comando trx re-copies the last resolved command" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try app_state.dispatch(&harness.runtime, 1, .naming_skip);

    const first_request = app_state.effects.pendingClipboardAt(0).?;
    var first_text_owned: [main.clipboard_command_buffer_bytes]u8 = undefined;
    @memcpy(first_text_owned[0..first_request.text.len], first_request.text);
    const first_text = first_text_owned[0..first_request.text.len];

    // The naming-skip write shares `clipboard_key` with every clipboard
    // effect in this app; the fake executor keeps a key occupied until
    // its result is fed AND drained through a `.wake` pump (see the
    // SDK's own effects_clipboard_tests.zig), so the first write must
    // fully deliver before "Copiar comando trx" can open a second slot
    // (real mode completes synchronously - see `effects.zig`'s
    // `startClipboard`).
    try app_state.effects.feedClipboardResult(main.clipboard_key, .ok, "");
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try app_state.dispatch(&harness.runtime, 1, .copy_last_command);
    const second_request = app_state.effects.pendingClipboardAt(0).?;
    try testing.expectEqualStrings(first_text, second_request.text);
}

test "tray Salir dispatches the graceful terminate" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    // id 3 is "Salir" now (Abrir grabaciones took id 2 - see
    // statusItem/status_items).
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 3 });
    try testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().quit_count);
    try harness.stop(app);
}
