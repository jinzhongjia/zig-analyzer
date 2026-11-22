//! Scheduling of a background task that runs one pass at a time: scheduling it while a pass runs
//! makes the task do another pass instead of starting a second task.

const std = @import("std");

const Rerun = @This();

/// Incremented by every `schedule`; a pass covers the requests counted before it began
generation: std.atomic.Value(u64) = .init(0),
/// A task is running
running: std.atomic.Value(bool) = .init(false),

/// Counts a request; returns whether the caller must start the task (none is running)
pub fn schedule(r: *Rerun) bool {
    _ = r.generation.fetchAdd(1, .acq_rel);
    return !r.running.swap(true, .acq_rel);
}

/// The generation a pass that begins now covers
pub fn begin(r: *const Rerun) u64 {
    return r.generation.load(.acquire);
}

pub const Next = enum {
    /// Scheduled during the pass: do another one (the task kept running)
    again,
    /// Scheduled after the task stopped running, and no other task took over: do another one
    resumed,
    /// Nothing scheduled since the pass began: the task has stopped
    done,
    /// Scheduled after the task stopped running, and another task took over: stop
    taken_over,
};

/// Called by the task after the pass that began at `generation`; except for `again`, `running`
/// has been cleared in between
pub fn finish(r: *Rerun, generation: u64) Next {
    if (r.generation.load(.acquire) != generation) return .again;
    r.running.store(false, .release);
    if (r.generation.load(.acquire) == generation) return .done;
    return if (r.running.swap(true, .acq_rel)) .taken_over else .resumed;
}

/// Called by the task when it stops after a failed pass
pub fn stop(r: *Rerun) void {
    r.running.store(false, .release);
}

const testing = std.testing;

test "one task at a time; requests during a pass make it run again" {
    var r: Rerun = .{};
    try testing.expect(r.schedule());
    try testing.expect(!r.schedule());
    const g = r.begin();
    try testing.expectEqual(Next.done, r.finish(g));
    try testing.expect(!r.running.load(.acquire));

    try testing.expect(r.schedule());
    const g1 = r.begin();
    try testing.expect(!r.schedule());
    try testing.expectEqual(Next.again, r.finish(g1));
    try testing.expectEqual(Next.done, r.finish(r.begin()));
    try testing.expect(r.schedule());
}
