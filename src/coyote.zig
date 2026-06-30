const std = @import("std");
const builtin = @import("builtin");

pub const MAX_COMPONENTS = 12; //Maximum number of component types, 10x runs 10x slower create O(n) TODO: Fix
pub const CHUNK_SIZE = 128; //Only operate on one chunk at a time
pub const MAGIC = 0x0DEADB33F; //Helps check for optimizer related issues

pub const allocator = std.heap.c_allocator;

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
        ctx: *[]_Components,
        inner_index: usize = 0,
        outer_index: usize = 0,
        filter_type: u32,
        entities_alive: usize = 0,
        components_alive: usize = 0,
        world: *World,
        entity: *Entity,

        pub inline fn next(it: *MaskedEntityIterator) ?*Component {
            const vector_width = std.simd.suggestVectorLength(u32) orelse 4;

            while (it.outer_index < it.components_alive) {
                // Process vector_width components at a time
                const remaining = it.components_alive - it.outer_index;
                const batch_size = @min(vector_width, remaining);

                // Prepare vectors for parallel processing
                var owner_checks: @Vector(vector_width, bool) = @splat(false);
                var component_indices: @Vector(vector_width, u32) = @splat(0);

                // Fill vectors with component data
                inline for (0..vector_width) |i| {
                    if (i < batch_size) {
                        const idx = it.outer_index + i;
                        const rem = @rem(idx, CHUNK_SIZE);
                        const mod = idx / CHUNK_SIZE;
                        component_indices[i] = @intCast(rem);
                        //owner_checks[i] = it.world._entities[idx].component_mask[it.filter_type].isSet(it.entity.id);
                        owner_checks[i] = it.world._components[mod].sparse[rem].owners.contains(entityGlobalId(it.entity));
                    }
                }

                // Process components that are owned by the entity
                inline for (0..vector_width) |i| {
                    if (i < batch_size and owner_checks[i]) {
                        const mod = (it.outer_index + i) / CHUNK_SIZE;
                        const rem = component_indices[i];

                        // Use SIMD for entity chunk processing
                        const entities_per_vector = std.simd.suggestVectorLength(u32) orelse 4;
                        var entity_idx: usize = 0;

                        while (entity_idx + entities_per_vector <= it.world.entities_len) : (entity_idx += entities_per_vector) {
                            var entity_checks: @Vector(entities_per_vector, bool) = undefined;

                            // Check multiple entities in parallel
                            inline for (0..entities_per_vector) |j| {
                                entity_checks[j] = it.world._entities[entity_idx + j].component_mask[it.filter_type].isSet(it.world._components[mod].sparse[@intCast(rem)].id);
                            }

                            // If any entity has this component
                            inline for (0..entities_per_vector) |j| {
                                if (entity_checks[j]) {
                                    it.outer_index += i + 1;
                                    return &it.ctx.*[mod].sparse[@intCast(rem)];
                                }
                            }
                        }

                        // Handle remaining entities
                        while (entity_idx < it.world.entities_len) : (entity_idx += 1) {
                            if (it.world._entities[entity_idx].component_mask[it.filter_type].isSet(it.world._components[mod].sparse[@intCast(rem)].id)) {
                                it.outer_index += i + 1;
                                return &it.ctx.*[mod].sparse[@intCast(rem)];
                            }
                        }
                    }
                }

                it.outer_index += batch_size;
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
        //get an iterator for components attached to this entity
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const components = &world._components;
        return .{ .ctx = components, .filter_type = typeToId(comp_type), .alive = CHUNK_SIZE * world.components_len, .world = world };
    }

    pub fn iteratorFilterRange(ctx: *SuperComponents, comptime comp_type: type, start_idx: usize, end_idx: usize) SuperComponents.MaskedRangeIterator {
        //get an iterator for components attached to this entity within a specific range
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const components = &world._components;
        return .{ .ctx = components, .filter_type = typeToId(comp_type), .index = start_idx, .start_index = start_idx, .end_index = end_idx, .world = world };
    }

    pub fn iteratorFilterByEntity(ctx: *SuperComponents, entity: *Entity, comptime comp_type: type) SuperComponents.MaskedEntityIterator {
        return ctx.iteratorFilterByEntityType(entity, typeToId(comp_type));
    }

    pub fn iteratorFilterByEntityType(ctx: *SuperComponents, entity: *Entity, filter_type: u32) SuperComponents.MaskedEntityIterator {
        //get an iterator for components of a given type id attached to this entity
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const components = &world._components;
        return .{ .ctx = components, .filter_type = filter_type, .components_alive = ctx.alive, .entities_alive = world.entities.alive, .world = world, .entity = entity };
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
                if (component.alive and component.typeId == typeToId(comp_type)) {
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
            if (component.alive and component.typeId == typeToId(comp_type)) {
                if (component.data) |data| {
                    const typed_data = CastData(comp_type, data);
                    processor(typed_data);
                }
            }
        }
    }

    pub fn processComponentsRangeSimd(ctx: *_Components, comptime comp_type: type, start_idx: usize, end_idx: usize, processor: fn (*comp_type) void) void {
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
                if (component.alive and component.typeId == typeToId(comp_type)) {
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
            if (component.alive and component.typeId == typeToId(comp_type)) {
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
        component.typeId = typeToId(comp_type);
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

        if (typeToId(comp_type) >= MAX_COMPONENTS)
            return error.ComponentNotInContainer;

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
        component.typeId = typeToIdC(comp_type);
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

        if (typeToIdC(comp_type) >= MAX_COMPONENTS)
            return error.ComponentNotInContainer;

        return component;
    }
};

//Global
var types: [MAX_COMPONENTS]usize = undefined;
var types_size: [MAX_COMPONENTS]usize = undefined;
var types_align: [MAX_COMPONENTS]u8 = undefined;
var type_idx: usize = 0;

//TLS
var entities_idx: usize = 0;
var components_idx: usize = 0;

pub const World = struct {
    //Superset of Entities and Systems
    entities: SuperEntities,
    components: SuperComponents,
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
        }

        world.systems = Systems{};

        world._components = try allocator.alloc(_Components, 1);
        world._components[components_idx].world = world;
        world._components[components_idx].len = 0;
        world._components[components_idx].alive = 0;
        world._components[components_idx].free_idx = 0;
        world._components[components_idx].chunk = 0;
        world._components[components_idx].sparse = try allocator.alloc(Component, CHUNK_SIZE);

        var i: usize = 0;
        while (i < MAX_COMPONENTS) {
            world._entities[entities_idx].component_mask[i] = std.StaticBitSet(CHUNK_SIZE).empty;
            i += 1;
        }

        return world;
    }

    pub fn destroy(self: *World) void {
        var it = self.components.iterator();
        while (it.next()) |component|
            component.destroy();

        self.components.gc();
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
        if (self.typeId == typeToId(comp_type)) {
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
    }

    //Removes this component from every owning entity's reverse index and then
    //clears the owner set, keeping the entity->component and component->entity
    //views consistent whenever a component is detached or destroyed.
    fn releaseOwners(self: *Component, world: *World) void {
        if (self.owners.len > 0) {
            if (resolveGlobalId(world, self.owners.first)) |e| e.owned.remove(self);
            for (self.owners.rest.items) |gid| {
                if (resolveGlobalId(world, gid)) |e| e.owned.remove(self);
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
        const world = @as(*World, @ptrCast(@alignCast(self.world)));

        if (!self.alive and self.magic == MAGIC and self.allocated) {
            opaqueDestroy(world.allocator, self.data.?, types_size[@as(usize, @intCast(self.typeId.?))], types_align[@as(usize, @intCast(self.typeId.?))]);
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

    //Returns a stable handle that can be stored and later validated with
    //`world.entities.resolve`/`isValid`, even after this slot is recycled.
    pub inline fn ref(self: *const Entity) EntityRef {
        return .{ .chunk = @intCast(self.chunk), .id = self.id, .generation = self.generation };
    }

    pub inline fn addComponent(ctx: *Entity, comp_val: anytype) !*Component {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const component = try world.components.create(@TypeOf(comp_val));
        try ctx.attach(component, comp_val);
        return component;
    }

    pub inline fn getOneComponent(ctx: *Entity, comptime comp_type: type) ?*const Component {
        return ctx.getOneComponentById(typeToId(comp_type));
    }

    //Runtime (type-id) variant of getOneComponent, used by the C API.
    //
    //Scans for a live component of `filter_type` owned by this entity. Ownership
    //is keyed by global entity id, so it is exact across multiple entity chunks.
    pub inline fn getOneComponentById(ctx: *Entity, filter_type: u32) ?*Component {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const gid = entityGlobalId(ctx);
        var ci: usize = 0;
        while (ci < world.components_len) : (ci += 1) {
            const chunk = &world._components[ci];
            var si: usize = 0;
            while (si < CHUNK_SIZE) : (si += 1) {
                const component = &chunk.sparse[si];
                if (!component.alive) continue;
                const tid = component.typeId orelse continue;
                if (tid == filter_type and component.owners.contains(gid))
                    return component;
            }
        }
        return null;
    }

    //Returns true if this entity owns at least one component of the given type.
    pub inline fn has(ctx: *Entity, comptime comp_type: type) bool {
        return ctx.hasById(typeToId(comp_type));
    }

    //Runtime (type-id) variant of has, used by the C API.
    pub inline fn hasById(ctx: *Entity, filter_type: u32) bool {
        return ctx.getOneComponentById(filter_type) != null;
    }

    //Returns a typed pointer to the data of one component of the given type
    //owned by this entity, or null if it has none.
    pub inline fn get(ctx: *Entity, comptime comp_type: type) ?*comp_type {
        const component = ctx.getOneComponentById(typeToId(comp_type)) orelse return null;
        return component.get(comp_type);
    }

    //Detaches every component of the given type from this entity. Any component
    //left without owners is destroyed so its slot can be reused (run gc to free).
    pub fn remove(ctx: *Entity, comptime comp_type: type) !void {
        return ctx.removeById(typeToId(comp_type));
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

        if (@sizeOf(@TypeOf(comp_type)) > 0) {
            if (!component.allocated) {
                const data = try world.allocator.create(@TypeOf(comp_type));
                data.* = comp_type;
                const oref = @as(?*anyopaque, @ptrCast(data));
                component.data = oref;
            } else {
                if (component.allocated and component.typeId == typeToId(@TypeOf(comp_type))) {
                    const data = CastData(@TypeOf(comp_type), component.data);
                    data.* = comp_type;
                } else {
                    if (component.allocated and component.typeId != typeToId(@TypeOf(comp_type))) {
                        opaqueDestroy(world.allocator, component.data, types_size[@as(usize, @intCast(typeToId(@TypeOf(comp_type))))], types_align[@as(usize, @intCast(typeToId(@TypeOf(comp_type))))]);
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

        world._entities[self.chunk].component_mask[@as(usize, @intCast(component.typeId.?))].setValue(component.id, true);
        try component.owners.add(world.allocator, entityGlobalId(self));
        try self.owned.add(world.allocator, component);
    }

    pub fn attach_c(self: *Entity, component: *Component, comp_type: *c_type) !void {
        const world = @as(*World, @ptrCast(@alignCast(component.world)));

        if (@sizeOf(@TypeOf(comp_type)) > 0) {
            if (!component.allocated) {
                const data = try world.allocator.create(@TypeOf(comp_type));
                data.* = comp_type;
                const oref = @as(?*anyopaque, @ptrCast(data));
                component.data = oref;
            } else {
                if (component.allocated and component.typeId == typeToId(@TypeOf(comp_type))) {
                    const data = CastData(@TypeOf(comp_type), component.data);
                    data.* = comp_type;
                } else {
                    if (component.allocated and component.typeId != typeToId(@TypeOf(comp_type))) {
                        opaqueDestroy(world.allocator, component.data, types_size[@as(usize, @intCast(typeToIdC(comp_type)))], types_align[@as(usize, @intCast(typeToIdC(comp_type)))]);
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

        world._entities[self.chunk].component_mask[@as(usize, @intCast(component.typeId.?))].setValue(component.id, true);
        try component.owners.add(world.allocator, entityGlobalId(self));
        try self.owned.add(world.allocator, component);
    }

    pub inline fn detach(self: *Entity, component: *Component) !void {
        var world = @as(*World, @ptrCast(@alignCast(self.world)));

        component.attached = false;
        component.owners.remove(entityGlobalId(self));
        self.owned.remove(component);
        world._entities[self.chunk].component_mask[@as(usize, @intCast(component.typeId.?))].setValue(component.id, false);
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
            component.owners.remove(gid);
            if (component.typeId) |tid|
                world._entities[self.chunk].component_mask[@as(usize, @intCast(tid))].setValue(component.id, false);
            if (component.owners.count() == 0)
                component.destroy();
        }
        self.owned.clear(world.allocator);

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
pub fn typeToId(comptime T: type) u32 {
    //Stable, unique-per-type key. The type name is interned once per distinct
    //type, so its pointer is a reliable identity (the previous &struct{var x}
    //trick collapsed all types to one address because it never captured T).
    const longId = @intFromPtr(@typeName(T).ptr);

    var found = false;
    var i: usize = 0;
    while (i < type_idx) : (i += 1) {
        if (types[i] == longId) {
            found = true;
            break;
        }
    }
    if (!found) {
        types[type_idx] = longId;
        types_size[type_idx] = @sizeOf(T);
        types_align[type_idx] = @alignOf(T);
        type_idx += 1;
    }
    return @as(u32, @intCast(i));
}

pub fn typeToIdC(comp_type: c_type) u32 {
    const longId = comp_type.id;

    var found = false;
    var i: usize = 0;
    while (i < type_idx) : (i += 1) {
        if (types[i] == longId) {
            found = true;
            break;
        }
    }
    if (!found) {
        types[type_idx] = longId;
        types_size[type_idx] = comp_type.size;
        types_align[type_idx] = comp_type.alignof;
        type_idx += 1;
    }
    return @as(u32, @intCast(i));
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
        }

        var i: usize = 0;
        while (i < MAX_COMPONENTS) : (i += 1) {
            world._entities[world.entities_len].component_mask[i] = std.StaticBitSet(CHUNK_SIZE).empty;
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

        //get an iterator for entities that own a component of this type
        return .{ .ctx = entities, .filter_type = typeToId(comp_type), .alive = CHUNK_SIZE * world.components_len, .world = world };
    }

    //Multi-component query: yields entities that own a component of every
    //`include` type and none of the `exclude` types.
    //
    //This is a linear (non-archetype) scan: each candidate entity is tested
    //with `Entity.hasById` per filter type, so cost scales with
    //entities * filter_types * components. Fine for modest worlds; an
    //archetype/cached implementation is a future optimization.
    pub const QueryIterator = struct {
        ctx: *[]Entities,
        world: *World,
        total: usize = 0,
        index: usize = 0,
        include_ids: [MAX_COMPONENTS]u32 = undefined,
        include_len: usize = 0,
        exclude_ids: [MAX_COMPONENTS]u32 = undefined,
        exclude_len: usize = 0,

        pub fn next(it: *QueryIterator) ?*Entity {
            while (it.index < it.total) : (it.index += 1) {
                const mod = it.index / CHUNK_SIZE;
                const rem = @rem(it.index, CHUNK_SIZE);
                const entity = &it.ctx.*[mod].sparse[rem];
                if (!entity.alive) continue;

                var match = true;
                for (it.include_ids[0..it.include_len]) |tid| {
                    if (!entity.hasById(tid)) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    for (it.exclude_ids[0..it.exclude_len]) |tid| {
                        if (entity.hasById(tid)) {
                            match = false;
                            break;
                        }
                    }
                }
                if (match) {
                    it.index += 1;
                    return entity;
                }
            }

            return null;
        }
    };

    fn newQuery(ctx: *SuperEntities) SuperEntities.QueryIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        return .{ .ctx = &world._entities, .world = world, .total = CHUNK_SIZE * world.entities_len };
    }

    //Query entities owning a component of every type in the `include` tuple,
    //e.g. `world.entities.query(.{ Apple, Orange })`.
    pub fn query(ctx: *SuperEntities, comptime include: anytype) SuperEntities.QueryIterator {
        var it = ctx.newQuery();
        inline for (include) |T| {
            it.include_ids[it.include_len] = typeToId(T);
            it.include_len += 1;
        }
        return it;
    }

    //As `query`, but also excludes entities owning any type in `exclude`,
    //e.g. `world.entities.queryExclude(.{ Apple }, .{ Orange })`.
    pub fn queryExclude(ctx: *SuperEntities, comptime include: anytype, comptime exclude: anytype) SuperEntities.QueryIterator {
        var it = ctx.query(include);
        inline for (exclude) |T| {
            it.exclude_ids[it.exclude_len] = typeToId(T);
            it.exclude_len += 1;
        }
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
    component_mask: [MAX_COMPONENTS]std.StaticBitSet(CHUNK_SIZE),

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

        ctx.alive += 1;
        ctx.free_idx += 1;

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
