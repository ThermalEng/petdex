//! Petdex on Native SDK, slice 1: a runtime-loaded pet animating its real
//! atlas in a chromeless window. No WebView, no Node sidecar.
//!
//! The atlas decodes app-side and each state's frames register into
//! slots 1..8, replaced in place on state switch (see Sheet for why
//! the full texture cannot ride registerImageBytes). The state table
//! is the canonical map ported from the WebView renderer
//! (petdex-desktop/src/main.zig STATES): 9 states, 8 columns,
//! per-frame durations with idle's irregular blink timing.
//!
//! V1 demo affordance: Space cycles states (replaced by the :7777 hook
//! server in V2).

const std = @import("std");
const runner = @import("runner");

extern "c" fn system(command: [*:0]const u8) c_int;
const native_sdk = @import("native_sdk");
const hook_server = @import("hook_server.zig");
const hook_runner = @import("hook_runner.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "pet-canvas";
const frame_w: f32 = 192;
const frame_h: f32 = 208;
const max_scale: f32 = 1.2;
const win_w: f32 = frame_w * max_scale;
const win_h: f32 = frame_h * max_scale;
const cols: u64 = 8;
const sheet_image_id: u64 = 1;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Pet canvas", .accessibility_label = "Petdex pet", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Petdex",
    .width = win_w,
    .height = win_h,
    .resizable = false,
    .restore_state = false,
    .titlebar = .chromeless,
    .floating = true,
    .transparent = true,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ----------------------------------------------------------------- states

pub const State = enum(u8) {
    idle,
    @"running-right",
    @"running-left",
    waving,
    jumping,
    failed,
    waiting,
    running,
    review,

    pub fn next(self: State) State {
        const n = (@intFromEnum(self) + 1) % 9;
        return @enumFromInt(n);
    }
};

const FrameSpec = struct { col: u64, dur_ms: u32 };

fn uniform(comptime count: u64, comptime dur: u32, comptime last: u32) [count]FrameSpec {
    var frames: [count]FrameSpec = undefined;
    for (&frames, 0..) |*f, i| {
        f.* = .{ .col = i, .dur_ms = if (i == count - 1) last else dur };
    }
    return frames;
}

const idle_frames = [_]FrameSpec{
    .{ .col = 0, .dur_ms = 280 }, .{ .col = 1, .dur_ms = 110 },
    .{ .col = 2, .dur_ms = 110 }, .{ .col = 3, .dur_ms = 140 },
    .{ .col = 4, .dur_ms = 140 }, .{ .col = 5, .dur_ms = 320 },
};
const running_right_frames = uniform(8, 120, 220);
const running_left_frames = uniform(8, 120, 220);
const waving_frames = uniform(4, 140, 280);
const jumping_frames = uniform(5, 140, 280);
const failed_frames = uniform(8, 140, 240);
const waiting_frames = uniform(6, 150, 260);
const running_frames = uniform(6, 120, 220);
const review_frames = uniform(6, 150, 280);

const StateDef = struct { row: u64, frames: []const FrameSpec };

fn stateDef(state: State) StateDef {
    return switch (state) {
        .idle => .{ .row = 0, .frames = &idle_frames },
        .@"running-right" => .{ .row = 1, .frames = &running_right_frames },
        .@"running-left" => .{ .row = 2, .frames = &running_left_frames },
        .waving => .{ .row = 3, .frames = &waving_frames },
        .jumping => .{ .row = 4, .frames = &jumping_frames },
        .failed => .{ .row = 5, .frames = &failed_frames },
        .waiting => .{ .row = 6, .frames = &waiting_frames },
        .running => .{ .row = 7, .frames = &running_frames },
        .review => .{ .row = 8, .frames = &review_frames },
    };
}

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    frame_tick: native_sdk.EffectTimer,
    poll_tick: native_sdk.EffectTimer,
    physics_tick: native_sdk.EffectTimer,
    frame_clock,
    cycle_state,
    open_settings,
    settings_closed,
    close_pet,
    select_pet: u32,
    set_scale: f32,
    open_pets_folder,
    open_pet_page: u32,
    appearance: native_sdk.platform.Appearance,
    toggle_bubbles,
    noop,

    pub const view_unbound = .{ "frame_tick", "poll_tick", "physics_tick", "frame_clock", "cycle_state" };
};

pub const Model = struct {
    sheet_loaded: bool = false,
    pet_name: [64]u8 = @splat(0),
    pet_name_len: usize = 0,
    state: State = .idle,
    frame_index: usize = 0,
    // Sidecar dwell semantics (state-queue.ts): the displayed state
    // holds for its dwell before the next queued event applies, so
    // running/idle pinball under heavy tool calls never thrashes.
    shown_at_ms: i64 = 0,
    shown_dwell_ms: u32 = 0,
    bubble: hook_server.Bubble = .{},
    // Drag + momentum, the old desktop's "Codex parity" physics: the
    // frame clock samples the window origin and the primary button
    // through fx.moveWindow(0,0); a down->up edge computes the release
    // velocity from the last 100ms of samples and the physics timer
    // throws the window with friction until it slows or hits an edge.
    samples: [16]PosSample = @splat(.{}),
    sample_len: usize = 0,
    primary_was_down: bool = false,
    throwing: bool = false,
    vx: f64 = 0,
    vy: f64 = 0,
    throw_elapsed_ms: u32 = 0,
    last_physics_ms: i64 = 0,
    // App-owned drag (the old renderer's model, over the moveWindow
    // verb): grab offset from the window origin to the cursor at
    // press, followed every frame while the button holds. Native
    // performWindowDrag is deliberately not used: it swallows the
    // gesture where neither velocity nor tests can see it.
    dragging: bool = false,
    grab_dx: f64 = 0,
    grab_dy: f64 = 0,
    settings_open: bool = false,
    /// Sprite scale, persisted. Codex parity: the settings slider maps
    /// 0.4..1.2 over this.
    scale: f32 = 0.7,
    active_pet: u32 = 0,
    window_fitted: bool = false,
    bubbles_enabled: bool = true,
    dark: bool = true,
    high_contrast: bool = false,
    reduce_motion: bool = false,
};

/// Petdex web tokens (globals.css) translated from OKLCH: brand purple
/// #5266ea family, cool-tinted near-white light surfaces, stone-900
/// dark cards. High contrast keeps the stock loud register untouched.
fn petdexTokens(model: *const Model) canvas.DesignTokens {
    const scheme: canvas.ColorScheme = if (model.dark) .dark else .light;
    var tokens = canvas.DesignTokens.theme(.{
        .color_scheme = scheme,
        .contrast = if (model.high_contrast) .high else .standard,
        .reduce_motion = model.reduce_motion,
    });
    if (model.high_contrast) return tokens;
    const c = &tokens.colors;
    if (model.dark) {
        c.background = canvas.Color.rgb8(12, 12, 15);
        c.surface = canvas.Color.rgb8(25, 25, 28);
        c.surface_subtle = canvas.Color.rgb8(45, 45, 48);
        c.surface_pressed = canvas.Color.rgb8(22, 27, 67);
        c.text = canvas.Color.rgb8(237, 237, 238);
        c.text_muted = canvas.Color.rgb8(156, 158, 168);
        c.accent = canvas.Color.rgb8(137, 163, 255);
        c.destructive = canvas.Color.rgb8(250, 105, 94);
    } else {
        c.background = canvas.Color.rgb8(247, 250, 255);
        c.surface = canvas.Color.rgb8(255, 255, 255);
        c.surface_subtle = canvas.Color.rgb8(236, 238, 244);
        c.surface_pressed = canvas.Color.rgb8(233, 238, 251);
        c.text = canvas.Color.rgb8(9, 9, 9);
        c.text_muted = canvas.Color.rgb8(88, 92, 106);
        c.accent = canvas.Color.rgb8(78, 98, 235);
        c.destructive = canvas.Color.rgb8(212, 12, 26);
    }
    return tokens.withOverrides(canvas.accentOverrides(c.accent, scheme));
}

fn onAppearance(appearance: native_sdk.platform.Appearance) ?Msg {
    return .{ .appearance = appearance };
}

pub const max_catalog = 32;
pub const CatalogEntry = struct {
    name: [64]u8 = @splat(0),
    len: usize = 0,
    root: [160]u8 = @splat(0),
    root_len: usize = 0,

    pub fn slice(self: *const CatalogEntry) []const u8 {
        return self.name[0..self.len];
    }
    pub fn rootSlice(self: *const CatalogEntry) []const u8 {
        return self.root[0..self.root_len];
    }
};
pub var catalog: [max_catalog]CatalogEntry = @splat(.{});
pub var catalog_len: usize = 0;

pub const PosSample = struct { x: f64 = 0, y: f64 = 0, t_ms: i64 = 0 };

const physics_timer_key: u64 = 3;
const physics_tick_ms: u32 = 16;
const physics_friction: f64 = 0.88;
const physics_min_vel: f64 = 65;
const physics_max_duration_ms: u32 = 900;
const sample_window_ms: i64 = 100;

pub const Effects = native_sdk.Effects(Msg);

const frame_timer_key: u64 = 1;

fn armFrameTimer(model: *const Model, fx: *Effects) void {
    const def = stateDef(model.state);
    const spec = def.frames[model.frame_index % def.frames.len];
    fx.startTimer(.{
        .key = frame_timer_key,
        .interval_ms = spec.dur_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.frame_tick),
    });
}

// ------------------------------------------------------------- pet loading

const PetFile = struct {
    name: []const u8,
    sheet_path: []const u8,
};

/// Decoded atlas kept app-side: the runtime's image registry caps one
/// image at 1MB of pixels and the platform decode scratch at 1.25MB,
/// so a full sheet (11.5MB RGBA) can never ride registerImageBytes.
/// We decode the sheet ourselves and register one 192x208 frame per
/// slot (160KB, 16 slots available), replacing in place per state.
/// V1 macOS dev shim: `sips` converts webp->TGA and we parse TGA
/// (RLE + raw); V5 swaps the shim for vendored libwebp on all
/// platforms. Raising the registry caps is on the upstream PR list.
const Sheet = struct {
    pixels: []u8 = &.{},
    width: usize = 0,
    height: usize = 0,
    rows: usize = 9,
};
var sheet: Sheet = .{};

fn parseTga(allocator: std.mem.Allocator, bytes: []const u8) !Sheet {
    if (bytes.len < 18) return error.BadTga;
    if (bytes[1] != 0) return error.UnsupportedTga;
    const image_type = bytes[2];
    if (image_type != 2 and image_type != 10) return error.UnsupportedTga;
    const id_len: usize = bytes[0];
    const width: usize = @as(usize, bytes[12]) | (@as(usize, bytes[13]) << 8);
    const height: usize = @as(usize, bytes[14]) | (@as(usize, bytes[15]) << 8);
    const bpp = bytes[16];
    if (bpp != 32 and bpp != 24) return error.UnsupportedTga;
    const bytes_per_pixel: usize = bpp / 8;
    const top_left = (bytes[17] & 0x20) != 0;
    if (width == 0 or height == 0 or width > 8192 or height > 8192) return error.BadTga;

    const out = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(out);
    var src: usize = 18 + id_len;
    var px: usize = 0;
    const total = width * height;
    while (px < total) {
        if (image_type == 2) {
            if (src + bytes_per_pixel > bytes.len) return error.BadTga;
            writeTgaPixel(out, px, bytes[src..], bytes_per_pixel);
            src += bytes_per_pixel;
            px += 1;
        } else {
            if (src >= bytes.len) return error.BadTga;
            const packet = bytes[src];
            src += 1;
            const count: usize = @as(usize, packet & 0x7f) + 1;
            if (packet & 0x80 != 0) {
                if (src + bytes_per_pixel > bytes.len) return error.BadTga;
                for (0..count) |_| {
                    if (px >= total) return error.BadTga;
                    writeTgaPixel(out, px, bytes[src..], bytes_per_pixel);
                    px += 1;
                }
                src += bytes_per_pixel;
            } else {
                for (0..count) |_| {
                    if (px >= total or src + bytes_per_pixel > bytes.len) return error.BadTga;
                    writeTgaPixel(out, px, bytes[src..], bytes_per_pixel);
                    src += bytes_per_pixel;
                    px += 1;
                }
            }
        }
    }
    if (!top_left) {
        const row_len = width * 4;
        var top: usize = 0;
        var bottom: usize = height - 1;
        while (top < bottom) : ({
            top += 1;
            bottom -= 1;
        }) {
            const a = out[top * row_len ..][0..row_len];
            const b = out[bottom * row_len ..][0..row_len];
            for (a, b) |*x, *y| std.mem.swap(u8, x, y);
        }
    }
    return .{ .pixels = out, .width = width, .height = height };
}

fn writeTgaPixel(out: []u8, px: usize, src: []const u8, bytes_per_pixel: usize) void {
    const o = px * 4;
    out[o + 0] = src[2];
    out[o + 1] = src[1];
    out[o + 2] = src[0];
    out[o + 3] = if (bytes_per_pixel == 4) src[3] else 0xff;
}

/// Scan the petdex pet roots for the first usable pet, honoring
/// PETDEX_PET as a directory-name override. Returns the sheet bytes
/// (caller frees) and the display name.
/// Env snapshot taken in main() from init.environ_map (Zig 0.16 has no
/// global getenv; env rides std.process.Init).
var env_home: ?[]const u8 = null;
var env_wanted_pet: ?[]const u8 = null;

fn readFileAbsolute(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    if (size == 0 or size > max) return error.FileTooLarge;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const read = try file.readPositionalAll(io, buf, 0);
    if (read != size) return error.ShortRead;
    return buf;
}

fn petNameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

/// Scan both pet roots into the catalog (name + which root), sorted by
/// scan order. Runs once in main() with the io handle.
fn scanCatalog(io: std.Io, allocator: std.mem.Allocator) void {
    const home = env_home orelse return;
    const roots = [_][]const u8{ ".petdex/pets", ".codex/pets" };
    for (roots) |root| {
        const root_path = std.fs.path.join(allocator, &.{ home, root }) catch continue;
        defer allocator.free(root_path);
        var dir = std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!petNameOk(entry.name)) continue;
            if (catalog_len >= max_catalog) return;
            var duplicate = false;
            for (catalog[0..catalog_len]) |*existing| {
                if (std.mem.eql(u8, existing.slice(), entry.name)) duplicate = true;
            }
            if (duplicate) continue;
            var e = &catalog[catalog_len];
            @memcpy(e.name[0..entry.name.len], entry.name);
            e.len = entry.name.len;
            @memcpy(e.root[0..root.len], root);
            e.root_len = root.len;
            catalog_len += 1;
        }
    }
}

var boot_allocator: std.mem.Allocator = std.heap.page_allocator;
var boot_io: ?std.Io = null;
var pet_display_name: []const u8 = "";

fn settingsPath(buf: []u8) ?[]const u8 {
    const home = env_home orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.petdex/desktop-native-settings.json", .{home}) catch null;
}

/// Tiny std.c file helpers usable from the runtime thread (std.Io
/// stays on the main thread; these mirror hook_server's).
fn cReadFile(path: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return null;
    return buf[0..total];
}

fn cWriteFile(path: []const u8, bytes: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn saveSettings(model: *const Model) void {
    var path_buf: [512]u8 = undefined;
    const path = settingsPath(&path_buf) orelse return;
    var buf: [256]u8 = undefined;
    const active = if (model.active_pet < catalog_len) catalog[model.active_pet].slice() else "";
    const json = std.fmt.bufPrint(&buf, "{{\"active_pet\":\"{s}\",\"scale\":{d:.2},\"bubbles\":{}}}", .{ active, model.scale, model.bubbles_enabled }) catch return;
    cWriteFile(path, json);
}

/// Convert a pet's sheet to the cached /tmp TGA. sips exits 0 even on
/// a missing input, so success is the OUTPUT existing, never the exit
/// code. Prefers pet.json's spritesheetPath, then the standard names.
fn convertPetToTga(entry: *const CatalogEntry, tga_path: []const u8) bool {
    const home = env_home orelse return false;
    var cmd_buf: [1024]u8 = undefined;
    var probe: [1]u8 = undefined;
    if (cReadFile(tga_path, &probe) != null) return true;

    var candidates_buf: [3][64]u8 = undefined;
    var candidates: [3][]const u8 = undefined;
    var candidate_count: usize = 0;
    var json_buf: [1024]u8 = undefined;
    var pj_path: [512]u8 = undefined;
    if (std.fmt.bufPrint(&pj_path, "{s}/{s}/{s}/pet.json", .{ home, entry.rootSlice(), entry.slice() })) |pjp| {
        if (cReadFile(pjp, &json_buf)) |json| {
            if (hook_server.jsonStringPub(json, "spritesheetPath")) |sp| {
                if (petNameOk(sp) and sp.len < 64) {
                    @memcpy(candidates_buf[candidate_count][0..sp.len], sp);
                    candidates[candidate_count] = candidates_buf[candidate_count][0..sp.len];
                    candidate_count += 1;
                }
            }
        }
    } else |_| {}
    candidates[candidate_count] = "spritesheet.webp";
    candidate_count += 1;
    candidates[candidate_count] = "spritesheet.png";
    candidate_count += 1;

    for (candidates[0..candidate_count]) |name| {
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "/usr/bin/sips -s format tga '{s}/{s}/{s}/{s}' --out '{s}' >/dev/null 2>&1", .{ home, entry.rootSlice(), entry.slice(), name, tga_path }) catch continue;
        _ = system(cmd);
        if (cReadFile(tga_path, &probe) != null) return true;
    }
    return false;
}

/// Convert + decode a pet's sheet from the runtime thread: blocking
/// sips via std.c.system (a pet switch is a user action, a ~200ms
/// hitch is fine), then the TGA parse. Names come from directory
/// scans and are charset-restricted, so the command is injection-safe.
fn loadSheetForPet(entry: *const CatalogEntry) bool {
    var tga_buf: [256]u8 = undefined;
    const tga_path = std.fmt.bufPrint(&tga_buf, "/tmp/petdex-native-{s}.tga", .{entry.slice()}) catch return false;
    if (!convertPetToTga(entry, tga_path)) return false;
    const tga_heap = boot_allocator.alloc(u8, 64 * 1024 * 1024) catch return false;
    defer boot_allocator.free(tga_heap);
    const tga_bytes = cReadFile(tga_path, tga_heap) orelse return false;
    const parsed = parseTga(boot_allocator, tga_bytes) catch return false;
    if (sheet.pixels.len > 0) boot_allocator.free(sheet.pixels);
    sheet = parsed;
    sheet.rows = if (sheet.height * 1536 >= sheet.width * 2288) 11 else 9;
    return true;
}

var initial_scale: f32 = 0.7;
var initial_pet: u32 = 0;
var initial_bubbles: bool = true;

// ------------------------------------------------------------- avatars
// One slot for the CURRENT bubble's agent avatar (claude-code, codex,
// gemini, opencode, antigravity), 40x40 PNGs committed under
// assets/agents/, re-registered only when the agent changes.
const avatar_image_id: u64 = 13;
const tail_image_id: u64 = 14;
const tail_w: usize = 18;
const tail_h: usize = 9;
var tail_dark: bool = false;
var tail_ready: bool = false;

/// Register the speech-bubble tail: a filled triangle pointing down,
/// generated in code and colored like the card for the active theme.
fn registerTail(dark: bool, fx: *Effects) void {
    if (tail_ready and tail_dark == dark) return;
    var pixels: [tail_w * tail_h * 4]u8 = @splat(0);
    const cr: u8 = if (dark) 25 else 255;
    const cg: u8 = if (dark) 25 else 255;
    const cb: u8 = if (dark) 28 else 255;
    for (0..tail_h) |y| {
        const inset = y;
        for (0..tail_w) |x| {
            if (x >= inset and x < tail_w - inset) {
                const i = (y * tail_w + x) * 4;
                pixels[i] = cr;
                pixels[i + 1] = cg;
                pixels[i + 2] = cb;
                pixels[i + 3] = 255;
            }
        }
    }
    fx.registerImage(tail_image_id, tail_w, tail_h, &pixels) catch return;
    tail_dark = dark;
    tail_ready = true;
}
var avatar_agent: [24]u8 = @splat(0);
var avatar_agent_len: usize = 0;
var avatar_ready: bool = false;
var avatar_theme_dark: bool = false;

fn loadAgentAvatar(agent: []const u8, dark: bool, fx: *Effects) void {
    if (avatar_ready and avatar_theme_dark == dark and std.mem.eql(u8, avatar_agent[0..avatar_agent_len], agent)) return;
    var safe = true;
    for (agent) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) safe = false;
    }
    var path_buf: [128]u8 = undefined;
    var probe: [1]u8 = undefined;
    const name = if (safe and agent.len > 0) agent else "fallback";
    // Themed variant first (opencode ships light/dark glyphs), then
    // the plain file, then the generic fallback.
    var png_path = std.fmt.bufPrint(&path_buf, "assets/agents/{s}-{s}.png", .{ name, if (dark) "dark" else "light" }) catch return;
    if (cReadFile(png_path, &probe) == null) {
        png_path = std.fmt.bufPrint(&path_buf, "assets/agents/{s}.png", .{name}) catch return;
    }
    if (cReadFile(png_path, &probe) == null) {
        png_path = std.fmt.bufPrint(&path_buf, "assets/agents/fallback.png", .{}) catch return;
    }
    var tga_buf: [128]u8 = undefined;
    var cmd_buf: [512]u8 = undefined;
    const tga_path = std.fmt.bufPrint(&tga_buf, "/tmp/petdex-native-avatar-{s}-{s}.tga", .{ name, if (dark) "d" else "l" }) catch return;
    if (cReadFile(tga_path, &probe) == null) {
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "/usr/bin/sips -s format tga '{s}' --out '{s}' >/dev/null 2>&1", .{ png_path, tga_path }) catch return;
        _ = system(cmd);
        if (cReadFile(tga_path, &probe) == null) return;
    }
    var heap: [32 * 1024]u8 = undefined;
    const bytes = cReadFile(tga_path, &heap) orelse return;
    const parsed = parseTga(boot_allocator, bytes) catch return;
    defer boot_allocator.free(parsed.pixels);
    fx.registerImage(avatar_image_id, parsed.width, parsed.height, parsed.pixels) catch return;
    @memcpy(avatar_agent[0..agent.len], agent);
    avatar_agent_len = agent.len;
    avatar_theme_dark = dark;
    avatar_ready = true;
}

// ------------------------------------------------------------- thumbnails
// One atlas texture for every catalog thumbnail: the image registry
// caps at 16 slots, so 28+ per-pet images can never each own one. A
// 32-cell strip of 48x52 nearest-scaled idle frames is ~320KB, well
// inside the 1MB slot bound, and rows draw their cell via image_src.
const thumb_w: usize = 48;
const thumb_h: usize = 52;
const thumb_atlas_id: u64 = 12;
var thumbs_pixels: []u8 = &.{};
var thumbs_ready: [max_catalog]bool = @splat(false);
var thumbs_built: usize = 0;

/// Decode one pet's sheet without touching the live global (the pet
/// keeps animating from its own frames). Same sips shim + TGA parse.
fn decodeSheetForThumb(entry: *const CatalogEntry) ?Sheet {
    var tga_buf: [256]u8 = undefined;
    const tga_path = std.fmt.bufPrint(&tga_buf, "/tmp/petdex-native-{s}.tga", .{entry.slice()}) catch return null;
    if (!convertPetToTga(entry, tga_path)) return null;
    const heap = boot_allocator.alloc(u8, 64 * 1024 * 1024) catch return null;
    defer boot_allocator.free(heap);
    const bytes = cReadFile(tga_path, heap) orelse return null;
    return parseTga(boot_allocator, bytes) catch null;
}

/// Build one thumbnail into the atlas and re-register it. Incremental:
/// the poll timer builds one per tick while settings is open, so the
/// pet never freezes behind a 28-conversion batch.
fn buildNextThumb(fx: *Effects) void {
    if (thumbs_built >= catalog_len) return;
    const index = thumbs_built;
    thumbs_built += 1;
    if (thumbs_pixels.len == 0) {
        thumbs_pixels = boot_allocator.alloc(u8, max_catalog * thumb_w * thumb_h * 4) catch return;
        @memset(thumbs_pixels, 0);
    }
    const decoded = decodeSheetForThumb(&catalog[index]) orelse return;
    defer boot_allocator.free(decoded.pixels);
    const rows: usize = if (decoded.height * 1536 >= decoded.width * 2288) 11 else 9;
    const fw = decoded.width / cols;
    const fh = decoded.height / rows;
    const atlas_row_len = max_catalog * thumb_w * 4;
    for (0..thumb_h) |y| {
        const src_y = y * fh / thumb_h;
        for (0..thumb_w) |x| {
            const src_x = x * fw / thumb_w;
            const src_off = (src_y * decoded.width + src_x) * 4;
            const dst_off = y * atlas_row_len + (index * thumb_w + x) * 4;
            @memcpy(thumbs_pixels[dst_off..][0..4], decoded.pixels[src_off..][0..4]);
        }
    }
    thumbs_ready[index] = true;
    fx.registerImage(thumb_atlas_id, max_catalog * thumb_w, thumb_h, thumbs_pixels) catch {};
}

/// Boot-time load: scan the catalog, pick the initial pet
/// (PETDEX_PET env > persisted settings > first found), and decode its
/// sheet through the shared runtime-thread-safe path.
fn loadSheetPixels(io: std.Io, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !void {
    _ = environ_map;
    scanCatalog(io, allocator);
    if (catalog_len == 0) return error.NoPetInstalled;

    var wanted: []const u8 = "";
    var settings_buf: [512]u8 = undefined;
    var path_buf: [512]u8 = undefined;
    if (env_wanted_pet) |w| {
        wanted = w;
    } else if (settingsPath(&path_buf)) |path| {
        if (cReadFile(path, &settings_buf)) |json| {
            if (hook_server.jsonStringPub(json, "active_pet")) |v| wanted = v;
            if (hook_server.jsonNumberPub(json, "scale")) |v| {
                if (v >= 0.3 and v <= 1.5) initial_scale = @floatCast(v);
            }
            if (hook_server.jsonStringPub(json, "bubbles")) |_| {} else if (std.mem.indexOf(u8, json, "\"bubbles\":false") != null) {
                initial_bubbles = false;
            }
        }
    }
    var index: usize = 0;
    if (wanted.len > 0) {
        for (catalog[0..catalog_len], 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.slice(), wanted)) index = i;
        }
    }
    initial_pet = @intCast(index);
    if (!loadSheetForPet(&catalog[index])) return error.SheetConvertFailed;
    pet_display_name = catalog[index].slice();
}

/// Register the active state's frames into slots 1..count (replace in
/// place: the registry caps at 16 slots of 1MB, one 192x208 frame is
/// 160KB, and no state has more than 8 frames).
fn registerStateFrames(state: State, fx: *Effects) void {
    if (sheet.pixels.len == 0) return;
    const def = stateDef(state);
    const fw = sheet.width / cols;
    const fh = sheet.height / sheet.rows;
    var scratch = boot_allocator.alloc(u8, fw * fh * 4) catch return;
    defer boot_allocator.free(scratch);
    for (def.frames, 0..) |spec, i| {
        const src_x = spec.col * fw;
        const src_y = def.row * fh;
        for (0..fh) |y| {
            const src_off = ((src_y + y) * sheet.width + src_x) * 4;
            @memcpy(scratch[y * fw * 4 ..][0 .. fw * 4], sheet.pixels[src_off..][0 .. fw * 4]);
        }
        fx.registerImage(i + 1, fw, fh, scratch) catch |err| {
            std.debug.print("petdex: frame register failed ({s})\n", .{@errorName(err)});
            return;
        };
    }
}

const poll_timer_key: u64 = 2;
const poll_interval_ms: u32 = 100;
const min_dwell_ms: u32 = 250;

/// Transient states whose duration is intrinsic to the animation;
/// they revert to idle when their dwell expires and nothing is queued
/// (steady states persist until the hooks send the next event).
fn isDurationState(state: State) bool {
    return switch (state) {
        .waving, .failed, .review, .jumping => true,
        else => false,
    };
}

/// Port of state-queue.ts dwellFor.
fn dwellFor(state: State, duration_ms: u32) u32 {
    if (isDurationState(state) and duration_ms > 0) return @max(duration_ms, min_dwell_ms);
    if (duration_ms > min_dwell_ms) return duration_ms;
    return min_dwell_ms;
}

fn applyState(model: *Model, state: State, duration_ms: u32, fx: *Effects) void {
    model.state = state;
    model.frame_index = 0;
    model.shown_at_ms = fx.wallMs();
    model.shown_dwell_ms = dwellFor(state, duration_ms);
    registerStateFrames(state, fx);
    armFrameTimer(model, fx);
}

pub fn boot(model: *Model, fx: *Effects) void {
    if (env_home) |home| {
        hook_server.start(boot_allocator, home) catch |err| {
            std.debug.print("petdex: hook server failed to start ({s})\n", .{@errorName(err)});
        };
    }
    fx.startTimer(.{
        .key = poll_timer_key,
        .interval_ms = poll_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.poll_tick),
    });
    if (sheet.pixels.len == 0) return;
    model.scale = initial_scale;
    model.bubbles_enabled = initial_bubbles;
    model.active_pet = initial_pet;
    registerStateFrames(model.state, fx);
    model.sheet_loaded = true;
    const n = @min(pet_display_name.len, model.pet_name.len);
    @memcpy(model.pet_name[0..n], pet_display_name[0..n]);
    model.pet_name_len = n;
    armFrameTimer(model, fx);
}

fn pushSample(model: *Model, x: f64, y: f64, now: i64) void {
    // Keep only samples inside the window, then append.
    var kept: usize = 0;
    for (model.samples[0..model.sample_len]) |sample| {
        if (now - sample.t_ms <= sample_window_ms) {
            model.samples[kept] = sample;
            kept += 1;
        }
    }
    if (kept == model.samples.len) {
        std.mem.copyForwards(PosSample, model.samples[0 .. kept - 1], model.samples[1..kept]);
        kept -= 1;
    }
    model.samples[kept] = .{ .x = x, .y = y, .t_ms = now };
    model.sample_len = kept + 1;
}

/// The old renderer's computeVelocity: last sample against the newest
/// one older than 16ms, in points per second.
fn releaseVelocity(model: *const Model) ?struct { x: f64, y: f64 } {
    if (model.sample_len < 2) return null;
    const last = model.samples[model.sample_len - 1];
    // Oldest sample in the window older than one tick, the old
    // renderer's anchor: velocity averages the whole 100ms gesture
    // tail instead of chasing the last two frames.
    var first: ?PosSample = null;
    for (model.samples[0..model.sample_len]) |sample| {
        if (last.t_ms - sample.t_ms > 16) {
            first = sample;
            break;
        }
    }
    const anchor = first orelse return null;
    const dt_sec = @as(f64, @floatFromInt(last.t_ms - anchor.t_ms)) / 1000.0;
    if (dt_sec <= 0) return null;
    return .{ .x = (last.x - anchor.x) / dt_sec, .y = (last.y - anchor.y) / dt_sec };
}

fn setThrowState(model: *Model, state: State, fx: *Effects) void {
    if (model.state == state) return;
    model.state = state;
    model.frame_index = 0;
    registerStateFrames(state, fx);
    armFrameTimer(model, fx);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .frame_tick => |timer| {
            if (timer.outcome != .fired) return;
            if (!model.sheet_loaded) return;
            const def = stateDef(model.state);
            model.frame_index = (model.frame_index + 1) % def.frames.len;
            armFrameTimer(model, fx);
        },
        .cycle_state => {
            applyState(model, model.state.next(), 0, fx);
        },
        .open_settings => {
            if (model.settings_open) {
                // Already open, likely buried behind other windows:
                // raise it instead of rebuilding an identical
                // descriptor (a no-op).
                fx.focusWindow(settings_window_label);
                return;
            }
            model.settings_open = true;
        },
        .settings_closed => model.settings_open = false,
        .close_pet => fx.closeWindow("main"),
        .select_pet => |index| {
            if (index >= catalog_len or index == model.active_pet) return;
            if (!loadSheetForPet(&catalog[index])) return;
            model.active_pet = index;
            model.frame_index = 0;
            registerStateFrames(model.state, fx);
            armFrameTimer(model, fx);
            saveSettings(model);
        },
        .toggle_bubbles => {
            model.bubbles_enabled = !model.bubbles_enabled;
            _ = fitWindow(model, fx);
            saveSettings(model);
        },
        .set_scale => |fraction| {
            model.scale = 0.4 + fraction * 0.8;
            _ = fitWindow(model, fx);
            saveSettings(model);
        },
        .open_pet_page => |index| {
            if (index >= catalog_len) return;
            var buf: [256]u8 = undefined;
            const cmd = std.fmt.bufPrintZ(&buf, "/usr/bin/open 'https://petdex.dev/pets/{s}'", .{catalog[index].slice()}) catch return;
            _ = system(cmd);
        },
        .appearance => |a| {
            model.dark = a.color_scheme == .dark;
            if (model.bubble.text_len > 0) {
                registerTail(model.dark, fx);
                loadAgentAvatar(model.bubble.agent[0..model.bubble.agent_len], model.dark, fx);
            }
            model.high_contrast = a.high_contrast;
            model.reduce_motion = a.reduce_motion;
        },
        .noop => {},
        .open_pets_folder => {
            if (env_home) |home| {
                var buf: [512]u8 = undefined;
                const cmd = std.fmt.bufPrintZ(&buf, "/usr/bin/open '{s}/.petdex/pets'", .{home}) catch return;
                _ = system(cmd);
            }
        },
        .frame_clock => {
            if (!model.sheet_loaded) return;
            if (!model.window_fitted) {
                // The shell window boots at the slider's max extent;
                // fit it to the drawn sprite so the whole window IS the
                // pet — no invisible band above it eating clicks.
                model.window_fitted = fitWindow(model, fx);
            }
            const now = fx.wallMs();
            if (model.throwing) {
                // Momentum rides the frame clock with the real elapsed
                // time: no timer jitter, friction scaled per frame.
                var dt_ms = now - model.last_physics_ms;
                if (dt_ms <= 0) return;
                if (dt_ms > 50) dt_ms = 50;
                model.last_physics_ms = now;
                model.throw_elapsed_ms += @intCast(dt_ms);
                const dt: f64 = @as(f64, @floatFromInt(dt_ms)) / 1000.0;
                const moved = fx.moveWindow("main", model.vx * dt, model.vy * dt, true);
                if (moved) |result| {
                    if (result.hit_x) model.vx = 0;
                    if (result.hit_y) model.vy = 0;
                }
                if (model.vx >= physics_min_vel) {
                    setThrowState(model, .@"running-right", fx);
                } else if (model.vx <= -physics_min_vel) {
                    setThrowState(model, .@"running-left", fx);
                }
                const decay = std.math.pow(f64, physics_friction, dt * 1000.0 / @as(f64, physics_tick_ms));
                model.vx *= decay;
                model.vy *= decay;
                const speed = @sqrt(model.vx * model.vx + model.vy * model.vy);
                if (model.throw_elapsed_ms >= physics_max_duration_ms or speed < physics_min_vel) {
                    model.throwing = false;
                    applyState(model, .waving, 1200, fx);
                }
                return;
            }
            const read = fx.moveWindow("main", 0, 0, false) orelse return;
            if (model.dragging) {
                if (read.primary_down) {
                    // Follow the cursor keeping the grab offset, and
                    // record OUR OWN applied positions: the app drives
                    // the drag, so it has perfect knowledge of the
                    // gesture, no host telemetry involved.
                    const dx = (read.cursor_x - model.grab_dx) - read.x;
                    const dy = (read.cursor_y - model.grab_dy) - read.y;
                    if (dx != 0 or dy != 0) {
                        if (fx.moveWindow("main", dx, dy, false)) |moved| {
                            pushSample(model, moved.x, moved.y, now);
                        }
                    } else {
                        pushSample(model, read.x, read.y, now);
                    }
                    // Mid-drag animation: the pet runs toward where it
                    // is being pulled, from the same 100ms velocity
                    // tail the release uses (per-frame dx flaps).
                    if (releaseVelocity(model)) |vel| {
                        if (vel.x >= physics_min_vel) {
                            setThrowState(model, .@"running-right", fx);
                        } else if (vel.x <= -physics_min_vel) {
                            setThrowState(model, .@"running-left", fx);
                        } else if (@abs(vel.x) < 20 and @abs(vel.y) < 20) {
                            setThrowState(model, .idle, fx);
                        }
                    }
                    return;
                }
                // Release: velocity from our own 100ms sample tail,
                // the WebView renderer's computeVelocity semantics.
                model.dragging = false;
                const velocity = releaseVelocity(model) orelse {
                    model.sample_len = 0;
                    return;
                };
                model.sample_len = 0;
                if (@abs(velocity.x) < 1 and @abs(velocity.y) < 1) return;
                model.throwing = true;
                model.vx = velocity.x;
                model.vy = velocity.y;
                model.throw_elapsed_ms = 0;
                model.last_physics_ms = now;
                return;
            }
            const pet_w = frame_w * model.scale;
            const pet_h = frame_h * model.scale;
            // The window is fitted to the sprite; while a bubble
            // shows, the sprite sits bottom-center under the band.
            const window_w = if (bubbleActive(model)) @max(pet_w, @min(bubble_win_w, bubbleColW(model) + 80)) else pet_w;
            const left = read.x + (window_w - pet_w) / 2.0;
            const top = read.y + (if (bubbleActive(model)) bubbleBandH(model) else 0);
            const inside = read.cursor_x >= left and read.cursor_x <= left + pet_w and
                read.cursor_y >= top and read.cursor_y <= top + pet_h;
            if (read.primary_down and !model.primary_was_down and inside) {
                model.dragging = true;
                model.grab_dx = read.cursor_x - read.x;
                model.grab_dy = read.cursor_y - read.y;
                model.sample_len = 0;
                pushSample(model, read.x, read.y, now);
            }
            model.primary_was_down = read.primary_down;
        },
        .physics_tick => |timer| {
            _ = timer;
        },
        .poll_tick => |timer| {
            if (timer.outcome != .fired) return;
            if (!model.sheet_loaded) return;
            if (model.settings_open and thumbs_built < catalog_len) buildNextThumb(fx);
            if (hook_server.mailbox.takeBubble(&model.bubble)) {
                _ = fitWindow(model, fx);
                if (model.bubble.text_len > 0) {
                    loadAgentAvatar(model.bubble.agent[0..model.bubble.agent_len], model.dark, fx);
                    registerTail(model.dark, fx);
                }
            }
            const now = fx.wallMs();
            const dwell_over = now - model.shown_at_ms >= model.shown_dwell_ms;
            if (!dwell_over) return;
            if (hook_server.mailbox.pop()) |event| {
                const next_state = std.meta.stringToEnum(State, event.slice()) orelse return;
                if (next_state != model.state or isDurationState(next_state)) {
                    applyState(model, next_state, event.duration_ms, fx);
                } else {
                    model.shown_at_ms = now;
                    model.shown_dwell_ms = dwellFor(next_state, event.duration_ms);
                }
            } else if (isDurationState(model.state)) {
                applyState(model, .idle, 0, fx);
            }
        },
    }
}

pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.modifiers.hasNavigationModifier() or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "space")) return .cycle_state;
    return null;
}

pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    _ = model;
    _ = frame;
    return .frame_clock;
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "petdex.cycle")) return .cycle_state;
    if (std.mem.eql(u8, name, "petdex.settings")) return .open_settings;
    if (std.mem.eql(u8, name, "petdex.close")) return .close_pet;
    return null;
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);



const pet_menu = [_]AppUi.ContextMenuItem{
    .{ .label = "Open Settings", .msg = .open_settings },
    .{ .label = "Close Pet", .msg = .close_pet },
};

// Bubble geometry is fully derived: text is clipped to a hard char
// budget, the char budget bounds the line count, and the line count
// sets the card and window band heights. Nothing can overflow because
// nothing exceeds its budget.
const bubble_win_w: f32 = 330;
const bubble_text_w: f32 = 250;
const bubble_chars_per_line: usize = 26;
const bubble_max_lines: usize = 2;
const bubble_display_chars: usize = bubble_chars_per_line * bubble_max_lines;
const bubble_line_h: f32 = 20;
const bubble_card_pad: f32 = 12;
const tail_gap: f32 = 4;

/// Count display characters (UTF-8 sequences, not bytes).
fn charCount(text: []const u8) usize {
    var n: usize = 0;
    for (text) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
    }
    return n;
}

var bubble_title_scratch: [280]u8 = undefined;
var bubble_text_scratch: [280]u8 = undefined;

/// Clip to `max_chars` on a safe boundary: never mid UTF-8 sequence,
/// never splitting a JSON escape, preferring the last word boundary
/// within reach, with an ellipsis appended into `scratch` (globals:
/// the view's byte slices must outlive the frame build).
fn clipDisplay(text: []const u8, max_chars: usize, scratch: []u8) []const u8 {
    if (charCount(text) <= max_chars) return text;
    var n: usize = 0;
    var cut: usize = text.len;
    for (text, 0..) |b, i| {
        if ((b & 0xC0) != 0x80) {
            if (n == max_chars) {
                cut = i;
                break;
            }
            n += 1;
        }
    }
    if (std.mem.lastIndexOfScalar(u8, text[0..cut], ' ')) |sp| {
        if (cut - sp <= 10) cut = sp;
    }
    var backslashes: usize = 0;
    while (cut > backslashes and text[cut - 1 - backslashes] == '\\') backslashes += 1;
    if (backslashes % 2 == 1) cut -= 1;
    const ell = "\u{2026}";
    const total = @min(cut, scratch.len - ell.len);
    @memcpy(scratch[0..total], text[0..total]);
    @memcpy(scratch[total .. total + ell.len], ell);
    return scratch[0 .. total + ell.len];
}

/// Greedy word-wrap simulation at an over-provisioned per-char width:
/// the same packing the engine performs, so long unbreakable tokens
/// ("mcp__firecrawl__search") count the extra line they really take.
fn wrapLines(text: []const u8, width: f32, per_char: f32) f32 {
    if (text.len == 0) return 0;
    var lines: f32 = 1;
    var line_w: f32 = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |word| {
        const w = @as(f32, @floatFromInt(charCount(word))) * per_char;
        if (w > width) {
            // Token longer than the line: it breaks mid-token across
            // however many lines it needs, continuing on the last.
            var remaining = w;
            if (line_w > 0) lines += 1;
            while (remaining > width) {
                lines += 1;
                remaining -= width;
            }
            line_w = remaining + per_char;
            continue;
        }
        const space: f32 = if (line_w > 0) per_char else 0;
        if (line_w + space + w > width) {
            lines += 1;
            line_w = w;
        } else {
            line_w += space + w;
        }
    }
    return lines;
}

const bubble_title_per_char: f32 = 8.2;
const bubble_text_per_char: f32 = 7.4;
const bubble_line_h_exact: f32 = 21;

/// Fluid text-column width: short one-liners get a snug card, anything
/// longer takes the full column. Chars are display chars, the per-char
/// width a generous sm-size average so the estimate over-provisions
/// (the card itself is intrinsic — a misestimate costs pixels, never
/// clipped text).
fn bubbleColW(model: *const Model) f32 {
    const title_chars = @min(charCount(model.bubble.title[0..model.bubble.title_len]), bubble_display_chars);
    const text_chars = @min(charCount(model.bubble.text[0..model.bubble.text_len]), bubble_display_chars);
    const longest = @max(title_chars, text_chars);
    if (longest > bubble_chars_per_line) return bubble_text_w;
    // Bold titles carry wider glyphs than the muted preview.
    const per_char: f32 = if (title_chars > 0) 8.2 else 7.4;
    const w = @as(f32, @floatFromInt(longest)) * per_char + 10.0;
    return @max(64.0, @min(bubble_text_w, w));
}

/// Exact content height from the wrap simulation (display-clipped
/// text, so the inputs match what renders).
fn bubbleContentH(model: *const Model) f32 {
    const col = bubbleColW(model);
    var tbuf: [280]u8 = undefined;
    var xbuf: [280]u8 = undefined;
    const title = clipDisplay(model.bubble.title[0..model.bubble.title_len], bubble_display_chars, &tbuf);
    const text = clipDisplay(model.bubble.text[0..model.bubble.text_len], bubble_display_chars, &xbuf);
    const title_lines = wrapLines(title, col, bubble_title_per_char);
    const text_lines = @max(wrapLines(text, col, bubble_text_per_char), 1);
    const gap: f32 = if (title_lines > 0) 2 else 0;
    return @max(title_lines * bubble_line_h_exact + gap + text_lines * bubble_line_h_exact, 20);
}

fn bubbleBandH(model: *const Model) f32 {
    return bubble_card_pad * 2 + bubbleContentH(model) + tail_h_f + tail_gap + 12;
}
const tail_h_f: f32 = 9;

fn bubbleActive(model: *const Model) bool {
    return model.bubbles_enabled and model.bubble.text_len > 0;
}

/// The window tracks exactly what is drawn: the sprite, plus a band
/// above it while a bubble is showing (kept at least bubble-wide so
/// the text can wrap like the old 190px-capped tooltip).
fn fitWindow(model: *const Model, fx: *Effects) bool {
    const pet_w = frame_w * model.scale;
    const pet_h = frame_h * model.scale;
    const bubble_w = bubbleColW(model) + 80;
    const w = if (bubbleActive(model)) @max(pet_w, @min(bubble_win_w, bubble_w)) else pet_w;
    const h = if (bubbleActive(model)) pet_h + bubbleBandH(model) else pet_h;
    return fx.resizeWindow("main", w, h, .bottom_center);
}

pub fn rootView(ui: *AppUi, model: *const Model) AppUi.Node {
    if (!model.sheet_loaded) {
        return ui.panel(.{ .width = frame_w, .height = frame_h, .semantics = .{ .label = "No pet installed" } }, .{});
    }
    const w = frame_w * model.scale;
    const h = frame_h * model.scale;
    var node = ui.image(.{
        .width = w,
        .height = h,
        .image = @intCast(model.frame_index + 1),
        .semantics = .{ .label = "Petdex pet" },
    });
    node.widget.image_fit = .stretch;
    node.widget.image_sampling = .nearest;
    // Bottom-center anchored: a smaller pet still stands on the same
    // ground line instead of floating at the window's top-left. The
    // context menu rides the root container: the image widget is
    // display-only for hit testing, the column owns the right-click.
    // on_press makes the container a press claimer so the right-click
    // fall-through resolves here and the context menu shows; the drag
    // never rides widget presses (cursor polling), so a claimed press
    // costs nothing.
    if (bubbleActive(model)) {
        const title_raw = model.bubble.title[0..model.bubble.title_len];
        const text_raw = model.bubble.text[0..model.bubble.text_len];
        const title_clipped = clipDisplay(title_raw, bubble_display_chars, &bubble_title_scratch);
        const text_clipped = clipDisplay(text_raw, bubble_display_chars, &bubble_text_scratch);
        var text_node = ui.text(.{
            .size = .sm,
            .wrap = true,
            .width = bubbleColW(model),
        }, text_clipped);
        var avatar = ui.image(.{
            .width = 20,
            .height = 20,
            .image = if (avatar_ready) avatar_image_id else 0,
            .semantics = .{ .label = "Agent avatar" },
        });
        avatar.widget.image_fit = .contain;
        const spinner_slot = if (model.bubble.busy)
            ui.el(.spinner, .{ .width = 16, .height = 16, .semantics = .{ .label = "Working" } }, .{})
        else
            ui.el(.stack, .{ .width = 16, .height = 16 }, .{});
        var card = if (title_clipped.len > 0) blk: {
            var title_node = ui.paragraph(.{ .size = .sm, .width = bubbleColW(model) }, &.{.{
                .text = title_clipped,
                .weight = .bold,
            }});
            title_node.widget.style.foreground = if (model.dark) canvas.Color.rgb8(237, 237, 238) else canvas.Color.rgb8(17, 17, 17);
            text_node.widget.style.foreground = if (model.dark) canvas.Color.rgb8(156, 158, 168) else canvas.Color.rgb8(88, 92, 106);
            break :blk ui.el(.panel, .{
                .padding = bubble_card_pad,
                .style_tokens = .{ .radius = .md },
            }, .{
                ui.row(.{ .gap = 8, .cross = .center }, .{
                    avatar,
                    ui.column(.{ .gap = 2, .width = bubbleColW(model), .cross = .start }, .{ title_node, text_node }),
                    spinner_slot,
                }),
            });
        } else blk: {
            text_node.widget.style.foreground = if (model.dark) canvas.Color.rgb8(237, 237, 238) else canvas.Color.rgb8(17, 17, 17);
            break :blk ui.el(.panel, .{
                .padding = bubble_card_pad,
                .style_tokens = .{ .radius = .md },
            }, .{
                ui.row(.{ .gap = 8, .cross = .center }, .{
                    avatar,
                    ui.column(.{ .width = bubbleColW(model), .cross = .start }, .{text_node}),
                    spinner_slot,
                }),
            });
        };
        if (model.dark) {
            card.widget.style.background = canvas.Color.rgb8(25, 25, 28);
            card.widget.style.border = canvas.Color.rgba8(255, 255, 255, 26);
            card.widget.style.stroke_width = 1;
        } else {
            card.widget.style.background = canvas.Color.rgb8(255, 255, 255);
        }
        var tail = ui.image(.{
            .width = tail_w,
            .height = tail_h,
            .image = if (tail_ready) tail_image_id else 0,
        });
        tail.widget.image_fit = .contain;
        return ui.column(.{ .grow = 1, .main = .end, .cross = .center, .on_press = .noop, .context_menu = &pet_menu }, .{
            card,
            tail,
            node,
        });
    }
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center, .on_press = .noop, .context_menu = &pet_menu }, .{node});
}

// --------------------------------------------------------- settings window

const settings_window_label = "settings";
const settings_canvas_label = "settings-canvas";

fn petdexWindows(model: *const Model, scratch: *PetdexApp.WindowsScratch) []const PetdexApp.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = settings_window_label,
            .canvas_label = settings_canvas_label,
            .title = "Petdex Settings",
            .width = 420,
            .height = 640,
            .resizable = false,
            .on_close = .settings_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn petdexWindowView(ui: *PetdexApp.Ui, model: *const Model, window_label: []const u8) PetdexApp.Ui.Node {
    std.debug.assert(std.mem.eql(u8, window_label, settings_window_label));
    return settingsView(ui, model);
}

fn settingsView(ui: *AppUi, model: *const Model) AppUi.Node {
    var rows: [max_catalog]AppUi.Node = undefined;
    const shown = @min(catalog_len, max_catalog);
    for (catalog[0..shown], 0..) |*entry, i| {
        const active = i == model.active_pet;
        var thumb = ui.image(.{
            .width = 40,
            .height = 44,
            .image = if (thumbs_ready[i]) thumb_atlas_id else 0,
            .semantics = .{ .label = entry.slice() },
        });
        thumb.widget.image_src = geometry.RectF.init(
            @as(f32, @floatFromInt(i * thumb_w)),
            0,
            @as(f32, @floatFromInt(thumb_w)),
            @as(f32, @floatFromInt(thumb_h)),
        );
        thumb.widget.image_fit = .contain;
        thumb.widget.image_sampling = .nearest;
        rows[i] = ui.el(.list_item, .{
            .height = 56,
            .padding = 8,
            .gap = 12,
            .cross = .center,
            .on_press = Msg{ .select_pet = @intCast(i) },
            .selected = active,
            .style_tokens = .{ .background = .surface, .radius = .md },
            .semantics = .{ .label = entry.slice() },
        }, .{
            thumb,
            ui.column(.{ .grow = 1, .main = .center }, .{
                ui.text(.{}, entry.slice()),
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, entry.rootSlice()),
            }),
            if (active)
                ui.button(.{ .size = .sm, .width = 64, .variant = .primary, .disabled = true }, "Active")
            else
                ui.button(.{ .size = .sm, .width = 64, .variant = .primary, .on_press = Msg{ .select_pet = @intCast(i) } }, "Select"),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = Msg{ .open_pet_page = @intCast(i) } }, "Open"),
        });
    }
    const scale_fraction: f32 = (model.scale - 0.4) / 0.8;
    // The scroll needs a definite band (grow cannot shrink a scroll
    // below its intrinsic content). Budget, measured from a collapsed
    // render: constant chrome incl. paddings = 339pt of the 640pt
    // canvas (three cards), leaving 300 for the list at a 16pt bottom
    // margin.
    const list_intrinsic: f32 = @as(f32, @floatFromInt(shown)) * 62.0 - 6.0;
    const list_h: f32 = @min(300.0, list_intrinsic);
    return ui.column(.{ .grow = 1, .padding = 16, .gap = 12 }, .{
        ui.text(.{ .size = .heading }, "Pets"),
        ui.scroll(.{ .height = list_h }, .{ui.column(.{ .gap = 6 }, @as([]const AppUi.Node, rows[0..shown]))}),
        ui.text(.{ .size = .heading }, "Appearance"),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, "Pet size"),
                    ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Adjust the size of your pet"),
                }),
                ui.el(.slider, .{ .width = 150, .value = scale_fraction, .on_value = AppUi.valueMsg(.set_scale), .semantics = .{ .label = "Pet size" } }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, "Show messages"),
                    ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Agent activity bubbles over the pet"),
                }),
                ui.el(.switch_control, .{
                    .selected = model.bubbles_enabled,
                    .on_toggle = .toggle_bubbles,
                    .semantics = .{ .label = "Show messages" },
                }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, "Custom pets"),
                    ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "~/.petdex/pets"),
                }),
                ui.button(.{ .on_press = .open_pets_folder }, "Open folder"),
            }),
        }),
    });
}

/// Keep `~/.petdex/bin/petdex-hook` pointing at the running binary so
/// agent hooks survive app updates: the hooks reference the stable
/// symlink, the app re-aims it every boot.
fn refreshHookSymlink(argv0: []const u8) void {
    const home = env_home orelse return;
    var argv0_z: [1024]u8 = undefined;
    const az = std.fmt.bufPrintZ(&argv0_z, "{s}", .{argv0}) catch return;
    var self_buf: [1024]u8 = undefined;
    const rp = std.c.realpath(az, &self_buf) orelse return;
    var dir_z: [512]u8 = undefined;
    const bin = std.fmt.bufPrintZ(&dir_z, "{s}/.petdex/bin", .{home}) catch return;
    _ = std.c.mkdir(bin, 0o755);
    var link_z: [512]u8 = undefined;
    const link = std.fmt.bufPrintZ(&link_z, "{s}/.petdex/bin/petdex-hook", .{home}) catch return;
    _ = std.c.unlink(link);
    _ = std.c.symlink(rp, link);
}

// -------------------------------------------------------------------- app

const app_menus = [_]native_sdk.platform.Menu{.{
    .title = "Pet",
    .items = &.{
        .{ .label = "Settings...", .command = "petdex.settings", .key = ",", .modifiers = .{ .primary = true } },
        .{ .separator = true },
        .{ .label = "Close Pet", .command = "petdex.close", .key = "w", .modifiers = .{ .primary = true } },
    },
}};

const PetdexApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    env_home = init.environ_map.get("HOME");
    // Hook hot path: `<binary> bubble <phase> [agent]` runs the
    // in-binary runner and exits before any UI machinery spins up.
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    const argv0: ?[]const u8 = args_it.next();
    if (args_it.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "bubble")) {
            const phase = args_it.next() orelse return;
            const agent: ?[]const u8 = args_it.next();
            hook_runner.run(phase, agent, env_home orelse return);
            return;
        }
    }
    if (argv0) |a0| refreshHookSymlink(a0);
    env_wanted_pet = init.environ_map.get("PETDEX_PET");
    boot_io = init.io;
    loadSheetPixels(init.io, boot_allocator, init.environ_map) catch |err| {
        std.debug.print("petdex: sheet load failed ({s}); install a pet with `petdex install <pet>`\n", .{@errorName(err)});
    };
    const app_state = try PetdexApp.create(std.heap.page_allocator, .{
        .name = "petdex-desktop-native",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .view = rootView,
        .on_key = onKey,
        .on_command = onCommand,
        .on_frame = onFrame,
        .windows_fn = petdexWindows,
        .window_view = petdexWindowView,
        .tokens_fn = petdexTokens,
        .on_appearance = onAppearance,
    });
    defer app_state.destroy();
    app_state.model = .{};

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "petdex-desktop-native",
        .window_title = "Petdex",
        .bundle_id = "dev.petdex.desktop-native",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, win_w, win_h),
        .restore_state = false,
        .js_window_api = false,
        .menus = &app_menus,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}
