handle: *c.archive_read_filter,

pub fn peek(self: Filter, limit: std.Io.Limit) std.Io.Reader.Error![]u8 {
    const min = limit.toInt() orelse 1;
    var avail: isize = 0;
    if (c.__archive_read_filter_ahead(self.handle, min, &avail)) |ptr| {
        @branchHint(.likely);
        var buffer: [*]u8 = @ptrCast(@alignCast(@constCast(ptr)));
        return buffer[0..@intCast(avail)];
    } else if (avail == 0) {
        return error.EndOfStream;
    } else {
        return error.ReadFailed;
    }
}

pub fn clientBuff(self: Filter) []u8 {
    assert(self.handle.client_buff != null);
    var ptr: [*]u8 = @ptrCast(@alignCast(@constCast(self.handle.client_buff.?)));
    return ptr[0..self.handle.client_total];
}

pub fn copyBuffer(self: Filter) []u8 {
    assert(self.handle.buffer != null);
    return self.handle.*.buffer[0..self.handle.*.buffer_size];
}

const BufferInfo = struct {
    buffer: []u8,
    seek: usize,
    end: usize,
};

pub fn bufferInfo(self: Filter, buf: []u8) BufferInfo {
    const ptr = buf.ptr;
    const next_ptr: ?[*]const u8 = self.handle.next;
    const client_next_ptr: ?[*]const u8 = self.handle.client_next;

    if (client_next_ptr != null and ptr == client_next_ptr) {
        const buffer = self.clientBuff();
        return .{
            .buffer = buffer,
            .seek = ptr - buffer.ptr,
            .end = self.handle.client_avail,
        };
    } else if (next_ptr != null and ptr == next_ptr) {
        const buffer = self.copyBuffer();
        return .{
            .buffer = buffer,
            .seek = ptr - buffer.ptr,
            .end = self.handle.avail,
        };
    } else {
        unreachable;
    }
}

pub fn consume(self: Filter, request: usize) std.Io.Reader.Error!usize {
    const rc = c.__archive_read_filter_consume(self.handle, @intCast(request));
    if (rc < 0) return error.ReadFailed;
    return @intCast(rc);
}

pub fn seekCur(self: Filter, offset: i64) std.Io.Reader.Error!void {
    if (c.__archive_read_filter_seek(self.handle, offset, c.SEEK_CUR) < 0) {
        return error.ReadFailed;
    }
}

pub const Reader = struct {
    filter: Filter,
    interface: std.Io.Reader,

    pub fn initInterface(buf_info: BufferInfo) !std.Io.Reader {
        return .{
            .vtable = &.{
                .stream = Reader.stream,
                .discard = Reader.discard,
                .readVec = Reader.readVec,
            },
            .buffer = buf_info.buffer,
            .seek = buf_info.seek,
            .end = buf_info.end,
        };
    }

    pub fn init(filter: Filter) !Reader {
        const buf = try filter.peek(.unlimited);
        const buf_info = filter.bufferInfo(buf);
        _ = try filter.consume(buf.len);
        return .{
            .filter = filter,
            .interface = try initInterface(buf_info),
        };
    }

    fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        const buf = try r.filter.peek(limit);
        const buf_info = r.filter.bufferInfo(buf);
        io_reader.buffer = buf_info.buffer;
        io_reader.seek = buf_info.seek;
        io_reader.end = buf_info.end;
        const bytes_written = try w.write(limit.slice(buf));
        _ = try r.filter.consume(buf.len);
        io_reader.seek += bytes_written;
        return bytes_written;
    }

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        assert(io_reader.seek == 0);
        try r.filter.seekCur(-@as(i64, @intCast(io_reader.end)));
        const first = data[0];
        const len = if (first.len > 0) first.len else 1;
        const buf = try r.filter.peek(.limited(len));
        const buf_info = r.filter.bufferInfo(buf);
        io_reader.buffer = buf_info.buffer;
        io_reader.seek = buf_info.seek;
        io_reader.end = buf_info.end;
        assert(io_reader.seek == 0);
        _ = try r.filter.consume(buf.len);
        return 0;
    }

    fn discard(io_reader: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        assert(io_reader.seek == io_reader.end);
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        return try r.filter.consume(@min(maxInt(i64), @intFromEnum(limit)));
    }
};

const std = @import("std");
const c = @import("c");
const assert = std.debug.assert;
const posix = std.posix;
const maxInt = std.math.maxInt;
const Filter = @This();
