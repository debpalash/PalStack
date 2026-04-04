// validator.zig — Runtime JSON schema validation for PalStack.
//
// Ported from turboAPI/zig (dhi_validator.zig).
// Supports nested objects, unions (str | int), typed arrays, and Field constraints.

const std = @import("std");

// ── Schema types ────────────────────────────────────────────────────────────

pub const FieldType = enum {
    string,
    integer,
    float,
    boolean,
    array,
    //@"object", // 'object' is a keyword in some contexts, but fine as enum field
    object,
    union_type,
    any,
};

pub const FieldConstraint = struct {
    name: []const u8,
    field_type: FieldType,
    required: bool = true,
    // String constraints
    min_length: ?usize = null,
    max_length: ?usize = null,
    // Numeric constraints
    gt: ?f64 = null,
    ge: ?f64 = null,
    lt: ?f64 = null,
    le: ?f64 = null,
    // Nested object schema (for type=object with a model)
    nested_schema: ?*const ModelSchema = null,
    // Array item type (for type=array with typed items like list[str])
    items_type: ?FieldType = null,
    // Array item schema (for type=array with nested models like list[ContactInfo])
    items_schema: ?*const ModelSchema = null,
    // Union allowed types (for type=union like str | int)
    union_types: ?[]const FieldType = null,
};

pub const ModelSchema = struct {
    name: []const u8,
    fields: []const FieldConstraint,
};

pub const ValidationResult = union(enum) {
    ok: void,
    err: ValidationError,
};

pub const ValidationError = struct {
    status_code: u16,
    message: []const u8,
    path: ?[]const u8 = null,

    pub fn deinit(self: ValidationError, alloc: std.mem.Allocator) void {
        alloc.free(self.message);
        if (self.path) |p| alloc.free(p);
    }
};

// ── Validation ──────────────────────────────────────────────────────────────

/// Validate raw JSON bytes against a runtime schema.
pub fn validateJson(alloc: std.mem.Allocator, json_bytes: []const u8, schema: *const ModelSchema) !ValidationResult {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch {
        return .{ .err = try makeError(alloc, 422, "Invalid JSON", null) };
    };
    defer parsed.deinit();

    return try validateObject(alloc, parsed.value, schema, "body");
}

fn validateObject(alloc: std.mem.Allocator, value: std.json.Value, schema: *const ModelSchema, path: []const u8) !ValidationResult {
    if (value != .object) {
        return .{ .err = try makeError(alloc, 422, "Expected JSON object", path) };
    }

    for (schema.fields) |field| {
        const val_opt = value.object.get(field.name);

        if (val_opt == null) {
            if (field.required) {
                const field_path = try joinPath(alloc, path, field.name);
                return .{ .err = try makeError(alloc, 422, "Field is required", field_path) };
            }
            continue;
        }

        const val = val_opt.?;

        // Null check — allowed for optional fields
        if (val == .null) {
            if (field.required) {
                const field_path = try joinPath(alloc, path, field.name);
                return .{ .err = try makeError(alloc, 422, "Field is required (cannot be null)", field_path) };
            }
            continue;
        }

        const field_path = try joinPath(alloc, path, field.name);
        // Note: field_path is owned by us, but if we return an error later it needs to be freed or handled.
        // To keep it simple, validation errors own their path.

        const res = try validateField(alloc, val, &field, field_path);
        switch (res) {
            .ok => alloc.free(field_path),
            .err => return res,
        }
    }

    return .ok;
}

fn validateField(alloc: std.mem.Allocator, val: std.json.Value, field: *const FieldConstraint, path: []const u8) !ValidationResult {
    switch (field.field_type) {
        .string => {
            if (val != .string) return .{ .err = try makeError(alloc, 422, "Expected string", path) };
            return validateStringConstraints(alloc, val.string, field, path);
        },
        .integer => {
            if (val != .integer) return .{ .err = try makeError(alloc, 422, "Expected integer", path) };
            const v: f64 = @floatFromInt(val.integer);
            return validateNumericConstraints(alloc, v, field, path);
        },
        .float => {
            const v: f64 = if (val == .float) val.float else if (val == .integer) @as(f64, @floatFromInt(val.integer)) else {
                return .{ .err = try makeError(alloc, 422, "Expected number", path) };
            };
            return validateNumericConstraints(alloc, v, field, path);
        },
        .boolean => {
            if (val != .bool) return .{ .err = try makeError(alloc, 422, "Expected boolean", path) };
        },
        .object => {
            if (val != .object) return .{ .err = try makeError(alloc, 422, "Expected object", path) };
            if (field.nested_schema) |ns| {
                return try validateObject(alloc, val, ns, path);
            }
        },
        .array => {
            if (val != .array) return .{ .err = try makeError(alloc, 422, "Expected array", path) };
            for (val.array.items, 0..) |item, i| {
                const idx_str = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ path, i });
                
                if (field.items_schema) |is| {
                    const r = try validateObject(alloc, item, is, idx_str);
                    switch (r) {
                        .ok => alloc.free(idx_str),
                        .err => return r,
                    }
                } else if (field.items_type) |it| {
                    if (!checkType(item, it)) {
                        return .{ .err = try makeError(alloc, 422, "Invalid item type", idx_str) };
                    }
                    alloc.free(idx_str);
                } else {
                    alloc.free(idx_str);
                }
            }
        },
        .union_type => {
            if (field.union_types) |types| {
                var matched = false;
                for (types) |t| {
                    if (checkType(val, t)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) {
                    return .{ .err = try makeError(alloc, 422, "Value does not match any union type", path) };
                }
            }
        },
        .any => {},
    }

    return .ok;
}

fn checkType(val: std.json.Value, t: FieldType) bool {
    return switch (t) {
        .string => val == .string,
        .integer => val == .integer,
        .float => val == .float or val == .integer,
        .boolean => val == .bool,
        .array => val == .array,
        .object => val == .object,
        .any => true,
        .union_type => true,
    };
}

fn validateStringConstraints(alloc: std.mem.Allocator, s: []const u8, field: *const FieldConstraint, path: []const u8) !ValidationResult {
    if (field.min_length) |ml| {
        if (s.len < ml) return .{ .err = try makeError(alloc, 422, "String too short", path) };
    }
    if (field.max_length) |ml| {
        if (s.len > ml) return .{ .err = try makeError(alloc, 422, "String too long", path) };
    }
    return .ok;
}

fn validateNumericConstraints(alloc: std.mem.Allocator, v: f64, field: *const FieldConstraint, path: []const u8) !ValidationResult {
    if (field.gt) |gt| {
        if (v <= gt) return .{ .err = try makeError(alloc, 422, "Value must be greater than constraint", path) };
    }
    if (field.ge) |ge| {
        if (v < ge) return .{ .err = try makeError(alloc, 422, "Value must be >= constraint", path) };
    }
    if (field.lt) |lt| {
        if (v >= lt) return .{ .err = try makeError(alloc, 422, "Value must be less than constraint", path) };
    }
    if (field.le) |le| {
        if (v > le) return .{ .err = try makeError(alloc, 422, "Value must be <= constraint", path) };
    }
    return .ok;
}

// ── Error formatting ────────────────────────────────────────────────────────

fn makeError(alloc: std.mem.Allocator, status: u16, msg: []const u8, path: ?[]const u8) !ValidationError {
    return ValidationError{
        .status_code = status,
        .message = try alloc.dupe(u8, msg),
        .path = if (path) |p| try alloc.dupe(u8, p) else null,
    };
}

fn joinPath(alloc: std.mem.Allocator, parent: []const u8, child: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ parent, child });
}
