a: *c.archive,
file: std.fs.File,
interface: std.Io.Writer,

pub const Filter = enum {
    zstd,
};

pub const Format = enum {
    pax_restricted,
};

pub const InitOptions = struct {
    dir: std.fs.Dir,
    sub_path: []const u8,
    flags: std.fs.File.CreateFlags,
    format: Format,
    filter: Filter,
};

const set_format_prefix = "archive_write_set_format_";
const add_filter_prefix = "archive_write_add_filter_";

pub fn init(buffer: []u8, options: InitOptions) !Writer {
    var file = try options.dir.createFile(options.sub_path, .{});
    errdefer file.close();

    const a = c.archive_write_new() orelse
        return error.NoMemory;
    assert(c.archive_errno(a) == 0);
    const set_format_fn_name = switch (options.format) {
        inline else => |t| set_format_prefix ++ @tagName(t),
    };
    const add_filter_fn_name = switch (options.filter) {
        inline else => |t| add_filter_prefix ++ @tagName(t),
    };
    _ = @field(c, add_filter_fn_name)(a);
    _ = @field(c, set_format_fn_name)(a);
    _ = c.archive_write_open_fd(a, file.handle);
    return .{
        .a = a,
        .file = file,
        .interface = initInterface(buffer),
    };
}

pub fn deinit(self: *Writer) void {
    self.file.close();
    _ = c.archive_write_close(self.a);
    _ = c.archive_write_free(self.a);
}

pub fn initInterface(buffer: []u8) std.Io.Writer {
    return .{
        .vtable = &.{
            .drain = drain,
        },
        .buffer = buffer,
    };
}

fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
    const buffered = io_w.buffered();
    if (buffered.len != 0) {
        const n = try w.writeData(buffered);
        return io_w.consume(n);
    }
    for (data[0 .. data.len - 1]) |buf| {
        if (buf.len == 0) continue;
        const n = try w.writeData(buffered);
        return io_w.consume(n);
    }
    const pattern = data[data.len - 1];
    if (pattern.len == 0 or splat == 0) return 0;
    const n = try w.writeData(buffered);
    return io_w.consume(n);
}

pub fn writerHeader(w: *Writer, entry: Entry) std.Io.Writer.Error!void {
    const rc = c.archive_write_header(w.a, entry.inner);
    if (rc < 0) {
        log.err("{d}", .{c.archive_errno(w.a)});
        if (c.archive_error_string(w.a)) |str| {
            log.err("{s}", .{str});
        }
        return error.WriteFailed;
    }
}

pub const WriteFileOptions = struct {
    file: std.fs.File,
    path: [*:0]const u8,
};

pub fn writeFile(w: *Writer, options: WriteFileOptions) !void {
    const io_w = &w.interface;

    const st = try posix.fstat(options.file.handle);
    var entry: Entry = try .init();
    defer entry.deinit();
    entry.setPathName(options.path);
    entry.copyStat(&st);
    try w.writerHeader(entry);

    var buf: [8 * 1024]u8 = undefined;
    var file_reader = options.file.reader(&buf);
    const reader = &file_reader.interface;
    _ = try reader.streamRemaining(io_w);

    try io_w.flush();
}

const WriteDirHeaderOptions = struct {
    dir: std.fs.Dir,
    path: [*:0]const u8,
};

pub fn writeDirHeader(w: *Writer, options: WriteDirHeaderOptions) !void {
    const st = try posix.fstat(options.dir.fd);
    var header: Entry = try .init();
    defer header.deinit();
    header.setPathName(options.path);
    header.copyStat(&st);
    try w.writerHeader(header);
}

pub fn writeDir(w: *Writer, gpa: mem.Allocator, dir: std.fs.Dir) !void {
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                var file = try entry.dir.openFile(entry.basename, .{});
                defer file.close();
                try w.writeFile(.{
                    .file = file,
                    .path = entry.path,
                });
            },
            .directory => {
                var child = try entry.dir.openDir(entry.basename, .{});
                defer child.close();
                try w.writeDirHeader(.{
                    .dir = child,
                    .path = entry.path,
                });
            },
            else => {},
        }
    }
}

fn writeData(w: *Writer, buf: []const u8) std.Io.Writer.Error!usize {
    const n = c.archive_write_data(w.a, buf.ptr, buf.len);
    if (n < 0) {
        log.err("{d}", .{c.archive_errno(w.a)});
        if (c.archive_error_string(w.a)) |str| {
            log.err("{s}", .{str});
        }
        return error.WriteFailed;
    }
    return @intCast(n);
}

const std = @import("std");
const log = std.log.scoped(.writer);
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const testing = std.testing;
const Writer = @This();
const Entry = @import("Entry.zig");
const c = @import("c");
