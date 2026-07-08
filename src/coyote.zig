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
        try self.entries.append(alloc, .{ .key = key, .size = ct.size, .alignment = ct.alignof });
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
    alignof: u8 = 8,
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
        ctx: *[]_Components,
        index: usize = 0,
        filter_type: u32,
        alive: usize = 0,
        world: *World,

        pub fn next(it: *MaskedIterator) ?*Component {
            while (it.index < it.alive) : (it.index += 1) {
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
        const components = &world._components;
        return .{ .ctx = components, .filter_type = world.typeId(comp_type), .alive = CHUNK_SIZE * world.components_len, .world = world };
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
        const filter_id = world.typeId(comp_type);
        const vector_width = std.simd.suggestVectorLength(u32) orelse 4;
        var i: usize = 0;

        // Process components in SIMD batches
        while (i + vector_width <= ctx.alive) : (i += vector_width) {
            const rems = blk: {
                var result: @Vector(vector_width, u32) = undefined;
                inline for (0..vector_width) |j| {
                    result[j] = @intCast(@rem(i + j, CHUNK_SIZE));
                }
                break :blk result;
            };

            // Process multiple components in parallel
            inline for (0..vector_width) |j| {
                const component = &ctx.sparse[@intCast(rems[j])];
                if (component.alive and component.typeId == filter_id) {
                    if (component.data) |data| {
                        const typed_data = CastData(comp_type, data);
                        processor(typed_data);
                    }
                }
            }
        }

        // Handle remaining components
        while (i < ctx.alive) : (i += 1) {
            const rem = @rem(i, CHUNK_SIZE);
            const component = &ctx.sparse[rem];
            if (component.alive and component.typeId == filter_id) {
                if (component.data) |data| {
                    const typed_data = CastData(comp_type, data);
                    processor(typed_data);
                }
            }
        }
    }

    pub fn processComponentsRangeSimd(ctx: *_Components, comptime comp_type: type, start_idx: usize, end_idx: usize, processor: fn (*comp_type) void) void {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const filter_id = world.typeId(comp_type);
        const vector_width = std.simd.suggestVectorLength(u32) orelse 4;
        var i: usize = start_idx;

        // Process components in SIMD batches within the range
        while (i + vector_width <= end_idx) : (i += vector_width) {
            const rems = blk: {
                var result: @Vector(vector_width, u32) = undefined;
                inline for (0..vector_width) |j| {
                    result[j] = @intCast(@rem(i + j, CHUNK_SIZE));
                }
                break :blk result;
            };

            // Process multiple components in parallel
            inline for (0..vector_width) |j| {
                const component = &ctx.sparse[@intCast(rems[j])];
                if (component.alive and component.typeId == filter_id) {
                    if (component.data) |data| {
                        const typed_data = CastData(comp_type, data);
                        processor(typed_data);
                    }
                }
            }
        }

        // Handle remaining components
        while (i < end_idx) : (i += 1) {
            const rem = @rem(i, CHUNK_SIZE);
            const component = &ctx.sparse[rem];
            if (component.alive and component.typeId == filter_id) {
                if (component.data) |data| {
                    const typed_data = CastData(comp_type, data);
                    processor(typed_data);
                }
            }
        }
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

//Archetype index: groups live entities by their sparse component-type signature.
pub const Archetypes = struct {
    pub const nil: u32 = std.math.maxInt(u32);

    pub const Archetype = struct {
        signature: TypeSignature,
        entities: std.ArrayListUnmanaged(u64) = .empty, //generation-tagged gids
    };

    list: std.ArrayListUnmanaged(Archetype) = .empty,

    pub fn deinit(self: *Archetypes, alloc: std.mem.Allocator) void {
        for (self.list.items) |*a| {
            a.signature.deinit(alloc);
            a.entities.deinit(alloc);
        }
        self.list.deinit(alloc);
    }

    pub fn count(self: *const Archetypes) usize {
        var n: usize = 0;
        for (self.list.items) |a| {
            if (a.entities.items.len > 0) n += 1;
        }
        return n;
    }

    fn findIndex(self: *const Archetypes, sig: *const TypeSignature) ?u32 {
        for (self.list.items, 0..) |*arch, i| {
            if (arch.signature.eql(sig.*)) return @intCast(i);
        }
        return null;
    }

    fn indexFor(self: *Archetypes, alloc: std.mem.Allocator, sig: *const TypeSignature) !u32 {
        if (self.findIndex(sig)) |idx| return idx;
        const idx: u32 = @intCast(self.list.items.len);
        try self.list.append(alloc, .{ .signature = try sig.clone(alloc), .entities = .empty });
        return idx;
    }

    pub fn insert(self: *Archetypes, alloc: std.mem.Allocator, entity: *Entity, sig: *const TypeSignature) !void {
        const idx = try self.indexFor(alloc, sig);
        const arch = &self.list.items[idx];
        try arch.entities.append(alloc, entityGlobalId(entity));
        entity.archetype = idx;
        entity.archetype_row = @intCast(arch.entities.items.len - 1);
    }

    pub fn remove(self: *Archetypes, world: *World, entity: *Entity) void {
        if (entity.archetype == nil) return;
        const arch = &self.list.items[entity.archetype];
        const row = entity.archetype_row;
        _ = arch.entities.swapRemove(row);
        if (row < arch.entities.items.len) {
            if (resolveGlobalId(world, arch.entities.items[row])) |moved|
                moved.archetype_row = row;
        }
        entity.archetype = nil;
    }

    pub fn move(self: *Archetypes, alloc: std.mem.Allocator, world: *World, entity: *Entity, new_sig: *const TypeSignature) !void {
        if (entity.archetype != nil) {
            const cur = &self.list.items[entity.archetype].signature;
            if (cur.eql(new_sig.*)) return;
        }
        self.remove(world, entity);
        try self.insert(alloc, entity, new_sig);
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

    //Rebuilds the entity's archetype from its owned components and moves it if
    //the signature changed.
    fn archetypeRefresh(self: *World, entity: *Entity) !void {
        var sig = try TypeSignature.fromEntity(self.allocator, entity);
        defer sig.deinit(self.allocator);
        try self.archetypes.move(self.allocator, self, entity, &sig);
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
                world.archetypeRefresh(e) catch unreachable;
            }
            for (self.owners.rest.items) |gid| {
                if (resolveGlobalId(world, gid)) |e| {
                    e.owned.remove(self);
                    world.archetypeRefresh(e) catch unreachable;
                }
            }
        }
        self.owners.clear(world.allocator);
    }

    //Detaches from all entities
    pub inline fn detach(self: *Component) void {
        const world = @as(*World, @ptrCast(@alignCast(self.world)));

        self.attached = false;
        self.releaseOwners(world);
    }

    pub inline fn dealloc(self: *Component) void {
        if (!self.alive and self.magic == MAGIC and self.allocated) {
            if (self.data) |data| {
                const w = @as(*World, @ptrCast(@alignCast(self.world)));
                const tid = self.typeId.?;
                opaqueDestroy(w.allocator, data, w.types.sizeOf(tid), w.types.alignOf(tid));
            }
            self.allocated = false;
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
        return &world.archetypes.list.items[self.archetype].signature;
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

        if (@sizeOf(@TypeOf(comp_type)) > 0) {
            if (!component.allocated) {
                const data = try world.allocator.create(@TypeOf(comp_type));
                data.* = comp_type;
                const oref = @as(?*anyopaque, @ptrCast(data));
                component.data = oref;
            } else {
                if (component.allocated and component.typeId == tid) {
                    const data = CastData(@TypeOf(comp_type), component.data);
                    data.* = comp_type;
                } else {
                    if (component.allocated and component.typeId != tid) {
                        const old_tid = component.typeId.?;
                        opaqueDestroy(world.allocator, component.data, world.types.sizeOf(old_tid), world.types.alignOf(old_tid));
                        const data = try world.allocator.create(@TypeOf(comp_type));
                        data.* = comp_type;
                        const oref = @as(?*anyopaque, @ptrCast(data));
                        component.data = oref;
                    }
                }
            }
        }
        component.attached = true;
        component.allocated = true;

        try component.owners.add(world.allocator, entityGlobalId(self));
        try self.owned.add(world.allocator, component);
        try world.archetypeRefresh(self);
        if (component.typeId) |ctid| world.signalComponentAdded(self, component, ctid);
    }

    pub fn attach_c(self: *Entity, component: *Component, comp_type: *c_type) !void {
        const world = @as(*World, @ptrCast(@alignCast(component.world)));
        const tid = world.typeIdC(comp_type.*);

        if (comp_type.size > 0) {
            if (!component.allocated) {
                const data = try world.allocator.create(c_type);
                data.* = comp_type.*;
                const oref = @as(?*anyopaque, @ptrCast(data));
                component.data = oref;
            } else {
                if (component.allocated and component.typeId == tid) {
                    const data = CastData(c_type, component.data);
                    data.* = comp_type.*;
                } else {
                    if (component.allocated and component.typeId != tid) {
                        const old_tid = component.typeId.?;
                        opaqueDestroy(world.allocator, component.data, world.types.sizeOf(old_tid), world.types.alignOf(old_tid));
                        const data = try world.allocator.create(c_type);
                        data.* = comp_type.*;
                        const oref = @as(?*anyopaque, @ptrCast(data));
                        component.data = oref;
                    }
                }
            }
        }
        component.attached = true;
        component.allocated = true;

        try component.owners.add(world.allocator, entityGlobalId(self));
        try self.owned.add(world.allocator, component);
        try world.archetypeRefresh(self);
        if (component.typeId) |ctid| world.signalComponentAdded(self, component, ctid);
    }

    pub inline fn detach(self: *Entity, component: *Component) !void {
        var world = @as(*World, @ptrCast(@alignCast(self.world)));

        component.attached = false;
        component.owners.remove(entityGlobalId(self));
        self.owned.remove(component);
        try world.archetypeRefresh(self);
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

        world.archetypes.remove(world, self);

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

    //Yields entities that own a component of `filter_type`. Implemented by
    //scanning components (O(components)) and resolving each matching component's
    //owners through the global-id OwnerSet, so it is exact across entity chunks.
    //`alive` is the component slot scan bound (CHUNK_SIZE * components_len).
    //An entity owning N matching components is yielded N times.
    pub const MaskedIterator = struct {
        ctx: *[]Entities,
        index: usize = 0,
        owner_idx: usize = 0,
        filter_type: u32,
        alive: usize = 0,
        world: *World,

        pub fn next(it: *MaskedIterator) ?*Entity {
            while (it.index < it.alive) {
                const mod = it.index / CHUNK_SIZE;
                const rem = @rem(it.index, CHUNK_SIZE);
                const component = &it.world._components[mod].sparse[rem];

                const matches = component.alive and component.owners.len > 0 and
                    (if (component.typeId) |tid| tid == it.filter_type else false);

                if (matches and it.owner_idx < component.owners.len) {
                    const k = it.owner_idx;
                    it.owner_idx += 1;
                    const gid = if (k == 0) component.owners.first else component.owners.rest.items[k - 1];
                    //Skip owners whose entity was destroyed/recycled (generation
                    //mismatch) so a stale ownership entry never yields a wrong entity.
                    if (resolveGlobalId(it.world, gid)) |entity| return entity;
                    continue;
                }

                it.index += 1;
                it.owner_idx = 0;
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
        const entities = &world._entities;
        return .{ .ctx = entities, .filter_type = world.typeId(comp_type), .alive = CHUNK_SIZE * world.components_len, .world = world };
    }

    pub const QueryIterator = struct {
        world: *World,
        include_storage: [64]u32 = undefined,
        exclude_storage: [64]u32 = undefined,
        include: []const u32 = &.{},
        exclude: []const u32 = &.{},
        arch_index: usize = 0,
        row: usize = 0,
        heap_include: ?[]u32 = null,
        heap_exclude: ?[]u32 = null,

        pub fn deinit(self: *QueryIterator, alloc: std.mem.Allocator) void {
            if (self.heap_include) |buf| alloc.free(buf);
            if (self.heap_exclude) |buf| alloc.free(buf);
            self.heap_include = null;
            self.heap_exclude = null;
        }

        pub fn next(it: *QueryIterator) ?*Entity {
            const archetypes = it.world.archetypes.list.items;
            while (it.arch_index < archetypes.len) {
                const arch = &archetypes[it.arch_index];
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
        const empty_sig: TypeSignature = .{};
        try world.archetypes.insert(world.allocator, entity, &empty_sig);
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

    try std.testing.expectEqual(@as(usize, 3), world.archetypes.count());
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
        const ct = c_type{ .id = @as(usize, @intCast(i)) + 1000, .size = 4, .alignof = 4, .name = null };
        const id = world.typeIdC(ct);
        try std.testing.expectEqual(i, id);
    }
    try std.testing.expectEqual(@as(u32, 80), world.types.count());

    var ct79 = c_type{ .id = 79 + 1000, .size = @sizeOf(u32), .alignof = @alignOf(u32), .name = null };
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
