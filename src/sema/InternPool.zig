//! InternPool: the unique representation of types and comptime values.
//!
//! Types are values too (of type `type`). The same Key always yields the same Index regardless of
//! the interning order, so Indexes in query results can be compared directly. Items are only
//! appended, never removed: type identity is stable for the whole process. Multiple queries
//! intern concurrently, protected by a mutex; looking up the Key of an Index takes no lock (keys
//! are stored in chunks that never move).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const FileId = @import("../base/Vfs.zig").FileId;
const AstId = @import("../syntax/ItemTree.zig").AstId;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const SpinMutex = @import("../util/SpinMutex.zig");

const InternPool = @This();

gpa: Allocator,
io: Io,
/// Protects `map`, `arena`, and appending to `items`
mutex: SpinMutex = .{},
/// Target-dependent parameters for value computations outside every compilation: the parts the
/// targets of all compilations agree on. Set in the same write transaction as the
/// `queries.TargetAbi` input; every query that reads it reads that input first to record the
/// dependency. Read and write transactions are mutually exclusive, so it is never modified while
/// being read.
target: Target = .{},
/// Target-dependent parameters of each compilation (indexed like `ModuleGraph.compiles`, the
/// value of a `context` key), set in the same write transaction as the `queries.ContextTarget`
/// inputs. A computation running in a compilation selects its entry with `enterContext`.
targets: []const Target = &.{},
/// Storage for the slices in Keys
arena: std.heap.ArenaAllocator,
items: Items = .{},
map: std.HashMapUnmanaged(Key, Index, KeyContext, std.hash_map.default_max_load_percentage) = .empty,

/// The Key of each Index, in chunks of doubling size that are never moved or freed while the pool
/// is in use: a thread that has obtained an Index (from `get`, or from a query result published
/// after it was interned) reads its Key without the lock. Interning is far less frequent than
/// looking up keys, which concurrent requests would otherwise serialize on.
const Items = struct {
    /// Chunk `c` holds the `first_chunk << c` keys from index `first_chunk * (2^c - 1)` on
    chunks: [chunk_count]?[*]Key = @splat(null),
    len: u32 = 0,

    const first_chunk = 256;
    /// Enough chunks for every u32 index
    const chunk_count = locate(std.math.maxInt(u32)).chunk + 1;

    fn locate(index: u32) struct { chunk: usize, offset: usize } {
        const n = @as(u64, index) / first_chunk + 1;
        const chunk = std.math.log2_int(u64, n);
        return .{ .chunk = chunk, .offset = index - first_chunk * ((@as(u64, 1) << chunk) - 1) };
    }

    fn chunkLen(chunk: usize) usize {
        return @as(usize, first_chunk) << @intCast(chunk);
    }

    fn at(items: *const Items, index: u32) *Key {
        const loc = locate(index);
        return &items.chunks[loc.chunk].?[loc.offset];
    }

    /// Appends a key (the caller holds the mutex)
    fn append(items: *Items, gpa: Allocator, k: Key) Allocator.Error!u32 {
        const index = items.len;
        const loc = locate(index);
        if (items.chunks[loc.chunk] == null) items.chunks[loc.chunk] = (try gpa.alloc(Key, chunkLen(loc.chunk))).ptr;
        items.chunks[loc.chunk].?[loc.offset] = k;
        items.len = index + 1;
        return index;
    }

    fn capacity(items: *const Items) usize {
        var n: usize = 0;
        for (items.chunks, 0..) |c, i| if (c != null) {
            n += chunkLen(i);
        };
        return n;
    }

    fn deinit(items: *Items, gpa: Allocator) void {
        for (items.chunks, 0..) |c, i| if (c) |p| gpa.free(p[0..chunkLen(i)]);
        items.* = undefined;
    }
};

pub const Index = enum(u32) {
    /// Unknown type (absorbs everything: any operation involving it also yields unknown, and no
    /// diagnostic is produced)
    unknown,
    type_type,
    void_type,
    bool_type,
    noreturn_type,
    anyerror_type,
    anyopaque_type,
    comptime_int_type,
    comptime_float_type,
    null_type,
    undefined_type,
    enum_literal_type,
    usize_type,
    isize_type,
    u8_type,
    u1_type,
    void_value,
    true_value,
    false_value,
    null_value,
    undefined_value,
    /// Placeholder for non-comptime parameters among the arguments of an instance (not part of
    /// the instance's identity); marker for runtime fields in tuples and anonymous structs
    runtime,
    /// `error{}`
    empty_error_set,
    _,
};

pub const Simple = enum {
    type,
    void,
    bool,
    noreturn,
    anyerror,
    anyopaque,
    comptime_int,
    comptime_float,
    null,
    undefined,
    enum_literal,
    usize,
    isize,
    c_char,
    c_short,
    c_ushort,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_longlong,
    c_ulonglong,
    c_longdouble,
    f16,
    f32,
    f64,
    f80,
    f128,
};

pub const SimpleValue = enum { void, true, false, null, undefined };

pub const PtrSize = enum { one, many, slice, c };

pub const PtrType = struct {
    child: Index,
    size: PtrSize,
    is_const: bool = false,
    sentinel: ?Index = null,
    attrs: PtrAttrs = .{},
};

/// Pointer attributes other than constness and the sentinel: `align(a)` / `align(a:b:h)`,
/// `addrspace(...)`, `volatile`, `allowzero`. Pointers without any keep the defaults.
pub const PtrAttrs = struct {
    alignment: Alignment = .natural,
    /// Bit pointer into a packed host integer of `host_size` bytes (0 for other pointers), at
    /// `bit_offset` bits from its start
    host_size: u16 = 0,
    bit_offset: u16 = 0,
    is_volatile: bool = false,
    /// Always false for C pointers, which allow zero by definition (see `get`)
    is_allowzero: bool = false,
    /// null when the `addrspace(...)` expression cannot be evaluated
    address_space: ?std.builtin.AddressSpace = .generic,

    /// Contains no part that could not be evaluated
    pub fn isKnown(a: PtrAttrs) bool {
        return a.alignment != .unknown and a.address_space != null;
    }
};

/// Explicit pointer alignment in bytes. Matching the compiler, an explicit alignment equal to the
/// natural one still makes a different type (`*align(4) u32` is not `*u32`).
pub const Alignment = enum(u64) {
    /// No `align` written: the alignment of the child type
    natural = 0,
    /// The `align` expression cannot be evaluated
    unknown = std.math.maxInt(u64),
    _,

    /// An alignment of `n` bytes; unknown when `n` is not a valid alignment (a power of 2)
    pub fn fromBytes(n: u64) Alignment {
        return if (n == 0 or n == std.math.maxInt(u64) or !std.math.isPowerOfTwo(n)) .unknown else @fromBackingInt(n);
    }

    /// The explicit alignment; null for `natural` and `unknown`
    pub fn bytes(a: Alignment) ?u64 {
        return switch (a) {
            .natural, .unknown => null,
            _ => @backingInt(a),
        };
    }
};

pub const Key = union(enum) {
    unknown,
    simple_type: Simple,
    int_type: struct { signedness: std.builtin.Signedness, bits: u16 },
    ptr_type: PtrType,
    array_type: struct { len: u64, child: Index, sentinel: ?Index = null },
    /// An array whose length is not known: the element type and sentinel are. With `len`, the
    /// length depends on an abstract parameter (in a generic function body without a concrete
    /// instance, e.g. `[block_length]u8`), and `len` is the source text of the length expression,
    /// used only for display. Without `len`, the length depends on no abstract parameter but
    /// cannot be evaluated (`count(fmt, args)` in an instance of `std.fmt.comptimePrint`): no
    /// instance determines it, and it is displayed as `_`.
    abstract_array_type: struct { len: ?[]const u8, child: Index, sentinel: ?Index = null },
    optional_type: Index,
    error_union_type: struct { err: Index, payload: Index },
    error_set_type: ErrorSet,
    /// The error set of a function's `!T` inferred from the function body. The signature records
    /// only this marker; the members are computed on demand by `ErrorSetOf`.
    inferred_error_set: struct { file: FileId, decl: AstId, inst: ?Index = null },
    fn_type: struct { params: []const Index, ret: Index, varargs: bool = false },
    /// Identity = definition location (file + AstId of the container)
    container_type: Container,
    /// Tuple `struct { A, B }` (`@Tuple`, tuple literals)
    tuple_type: Tuple,
    /// `@Vector(len, T)`
    vector_type: struct { len: u32, child: Index },
    /// Type of an anonymous struct literal `.{ .a = x }` without a result type; `values` as in
    /// `Tuple`
    anon_struct_type: struct { names: []const []const u8, types: []const Index, values: []const Index = &.{} },
    /// Types constructed by `@Enum` / `@Struct` / `@Union`
    reified_type: Reified,
    /// The tag enum generated automatically for a `union(enum)` (the value is the union type)
    union_tag_type: Index,

    simple_value: SimpleValue,
    int_value: struct { ty: Index, value: i128 },
    /// Float value (the bit representation as f128, already rounded to the precision of the type)
    float_value: struct { ty: Index, bits: u128 },
    enum_literal: []const u8,
    /// A member of an enum type
    enum_tag: struct { ty: Index, name: []const u8 },
    error_value: []const u8,
    /// Function declaration; `inst` is the instance the function belongs to (methods of generic
    /// containers)
    fn_value: struct { ty: Index, file: FileId, decl: AstId, inst: ?Index = null },

    /// Value of an array, vector, tuple or struct (in field order). When the type is a slice or a
    /// pointer to an array, it represents the elements pointed to.
    aggregate: struct { ty: Index, elems: []const Index },
    /// Aggregate with u8 elements (a string); the type means the same as in `aggregate`
    bytes: struct { ty: Index, bytes: []const u8 },
    /// Value of a union
    union_value: struct { ty: Index, tag: []const u8, payload: Index },
    /// Single-item pointer to a comptime value
    ptr_value: struct { ty: Index, pointee: Index },

    /// One instantiation of a generic function: the function + the value of each parameter (the
    /// argument value for comptime parameters, unknown when it is not known; the argument type
    /// for anytype parameters; `runtime` for non-comptime parameters).
    /// `parent` is the instance the function itself belongs to (for a function defined in another
    /// instantiated container), or the `context` of a function outside every generic function.
    instance: Instance,
    /// The compilation (an index into `ModuleGraph.compiles`) code is analyzed in when it is not
    /// its file's own compilation (`ModuleGraph.home`): a file shared by several compilations,
    /// such as the standard library, is analyzed once per compilation that uses it. It takes the
    /// place of an instance where code is outside every generic function (`inst` of declarations,
    /// container types and function values) and ends the `parent` chain of instances, so values
    /// from different compilations never share an identity. Neither a type nor a value.
    context: u32,
    /// A comptime type parameter without a concrete instance (abstract instance), displayed as the
    /// parameter name
    opaque_param: struct { file: FileId, owner: AstId, binding: u32, name: []const u8 },
    /// Placeholder for non-comptime parameters among the arguments of an instance
    runtime,
};

/// Members of an error set, without duplicates. Two sets with the same members are the same
/// type whatever the order of their names: identity (hashing, equality) follows `sorted`, and
/// `names` keeps the order of the first set interned with these members. The compiler lists
/// `@typeInfo(E).error_set.error_names` in the order in which it first saw each name (in
/// practice, the declaration order), but `@typeName` sorted by bytes.
pub const ErrorSet = struct {
    names: []const []const u8,
    /// Indexes into `names`, ordering the names by their bytes
    sorted: []const u32,

    pub const empty: ErrorSet = .{ .names = &.{}, .sorted = &.{} };

    fn hash(es: ErrorSet, h: *std.hash.Wyhash) void {
        std.hash.autoHash(h, es.sorted.len);
        for (es.sorted) |i| {
            std.hash.autoHash(h, es.names[i].len);
            h.update(es.names[i]);
        }
    }

    fn eql(a: ErrorSet, b: ErrorSet) bool {
        if (a.sorted.len != b.sorted.len) return false;
        for (a.sorted, b.sorted) |i, j| if (!std.mem.eql(u8, a.names[i], b.names[j])) return false;
        return true;
    }
};

/// Fields of a tuple
pub const Tuple = struct {
    types: []const Index,
    /// Comptime value of each field; see `fieldValue`
    values: []const Index = &.{},
};

/// Comptime value of field `i` of a tuple or anonymous struct. Fields of a literal that are known
/// at comptime are comptime fields (matching the compiler), and their values belong to the type;
/// runtime fields are `runtime`, and fields whose comptime-ness or value cannot be determined are
/// `unknown`. When `values` is empty, all fields are runtime fields (tuples constructed by
/// `@Tuple`).
pub fn fieldValue(values: []const Index, i: usize) Index {
    return if (values.len == 0) .runtime else values[i];
}

/// Empty when all fields are runtime fields: the type is then the same as a tuple constructed by
/// `@Tuple`
pub fn fieldValues(values: []const Index) []const Index {
    for (values) |v| if (v != .runtime) return values;
    return &.{};
}

pub const Instance = struct {
    file: FileId,
    decl: AstId,
    args: []const Index,
    parent: ?Index = null,
    /// When inferring per iteration, the instance that containers defined inside a loop body (or
    /// an `inline` switch prong) of member `decl` belong to: the instance of `decl` (when
    /// `abstract`, `decl` has no instance, `args` is empty, and the enclosing instance is
    /// `parent`) with `binding` at iteration `index`. The field types of these containers can
    /// depend on the loop variable.
    iteration: ?Iteration = null,

    /// When `index` is `unknown_index`, the iteration is undetermined (containers in a loop body
    /// when not inferring per iteration): the type is not concrete
    pub const Iteration = struct {
        binding: u32,
        index: u32,
        abstract: bool,

        pub const unknown_index = std.math.maxInt(u32);
    };
};

/// Container type constructed by a builtin. Identity = construction location (member +
/// expression) + the instance at construction + the contents
pub const Reified = struct {
    kind: Kind,
    file: FileId,
    owner: AstId,
    expr: u32,
    /// The instance where it is constructed (displayed as `FieldEnum(S)`)
    inst: ?Index = null,
    layout: Layout = .auto,
    /// enum: the integer type of the tag; union: the tag enum (null when untagged); packed struct:
    /// the backing integer
    tag: ?Index = null,
    names: []const []const u8,
    /// Field types of a struct / union
    types: []const Index = &.{},
    /// Values of the enum members
    values: []const i128 = &.{},
    nonexhaustive: bool = false,
    /// Explicit alignments of struct / union fields (0 when unspecified); empty when none is
    /// specified
    field_aligns: []const u64 = &.{},
    /// Whether each struct field is comptime; empty when none is
    comptime_fields: []const bool = &.{},
    /// Field attributes cannot be computed (the layout is unknown)
    attrs_unknown: bool = false,

    pub const Kind = enum { @"struct", @"enum", @"union" };
    pub const Layout = enum { auto, @"extern", @"packed" };
};

pub const Container = struct {
    file: FileId,
    ast_id: AstId,
    kind: Kind,
    /// When the container is defined in a generic function body, the instance of that function
    /// (`ArrayList(u8)` and `ArrayList(i32)` are different types)
    inst: ?Index = null,

    pub const Kind = enum {
        file,
        @"struct",
        @"enum",
        @"union",
        @"opaque",

        /// A file is a struct: its fields are written at the top level
        pub fn isStruct(k: Kind) bool {
            return k == .@"struct" or k == .file;
        }
    };
};

/// A type and (if known at comptime) a value. `ty == .unknown` means unknown.
pub const TypedValue = struct {
    ty: Index,
    val: ?Index = null,

    pub const unknown: TypedValue = .{ .ty = .unknown };

    pub fn isType(tv: TypedValue) bool {
        return tv.ty == .type_type;
    }

    /// Returns the type when the value is a type
    pub fn asType(tv: TypedValue) ?Index {
        return if (tv.ty == .type_type) tv.val else null;
    }

    pub fn ofType(t: Index) TypedValue {
        return .{ .ty = .type_type, .val = t };
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h: std.hash.Wyhash = .init(0);
        switch (k) {
            .error_set_type => |es| {
                std.hash.autoHash(&h, std.meta.activeTag(k));
                es.hash(&h);
            },
            // Name lists are slices of slices: pointers must be followed at every level
            else => std.hash.autoHashStrat(&h, k, .DeepRecursive),
        }
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return keyEql(a, b);
    }
};

fn keyEql(a: Key, b: Key) bool {
    if (a == .error_set_type and b == .error_set_type) return a.error_set_type.eql(b.error_set_type);
    return deepEql(a, b);
}

/// Corresponds one-to-one to the preset members of `Index`
const preset = [_]Key{
    .unknown,
    .{ .simple_type = .type },
    .{ .simple_type = .void },
    .{ .simple_type = .bool },
    .{ .simple_type = .noreturn },
    .{ .simple_type = .anyerror },
    .{ .simple_type = .anyopaque },
    .{ .simple_type = .comptime_int },
    .{ .simple_type = .comptime_float },
    .{ .simple_type = .null },
    .{ .simple_type = .undefined },
    .{ .simple_type = .enum_literal },
    .{ .simple_type = .usize },
    .{ .simple_type = .isize },
    .{ .int_type = .{ .signedness = .unsigned, .bits = 8 } },
    .{ .int_type = .{ .signedness = .unsigned, .bits = 1 } },
    .{ .simple_value = .void },
    .{ .simple_value = .true },
    .{ .simple_value = .false },
    .{ .simple_value = .null },
    .{ .simple_value = .undefined },
    .runtime,
    .{ .error_set_type = .empty },
};

pub fn init(gpa: Allocator, io: Io) Allocator.Error!InternPool {
    var ip: InternPool = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    errdefer ip.deinit();
    for (preset, 0..) |k, i| std.debug.assert(@backingInt(try ip.get(k)) == i);
    return ip;
}

pub fn deinit(ip: *InternPool) void {
    ip.gpa.free(ip.targets);
    ip.items.deinit(ip.gpa);
    ip.map.deinit(ip.gpa);
    ip.arena.deinit();
    ip.* = undefined;
}

/// Reclaims all non-preset items (whole-generation reclamation). The caller must ensure that no
/// non-preset Index is used anywhere afterwards: the queries referring to them are cleared at the
/// same time (`Db.resetQueries`), and no read transaction is in progress.
///
/// The preset items are built in a new table first, which then replaces the old one as a whole:
/// if an allocation fails, the original pool stays intact (preset Indexes remain valid) and is
/// just not reclaimed.
pub fn reset(ip: *InternPool) Allocator.Error!void {
    var fresh: InternPool = .{ .gpa = ip.gpa, .io = ip.io, .arena = .init(ip.gpa) };
    errdefer fresh.deinit();
    for (preset, 0..) |k, i| std.debug.assert(@backingInt(try fresh.get(k)) == i);

    ip.mutex.lockUncancelable(ip.io);
    std.mem.swap(Items, &ip.items, &fresh.items);
    std.mem.swap(@TypeOf(ip.map), &ip.map, &fresh.map);
    std.mem.swap(std.heap.ArenaAllocator, &ip.arena, &fresh.arena);
    ip.mutex.unlock(ip.io);
    // The old table that was swapped out
    fresh.deinit();
}

/// Bytes in use (the Key table, the hash table, and the arena holding the slices in Keys), for
/// statistics
pub fn bytes(ip: *InternPool) usize {
    ip.mutex.lockUncancelable(ip.io);
    defer ip.mutex.unlock(ip.io);
    return ip.items.capacity() * @sizeOf(Key) + ip.map.capacity() * (@sizeOf(Key) + @sizeOf(Index) + 1) + ip.arena.queryCapacity();
}

/// The target parameters value computations on this thread use: those of the compilation the
/// innermost computation in progress runs in (see `enterContext`); null outside every compilation,
/// where the parameters common to all compilations (`target`) apply. A computation runs entirely
/// on one thread, and nested computations restore it when they return.
threadlocal var active_target: ?*const Target = null;

fn currentTarget(ip: *const InternPool) *const Target {
    return active_target orelse &ip.target;
}

pub fn pointerBits(ip: *const InternPool) ?u16 {
    return ip.currentTarget().pointer_bits;
}

pub fn vectorAbi(ip: *const InternPool) VectorAbi {
    return ip.currentTarget().vector_abi;
}

pub fn scalarAbi(ip: *const InternPool) *const ScalarAbi {
    return &ip.currentTarget().scalar_abi;
}

pub fn errorBits(ip: *const InternPool) ?u16 {
    return ip.currentTarget().error_bits;
}

/// May only be called in a write transaction
pub fn setTarget(ip: *InternPool, t: Target) void {
    ip.target = t;
}

/// Replaces the target parameters of the compilations. May only be called in a write transaction.
pub fn setTargets(ip: *InternPool, targets: []const Target) Allocator.Error!void {
    const copy = try ip.gpa.dupe(Target, targets);
    ip.gpa.free(ip.targets);
    ip.targets = copy;
}

/// Makes value computations on this thread use the target of compilation `context` (null: the
/// parameters common to all compilations) until `leaveContext` is called with the returned value
pub fn enterContext(ip: *const InternPool, context: ?u32) ?*const Target {
    const prev = active_target;
    active_target = if (context) |c| (if (c < ip.targets.len) &ip.targets[c] else null) else null;
    return prev;
}

pub fn leaveContext(prev: ?*const Target) void {
    active_target = prev;
}

/// Target-dependent parameters for value computations; defaults to the native target
pub const Target = struct {
    /// Pointer bit width; null when unknown (the targets the parameters are common to disagree)
    pointer_bits: ?u16 = @bitSizeOf(usize),
    vector_abi: VectorAbi = .unknown,
    scalar_abi: ScalarAbi = .native,
    /// Bit width of error codes, set by the compilation's error limit (`errorBitsOf`); null when
    /// the compilations the parameters are common to disagree
    error_bits: ?u16 = errorBitsOf(null),
};

/// Bit width of error codes for the error limit of a compilation (`--error-limit`, the compiler's
/// default when null): enough bits for the largest error value, as the compiler's
/// `Zcu.errorSetBits`
pub fn errorBitsOf(error_limit: ?u32) u16 {
    const limit: u32 = error_limit orelse std.math.maxInt(u16);
    return 32 - @clz(limit);
}

/// Layouts of integer, float and C types, and the bit widths and signedness of C integer types
/// (the corresponding branches of the compiler's `Type.abiAlignment` / `abiSize` / `intInfo`),
/// computed from `std.Target` by the compiler's rules
pub const ScalarAbi = struct {
    /// The minimum and maximum across modules of the maximum alignment of fixed-width integers
    /// (`std.Target.cMaxIntAlignment`). The alignment of an integer is its byte size rounded up
    /// to a power of 2, but no larger than the maximum alignment; when the two differ, the layout
    /// of integers whose alignment is affected by the maximum alignment is unknown.
    max_int_align: struct { min: u16, max: u16 },
    /// Signedness of `c_char`; null when the target has no C ABI or the modules disagree
    c_char_signedness: ?std.builtin.Signedness,
    /// Layout of each type; null when the target does not define it (no C ABI, etc.) or the
    /// modules disagree
    types: std.EnumArray(Type, ?Scalar),

    /// Types whose layout depends on the target and cannot be derived from the integer rules
    /// (unsigned types such as `c_ushort` are the same as the corresponding signed types)
    pub const Type = enum { c_char, c_short, c_int, c_long, c_longlong, c_longdouble, f32, f64, f80, f128 };

    pub const Scalar = struct { size: u16, alignment: u16, bits: u16 };

    pub const native: ScalarAbi = .of(&builtin.target);

    /// Unknown target: only integers whose alignment does not depend on the target (at most 1
    /// byte) have a determined layout
    pub const unknown: ScalarAbi = .{
        .max_int_align = .{ .min = 1, .max = std.math.maxInt(u16) },
        .c_char_signedness = null,
        .types = .initFill(null),
    };

    pub fn of(t: *const std.Target) ScalarAbi {
        const max_align = t.cMaxIntAlignment();
        var r: ScalarAbi = .{
            .max_int_align = .{ .min = max_align, .max = max_align },
            .c_char_signedness = null,
            .types = .initFill(null),
        };
        // std does not define the sizes of C types for these systems (`cTypeBitSize` panics),
        // and the float rules depend on them too
        switch (t.os.tag) {
            .ps3, .contiki, .managarm => return r,
            else => {},
        }
        r.c_char_signedness = t.cCharSignedness();
        inline for (.{ .c_char, .c_short, .c_int, .c_long, .c_longlong }, .{ .char, .short, .int, .long, .longlong }) |k, c| {
            r.types.set(k, cType(t, c));
        }
        // std defines the size of long double only when it is 64, 80 or 128 bits (the 32-bit
        // long double of AVR is unreachable in `cTypeByteSize`)
        if (t.cTypeBitSize(.longdouble)) |bits| switch (bits) {
            64, 80, 128 => r.types.set(.c_longdouble, cType(t, .longdouble)),
            else => {},
        };
        // The following matches the float branches of the compiler's `Type.abiAlignment` /
        // `abiSize`: the C type when the bit width matches the C type, otherwise the integer
        // that represents it, or the soft float representation of compiler-rt
        r.types.set(.f32, if (t.cTypeBitSize(.float) == 32) cType(t, .float) else intScalar(t, 32));
        r.types.set(.f64, if (t.cTypeBitSize(.double) == 64) cType(t, .double) else intScalar(t, 64));
        r.types.set(.f80, if (t.cTypeBitSize(.longdouble) == 80) r.types.get(.c_longdouble) else switch (std.zig.target.compilerRtFloatAbi(t, 80)) {
            .hard => intScalar(t, 80),
            // u64 mantissa and u16 exponent
            .soft => blk: {
                const alignment = @max(std.zig.target.intAlignment(t, 64), std.zig.target.intAlignment(t, 16));
                const size = std.mem.alignForward(u16, std.zig.target.intByteSize(t, 64) + std.zig.target.intByteSize(t, 16), alignment);
                break :blk .{ .size = size, .alignment = alignment, .bits = 80 };
            },
        });
        r.types.set(.f128, if (t.cTypeBitSize(.longdouble) == 128) r.types.get(.c_longdouble) else switch (std.zig.target.compilerRtFloatAbi(t, 128)) {
            // x86 follows C's `__float128`
            .hard => if (t.cpu.arch.isX86()) .{ .size = 16, .alignment = 16, .bits = 128 } else intScalar(t, 128),
            // Two u64s
            .soft => .{ .size = 2 * std.zig.target.intByteSize(t, 64), .alignment = std.zig.target.intAlignment(t, 64), .bits = 128 },
        });
        return r;
    }

    fn cType(t: *const std.Target, c: std.Target.CType) ?Scalar {
        return .{
            .size = t.cTypeByteSize(c) orelse return null,
            .alignment = t.cTypeAlignment(c) orelse return null,
            .bits = t.cTypeBitSize(c) orelse return null,
        };
    }

    fn intScalar(t: *const std.Target, bits: u16) Scalar {
        return .{ .size = std.zig.target.intByteSize(t, bits), .alignment = std.zig.target.intAlignment(t, bits), .bits = bits };
    }

    /// The parts on which two sets of parameters agree (when a project has multiple targets)
    pub fn merge(a: ScalarAbi, b: ScalarAbi) ScalarAbi {
        var r = a;
        r.max_int_align = .{ .min = @min(a.max_int_align.min, b.max_int_align.min), .max = @max(a.max_int_align.max, b.max_int_align.max) };
        if (a.c_char_signedness != b.c_char_signedness) r.c_char_signedness = null;
        for (&r.types.values, b.types.values) |*x, y| {
            if (!std.meta.eql(x.*, y)) x.* = null;
        }
        return r;
    }
};

/// Layout rules for vectors (the vector branch of `Type.abiAlignment` / `abiSize`), determined by
/// the compiler backend, the architecture and the CPU features
pub const VectorAbi = enum(u8) {
    unknown,
    /// The alignment is the byte size rounded up to a power of 2 (LLVM and other backends)
    llvm,
    /// Like `llvm`, but no larger than the stack alignment of 16 (aarch64)
    llvm_aarch64,
    /// The self-hosted x86_64 backend: the alignment is at least 16; with AVX / AVX-512,
    /// vectors larger than 16 / 32 bytes are aligned to 32 / 64
    x86_64,
    x86_64_avx,
    x86_64_avx512,
    /// The alignment of the element (C and wasm backends)
    elem,

    pub fn of(backend: std.lang.CompilerBackend, arch: std.Target.Cpu.Arch, avx: bool, avx512f: bool, soft_float: bool) VectorAbi {
        // Soft float on x86: float elements use the element layout, and element types are not
        // distinguished here
        if (soft_float) return .unknown;
        return switch (backend) {
            .stage2_x86_64 => if (avx512f) .x86_64_avx512 else if (avx) .x86_64_avx else .x86_64,
            .stage2_c, .stage2_wasm => .elem,
            // Other backends go by the byte size. On ARM and s390x the alignment does not exceed
            // their respective stack alignments, and f16 is soft float on MIPS and PowerPC, so
            // only common architectures are handled
            else => switch (arch) {
                .x86, .x86_64, .riscv32, .riscv64, .wasm32, .wasm64, .loongarch64 => .llvm,
                .aarch64, .aarch64_be => .llvm_aarch64,
                else => .unknown,
            },
        };
    }
};

/// Interns: the same Key returns the same Index. C pointers always allow zero (as the compiler
/// canonicalizes them), so `allowzero` is dropped from them.
pub fn get(ip: *InternPool, key_in: Key) Allocator.Error!Index {
    var k = key_in;
    if (k == .ptr_type and k.ptr_type.size == .c) k.ptr_type.attrs.is_allowzero = false;
    // Hashed before taking the lock: only probing the table is serialized
    const hashed: Prehashed = .{ .h = KeyContext.hash(.{}, k) };
    ip.mutex.lockUncancelable(ip.io);
    defer ip.mutex.unlock(ip.io);
    if (ip.map.getAdapted(k, hashed)) |i| return i;
    const owned = try ip.own(k);
    const index: Index = @fromBackingInt(try ip.items.append(ip.gpa, owned));
    errdefer ip.items.len -= 1;
    try ip.map.putNoClobber(ip.gpa, owned, index);
    return index;
}

/// Lookup context carrying a hash already computed with `KeyContext`
const Prehashed = struct {
    h: u64,
    pub fn hash(c: Prehashed, _: Key) u64 {
        return c.h;
    }
    pub fn eql(_: Prehashed, a: Key, b: Key) bool {
        return keyEql(a, b);
    }
};

/// Copies the slices in a Key into the arena
fn own(ip: *InternPool, k: Key) Allocator.Error!Key {
    const a = ip.arena.allocator();
    return switch (k) {
        .error_set_type => |es| blk: {
            const out = try a.alloc([]const u8, es.names.len);
            for (es.names, out) |n, *o| o.* = try a.dupe(u8, n);
            break :blk .{ .error_set_type = .{ .names = out, .sorted = try a.dupe(u32, es.sorted) } };
        },
        .fn_type => |f| .{ .fn_type = .{ .params = try a.dupe(Index, f.params), .ret = f.ret, .varargs = f.varargs } },
        .enum_literal => |n| .{ .enum_literal = try a.dupe(u8, n) },
        .abstract_array_type => |t| .{ .abstract_array_type = .{ .len = if (t.len) |l| try a.dupe(u8, l) else null, .child = t.child, .sentinel = t.sentinel } },
        .enum_tag => |t| .{ .enum_tag = .{ .ty = t.ty, .name = try a.dupe(u8, t.name) } },
        .error_value => |n| .{ .error_value = try a.dupe(u8, n) },
        .instance => |i| .{ .instance = .{ .file = i.file, .decl = i.decl, .args = try a.dupe(Index, i.args), .parent = i.parent, .iteration = i.iteration } },
        .tuple_type => |t| .{ .tuple_type = .{ .types = try a.dupe(Index, t.types), .values = try a.dupe(Index, t.values) } },
        .anon_struct_type => |t| .{ .anon_struct_type = .{ .names = try dupeNames(a, t.names), .types = try a.dupe(Index, t.types), .values = try a.dupe(Index, t.values) } },
        .reified_type => |t| blk: {
            var out = t;
            out.names = try dupeNames(a, t.names);
            out.types = try a.dupe(Index, t.types);
            out.values = try a.dupe(i128, t.values);
            out.field_aligns = try a.dupe(u64, t.field_aligns);
            out.comptime_fields = try a.dupe(bool, t.comptime_fields);
            break :blk .{ .reified_type = out };
        },
        .aggregate => |v| .{ .aggregate = .{ .ty = v.ty, .elems = try a.dupe(Index, v.elems) } },
        .bytes => |v| .{ .bytes = .{ .ty = v.ty, .bytes = try a.dupe(u8, v.bytes) } },
        .union_value => |v| .{ .union_value = .{ .ty = v.ty, .tag = try a.dupe(u8, v.tag), .payload = v.payload } },
        .opaque_param => |o| .{ .opaque_param = .{ .file = o.file, .owner = o.owner, .binding = o.binding, .name = try a.dupe(u8, o.name) } },
        else => k,
    };
}

fn dupeNames(a: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, names.len);
    for (names, out) |n, *o| o.* = try a.dupe(u8, n);
    return out;
}

/// Number of interned types and values
pub fn count(ip: *InternPool) usize {
    ip.mutex.lockUncancelable(ip.io);
    defer ip.mutex.unlock(ip.io);
    return ip.items.len;
}

/// The slices in the returned Key are valid for the lifetime of the InternPool. Takes no lock (see
/// `Items`).
pub fn key(ip: *InternPool, index: Index) Key {
    return ip.items.at(@backingInt(index)).*;
}

// ── Common constructors ──────────────────────────────────────────────

pub fn intType(ip: *InternPool, signedness: std.builtin.Signedness, bits: u16) Allocator.Error!Index {
    return ip.get(.{ .int_type = .{ .signedness = signedness, .bits = bits } });
}

pub fn optionalOf(ip: *InternPool, child: Index) Allocator.Error!Index {
    if (child == .unknown) return .unknown;
    return ip.get(.{ .optional_type = child });
}

pub fn ptrTo(ip: *InternPool, child: Index, size: PtrSize, is_const: bool) Allocator.Error!Index {
    if (child == .unknown) return .unknown;
    return ip.get(.{ .ptr_type = .{ .child = child, .size = size, .is_const = is_const } });
}

/// Error set with the given names (later duplicates are dropped); when a set with the same
/// members already exists, that set (with the order of its names) is returned
pub fn errorSet(ip: *InternPool, gpa: Allocator, names: []const []const u8) Allocator.Error!Index {
    // Positions ordered by the bytes of the names, equal names by position: the first occurrence
    // of a name comes first
    const order = try gpa.alloc(u32, names.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, names, struct {
        fn lt(ns: []const []const u8, a: u32, b: u32) bool {
            return switch (std.mem.order(u8, ns[a], ns[b])) {
                .lt => true,
                .gt => false,
                .eq => a < b,
            };
        }
    }.lt);
    // Position of each first occurrence among the kept names (`dropped` for duplicates)
    const dropped = std.math.maxInt(u32);
    const pos = try gpa.alloc(u32, names.len);
    defer gpa.free(pos);
    @memset(pos, dropped);
    var prev: ?u32 = null;
    for (order) |i| if (prev == null or !std.mem.eql(u8, names[prev.?], names[i])) {
        pos[i] = 0;
        prev = i;
    };
    const kept = try gpa.alloc([]const u8, names.len);
    defer gpa.free(kept);
    var n: u32 = 0;
    for (names, pos) |name, *p| if (p.* != dropped) {
        kept[n] = name;
        p.* = n;
        n += 1;
    };
    // `order` becomes the positions of the kept names ordered by bytes (written behind reading)
    var m: usize = 0;
    for (order) |i| if (pos[i] != dropped) {
        order[m] = pos[i];
        m += 1;
    };
    return ip.get(.{ .error_set_type = .{ .names = kept[0..n], .sorted = order[0..m] } });
}

/// Type of a string literal, `*const [len:0]u8`
pub fn stringLiteralType(ip: *InternPool, len: u64) Allocator.Error!Index {
    const zero = try ip.get(.{ .int_value = .{ .ty = .u8_type, .value = 0 } });
    const array = try ip.get(.{ .array_type = .{ .len = len, .child = .u8_type, .sentinel = zero } });
    return ip.ptrTo(array, .one, true);
}

pub fn isInt(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .int_type => true,
        .simple_type => |s| switch (s) {
            .usize, .isize, .comptime_int, .c_char, .c_short, .c_ushort, .c_int, .c_uint, .c_long, .c_ulong, .c_longlong, .c_ulonglong => true,
            else => false,
        },
        else => false,
    };
}

pub fn isFloat(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .simple_type => |s| switch (s) {
            .f16, .f32, .f64, .f80, .f128, .comptime_float, .c_longdouble => true,
            else => false,
        },
        else => false,
    };
}

// ── Display ──────────────────────────────────────────────────────────

/// Prints a type or value in Zig syntax. `container_name` provides the names of container types
/// (such as `mem.Allocator`).
pub fn print(ip: *InternPool, index: Index, w: *Io.Writer, container_name: anytype) Io.Writer.Error!void {
    switch (ip.key(index)) {
        .unknown => try w.writeAll("unknown"),
        // Types without a name of their own are written as Zig spells them
        .simple_type => |s| try w.writeAll(switch (s) {
            .null => "@TypeOf(null)",
            .undefined => "@TypeOf(undefined)",
            .enum_literal => "@EnumLiteral()",
            else => @tagName(s),
        }),
        .int_type => |i| try w.print("{c}{d}", .{ @as(u8, if (i.signedness == .signed) 'i' else 'u'), i.bits }),
        .ptr_type => |p| {
            switch (p.size) {
                .one => try w.writeAll("*"),
                .many, .slice, .c => {
                    try w.writeAll(switch (p.size) {
                        .many => "[*",
                        .slice => "[",
                        else => "[*c",
                    });
                    if (p.sentinel) |s| {
                        try w.writeAll(":");
                        try ip.print(s, w, container_name);
                    }
                    try w.writeAll("]");
                },
            }
            try writePtrQualifiers(p, w);
            try ip.print(p.child, w, container_name);
        },
        .array_type => |a| {
            try w.print("[{d}", .{a.len});
            if (a.sentinel) |s| {
                try w.writeAll(":");
                try ip.print(s, w, container_name);
            }
            try w.writeAll("]");
            try ip.print(a.child, w, container_name);
        },
        .abstract_array_type => |a| {
            try w.print("[{s}", .{a.len orelse "_"});
            if (a.sentinel) |s| {
                try w.writeAll(":");
                try ip.print(s, w, container_name);
            }
            try w.writeAll("]");
            try ip.print(a.child, w, container_name);
        },
        .optional_type => |c| {
            try w.writeAll("?");
            try ip.print(c, w, container_name);
        },
        .error_union_type => |e| {
            try ip.print(e.err, w, container_name);
            try w.writeAll("!");
            try ip.print(e.payload, w, container_name);
        },
        .inferred_error_set => if (@hasDecl(@TypeOf(container_name), "writeInferredErrorSet")) try container_name.writeInferredErrorSet(index, w) else try w.writeAll("anyerror"),
        .error_set_type => |es| {
            try w.writeAll("error{");
            for (es.sorted, 0..) |n, i| {
                if (i != 0) try w.writeAll(",");
                if (try truncateList(container_name, w, es.sorted.len)) break;
                try w.writeAll(es.names[n]);
            }
            try w.writeAll("}");
        },
        .fn_type => |f| {
            try w.writeAll("fn (");
            for (f.params, 0..) |p, i| {
                if (i != 0) try w.writeAll(", ");
                if (try truncateList(container_name, w, f.params.len)) break;
                try ip.print(p, w, container_name);
            }
            if (f.varargs) try w.writeAll(if (f.params.len != 0) ", ..." else "...");
            try w.writeAll(") ");
            try ip.print(f.ret, w, container_name);
        },
        .container_type => |c| try container_name.write(c, w),
        // Matches the compiler: `struct { comptime u8 = 1, u32 }`, and the empty tuple is
        // `@TypeOf(.{})`
        .tuple_type => |t| {
            if (t.types.len == 0) return w.writeAll("@TypeOf(.{})");
            try w.writeAll("struct {");
            for (t.types, 0..) |ty, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                if (try truncateList(container_name, w, t.types.len)) break;
                try ip.printField(null, ty, fieldValue(t.values, i), w, container_name);
            }
            try w.writeAll(" }");
        },
        .vector_type => |v| {
            try w.print("@Vector({d}, ", .{v.len});
            try ip.print(v.child, w, container_name);
            try w.writeAll(")");
        },
        .anon_struct_type => |t| {
            try w.writeAll("struct {");
            for (t.names, t.types, 0..) |n, ty, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                if (try truncateList(container_name, w, t.names.len)) break;
                try ip.printField(n, ty, fieldValue(t.values, i), w, container_name);
            }
            try w.writeAll(if (t.names.len == 0) "}" else " }");
        },
        .reified_type => |t| if (@hasDecl(@TypeOf(container_name), "writeReified")) try container_name.writeReified(t, w) else try ip.printReified(t, w, container_name),
        .union_tag_type => |u| {
            try w.writeAll("@typeInfo(");
            try ip.print(u, w, container_name);
            try w.writeAll(").@\"union\".tag_type.?");
        },
        // The void value is written as `{}` (`void` is the type)
        .simple_value => |v| try w.writeAll(if (v == .void) "{}" else @tagName(v)),
        .int_value => |v| try w.print("{d}", .{v.value}),
        .float_value => |v| {
            // Prints the shortest representation for the type of the value (√2 as f32 is
            // 1.4142135, not its expansion as f128)
            const x: f128 = @bitCast(v.bits);
            switch (ip.key(v.ty)) {
                .simple_type => |t| switch (t) {
                    .f16 => try w.print("{d}", .{@as(f16, @floatCast(x))}),
                    .f32 => try w.print("{d}", .{@as(f32, @floatCast(x))}),
                    .f64 => try w.print("{d}", .{@as(f64, @floatCast(x))}),
                    .f80 => try w.print("{d}", .{@as(f80, @floatCast(x))}),
                    else => try w.print("{d}", .{x}),
                },
                else => try w.print("{d}", .{x}),
            }
        },
        .enum_literal => |n| try w.print(".{f}", .{std.zig.fmtId(n)}),
        .enum_tag => |t| try w.print(".{f}", .{std.zig.fmtId(t.name)}),
        .error_value => |n| try w.print("error.{s}", .{n}),
        .fn_value => |f| try ip.print(f.ty, w, container_name),
        .aggregate => |v| {
            if (ip.key(v.ty) == .ptr_type) try w.writeAll("&");
            // Struct values include the field names
            const names: ?[]const []const u8 = if (@hasDecl(@TypeOf(container_name), "fieldNames")) container_name.fieldNames(v.ty) else null;
            try w.writeAll(".{");
            for (v.elems, 0..) |e, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                if (try truncateList(container_name, w, v.elems.len)) break;
                if (names) |n| if (i < n.len) try w.print(".{f} = ", .{std.zig.fmtId(n[i])});
                try ip.print(e, w, container_name);
            }
            try w.writeAll(if (v.elems.len == 0) "}" else " }");
        },
        .bytes => |v| switch (ip.key(v.ty)) {
            .array_type, .ptr_type => {
                try w.writeAll("\"");
                const shown = try writeStringPrefix(v.bytes, remaining(container_name, w), w);
                if (shown == v.bytes.len) return w.writeAll("\"");
                try w.writeAll("…\"");
                try writeTotal(container_name, w, v.bytes.len, " bytes");
            },
            // Structs, tuples and vectors whose elements are all u8 (also represented as
            // bytes): shown element by element like an aggregate
            else => {
                const names: ?[]const []const u8 = if (@hasDecl(@TypeOf(container_name), "fieldNames")) container_name.fieldNames(v.ty) else null;
                try w.writeAll(".{");
                for (v.bytes, 0..) |byte, i| {
                    try w.writeAll(if (i == 0) " " else ", ");
                    if (try truncateList(container_name, w, v.bytes.len)) break;
                    if (names) |n| if (i < n.len) try w.print(".{f} = ", .{std.zig.fmtId(n[i])});
                    try w.print("{d}", .{byte});
                }
                try w.writeAll(if (v.bytes.len == 0) "}" else " }");
            },
        },
        .union_value => |v| {
            try w.print(".{{ .{f} = ", .{std.zig.fmtId(v.tag)});
            try ip.print(v.payload, w, container_name);
            try w.writeAll(" }");
        },
        .ptr_value => |v| {
            try w.writeAll("&");
            try ip.print(v.pointee, w, container_name);
        },
        .instance, .context => try w.writeAll("instance"),
        .opaque_param => |o| try w.writeAll(o.name),
        .runtime => try w.writeAll("_"),
    }
}

/// `container_name.remaining(w)`: the number of characters the output can still take (the
/// length limit of inlay hints); null means unlimited
fn remaining(container_name: anytype, w: *Io.Writer) ?usize {
    return if (@hasDecl(@TypeOf(container_name), "remaining")) container_name.remaining(w) else null;
}

/// Called before writing the next item of a list (fields, elements, parameters): when the output
/// is already full, writes `…` (see `writeTotal`) and returns true, and the list stops there. The
/// output can thus exceed the limit by one item; strings are written only up to the limit.
/// `total` is the number of items in the list.
pub fn truncateList(container_name: anytype, w: *Io.Writer, total: usize) Io.Writer.Error!bool {
    if (remaining(container_name, w) != 0) return false;
    try w.writeAll("…");
    try writeTotal(container_name, w, total, "");
    return true;
}

/// After the `…` of a cut list or string: ` (N total)` with the full number of items (or of
/// `unit`s) when `container_name.show_total` is set, so that the cut states how much is left out
fn writeTotal(container_name: anytype, w: *Io.Writer, total: usize, unit: []const u8) Io.Writer.Error!void {
    if (@hasField(@TypeOf(container_name), "show_total") and container_name.show_total) try w.print(" ({d}{s} total)", .{ total, unit });
}

/// Writes `text` escaped as in a string literal, stopping once about `limit` characters are
/// written (null: no limit); returns the number of bytes written. A valid UTF-8 sequence is
/// written whole, so the output is the same as escaping the whole string at once.
fn writeStringPrefix(text: []const u8, limit: ?usize, w: *Io.Writer) Io.Writer.Error!usize {
    const max = limit orelse {
        try std.zig.stringEscape(text, w);
        return text.len;
    };
    var i: usize = 0;
    var written: usize = 0;
    while (i < text.len and written < max) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const unit = if (i + len <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..len])) len else 1;
        const before = w.buffered().len;
        try std.zig.stringEscape(text[i..][0..unit], w);
        const out = w.buffered()[before..];
        written += std.unicode.utf8CountCodepoints(out) catch out.len;
        i += unit;
    }
    return i;
}

/// The qualifiers of a pointer type between its size and its child, in the order the compiler
/// prints them: `allowzero align(a:b:h) addrspace(.x) const volatile ` (each only when present;
/// C pointers never print `allowzero`). Parts that cannot be evaluated print as `unknown`.
pub fn writePtrQualifiers(p: PtrType, w: *Io.Writer) Io.Writer.Error!void {
    const a = p.attrs;
    if (a.is_allowzero) try w.writeAll("allowzero ");
    if (a.alignment != .natural or a.host_size != 0) {
        if (a.alignment.bytes()) |n| try w.print("align({d}", .{n}) else try w.writeAll("align(unknown");
        if (a.host_size != 0) try w.print(":{d}:{d}", .{ a.bit_offset, a.host_size });
        try w.writeAll(") ");
    }
    if (a.address_space) |space| {
        if (space != .generic) try w.print("addrspace(.{t}) ", .{space});
    } else try w.writeAll("addrspace(unknown) ");
    if (p.is_const) try w.writeAll("const ");
    if (a.is_volatile) try w.writeAll("volatile ");
}

/// A field of a tuple or anonymous struct: comptime fields include their value
/// (`comptime a: u8 = 1`)
fn printField(ip: *InternPool, name: ?[]const u8, ty: Index, v: Index, w: *Io.Writer, container_name: anytype) Io.Writer.Error!void {
    const is_comptime = v != .runtime and v != .unknown;
    if (is_comptime) try w.writeAll("comptime ");
    if (name) |n| try w.print("{f}: ", .{std.zig.fmtId(n)});
    try ip.print(ty, w, container_name);
    if (!is_comptime) return;
    try w.writeAll(" = ");
    try ip.print(v, w, container_name);
}

/// Displays a constructed type by its contents when there is no name for its construction
/// location
pub fn printReified(ip: *InternPool, t: Reified, w: *Io.Writer, container_name: anytype) Io.Writer.Error!void {
    try w.print("{t} {{", .{t.kind});
    for (t.names, 0..) |n, i| {
        try w.writeAll(if (i == 0) " " else ", ");
        if (try truncateList(container_name, w, t.names.len)) break;
        try w.writeAll(n);
        if (i < t.types.len) {
            try w.writeAll(": ");
            try ip.print(t.types[i], w, container_name);
        }
    }
    try w.writeAll(if (t.names.len == 0) "}" else " }");
}

const testing = std.testing;

test "interning is idempotent and presets are stable" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    try testing.expectEqual(Index.u8_type, try ip.intType(.unsigned, 8));
    const a = try ip.ptrTo(.u8_type, .slice, true);
    const b = try ip.ptrTo(.u8_type, .slice, true);
    try testing.expectEqual(a, b);
    try testing.expect(a != try ip.ptrTo(.u8_type, .slice, false));
    try testing.expectEqual(try ip.errorSet(testing.allocator, &.{ "B", "A", "B" }), try ip.errorSet(testing.allocator, &.{ "A", "B" }));

    const Names = struct {
        fn write(_: @This(), _: Container, w: *Io.Writer) Io.Writer.Error!void {
            try w.writeAll("S");
        }
    };
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try ip.print(try ip.stringLiteralType(5), &w, Names{});
    try testing.expectEqualStrings("*const [5:0]u8", w.buffered());
    w.end = 0;
    const eu = try ip.get(.{ .error_union_type = .{ .err = .anyerror_type, .payload = try ip.optionalOf(a) } });
    try ip.print(eu, &w, Names{});
    try testing.expectEqualStrings("anyerror!?[]const u8", w.buffered());
}

test "types of null, undefined and enum literals print as Zig spells them" {
    // Prevents displaying them as `null`, `undefined` and `enum_literal`, which are not types
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const cases = [_]struct { Index, []const u8 }{
        .{ .null_type, "@TypeOf(null)" },
        .{ .undefined_type, "@TypeOf(undefined)" },
        .{ .enum_literal_type, "@EnumLiteral()" },
        .{ try ip.optionalOf(.enum_literal_type), "?@EnumLiteral()" },
    };
    for (cases) |c| {
        w.end = 0;
        try ip.print(c[0], &w, struct {
            fn write(_: @This(), _: Container, _: *Io.Writer) Io.Writer.Error!void {}
        }{});
        try testing.expectEqualStrings(c[1], w.buffered());
    }
}

test "reset keeps the presets and frees everything else" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    const n = ip.count();
    const slice = try ip.ptrTo(.u8_type, .slice, true);
    _ = try ip.errorSet(testing.allocator, &.{ "A", "B" });
    try testing.expect(ip.count() > n);
    try ip.reset();
    try testing.expectEqual(n, ip.count());
    try testing.expectEqual(Index.u8_type, try ip.intType(.unsigned, 8));
    // Interning again yields the same position (the index depends only on the interning order)
    try testing.expectEqual(slice, try ip.ptrTo(.u8_type, .slice, true));
}

test "concurrent interning across chunk boundaries gives each key one index and its key back" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    // Enough keys to fill several chunks while other threads read keys without the lock
    const n = 5000;
    const Worker = struct {
        fn run(pool: *InternPool, out: *[n]Index, failed: *std.atomic.Value(bool)) void {
            for (out, 0..) |*o, i| {
                const bits: u16 = @intCast(i + 1);
                o.* = pool.intType(.signed, bits) catch return failed.store(true, .monotonic);
                const k = pool.key(o.*);
                if (k != .int_type or k.int_type.bits != bits or k.int_type.signedness != .signed) failed.store(true, .monotonic);
            }
        }
    };
    var results: [4][n]Index = undefined;
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    for (&threads, &results) |*t, *r| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &ip, r, &failed });
        spawned += 1;
    }
    for (threads) |t| t.join();
    spawned = 0;
    try testing.expect(!failed.load(.monotonic));
    for (results[1..]) |r| try testing.expectEqualSlices(Index, &results[0], &r);
    try testing.expectEqual(preset.len + n, ip.count());
}

test "reset that runs out of memory leaves the pool intact" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var ip: InternPool = try .init(failing.allocator(), testing.io);
    defer ip.deinit();
    const slice = try ip.ptrTo(.u8_type, .slice, true);
    const n = ip.count();
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, ip.reset());
    failing.fail_index = std.math.maxInt(usize);
    // Nothing was reclaimed; the original items (including the presets) are still valid
    try testing.expectEqual(n, ip.count());
    try testing.expectEqual(Index.u8_type, try ip.intType(.unsigned, 8));
    try testing.expectEqual(slice, try ip.ptrTo(.u8_type, .slice, true));
}
