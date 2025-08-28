handle: [*c]c.archive_read_filter,

pub fn read(self: Filter, min: usize) std.Io.Reader.Error![]u8 {
    var avail: isize = 0;
    const ptr = c.__archive_read_filter_ahead(self.handle, min, &avail);
    if (avail == 0) {
        return error.EndOfStream;
    } else if (avail < 0 and ptr == null) {
        return error.ReadFailed;
    } else {
        @branchHint(.likely);
        var buffer: [*]u8 = @ptrCast(@alignCast(ptr));
        return buffer[0..avail];
    }
}

pub fn consume(self: Filter, request: i64) std.Io.Reader.Error!void {
    const rc = c.__archive_read_filter_consume(self.handle, request);
    if (rc < 0) return error.ReadFailed;
}

pub const Reader = struct {
    filter: Filter,
    interface: std.Io.Reader,

    pub fn initInterface(buffer: []u8) std.Io.Reader {
        return .{
            .vtable = &.{
                .stream = Reader.stream,
                .discard = Reader.discard,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        };
    }

    pub fn init(filter: Filter, buffer: []u8) Reader {
        return .{
            .filter = filter,
            .interface = initInterface(buffer),
        };
    }

    fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        const data = try r.filter.read(limit.toInt() orelse 1);

        const bytes_written = try w.write(limit.slice(data));

        try r.filter.consume(bytes_written);

        return bytes_written;
    }

    fn discard(io_reader: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        try r.filter.consume(@min(maxInt(i64), @intFromEnum(limit)));
    }
};

const std = @import("std");
const c = @import("c");
const posix = std.posix;
const maxInt = std.math.maxInt;
const Filter = @This();
