const PrivateData = struct {
    gpa: mem.Allocator,
    compress: compress.flate.Decompress,
    reader: Filter.Reader,
    flate_buffer: [std.compress.flate.max_window_len]u8,

    pub fn init(handle: *c.archive_read_filter, gpa: mem.Allocator) !*PrivateData {
        const private_data = try gpa.create(PrivateData);
        errdefer gpa.destroy(private_data);

        private_data.* = .{
            .flate_buffer = undefined,
            .gpa = gpa,
            .reader = try .init(.{ .handle = handle }),
            .compress = undefined,
        };

        return private_data;
    }

    pub fn initCompress(self: *PrivateData) void {
        self.compress = .init(&self.reader.interface, .gzip, &self.flate_buffer);
    }

    pub fn deinit(self: *PrivateData) void {
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

pub const Bidder = struct {
    pub const vtable: c.archive_read_filter_bidder_vtable = .{
        .bid = &bid,
        .init = &init,
    };

    const Header = extern struct {
        magic: u16 align(1),
        method: u8,
        flags: packed struct(u8) {
            text: bool,
            hcrc: bool,
            extra: bool,
            name: bool,
            comment: bool,
            reserved: u3,
        },
        mtime: u32 align(1),
        xfl: u8,
        os: u8,
    };

    fn bid(
        self: [*c]c.archive_read_filter_bidder,
        filter: [*c]c.archive_read_filter,
    ) callconv(.c) c_int {
        _ = self;
        const handle: *c.archive_read_filter = filter orelse return 0;
        const len = checkHeader(handle) catch return 0;
        return len;
    }

    fn checkHeader(filter: *c.archive_read_filter) !c_int {
        var f: Filter = .{ .handle = filter };
        const buf = try f.peek(.unlimited);
        var in: std.Io.Reader = .fixed(buf);
        const header = try in.takeStruct(Header, .little);
        if (header.magic != 0x8b1f or header.method != 0x08)
            return error.BadGzipHeader;
        if (header.flags.extra) {
            const extra_len = try in.takeInt(u16, .little);
            try in.discardAll(extra_len);
        }
        if (header.flags.name) {
            _ = try in.discardDelimiterInclusive(0);
        }
        if (header.flags.comment) {
            _ = try in.discardDelimiterInclusive(0);
        }
        if (header.flags.hcrc) {
            try in.discardAll(2);
        }
        return @intCast(in.seek);
    }

    fn init(self: [*c]c.archive_read_filter) callconv(.c) c_int {
        self.*.code = c.ARCHIVE_FILTER_GZIP;
        self.*.name = "gzip";
        self.*.vtable = &ReadFilter.vtable;
        const data = PrivateData.init(self.*.upstream, std.heap.c_allocator) catch |err| {
            log.err("init gzip: private data: {t}", .{err});
            return c.ARCHIVE_FATAL;
        };
        self.*.data = data;
        data.initCompress();
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
const compress = std.compress;
const Filter = @import("../Filter.zig");
const c = @import("c");
