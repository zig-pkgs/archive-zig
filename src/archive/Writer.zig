a: *c.archive,
file: std.fs.File,
fakeroot: bool,
interface: std.Io.Writer,

pub const Filter = enum {
    zstd,
};

pub const Format = enum {
    mtree,
    pax_restricted,
};

pub const InitOptions = struct {
    dir: std.fs.Dir,
    sub_path: []const u8,
    flags: std.fs.File.CreateFlags,
    format: Format,
    filter: Filter,
    fakeroot: bool = false,
    opts: ?[]const []const u8 = null,
};

const set_format_prefix = "archive_write_set_format_";
const add_filter_prefix = "archive_write_add_filter_";

pub fn init(gpa: mem.Allocator, buffer: []u8, options: InitOptions) !Writer {
    var file = try options.dir.createFile(options.sub_path, .{});
    errdefer file.close();

    const a = c.archive_write_new() orelse
        return error.NoMemory;

    switch (options.format) {
        inline else => |t| {
            const set_format_fn_name = set_format_prefix ++ @tagName(t);
            _ = @field(c, set_format_fn_name)(a);
        },
    }
    switch (options.filter) {
        inline else => |t| {
            const add_filter_fn_name = add_filter_prefix ++ @tagName(t);
            _ = @field(c, add_filter_fn_name)(a);
        },
    }
    if (options.opts) |opts| {
        const opts_str = try std.mem.joinZ(gpa, ",", opts);
        defer gpa.free(opts_str);
        _ = c.archive_write_set_options(a, opts_str.ptr);
    }
    if (c.archive_write_open_fd(a, file.handle) != c.ARCHIVE_OK) {
        log.err("{d}", .{c.archive_errno(a)});
        if (c.archive_error_string(a)) |str| {
            log.err("{s}", .{str});
        }
        return error.OpenFd;
    }
    return .{
        .a = a,
        .file = file,
        .fakeroot = options.fakeroot,
        .interface = initInterface(buffer),
    };
}

pub fn deinit(self: *Writer) void {
    _ = c.archive_write_close(self.a);
    _ = c.archive_write_free(self.a);
    self.file.close();
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

pub const WriteHeaderOptions = struct {
    stat: *const posix.Stat,
    path: [*:0]const u8,
    symlink: ?[*:0]const u8 = null,
};

pub fn writerHeader(w: *Writer, options: WriteHeaderOptions) !void {
    var entry: Entry = try .init();
    defer entry.deinit();
    entry.setPathName(options.path);
    entry.copyStat(options.stat);
    if (options.symlink) |symlink| {
        c.archive_entry_set_symlink(entry.inner, symlink);
    }
    if (w.fakeroot) {
        c.archive_entry_set_uid(entry.inner, 0);
        c.archive_entry_set_gid(entry.inner, 0);
    }
    const rc = c.archive_write_header(w.a, entry.inner);
    if (rc < 0) {
        log.err("{d}", .{c.archive_errno(w.a)});
        if (c.archive_error_string(w.a)) |str| {
            log.err("{s}", .{str});
        }
        return error.WriteFailed;
    }
}

pub fn writeFile(w: *Writer, r: *std.Io.Reader) !void {
    const io_w = &w.interface;
    _ = try r.streamRemaining(io_w);
    try io_w.flush();
}

pub fn writeDir(w: *Writer, gpa: mem.Allocator, dir: std.fs.Dir) !void {
    const format = c.archive_format(w.a);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    const archive_stat = try w.file.stat();

    while (try walker.next()) |entry| {
        const st = try posix.fstatat(entry.dir.fd, entry.basename, posix.AT.SYMLINK_NOFOLLOW);
        const stat: std.fs.File.Stat = .fromPosix(st);
        if (archive_stat.inode == stat.inode) continue;
        switch (entry.kind) {
            .file => {
                try w.writerHeader(.{
                    .stat = &st,
                    .path = entry.path,
                });

                if (stat.size == 0 or format == c.ARCHIVE_FORMAT_MTREE)
                    continue;

                const file = try entry.dir.openFile(entry.basename, .{});
                defer file.close();

                var buf: [8 * 1024]u8 = undefined;
                var file_reader = file.reader(&buf);
                try w.writeFile(&file_reader.interface);
            },
            .sym_link => {
                var path: [std.fs.max_path_bytes + 1]u8 = undefined;
                const link = try entry.dir.readLinkZ(entry.basename, &path);
                path[link.len] = 0;
                try w.writerHeader(.{
                    .stat = &st,
                    .path = entry.path,
                    .symlink = @ptrCast(link.ptr),
                });
            },
            else => {
                try w.writerHeader(.{
                    .stat = &st,
                    .path = entry.path,
                });
            },
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
