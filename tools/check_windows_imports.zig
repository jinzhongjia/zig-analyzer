//! Fails when a Windows executable imports a function that Windows 10 1507 lacks. Zig supports
//! Windows 10 from its first release (1507), and the loader refuses to start a program that
//! imports a function its DLL does not export. The mingw-w64 `.def` files bundled with Zig
//! (`libc/mingw/lib32`) list the symbols of ntdll, kernel32 and advapi32 grouped by the Windows
//! version that introduced them; an import from one of these DLLs must not be listed in a group
//! after Windows 10 1507. Imports from other DLLs are not checked.
//!
//! Usage: check_windows_imports <exe> <mingw lib32 directory>

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const coff = std.coff;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.log.err("usage: check_windows_imports <exe> <mingw lib32 directory>", .{});
        return 2;
    }
    const data = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    const imports = try importedFunctions(arena, data);
    var def_dir = try Io.Dir.cwd().openDir(io, args[2], .{});
    defer def_dir.close(io);

    var failed = false;
    var later_by_dll: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    for (imports) |import| {
        const gop = try later_by_dll.getOrPut(arena, import.dll);
        if (!gop.found_existing) {
            const def_name = try std.fmt.allocPrint(arena, "{s}.def", .{import.dll});
            const text = def_dir.readFileAlloc(io, def_name, arena, .unlimited) catch |err| switch (err) {
                error.FileNotFound => "",
                else => |e| return e,
            };
            gop.value_ptr.* = try symbolsAfter1507(arena, text);
        }
        if (gop.value_ptr.contains(import.name)) {
            std.log.err("{s} imports {s}!{s}, which Windows 10 1507 lacks", .{ args[1], import.dll, import.name });
            failed = true;
        }
    }
    return @intFromBool(failed);
}

const Import = struct {
    /// Lowercase DLL name without the `.dll` extension
    dll: []const u8,
    name: []const u8,
};

/// The functions a PE image imports by name, from its import directory
fn importedFunctions(arena: Allocator, data: []const u8) ![]Import {
    const image = try coff.Coff.init(data, false);
    if (!image.is_image) return error.NotAnImage;
    const pe32_plus = switch (image.getOptionalHeader().magic) {
        .PE32 => false,
        .@"PE32+" => true,
        _ => return error.UnknownOptionalHeader,
    };
    const dirs = image.getDataDirectories();
    const import_index = @backingInt(coff.IMAGE.DIRECTORY_ENTRY.IMPORT);
    if (dirs.len <= import_index or dirs[import_index].virtual_address == 0) return &.{};
    const sections = image.getSectionHeaders();

    var imports: std.ArrayList(Import) = .empty;
    var entry_offset = try fileOffset(sections, dirs[import_index].virtual_address);
    while (true) : (entry_offset += @sizeOf(coff.ImportDirectoryEntry)) {
        if (entry_offset + @sizeOf(coff.ImportDirectoryEntry) > data.len) return error.Truncated;
        const entry = std.mem.bytesToValue(coff.ImportDirectoryEntry, data[entry_offset..][0..@sizeOf(coff.ImportDirectoryEntry)]);
        if (entry.name_rva == 0) break;
        const dll_file = try cString(data, try fileOffset(sections, entry.name_rva));
        const dll = try std.ascii.allocLowerString(arena, if (std.ascii.endsWithIgnoreCase(dll_file, ".dll")) dll_file[0 .. dll_file.len - 4] else dll_file);
        const lookup_rva = if (entry.import_lookup_table_rva != 0) entry.import_lookup_table_rva else entry.import_address_table_rva;
        var lookup = try fileOffset(sections, lookup_rva);
        const width: usize = if (pe32_plus) 8 else 4;
        while (true) : (lookup += width) {
            if (lookup + width > data.len) return error.Truncated;
            const value: u64 = if (pe32_plus) std.mem.readInt(u64, data[lookup..][0..8], .little) else std.mem.readInt(u32, data[lookup..][0..4], .little);
            if (value == 0) break;
            const by_ordinal = if (pe32_plus) value >> 63 != 0 else value >> 31 != 0;
            if (by_ordinal) continue;
            // Hint/name entry: a 2-byte hint, then the name
            const hint_name = try fileOffset(sections, @intCast(value & 0x7fff_ffff));
            try imports.append(arena, .{ .dll = dll, .name = try cString(data, hint_name + 2) });
        }
    }
    return imports.items;
}

fn fileOffset(sections: []align(1) const coff.SectionHeader, rva: u32) !usize {
    for (sections) |s| {
        const size = @max(s.virtual_size, s.size_of_raw_data);
        if (rva >= s.virtual_address and rva - s.virtual_address < size) return s.pointer_to_raw_data + (rva - s.virtual_address);
    }
    return error.AddressOutsideSections;
}

fn cString(data: []const u8, offset: usize) ![]const u8 {
    if (offset >= data.len) return error.Truncated;
    const end = std.mem.indexOfScalarPos(u8, data, offset, 0) orelse return error.Truncated;
    return data[offset..end];
}

const windows_10_1507 = "; This is list of symbols added in Windows 10 (Threshold / 1507)";

/// The symbols a lib32 `.def` file lists in the groups after the Windows 10 1507 group (without
/// the `@<bytes>` stdcall suffix of 32-bit names); empty when the file has no 1507 group
fn symbolsAfter1507(arena: Allocator, def: []const u8) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var symbols: std.StringHashMapUnmanaged(void) = .empty;
    var state: enum { before, in_1507, after } = .before;
    var lines = std.mem.splitScalar(u8, def, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "; This is list of symbols")) {
            state = switch (state) {
                .before => if (std.mem.startsWith(u8, line, windows_10_1507)) .in_1507 else .before,
                .in_1507, .after => .after,
            };
            continue;
        }
        if (state != .after or line.len == 0 or line[0] == ';') continue;
        const token = line[0 .. std.mem.indexOfAny(u8, line, " \t;=") orelse line.len];
        const name = token[0 .. std.mem.indexOfScalar(u8, token, '@') orelse token.len];
        if (name.len > 0) try symbols.put(arena, name, {});
    }
    return symbols;
}

test symbolsAfter1507 {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const def =
        \\LIBRARY "ntdll.dll"
        \\EXPORTS
        \\; This is list of symbols added in Windows 8.1
        \\Old@4
        \\; This is list of symbols added in Windows 10 (Threshold / 1507)
        \\InFirstRelease@8
        \\; This is list of symbols added in Windows 10 Fall Creators Update (Redstone 3 / 1709)
        \\NtNotifyChangeDirectoryFileEx@40
        \\; NotExportedHere@4
        \\Data DATA
        \\
    ;
    var later = try symbolsAfter1507(arena.allocator(), def);
    try std.testing.expect(later.contains("NtNotifyChangeDirectoryFileEx"));
    try std.testing.expect(later.contains("Data"));
    try std.testing.expect(!later.contains("Old"));
    try std.testing.expect(!later.contains("InFirstRelease"));
    try std.testing.expect(!later.contains("NotExportedHere"));
    try std.testing.expectEqual(0, (try symbolsAfter1507(arena.allocator(), "Anything@4\n")).count());
}
