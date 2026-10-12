//! 模糊测试与随机性质测试共用的熵源：把一段字节按需解释为各种选择，字节耗尽后恒为 0。
//! 同一份输入既可以来自 `std.testing.Smith`（覆盖率引导），也可以来自固定种子的伪随机数。

const Entropy = @This();

/// 随机性质测试的迭代次数：Debug 下（带分配检查，慢一个数量级）取十分之一，
/// 优化构建（CI 的 ReleaseSafe 测试）跑全量
pub fn iterations(comptime full: usize) usize {
    return if (@import("builtin").mode == .debug) full / 10 else full;
}

bytes: []const u8,
pos: usize = 0,

pub fn byte(e: *Entropy) u8 {
    if (e.pos >= e.bytes.len) return 0;
    defer e.pos += 1;
    return e.bytes[e.pos];
}

pub fn below(e: *Entropy, n: usize) usize {
    if (n <= 1) return 0;
    const v = @as(usize, e.byte()) << 8 | e.byte();
    return v % n;
}

pub fn pick(e: *Entropy, comptime T: type, items: []const T) T {
    return items[e.below(items.len)];
}
