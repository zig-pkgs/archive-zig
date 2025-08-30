const old_prefix = "archive_read_support_compression_";
const new_prefix = "archive_read_support_filter_";

comptime {
    exportUnsupportedReadFormats();
    exportSupportedReadFilters();
    exportUnsupportedReadFilters();
}

const SupportedReadFilters = union(enum) {
    xz: @import("exports/xz.zig"),
    gzip: @import("exports/gzip.zig"),
};

const UnsupportedReadFilters = enum {
    lzip,
    lzma,
    bzip2,
    grzip,
    lrzip,
    lz4,
    lzop,
};

const UnsupportedReadFormats = enum {
    rar5,
};

fn exportSupportedReadFilters() void {
    inline for (@typeInfo(SupportedReadFilters).@"union".fields) |field| {
        exportSupportedSingle(field.type, field.name);
    }
}

fn exportSupportedSingle(comptime T: type, comptime name: []const u8) void {
    const supportedFn = (struct {
        fn supportedFn(_a: [*c]c.archive) callconv(.c) c_int {
            const a: [*c]c.archive_read = @ptrCast(@alignCast(_a));
            if (c.__archive_read_register_bidder(
                a,
                null,
                @ptrCast(name),
                &T.Bidder.vtable,
            ) != c.ARCHIVE_OK)
                return c.ARCHIVE_FATAL;

            return c.ARCHIVE_OK;
        }
    }).supportedFn;
    if (c.ARCHIVE_VERSION_NUMBER < 4000000) {
        @export(&(struct {
            fn oldSupportedFn(_a: [*c]c.archive) callconv(.c) c_int {
                return supportedFn(_a);
            }
        }).oldSupportedFn, .{
            .name = old_prefix ++ name,
        });
    }
    @export(&supportedFn, .{
        .name = new_prefix ++ name,
    });
}

fn exportUnsupportedReadFilters() void {
    inline for (@typeInfo(UnsupportedReadFilters).@"enum".fields) |field| {
        exportUnsupportedSingle(field.name);
    }
}

fn exportUnsupportedSingle(comptime name: []const u8) void {
    if (c.ARCHIVE_VERSION_NUMBER < 4000000) {
        @export(&(struct {
            fn unsupportedFn(_a: [*c]c.archive) callconv(.c) c_int {
                _ = _a;
                return c.ARCHIVE_FATAL;
            }
        }).unsupportedFn, .{
            .name = old_prefix ++ name,
        });
    }
    @export(&(struct {
        fn unsupportedFn(_a: [*c]c.archive) callconv(.c) c_int {
            _ = _a;
            return c.ARCHIVE_FATAL;
        }
    }).unsupportedFn, .{
        .name = new_prefix ++ name,
    });
}

fn exportUnsupportedReadFormats() void {
    const prefix = "archive_read_support_format_";
    inline for (@typeInfo(UnsupportedReadFormats).@"enum".fields) |field| {
        @export(&(struct {
            fn unsupportedFn(_a: [*c]c.archive) callconv(.c) c_int {
                _ = _a;
                return c.ARCHIVE_FATAL;
            }
        }).unsupportedFn, .{
            .name = prefix ++ field.name,
        });
    }
}

const std = @import("std");
const log = std.log;
const mem = std.mem;
const c = @import("c");
