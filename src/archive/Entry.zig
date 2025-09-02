inner: *c.archive_entry,

pub fn init() !Entry {
    const entry = c.archive_entry_new() orelse
        return error.NoMemory;
    return .{
        .inner = entry,
    };
}

pub fn deinit(self: *Entry) void {
    c.archive_entry_free(self.inner);
}

pub fn setPathName(self: *Entry, name: [*:0]const u8) void {
    _ = c.archive_entry_set_pathname(self.inner, name);
}

pub fn copyStat(self: *Entry, st: *const posix.Stat) void {
    c.archive_entry_set_atime(self.inner, st.atime().sec, st.atime().nsec);
    c.archive_entry_set_ctime(self.inner, st.ctime().sec, st.ctime().nsec);
    c.archive_entry_set_mtime(self.inner, st.mtime().sec, st.mtime().nsec);
    if (@hasField(@TypeOf(st.*), "birthtime")) {
        c.archive_entry_set_birthtime(self.inner, st.birthtime().sec, st.birthtime().nsec);
    } else {
        c.archive_entry_unset_birthtime(self.inner);
    }
    c.archive_entry_set_dev(self.inner, st.dev);
    c.archive_entry_set_gid(self.inner, st.gid);
    c.archive_entry_set_uid(self.inner, st.uid);
    c.archive_entry_set_ino(self.inner, @intCast(st.ino));
    c.archive_entry_set_nlink(self.inner, @intCast(st.nlink));
    c.archive_entry_set_rdev(self.inner, st.rdev);
    c.archive_entry_set_size(self.inner, st.size);
    c.archive_entry_set_mode(self.inner, st.mode);
}

const std = @import("std");
const log = std.log.scoped(.entry);
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const testing = std.testing;
const Entry = @This();
const c = @import("c");
