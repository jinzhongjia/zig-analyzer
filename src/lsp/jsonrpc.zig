//! Parsing and construction of JSON-RPC 2.0 messages.

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const json_ext = @import("json_ext.zig");

pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    pub const jsonParse = json_ext.Union(@This()).jsonParse;
    pub const jsonParseFromValue = json_ext.Union(@This()).jsonParseFromValue;
    pub const jsonStringify = json_ext.Union(@This()).jsonStringify;

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .integer => |i| b == .integer and b.integer == i,
            .string => |s| b == .string and std.mem.eql(u8, b.string, s),
        };
    }
};

pub const ResponseError = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,
};

pub const Message = union(enum) {
    request: struct { id: Id, method: []const u8, params: json.Value },
    notification: struct { method: []const u8, params: json.Value },
    /// `failed`: the response has an `error` member that is not null. Its content is not
    /// inspected: a malformed error object (such as one without `message`) still reports the
    /// failure of the request it answers.
    response: struct { id: ?Id, result: json.Value, failed: bool },
};

pub const ParseError = error{
    /// The body is not valid JSON
    InvalidJson,
    /// The body is valid JSON but not a request, notification or response
    InvalidMessage,
    OutOfMemory,
};

/// Parses the outer structure of a message; `params` / `result` are kept as `json.Value` and
/// parsed into concrete types per method by the handlers.
/// All memory is allocated in `arena`.
pub fn parse(arena: Allocator, body: []const u8) ParseError!Message {
    const value = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (value != .object) return error.InvalidMessage;
    const obj = value.object;

    const id: ?Id = if (obj.get("id")) |v| switch (v) {
        .integer => |i| .{ .integer = i },
        .string => |s| .{ .string = s },
        .null => null,
        else => return error.InvalidMessage,
    } else null;

    if (obj.get("method")) |method| {
        if (method != .string) return error.InvalidMessage;
        const params = obj.get("params") orelse .null;
        if (id) |request_id| return .{ .request = .{ .id = request_id, .method = method.string, .params = params } };
        return .{ .notification = .{ .method = method.string, .params = params } };
    }

    const failed = if (obj.get("error")) |e| e != .null else false;
    return .{ .response = .{ .id = id, .result = obj.get("result") orelse .null, .failed = failed } };
}

/// Parses `params` into the parameter type of the method.
pub fn parseParams(comptime T: type, arena: Allocator, params: json.Value) json.ParseFromValueError!T {
    if (T == void) return {};
    return json.parseFromValueLeaky(T, arena, params, .{ .ignore_unknown_fields = true });
}

const stringify_options: json.Stringify.Options = .{ .emit_null_optional_fields = false };

fn writeValue(s: *json.Stringify, value: anytype) json.Stringify.Error!void {
    const T = @TypeOf(value);
    if (T == void or T == ?void) return s.write(null);
    try s.write(value);
}

pub fn response(gpa: Allocator, id: Id, result: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: json.Stringify = .{ .writer = &out.writer, .options = stringify_options };
    build: {
        s.beginObject() catch break :build;
        s.objectField("jsonrpc") catch break :build;
        s.write("2.0") catch break :build;
        s.objectField("id") catch break :build;
        s.write(id) catch break :build;
        s.objectField("result") catch break :build;
        writeValue(&s, result) catch break :build;
        s.endObject() catch break :build;
        return out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

pub fn errorResponse(gpa: Allocator, id: ?Id, code: i32, message: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: json.Stringify = .{ .writer = &out.writer, .options = stringify_options };
    build: {
        s.beginObject() catch break :build;
        s.objectField("jsonrpc") catch break :build;
        s.write("2.0") catch break :build;
        s.objectField("id") catch break :build;
        s.write(id) catch break :build;
        s.objectField("error") catch break :build;
        s.write(ResponseError{ .code = code, .message = message }) catch break :build;
        s.endObject() catch break :build;
        return out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

/// A request from the server to the client; `params` of type `void` omits the member (for
/// methods without parameters: JSON-RPC allows only a structured value there)
pub fn request(gpa: Allocator, id: Id, method: []const u8, params: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: json.Stringify = .{ .writer = &out.writer, .options = stringify_options };
    build: {
        s.beginObject() catch break :build;
        s.objectField("jsonrpc") catch break :build;
        s.write("2.0") catch break :build;
        s.objectField("id") catch break :build;
        s.write(id) catch break :build;
        s.objectField("method") catch break :build;
        s.write(method) catch break :build;
        if (@TypeOf(params) != void) {
            s.objectField("params") catch break :build;
            s.write(params) catch break :build;
        }
        s.endObject() catch break :build;
        return out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

pub fn notification(gpa: Allocator, method: []const u8, params: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: json.Stringify = .{ .writer = &out.writer, .options = stringify_options };
    build: {
        s.beginObject() catch break :build;
        s.objectField("jsonrpc") catch break :build;
        s.write("2.0") catch break :build;
        s.objectField("method") catch break :build;
        s.write(method) catch break :build;
        if (@TypeOf(params) != void) {
            s.objectField("params") catch break :build;
            s.write(params) catch break :build;
        }
        s.endObject() catch break :build;
        return out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

/// Error codes defined by JSON-RPC and LSP
pub const error_codes = struct {
    pub const parse_error = @backingInt(types.ErrorCodes.ParseError);
    pub const invalid_request = @backingInt(types.ErrorCodes.InvalidRequest);
    pub const method_not_found = @backingInt(types.ErrorCodes.MethodNotFound);
    pub const invalid_params = @backingInt(types.ErrorCodes.InvalidParams);
    pub const internal_error = @backingInt(types.ErrorCodes.InternalError);
    pub const server_not_initialized = @backingInt(types.ErrorCodes.ServerNotInitialized);
    pub const request_cancelled = @backingInt(types.LSPErrorCodes.RequestCancelled);
    pub const content_modified = @backingInt(types.LSPErrorCodes.ContentModified);
    pub const request_failed = @backingInt(types.LSPErrorCodes.RequestFailed);
};

const testing = std.testing;

test "classify requests, notifications and responses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req = try parse(a,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    try testing.expectEqual(1, req.request.id.integer);
    try testing.expectEqualStrings("initialize", req.request.method);

    const note = try parse(a,
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try testing.expectEqualStrings("exit", note.notification.method);
    try testing.expect(note.notification.params == .null);

    const resp = try parse(a,
        \\{"jsonrpc":"2.0","id":"abc","error":{"code":-32601,"message":"no"}}
    );
    try testing.expectEqualStrings("abc", resp.response.id.?.string);
    try testing.expect(resp.response.failed);

    // A null error is no error; an error object missing members is still an error
    const ok = try parse(a,
        \\{"jsonrpc":"2.0","id":2,"result":[null],"error":null}
    );
    try testing.expect(!ok.response.failed);
    try testing.expect(ok.response.result == .array);
    const incomplete = try parse(a,
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32603}}
    );
    try testing.expect(incomplete.response.failed);

    try testing.expectError(error.InvalidMessage, parse(a, "[1]"));
    try testing.expectError(error.InvalidMessage, parse(a,
        \\{"jsonrpc":"2.0","id":true,"method":"x"}
    ));
    try testing.expectError(error.InvalidMessage, parse(a,
        \\{"jsonrpc":"2.0","method":1}
    ));
    try testing.expectError(error.InvalidJson, parse(a, "{"));
}

test request {
    const gpa = testing.allocator;
    const a = try request(gpa, .{ .integer = 7 }, "window/workDoneProgress/create", .{ .token = "t" });
    defer gpa.free(a);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":7,"method":"window/workDoneProgress/create","params":{"token":"t"}}
    , a);
    const b = try request(gpa, .{ .string = "r" }, "workspace/inlayHint/refresh", {});
    defer gpa.free(b);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":"r","method":"workspace/inlayHint/refresh"}
    , b);
}

test "build response: void result is null, optional fields omitted" {
    const gpa = testing.allocator;
    const a = try response(gpa, .{ .integer = 3 }, {});
    defer gpa.free(a);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"result":null}
    , a);

    const b = try response(gpa, .{ .string = "x" }, types.Position{ .line = 1, .character = 2 });
    defer gpa.free(b);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":"x","result":{"line":1,"character":2}}
    , b);

    const c = try errorResponse(gpa, null, error_codes.parse_error, "bad");
    defer gpa.free(c);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad"}}
    , c);
}
