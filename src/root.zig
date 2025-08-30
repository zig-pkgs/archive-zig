const std = @import("std");
const log = std.log;
const testing = std.testing;
const c = @import("c");

const Writer = struct {
    a: *c.archive,
    interface: std.Io.Writer,

    pub fn init(a: *c.archive, buffer: []u8) Writer {
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

test "zstd compress" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var pkg_dir = try tmp_dir.dir.makeOpenPath("pkg", .{ .iterate = true });
    defer pkg_dir.close();

    var pkg_file = try tmp_dir.dir.createFile("helloworld.pkg.tar.zst", .{});
    defer pkg_file.close();

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
    _ = c.archive_write_open_fd(a, pkg_file.handle);

    var buf: [8 * 1024]u8 = undefined;
    var archive_writer: Writer = .init(a.?, &buf);
    try addToArchive(pkg_dir, &archive_writer);
}

test "decompress" {
    var flags = c.ARCHIVE_EXTRACT_TIME;
    flags |= c.ARCHIVE_EXTRACT_PERM;
    flags |= c.ARCHIVE_EXTRACT_ACL;
    flags |= c.ARCHIVE_EXTRACT_FFLAGS;

    var dir = try std.fs.cwd().openDir("testdata", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    const output_dir_name = ".zig-cache/tmp";

    while (try walker.next()) |entry| {
        const a = c.archive_read_new();
        defer {
            _ = c.archive_read_close(a);
            _ = c.archive_read_free(a);
        }
        try testing.expect(a != null);
        _ = c.archive_read_support_format_all(a);
        _ = c.archive_read_support_filter_all(a);

        var tmp_dir = testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        const ext = c.archive_write_disk_new();
        try testing.expect(ext != null);
        _ = c.archive_write_disk_set_options(ext, flags);
        _ = c.archive_write_disk_set_standard_lookup(ext);
        defer _ = c.archive_write_close(ext);

        if (entry.kind != .file) continue;

        var file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();
        _ = c.archive_read_open_fd(a, file.handle, 8 * 1024);
        try testing.expect(c.archive_errno(a) == 0);

        while (true) {
            var archive_entry: ?*c.archive_entry = null;
            var r = c.archive_read_next_header(a, &archive_entry);
            if (r == c.ARCHIVE_EOF) {
                break;
            }
            if (r < c.ARCHIVE_OK) {
                log.err("{d}", .{c.archive_errno(a)});
            }
            try testing.expect(r >= c.ARCHIVE_WARN);

            const original_path = c.archive_entry_pathname(archive_entry);
            // Combine the temp directory path with the file path from the archive.
            // We must use C-style null termination, which allocPrint handles well.
            const new_path_buf = try std.fs.path.joinZ(testing.allocator, &.{
                output_dir_name, &tmp_dir.sub_path, std.mem.span(original_path),
            });
            defer testing.allocator.free(new_path_buf);

            // Set the new path back on the entry structure
            c.archive_entry_set_pathname(archive_entry, new_path_buf.ptr);

            r = c.archive_write_header(ext, archive_entry);
            if (r < c.ARCHIVE_OK) {
                log.err("{d}", .{c.archive_errno(a)});
            } else if (c.archive_entry_size(archive_entry) > 0) {
                try copyData(a, ext);
            }

            r = c.archive_write_finish_entry(ext);
            if (r < c.ARCHIVE_OK) {
                log.err("{d}", .{c.archive_errno(a)});
            }
            try testing.expect(r >= c.ARCHIVE_WARN);
        }
    }
}

fn copyData(ar: ?*c.archive, aw: ?*c.archive) !void {
    while (true) {
        var size: usize = 0;
        var buff: ?*const anyopaque = null;
        var offset: c.la_int64_t = 0;
        const r = c.archive_read_data_block(ar, &buff, &size, &offset);
        if (r == c.ARCHIVE_EOF) {
            return;
        }
        if (r < c.ARCHIVE_OK) {
            return error.ReadFailed;
        }
        const ret = c.archive_write_data_block(aw, buff, size, offset);
        if (ret < c.ARCHIVE_OK) {
            log.err("{d}", .{c.archive_errno(aw)});
            return error.WriteFailed;
        }
    }
}
