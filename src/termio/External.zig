//! External implements terminal IO for embedders that own the PTY.
//!
//! Bytes written by terminal input or terminal protocol responses are
//! forwarded through callbacks. Output is supplied separately through the
//! embedded surface API and processed by Termio.
const External = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

pub const WriteCallback = *const fn (
    ?*anyopaque,
    [*]const u8,
    usize,
) callconv(.c) void;

pub const ResizeCallback = *const fn (
    ?*anyopaque,
    u16,
    u16,
    u32,
    u32,
) callconv(.c) void;

pub const Config = struct {
    userdata: ?*anyopaque = null,
    write: WriteCallback,
    resize: ?ResizeCallback = null,
};

pub const ThreadData = struct {
    pub fn deinit(_: *ThreadData, _: Allocator) void {}
};

userdata: ?*anyopaque,
write_callback: WriteCallback,
resize_callback: ?ResizeCallback,

pub fn init(config: Config) External {
    return .{
        .userdata = config.userdata,
        .write_callback = config.write,
        .resize_callback = config.resize,
    };
}

pub fn deinit(_: *External) void {}

pub fn initTerminal(_: *External, _: *terminal.Terminal) void {}

pub fn threadEnter(
    _: *External,
    _: Allocator,
    _: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    td.backend = .{ .external = .{} };
}

pub fn threadExit(_: *External, _: *termio.Termio.ThreadData) void {}

pub fn focusGained(_: *External, _: *termio.Termio.ThreadData, _: bool) !void {}

pub fn resize(
    self: *External,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    if (self.resize_callback) |callback| {
        callback(
            self.userdata,
            grid_size.columns,
            grid_size.rows,
            screen_size.width,
            screen_size.height,
        );
    }
}

pub fn queueWrite(
    self: *External,
    _: Allocator,
    _: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    if (!linefeed) {
        if (data.len > 0) self.write_callback(self.userdata, data.ptr, data.len);
        return;
    }

    var offset: usize = 0;
    for (data, 0..) |byte, i| {
        if (byte != '\r') continue;
        if (i > offset) {
            self.write_callback(self.userdata, data[offset..i].ptr, i - offset);
        }
        self.write_callback(self.userdata, "\r\n".ptr, 2);
        offset = i + 1;
    }
    if (offset < data.len) {
        self.write_callback(self.userdata, data[offset..].ptr, data.len - offset);
    }
}

const TestCallbacks = struct {
    buffer: [32]u8 = undefined,
    len: usize = 0,
    columns: u16 = 0,
    rows: u16 = 0,
    width: u32 = 0,
    height: u32 = 0,

    fn write(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
        const self: *TestCallbacks = @ptrCast(@alignCast(userdata.?));
        @memcpy(self.buffer[self.len..][0..len], ptr[0..len]);
        self.len += len;
    }

    fn resize(
        userdata: ?*anyopaque,
        columns: u16,
        rows: u16,
        width: u32,
        height: u32,
    ) callconv(.c) void {
        const self: *TestCallbacks = @ptrCast(@alignCast(userdata.?));
        self.columns = columns;
        self.rows = rows;
        self.width = width;
        self.height = height;
    }
};

test "external IO forwards writes with linefeed expansion" {
    var callbacks: TestCallbacks = .{};
    var external = External.init(.{
        .userdata = &callbacks,
        .write = TestCallbacks.write,
    });
    var thread_data: termio.Termio.ThreadData = undefined;

    try external.queueWrite(
        std.testing.allocator,
        &thread_data,
        "first\rsecond",
        true,
    );

    try std.testing.expectEqualStrings("first\r\nsecond", callbacks.buffer[0..callbacks.len]);
}

test "external IO reports host-controlled PTY geometry" {
    var callbacks: TestCallbacks = .{};
    var external = External.init(.{
        .userdata = &callbacks,
        .write = TestCallbacks.write,
        .resize = TestCallbacks.resize,
    });

    try external.resize(
        .{ .columns = 100, .rows = 36 },
        .{ .width = 1200, .height = 720 },
    );

    try std.testing.expectEqual(@as(u16, 100), callbacks.columns);
    try std.testing.expectEqual(@as(u16, 36), callbacks.rows);
    try std.testing.expectEqual(@as(u32, 1200), callbacks.width);
    try std.testing.expectEqual(@as(u32, 720), callbacks.height);
}
