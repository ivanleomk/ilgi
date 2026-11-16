//! Ilgi: local-first Markdown & knowledge vault.
const std = @import("std");
const nanoui = @import("nanoui");
const app_view = @import("app.zig");
const config_mod = @import("config.zig");

pub const panic = nanoui.panic;
pub const std_options = nanoui.std_options;
pub const std_options_debug_threaded_io = nanoui.std_options_debug_threaded_io;
pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();

pub fn main(init: nanoui.Init) void {
    const app = nanoui.App.create(init, .{ .name = "Ilgi" }) catch return;
    defer app.destroy();

    var threaded_io: std.Io.Threaded = .init(app.gpa, .{});
    defer threaded_io.deinit();

    const cfg_path = config_mod.Config.defaultPath(app.gpa, init.environ) catch return;
    defer app.gpa.free(cfg_path);

    var state = app_view.State.init(app.gpa, threaded_io.io(), cfg_path);
    defer state.deinit();

    var args = init.args.iterate();
    _ = args.next();
    if (args.next()) |arg_folder| {
        if (state.sidebar.config.addFolder(arg_folder, null) catch false) {
            state.sidebar.config.save(state.sidebar.io, state.sidebar.config_path) catch {};
        }
        state.sidebar.openDir(arg_folder);
    }

    _ = app.newWindow(.{
        .title = "Ilgi",
        .width = 960,
        .height = 640,
        .content = .{ .view = .init(&state, app_view.State.view) },
    }) catch return;
    app.run() catch return;
}
