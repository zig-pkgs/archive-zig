export fn archive_read_support_format_rar5(a: [*c]c.archive) c_int {
    _ = a;
    return c.ARCHIVE_FATAL;
}

fn archive_read_support_compression_xz(a: [*c]c.archive) callconv(.c) c_int {
    return archive_read_support_filter_xz(a);
}

fn archive_read_support_compression_lzip(a: [*c]c.archive) callconv(.c) c_int {
    return archive_read_support_filter_lzip(a);
}

fn archive_read_support_compression_lzma(a: [*c]c.archive) callconv(.c) c_int {
    return archive_read_support_filter_lzma(a);
}

fn xzBidderBid(
    self: [*c]c.archive_read_filter_bidder,
    filter: [*c]c.archive_read_filter,
) callconv(.c) c_int {
    _ = self;
    var avail: isize = 0;
    if (c.__archive_read_filter_ahead(filter, 6, &avail)) |ptr| {
        std.debug.assert(avail == 6);
        const buffer: [*]const u8 = @ptrCast(@alignCast(ptr));
        // Verify Header Magic Bytes : FD 37 7A 58 5A 00
        if (!mem.eql(u8, buffer[0..6], "\xFD\x37\x7A\x58\x5A\x00")) {
            return 0;
        }
        return 48;
    }
    return 0;
}

fn xzBidderInit(self: [*c]c.archive_read_filter) callconv(.c) c_int {
    self.*.code = c.ARCHIVE_FILTER_XZ;
    self.*.name = "xz";
    return c.ARCHIVE_OK;
}

const xz_bidder_vtable: c.archive_read_filter_bidder_vtable = .{
    .bid = &xzBidderBid,
    .init = &xzBidderInit,
};

fn xzFilterRead(self: [*c]c.archive_read_filter, p: [*c]?*const anyopaque) callconv(.c) isize {
    _ = self;
    _ = p;
    return 0;
}

fn xzFilterClose(self: [*c]c.archive_read_filter) callconv(.c) c_int {
    _ = self;
    return c.ARCHIVE_OK;
}

const xz_read_vtable: c.archive_read_filter_vtable = .{
    .read = &xzFilterRead,
    .close = &xzFilterClose,
};

export fn archive_read_support_filter_xz(_a: [*c]c.archive) c_int {
    const a: [*c]c.archive_read = @ptrCast(@alignCast(_a));
    if (c.__archive_read_register_bidder(
        a,
        null,
        "xz",
        &xz_bidder_vtable,
    ) != c.ARCHIVE_OK)
        return c.ARCHIVE_FATAL;

    return c.ARCHIVE_OK;
}

export fn archive_read_support_filter_lzip(_a: [*c]c.archive) c_int {
    _ = _a;
    return c.ARCHIVE_FATAL;
}

export fn archive_read_support_filter_lzma(_a: [*c]c.archive) c_int {
    _ = _a;
    return c.ARCHIVE_FATAL;
}

comptime {
    if (c.ARCHIVE_VERSION_NUMBER < 4000000) {
        @export(&archive_read_support_compression_xz, .{
            .name = "archive_read_support_compression_xz",
        });
        @export(&archive_read_support_compression_lzip, .{
            .name = "archive_read_support_compression_lzip",
        });
        @export(&archive_read_support_compression_lzma, .{
            .name = "archive_read_support_compression_lzma",
        });
    }
}

const std = @import("std");
const mem = std.mem;
const c = @import("c");
