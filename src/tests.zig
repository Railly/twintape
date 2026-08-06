//! The V1 skeleton loop through the real dispatch paths: the status
//! item installs with Grabar/Salir, the Grabar row starts a repeating
//! elapsed timer AND declares the overlay window (windows_fn presence =
//! visibility), the Detener row cancels the timer and drops the
//! declaration, and the main window's close_policy stays pinned to
//! .hide so the app keeps running behind its status item.

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
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(320, 190) });
    errdefer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = geometry.SizeF.init(320, 190),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    return harness;
}

test "the scene declares the hide-on-close main window (the menu-bar shape)" {
    try testing.expectEqual(native_sdk.app_manifest.WindowClosePolicy.hide, main.shell_scene.windows[0].close_policy);
    try testing.expectEqualStrings(main.window_label, main.shell_scene.windows[0].label);
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

test "tray Grabar starts the model, declares the overlay window, and arms the elapsed timer" {
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

    // windows_fn presence IS visibility: recording declares the overlay.
    var scratch: TwintapeApp.WindowsScratch = undefined;
    const declared = main.windows(&app_state.model, &scratch);
    try testing.expectEqual(@as(usize, 1), declared.len);
    try testing.expectEqualStrings(main.overlay_label, declared[0].label);
    try testing.expect(declared[0].transparent);
    try testing.expect(declared[0].always_on_top);
    try testing.expect(declared[0].click_through);
    try testing.expect(!declared[0].activate_on_show);

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

    var scratch: TwintapeApp.WindowsScratch = undefined;
    const declared = main.windows(&app_state.model, &scratch);
    try testing.expectEqual(@as(usize, 1), declared.len);
    try testing.expectEqualStrings(main.overlay_label, declared[0].label);

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

test "the idle view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var ui = main.AppUi.init(arena);
    const tree = try ui.finalize(main.view(&ui, &model));

    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 320, 190), &nodes);
    try testing.expect(layout.nodes.len > 0);
    try testing.expect(findByText(tree.root, .button, "Grabar") != null);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}
