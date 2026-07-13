//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const soem = @import("soem");

io_map: []u8,
ifname: []u8,
ctx: *soem.ecx_contextt,
lock: std.Io.RwLock,
expected_wkc: u16,

/// Allocate required memory for establishing ethercat connection.
pub fn init(gpa: std.mem.Allocator, ifname: []const u8) !@This() {
    var res: @This() = .{
        .ctx = undefined,
        .lock = .init,
        .io_map = &.{},
        .ifname = &.{},
        .expected_wkc = 0,
    };
    errdefer res.deinit(gpa);
    res.ctx = try gpa.create(soem.ecx_contextt);
    res.ctx.* = std.mem.zeroInit(soem.ecx_contextt, .{});
    // TODO: Find a way to calculate required memory before even initializing connectioni to ethercat
    res.io_map = try gpa.alloc(u8, 4096);
    res.ifname = try gpa.dupe(u8, ifname);
    return res;
}

/// Close and free all allocated memory for ethercat interface.
pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
    soem.ecx_close(self.ctx);
    gpa.destroy(self.ctx);
    gpa.free(self.ifname);
    gpa.free(self.io_map);
}

/// Establish ethercat connection and ensure all slaves are in safe
/// operational state. User must spawn a `process` thread for exhanging
/// information to all slaves to ensure the slave's watchdogs is not triggered.
pub fn open(self: *@This()) !void {
    if (soem.ecx_init(self.ctx, self.ifname.ptr) <= 0) {
        return error.SoemInitializationFailed;
    }
    errdefer soem.ecx_close(self.ctx);
    // Wait until all slaves are in INIT state.
    checkSlaveState(self.ctx, soem.EC_STATE_INIT);
    if (self.ctx.slavelist[0].state != soem.EC_STATE_INIT) {
        return error.FailedToReachInitState;
    }
    const stations: usize = @intCast(soem.ecx_config_init(self.ctx));
    if (stations <= 0) return error.NoSlavesFound;
    // Wait until all slaves are in PRE_OP state.
    checkSlaveState(self.ctx, soem.EC_STATE_PRE_OP);
    if (self.ctx.slavelist[0].state != soem.EC_STATE_PRE_OP) {
        return error.FailedToReachPreOperationalState;
    }
    // Configure SM2 and SM3 for each slaves. This is a bug in the firmware
    // that the SM for PDO mapping is not configured correctly.
    for (self.ctx.slavelist[1 .. @as(usize, @intCast(self.ctx.slavecount)) + 1]) |*slave| {
        slave.SM[2] = .{ .StartAddr = 0x1100, .SMlength = 42, .SMflags = 0x64 };
        slave.SM[3] = .{ .StartAddr = 0x1180, .SMlength = 44, .SMflags = 0x20 };
    }
    const size = soem.ecx_config_map_group(
        self.ctx,
        @ptrCast(@alignCast(self.io_map)),
        0,
    );
    if (size > self.io_map.len) return error.IoMapOverflow;
    _ = soem.ecx_configdc(self.ctx);
    self.expected_wkc =
        self.ctx.grouplist[0].outputsWKC * 2 + self.ctx.grouplist[0].inputsWKC;
    // Wait until all slaves are in SAFE_OP state.
    checkSlaveState(self.ctx, soem.EC_STATE_SAFE_OP);
    if (self.ctx.slavelist[0].state != soem.EC_STATE_SAFE_OP) {
        return error.FailedToReachSafeOperationalState;
    }
    // Ensure slaves have valid output
    _ = soem.ecx_send_processdata(self.ctx);
    const receive_wkc = soem.ecx_receive_processdata(self.ctx, soem.EC_TIMEOUTRET);
    if (receive_wkc != self.expected_wkc) {
        std.log.debug(
            "expected wkc: {} -- actual wkc: {}",
            .{ self.expected_wkc, receive_wkc },
        );
        return error.InvalidWorkCounter;
    }
    std.log.debug("Connected to ethercat", .{});
}

/// Asks slaves to be in operational state and maintain process data exchange.
/// This function must be called in its own thread to maintain the slaves state
/// stays on OPERATIONAL state.
pub fn process(
    io: std.Io,
    board: *@This(),
) (std.Io.Cancelable || error{InvalidWorkCounter})!void {
    defer {
        if (@errorReturnTrace()) |error_trace| {
            std.debug.dumpErrorReturnTrace(error_trace);
        }
    }
    // Asks the slaves to be in operational state
    board.ctx.slavelist[0].state = soem.EC_STATE_OPERATIONAL;
    _ = soem.ecx_writestate(board.ctx, 0);
    checkSlaveState(board.ctx, soem.EC_STATE_OPERATIONAL);
    // Update all slaves state
    _ = soem.ecx_readstate(board.ctx);
    var timestamp: std.Io.Timestamp = .now(io, .real);
    const update_rate_us = 1000;
    while (true) {
        _ = soem.ecx_readstate(board.ctx);
        try board.lock.lock(io);
        _ = soem.ecx_send_processdata(board.ctx);
        if (soem.ecx_receive_processdata(board.ctx, soem.EC_TIMEOUTRET) != board.expected_wkc) {
            return error.InvalidWorkCounter;
        }
        board.lock.unlock(io);
        const current = timestamp.untilNow(io, .real).toMicroseconds();
        try io.sleep(.fromMicroseconds(update_rate_us - current), .real);
    }
}

/// Close ethercat connection.
pub fn close(self: *@This()) void {
    // Put all slaves to INIT state before closing the socket
    self.ctx.slavelist[0].state = soem.EC_STATE_INIT;
    _ = soem.ecx_writestate(self.ctx, 0);
    checkSlaveState(self.ctx, soem.EC_STATE_INIT);
    // Close the socket connection
    soem.ecx_close(self.ctx);
}

/// Switch all slaves state
pub fn switchState(self: *@This(), state: u16) void {
    self.ctx.slavelist[0].state = state;
    _ = soem.ecx_writestate(self.ctx, 0);
    checkSlaveState(self.ctx, state);
}

/// Check whether all slaves already in the specified state.
fn checkSlaveState(ctx: *soem.ecx_contextt, state: u16) void {
    const slave_state: SlaveState = @enumFromInt(state);
    _ = soem.ecx_statecheck(ctx, 0, state, soem.EC_TIMEOUTSTATE * 4);
    if (ctx.slavelist[0].state != state) {
        std.log.warn("Not all slave enter {t} state", .{slave_state});
        _ = soem.ecx_readstate(ctx);
        std.log.debug("slave count {}", .{ctx.slavecount});
        for (ctx.slavelist[1..@as(usize, @intCast(ctx.slavecount + 1))]) |slave| {
            std.log.warn(
                "slave state: {t}, AL code: {t}",
                .{
                    @as(SlaveState, @enumFromInt(slave.state)),
                    @as(ALStatusCode, @enumFromInt(slave.ALstatuscode)),
                },
            );
        }
    } else {
        std.log.debug("All slaves enter {t}", .{slave_state});
    }
}

/// Wrapper for SOEM functions that may return error code.
///
/// Usage: `error_handling(ctx, SOEM_FUNCTION_CALL())`;
fn error_handling(ctx: *soem.ecx_contextt, code: c_int) !void {
    if (code == 0) return;
    var err: soem.ec_errort = std.mem.zeroInit(soem.ec_errort, .{});
    if (soem.ecx_poperror(ctx, &err) > 0) {
        const err_code: ErrorCode = @enumFromInt(err.Etype);
        std.log.err("{s}", .{soem.ecx_err2string(err)});
        try err_code.throwError();
    } else return error.PopErrorFailed;
}

const ErrorCode = enum(u8) {
    EC_ERR_TYPE_SDO_ERROR = 0,
    EC_ERR_TYPE_EMERGENCY = 1,
    EC_ERR_TYPE_PACKET_ERROR = 3,
    EC_ERR_TYPE_SDOINFO_ERROR = 4,
    EC_ERR_TYPE_FOE_ERROR = 5,
    EC_ERR_TYPE_FOE_BUF2SMALL = 6,
    EC_ERR_TYPE_FOE_PACKETNUMBER = 7,
    EC_ERR_TYPE_SOE_ERROR = 8,
    EC_ERR_TYPE_MBX_ERROR = 9,
    EC_ERR_TYPE_FOE_FILE_NOTFOUND = 10,
    EC_ERR_TYPE_EOE_INVALID_RX_DATA = 11,
    _,

    fn throwError(err: ErrorCode) !void {
        switch (err) {
            .EC_ERR_TYPE_SDO_ERROR => return error.SDOError,
            .EC_ERR_TYPE_EMERGENCY => return error.Emergency,
            .EC_ERR_TYPE_PACKET_ERROR => return error.PacketError,
            .EC_ERR_TYPE_SDOINFO_ERROR => return error.SDOInfoError,
            .EC_ERR_TYPE_FOE_ERROR => return error.FOEError,
            .EC_ERR_TYPE_FOE_BUF2SMALL => return error.FOEBufTooSmall,
            .EC_ERR_TYPE_FOE_PACKETNUMBER => return error.FOEPacketNumber,
            .EC_ERR_TYPE_SOE_ERROR => return error.SOEError,
            .EC_ERR_TYPE_MBX_ERROR => return error.MBXError,
            .EC_ERR_TYPE_FOE_FILE_NOTFOUND => return error.FOEFileNotFound,
            .EC_ERR_TYPE_EOE_INVALID_RX_DATA => return error.InvalidRxData,
            _ => unreachable,
        }
    }
};

// TODO: If an error occur, the slave state will be its state + error. When it
// shows an error, user have to check the AL status code.
pub const SlaveState = enum(u5) {
    /// No valid state.
    EC_STATE_NONE = 0x00,
    /// Init state.
    EC_STATE_INIT = 0x01,
    /// Pre-operational state.
    EC_STATE_PRE_OP = 0x02,
    /// Boot state.
    EC_STATE_BOOT = 0x03,
    /// Safe-operational state.
    EC_STATE_SAFE_OP = 0x04,
    /// Operational state.
    EC_STATE_OPERATIONAL = 0x08,
    // Error or ACK Error state.
    EC_STATE_ACK_ERROR = 0x10,
    /// Init + error state.
    EC_STATE_INIT_ERROR = 0x01 | 0x10,
    /// Pre-operational + error state.
    EC_STATE_PRE_OP_ERROR = 0x02 | 0x10,
    /// Boot + error state.
    EC_STATE_BOOT_ERROR = 0x03 | 0x10,
    /// Safe-operational + error state.
    EC_STATE_SAFE_OP_ERROR = 0x04 | 0x10,
    /// Operational + error state.
    EC_STATE_OPERATIONAL_ERROR = 0x08 | 0x10,
};

pub const ALStatusCode = enum(u16) {
    No_error = 0x0000,
    Unspecified_error = 0x0001,
    No_memory = 0x0002,
    Invalid_device_setup = 0x0003,
    Invalid_revision = 0x0004,
    SII_EEPROM_information_does_not_match_firmware = 0x0006,
    Firmware_update_not_successful = 0x0007,
    License_error = 0x000E,
    Invalid_requested_state_change = 0x0011,
    Unknown_requested_state = 0x0012,
    Bootstrap_not_supported = 0x0013,
    No_valid_firmware = 0x0014,
    Invalid_mailbox_configuration_0 = 0x0015,
    Invalid_mailbox_configuration_1 = 0x0016,
    Invalid_sync_manager_configuration = 0x0017,
    No_valid_inputs_available = 0x0018,
    No_valid_outputs = 0x0019,
    Synchronization_error = 0x001A,
    Sync_manager_watchdog = 0x001B,
    Invalid_sync_Manager_types = 0x001C,
    Invalid_output_configuration = 0x001D,
    Invalid_input_configuration = 0x001E,
    Invalid_watchdog_configuration = 0x001F,
    Slave_needs_cold_start = 0x0020,
    Slave_needs_INIT = 0x0021,
    Slave_needs_PREOP = 0x0022,
    Slave_needs_SAFEOP = 0x0023,
    Invalid_input_mapping = 0x0024,
    Invalid_output_mapping = 0x0025,
    Inconsistent_settings = 0x0026,
    Freerun_not_supported = 0x0027,
    Synchronisation_not_supported = 0x0028,
    Freerun_needs_3buffer_mode = 0x0029,
    Background_watchdog = 0x002A,
    No_valid_Inputs_and_Outputs = 0x002B,
    Fatal_sync_error = 0x002C,
    No_sync_error = 0x002D,
    Invalid_input_FMMU_configuration = 0x002E,
    Invalid_DC_SYNC_configuration = 0x0030,
    Invalid_DC_latch_configuration = 0x0031,
    PLL_error = 0x0032,
    DC_sync_IO_error = 0x0033,
    DC_sync_timeout_error = 0x0034,
    DC_invalid_sync_cycle_time = 0x0035,
    DC_invalid_sync0_cycle_time = 0x0036,
    DC_invalid_sync1_cycle_time = 0x0037,
    MBX_AOE = 0x0041,
    MBX_EOE = 0x0042,
    MBX_COE = 0x0043,
    MBX_FOE = 0x0044,
    MBX_SOE = 0x0045,
    MBX_VOE = 0x004F,
    EEPROM_no_access = 0x0050,
    EEPROM_error = 0x0051,
    External_hardware_not_ready = 0x0052,
    Slave_restarted_locally = 0x0060,
    Device_identification_value_updated = 0x0061,
    Detected_Module_Ident_List_does_not_match = 0x0070,
    Supply_voltage_too_low = 0x0080,
    Supply_voltage_too_high = 0x0081,
    Temperature_too_low = 0x0082,
    Temperature_too_high = 0x0083,
    Application_controller_available = 0x00f0,
    Unknown = 0xffff,
    _,
};

test {
    std.testing.refAllDecls(@This());
}
