const std = @import("std");
const log = std.log;
const testing = std.testing;
const c = @import("c");
pub const Writer = @import("archive/Writer.zig");

test "zstd compress" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var pkg_dir = try tmp_dir.dir.makeOpenPath("pkg", .{ .iterate = true });
    defer pkg_dir.close();

    {
        var build_info = try pkg_dir.createFile(".BUILD_INFO", .{});
        defer build_info.close();
        try build_info.writeAll("pkgname = helloworld\n");
    }

    {
        var pkg_info = try pkg_dir.createFile(".PKGINFO", .{});
        defer pkg_info.close();
        try pkg_info.writeAll("pkgname = helloworld\n");
    }

    {
        var bin_dir = try pkg_dir.makeOpenPath("usr/bin", .{});
        defer bin_dir.close();
        var script = try bin_dir.createFile("helloworld.sh", .{});
        defer script.close();
        try script.chmod(0o755);
        try script.writeAll("!#/bin/sh\necho \"hello world\"");

        try bin_dir.symLink("helloworld.sh", "helloworld", .{});
    }

    var buf: [8 * 1024]u8 = undefined;
    {
        var mtree_writer: Writer = try .init(testing.allocator, &buf, .{
            .dir = pkg_dir,
            .sub_path = ".MTREE",
            .flags = .{},
            .filter = .zstd,
            .format = .mtree,
            .fakeroot = true,
            .opts = &.{
                "!all", "use-set", "type", "uid",    "gid",
                "mode", "time",    "size", "sha256", "link",
            },
        });
        defer mtree_writer.deinit();
        _ = try mtree_writer.writeDir(testing.allocator, pkg_dir);
    }

    {
        var pkg_writer: Writer = try .init(testing.allocator, &buf, .{
            .dir = tmp_dir.dir,
            .sub_path = "helloworld.pkg.tar.zst",
            .flags = .{},
            .filter = .zstd,
            .format = .pax_restricted,
            .fakeroot = true,
        });
        defer pkg_writer.deinit();
        _ = try pkg_writer.writeDir(testing.allocator, pkg_dir);
    }
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
