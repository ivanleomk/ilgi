//! Ilgi's root state and view.
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const State = struct {
    pub fn view(_: *State, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().itemsCenter().justifyCenter().gap(8);
        defer root.end();
        ui.text(c, "Ilgi", .{ .size = 32, .weight = .bold });
        ui.text(c, "Local-first Markdown & knowledge vault", .{ .size = 14, .color = c.theme.muted });
    }
};
