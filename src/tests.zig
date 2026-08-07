//! The pill/panel HUD loop through the real dispatch paths: the status
//! item installs with Grabar/Salir, the Grabar row starts a repeating
//! elapsed timer AND declares the overlay border on top of the
//! always-declared pill (windows_fn presence = visibility), the
//! Detener row cancels the timer and drops the overlay declaration,
//! the startup window's close_policy stays pinned to .hide so the app
//! keeps running behind its status item, and hovering the pill/panel
//! swaps which of the two is declared.

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
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(main.pill_width, main.pill_height) });
    errdefer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app = app_state.app();
    try harness.start(app);
    // The startup window IS the pill (see main.zig's file doc), so its
    // installing frame is sized to the pill, not a placeholder.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = geometry.SizeF.init(main.pill_width, main.pill_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    return harness;
}

fn findWindow(declared: []const TwintapeApp.WindowDescriptor, label: []const u8) ?TwintapeApp.WindowDescriptor {
    for (declared) |descriptor| {
        if (std.mem.eql(u8, descriptor.label, label)) return descriptor;
    }
    return null;
}

test "the scene declares the hide-on-close main window, sized and dressed as the pill" {
    const scene_window = main.shell_scene.windows[0];
    try testing.expectEqual(native_sdk.app_manifest.WindowClosePolicy.hide, scene_window.close_policy);
    try testing.expectEqualStrings(main.window_label, scene_window.label);
    try testing.expectEqual(@as(f32, main.pill_width), scene_window.width);
    try testing.expectEqual(@as(f32, main.pill_height), scene_window.height);
    try testing.expectEqual(native_sdk.app_manifest.WindowTitlebarStyle.chromeless, scene_window.titlebar);
    try testing.expect(scene_window.transparent);
    try testing.expect(scene_window.always_on_top);
    // Unlike the border overlay, the pill must receive hover/press.
    try testing.expect(!scene_window.click_through);
    try testing.expect(!scene_window.activate_on_show);
}

test "the status item installs with the Grabar/Salir rows" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    try testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try testing.expectEqual(@as(usize, main.status_items.len), harness.null_platform.trayItems().len);
    try testing.expectEqualStrings("twintape", harness.null_platform.lastTrayTitle());
}

test "tray Grabar starts the model and declares the overlay window (the pill is the startup window, never windows_fn)" {
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

    // windows_fn presence IS visibility: recording declares the
    // overlay. The pill itself is the startup window (see main.zig's
    // file doc for why) and is never in this list at all - it is
    // covered by "the scene declares..." below instead.
    var scratch: TwintapeApp.WindowsScratch = undefined;
    const declared = main.windows(&app_state.model, &scratch);
    try testing.expectEqual(@as(usize, 1), declared.len);

    const overlay = findWindow(declared, main.overlay_label).?;
    try testing.expect(overlay.transparent);
    try testing.expect(overlay.always_on_top);
    try testing.expect(overlay.click_through);
    try testing.expect(!overlay.activate_on_show);

    // "Salir" would be id 2 - not exercised here, tray Detener is next.
    _ = &harness;
}

test "tray Detener stops the model, cancels the timer, and drops the overlay declaration" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(main.RecordingState.recording, app_state.model.state);

    // Toggling again lands on id 1 again (Grabar became Detener, same
    // slot) through the model-driven status item, not a second id.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(main.RecordingState.idle, app_state.model.state);
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingTimerCount());

    var scratch: TwintapeApp.WindowsScratch = undefined;
    const declared = main.windows(&app_state.model, &scratch);
    try testing.expectEqual(@as(usize, 0), declared.len);
}

test "the toggle-rec global hotkey starts the model and declares the overlay window, unfocused-safe" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    var app = app_state.app();
    app.context = app_state;
    app.event_fn = main.hudEventFn;

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

    var scratch: TwintapeApp.WindowsScratch = undefined;
    const declared = main.windows(&app_state.model, &scratch);
    try testing.expectEqual(@as(usize, 1), declared.len);
    try testing.expect(findWindow(declared, main.overlay_label) != null);

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
    app.event_fn = main.hudEventFn;

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

    // The overlay border must not outlive the capture: a failure that
    // left the border up would claim a recording that is not happening.
    // The pill needs no assertion here - it is the startup window, not
    // windows_fn-declared, so it was never going to be in this list.
    var scratch: TwintapeApp.WindowsScratch = undefined;
    try testing.expectEqual(@as(usize, 0), main.windows(&app_state.model, &scratch).len);

    // And the menu bar says so rather than showing a clean "twintape".
    var item_scratch: TwintapeApp.StatusItemScratch = undefined;
    const state = main.statusItem(&app_state.model, &item_scratch);
    try testing.expect(std.mem.indexOf(u8, state.title, "permiso") != null);
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

test "tray Salir dispatches the graceful terminate" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 2 });
    try testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().quit_count);
    try harness.stop(app);
}

test "the panel view lays out through the canvas engine and carries the Grabar/Detener toggle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var ui = main.AppUi.init(arena);
    const tree = try ui.finalize(main.windowView(&ui, &model, main.panel_label));

    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, main.panel_width, main.panel_height), &nodes);
    try testing.expect(layout.nodes.len > 0);
    try testing.expect(findByText(tree.root, .button, "Grabar") != null);
    try testing.expect(findByText(tree.root, .button, "Abrir grabaciones") != null);
}

fn windowInfoByLabel(harness: *native_sdk.TestHarness(), label: []const u8) ?native_sdk.platform.WindowInfo {
    var buffer: [native_sdk.platform.max_windows]native_sdk.platform.WindowInfo = undefined;
    for (harness.runtime.listWindows(&buffer)) |info| {
        if (std.mem.eql(u8, info.label, label)) return info;
    }
    return null;
}

test "hovering the pill (the startup window) switches the model to the panel, and hovering the panel switches back" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    // Idle: the panel is not declared (see the windows() tests above).
    // The pill IS the startup window - `startedHarness` already
    // installed its canvas frame, so no separate install step here.
    try testing.expect(!app_state.model.hud_hovering);
    try testing.expect(windowInfoByLabel(harness, main.panel_label) == null);

    // The pointer entering the pill's hit region dispatches
    // hud_hover_enter through the REAL hover path (on_hover_enter),
    // not a direct Msg send.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.pill_canvas_label,
        .kind = .pointer_move,
        .x = main.pill_width / 2,
        .y = main.pill_height / 2,
    } });
    try testing.expect(app_state.model.hud_hovering);

    // The reconcile that followed opened the panel - the pill (the
    // startup window) is never un-declared, so it stays open
    // underneath the whole time.
    const pill_info = windowInfoByLabel(harness, main.pill_label) orelse return error.TestUnexpectedResult;
    try testing.expect(pill_info.open);
    const panel_info = windowInfoByLabel(harness, main.panel_label) orelse return error.TestUnexpectedResult;
    try testing.expect(panel_info.open);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = panel_info.id,
        .label = main.panel_canvas_label,
        .size = geometry.SizeF.init(main.panel_width, main.panel_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 3_000_000,
        .nonblank = true,
    } });

    // A real cursor crossing from the pill's window into the panel's
    // sends the OS's own exit event to the window it left - the pill's
    // chain (window 1) never got a leave-triggering event above, so it
    // is still the app-wide hover mirror's standing view
    // (`stepHoverMsgs` picks whichever view still carries a nonzero
    // chain, and the pill's is the one that has stood since the first
    // move). Retire it explicitly before entering the panel, the same
    // window-exit edge a real move to a different window produces.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.pill_canvas_label,
        .kind = .pointer_cancel,
        .x = main.pill_width / 2,
        .y = main.pill_height / 2,
    } });

    // Enter the panel (`pointer_move` maps to the SDK's `.hover` phase
    // - canvas_frame_helpers.zig `canvasWidgetPointerEventFromGpuInput`
    // - which earns the pointer's hover proof for THIS view).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = panel_info.id,
        .label = main.panel_canvas_label,
        .kind = .pointer_move,
        .x = main.panel_width / 2,
        .y = main.panel_height / 2,
    } });
    try testing.expect(app_state.model.hud_hovering);

    // Leaving the panel's window retires ITS chain the same way, which
    // is what `on_hover_leave` (bound on the panel's whole surface)
    // actually fires on.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = panel_info.id,
        .label = main.panel_canvas_label,
        .kind = .pointer_cancel,
        .x = main.panel_width / 2,
        .y = main.panel_height / 2,
    } });
    try testing.expect(!app_state.model.hud_hovering);
    {
        const closed = windowInfoByLabel(harness, main.panel_label);
        try testing.expect(closed == null or !closed.?.open);
    }
    const pill_still = windowInfoByLabel(harness, main.pill_label) orelse return error.TestUnexpectedResult;
    try testing.expect(pill_still.open);
}

test "the collapse timer arms on hover, re-arms on pointer activity, and firing it collapses the panel" {
    // The real mechanic (see hud_collapse_timer_key's doc): macOS never
    // fires on_hover_leave for a never-key window, so this timer -
    // not the leave handler - is what actually closes the panel.
    // Wired through `hudEventFn` (main.zig's event_fn, not the plain
    // hover-only path `createApp`/`startedHarness` install by default),
    // so it is set explicitly here.
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    var app = app_state.app();
    app.context = app_state;
    app.event_fn = main.hudEventFn;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.pill_canvas_label,
        .kind = .pointer_move,
        .x = main.pill_width / 2,
        .y = main.pill_height / 2,
    } });
    try testing.expect(app_state.model.hud_hovering);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingTimerCount());
    const armed = app_state.effects.pendingTimerAt(0).?;
    try testing.expectEqual(main.hud_collapse_timer_key, armed.key);
    try testing.expectEqual(main.hud_collapse_grace_ms, armed.interval_ms);
    try testing.expectEqual(native_sdk.TimerMode.one_shot, armed.mode);

    // Fresh pointer activity inside the panel re-arms the SAME key
    // (startTimer on an active key replaces it) - this is what keeps a
    // genuinely-still-hovering panel open past one grace window.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.pill_canvas_label,
        .kind = .pointer_move,
        .x = main.pill_width / 2 + 1,
        .y = main.pill_height / 2,
    } });
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingTimerCount());

    // No further activity: firing the armed timer by hand (standing in
    // for "600ms of silence really elapsed") is the only thing that
    // ever clears hud_hovering on this host - proving the pill can
    // never stay stuck open even though on_hover_leave never fires.
    try app_state.effects.fireTimer(main.hud_collapse_timer_key);
    while (harness.null_platform.takeWake()) |_| {
        try harness.runtime.dispatchPlatformEvent(app, .wake);
    }
    try testing.expect(!app_state.model.hud_hovering);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}
