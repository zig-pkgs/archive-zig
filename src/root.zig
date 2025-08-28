const std = @import("std");
const testing = std.testing;
const c = @import("c");

const Writer = struct {
    a: *c.archive,
    interface: std.Io.Writer,

    pub fn initArchive(a: *c.archive, buffer: []u8) Writer {
        return .{
            .a = a,
            .interface = initInterface(buffer),
        };
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

    fn writeData(w: *Writer, buf: []const u8) std.Io.Writer.Error!usize {
        const n = c.archive_write_data(w.a, buf.ptr, buf.len);
        if (n < 0) {
            return error.WriteFailed;
        }
        return @intCast(n);
    }
};

fn addToArchive(dir: std.fs.Dir, w: *Writer) !void {
    const io_w = &w.interface;
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const st = try std.posix.fstatat(entry.dir.fd, entry.basename, 0);
        const stat: std.fs.File.Stat = .fromPosix(st);
        switch (stat.kind) {
            inline .file, .directory => |kind| {
                const archive_entry = c.archive_entry_new();
                try testing.expect(archive_entry != null);
                defer c.archive_entry_free(archive_entry);
                c.archive_entry_set_pathname(archive_entry, entry.basename);
                c.archive_entry_copy_stat(archive_entry, @ptrCast(&st));
                _ = c.archive_write_header(w.a, archive_entry);
                switch (kind) {
                    .file => {
                        var buf: [8 * 1024]u8 = undefined;
                        var child = try entry.dir.openFile(entry.basename, .{});
                        defer child.close();
                        var file_reader = child.reader(&buf);
                        const reader = &file_reader.interface;
                        _ = try reader.streamRemaining(io_w);
                        try io_w.flush();
                    },
                    .directory => {
                        var child = try entry.dir.openDir(entry.basename, .{ .iterate = true });
                        defer child.close();
                        try addToArchive(child, w);
                    },
                    else => comptime unreachable,
                }
            },
            else => {},
        }
    }
}

test {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();

    var pkg_dir = try tmp_dir.dir.makeOpenPath("pkg", .{ .iterate = true });
    defer pkg_dir.close();

    var build_info = try pkg_dir.createFile(".BUILD_INFO", .{});
    try build_info.writeAll("pkgname = helloworld");
    build_info.close();

    const a = c.archive_write_new();
    try testing.expect(a != null);
    defer {
        _ = c.archive_write_close(a);
        _ = c.archive_write_free(a);
    }
    _ = c.archive_write_add_filter_zstd(a);
    _ = c.archive_write_set_format_pax_restricted(a);
    _ = c.archive_write_open_filename(a, "helloworld.pkg.tar.zst");

    var buf: [8 * 1024]u8 = undefined;
    var archive_writer: Writer = .initArchive(a.?, &buf);
    try addToArchive(pkg_dir, &archive_writer);
}
