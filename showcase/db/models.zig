pub const Post = struct {
    id: i32,
    title: []const u8,
    content: ?[]const u8,
    published: bool,
};

pub const User = struct {
    id: i32,
    email: []const u8,
    handle: []const u8,
    bio: ?[]const u8 = null,
};
