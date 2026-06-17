//! ExternalPty attaches Ghostty's terminal IO to file descriptors supplied by
//! the embedding host. It is intentionally macOS-only for Alan's embedded
//! GhosttyKit use case and does not own subprocess creation or lifecycle.
const ExternalPty = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const xev = @import("../global.zig").xev;
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const SegmentedPool = @import("../datastruct/main.zig").SegmentedPool;

const log = std.log.scoped(.io_external_pty);

/// The preallocation size for the write request pool. This should be big
/// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

read_fd: posix.fd_t,
write_fd: posix.fd_t,
close_read_fd: bool,
close_write_fd: bool,
fds_moved_to_thread: bool = false,

pub const Config = struct {
    /// File descriptor Ghostty reads terminal output from.
    read_fd: posix.fd_t,

    /// File descriptor Ghostty writes encoded terminal input to.
    write_fd: posix.fd_t,

    /// When false, Ghostty duplicates the supplied descriptors and leaves the
    /// caller's originals open. When true, Ghostty takes ownership of them.
    close_fds: bool = false,
};

pub fn init(cfg: Config) !ExternalPty {
    if (comptime builtin.target.os.tag != .macos) {
        return error.ExternalPtyUnsupportedPlatform;
    }

    if (cfg.read_fd < 0 or cfg.write_fd < 0) {
        return error.ExternalPtyInvalidFd;
    }

    if (cfg.close_fds) {
        return .{
            .read_fd = cfg.read_fd,
            .write_fd = cfg.write_fd,
            .close_read_fd = true,
            .close_write_fd = cfg.write_fd != cfg.read_fd,
        };
    }

    const read_fd = try posix.dup(cfg.read_fd);
    errdefer posix.close(read_fd);

    const write_fd = if (cfg.write_fd == cfg.read_fd)
        read_fd
    else
        try posix.dup(cfg.write_fd);
    errdefer if (write_fd != read_fd) posix.close(write_fd);

    return .{
        .read_fd = read_fd,
        .write_fd = write_fd,
        .close_read_fd = true,
        .close_write_fd = write_fd != read_fd,
    };
}

pub fn deinit(self: *ExternalPty) void {
    if (self.fds_moved_to_thread) return;
    self.closeOwnedFds();
}

fn closeOwnedFds(self: *ExternalPty) void {
    if (self.close_write_fd) {
        posix.close(self.write_fd);
        self.close_write_fd = false;
    }
    if (self.close_read_fd) {
        posix.close(self.read_fd);
        self.close_read_fd = false;
    }
}

pub fn initTerminal(self: *ExternalPty, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *ExternalPty,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    if (comptime builtin.target.os.tag != .macos) {
        return error.ExternalPtyUnsupportedPlatform;
    }

    // Create our pipe that we'll use to kill our read thread.
    // pipe[0] is the read end, pipe[1] is the write end.
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    // Setup our stream so that we can write to the host-provided input fd.
    const stream = xev.Stream.initFd(self.write_fd);

    // Start our read thread. Alan owns the real child-process lifecycle; this
    // thread only ingests bytes from the host-provided output fd.
    const read_thread = try std.Thread.spawn(
        .{},
        termio.Exec.ReadThread.threadMainPosix,
        .{ self.read_fd, io, pipe[0] },
    );
    read_thread.setName("io-reader") catch {};

    td.backend = .{ .external_pty = .{
        .closed = false,
        .write_stream = stream,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = self.read_fd,
        .close_read_fd = self.close_read_fd,
        .close_write_fd = self.close_write_fd,
    } };

    self.close_read_fd = false;
    self.close_write_fd = false;
    self.fds_moved_to_thread = true;
}

pub fn threadExit(self: *ExternalPty, td: *termio.Termio.ThreadData) void {
    _ = self;
    assert(td.backend == .external_pty);
    const external = &td.backend.external_pty;

    external.closed = true;

    // Quit our read thread. Alan owns process shutdown, so this only stops the
    // renderer-side reader from waiting on its attachment fd forever.
    _ = posix.write(external.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn("error writing to read thread quit pipe err={}", .{err}),
    };

    external.read_thread.join();
}

pub fn focusGained(
    self: *ExternalPty,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *ExternalPty,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

pub fn queueWrite(
    self: *ExternalPty,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    const external = &td.backend.external_pty;

    if (external.closed) return;

    var i: usize = 0;
    while (i < data.len) {
        const req = try external.write_req_pool.getGrow(alloc);
        const buf = try external.write_buf_pool.getGrow(alloc);
        const slice = slice: {
            const max = @min(data.len, i + buf.len);

            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }

            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;

                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }

                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }

            break :slice buf[0..buf_i];
        };

        external.write_stream.queueWrite(
            td.loop,
            &external.write_queue,
            req,
            .{ .slice = slice },
            ThreadData,
            external,
            ttyWrite,
        );
    }
}

fn ttyWrite(
    td_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const td = td_.?;
    td.write_req_pool.put();
    td.write_buf_pool.put();

    _ = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };

    return .disarm;
}

pub fn childExitedAbnormally(
    self: *ExternalPty,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(self: *ExternalPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub const ThreadData = struct {
    closed: bool = false,

    /// The data stream is the main IO for writes to the host attachment.
    write_stream: xev.Stream,

    /// This is the pool of available (unused) write requests.
    write_req_pool: SegmentedPool(xev.WriteRequest, WRITE_REQ_PREALLOC) = .{},

    /// The pool of available buffers for writing to the pty.
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

    /// The write queue for the data stream.
    write_queue: xev.WriteQueue = .{},

    /// Reader thread state.
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    read_thread_fd: posix.fd_t,
    close_read_fd: bool,
    close_write_fd: bool,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        posix.close(self.read_thread_pipe);

        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);
        self.write_stream.deinit();

        if (self.close_write_fd) {
            posix.close(self.write_stream.fd);
            self.close_write_fd = false;
        }
        if (self.close_read_fd) {
            posix.close(self.read_thread_fd);
            self.close_read_fd = false;
        }
    }
};
