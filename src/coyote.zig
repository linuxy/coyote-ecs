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

        var i: usize = 0;
        while (i < MAX_COMPONENTS) : (i += 1) {
            world._components[world.components_len].entity_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        }

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
            const vector_width = std.simd.suggestVectorLength(u32) orelse 4; // Or appropriate size
            var i: usize = it.index;
            while (i + vector_width <= it.alive) : (i += vector_width) {
                const mod = i / CHUNK_SIZE;
                const rems = blk: {
                    var result: @Vector(vector_width, u32) = undefined;
                    var j: u32 = 0;
                    while (j < vector_width) : (j += 1) {
                        result[j] = @intCast(@rem(i + j, CHUNK_SIZE));
                    }
                    break :blk result;
                };

                // Process multiple mask checks in parallel
                const masks = blk: {
                    var result: @Vector(vector_width, bool) = undefined;
                    var j: u32 = 0;
                    while (j < vector_width) : (j += 1) {
                        result[j] = it.world._components[mod].entity_mask[it.filter_type].isSet(rems[j]);
                    }
                    break :blk result;
                };

                // Find first match
                inline for (0..vector_width) |j| {
                    if (masks[j]) {
                        it.index = i + j + 1;
                        return &it.ctx.*[mod].sparse[@intCast(rems[j])];
                    }
                }
            }

            // Handle remaining elements
            while (i < it.alive) : (i += 1) {
                const mod = i / CHUNK_SIZE;
                const rem = @rem(i, CHUNK_SIZE);
                if (it.world._components[mod].entity_mask[it.filter_type].isSet(rem)) {
                    const sparse_index = rem;
                    it.index = i + 1;
                    return &it.ctx.*[mod].sparse[sparse_index];
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
            const vector_width = std.simd.suggestVectorLength(u32) orelse 4;
            var i: usize = it.index;

            // Ensure we don't go beyond the end_index
            const effective_end = @min(it.end_index, it.index + vector_width);

            if (i < effective_end) {
                const mod = i / CHUNK_SIZE;
                const rems = blk: {
                    var result: @Vector(vector_width, u32) = undefined;
                    var j: u32 = 0;
                    while (j < vector_width) : (j += 1) {
                        result[j] = @intCast(@rem(i + j, CHUNK_SIZE));
                    }
                    break :blk result;
                };

                // Process multiple mask checks in parallel
                const masks = blk: {
                    var result: @Vector(vector_width, bool) = undefined;
                    var j: u32 = 0;
                    while (j < vector_width) : (j += 1) {
                        result[j] = it.world._components[mod].entity_mask[it.filter_type].isSet(rems[j]);
                    }
                    break :blk result;
                };

                // Find first match
                inline for (0..vector_width) |j| {
                    if (masks[j]) {
                        it.index = i + j + 1;
                        return &it.ctx.*[mod].sparse[@intCast(rems[j])];
                    }
                }
            }

            // Handle remaining elements
            while (i < it.end_index) : (i += 1) {
                const mod = i / CHUNK_SIZE;
                const rem = @rem(i, CHUNK_SIZE);
                if (it.world._components[mod].entity_mask[it.filter_type].isSet(rem)) {
                    const sparse_index = rem;
                    it.index = i + 1;
                    return &it.ctx.*[mod].sparse[sparse_index];
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
                var component_indices: @Vector(vector_width, u32) = undefined;

                // Fill vectors with component data
                for (0..batch_size) |i| {
                    const idx = it.outer_index + i;
                    const rem = @rem(idx, CHUNK_SIZE);
                    const mod = idx / CHUNK_SIZE;
                    component_indices[i] = @intCast(rem);
                    //owner_checks[i] = it.world._entities[idx].component_mask[it.filter_type].isSet(it.entity.id);
                    owner_checks[i] = it.world._components[mod].sparse[rem].owners.isSet(it.entity.id);
                }

                // Process components that are owned by the entity
                for (0..batch_size) |i| {
                    if (owner_checks[i]) {
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
        //get an iterator for components attached to this entity
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const components = &world._components;
        return .{ .ctx = components, .filter_type = typeToId(comp_type), .components_alive = ctx.alive, .entities_alive = world.entities.alive, .world = world, .entity = entity };
    }
};

pub const _Components = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    len: u32,
    alive: u32,
    sparse: []Component,
    free_idx: u32 = 0,
    created: u32 = 0,
    entity_mask: [MAX_COMPONENTS]std.StaticBitSet(CHUNK_SIZE), //Owns at least one component of type
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
                var j: u32 = 0;
                while (j < vector_width) : (j += 1) {
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
                var j: u32 = 0;
                while (j < vector_width) : (j += 1) {
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
        component.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        component.type_node = .{ .data = component };
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
        component.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        component.type_node = .{ .data = component };
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
            world._entities[entities_idx].component_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
            world._components[components_idx].entity_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
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

        i = 0;
        while (i < self.entities_len) : (i += 1)
            self.allocator.free(self._entities[i].sparse);

        self.allocator.free(self._entities);
        self.allocator.destroy(self);
    }
};

pub const Component = struct {
    chunk: usize,
    id: u32,
    data: ?*anyopaque,
    world: ?*anyopaque,
    owners: std.StaticBitSet(CHUNK_SIZE),
    attached: bool,
    typeId: ?u32 = undefined,
    allocated: bool = false,
    alive: bool = false,
    type_node: std.DoublyLinkedList(*Component).Node,
    magic: usize = MAGIC,

    pub inline fn is(self: *const Component, comp_type: anytype) bool {
        if (self.typeId == typeToId(comp_type)) {
            return true;
        } else {
            return false;
        }
    }

    pub inline fn set(component: *Component, comptime comp_type: type, members: anytype) !void {
        const field_ptr = @as(*comp_type, @ptrCast(@alignCast(component.data)));
        inline for (std.meta.fields(@TypeOf(members))) |sets| {
            @field(field_ptr, sets.name) = @field(members, sets.name);
        }
    }

    //Detaches from all entities
    pub inline fn detach(self: *Component) void {

        //TODO: Entities mask TBD
        self.attached = false;
        self.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
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
            self.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
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
    alive: bool,
    world: ?*anyopaque,
    allocated: bool = false,

    pub inline fn addComponent(ctx: *Entity, comp_val: anytype) !*Component {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const component = try world.components.create(@TypeOf(comp_val));
        try ctx.attach(component, comp_val);
        return component;
    }

    pub inline fn getOneComponent(ctx: *Entity, comptime comp_type: type) ?*const Component {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        var it = world.components.iteratorFilterByEntity(ctx, comp_type);
        const next = it.next();
        return next;
    }

    pub fn attach(self: *Entity, component: *Component, comp_type: anytype) !void {
        const world = @as(*World, @ptrCast(@alignCast(component.world)));

        if (@sizeOf(@TypeOf(comp_type)) > 0) {
            var ref = @TypeOf(comp_type){};
            ref = comp_type;
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
        world._components[component.chunk].entity_mask[@as(usize, @intCast(component.typeId.?))].setValue(self.id, true);
        component.owners.setValue(self.id, true);
    }

    pub fn attach_c(self: *Entity, component: *Component, comp_type: *c_type) !void {
        const world = @as(*World, @ptrCast(@alignCast(component.world)));

        if (@sizeOf(@TypeOf(comp_type)) > 0) {
            var ref = @TypeOf(comp_type){};
            ref = comp_type;
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
        world._components[component.chunk].entity_mask[@as(usize, @intCast(component.typeId.?))].setValue(self.id, true);
        component.owners.setValue(self.id, true);
    }

    pub inline fn detach(self: *Entity, component: *Component) !void {
        var world = @as(*World, @ptrCast(@alignCast(self.world)));

        component.attached = false;
        component.owners.setValue(self.id, false);
        world._entities[self.chunk].component_mask[@as(usize, @intCast(component.typeId.?))].setValue(component.id, false);
    }

    pub inline fn destroy(self: *Entity) void {
        var world = @as(*World, @ptrCast(@alignCast(self.world)));

        self.alive = false;
        world._entities[self.chunk].alive -= 1;
        world._entities[self.chunk].free_idx = self.id;
        world.entities_free_idx = self.chunk;
        world.entities.alive -= 1;
    }

    pub inline fn set(self: *Entity, component: *Component, comptime comp_type: type, members: anytype) !void {
        var field_ptr = @as(*comp_type, @ptrCast(component.data));
        inline for (std.meta.fields(@TypeOf(members))) |sets| {
            @field(field_ptr, sets.name) = @field(members, sets.name);
        }
        _ = self;
    }
};

//Do not inline
pub fn typeToId(comptime T: type) u32 {
    const longId = @as(usize, @intCast(@intFromPtr(&struct {
        var x: u8 = 0;
    }.x)));

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

        var i: usize = 0;
        while (i < MAX_COMPONENTS) : (i += 1) {
            world._entities[world.entities_len].component_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
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

    //TODO: Rewrite to use bitset iterator?
    pub const MaskedIterator = struct {
        ctx: *[]Entities,
        index: usize = 0,
        filter_type: u32,
        alive: usize = 0,
        world: *World,

        pub fn next(it: *MaskedIterator) ?*Entity {
            while (it.index < it.alive) : (it.index += 1) {
                const mod = it.index / CHUNK_SIZE;
                const rem = @rem(it.index, CHUNK_SIZE);
                if (it.world._components[mod].entity_mask[it.filter_type].isSet(rem)) {
                    const sparse_index = rem;
                    it.index += 1;
                    return &it.ctx.*[mod].sparse[sparse_index];
                }
            }

            return null;
        }
    };

    pub inline fn iterator(ctx: *SuperEntities) SuperEntities.Iterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const entities = &world._entities;
        return .{ .ctx = entities, .alive = ctx.alive };
    }

    pub fn iteratorFilter(ctx: *SuperEntities, comptime comp_type: type) SuperEntities.MaskedIterator {
        const world = @as(*World, @ptrCast(@alignCast(ctx.world)));
        const entities = &world._entities;

        //TODO: Go through each chunk
        //get an iterator for entities attached to this entity
        return .{ .ctx = entities, .filter_type = typeToId(comp_type), .alive = world.components.alive, .world = world };
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
