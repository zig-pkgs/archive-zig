const PrivateData = struct {
    gpa: mem.Allocator,
    compress: compress.xz.Decompress,
    reader: Filter.Reader,

    pub fn init(handle: *c.archive_read_filter, gpa: mem.Allocator) !*PrivateData {
        const private_data = try gpa.create(PrivateData);
        errdefer gpa.destroy(private_data);

        private_data.* = .{
            .gpa = gpa,
            .reader = try .init(.{ .handle = handle }),
            .compress = undefined,
        };

        return private_data;
    }

    pub fn initCompress(self: *PrivateData) !void {
        self.compress = try .init(&self.reader.interface, self.gpa, &.{});
    }

    pub fn deinit(self: *PrivateData) void {
        const gpa = self.gpa;
        self.compress.deinit();
        gpa.destroy(self);
    }
};

pub const Bidder = struct {
    pub const vtable: c.archive_read_filter_bidder_vtable = .{
        .bid = &bid,
        .init = &init,
    };

    fn bid(
        self: [*c]c.archive_read_filter_bidder,
        filter: [*c]c.archive_read_filter,
    ) callconv(.c) c_int {
        _ = self;
        const handle: *c.archive_read_filter = filter orelse return 0;
        var f: Filter = .{ .handle = handle };
        const data = f.peek(.limited(6)) catch return 0;
        if (data.len < 6) return 0;
        if (!mem.eql(u8, data[0..6], "\xFD\x37\x7A\x58\x5A\x00")) {
            return 0;
        }
        return 48;
    }

    fn init(self: [*c]c.archive_read_filter) callconv(.c) c_int {
        self.*.code = c.ARCHIVE_FILTER_XZ;
        self.*.name = "xz";
        self.*.vtable = &ReadFilter.vtable;
        const data = PrivateData.init(self.*.upstream, std.heap.c_allocator) catch {
            return c.ARCHIVE_FATAL;
        };
        self.*.data = data;
        data.initCompress() catch return c.ARCHIVE_FATAL;
        return c.ARCHIVE_OK;
    }
};

const ReadFilter = struct {
    pub const vtable: c.archive_read_filter_vtable = .{
        .read = &read,
        .close = &close,
    };

    fn read(self: [*c]c.archive_read_filter, p: [*c]?*const anyopaque) callconv(.c) isize {
        var writer: std.Io.Writer = .{
            .vtable = &.{
                .drain = noopDrain,
                .flush = std.Io.Writer.noopFlush,
                .rebase = std.Io.Writer.failingRebase,
            },
            .buffer = &.{},
        };
        var data: *PrivateData = @ptrCast(@alignCast(self.*.data.?));
        if (data.compress.reader.bufferedLen() > 0) {
            _ = data.compress.reader.stream(&writer, .unlimited) catch unreachable;
        }
        _ = data.compress.reader.stream(&writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => {
                if (data.compress.err) |e| {
                    log.err("decompressing: {t}", .{e});
                }
                log.err("{t}", .{err});
                return c.ARCHIVE_FAILED;
            },
        };
        const decompressed = data.compress.reader.buffered();
        if (decompressed.len == 0) {
            p.* = null;
        } else {
            p.* = decompressed.ptr;
        }
        return @intCast(decompressed.len);
    }

    fn close(self: [*c]c.archive_read_filter) callconv(.c) c_int {
        var data: *PrivateData = @ptrCast(@alignCast(self.*.data.?));
        data.deinit();
        return c.ARCHIVE_OK;
    }

    fn noopDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = w;
        _ = splat;
        return data[0].len;
    }
};

const std = @import("std");
const log = std.log;
const mem = std.mem;
const Filter = @import("../Filter.zig");
const compress = @import("../compress.zig");
const c = @import("c");
