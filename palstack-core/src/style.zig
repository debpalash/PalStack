const std = @import("std");

pub const Color = enum {
    inherit,
    initial,
    transparent,
    current,
    black,
    white,
    slate_50, slate_100, slate_200, slate_300, slate_400, slate_500, slate_600, slate_700, slate_800, slate_900, slate_950,
    gray_50, gray_100, gray_200, gray_300, gray_400, gray_500, gray_600, gray_700, gray_800, gray_900, gray_950,
    red_50, red_100, red_200, red_300, red_400, red_500, red_600, red_700, red_800, red_900, red_950,
    blue_50, blue_100, blue_200, blue_300, blue_400, blue_500, blue_600, blue_700, blue_800, blue_900, blue_950,
    green_50, green_100, green_200, green_300, green_400, green_500, green_600, green_700, green_800, green_900, green_950,
};

pub const UnitType = enum {
    none,
    px,
    rem,
    em,
    percent,
    auto,
};

pub const Unit = union(UnitType) {
    none: void,
    px: f32,
    rem: f32,
    em: f32,
    percent: f32,
    auto: void,

    pub fn format(self: Unit, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .none => {},
            .px => |v| try writer.print("{d}px", .{v}),
            .rem => |v| try writer.print("{d}rem", .{v}),
            .em => |v| try writer.print("{d}em", .{v}),
            .percent => |v| try writer.print("{d}%", .{v}),
            .auto => try writer.writeAll("auto"),
        }
    }
};

pub const Spacing = union(enum) {
    none,
    u0, u1, u2, u3, u4, u5, u6, u8, u10, u12, u16, u20, u24, u32, u40, u48, u56, u64,
    custom: Unit,

    pub fn format(self: Spacing, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .none => {},
            .u0 => try writer.writeAll("0"),
            .u1 => try writer.writeAll("0.25rem"),
            .u2 => try writer.writeAll("0.5rem"),
            .u3 => try writer.writeAll("0.75rem"),
            .u4 => try writer.writeAll("1rem"),
            .u5 => try writer.writeAll("1.25rem"),
            .u6 => try writer.writeAll("1.5rem"),
            .u8 => try writer.writeAll("2rem"),
            .u10 => try writer.writeAll("2.5rem"),
            .u12 => try writer.writeAll("3rem"),
            .u16 => try writer.writeAll("4rem"),
            .u20 => try writer.writeAll("5rem"),
            .u24 => try writer.writeAll("6rem"),
            .u32 => try writer.writeAll("8rem"),
            .u40 => try writer.writeAll("10rem"),
            .u48 => try writer.writeAll("12rem"),
            .u56 => try writer.writeAll("14rem"),
            .u64 => try writer.writeAll("16rem"),
            .custom => |u| try u.format(fmt, options, writer),
        }
    }
};

pub const Display = enum { block, @"inline", flex, grid, none_ };
pub const FlexDirection = enum { row, col, row_reverse, col_reverse };

pub const Style = struct {
    display: Display = .block,
    flex_direction: FlexDirection = .row,
    padding: Spacing = .none,
    margin: Spacing = .none,
    background: Color = .transparent,
    text_color: Color = .inherit,
    font_size: Unit = .none,
};
