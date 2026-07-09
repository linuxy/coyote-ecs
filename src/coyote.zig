const std = @import("std");
const builtin = @import("builtin");

pub const CHUNK_SIZE = 128; //Only operate on one chunk at a time
pub const MAGIC = 0x0DEADB33F; //Helps check for optimizer related issues

pub const allocator = std.heap.c_allocator;

//Per-world component/resource type registry. Type ids are dense u32 indices
//assigned on first use; there is no fixed upper bound on registered types.
pub const TypeRegistry = struct {
    const Entry = struct {
        key: usize,
        size: usize,
        alignment: u8,
    };

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    zig_lookup: std.HashMapUnmanaged(usize, u32, std.hash_map.AutoContext(usize), 80) = .{},
    c_lookup: std.HashMapUnmanaged(usize, u32, std.hash_map.AutoContext(usize), 80) = .{},

    pub fn deinit(self: *TypeRegistry, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.zig_lookup.deinit(alloc);
        self.c_lookup.deinit(alloc);
    }

    pub fn registerZig(self: *TypeRegistry, alloc: std.mem.Allocator, comptime T: type) !u32 {
        const key = @intFromPtr(@typeName(T).ptr);
        if (self.zig_lookup.get(key)) |id| return id;
        const id: u32 = @intCast(self.entries.items.len);
        try self.entries.append(alloc, .{ .key = key, .size = @sizeOf(T), .alignment = @alignOf(T) });
        try self.zig_lookup.put(alloc, key, id);
        return id;
    }

    pub fn registerC(self: *TypeRegistry, alloc: std.mem.Allocator, ct: c_type) !u32 {
        const key = ct.id;
        if (self.c_lookup.get(key)) |id| return id;
        const id: u32 = @intCast(self.entries.items.len);
        try self.entries.append(alloc, .{ .key = key, .size = ct.size, .alignment = ct.alignment });
        try self.c_lookup.put(alloc, key, id);
        return id;
    }

    pub fn sizeOf(self: *const TypeRegistry, id: u32) usize {
        return self.entries.items[@intCast(id)].size;
    }

    pub fn alignOf(self: *const TypeRegistry, id: u32) u8 {
        return self.entries.items[@intCast(id)].alignment;
    }

    pub fn count(self: *const TypeRegistry) u32 {
        return @intCast(self.entries.items.len);
    }
};

//Sorted, deduplicated list of component type ids owned by an entity/archetype.
//Archetype queries test include/exclude against these small lists instead of
//fixed-width bitmasks, so registered types are not capped by machine word size.
pub const TypeSignature = struct {
    ids: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(self: *TypeSignature, alloc: std.mem.Allocator) void {
        self.ids.deinit(alloc);
    }

    pub fn clone(self: *const TypeSignature, alloc: std.mem.Allocator) !TypeSignature {
        var out: TypeSignature = .{};
        try out.ids.appendSlice(alloc, self.ids.items);
        return out;
    }

    pub fn eql(self: TypeSignature, other: TypeSignature) bool {
        return std.mem.eql(u32, self.ids.items, other.ids.items);
    }

    pub fn hash(self: TypeSignature) u64 {
        var h: u64 = self.ids.items.len;
        for (self.ids.items) |id| {
            h = std.hash.Wyhash.hash(h, std.mem.asBytes(&id));
        }
        return h;
    }

    pub fn contains(self: *const TypeSignature, tid: u32) bool {
        for (self.ids.items) |id| {
            if (id == tid) return true;
        }
        return false;
    }

    pub fn matches(self: *const TypeSignature, include: []const u32, exclude: []const u32) bool {
        for (include) |tid| {
            if (!self.contains(tid)) return false;
        }
        for (exclude) |tid| {
            if (self.contains(tid)) return false;
        }
        return true;
    }

    pub fn add(self: *TypeSignature, alloc: std.mem.Allocator, tid: u32) !void {
        if (self.contains(tid)) return;
        try self.ids.append(alloc, tid);
        std.mem.sort(u32, self.ids.items, {}, std.sort.asc(u32));
    }

    pub fn remove(self: *TypeSignature, tid: u32) void {
        for (self.ids.items, 0..) |id, i| {
            if (id == tid) {
                _ = self.ids.swapRemove(i);
                return;
            }
        }
    }

    //Builds the sorted type-id set from an entity's owned-component reverse index.
    pub fn fromEntity(alloc: std.mem.Allocator, entity: *const Entity) !TypeSignature {
        var sig: TypeSignature = .{};
        errdefer sig.deinit(alloc);
        var k: u32 = 0;
        while (k < entity.owned.len) : (k += 1) {
            const component = entity.owned.at(k);
            if (!component.alive) continue;
            if (component.typeId) |tid| try sig.add(alloc, tid);
        }
        return sig;
    }
};

//No chunk should know of another chunk
//Modulo ID/CHUNK

//SuperComponents map component chunks to current layout

pub const c_type = extern struct {
    id: usize = 0,
    size: usize = 0,
    alignment: u8 = 8,
    name: [*c]u8 = null,
};

pub const SuperComponents = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    alive: usize,

    pub inline fn count(ctx: *SuperComponents) u32 {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        var i: usize = 0;
        var total: u32 = 0;
        while (i < world.components_len) : (i += 1) {
            total += world._components[i].alive;
        }
        return total;
    }

    pub fn create(ctx: *SuperComponents, comptime comp_type: type) !*Component {
        var world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        // Find a chunk with available space
        var i: usize = 0;
        var found_chunk = false;
        while (i < world.components_len) : (i += 1) {
            if (world._components[i].alive < CHUNK_SIZE) {
                world.components_free_idx = i;
                found_chunk = true;
                break;
            }
        }

        // If no chunk has space, create a new one
        if (!found_chunk) {
            try ctx.expand();
        }

        // Create the component in the selected chunk
        const component = try world._components[world.components_free_idx].create(comp_type);

        // Only increment the alive count after successful creation
        ctx.alive += 1;

        return component;
    }

    pub fn create_c(ctx: *SuperComponents, comp_type: c_type) !*Component {
        var world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        // Find a chunk with available space
        var i: usize = 0;
        var found_chunk = false;
        while (i < world.components_len) : (i += 1) {
            if (world._components[i].alive < CHUNK_SIZE) {
                world.components_free_idx = i;
                found_chunk = true;
                break;
            }
        }

        // If no chunk has space, create a new one
        if (!found_chunk) {
            try ctx.expand();
        }

        // Create the component in the selected chunk
        const component = try world._components[world.components_free_idx].create_c(comp_type);

        // Only increment the alive count after successful creation
        ctx.alive += 1;

        return component;
    }

    pub fn expand(ctx: *SuperComponents) !void {
        var world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        world._components = try world.allocator.realloc(world._components, world.components_len + 1);
        world._components[world.components_len].world = world;
        world._components[world.components_len].len = 0;
        world._components[world.components_len].alive = 0;
        world._components[world.components_len].created = 0;
        world._components[world.components_len].free_idx = 0;
        world._components[world.components_len].chunk = world.components_len;
        world._components[world.components_len].sparse = try world.allocator.alloc(Component, CHUNK_SIZE);

        world.components_len += 1;
        world.components_free_idx = world.components_len - 1;
        components_idx = world.components_free_idx;
    }

    pub fn gc(ctx: *SuperComponents) void {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        var i: usize = 0;
        var j: usize = 0;
        while (i < world.components_len) : (i += 1) {
            while (j < CHUNK_SIZE) : (j += 1) {
                if (world._components[i].sparse[j].allocated and !world._components[i].sparse[j].alive) {
                    world._components[i].sparse[j].dealloc();
                }
            }
            j = 0;
        }
    }

    pub const Iterator = struct {
        ctx: *[]_Components,
        index: usize = 0,
        alive: usize = 0,
        world: *World,

        pub inline fn next(it: *Iterator) ?*Component {
            while (it.index < it.alive) : (it.index += 1) {
                const mod = it.index / CHUNK_SIZE;
                const rem = @rem(it.index, CHUNK_SIZE);
                if (it.ctx.*[mod].sparse[rem].alive) {
                    const sparse_index = rem;
                    it.index += 1;
                    return &it.ctx.*[mod].sparse[sparse_index];
                }
            }

            return null;
        }
    };

    pub const MaskedIterator = struct {
        world: *World,
        filter_type: u32,
        arch_index: usize = 0,
        row: usize = 0,

        pub fn next(it: *MaskedIterator) ?*Component {
            const active = it.world.archetypes.active.items;
            while (it.arch_index < active.len) {
                const arch = &it.world.archetypes.list.items[active[it.arch_index]];
                if (!arch.signature.contains(it.filter_type)) {
                    it.arch_index += 1;
                    it.row = 0;
                    continue;
                }
                while (it.row < arch.entities.items.len) {
                    const gid = arch.entities.items[it.row];
                    it.row += 1;
                    if (resolveGlobalId(it.world, gid)) |entity| {
                        if (entity.getOneComponentById(it.filter_type)) |component| return component;
                    }
                }
                it.arch_index += 1;
                it.row = 0;
            }
            return null;
        }
    };

    pub const MaskedRangeIterator = struct {
        ctx: *[]_Components,
        index: usize = 0,
        filter_type: u32,
        start_index: usize = 0,
        end_index: usize = 0,
        world: *World,

        pub fn next(it: *MaskedRangeIterator) ?*Component {
            while (it.index < it.end_index) : (it.index += 1) {
                const mod = it.index / CHUNK_SIZE;
                const rem = @rem(it.index, CHUNK_SIZE);
                const component = &it.ctx.*[mod].sparse[rem];
                if (!component.alive) continue;
                if (component.typeId) |tid| {
                    if (tid == it.filter_type) {
                        it.index += 1;
                        return component;
                    }
                }
            }

            return null;
        }
    };

    pub const MaskedEntityIterator = struct {
        filter_type: u32,
        entity: *Entity,
        index: u32 = 0,

        pub inline fn next(it: *MaskedEntityIterator) ?*Component {
            while (it.index < it.entity.owned.len) : (it.index += 1) {
                const component = it.entity.owned.at(it.index);
                if (!component.alive) continue;
                if (component.typeId) |tid| {
                    if (tid == it.filter_type) return component;
                }
            }
            return null;
        }
    };

    //TODO: By attached vs unattached
    pub inline fn iterator(ctx: *SuperComponents) SuperComponents.Iterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const components = &world._components;
        return .{ .ctx = components, .index = 0, .alive = CHUNK_SIZE * world.components_len, .world = world };
    }

    pub fn iteratorFilter(ctx: *SuperComponents, comptime comp_type: type) SuperComponents.MaskedIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return .{ .world = world, .filter_type = world.typeId(comp_type) };
    }

    pub fn iteratorFilterRange(ctx: *SuperComponents, comptime comp_type: type, start_idx: usize, end_idx: usize) SuperComponents.MaskedRangeIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const components = &world._components;
        return .{ .ctx = components, .filter_type = world.typeId(comp_type), .index = start_idx, .start_index = start_idx, .end_index = end_idx, .world = world };
    }

    pub fn iteratorFilterByEntity(ctx: *SuperComponents, entity: *Entity, comptime comp_type: type) SuperComponents.MaskedEntityIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return ctx.iteratorFilterByEntityType(entity, world.typeId(comp_type));
    }

    pub fn iteratorFilterByEntityType(_: *SuperComponents, entity: *Entity, filter_type: u32) SuperComponents.MaskedEntityIterator {
        return .{ .filter_type = filter_type, .entity = entity };
    }

    /// Processes every SoA column for `comp_type` across matching archetype tables.
    pub fn processComponentsSimd(ctx: *SuperComponents, comptime comp_type: type, processor: fn (*comp_type) void) void {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        ColumnSimd.forEachMatchingColumn(world, comp_type, processor);
    }

    /// Processes a row subrange `[row_start, row_end)` in each matching archetype column.
    pub fn processComponentsRangeSimd(
        ctx: *SuperComponents,
        comptime comp_type: type,
        row_start: usize,
        row_end: usize,
        processor: fn (*comp_type) void,
    ) void {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        ColumnSimd.forEachMatchingColumnRange(world, comp_type, row_start, row_end, processor);
    }
};

pub const _Components = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    len: u32,
    alive: u32,
    sparse: []Component,
    free_idx: u32 = 0,
    created: u32 = 0,
    chunk: usize,

    pub inline fn count(ctx: *_Components) u32 {
        return ctx.alive;
    }

    pub fn processComponentsSimd(ctx: *_Components, comptime comp_type: type, processor: fn (*comp_type) void) void {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        ColumnSimd.forEachMatchingColumn(world, comp_type, processor);
    }

    pub fn processComponentsRangeSimd(
        ctx: *_Components,
        comptime comp_type: type,
        row_start: usize,
        row_end: usize,
        processor: fn (*comp_type) void,
    ) void {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        ColumnSimd.forEachMatchingColumnRange(world, comp_type, row_start, row_end, processor);
    }

    pub fn create(ctx: *_Components, comptime comp_type: type) !*Component {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        if (ctx.alive >= CHUNK_SIZE)
            return error.NoFreeComponentSlots;

        // Reset free_idx if it's out of bounds
        if (ctx.free_idx >= CHUNK_SIZE)
            ctx.free_idx = 0;

        // Find a free slot
        const start_idx = ctx.free_idx;
        var wrapped = false;
        while (ctx.sparse[ctx.free_idx].alive) {
            ctx.free_idx += 1;
            if (ctx.free_idx >= CHUNK_SIZE) {
                if (wrapped) {
                    return error.NoFreeComponentSlots;
                }
                ctx.free_idx = 0;
                wrapped = true;
            }
            if (ctx.free_idx == start_idx) {
                return error.NoFreeComponentSlots;
            }
        }

        // Initialize the component
        var component = &ctx.sparse[ctx.free_idx];
        component.world = world;
        component.attached = false;
        component.magic = MAGIC;
        component.typeId = world.typeId(comp_type);
        component.id = ctx.free_idx;
        component.alive = true;
        component.owners = .{};
        component.type_node = .{};
        component.chunk = ctx.chunk;
        component.data = null;
        component.allocated = false;

        // Update chunk state
        ctx.free_idx += 1;
        ctx.created += 1;
        ctx.alive += 1;
        if (!wrapped) {
            ctx.len += 1;
        }

        return component;
    }

    pub fn create_c(ctx: *_Components, comp_type: c_type) !*Component {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        if (ctx.alive >= CHUNK_SIZE)
            return error.NoFreeComponentSlots;

        // Reset free_idx if it's out of bounds
        if (ctx.free_idx >= CHUNK_SIZE)
            ctx.free_idx = 0;

        // Find a free slot
        const start_idx = ctx.free_idx;
        var wrapped = false;
        while (ctx.sparse[ctx.free_idx].alive) {
            ctx.free_idx += 1;
            if (ctx.free_idx >= CHUNK_SIZE) {
                if (wrapped) {
                    return error.NoFreeComponentSlots;
                }
                ctx.free_idx = 0;
                wrapped = true;
            }
            if (ctx.free_idx == start_idx) {
                return error.NoFreeComponentSlots;
            }
        }

        // Initialize the component
        var component = &ctx.sparse[ctx.free_idx];
        component.world = world;
        component.attached = false;
        component.magic = MAGIC;
        component.typeId = world.typeIdC(comp_type);
        component.id = ctx.free_idx;
        component.alive = true;
        component.owners = .{};
        component.type_node = .{};
        component.chunk = ctx.chunk;
        component.data = null;
        component.allocated = false;

        // Update chunk state
        ctx.free_idx += 1;
        ctx.created += 1;
        ctx.alive += 1;
        if (!wrapped) {
            ctx.len += 1;
        }

        return component;
    }
};

//TLS
var entities_idx: usize = 0;
var components_idx: usize = 0;

//World-scoped singletons keyed by type (delta time, input, config, etc.). Uses
//the same type-id registry as components so the C API can address resources by
//`coyote_type`. At most one value per type per world; inserting again replaces.
pub const Resources = struct {
    const Entry = struct {
        ptr: *anyopaque,
        size: usize,
        alignment: u8,
    };

    store: std.HashMapUnmanaged(u32, Entry, std.hash_map.AutoContext(u32), 80) = .{},

    pub fn deinit(self: *Resources, alloc: std.mem.Allocator) void {
        if (self.store.count() != 0) {
            var it = self.store.iterator();
            while (it.next()) |entry| {
                opaqueDestroy(alloc, entry.value_ptr.ptr, entry.value_ptr.size, entry.value_ptr.alignment);
            }
        }
        self.store.deinit(alloc);
    }

    pub fn insert(self: *Resources, world: *World, comptime T: type, value: T) !void {
        const id = world.typeId(T);
        if (self.store.get(id)) |existing| {
            opaqueDestroy(world.allocator, existing.ptr, existing.size, existing.alignment);
            _ = self.store.remove(id);
        }
        const ptr = try world.allocator.create(T);
        ptr.* = value;
        try self.store.put(world.allocator, id, .{
            .ptr = ptr,
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
        });
    }

    pub fn get(self: *Resources, world: *World, comptime T: type) ?*T {
        const id = world.typeId(T);
        const entry = self.store.get(id) orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    pub inline fn contains(self: *Resources, world: *World, comptime T: type) bool {
        return self.get(world, T) != null;
    }

    pub fn remove(self: *Resources, world: *World, comptime T: type) void {
        const id = world.typeId(T);
        if (self.store.fetchRemove(id)) |kv| {
            opaqueDestroy(world.allocator, kv.value.ptr, kv.value.size, kv.value.alignment);
        }
    }

    pub fn cInsert(self: *Resources, world: *World, ct: c_type, data: *const anyopaque) !void {
        const id = world.typeIdC(ct);
        const size = world.types.sizeOf(id);
        const align_val = world.types.alignOf(id);

        if (self.store.get(id)) |existing| {
            opaqueDestroy(world.allocator, existing.ptr, existing.size, existing.alignment);
            _ = self.store.remove(id);
        }

        const mem = world.allocator.rawAlloc(size, .fromByteUnits(align_val), @returnAddress()) orelse return error.OutOfMemory;
        @memcpy(mem[0..size], @as([*]const u8, @ptrCast(data))[0..size]);
        try self.store.put(world.allocator, id, .{ .ptr = mem, .size = size, .alignment = align_val });
    }

    pub fn cGet(self: *Resources, world: *World, ct: c_type) ?*anyopaque {
        const id = world.typeIdC(ct);
        const entry = self.store.get(id) orelse return null;
        return entry.ptr;
    }

    pub fn cContains(self: *Resources, world: *World, ct: c_type) bool {
        const id = world.typeIdC(ct);
        return self.store.contains(id);
    }

    pub fn cRemove(self: *Resources, world: *World, ct: c_type) void {
        const id = world.typeIdC(ct);
        if (self.store.fetchRemove(id)) |kv| {
            opaqueDestroy(world.allocator, kv.value.ptr, kv.value.size, kv.value.alignment);
        }
    }
};

//Dense SoA column for one component type inside an archetype table.
pub const ArchetypeColumn = struct {
    type_id: u32,
    data: []u8 = &.{},
    capacity: usize = 0,
    elem_size: usize,
    align_bytes: u8,

    pub fn rowPtr(self: *const ArchetypeColumn, row: usize) ?*anyopaque {
        if (self.elem_size == 0) return @ptrFromInt(1);
        if (row >= self.capacity) return null;
        return @ptrCast(self.data.ptr + row * self.elem_size);
    }

    fn ensureCapacity(self: *ArchetypeColumn, alloc: std.mem.Allocator, rows: usize) !void {
        if (rows <= self.capacity) return;
        var new_cap: usize = if (self.capacity == 0) 16 else self.capacity;
        while (new_cap < rows) new_cap *= 2;
        const total = new_cap * self.elem_size;
        const new_bytes = try allocBytes(alloc, total, self.align_bytes);
        if (self.capacity > 0) {
            const old_bytes = self.capacity * self.elem_size;
            @memcpy(new_bytes[0..old_bytes], self.data[0..old_bytes]);
        }
        if (self.capacity > 0) freeBytes(alloc, self.data, self.align_bytes);
        self.data = new_bytes;
        self.capacity = new_cap;
    }

    fn swapRows(self: *ArchetypeColumn, alloc: std.mem.Allocator, a: usize, b: usize) !void {
        if (a == b or self.elem_size == 0) return;
        const tmp = try allocBytes(alloc, self.elem_size, self.align_bytes);
        defer freeBytes(alloc, tmp, self.align_bytes);
        const a_off = a * self.elem_size;
        const b_off = b * self.elem_size;
        @memcpy(tmp, self.data[a_off .. a_off + self.elem_size]);
        @memcpy(self.data[a_off .. a_off + self.elem_size], self.data[b_off .. b_off + self.elem_size]);
        @memcpy(self.data[b_off .. b_off + self.elem_size], tmp);
    }

    fn deinit(self: *ArchetypeColumn, alloc: std.mem.Allocator) void {
        if (self.capacity > 0) freeBytes(alloc, self.data, self.align_bytes);
        self.* = .{ .type_id = self.type_id, .elem_size = self.elem_size, .align_bytes = self.align_bytes };
    }
};

fn allocBytes(alloc: std.mem.Allocator, size: usize, align_bytes: u8) ![]u8 {
    const mem = alloc.rawAlloc(size, .fromByteUnits(align_bytes), @returnAddress()) orelse return error.OutOfMemory;
    return mem[0..size];
}

fn freeBytes(alloc: std.mem.Allocator, bytes: []u8, align_bytes: u8) void {
    alloc.rawFree(bytes, .fromByteUnits(align_bytes), @returnAddress());
}

/// SoA column utilities: typed slices, dense iteration, and vectorized float math.
pub const ColumnSimd = struct {
    pub fn typedSlice(comptime T: type, col: *const ArchetypeColumn, row_count: usize) []T {
        if (row_count == 0 or col.elem_size == 0) return &[_]T{};
        const n = @min(row_count, col.capacity);
        std.debug.assert(@sizeOf(T) == col.elem_size);
        std.debug.assert(@alignOf(T) <= col.align_bytes);
        return @as([*]T, @ptrCast(@alignCast(col.data.ptr)))[0..n];
    }

    pub fn processElements(comptime T: type, col: *const ArchetypeColumn, row_count: usize, processor: fn (*T) void) void {
        const slice = typedSlice(T, col, row_count);
        for (slice) |*elem| processor(elem);
    }

    pub fn forEachMatchingColumn(world: *World, comptime T: type, processor: fn (*T) void) void {
        const tid = world.typeId(T);
        for (world.archetypes.active.items) |arch_idx| {
            const arch = &world.archetypes.list.items[arch_idx];
            if (!arch.signature.contains(tid)) continue;
            const col_idx = Archetypes.columnIndex(arch, tid) orelse continue;
            const col = &arch.columns.items[col_idx];
            processElements(T, col, arch.entities.items.len, processor);
        }
    }

    pub fn forEachMatchingColumnRange(
        world: *World,
        comptime T: type,
        row_start: usize,
        row_end: usize,
        processor: fn (*T) void,
    ) void {
        if (row_end <= row_start) return;
        const tid = world.typeId(T);
        for (world.archetypes.active.items) |arch_idx| {
            const arch = &world.archetypes.list.items[arch_idx];
            if (!arch.signature.contains(tid)) continue;
            const col_idx = Archetypes.columnIndex(arch, tid) orelse continue;
            const col = &arch.columns.items[col_idx];
            const n = arch.entities.items.len;
            const start = @min(row_start, n);
            const end = @min(row_end, n);
            if (end <= start) continue;
            const slice = typedSlice(T, col, n);
            for (slice[start..end]) |*elem| processor(elem);
        }
    }

    /// `dst[i] += src[i] * scale` over the shared prefix, using SIMD when width > 1.
    pub fn f32AddMulSimd(dst: []f32, src: []const f32, scale: f32) void {
        const n = @min(dst.len, src.len);
        if (n == 0) return;
        const width = std.simd.suggestVectorLength(f32) orelse 1;
        if (width <= 1) {
            var i: usize = 0;
            while (i < n) : (i += 1) dst[i] += src[i] * scale;
            return;
        }
        const scale_v: @Vector(width, f32) = @splat(scale);
        var i: usize = 0;
        while (i + width <= n) : (i += width) {
            var d: @Vector(width, f32) = undefined;
            var s: @Vector(width, f32) = undefined;
            inline for (0..width) |j| {
                d[j] = dst[i + j];
                s[j] = src[i + j];
            }
            d += s * scale_v;
            inline for (0..width) |j| dst[i + j] = d[j];
        }
        while (i < n) : (i += 1) dst[i] += src[i] * scale;
    }

    /// Fills `slice` with `value`, unrolling with SIMD width when `T` is `f32`.
    pub fn fillUniformSimd(comptime T: type, slice: []T, value: T) void {
        if (slice.len == 0) return;
        if (T != f32) {
            for (slice) |*e| e.* = value;
            return;
        }
        const width = std.simd.suggestVectorLength(f32) orelse 1;
        if (width <= 1) {
            for (slice) |*e| e.* = value;
            return;
        }
        const val_v: @Vector(width, f32) = @splat(value);
        var i: usize = 0;
        while (i + width <= slice.len) : (i += width) {
            inline for (0..width) |j| slice[i + j] = val_v[j];
        }
        while (i < slice.len) : (i += 1) slice[i] = value;
    }
};

/// Typed SIMD helpers for common motion/physics component layouts.
pub const SimdSystems = struct {
    /// Velocity may use `dx`/`dy` or `x`/`y` (benchmark / C layouts use the latter).
    fn velocityAxisName(comptime Velocity: type, comptime axis: enum { x, y }) []const u8 {
        return switch (axis) {
            .x => if (@hasField(Velocity, "dx")) "dx" else "x",
            .y => if (@hasField(Velocity, "dy")) "dy" else "y",
        };
    }

    /// Updates `positions[i].x/y += velocities[i].(dx|x)/(dy|y) * dt` using SIMD batches.
    pub fn integratePosition2D(
        comptime Position: type,
        comptime Velocity: type,
        positions: []Position,
        velocities: []const Velocity,
        dt: f32,
    ) void {
        std.debug.assert(positions.len == velocities.len);
        const vx_name = comptime velocityAxisName(Velocity, .x);
        const vy_name = comptime velocityAxisName(Velocity, .y);
        const width = std.simd.suggestVectorLength(f32) orelse 1;
        const dt_v: @Vector(width, f32) = @splat(dt);
        var i: usize = 0;
        if (width > 1) {
            while (i + width <= positions.len) : (i += width) {
                var px: @Vector(width, f32) = undefined;
                var py: @Vector(width, f32) = undefined;
                var vx: @Vector(width, f32) = undefined;
                var vy: @Vector(width, f32) = undefined;
                inline for (0..width) |j| {
                    px[j] = positions[i + j].x;
                    py[j] = positions[i + j].y;
                    vx[j] = @field(velocities[i + j], vx_name);
                    vy[j] = @field(velocities[i + j], vy_name);
                }
                px += vx * dt_v;
                py += vy * dt_v;
                inline for (0..width) |j| {
                    positions[i + j].x = px[j];
                    positions[i + j].y = py[j];
                }
            }
        }
        while (i < positions.len) : (i += 1) {
            positions[i].x += @field(velocities[i], vx_name) * dt;
            positions[i].y += @field(velocities[i], vy_name) * dt;
        }
    }

    /// Runs `integratePosition2D` on every active archetype table that contains both type ids.
    /// Used by the C API where component layouts are `{x:f32,y:f32}` for both columns.
    pub fn integratePosition2DByTypeId(world: *World, pos_tid: u32, vel_tid: u32, dt: f32) void {
        const Vec2 = extern struct { x: f32, y: f32 };
        for (world.archetypes.active.items) |arch_idx| {
            const arch = &world.archetypes.list.items[arch_idx];
            const pos_col_idx = Archetypes.columnIndex(arch, pos_tid) orelse continue;
            const vel_col_idx = Archetypes.columnIndex(arch, vel_tid) orelse continue;
            const rows = arch.entities.items.len;
            const pos_col = &arch.columns.items[pos_col_idx];
            const vel_col = &arch.columns.items[vel_col_idx];
            if (pos_col.elem_size != @sizeOf(Vec2) or vel_col.elem_size != @sizeOf(Vec2)) continue;
            const positions = ColumnSimd.typedSlice(Vec2, pos_col, rows);
            const velocities = ColumnSimd.typedSlice(Vec2, vel_col, rows);
            integratePosition2D(Vec2, Vec2, positions, velocities, dt);
        }
    }

    /// Runs `integratePosition2D` on every active archetype table that contains both types.
    pub fn integratePosition2DQuery(world: *World, comptime Position: type, comptime Velocity: type, dt: f32) void {
        const pos_tid = world.typeId(Position);
        const vel_tid = world.typeId(Velocity);
        for (world.archetypes.active.items) |arch_idx| {
            const arch = &world.archetypes.list.items[arch_idx];
            const pos_col_idx = Archetypes.columnIndex(arch, pos_tid) orelse continue;
            const vel_col_idx = Archetypes.columnIndex(arch, vel_tid) orelse continue;
            const rows = arch.entities.items.len;
            const positions = ColumnSimd.typedSlice(Position, &arch.columns.items[pos_col_idx], rows);
            const velocities = ColumnSimd.typedSlice(Velocity, &arch.columns.items[vel_col_idx], rows);
            integratePosition2D(Position, Velocity, positions, velocities, dt);
        }
    }
};

//Archetype table: entities grouped by signature with SoA component columns.
pub const Archetypes = struct {
    pub const nil: u32 = std.math.maxInt(u32);
    pub const missing_col: u16 = std.math.maxInt(u16);

    pub const PendingWrite = struct {
        tid: u32 = 0,
        data: ?*const anyopaque = null,
    };

    pub const Archetype = struct {
        signature: TypeSignature,
        entities: std.ArrayListUnmanaged(u64) = .empty, //generation-tagged gids
        columns: std.ArrayListUnmanaged(ArchetypeColumn) = .empty,
        /// Dense type-id → column index; `missing_col` means absent. Built at creation.
        col_idx_by_tid: []u16 = &.{},
        /// Index into `active` when non-empty, else `nil`.
        active_slot: u32 = nil,
    };

    list: std.ArrayListUnmanaged(Archetype) = .empty,
    /// Non-empty archetype indices for query/foreach walks.
    active: std.ArrayListUnmanaged(u32) = .empty,
    /// Bumped when a new archetype table is created (cached queries refresh).
    generation: u32 = 0,
    //Stable empty signature for entities with no archetype table row yet.
    empty_signature: TypeSignature = .{},

    pub fn deinit(self: *Archetypes, alloc: std.mem.Allocator) void {
        self.empty_signature.deinit(alloc);
        for (self.list.items) |*a| {
            a.signature.deinit(alloc);
            a.entities.deinit(alloc);
            for (a.columns.items) |*col| col.deinit(alloc);
            a.columns.deinit(alloc);
            if (a.col_idx_by_tid.len > 0) alloc.free(a.col_idx_by_tid);
        }
        self.list.deinit(alloc);
        self.active.deinit(alloc);
    }

    pub fn count(self: *const Archetypes) usize {
        return self.active.items.len;
    }

    fn findIndex(self: *const Archetypes, sig: *const TypeSignature) ?u32 {
        for (self.list.items, 0..) |*arch, i| {
            if (arch.signature.eql(sig.*)) return @intCast(i);
        }
        return null;
    }

    pub fn columnIndex(arch: *const Archetype, tid: u32) ?usize {
        if (tid < arch.col_idx_by_tid.len) {
            const ci = arch.col_idx_by_tid[tid];
            if (ci != missing_col) return ci;
            return null;
        }
        // Fallback for any archetype built before the side table existed.
        for (arch.signature.ids.items, 0..) |id, i| {
            if (id == tid) return i;
        }
        return null;
    }

    fn markActive(self: *Archetypes, alloc: std.mem.Allocator, arch_idx: u32) void {
        const arch = &self.list.items[arch_idx];
        if (arch.active_slot != nil) return;
        arch.active_slot = @intCast(self.active.items.len);
        self.active.append(alloc, arch_idx) catch unreachable;
    }

    fn markInactive(self: *Archetypes, arch_idx: u32) void {
        const arch = &self.list.items[arch_idx];
        const slot = arch.active_slot;
        if (slot == nil) return;
        const last = self.active.items.len - 1;
        if (slot < last) {
            const moved = self.active.items[last];
            self.active.items[slot] = moved;
            self.list.items[moved].active_slot = slot;
        }
        _ = self.active.swapRemove(slot);
        arch.active_slot = nil;
    }

    fn initArchetype(alloc: std.mem.Allocator, types: *const TypeRegistry, sig: *const TypeSignature) !Archetype {
        var arch: Archetype = .{ .signature = try sig.clone(alloc), .entities = .empty, .columns = .empty };
        errdefer {
            arch.signature.deinit(alloc);
            if (arch.col_idx_by_tid.len > 0) alloc.free(arch.col_idx_by_tid);
            for (arch.columns.items) |*col| col.deinit(alloc);
            arch.columns.deinit(alloc);
        }
        for (sig.ids.items) |tid| {
            try arch.columns.append(alloc, .{
                .type_id = tid,
                .elem_size = types.sizeOf(tid),
                .align_bytes = types.alignOf(tid),
            });
        }
        var max_tid: u32 = 0;
        for (sig.ids.items) |tid| max_tid = @max(max_tid, tid);
        const table_len: usize = @as(usize, max_tid) + 1;
        const table = try alloc.alloc(u16, table_len);
        @memset(table, missing_col);
        for (sig.ids.items, 0..) |tid, i| {
            table[tid] = @intCast(i);
        }
        arch.col_idx_by_tid = table;
        return arch;
    }

    fn indexFor(self: *Archetypes, alloc: std.mem.Allocator, types: *const TypeRegistry, sig: *const TypeSignature) !u32 {
        if (self.findIndex(sig)) |idx| return idx;
        const idx: u32 = @intCast(self.list.items.len);
        try self.list.append(alloc, try initArchetype(alloc, types, sig));
        self.generation +%= 1;
        return idx;
    }

    fn growColumns(arch: *Archetype, alloc: std.mem.Allocator, rows: usize) !void {
        for (arch.columns.items) |*col| try col.ensureCapacity(alloc, rows);
    }

    fn swapColumnRows(arch: *Archetype, alloc: std.mem.Allocator, a: usize, b: usize) !void {
        for (arch.columns.items) |*col| try col.swapRows(alloc, a, b);
    }

    fn writeRowValue(
        arch: *Archetype,
        types: *const TypeRegistry,
        row: usize,
        tid: u32,
        data: ?*const anyopaque,
    ) void {
        if (data == null) return;
        const col_idx = columnIndex(arch, tid) orelse return;
        const col = &arch.columns.items[col_idx];
        if (col.elem_size == 0) return;
        const dst = col.rowPtr(row) orelse return;
        @memcpy(@as([*]u8, @ptrCast(dst))[0..col.elem_size], @as([*]const u8, @ptrCast(data.?))[0..col.elem_size]);
        _ = types;
    }

    pub fn columnPtr(self: *const Archetypes, arch_idx: u32, row: usize, tid: u32) ?*anyopaque {
        const arch = &self.list.items[arch_idx];
        const col_idx = columnIndex(arch, tid) orelse return null;
        return arch.columns.items[col_idx].rowPtr(row);
    }

    pub fn insert(self: *Archetypes, alloc: std.mem.Allocator, types: *const TypeRegistry, entity: *Entity, sig: *const TypeSignature) !void {
        std.debug.assert(sig.ids.items.len > 0);
        const idx = try self.indexFor(alloc, types, sig);
        const arch = &self.list.items[idx];
        const row = arch.entities.items.len;
        const old_cap = if (arch.columns.items.len > 0) arch.columns.items[0].capacity else 0;
        try growColumns(arch, alloc, row + 1);
        try arch.entities.append(alloc, entityGlobalId(entity));
        entity.archetype = idx;
        entity.archetype_row = @intCast(row);
        if (row == 0) self.markActive(alloc, idx);
        if (arch.columns.items.len > 0 and arch.columns.items[0].capacity > old_cap) {
            const world = @as(*World, @ptrCast(@alignCast(entity.world)));
            self.syncArchetypeComponentPointers(world, idx);
        }
    }

    //Appends many entities to one archetype table in a single grow + optional resync.
    pub fn insertBatch(
        self: *Archetypes,
        alloc: std.mem.Allocator,
        types: *const TypeRegistry,
        world: *World,
        sig: *const TypeSignature,
        entities: []const *Entity,
    ) !usize {
        if (entities.len == 0) return 0;
        std.debug.assert(sig.ids.items.len > 0);
        const idx = try self.indexFor(alloc, types, sig);
        const arch = &self.list.items[idx];
        const start_row = arch.entities.items.len;
        const new_total = start_row + entities.len;
        const old_cap = if (arch.columns.items.len > 0) arch.columns.items[0].capacity else 0;
        try growColumns(arch, alloc, new_total);
        for (entities, 0..) |entity, i| {
            try arch.entities.append(alloc, entityGlobalId(entity));
            entity.archetype = idx;
            entity.archetype_row = @intCast(start_row + i);
        }
        if (start_row == 0) self.markActive(alloc, idx);
        if (arch.columns.items.len > 0 and arch.columns.items[0].capacity > old_cap) {
            self.syncArchetypeComponentPointers(world, idx);
        } else {
            for (entities) |entity| world.syncEntityComponentPointers(entity);
        }
        return start_row;
    }

    pub fn fillColumnUniform(
        arch: *Archetype,
        tid: u32,
        start_row: usize,
        n: usize,
        value: *const anyopaque,
        elem_size: usize,
    ) void {
        if (elem_size == 0 or n == 0) return;
        const col_idx = columnIndex(arch, tid) orelse return;
        const col = &arch.columns.items[col_idx];
        var r: usize = start_row;
        while (r < start_row + n) : (r += 1) {
            const dst = col.rowPtr(r) orelse continue;
            @memcpy(@as([*]u8, @ptrCast(dst))[0..elem_size], @as([*]const u8, @ptrCast(value))[0..elem_size]);
        }
    }

    pub fn fillColumnValues(
        arch: *Archetype,
        tid: u32,
        start_row: usize,
        values: []const u8,
        elem_size: usize,
    ) void {
        if (elem_size == 0 or values.len == 0) return;
        const col_idx = columnIndex(arch, tid) orelse return;
        const col = &arch.columns.items[col_idx];
        const n = values.len / elem_size;
        var r: usize = 0;
        while (r < n) : (r += 1) {
            const dst = col.rowPtr(start_row + r) orelse continue;
            @memcpy(@as([*]u8, @ptrCast(dst))[0..elem_size], values[r * elem_size ..][0..elem_size]);
        }
    }

    fn syncArchetypeComponentPointers(self: *const Archetypes, world: *World, arch_idx: u32) void {
        const arch = &self.list.items[arch_idx];
        if (arch.columns.items.len == 0) return;
        for (arch.entities.items) |gid| {
            if (resolveGlobalId(world, gid)) |e| world.syncEntityComponentPointers(e);
        }
    }

    pub fn remove(self: *Archetypes, alloc: std.mem.Allocator, world: *World, entity: *Entity) void {
        if (entity.archetype == nil) return;
        const arch_idx = entity.archetype;
        const arch = &self.list.items[arch_idx];
        const row = entity.archetype_row;
        const last = arch.entities.items.len - 1;
        if (row < last) {
            swapColumnRows(arch, alloc, row, last) catch unreachable;
        }
        _ = arch.entities.swapRemove(row);
        if (row < arch.entities.items.len) {
            if (resolveGlobalId(world, arch.entities.items[row])) |moved| {
                moved.archetype_row = row;
            }
        }
        entity.archetype = nil;
        if (arch.entities.items.len == 0) self.markInactive(arch_idx);
        if (arch.columns.items.len > 0 and arch.entities.items.len > 0) self.syncArchetypeComponentPointers(world, arch_idx);
    }

    pub fn relocate(
        self: *Archetypes,
        alloc: std.mem.Allocator,
        world: *World,
        entity: *Entity,
        new_sig: *const TypeSignature,
        pending: ?PendingWrite,
    ) !void {
        if (new_sig.ids.items.len == 0) {
            if (entity.archetype != nil) {
                self.remove(alloc, world, entity);
            } else {
                entity.archetype = nil;
            }
            world.syncEntityComponentPointers(entity);
            return;
        }

        const old_idx = entity.archetype;
        const old_row = entity.archetype_row;
        const had_old = old_idx != nil;

        if (had_old) {
            const old = &self.list.items[old_idx];
            if (old.signature.eql(new_sig.*)) {
                if (pending) |pw| writeRowValue(old, &world.types, old_row, pw.tid, pw.data);
                world.syncEntityComponentPointers(entity);
                return;
            }
        }

        // Snapshot overlapping column values before removing from the old table.
        var saved: std.ArrayListUnmanaged(struct { tid: u32, bytes: []u8 }) = .empty;
        defer {
            for (saved.items) |entry| alloc.free(entry.bytes);
            saved.deinit(alloc);
        }
        if (had_old) {
            const old = &self.list.items[old_idx];
            for (new_sig.ids.items) |tid| {
                if (!old.signature.contains(tid)) continue;
                const size = world.types.sizeOf(tid);
                if (size == 0) continue;
                const buf = try alloc.alloc(u8, size);
                if (columnPtr(self, old_idx, old_row, tid)) |src| {
                    @memcpy(buf, @as([*]const u8, @ptrCast(src))[0..size]);
                }
                try saved.append(alloc, .{ .tid = tid, .bytes = buf });
            }
            self.remove(alloc, world, entity);
        }

        try self.insert(alloc, &world.types, entity, new_sig);
        const new_arch = &self.list.items[entity.archetype];
        const new_row = entity.archetype_row;

        for (saved.items) |entry| {
            writeRowValue(new_arch, &world.types, new_row, entry.tid, entry.bytes.ptr);
        }
        if (pending) |pw| writeRowValue(new_arch, &world.types, new_row, pw.tid, pw.data);

        world.syncEntityComponentPointers(entity);
    }
};

/// Cached archetype query: stores sorted include/exclude type ids and matching
/// archetype indices with per-archetype column indices in caller include order.
/// Refresh when `world.archetypes.generation` advances (new archetype tables).
pub const CachedQuery = struct {
    world: *World,
    include: []u32 = &.{},
    exclude: []u32 = &.{},
    /// Caller-order type ids (same order as create args / C include array).
    caller_tids: []u32 = &.{},
    matches: std.ArrayListUnmanaged(Match) = .empty,
    cached_generation: u32 = std.math.maxInt(u32),

    pub const Match = struct {
        arch_idx: u32,
        col_idxs: []u16 = &.{},
    };

    pub fn create(
        world: *World,
        include_ids: []const u32,
        exclude_ids: []const u32,
        caller_order: []const u32,
    ) !*CachedQuery {
        const alloc = world.allocator;
        const q = try alloc.create(CachedQuery);
        errdefer alloc.destroy(q);
        q.* = .{ .world = world };

        q.include = try alloc.dupe(u32, include_ids);
        errdefer alloc.free(q.include);
        q.exclude = try alloc.dupe(u32, exclude_ids);
        errdefer alloc.free(q.exclude);
        q.caller_tids = try alloc.dupe(u32, caller_order);
        errdefer alloc.free(q.caller_tids);

        if (q.include.len > 1) std.mem.sort(u32, q.include, {}, std.sort.asc(u32));
        if (q.exclude.len > 1) std.mem.sort(u32, q.exclude, {}, std.sort.asc(u32));

        try q.refresh();
        return q;
    }

    pub fn destroy(self: *CachedQuery) void {
        const alloc = self.world.allocator;
        self.clearMatches(alloc);
        if (self.include.len > 0) alloc.free(self.include);
        if (self.exclude.len > 0) alloc.free(self.exclude);
        if (self.caller_tids.len > 0) alloc.free(self.caller_tids);
        alloc.destroy(self);
    }

    fn clearMatches(self: *CachedQuery, alloc: std.mem.Allocator) void {
        for (self.matches.items) |*m| {
            if (m.col_idxs.len > 0) alloc.free(m.col_idxs);
        }
        self.matches.clearRetainingCapacity();
    }

    pub fn refresh(self: *CachedQuery) !void {
        const alloc = self.world.allocator;
        self.clearMatches(alloc);
        const arches = self.world.archetypes;
        for (arches.list.items, 0..) |*arch, i| {
            if (!arch.signature.matches(self.include, self.exclude)) continue;
            const cols = try alloc.alloc(u16, self.caller_tids.len);
            errdefer alloc.free(cols);
            var missing = false;
            for (self.caller_tids, 0..) |tid, j| {
                if (Archetypes.columnIndex(arch, tid)) |ci| {
                    cols[j] = @intCast(ci);
                } else {
                    missing = true;
                    break;
                }
            }
            if (missing) {
                alloc.free(cols);
                continue;
            }
            try self.matches.append(alloc, .{ .arch_idx = @intCast(i), .col_idxs = cols });
        }
        self.cached_generation = arches.generation;
    }

    pub fn ensureFresh(self: *CachedQuery) void {
        if (self.cached_generation != self.world.archetypes.generation) {
            self.refresh() catch unreachable;
        }
    }

    /// Column-chunk callback: one invocation per matching non-empty archetype.
    pub fn runColumns(
        self: *CachedQuery,
        cb: *const fn (columns: [*c]?*anyopaque, row_count: usize, n_types: usize, user_data: ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) void {
        self.ensureFresh();
        const n_types = self.caller_tids.len;
        for (self.matches.items) |m| {
            const arch = &self.world.archetypes.list.items[m.arch_idx];
            const rows = arch.entities.items.len;
            if (rows == 0) continue;

            var columns: [16]?*anyopaque = @splat(null);
            var missing = false;
            var i: usize = 0;
            while (i < n_types) : (i += 1) {
                const col = &arch.columns.items[m.col_idxs[i]];
                if (col.elem_size == 0) {
                    columns[i] = @ptrFromInt(1);
                } else if (col.capacity == 0) {
                    missing = true;
                    break;
                } else {
                    columns[i] = col.data.ptr;
                }
            }
            if (missing) continue;
            cb(&columns, rows, n_types, user_data);
        }
    }

    /// SIMD Position+Velocity integrate using cached column indices.
    pub fn integratePosition2D(self: *CachedQuery, dt: f32) void {
        if (self.caller_tids.len < 2) return;
        self.ensureFresh();
        const Vec2 = extern struct { x: f32, y: f32 };
        for (self.matches.items) |m| {
            const arch = &self.world.archetypes.list.items[m.arch_idx];
            const rows = arch.entities.items.len;
            if (rows == 0) continue;
            const pos_col = &arch.columns.items[m.col_idxs[0]];
            const vel_col = &arch.columns.items[m.col_idxs[1]];
            if (pos_col.elem_size != @sizeOf(Vec2) or vel_col.elem_size != @sizeOf(Vec2)) continue;
            const positions = ColumnSimd.typedSlice(Vec2, pos_col, rows);
            const velocities = ColumnSimd.typedSlice(Vec2, vel_col, rows);
            SimdSystems.integratePosition2D(Vec2, Vec2, positions, velocities, dt);
        }
    }
};

pub const EventKind = enum(u8) {
    entity_spawned,
    entity_destroyed,
    component_added,
    component_removed,
    component_changed,
};

//A recorded structural lifecycle change. Queued by the world when entities and
//components are created/destroyed/updated so systems can react later (e.g. in
//an events stage after the scheduler flushes a command buffer).
pub const StructuralEvent = struct {
    kind: EventKind,
    entity: EntityRef,
    component: ?*Component = null,
    type_id: u32 = 0,
};

//World event queue: structural lifecycle events plus typed custom payloads.
pub const Events = struct {
    const CustomEntry = struct {
        type_id: u32,
        data: *anyopaque,
    };

    queue: std.ArrayListUnmanaged(StructuralEvent) = .empty,
    custom: std.ArrayListUnmanaged(CustomEntry) = .empty,
    arena: std.heap.ArenaAllocator,
    arena_inited: bool = false,

    pub fn init(alloc: std.mem.Allocator) Events {
        return .{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .arena_inited = true,
        };
    }

    pub fn deinit(self: *Events, alloc: std.mem.Allocator) void {
        self.queue.deinit(alloc);
        self.custom.deinit(alloc);
        if (self.arena_inited) self.arena.deinit();
    }

    pub inline fn count(self: *const Events) usize {
        return self.queue.items.len + self.custom.items.len;
    }

    pub fn push(self: *Events, alloc: std.mem.Allocator, event: StructuralEvent) !void {
        try self.queue.append(alloc, event);
    }

    //Records a typed custom event. Payload is copied into the events arena.
    pub fn emit(self: *Events, world: *World, comptime T: type, value: T) !void {
        const box = try self.arena.allocator().create(T);
        box.* = value;
        try self.custom.append(world.allocator, .{ .type_id = world.typeId(T), .data = box });
    }

    pub fn cEmit(self: *Events, world: *World, ct: c_type, data: *const anyopaque) !void {
        const id = world.typeIdC(ct);
        const size = world.types.sizeOf(id);
        const align_val = world.types.alignOf(id);
        const mem = self.arena.allocator().rawAlloc(size, .fromByteUnits(align_val), @returnAddress()) orelse return error.OutOfMemory;
        @memcpy(mem[0..size], @as([*]const u8, @ptrCast(data))[0..size]);
        try self.custom.append(world.allocator, .{ .type_id = id, .data = mem });
    }

    //Invokes `handler` for every queued structural event, then clears the
    //structural queue. Custom events are left intact until `clearCustom` or
    //`clearAll`.
    pub fn drainStructural(self: *Events, handler: *const fn (StructuralEvent) void) void {
        for (self.queue.items) |event| handler(event);
        self.queue.clearRetainingCapacity();
    }

    //Invokes `handler` for every custom event of type `T`, then removes them.
    pub fn drainCustom(self: *Events, world: *World, comptime T: type, handler: *const fn (T) void) void {
        const id = world.typeId(T);
        var i: usize = 0;
        while (i < self.custom.items.len) {
            if (self.custom.items[i].type_id == id) {
                handler(@as(*T, @ptrCast(@alignCast(self.custom.items[i].data))).*);
                _ = self.custom.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clearCustom(self: *Events) void {
        self.custom.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn clearAll(self: *Events) void {
        self.queue.clearRetainingCapacity();
        self.clearCustom();
    }
};

//`type_id` value that matches every component type when registering observers.
pub const observe_all: u32 = std.math.maxInt(u32);

//Synchronous lifecycle callbacks. Unlike the event queue, observers run
//immediately when a change is committed (including during command-buffer flush).
pub const Observers = struct {
    pub const EntityFn = *const fn (*World, *Entity) void;
    pub const ComponentFn = *const fn (*World, *Entity, *Component, u32) void;
    pub const CEntityFn = *const fn (usize, u64, ?*anyopaque) callconv(.c) void;
    pub const CComponentFn = *const fn (usize, u64, usize, u32, ?*anyopaque) callconv(.c) void;

    const EntityObserver = union(enum) {
        zig: EntityFn,
        c: struct { cb: CEntityFn, user_data: ?*anyopaque },
    };

    const ComponentObserver = struct {
        type_id: u32,
        observer: union(enum) {
            zig: ComponentFn,
            c: struct { cb: CComponentFn, user_data: ?*anyopaque },
        },
    };

    entity_spawn: std.ArrayListUnmanaged(EntityObserver) = .empty,
    entity_destroy: std.ArrayListUnmanaged(EntityObserver) = .empty,
    component_add: std.ArrayListUnmanaged(ComponentObserver) = .empty,
    component_remove: std.ArrayListUnmanaged(ComponentObserver) = .empty,
    component_change: std.ArrayListUnmanaged(ComponentObserver) = .empty,

    pub fn deinit(self: *Observers, alloc: std.mem.Allocator) void {
        self.entity_spawn.deinit(alloc);
        self.entity_destroy.deinit(alloc);
        self.component_add.deinit(alloc);
        self.component_remove.deinit(alloc);
        self.component_change.deinit(alloc);
    }

    pub fn onEntitySpawn(self: *Observers, alloc: std.mem.Allocator, cb: EntityFn) !void {
        try self.entity_spawn.append(alloc, .{ .zig = cb });
    }

    pub fn onEntityDestroy(self: *Observers, alloc: std.mem.Allocator, cb: EntityFn) !void {
        try self.entity_destroy.append(alloc, .{ .zig = cb });
    }

    pub fn onComponentAdd(self: *Observers, world: *World, comptime T: type, cb: ComponentFn) !void {
        try self.onComponentAddId(world.allocator, world.typeId(T), cb);
    }

    pub fn onComponentRemove(self: *Observers, world: *World, comptime T: type, cb: ComponentFn) !void {
        try self.onComponentRemoveId(world.allocator, world.typeId(T), cb);
    }

    pub fn onComponentChange(self: *Observers, world: *World, comptime T: type, cb: ComponentFn) !void {
        try self.onComponentChangeId(world.allocator, world.typeId(T), cb);
    }

    pub fn onComponentAddId(self: *Observers, alloc: std.mem.Allocator, type_id: u32, cb: ComponentFn) !void {
        try self.component_add.append(alloc, .{ .type_id = type_id, .observer = .{ .zig = cb } });
    }

    pub fn onComponentRemoveId(self: *Observers, alloc: std.mem.Allocator, type_id: u32, cb: ComponentFn) !void {
        try self.component_remove.append(alloc, .{ .type_id = type_id, .observer = .{ .zig = cb } });
    }

    pub fn onComponentChangeId(self: *Observers, alloc: std.mem.Allocator, type_id: u32, cb: ComponentFn) !void {
        try self.component_change.append(alloc, .{ .type_id = type_id, .observer = .{ .zig = cb } });
    }

    pub fn cOnEntitySpawn(self: *Observers, alloc: std.mem.Allocator, cb: CEntityFn, user_data: ?*anyopaque) !void {
        try self.entity_spawn.append(alloc, .{ .c = .{ .cb = cb, .user_data = user_data } });
    }

    pub fn cOnEntityDestroy(self: *Observers, alloc: std.mem.Allocator, cb: CEntityFn, user_data: ?*anyopaque) !void {
        try self.entity_destroy.append(alloc, .{ .c = .{ .cb = cb, .user_data = user_data } });
    }

    pub fn cOnComponentAdd(self: *Observers, alloc: std.mem.Allocator, type_id: u32, cb: CComponentFn, user_data: ?*anyopaque) !void {
        try self.component_add.append(alloc, .{ .type_id = type_id, .observer = .{ .c = .{ .cb = cb, .user_data = user_data } } });
    }

    pub fn cOnComponentRemove(self: *Observers, alloc: std.mem.Allocator, type_id: u32, cb: CComponentFn, user_data: ?*anyopaque) !void {
        try self.component_remove.append(alloc, .{ .type_id = type_id, .observer = .{ .c = .{ .cb = cb, .user_data = user_data } } });
    }

    pub fn cOnComponentChange(self: *Observers, alloc: std.mem.Allocator, type_id: u32, cb: CComponentFn, user_data: ?*anyopaque) !void {
        try self.component_change.append(alloc, .{ .type_id = type_id, .observer = .{ .c = .{ .cb = cb, .user_data = user_data } } });
    }

    fn dispatchEntitySpawn(self: *Observers, world: *World, entity: *Entity) void {
        const handle = entity.ref().toGlobalId();
        for (self.entity_spawn.items) |obs| switch (obs) {
            .zig => |f| f(world, entity),
            .c => |c| c.cb(@intFromPtr(world), handle, c.user_data),
        };
    }

    fn dispatchEntityDestroy(self: *Observers, world: *World, entity: *Entity) void {
        const handle = entity.ref().toGlobalId();
        for (self.entity_destroy.items) |obs| switch (obs) {
            .zig => |f| f(world, entity),
            .c => |c| c.cb(@intFromPtr(world), handle, c.user_data),
        };
    }

    fn dispatchComponent(
        list: []const ComponentObserver,
        world: *World,
        entity: *Entity,
        component: *Component,
        type_id: u32,
    ) void {
        const handle = entity.ref().toGlobalId();
        for (list) |obs| {
            if (obs.type_id != observe_all and obs.type_id != type_id) continue;
            switch (obs.observer) {
                .zig => |f| f(world, entity, component, type_id),
                .c => |c| c.cb(@intFromPtr(world), handle, @intFromPtr(component), type_id, c.user_data),
            }
        }
    }

    fn notifyEntitySpawn(self: *Observers, world: *World, entity: *Entity) void {
        self.dispatchEntitySpawn(world, entity);
    }

    fn notifyEntityDestroy(self: *Observers, world: *World, entity: *Entity) void {
        self.dispatchEntityDestroy(world, entity);
    }

    fn notifyComponentAdd(self: *Observers, world: *World, entity: *Entity, component: *Component, type_id: u32) void {
        dispatchComponent(self.component_add.items, world, entity, component, type_id);
    }

    fn notifyComponentRemove(self: *Observers, world: *World, entity: *Entity, component: *Component, type_id: u32) void {
        dispatchComponent(self.component_remove.items, world, entity, component, type_id);
    }

    fn notifyComponentChange(self: *Observers, world: *World, entity: *Entity, component: *Component, type_id: u32) void {
        dispatchComponent(self.component_change.items, world, entity, component, type_id);
    }
};

pub const World = struct {
    //Superset of Entities and Systems
    entities: SuperEntities,
    components: SuperComponents,
    resources: Resources = .{},
    events: Events,
    observers: Observers = .{},
    archetypes: Archetypes = .{},
    types: TypeRegistry = .{},
    _entities: []Entities,
    _components: []_Components,
    entities_len: usize = 0,
    components_len: usize = 0,
    components_free_idx: usize = 0,
    entities_free_idx: usize = 0,

    systems: Systems,
    allocator: std.mem.Allocator,

    pub fn create() !*World {
        var world = allocator.create(World) catch unreachable;

        //These module-level cursors track the active chunk during create/expand.
        //Reset them here so a new world starts at chunk 0 instead of inheriting
        //a stale index from a previously-created (e.g. multi-chunk) world.
        entities_idx = 0;
        components_idx = 0;

        world.allocator = allocator;
        world.entities.world = world;
        world.components.world = world;
        world.resources = .{};
        world.events = Events.init(allocator);
        world.observers = .{};
        world.archetypes = .{};
        world.types = .{};

        world.entities_len = 1;
        world.components_len = 1;
        world.entities_free_idx = 0;
        world.components_free_idx = 0;
        world.components.alive = 0;
        world.entities.alive = 0;

        world._entities = try allocator.alloc(Entities, 1);
        world._entities[entities_idx].world = world;
        world._entities[entities_idx].len = 0;
        world._entities[entities_idx].alive = 0;
        world._entities[entities_idx].free_idx = 0;
        world._entities[entities_idx].sparse = try allocator.alloc(Entity, CHUNK_SIZE);
        for (world._entities[entities_idx].sparse) |*e| {
            e.alive = false;
            e.generation = 0;
            e.owned = .{};
            e.archetype = Archetypes.nil;
            e.archetype_row = 0;
        }

        world.systems = Systems{};

        world._components = try allocator.alloc(_Components, 1);
        world._components[components_idx].world = world;
        world._components[components_idx].len = 0;
        world._components[components_idx].alive = 0;
        world._components[components_idx].free_idx = 0;
        world._components[components_idx].chunk = 0;
        world._components[components_idx].sparse = try allocator.alloc(Component, CHUNK_SIZE);

        return world;
    }

    pub inline fn typeId(self: *World, comptime T: type) u32 {
        return self.types.registerZig(self.allocator, T) catch unreachable;
    }

    pub inline fn typeIdC(self: *World, ct: c_type) u32 {
        return self.types.registerC(self.allocator, ct) catch unreachable;
    }

    //Returns a fresh command buffer bound to this world. Caller owns it and
    //must call `deinit()` when done (after a final `flush`/`reset`).
    pub fn commandBuffer(self: *World) CommandBuffer {
        return CommandBuffer.init(self);
    }

    //Returns a fresh staged system scheduler bound to this world. Caller owns it
    //and must call `deinit()` when done.
    pub fn scheduler(self: *World) Scheduler {
        return Scheduler.init(self);
    }

    pub fn insertResource(self: *World, comptime T: type, value: T) !void {
        try self.resources.insert(self, T, value);
    }

    pub inline fn getResource(self: *World, comptime T: type) ?*T {
        return self.resources.get(self, T);
    }

    pub fn removeResource(self: *World, comptime T: type) void {
        self.resources.remove(self, T);
    }

    pub fn emitEvent(self: *World, comptime T: type, value: T) !void {
        try self.events.emit(self, T, value);
    }

    pub fn onComponentAdd(self: *World, comptime T: type, cb: Observers.ComponentFn) !void {
        try self.observers.onComponentAdd(self, T, cb);
    }

    pub fn onComponentRemove(self: *World, comptime T: type, cb: Observers.ComponentFn) !void {
        try self.observers.onComponentRemove(self, T, cb);
    }

    pub fn onComponentChange(self: *World, comptime T: type, cb: Observers.ComponentFn) !void {
        try self.observers.onComponentChange(self, T, cb);
    }

    pub fn onEntitySpawn(self: *World, cb: Observers.EntityFn) !void {
        try self.observers.onEntitySpawn(self.allocator, cb);
    }

    pub fn onEntityDestroy(self: *World, cb: Observers.EntityFn) !void {
        try self.observers.onEntityDestroy(self.allocator, cb);
    }

    //Rebuilds the entity's archetype from its owned components and relocates it
    //in the SoA table if the signature changed.
    fn archetypeRefresh(self: *World, entity: *Entity, pending: Archetypes.PendingWrite) !void {
        var sig = try TypeSignature.fromEntity(self.allocator, entity);
        defer sig.deinit(self.allocator);
        try self.archetypes.relocate(self.allocator, self, entity, &sig, pending);
    }

    //Points sole-owner, primary components at their archetype column cells.
    fn syncEntityComponentPointers(self: *World, entity: *Entity) void {
        var k: u32 = 0;
        while (k < entity.owned.len) : (k += 1) {
            const component = entity.owned.at(k);
            if (!component.alive or !component.attached) continue;
            const tid = component.typeId orelse continue;
            if (component.owners.len != 1) continue;
            if (!entity.isPrimaryComponent(component, tid)) continue;
            if (entity.archetype == Archetypes.nil) continue;
            if (self.archetypes.columnPtr(entity.archetype, entity.archetype_row, tid)) |ptr| {
                component.data = ptr;
                component.column_backed = true;
                component.allocated = true;
            }
        }
    }

    pub fn archetypeColumnPtr(self: *const World, entity: *const Entity, tid: u32) ?*anyopaque {
        if (entity.archetype == Archetypes.nil) return null;
        return self.archetypes.columnPtr(entity.archetype, entity.archetype_row, tid);
    }

    //Links a component shell to an entity after a batch archetype insert.
    pub fn wireBatchAttach(self: *World, entity: *Entity, component: *Component, tid: u32) !void {
        try component.owners.add(self.allocator, entityGlobalId(entity));
        try entity.owned.add(self.allocator, component);
        component.attached = true;
        component.column_backed = false;
        component.allocated = false;
        component.data = null;
        self.syncEntityComponentPointers(entity);
        _ = tid;
    }

    pub fn signatureFromComponents(self: *World, alloc: std.mem.Allocator, comptime components: anytype) !TypeSignature {
        var sig: TypeSignature = .{};
        inline for (components) |Comp| {
            try sig.add(alloc, self.typeId(Comp));
        }
        return sig;
    }

    pub fn signatureFromInit(self: *World, alloc: std.mem.Allocator, init: anytype) !TypeSignature {
        var sig: TypeSignature = .{};
        const info = @typeInfo(@TypeOf(init)).@"struct";
        inline for (info.field_types) |FieldType| {
            try sig.add(alloc, self.typeId(FieldType));
        }
        return sig;
    }

    //Queues a structural event and invokes matching observers. Called from
    //entity/component lifecycle code whenever a change is committed.
    fn signalEntitySpawned(self: *World, entity: *Entity) void {
        const er = entity.ref();
        self.events.push(self.allocator, .{ .kind = .entity_spawned, .entity = er }) catch {};
        self.observers.notifyEntitySpawn(self, entity);
    }

    fn signalEntityDestroyed(self: *World, entity: *Entity) void {
        const er = entity.ref();
        self.events.push(self.allocator, .{ .kind = .entity_destroyed, .entity = er }) catch {};
        self.observers.notifyEntityDestroy(self, entity);
    }

    fn signalComponentAdded(self: *World, entity: *Entity, component: *Component, type_id: u32) void {
        const er = entity.ref();
        self.events.push(self.allocator, .{
            .kind = .component_added,
            .entity = er,
            .component = component,
            .type_id = type_id,
        }) catch {};
        self.observers.notifyComponentAdd(self, entity, component, type_id);
    }

    fn signalComponentRemoved(self: *World, entity: *Entity, component: *Component, type_id: u32) void {
        const er = entity.ref();
        self.events.push(self.allocator, .{
            .kind = .component_removed,
            .entity = er,
            .component = component,
            .type_id = type_id,
        }) catch {};
        self.observers.notifyComponentRemove(self, entity, component, type_id);
    }

    fn signalComponentChanged(self: *World, entity: *Entity, component: *Component, type_id: u32) void {
        const er = entity.ref();
        self.events.push(self.allocator, .{
            .kind = .component_changed,
            .entity = er,
            .component = component,
            .type_id = type_id,
        }) catch {};
        self.observers.notifyComponentChange(self, entity, component, type_id);
    }

    pub fn destroy(self: *World) void {
        var it = self.components.iterator();
        while (it.next()) |component|
            component.destroy();

        self.components.gc();
        self.resources.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.observers.deinit(self.allocator);
        self.archetypes.deinit(self.allocator);
        self.types.deinit(self.allocator);
        var i: usize = 0;
        while (i < self.components_len) : (i += 1)
            self.allocator.free(self._components[i].sparse);

        self.allocator.free(self._components);

        //Free any remaining per-entity reverse-index spill lists. Destroying
        //components above already removed entries for live entities; this
        //reclaims lists for entities the caller never explicitly destroyed.
        i = 0;
        while (i < self.entities_len) : (i += 1) {
            for (self._entities[i].sparse) |*e| e.owned.clear(self.allocator);
        }

        i = 0;
        while (i < self.entities_len) : (i += 1)
            self.allocator.free(self._entities[i].sparse);

        self.allocator.free(self._entities);
        self.allocator.destroy(self);
    }
};

//Globally unique entity identity = chunk * CHUNK_SIZE + per-chunk id.
//Used as the key for component ownership so it is unambiguous across the
//multiple entity chunks a world may grow into.
//
//Layout: the low 32 bits hold the slot location (chunk * CHUNK_SIZE + id) and
//the high 32 bits hold the entity generation. Folding the generation into the
//ownership key makes OwnerSet/queries reject stale owners for free: once an
//entity is destroyed its generation is bumped, so a recycled slot produces a
//different key and old ownership entries no longer match.
pub inline fn entityGlobalId(entity: *const Entity) u64 {
    const location: u64 = @as(u64, @intCast(entity.chunk)) * CHUNK_SIZE + @as(u64, entity.id);
    return (@as(u64, entity.generation) << 32) | location;
}

inline fn gidLocation(gid: u64) u64 {
    return gid & 0xFFFF_FFFF;
}

inline fn gidGeneration(gid: u64) u32 {
    return @intCast(gid >> 32);
}

//Resolves a generation-tagged global id back to a live entity, or null if the
//slot is empty or has since been recycled (generation mismatch). This is the
//single decode point shared by handles, the C API, and the entity filter.
pub inline fn resolveGlobalId(world: *World, gid: u64) ?*Entity {
    const loc = gidLocation(gid);
    const e_chunk: usize = @intCast(loc / CHUNK_SIZE);
    const e_id: usize = @intCast(loc % CHUNK_SIZE);
    if (e_chunk >= world.entities_len or e_id >= CHUNK_SIZE) return null;
    const entity = &world._entities[e_chunk].sparse[e_id];
    if (entity.alive and entity.generation == gidGeneration(gid)) return entity;
    return null;
}

//A stable, copyable handle to an entity. Unlike a `*Entity`, it survives slot
//recycling: resolving a handle whose generation no longer matches the live
//occupant returns null instead of silently aliasing a different entity.
//`extern` so it can cross the C ABI directly if needed.
pub const EntityRef = extern struct {
    chunk: u32,
    id: u32,
    generation: u32,

    pub inline fn toGlobalId(self: EntityRef) u64 {
        const location: u64 = @as(u64, self.chunk) * CHUNK_SIZE + @as(u64, self.id);
        return (@as(u64, self.generation) << 32) | location;
    }
};

//Rebuilds an EntityRef from the packed u64 handle the C API hands out.
pub inline fn entityRefFromGlobalId(gid: u64) EntityRef {
    const loc = gidLocation(gid);
    return .{
        .chunk = @intCast(loc / CHUNK_SIZE),
        .id = @intCast(loc % CHUNK_SIZE),
        .generation = gidGeneration(gid),
    };
}

//Tracks which entities own a component, keyed by global entity id.
//Optimized for the common single-owner case: the first owner is stored inline
//and no allocation happens until a component is shared by a second entity.
pub const OwnerSet = struct {
    const none: u64 = std.math.maxInt(u64);

    len: u32 = 0,
    first: u64 = none,
    rest: std.ArrayListUnmanaged(u64) = .empty,

    pub inline fn count(self: *const OwnerSet) u32 {
        return self.len;
    }

    pub fn contains(self: *const OwnerSet, gid: u64) bool {
        if (self.len == 0) return false;
        if (self.first == gid) return true;
        for (self.rest.items) |o| {
            if (o == gid) return true;
        }
        return false;
    }

    pub fn add(self: *OwnerSet, alloc: std.mem.Allocator, gid: u64) !void {
        if (self.contains(gid)) return;
        if (self.len == 0) {
            self.first = gid;
        } else {
            try self.rest.append(alloc, gid);
        }
        self.len += 1;
    }

    pub fn remove(self: *OwnerSet, gid: u64) void {
        if (self.len == 0) return;
        if (self.first == gid) {
            self.first = self.rest.pop() orelse none;
            self.len -= 1;
            return;
        }
        for (self.rest.items, 0..) |o, i| {
            if (o == gid) {
                _ = self.rest.swapRemove(i);
                self.len -= 1;
                return;
            }
        }
    }

    pub fn clear(self: *OwnerSet, alloc: std.mem.Allocator) void {
        self.rest.clearAndFree(alloc);
        self.first = none;
        self.len = 0;
    }
};

//Reverse index of the components an entity owns. Mirrors OwnerSet on the
//component side so destroy()/detach() are O(owned) instead of scanning every
//component slot in the world. Optimized for the common handful-of-components
//case: the first owned component is stored inline with no allocation, and the
//`rest` list is only allocated once a second component is added.
//Component pointers are stable (per-chunk sparse arrays are never reallocated).
pub const OwnedComponents = struct {
    len: u32 = 0,
    first: ?*Component = null,
    rest: std.ArrayListUnmanaged(*Component) = .empty,

    pub inline fn count(self: *const OwnedComponents) u32 {
        return self.len;
    }

    pub fn contains(self: *const OwnedComponents, c: *Component) bool {
        if (self.len == 0) return false;
        if (self.first == c) return true;
        for (self.rest.items) |o| {
            if (o == c) return true;
        }
        return false;
    }

    pub fn add(self: *OwnedComponents, alloc: std.mem.Allocator, c: *Component) !void {
        if (self.contains(c)) return;
        if (self.len == 0) {
            self.first = c;
        } else {
            try self.rest.append(alloc, c);
        }
        self.len += 1;
    }

    pub fn remove(self: *OwnedComponents, c: *Component) void {
        if (self.len == 0) return;
        if (self.first == c) {
            self.first = self.rest.pop() orelse null;
            self.len -= 1;
            return;
        }
        for (self.rest.items, 0..) |o, i| {
            if (o == c) {
                _ = self.rest.swapRemove(i);
                self.len -= 1;
                return;
            }
        }
    }

    //Returns the owned component at iteration position `k` (0-based).
    pub inline fn at(self: *const OwnedComponents, k: u32) *Component {
        return if (k == 0) self.first.? else self.rest.items[k - 1];
    }

    pub fn clear(self: *OwnedComponents, alloc: std.mem.Allocator) void {
        self.rest.clearAndFree(alloc);
        self.first = null;
        self.len = 0;
    }
};

pub const Component = struct {
    chunk: usize,
    id: u32,
    data: ?*anyopaque,
    world: ?*anyopaque,
    owners: OwnerSet = .{},
    attached: bool,
    typeId: ?u32 = undefined,
    allocated: bool = false,
    column_backed: bool = false,
    alive: bool = false,
    type_node: std.DoublyLinkedList.Node,
    magic: usize = MAGIC,

    pub inline fn is(self: *const Component, comp_type: anytype) bool {
        const world = @as(*World, @ptrCast(@alignCast(self.world)));
        const T = if (@TypeOf(comp_type) == type) comp_type else @TypeOf(comp_type);
        if (self.typeId == world.typeId(T)) {
            return true;
        } else {
            return false;
        }
    }

    //Returns a typed pointer to this component's data, or null if it has none.
    pub inline fn get(self: *const Component, comptime comp_type: type) ?*comp_type {
        if (self.data) |data| return CastData(comp_type, data);
        return null;
    }

    pub inline fn set(component: *Component, comptime comp_type: type, members: anytype) !void {
        const field_ptr = @as(*comp_type, @ptrCast(@alignCast(component.data)));
        inline for (@typeInfo(@TypeOf(members)).@"struct".field_names) |name| {
            @field(field_ptr, name) = @field(members, name);
        }
        const world = @as(*World, @ptrCast(@alignCast(component.world)));
        const tid = world.typeId(comp_type);
        if (component.owners.len > 0) {
            if (resolveGlobalId(world, component.owners.first)) |entity| {
                world.signalComponentChanged(entity, component, tid);
            }
        }
    }

    //Removes this component from every owning entity's reverse index and then
    //clears the owner set, keeping the entity->component and component->entity
    //views consistent whenever a component is detached or destroyed. Each
    //affected entity's archetype signature is narrowed if this was its last
    //component of the type. (OOM during the archetype move is fatal: the index
    //must stay exact, and the c_allocator failing is unrecoverable anyway.)
    fn releaseOwners(self: *Component, world: *World) void {
        if (self.owners.len > 0) {
            if (resolveGlobalId(world, self.owners.first)) |e| {
                e.owned.remove(self);
                world.archetypeRefresh(e, .{}) catch unreachable;
            }
            for (self.owners.rest.items) |gid| {
                if (resolveGlobalId(world, gid)) |e| {
                    e.owned.remove(self);
                    world.archetypeRefresh(e, .{}) catch unreachable;
                }
            }
        }
        self.owners.clear(world.allocator);
    }

    //Detaches from all entities
    pub inline fn detach(self: *Component) void {
        const world = @as(*World, @ptrCast(@alignCast(self.world)));

        self.attached = false;
        if (self.column_backed and self.owners.len > 0) {
            if (resolveGlobalId(world, self.owners.first)) |e| {
                self.promoteToHeap(world, e) catch {};
            }
        }
        self.releaseOwners(world);
    }

    pub inline fn dealloc(self: *Component) void {
        if (!self.alive and self.magic == MAGIC and self.allocated and !self.column_backed) {
            if (self.data) |data| {
                const w = @as(*World, @ptrCast(@alignCast(self.world)));
                const tid = self.typeId.?;
                opaqueDestroy(w.allocator, data, w.types.sizeOf(tid), w.types.alignOf(tid));
            }
            self.allocated = false;
        }
    }

    //Moves column-backed data onto the heap so multiple owners can share one blob.
    fn promoteToHeap(self: *Component, world: *World, entity: *Entity) !void {
        if (!self.column_backed) return;
        const tid = self.typeId orelse return;
        const size = world.types.sizeOf(tid);
        const align_val = world.types.alignOf(tid);
        if (size == 0) {
            self.column_backed = false;
            return;
        }
        const heap = try allocBytes(world.allocator, size, align_val);
        if (self.column_backed) {
            if (world.archetypeColumnPtr(entity, tid)) |src| {
                @memcpy(heap, @as([*]const u8, @ptrCast(src))[0..size]);
            } else if (self.data) |src| {
                @memcpy(heap, @as([*]const u8, @ptrCast(src))[0..size]);
            }
        } else if (self.data) |src| {
            @memcpy(heap, @as([*]const u8, @ptrCast(src))[0..size]);
        }
        self.data = heap.ptr;
        self.column_backed = false;
        self.allocated = true;
    }

    fn writeHeapValue(self: *Component, world: *World, tid: u32, data: ?*const anyopaque, size: usize) !void {
        if (size == 0) return;
        if (!self.allocated or self.column_backed) {
            if (self.allocated and !self.column_backed) {
                if (self.data) |old| {
                    opaqueDestroy(world.allocator, old, world.types.sizeOf(tid), world.types.alignOf(tid));
                }
            }
            const heap = try allocBytes(world.allocator, size, world.types.alignOf(tid));
            self.data = heap.ptr;
            self.column_backed = false;
            self.allocated = true;
        }
        if (self.data) |dst| {
            if (data) |src| {
                @memcpy(@as([*]u8, @ptrCast(dst))[0..size], @as([*]const u8, @ptrCast(src))[0..size]);
            }
        }
    }

    pub inline fn destroy(self: *Component) void {
        const world = @as(*World, @ptrCast(@alignCast(self.world)));

        //TODO: Destroy data? If allocated just hold to reuse.
        if (self.alive and self.magic == MAGIC) {
            self.attached = false;
            self.releaseOwners(world);
            self.alive = false;

            if (world._components[self.chunk].alive > 0)
                world._components[self.chunk].alive -= 1;

            world._components[self.chunk].free_idx = self.id;
            world.components_free_idx = self.chunk;

            if (world.components.alive > 0)
                world.components.alive -= 1;
        }
    }
};

pub const Entity = struct {
    chunk: usize,
    id: u32,
    generation: u32 = 0,
    alive: bool,
    world: ?*anyopaque,
    allocated: bool = false,
    owned: OwnedComponents = .{}, //reverse index of components this entity owns
    archetype: u32 = Archetypes.nil, //index into world.archetypes.list
    archetype_row: u32 = 0, //position within that archetype's entity list

    //Returns a stable handle that can be stored and later validated with
    //`world.entities.resolve`/`isValid`, even after this slot is recycled.
    pub inline fn ref(self: *const Entity) EntityRef {
        return .{ .chunk = @intCast(self.chunk), .id = self.id, .generation = self.generation };
    }

    //Returns this entity's archetype signature (sorted owned type ids).
    pub inline fn signature(self: *const Entity) *const TypeSignature {
        const world = @as(*World, @ptrCast(@alignCast(self.world)));
        if (self.archetype == Archetypes.nil) return &world.archetypes.empty_signature;
        return &world.archetypes.list.items[self.archetype].signature;
    }

    //True if `component` is the first live owned component of `tid` on this entity.
    pub inline fn isPrimaryComponent(self: *const Entity, component: *const Component, tid: u32) bool {
        var k: u32 = 0;
        while (k < self.owned.len) : (k += 1) {
            const c = self.owned.at(k);
            if (!c.alive) continue;
            if (c.typeId) |t| {
                if (t == tid) return c == component;
            }
        }
        return false;
    }

    pub inline fn countOwnedOfType(self: *const Entity, tid: u32) u32 {
        var n: u32 = 0;
        var k: u32 = 0;
        while (k < self.owned.len) : (k += 1) {
            const c = self.owned.at(k);
            if (!c.alive) continue;
            if (c.typeId) |t| {
                if (t == tid) n += 1;
            }
        }
        return n;
    }

    pub inline fn addComponent(ctx: *Entity, comp_val: anytype) !*Component {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const component = try world.components.create(@TypeOf(comp_val));
        try ctx.attach(component, comp_val);
        return component;
    }

    pub inline fn getOneComponent(ctx: *Entity, comptime comp_type: type) ?*const Component {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return ctx.getOneComponentById(world.typeId(comp_type));
    }

    //Runtime (type-id) variant of getOneComponent, used by the C API.
    //
    //Walks this entity's reverse index (`owned`), so lookup is O(owned
    //components) instead of scanning every component slot in the world. The
    //index is exact: attach adds, detach/destroy remove, and Entity.destroy
    //clears it before the slot can be recycled.
    pub inline fn getOneComponentById(ctx: *Entity, filter_type: u32) ?*Component {
        var k: u32 = 0;
        while (k < ctx.owned.len) : (k += 1) {
            const component = ctx.owned.at(k);
            if (!component.alive) continue;
            const tid = component.typeId orelse continue;
            if (tid == filter_type) return component;
        }
        return null;
    }

    //True if this entity owns at least one live component of type id `tid`.
    pub inline fn ownsType(self: *const Entity, tid: u32) bool {
        var k: u32 = 0;
        while (k < self.owned.len) : (k += 1) {
            const component = self.owned.at(k);
            if (!component.alive) continue;
            if (component.typeId) |t| if (t == tid) return true;
        }
        return false;
    }

    //Returns true if this entity owns at least one component of the given type.
    pub inline fn has(ctx: *Entity, comptime comp_type: type) bool {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return ctx.hasById(world.typeId(comp_type));
    }

    //Runtime (type-id) variant of has, used by the C API.
    pub inline fn hasById(ctx: *Entity, filter_type: u32) bool {
        return ctx.getOneComponentById(filter_type) != null;
    }

    //Returns a typed pointer to the data of one component of the given type
    //owned by this entity, or null if it has none.
    pub inline fn get(ctx: *Entity, comptime comp_type: type) ?*comp_type {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const component = ctx.getOneComponentById(world.typeId(comp_type)) orelse return null;
        return component.get(comp_type);
    }

    //Detaches every component of the given type from this entity. Any component
    //left without owners is destroyed so its slot can be reused (run gc to free).
    pub fn remove(ctx: *Entity, comptime comp_type: type) !void {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return ctx.removeById(world.typeId(comp_type));
    }

    //Runtime (type-id) variant of remove, used by the C API.
    pub fn removeById(ctx: *Entity, filter_type: u32) !void {
        while (ctx.getOneComponentById(filter_type)) |component| {
            try ctx.detach(component);
            if (component.owners.count() == 0)
                component.destroy();
        }
    }

    pub fn attach(self: *Entity, component: *Component, comp_type: anytype) !void {
        const world = @as(*World, @ptrCast(@alignCast(component.world)));
        const tid = world.typeId(@TypeOf(comp_type));
        const comp_size = @sizeOf(@TypeOf(comp_type));

        try component.owners.add(world.allocator, entityGlobalId(self));
        try self.owned.add(world.allocator, component);
        component.attached = true;

        const shared = component.owners.len > 1;
        const overflow = self.countOwnedOfType(tid) > 1;

        if (shared or overflow) {
            if (component.column_backed) try component.promoteToHeap(world, self);
            const val_ptr: ?*const anyopaque = if (comp_size > 0) @ptrCast(&comp_type) else null;
            try component.writeHeapValue(world, tid, val_ptr, comp_size);
            try world.archetypeRefresh(self, .{ .tid = tid, .data = val_ptr });
        } else {
            component.column_backed = false;
            component.allocated = false;
            component.data = null;
            const val_ptr: ?*const anyopaque = if (comp_size > 0) @ptrCast(&comp_type) else null;
            try world.archetypeRefresh(self, .{ .tid = tid, .data = val_ptr });
        }

        if (component.typeId) |ctid| world.signalComponentAdded(self, component, ctid);
    }

    pub fn attach_c(self: *Entity, component: *Component, comp_type: *c_type) !void {
        const world = @as(*World, @ptrCast(@alignCast(component.world)));
        const tid = world.typeIdC(comp_type.*);
        const comp_size = comp_type.size;

        try component.owners.add(world.allocator, entityGlobalId(self));
        try self.owned.add(world.allocator, component);
        component.attached = true;

        const shared = component.owners.len > 1;
        const overflow = self.countOwnedOfType(tid) > 1;

        if (shared or overflow) {
            if (component.column_backed) try component.promoteToHeap(world, self);
            if (comp_size > 0 and (!component.allocated or component.column_backed)) {
                const heap = try allocBytes(world.allocator, comp_size, world.types.alignOf(tid));
                component.data = heap.ptr;
                component.column_backed = false;
                component.allocated = true;
            }
            try world.archetypeRefresh(self, .{ .tid = tid, .data = component.data });
        } else {
            component.column_backed = false;
            component.allocated = false;
            component.data = null;
            try world.archetypeRefresh(self, .{ .tid = tid, .data = null });
        }

        if (component.typeId) |ctid| world.signalComponentAdded(self, component, ctid);
    }

    pub inline fn detach(self: *Entity, component: *Component) !void {
        var world = @as(*World, @ptrCast(@alignCast(self.world)));

        component.attached = false;
        component.owners.remove(entityGlobalId(self));
        self.owned.remove(component);
        if (component.column_backed and component.owners.len == 0) {
            component.column_backed = false;
            component.data = null;
            component.allocated = false;
        }
        try world.archetypeRefresh(self, .{});
        if (component.typeId) |tid| world.signalComponentRemoved(self, component, tid);
    }

    pub inline fn destroy(self: *Entity) void {
        var world = @as(*World, @ptrCast(@alignCast(self.world)));
        const gid = entityGlobalId(self);

        //Release ownership of every component this entity owns (O(owned), via
        //the reverse index). A component left with no remaining owners is
        //destroyed so its slot can be reclaimed by gc. Components shared with
        //other entities stay alive. We iterate by index and clear afterward;
        //destroying an ownerless component touches no owners, so `owned` is not
        //mutated underneath us during the loop.
        var k: u32 = 0;
        while (k < self.owned.len) : (k += 1) {
            const component = self.owned.at(k);
            if (component.typeId) |tid| world.signalComponentRemoved(self, component, tid);
            component.owners.remove(gid);
            if (component.owners.count() == 0)
                component.destroy();
        }
        self.owned.clear(world.allocator);

        world.archetypes.remove(world.allocator, world, self);

        world.signalEntityDestroyed(self);
        self.alive = false;
        //Invalidate any outstanding handles to this slot. Wrapping so a slot
        //recycled billions of times never panics; collisions are astronomically
        //unlikely and no worse than the pre-generational behavior.
        self.generation +%= 1;
        world._entities[self.chunk].alive -= 1;
        world._entities[self.chunk].free_idx = self.id;
        world.entities_free_idx = self.chunk;
        world.entities.alive -= 1;
    }

    pub inline fn set(self: *Entity, component: *Component, comptime comp_type: type, members: anytype) !void {
        var field_ptr = @as(*comp_type, @ptrCast(component.data));
        inline for (@typeInfo(@TypeOf(members)).@"struct".field_names) |name| {
            @field(field_ptr, name) = @field(members, name);
        }
        _ = self;
    }
};

//Do not inline
pub fn typeToId(world: *World, comptime T: type) u32 {
    return world.typeId(T);
}

pub fn typeToIdC(world: *World, ct: c_type) u32 {
    return world.typeIdC(ct);
}

pub inline fn Cast(comptime T: type, component: ?*Component) *T {
    const field_ptr = @as(*T, @ptrCast(@alignCast(component.?.data)));
    return field_ptr;
}

pub inline fn CastData(comptime T: type, component: ?*anyopaque) *T {
    const field_ptr = @as(*T, @ptrCast(@alignCast(component)));
    return field_ptr;
}

pub const SuperEntities = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    alive: usize,

    pub inline fn count(ctx: *SuperEntities) u32 {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        var i: usize = 0;
        var total: u32 = 0;
        while (i < world.entities_len) : (i += 1) {
            total += world._entities[i].alive;
        }
        return total;
    }

    pub fn create(ctx: *SuperEntities) !*Entity {
        var world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        defer ctx.alive += 1;

        if (world._entities[world.entities_free_idx].len < CHUNK_SIZE) {
            return try world._entities[world.entities_free_idx].create();
        } else { //Create new chunk
            try ctx.expand();
            return try world._entities[world.entities_free_idx].create();
        }
    }

    pub fn expand(ctx: *SuperEntities) !void {
        var world = @as(*World, @ptrCast(@alignCast(ctx.world)));

        world._entities = try world.allocator.realloc(world._entities, world.entities_len + 1);
        world._entities[world.entities_len].world = world;
        world._entities[world.entities_len].len = 0;
        world._entities[world.entities_len].alive = 0;
        world._entities[world.entities_len].created = 0;
        world._entities[world.entities_len].free_idx = 0;
        world._entities[world.entities_len].sparse = try world.allocator.alloc(Entity, CHUNK_SIZE);
        for (world._entities[world.entities_len].sparse) |*e| {
            e.alive = false;
            e.generation = 0;
            e.owned = .{};
            e.archetype = Archetypes.nil;
            e.archetype_row = 0;
        }

        world.entities_len += 1;
        world.entities_free_idx = world.entities_len - 1;
        entities_idx = world.entities_free_idx;
    }

    pub const Iterator = struct {
        ctx: *[]Entities,
        index: usize = 0,
        alive: usize = 0,

        pub inline fn next(it: *Iterator) ?*Entity {
            while (it.index < it.alive) : (it.index += 1) {
                const mod = it.index / CHUNK_SIZE;
                const rem = @rem(it.index, CHUNK_SIZE);
                if (it.ctx.*[mod].sparse[rem].alive) {
                    const sparse_index = rem;
                    it.index += 1;
                    return &it.ctx.*[mod].sparse[sparse_index];
                }
            }

            return null;
        }
    };

    //Yields entities whose archetype signature includes `filter_type`.
    pub const MaskedIterator = struct {
        world: *World,
        filter_type: u32,
        arch_index: usize = 0,
        row: usize = 0,

        pub fn next(it: *MaskedIterator) ?*Entity {
            const active = it.world.archetypes.active.items;
            while (it.arch_index < active.len) {
                const arch = &it.world.archetypes.list.items[active[it.arch_index]];
                if (!arch.signature.contains(it.filter_type)) {
                    it.arch_index += 1;
                    it.row = 0;
                    continue;
                }
                while (it.row < arch.entities.items.len) {
                    const gid = arch.entities.items[it.row];
                    it.row += 1;
                    if (resolveGlobalId(it.world, gid)) |entity| return entity;
                }
                it.arch_index += 1;
                it.row = 0;
            }
            return null;
        }
    };

    pub inline fn iterator(ctx: *SuperEntities) SuperEntities.Iterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const entities = &world._entities;
        //Scan the full allocated slot range and skip dead slots. Using the live
        //*count* as the bound (the old behavior) silently missed live entities
        //whenever destroyed slots left holes below the high-water mark.
        return .{ .ctx = entities, .alive = CHUNK_SIZE * world.entities_len };
    }

    //Resolves a stored handle to the live entity it refers to, or null if that
    //entity has been destroyed (or its slot recycled by a newer entity).
    pub inline fn resolve(ctx: *SuperEntities, handle: EntityRef) ?*Entity {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return resolveGlobalId(world, handle.toGlobalId());
    }

    //True if `handle` still refers to the same live entity it was taken from.
    pub inline fn isValid(ctx: *SuperEntities, handle: EntityRef) bool {
        return ctx.resolve(handle) != null;
    }

    pub fn iteratorFilter(ctx: *SuperEntities, comptime comp_type: type) SuperEntities.MaskedIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return .{ .world = world, .filter_type = world.typeId(comp_type) };
    }

    pub const QueryIterator = struct {
        world: *World,
        include_storage: [64]u32 = undefined,
        exclude_storage: [64]u32 = undefined,
        include: []const u32 = &.{},
        exclude: []const u32 = &.{},
        arch_index: usize = 0,
        row: usize = 0,
        untagged_chunk: usize = 0,
        untagged_slot: usize = 0,
        heap_include: ?[]u32 = null,
        heap_exclude: ?[]u32 = null,

        pub fn deinit(self: *QueryIterator, alloc: std.mem.Allocator) void {
            if (self.heap_include) |buf| alloc.free(buf);
            if (self.heap_exclude) |buf| alloc.free(buf);
            self.heap_include = null;
            self.heap_exclude = null;
        }

        pub fn next(it: *QueryIterator) ?*Entity {
            const active = it.world.archetypes.active.items;
            while (it.arch_index < active.len) {
                const arch = &it.world.archetypes.list.items[active[it.arch_index]];
                if (!arch.signature.matches(it.include, it.exclude)) {
                    it.arch_index += 1;
                    it.row = 0;
                    continue;
                }
                while (it.row < arch.entities.items.len) {
                    const gid = arch.entities.items[it.row];
                    it.row += 1;
                    if (resolveGlobalId(it.world, gid)) |entity| return entity;
                }
                it.arch_index += 1;
                it.row = 0;
            }

            //Component-less entities are not placed in a table until first attach.
            if (it.include.len > 0) return null;
            while (it.untagged_chunk < it.world.entities_len) {
                while (it.untagged_slot < CHUNK_SIZE) {
                    const entity = &it.world._entities[it.untagged_chunk].sparse[it.untagged_slot];
                    it.untagged_slot += 1;
                    if (!entity.alive or entity.archetype != Archetypes.nil) continue;
                    return entity;
                }
                it.untagged_chunk += 1;
                it.untagged_slot = 0;
            }
            return null;
        }
    };

    pub fn buildQueryFilter(world: *World, comptime include: anytype, comptime exclude: anytype) QueryIterator {
        var it: QueryIterator = .{ .world = world };
        var inc_len: usize = 0;
        inline for (include) |T| {
            it.include_storage[inc_len] = world.typeId(T);
            inc_len += 1;
        }
        it.include = it.include_storage[0..inc_len];
        var exc_len: usize = 0;
        inline for (exclude) |T| {
            it.exclude_storage[exc_len] = world.typeId(T);
            exc_len += 1;
        }
        std.mem.sort(u32, it.include_storage[0..inc_len], {}, std.sort.asc(u32));
        std.mem.sort(u32, it.exclude_storage[0..exc_len], {}, std.sort.asc(u32));
        it.exclude = it.exclude_storage[0..exc_len];
        return it;
    }

    pub fn query(ctx: *SuperEntities, comptime include: anytype) SuperEntities.QueryIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return SuperEntities.buildQueryFilter(world, include, .{});
    }

    pub fn queryExclude(ctx: *SuperEntities, comptime include: anytype, comptime exclude: anytype) SuperEntities.QueryIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return SuperEntities.buildQueryFilter(world, include, exclude);
    }

    pub fn queryC(ctx: *SuperEntities, alloc: std.mem.Allocator, include: []const u32, exclude: []const u32) !QueryIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        var it: QueryIterator = .{ .world = world };
        it.heap_include = try alloc.dupe(u32, include);
        it.heap_exclude = try alloc.dupe(u32, exclude);
        it.include = it.heap_include.?;
        it.exclude = it.heap_exclude.?;
        std.mem.sort(u32, it.heap_include.?, {}, std.sort.asc(u32));
        std.mem.sort(u32, it.heap_exclude.?, {}, std.sort.asc(u32));
        return it;
    }

    /// Spawns `n` component-less entities (no archetype table row until first attach).
    pub fn createBatch(ctx: *SuperEntities, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) _ = try ctx.create();
    }

    /// Spawns `n` entities with one component type, copying `value` into each SoA row.
    pub fn createBatchUniform(ctx: *SuperEntities, comptime T: type, n: usize, value: T) !void {
        if (n == 0) return;
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const tid = world.typeId(T);

        var sig = try world.signatureFromComponents(world.allocator, .{T});
        defer sig.deinit(world.allocator);

        const ents = try world.allocator.alloc(*Entity, n);
        defer world.allocator.free(ents);
        const comps = try world.allocator.alloc(*Component, n);
        defer world.allocator.free(comps);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            ents[i] = try ctx.create();
            comps[i] = try world.components.create(T);
        }

        const start_row = try world.archetypes.insertBatch(world.allocator, &world.types, world, &sig, ents);
        const arch = &world.archetypes.list.items[ents[0].archetype];
        Archetypes.fillColumnUniform(arch, tid, start_row, n, @ptrCast(&value), @sizeOf(T));

        i = 0;
        while (i < n) : (i += 1) {
            try world.wireBatchAttach(ents[i], comps[i], tid);
            world.signalComponentAdded(ents[i], comps[i], tid);
        }
    }

    /// Spawns one entity per value, writing each into the SoA column directly.
    pub fn createBatchValues(ctx: *SuperEntities, comptime T: type, values: []const T) !void {
        if (values.len == 0) return;
        try ctx.createBatchUniformValues(T, values);
    }

    fn createBatchUniformValues(ctx: *SuperEntities, comptime T: type, values: []const T) !void {
        const n = values.len;
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const tid = world.typeId(T);

        var sig = try world.signatureFromComponents(world.allocator, .{T});
        defer sig.deinit(world.allocator);

        const ents = try world.allocator.alloc(*Entity, n);
        defer world.allocator.free(ents);
        const comps = try world.allocator.alloc(*Component, n);
        defer world.allocator.free(comps);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            ents[i] = try ctx.create();
            comps[i] = try world.components.create(T);
        }

        const start_row = try world.archetypes.insertBatch(world.allocator, &world.types, world, &sig, ents);
        const arch = &world.archetypes.list.items[ents[0].archetype];
        Archetypes.fillColumnValues(arch, tid, start_row, std.mem.sliceAsBytes(values), @sizeOf(T));

        i = 0;
        while (i < n) : (i += 1) {
            try world.wireBatchAttach(ents[i], comps[i], tid);
            world.signalComponentAdded(ents[i], comps[i], tid);
        }
    }

    /// Spawns `n` entities with multiple component types, copying `init` into every row.
    pub fn createBatchComponents(ctx: *SuperEntities, n: usize, init: anytype) !void {
        if (n == 0) return;
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const info = @typeInfo(@TypeOf(init)).@"struct";
        const nfields = info.field_types.len;

        var sig = try world.signatureFromInit(world.allocator, init);
        defer sig.deinit(world.allocator);

        const ents = try world.allocator.alloc(*Entity, n);
        defer world.allocator.free(ents);
        const all_comps = try world.allocator.alloc(*Component, n * nfields);
        defer world.allocator.free(all_comps);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            ents[i] = try ctx.create();
            inline for (info.field_types, 0..) |FieldType, fi| {
                all_comps[i * nfields + fi] = try world.components.create(FieldType);
            }
        }

        const start_row = try world.archetypes.insertBatch(world.allocator, &world.types, world, &sig, ents);
        const arch = &world.archetypes.list.items[ents[0].archetype];

        inline for (info.field_names, info.field_types) |name, FieldType| {
            const col_tid = world.typeId(FieldType);
            const val = @field(init, name);
            Archetypes.fillColumnUniform(arch, col_tid, start_row, n, @ptrCast(&val), @sizeOf(FieldType));
        }

        i = 0;
        while (i < n) : (i += 1) {
            inline for (info.field_types, 0..) |FieldType, fi| {
                const wire_tid = world.typeId(FieldType);
                const comp = all_comps[i * nfields + fi];
                try world.wireBatchAttach(ents[i], comp, wire_tid);
                world.signalComponentAdded(ents[i], comp, wire_tid);
            }
        }
    }

    pub fn QueryView(comptime include: anytype, comptime _exclude: anytype) type {
        _ = _exclude;
        return struct {
            world: *World,
            include_storage: [64]u32 = undefined,
            exclude_storage: [64]u32 = undefined,
            include: []const u32 = &.{},
            exclude: []const u32 = &.{},
            arch_index: usize = 0,
            row: usize = 0,

            pub const Row = struct {
                entity: *Entity,
                world: *World,
                arch_idx: u32,
                row: usize,

                /// Returns a direct pointer into the archetype SoA column for `T`.
                pub fn get(self: Row, comptime T: type) *T {
                    comptime var ok = false;
                    inline for (include) |Comp| {
                        if (T == Comp) ok = true;
                    }
                    if (!ok) @compileError("component type not in query view");
                    const tid = self.world.typeId(T);
                    if (self.world.archetypes.columnPtr(self.arch_idx, self.row, tid)) |ptr| {
                        return CastData(T, ptr);
                    }
                    return self.entity.get(T) orelse unreachable;
                }
            };

            pub fn next(it: *@This()) ?Row {
                const active = it.world.archetypes.active.items;
                while (it.arch_index < active.len) {
                    const arch_idx = active[it.arch_index];
                    const arch = &it.world.archetypes.list.items[arch_idx];
                    if (!arch.signature.matches(it.include, it.exclude)) {
                        it.arch_index += 1;
                        it.row = 0;
                        continue;
                    }
                    while (it.row < arch.entities.items.len) {
                        const gid = arch.entities.items[it.row];
                        const current_row = it.row;
                        it.row += 1;
                        if (resolveGlobalId(it.world, gid)) |entity| {
                            return Row{
                                .entity = entity,
                                .world = it.world,
                                .arch_idx = arch_idx,
                                .row = current_row,
                            };
                        }
                    }
                    it.arch_index += 1;
                    it.row = 0;
                }
                return null;
            }
        };
    }

    fn buildQueryView(world: *World, comptime include: anytype, comptime exclude: anytype) SuperEntities.QueryView(include, exclude) {
        var qv = SuperEntities.QueryView(include, exclude){ .world = world };
        var inc_len: usize = 0;
        inline for (include) |T| {
            qv.include_storage[inc_len] = world.typeId(T);
            inc_len += 1;
        }
        qv.include = qv.include_storage[0..inc_len];
        var exc_len: usize = 0;
        inline for (exclude) |T| {
            qv.exclude_storage[exc_len] = world.typeId(T);
            exc_len += 1;
        }
        std.mem.sort(u32, qv.include_storage[0..inc_len], {}, std.sort.asc(u32));
        std.mem.sort(u32, qv.exclude_storage[0..exc_len], {}, std.sort.asc(u32));
        qv.exclude = qv.exclude_storage[0..exc_len];
        return qv;
    }

    /// Archetype-backed query yielding direct SoA column pointers per component type.
    pub fn queryView(ctx: *SuperEntities, comptime include: anytype) SuperEntities.QueryView(include, .{}) {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return SuperEntities.buildQueryView(world, include, .{});
    }

    pub fn queryViewExclude(ctx: *SuperEntities, comptime include: anytype, comptime exclude: anytype) SuperEntities.QueryView(include, exclude) {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return SuperEntities.buildQueryView(world, include, exclude);
    }

    pub fn QueryViewSimd(comptime include: anytype, comptime _exclude: anytype) type {
        _ = _exclude;
        return struct {
            world: *World,
            include_storage: [64]u32 = undefined,
            exclude_storage: [64]u32 = undefined,
            include: []const u32 = &.{},
            exclude: []const u32 = &.{},
            arch_index: usize = 0,

            /// Invokes `callback` with a dense typed column slice for each matching archetype.
            pub fn forEachColumn(it: *@This(), comptime T: type, callback: fn ([]T, arch_idx: u32) void) void {
                comptime var ok = false;
                inline for (include) |Comp| {
                    if (T == Comp) ok = true;
                }
                if (!ok) @compileError("component type not in queryViewSimd include list");
                const tid = it.world.typeId(T);
                it.arch_index = 0;
                const active = it.world.archetypes.active.items;
                while (it.arch_index < active.len) {
                    const arch_idx = active[it.arch_index];
                    it.arch_index += 1;
                    const arch = &it.world.archetypes.list.items[arch_idx];
                    if (!arch.signature.matches(it.include, it.exclude)) continue;
                    const col_idx = Archetypes.columnIndex(arch, tid) orelse continue;
                    const col = &arch.columns.items[col_idx];
                    const slice = ColumnSimd.typedSlice(T, col, arch.entities.items.len);
                    callback(slice, arch_idx);
                }
            }

            /// Element-wise callback over every row in matching columns for `T`.
            pub fn processColumn(it: *@This(), comptime T: type, processor: fn (*T) void) void {
                const Proc = struct {
                    fn cb(slice: []T, _: u32) void {
                        for (slice) |*elem| processor(elem);
                    }
                };
                it.forEachColumn(T, Proc.cb);
            }

            /// SIMD integration when the query includes both `Position` and `Velocity` types.
            pub fn integratePosition2D(
                it: *@This(),
                comptime Position: type,
                comptime Velocity: type,
                dt: f32,
            ) void {
                comptime var has_pos = false;
                comptime var has_vel = false;
                inline for (include) |Comp| {
                    if (Comp == Position) has_pos = true;
                    if (Comp == Velocity) has_vel = true;
                }
                if (!has_pos or !has_vel) @compileError("integratePosition2D requires Position and Velocity in include");
                const pos_tid = it.world.typeId(Position);
                const vel_tid = it.world.typeId(Velocity);
                it.arch_index = 0;
                const active = it.world.archetypes.active.items;
                while (it.arch_index < active.len) {
                    const arch_idx = active[it.arch_index];
                    it.arch_index += 1;
                    const arch = &it.world.archetypes.list.items[arch_idx];
                    if (!arch.signature.matches(it.include, it.exclude)) continue;
                    const pos_idx = Archetypes.columnIndex(arch, pos_tid) orelse continue;
                    const vel_idx = Archetypes.columnIndex(arch, vel_tid) orelse continue;
                    const rows = arch.entities.items.len;
                    const positions = ColumnSimd.typedSlice(Position, &arch.columns.items[pos_idx], rows);
                    const velocities = ColumnSimd.typedSlice(Velocity, &arch.columns.items[vel_idx], rows);
                    SimdSystems.integratePosition2D(Position, Velocity, positions, velocities, dt);
                }
            }
        };
    }

    fn buildQueryViewSimd(world: *World, comptime include: anytype, comptime exclude: anytype) SuperEntities.QueryViewSimd(include, exclude) {
        var qv = SuperEntities.QueryViewSimd(include, exclude){ .world = world };
        var inc_len: usize = 0;
        inline for (include) |T| {
            qv.include_storage[inc_len] = world.typeId(T);
            inc_len += 1;
        }
        qv.include = qv.include_storage[0..inc_len];
        var exc_len: usize = 0;
        inline for (exclude) |T| {
            qv.exclude_storage[exc_len] = world.typeId(T);
            exc_len += 1;
        }
        std.mem.sort(u32, qv.include_storage[0..inc_len], {}, std.sort.asc(u32));
        std.mem.sort(u32, qv.exclude_storage[0..exc_len], {}, std.sort.asc(u32));
        qv.exclude = qv.exclude_storage[0..exc_len];
        return qv;
    }

    /// Query filter + dense SoA column iteration with SIMD helpers.
    pub fn queryViewSimd(ctx: *SuperEntities, comptime include: anytype) SuperEntities.QueryViewSimd(include, .{}) {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return SuperEntities.buildQueryViewSimd(world, include, .{});
    }

    pub fn queryViewSimdExclude(ctx: *SuperEntities, comptime include: anytype, comptime exclude: anytype) SuperEntities.QueryViewSimd(include, exclude) {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return SuperEntities.buildQueryViewSimd(world, include, exclude);
    }
};

const Entities = struct {
    len: u32 = 0,
    sparse: []Entity,
    alive: u32 = 0,
    free_idx: u32 = 0,
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    created: u32 = 0,

    pub inline fn create(ctx: *Entities) !*Entity {
        //most ECS cheat here and don't allocate memory until a component is assigned

        //find end of sparse array
        var wrapped = false;
        while (ctx.sparse[ctx.free_idx].alive == true) {
            if (wrapped and ctx.free_idx > CHUNK_SIZE)
                return error.NoFreeEntitySlots;

            ctx.free_idx = ctx.alive + 1;
            if (ctx.free_idx > CHUNK_SIZE - 1) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }

        if (!wrapped)
            ctx.len += 1;

        var entity = &ctx.sparse[ctx.free_idx];
        entity.id = ctx.free_idx;
        entity.alive = true;
        entity.world = ctx.world;
        entity.chunk = entities_idx;
        entity.archetype = Archetypes.nil;
        entity.archetype_row = 0;

        ctx.alive += 1;
        ctx.free_idx += 1;

        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        world.signalEntitySpawned(entity);

        return entity;
    }

    pub inline fn count(ctx: *Entities) u32 {
        //count of all living entities
        return ctx.alive;
    }
};

pub const Systems = struct {
    pub fn run(comptime f: anytype, args: anytype) !void {
        const ret = @call(.auto, f, args);
        if (@typeInfo(@TypeOf(ret)) == .error_union) try ret;
    }
};

//Records structural mutations (spawn/despawn/attach/detach) so they can be
//applied later, instead of mutating the world in the middle of an iteration or
//query. This is the building block a scheduler uses: each system records into a
//buffer, and the scheduler flushes between stages.
//
//Commands are applied in the order they were recorded. Newly spawned entities
//are referred to by a `Deferred` placeholder that resolves to a real entity at
//flush time, so you can spawn an entity and attach components to it in one batch.
//Existing entities are targeted by `EntityRef` so a despawn recorded earlier in
//the batch never resurfaces as a stale pointer.
pub const CommandBuffer = struct {
    pub const Target = union(enum) {
        existing: EntityRef,
        deferred: u32,
    };

    //A placeholder for an entity that will exist after flush.
    pub const Deferred = struct {
        index: u32,
        pub inline fn target(self: Deferred) Target {
            return .{ .deferred = self.index };
        }
    };

    const ApplyFn = *const fn (*World, *Entity, *anyopaque) anyerror!void;

    const Cmd = union(enum) {
        create_entity: u32, //placeholder index
        destroy_entity: Target,
        attach_value: struct { target: Target, data: *anyopaque, apply: ApplyFn }, //Zig, typed payload
        attach_component: struct { target: Target, component: *Component, c_type: c_type }, //C, existing component
        remove: struct { target: Target, type_id: u32 },
    };

    world: *World,
    arena: std.heap.ArenaAllocator,
    cmds: std.ArrayListUnmanaged(Cmd) = .empty,
    created: std.ArrayListUnmanaged(?*Entity) = .empty,

    pub fn init(world: *World) CommandBuffer {
        return .{ .world = world, .arena = std.heap.ArenaAllocator.init(world.allocator) };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.cmds.deinit(self.world.allocator);
        self.created.deinit(self.world.allocator);
        self.arena.deinit();
    }

    //Spawns an entity at flush time, returning a placeholder usable as a target
    //for attach/remove commands recorded afterward in the same batch.
    pub fn createEntity(self: *CommandBuffer) !Deferred {
        const idx: u32 = @intCast(self.created.items.len);
        try self.created.append(self.world.allocator, null);
        try self.cmds.append(self.world.allocator, .{ .create_entity = idx });
        return .{ .index = idx };
    }

    pub fn destroyEntity(self: *CommandBuffer, ref: EntityRef) !void {
        try self.cmds.append(self.world.allocator, .{ .destroy_entity = .{ .existing = ref } });
    }

    pub fn destroyDeferred(self: *CommandBuffer, d: Deferred) !void {
        try self.cmds.append(self.world.allocator, .{ .destroy_entity = d.target() });
    }

    //Records attaching a (copied) typed component value to an existing entity.
    pub fn attach(self: *CommandBuffer, ref: EntityRef, value: anytype) !void {
        try self.attachTarget(.{ .existing = ref }, value);
    }

    //Records attaching a (copied) typed component value to a deferred entity.
    pub fn attachDeferred(self: *CommandBuffer, d: Deferred, value: anytype) !void {
        try self.attachTarget(d.target(), value);
    }

    fn attachTarget(self: *CommandBuffer, t: Target, value: anytype) !void {
        const T = @TypeOf(value);
        const box = try self.arena.allocator().create(T);
        box.* = value;
        const apply = struct {
            fn f(w: *World, e: *Entity, data: *anyopaque) anyerror!void {
                const v = @as(*T, @ptrCast(@alignCast(data))).*;
                const c = try w.components.create(T);
                try e.attach(c, v);
            }
        }.f;
        try self.cmds.append(self.world.allocator, .{ .attach_value = .{ .target = t, .data = box, .apply = apply } });
    }

    pub fn remove(self: *CommandBuffer, ref: EntityRef, comptime T: type) !void {
        try self.cmds.append(self.world.allocator, .{ .remove = .{ .target = .{ .existing = ref }, .type_id = self.world.typeId(T) } });
    }

    pub fn removeDeferred(self: *CommandBuffer, d: Deferred, comptime T: type) !void {
        try self.cmds.append(self.world.allocator, .{ .remove = .{ .target = d.target(), .type_id = self.world.typeId(T) } });
    }

    fn resolveTarget(self: *CommandBuffer, t: Target) ?*Entity {
        return switch (t) {
            .existing => |ref| self.world.entities.resolve(ref),
            .deferred => |idx| if (idx < self.created.items.len) self.created.items[idx] else null,
        };
    }

    //Applies all recorded commands in order, then resets the buffer for reuse.
    //Commands targeting an entity that no longer resolves (e.g. destroyed
    //earlier in the same batch) are skipped.
    pub fn flush(self: *CommandBuffer) !void {
        for (self.cmds.items) |cmd| {
            switch (cmd) {
                .create_entity => |idx| self.created.items[idx] = try self.world.entities.create(),
                .destroy_entity => |t| {
                    if (self.resolveTarget(t)) |e| e.destroy();
                },
                .attach_value => |a| {
                    if (self.resolveTarget(a.target)) |e| try a.apply(self.world, e, a.data);
                },
                .attach_component => |a| {
                    if (self.resolveTarget(a.target)) |e| try e.attach(a.component, a.c_type);
                },
                .remove => |r| {
                    if (self.resolveTarget(r.target)) |e| try e.removeById(r.type_id);
                },
            }
        }
        self.reset();
    }

    //Discards all recorded commands without applying them and frees payloads.
    pub fn reset(self: *CommandBuffer) void {
        self.cmds.clearRetainingCapacity();
        self.created.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    // --- helpers for the C API (runtime handles / ids, existing components) ---

    pub fn cSpawn(self: *CommandBuffer) u32 {
        const idx: u32 = @intCast(self.created.items.len);
        self.created.append(self.world.allocator, null) catch return std.math.maxInt(u32);
        self.cmds.append(self.world.allocator, .{ .create_entity = idx }) catch return std.math.maxInt(u32);
        return idx;
    }

    pub fn cDestroyExisting(self: *CommandBuffer, handle: u64) bool {
        return self.push(.{ .destroy_entity = .{ .existing = entityRefFromGlobalId(handle) } });
    }

    pub fn cDestroyDeferred(self: *CommandBuffer, idx: u32) bool {
        return self.push(.{ .destroy_entity = .{ .deferred = idx } });
    }

    pub fn cAttachExisting(self: *CommandBuffer, handle: u64, component: *Component, ct: c_type) bool {
        return self.push(.{ .attach_component = .{ .target = .{ .existing = entityRefFromGlobalId(handle) }, .component = component, .c_type = ct } });
    }

    pub fn cAttachDeferred(self: *CommandBuffer, idx: u32, component: *Component, ct: c_type) bool {
        return self.push(.{ .attach_component = .{ .target = .{ .deferred = idx }, .component = component, .c_type = ct } });
    }

    pub fn cRemoveExisting(self: *CommandBuffer, handle: u64, type_id: u32) bool {
        return self.push(.{ .remove = .{ .target = .{ .existing = entityRefFromGlobalId(handle) }, .type_id = type_id } });
    }

    pub fn cRemoveDeferred(self: *CommandBuffer, idx: u32, type_id: u32) bool {
        return self.push(.{ .remove = .{ .target = .{ .deferred = idx }, .type_id = type_id } });
    }

    fn push(self: *CommandBuffer, cmd: Cmd) bool {
        self.cmds.append(self.world.allocator, cmd) catch return false;
        return true;
    }
};

//What every system receives: the world to read/iterate, and a command buffer to
//record structural changes into. The scheduler owns the command buffer and
//flushes it at stage boundaries, so a system can safely spawn/despawn/attach
//while iterating without corrupting the iteration in progress.
pub const SystemContext = struct {
    world: *World,
    commands: *CommandBuffer,

    //Returns a mutable pointer to a world-scoped singleton of type `T`, or null
    //if none has been inserted yet.
    pub inline fn resource(self: *SystemContext, comptime T: type) ?*T {
        return self.world.resources.get(self.world, T);
    }

    pub inline fn events(self: *SystemContext) *Events {
        return &self.world.events;
    }
};

//A simple ordered, staged system runner. Systems are grouped into stages; stages
//execute in creation order, and within a stage systems run in registration
//order. The shared command buffer is flushed at the end of each stage, so
//structural changes a stage records become visible to later stages but never
//mid-stage. Systems read/write world resources via `SystemContext.resource`.
pub const Scheduler = struct {
    pub const SystemFn = *const fn (*SystemContext) anyerror!void;

    //C-ABI system callback: (world_ptr, command_buffer_ptr, user_data).
    pub const CSystemFn = *const fn (usize, usize, ?*anyopaque) callconv(.c) void;

    const System = union(enum) {
        zig: SystemFn,
        c: struct { cb: CSystemFn, user_data: ?*anyopaque },
    };

    const Stage = struct {
        systems: std.ArrayListUnmanaged(System) = .empty,
    };

    world: *World,
    commands: CommandBuffer,
    stages: std.ArrayListUnmanaged(Stage) = .empty,

    pub fn init(world: *World) Scheduler {
        return .{ .world = world, .commands = CommandBuffer.init(world) };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.stages.items) |*s| s.systems.deinit(self.world.allocator);
        self.stages.deinit(self.world.allocator);
        self.commands.deinit();
    }

    //Appends a new (empty) stage and returns its id. Stages run in id order.
    pub fn addStage(self: *Scheduler) !usize {
        const id = self.stages.items.len;
        try self.stages.append(self.world.allocator, .{});
        return id;
    }

    fn ensureStage(self: *Scheduler, stage: usize) !void {
        while (self.stages.items.len <= stage)
            try self.stages.append(self.world.allocator, .{});
    }

    //Registers a Zig system into `stage` (intermediate stages are created as
    //needed so addSystem(0, ...) works without an explicit addStage).
    pub fn addSystem(self: *Scheduler, stage: usize, system: SystemFn) !void {
        try self.ensureStage(stage);
        try self.stages.items[stage].systems.append(self.world.allocator, .{ .zig = system });
    }

    //Registers a C-ABI system callback into `stage`.
    pub fn addSystemC(self: *Scheduler, stage: usize, cb: CSystemFn, user_data: ?*anyopaque) !void {
        try self.ensureStage(stage);
        try self.stages.items[stage].systems.append(self.world.allocator, .{ .c = .{ .cb = cb, .user_data = user_data } });
    }

    //Runs every stage in order, flushing recorded commands after each stage.
    pub fn run(self: *Scheduler) !void {
        var ctx = SystemContext{ .world = self.world, .commands = &self.commands };
        for (self.stages.items) |*stage| {
            for (stage.systems.items) |system| {
                switch (system) {
                    .zig => |f| try f(&ctx),
                    .c => |c| c.cb(@intFromPtr(self.world), @intFromPtr(&self.commands), c.user_data),
                }
            }
            try self.commands.flush();
        }
    }
};

pub fn opaqueDestroy(self: std.mem.Allocator, ptr: anytype, sz: usize, alignment: u8) void {
    const non_const_ptr = @as([*]u8, @ptrFromInt(@intFromPtr(ptr)));
    self.rawFree(non_const_ptr[0..sz], .fromByteUnits(alignment), @returnAddress());
}

test "ownership is exact across multiple entity chunks" {
    const A = struct { v: u32 = 0 };
    const B = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    // Create enough entities to span more than one chunk so local ids repeat.
    const total = CHUNK_SIZE + 10;
    var entities: [total]*Entity = undefined;
    var i: usize = 0;
    while (i < total) : (i += 1) entities[i] = try world.entities.create();

    // Two entities sharing the same per-chunk id (5) but in different chunks.
    const e0 = entities[5]; // chunk 0, id 5
    const e1 = entities[CHUNK_SIZE + 5]; // chunk 1, id 5
    try std.testing.expect(e0.chunk != e1.chunk);
    try std.testing.expectEqual(e0.id, e1.id);

    _ = try e0.addComponent(A{ .v = 1 });
    _ = try e1.addComponent(B{ .v = 2 });

    // Exactness: neither entity should be seen as owning the other's component.
    try std.testing.expect(e0.has(A));
    try std.testing.expect(!e0.has(B));
    try std.testing.expect(e1.has(B));
    try std.testing.expect(!e1.has(A));

    // Typed get returns the right data.
    try std.testing.expectEqual(@as(u32, 1), e0.get(A).?.v);
    try std.testing.expectEqual(@as(u32, 2), e1.get(B).?.v);

    // Query [A] yields exactly e0; query [B] yields exactly e1.
    var count_a: usize = 0;
    var qa = world.entities.query(.{A});
    while (qa.next()) |e| {
        try std.testing.expectEqual(e0, e);
        count_a += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count_a);

    var count_b: usize = 0;
    var qb = world.entities.query(.{B});
    while (qb.next()) |e| {
        try std.testing.expectEqual(e1, e);
        count_b += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count_b);

    // remove clears ownership exactly.
    try e0.remove(A);
    try std.testing.expect(!e0.has(A));
    try std.testing.expect(e1.has(B));
}

test "generational handles detect recycled entity slots" {
    var world = try World.create();
    defer world.destroy();

    const e = try world.entities.create();
    const handle = e.ref();
    try std.testing.expect(world.entities.isValid(handle));
    try std.testing.expectEqual(e, world.entities.resolve(handle).?);

    // Destroying the entity invalidates the handle immediately.
    e.destroy();
    try std.testing.expect(!world.entities.isValid(handle));
    try std.testing.expect(world.entities.resolve(handle) == null);

    // Recycling the slot yields a fresh entity with a bumped generation; the
    // old handle must NOT resolve to it (no silent aliasing).
    const e2 = try world.entities.create();
    try std.testing.expectEqual(e.id, e2.id); // same slot reused
    try std.testing.expectEqual(e.chunk, e2.chunk);
    try std.testing.expect(e2.generation != handle.generation);
    try std.testing.expect(!world.entities.isValid(handle));

    // The new entity's own handle is valid and distinct.
    const handle2 = e2.ref();
    try std.testing.expect(world.entities.isValid(handle2));
    try std.testing.expectEqual(e2, world.entities.resolve(handle2).?);
}

test "queries never yield an entity through a recycled-slot owner" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    // e1 owns an A. Destroy it WITHOUT detaching, leaving a stale owner entry
    // on the component, then recycle the slot with a new entity.
    const e1 = try world.entities.create();
    _ = try e1.addComponent(A{ .v = 1 });
    e1.destroy();

    const e2 = try world.entities.create(); // reuses e1's slot, new generation
    try std.testing.expectEqual(e1.id, e2.id);
    try std.testing.expect(!e2.has(A)); // recycled entity does not inherit ownership

    // The A-filter must not surface the recycled slot via the stale owner.
    var count: usize = 0;
    var it = world.entities.iteratorFilter(A);
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "destroy releases owned components" {
    const A = struct { v: u32 = 0 };
    const B = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    const e = try world.entities.create();
    _ = try e.addComponent(A{ .v = 1 });
    _ = try e.addComponent(B{ .v = 2 });
    try std.testing.expectEqual(@as(u32, 2), world.components.count());
    try std.testing.expectEqual(@as(u32, 2), e.owned.count());

    // Destroying the entity destroys the components it solely owns.
    e.destroy();
    try std.testing.expectEqual(@as(u32, 0), world.components.count());
}

test "shared component survives while another owner remains" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    const e1 = try world.entities.create();
    const e2 = try world.entities.create();
    const c = try world.components.create(A);
    try e1.attach(c, A{ .v = 7 });
    try e2.attach(c, A{ .v = 7 });
    try std.testing.expectEqual(@as(u32, 2), c.owners.count());

    // One owner gone: the component stays alive for the remaining owner.
    e1.destroy();
    try std.testing.expectEqual(@as(u32, 1), c.owners.count());
    try std.testing.expect(c.alive);
    try std.testing.expect(e2.has(A));

    // Last owner gone: the component is destroyed.
    e2.destroy();
    try std.testing.expect(!c.alive);
}

test "entity iterator visits live entities despite destroyed-slot holes" {
    var world = try World.create();
    defer world.destroy();

    const n = 10;
    var es: [n]*Entity = undefined;
    for (0..n) |i| es[i] = try world.entities.create();

    // Punch holes in the middle of the slot range.
    es[2].destroy();
    es[5].destroy();
    es[7].destroy();

    var seen: usize = 0;
    var it = world.entities.iterator();
    while (it.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, n - 3), seen);
    try std.testing.expectEqual(@as(u32, n - 3), world.entities.count());
}

test "command buffer defers spawn + attach until flush" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    var cb = world.commandBuffer();
    defer cb.deinit();

    const e = try cb.createEntity();
    try cb.attachDeferred(e, A{ .v = 42 });

    // Nothing applied yet.
    try std.testing.expectEqual(@as(u32, 0), world.entities.count());
    try std.testing.expectEqual(@as(u32, 0), world.components.count());

    try cb.flush();

    // Now the entity exists and owns the component with the recorded value.
    try std.testing.expectEqual(@as(u32, 1), world.entities.count());
    var q = world.entities.query(.{A});
    var found: ?*Entity = null;
    while (q.next()) |ent| found = ent;
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 42), found.?.get(A).?.v);
}

test "command buffer defers destroy recorded during iteration" {
    var world = try World.create();
    defer world.destroy();

    const n = 6;
    var es: [n]*Entity = undefined;
    for (0..n) |i| es[i] = try world.entities.create();

    var cb = world.commandBuffer();
    defer cb.deinit();

    // Iterate and record destroys for even-indexed entities WITHOUT mutating
    // the world mid-iteration.
    var it = world.entities.iterator();
    var idx: usize = 0;
    while (it.next()) |e| : (idx += 1) {
        if (idx % 2 == 0) try cb.destroyEntity(e.ref());
    }
    // All still alive until flush.
    try std.testing.expectEqual(@as(u32, n), world.entities.count());

    try cb.flush();
    try std.testing.expectEqual(@as(u32, n - 3), world.entities.count());
}

test "command buffer defers component removal" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    const e = try world.entities.create();
    _ = try e.addComponent(A{ .v = 1 });
    try std.testing.expect(e.has(A));

    var cb = world.commandBuffer();
    defer cb.deinit();

    try cb.remove(e.ref(), A);
    try std.testing.expect(e.has(A)); // not yet
    try cb.flush();
    try std.testing.expect(!e.has(A));
}

test "command buffer skips commands targeting an entity destroyed earlier in the batch" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    const e = try world.entities.create();
    const ref = e.ref();

    var cb = world.commandBuffer();
    defer cb.deinit();

    // Destroy then (stale) attach in the same batch: the attach must be skipped.
    try cb.destroyEntity(ref);
    try cb.attach(ref, A{ .v = 9 });
    try cb.flush();

    try std.testing.expectEqual(@as(u32, 0), world.entities.count());
    try std.testing.expectEqual(@as(u32, 0), world.components.count());
}

test "scheduler runs stages and systems in order" {
    const S = struct {
        var log: u32 = 0;
        fn a(ctx: *SystemContext) anyerror!void {
            _ = ctx;
            log = log * 10 + 1;
        }
        fn b(ctx: *SystemContext) anyerror!void {
            _ = ctx;
            log = log * 10 + 2;
        }
        fn c(ctx: *SystemContext) anyerror!void {
            _ = ctx;
            log = log * 10 + 3;
        }
    };
    S.log = 0;

    var world = try World.create();
    defer world.destroy();

    var sched = world.scheduler();
    defer sched.deinit();

    // Stage 0 runs a then b (registration order); stage 1 runs c.
    try sched.addSystem(0, S.a);
    try sched.addSystem(0, S.b);
    try sched.addSystem(1, S.c);

    try sched.run();
    try std.testing.expectEqual(@as(u32, 123), S.log);
}

test "scheduler flushes commands between stages" {
    const A = struct { v: u32 = 0 };
    const S = struct {
        var seen_before: u32 = 0;
        var seen_after: u32 = 0;
        fn spawn(ctx: *SystemContext) anyerror!void {
            // Record a spawn; it must NOT be visible within this stage.
            const e = try ctx.commands.createEntity();
            try ctx.commands.attachDeferred(e, A{ .v = 1 });
            seen_before = ctx.world.entities.count();
        }
        fn observe(ctx: *SystemContext) anyerror!void {
            // Stage 1 runs after the stage-0 flush, so the spawn is visible.
            seen_after = ctx.world.entities.count();
        }
    };
    S.seen_before = 0;
    S.seen_after = 0;

    var world = try World.create();
    defer world.destroy();

    var sched = world.scheduler();
    defer sched.deinit();

    try sched.addSystem(0, S.spawn);
    try sched.addSystem(1, S.observe);
    try sched.run();

    try std.testing.expectEqual(@as(u32, 0), S.seen_before); // not visible mid-stage
    try std.testing.expectEqual(@as(u32, 1), S.seen_after); // visible next stage
}

test "resources are singleton per type per world" {
    const Time = struct { tick: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    try world.insertResource(Time, .{ .tick = 1 });
    try std.testing.expectEqual(@as(u32, 1), world.getResource(Time).?.tick);

    try world.insertResource(Time, .{ .tick = 2 }); // replace
    try std.testing.expectEqual(@as(u32, 2), world.getResource(Time).?.tick);

    world.removeResource(Time);
    try std.testing.expect(world.getResource(Time) == null);
}

test "systems access resources through SystemContext" {
    const Time = struct { tick: u32 = 0 };
    const S = struct {
        var tick_after: u32 = 0;
        fn bump(ctx: *SystemContext) anyerror!void {
            if (ctx.resource(Time)) |t| t.tick += 1;
        }
        fn read(ctx: *SystemContext) anyerror!void {
            tick_after = ctx.resource(Time).?.tick;
        }
    };
    S.tick_after = 0;

    var world = try World.create();
    defer world.destroy();
    try world.insertResource(Time, .{ .tick = 10 });

    var sched = world.scheduler();
    defer sched.deinit();
    try sched.addSystem(0, S.bump);
    try sched.addSystem(1, S.read);
    try sched.run();

    try std.testing.expectEqual(@as(u32, 11), S.tick_after);
}

test "observers fire synchronously on component attach" {
    const A = struct { v: u32 = 0 };
    const O = struct {
        var count: u32 = 0;
        fn onAdd(world: *World, entity: *Entity, component: *Component, type_id: u32) void {
            _ = world;
            _ = entity;
            _ = component;
            _ = type_id;
            count += 1;
        }
    };
    O.count = 0;

    var world = try World.create();
    defer world.destroy();

    try world.onComponentAdd(A, O.onAdd);
    const e = try world.entities.create();
    _ = try e.addComponent(A{ .v = 1 });
    try std.testing.expectEqual(@as(u32, 1), O.count);
}

test "archetype index groups entities by signature" {
    const A = struct { v: u32 = 0 };
    const B = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    const e1 = try world.entities.create(); // stays {}
    const e2 = try world.entities.create(); // -> {A}
    const e3 = try world.entities.create(); // -> {A,B}

    _ = try e2.addComponent(A{});
    _ = try e3.addComponent(A{});
    _ = try e3.addComponent(B{});

    try std.testing.expectEqual(@as(usize, 2), world.archetypes.count());
    try std.testing.expectEqual(@as(usize, 0), e1.signature().ids.items.len);
    try std.testing.expect(e2.signature().contains(world.typeId(A)));
    try std.testing.expect(e3.signature().contains(world.typeId(A)));
    try std.testing.expect(e3.signature().contains(world.typeId(B)));

    var only_a: usize = 0;
    var q = world.entities.queryExclude(.{A}, .{B});
    while (q.next()) |e| {
        try std.testing.expectEqual(e2, e);
        only_a += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), only_a);

    try e3.remove(B);
    try std.testing.expectEqual(e2.archetype, e3.archetype);
    try std.testing.expect(e2.signature().eql(e3.signature().*));
}

test "archetype swap-remove keeps rows consistent across destroys" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    var es: [4]*Entity = undefined;
    for (0..4) |i| {
        es[i] = try world.entities.create();
        _ = try es[i].addComponent(A{ .v = @intCast(i) });
    }

    // Destroying row 0 swap-moves the last entity into its place; the moved
    // entity's row index must be fixed up or later removals corrupt the list.
    es[0].destroy();
    es[3].destroy();

    var seen: usize = 0;
    var q = world.entities.query(.{A});
    while (q.next()) |e| {
        try std.testing.expect(e.alive);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "signature persists while entity owns multiple components of one type" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    const e = try world.entities.create();
    const c1 = try e.addComponent(A{ .v = 1 });
    const c2 = try e.addComponent(A{ .v = 2 });
    try std.testing.expect(e.signature().contains(world.typeId(A)));

    try e.detach(c1);
    try std.testing.expect(e.has(A));
    try std.testing.expect(e.signature().contains(world.typeId(A)));

    try e.detach(c2);
    try std.testing.expect(!e.has(A));
    try std.testing.expectEqual(@as(usize, 0), e.signature().ids.items.len);
}

test "empty query yields every live entity via the archetype index" {
    var world = try World.create();
    defer world.destroy();

    const n = 5;
    var es: [n]*Entity = undefined;
    for (0..n) |i| es[i] = try world.entities.create();
    es[1].destroy();

    var seen: usize = 0;
    var q = world.entities.query(.{});
    while (q.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, n - 1), seen);
}

test "component destroy narrows owning entities' archetypes" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    const e1 = try world.entities.create();
    const e2 = try world.entities.create();
    const c = try world.components.create(A);
    try e1.attach(c, A{ .v = 1 });
    try e2.attach(c, A{ .v = 1 });
    try std.testing.expect(e1.signature().contains(world.typeId(A)));
    try std.testing.expect(e2.signature().contains(world.typeId(A)));

    // Destroying the shared component must narrow BOTH owners back to {}.
    c.destroy();
    try std.testing.expectEqual(@as(usize, 0), e1.signature().ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), e2.signature().ids.items.len);

    var seen: usize = 0;
    var q = world.entities.query(.{A});
    while (q.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, 0), seen);
}

test "per-world type registry supports many component types" {
    var world = try World.create();
    defer world.destroy();

    var i: u32 = 0;
    while (i < 80) : (i += 1) {
        const ct = c_type{ .id = @as(usize, @intCast(i)) + 1000, .size = 4, .alignment = 4, .name = null };
        const id = world.typeIdC(ct);
        try std.testing.expectEqual(i, id);
    }
    try std.testing.expectEqual(@as(u32, 80), world.types.count());

    var ct79 = c_type{ .id = 79 + 1000, .size = @sizeOf(u32), .alignment = @alignOf(u32), .name = null };
    const e = try world.entities.create();
    const c = try world.components.create_c(ct79);
    try e.attach_c(c, &ct79);
    try std.testing.expect(e.hasById(79));
}

test "type registries are isolated per world" {
    const Shared = struct { v: u32 = 0 };

    var w1 = try World.create();
    defer w1.destroy();
    var w2 = try World.create();
    defer w2.destroy();

    const id1 = w1.typeId(Shared);
    const id2 = w2.typeId(Shared);
    try std.testing.expectEqual(@as(u32, 0), id1);
    try std.testing.expectEqual(@as(u32, 0), id2);

    _ = try w1.entities.create();
    try std.testing.expectEqual(@as(u32, 0), w2.entities.count());
}

test "structural events queue lifecycle changes" {
    const C = struct {
        var spawns: u32 = 0;
        fn onEvent(ev: StructuralEvent) void {
            if (ev.kind == .entity_spawned) spawns += 1;
        }
    };
    C.spawns = 0;

    var world = try World.create();
    defer world.destroy();

    _ = try world.entities.create();
    try std.testing.expect(world.events.count() >= 1);

    world.events.drainStructural(C.onEvent);
    try std.testing.expectEqual(@as(u32, 1), C.spawns);
    try std.testing.expect(world.events.queue.items.len == 0);
}

test "SoA archetype tables survive bulk attach and detach" {
    const Orange = struct { color: u32 = 0, ripe: bool = false, harvested: bool = false };

    var world = try World.create();
    defer world.destroy();

    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const e = try world.entities.create();
        const c = try world.components.create(Orange);
        try e.attach(c, Orange{ .color = @intCast(i) });
    }

    var seen: usize = 0;
    var it = world.components.iterator();
    while (it.next()) |component| {
        if (component.typeId != world.typeId(Orange)) continue;
        try component.set(Orange, .{ .ripe = true });
        component.detach();
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 5000), seen);
}

test "queryView yields direct SoA column pointers" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = try World.create();
    defer world.destroy();

    const e = try world.entities.create();
    _ = try e.addComponent(Position{ .x = 1, .y = 2 });
    _ = try e.addComponent(Velocity{ .dx = 3, .dy = 4 });

    var qv = world.entities.queryView(.{ Position, Velocity });
    const row = qv.next() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 1), row.get(Position).x);
    try std.testing.expectEqual(@as(f32, 2), row.get(Position).y);
    try std.testing.expectEqual(@as(f32, 3), row.get(Velocity).dx);
    try std.testing.expectEqual(@as(f32, 4), row.get(Velocity).dy);

    row.get(Position).x = 10;
    try std.testing.expectEqual(@as(f32, 10), e.get(Position).?.x);
    try std.testing.expect(qv.next() == null);
}

test "createBatchUniform spawns entities with shared component values" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    try world.entities.createBatchUniform(A, 100, .{ .v = 42 });
    try std.testing.expectEqual(@as(u32, 100), world.entities.count());
    try std.testing.expectEqual(@as(u32, 100), world.components.count());

    var seen: usize = 0;
    var qv = world.entities.queryView(.{A});
    while (qv.next()) |row| {
        try std.testing.expectEqual(@as(u32, 42), row.get(A).v);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), seen);
}

test "createBatchValues writes distinct SoA rows" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    var vals: [5]A = undefined;
    for (0..5) |i| vals[i] = .{ .v = @intCast(i) };
    try world.entities.createBatchValues(A, &vals);

    var qv = world.entities.queryView(.{A});
    var seen: usize = 0;
    while (qv.next()) |row| {
        try std.testing.expectEqual(@as(u32, @intCast(seen)), row.get(A).v);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), seen);
}

test "createBatchComponents spawns multi-component entities" {
    const A = struct { v: u32 = 0 };
    const B = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    try world.entities.createBatchComponents(3, .{ A{ .v = 1 }, B{ .v = 2 } });

    var qv = world.entities.queryView(.{ A, B });
    var seen: usize = 0;
    while (qv.next()) |row| {
        try std.testing.expectEqual(@as(u32, 1), row.get(A).v);
        try std.testing.expectEqual(@as(u32, 2), row.get(B).v);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "ColumnSimd f32AddMulSimd updates slice" {
    var dst = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const src = [_]f32{ 1, 1, 1, 1, 1, 1, 1, 1 };
    ColumnSimd.f32AddMulSimd(dst[0..], src[0..], 2);
    try std.testing.expectEqual(@as(f32, 3), dst[0]);
    try std.testing.expectEqual(@as(f32, 4), dst[1]);
    try std.testing.expectEqual(@as(f32, 10), dst[7]);
}

test "SimdSystems integratePosition2D advances positions" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var positions = [_]Position{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 2 },
    };
    const velocities = [_]Velocity{
        .{ .dx = 1, .dy = 0 },
        .{ .dx = 0, .dy = 3 },
    };
    SimdSystems.integratePosition2D(Position, Velocity, positions[0..], velocities[0..], 2);
    try std.testing.expectEqual(@as(f32, 2), positions[0].x);
    try std.testing.expectEqual(@as(f32, 0), positions[0].y);
    try std.testing.expectEqual(@as(f32, 1), positions[1].x);
    try std.testing.expectEqual(@as(f32, 8), positions[1].y);
}

test "SimdSystems integratePosition2D supports x/y velocity fields" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    var positions = [_]Position{.{ .x = 1, .y = 2 }};
    const velocities = [_]Velocity{.{ .x = 3, .y = 4 }};
    SimdSystems.integratePosition2D(Position, Velocity, positions[0..], velocities[0..], 0.5);
    try std.testing.expectEqual(@as(f32, 2.5), positions[0].x);
    try std.testing.expectEqual(@as(f32, 4), positions[0].y);
}

test "queryViewSimd forEachColumn visits SoA columns" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    try world.entities.createBatchUniform(A, 4, .{ .v = 1 });

    const Bump = struct {
        fn cb(slice: []A, _: u32) void {
            for (slice) |*elem| elem.v += 1;
        }
    };
    var qv = world.entities.queryViewSimd(.{A});
    qv.forEachColumn(A, Bump.cb);

    var seen: usize = 0;
    var row_it = world.entities.queryView(.{A});
    while (row_it.next()) |row| {
        try std.testing.expectEqual(@as(u32, 2), row.get(A).v);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), seen);
}

test "queryViewSimd integratePosition2D updates archetype columns" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = try World.create();
    defer world.destroy();

    const e = try world.entities.create();
    _ = try e.addComponent(Position{ .x = 0, .y = 0 });
    _ = try e.addComponent(Velocity{ .dx = 1, .dy = 2 });

    var qv = world.entities.queryViewSimd(.{ Position, Velocity });
    qv.integratePosition2D(Position, Velocity, 0.5);
    try std.testing.expectEqual(@as(f32, 0.5), e.get(Position).?.x);
    try std.testing.expectEqual(@as(f32, 1), e.get(Position).?.y);
}

test "processComponentsSimd mutates archetype columns" {
    const A = struct { v: u32 = 0 };

    var world = try World.create();
    defer world.destroy();

    try world.entities.createBatchUniform(A, 3, .{ .v = 0 });

    const Bump = struct {
        fn bump(elem: *A) void {
            elem.v += 10;
        }
    };
    world.components.processComponentsSimd(A, Bump.bump);

    var qv = world.entities.queryView(.{A});
    var seen: usize = 0;
    while (qv.next()) |row| {
        try std.testing.expectEqual(@as(u32, 10), row.get(A).v);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}
