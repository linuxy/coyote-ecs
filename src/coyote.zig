const std = @import("std");
const builtin = @import("builtin");

const rpmalloc = @import("rpmalloc");
const Rp = @import("rpmalloc").RPMalloc(.{});

pub const MAX_COMPONENTS = 12;     //Maximum number of component types, 10x runs 10x slower create O(n) TODO: Fix
pub const CHUNK_SIZE = 128;        //Only operate on one chunk at a time
pub const MAGIC = 0x0DEADB33F; //Helps check for optimizer related issues

pub const allocator = if(builtin.os.tag == .windows) std.heap.c_allocator else Rp.allocator();

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
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        var i: usize = 0;
        var total: u32 = 0;
        while(i < world.components_len) : (i += 1) {
            total += world._components[i].alive;
        }
        return total;
    }

    pub fn create(ctx: *SuperComponents, comptime comp_type: type) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        defer ctx.alive += 1;

        var i: usize = 0;
        var free: usize = 0;
        while(i < world.components_len) : (i += 1) {
            if(world._components[i].alive < CHUNK_SIZE) {
                free = i;
                break;
            }
        }

        if(world._components[free].alive < CHUNK_SIZE) {
            var component = try world._components[free].create(comp_type);
            return component;
        } else {
            try ctx.expand();
            var component = try world._components[world.components_len - 1].create(comp_type);
            return component;
        }
    }

    pub fn create_c(ctx: *SuperComponents, comp_type: c_type) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        defer ctx.alive += 1;

        var i: usize = 0;
        var free: usize = 0;
        while(i < world.components_len) : (i += 1) {
            if(world._components[i].alive < CHUNK_SIZE) {
                free = i;
                break;
            }
        }

        if(world._components[free].alive < CHUNK_SIZE) {
            var component = try world._components[free].create_c(comp_type);
            return component;
        } else {
            try ctx.expand();
            var component = try world._components[world.components_len - 1].create_c(comp_type);
            return component;
        }
    }

    pub fn expand(ctx: *SuperComponents) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        var temp = try world.allocator.realloc(world._components, world.components_len + 1);
        world._components = temp;
        world._components[world.components_len].world = world;
        world._components[world.components_len].len = 0;
        world._components[world.components_len].alive = 0;
        world._components[world.components_len].free_idx = 0;
        world._components[world.components_len].created = 0;
        world._components[world.components_len].chunk = world.components_len;
        world._components[world.components_len].sparse = try world.allocator.alloc(Component, CHUNK_SIZE);

        var i: usize = 0;
        while(i < MAX_COMPONENTS) : (i += 1) {
            world._components[world.components_len].entity_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        }

        world.components_len += 1;
        world.components_free_idx = world.components_len - 1;

        components_idx = world.components_free_idx;
    }

    pub fn gc(ctx: *SuperComponents) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var i: usize = 0;
        var j: usize = 0;
        while(i < world.components_len) : (i += 1) {
            while(j < CHUNK_SIZE) : (j += 1) {
                if(world._components[i].sparse[j].allocated and !world._components[i].sparse[j].alive) {
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
                var mod = it.index / CHUNK_SIZE;
                var rem = @rem(it.index, CHUNK_SIZE);
                if (it.ctx.*[mod].sparse[rem].alive) {
                    var sparse_index = rem;
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
            //TODO: Count unique types

            while (it.index < it.alive) : (it.index += 1) {
                var mod = it.index / CHUNK_SIZE;
                var rem = @rem(it.index, CHUNK_SIZE);
                if (it.world._components[mod].sparse[rem].typeId == it.filter_type) {
                    var sparse_index = rem;
                    it.index += 1;
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
            //TODO: Count unique types

            //Scan all components in every chunk, find the first matching component type owned by the entity
            while (it.outer_index < it.components_alive) : (it.outer_index += 1) {
                var mod = it.outer_index / CHUNK_SIZE;
                var rem = @rem(it.outer_index, CHUNK_SIZE);
                if (it.world._components[mod].sparse[rem].owners.isSet(it.entity.id)) { //Found a component matching type, check all chunks for entities
                    var inner: usize = 0;
                    while(inner < it.world.entities_len) : (inner += 1) {
                         if(it.world._entities[inner].component_mask[it.filter_type].isSet(it.world._components[mod].sparse[rem].id)) {
                            var sparse_index = rem;
                            it.outer_index += 1;
                            return &it.ctx.*[mod].sparse[sparse_index];
                        }
                    }
                }
            }
            return null;
        }
    };

    //TODO: By attached vs unattached
    pub inline fn iterator(ctx: *SuperComponents) SuperComponents.Iterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var components = &world._components;
        return .{ .ctx = components, .index = 0, .alive = CHUNK_SIZE * world.components_len, .world = world };
    }

    pub fn iteratorFilter(ctx: *SuperComponents, comptime comp_type: type) SuperComponents.MaskedIterator {
        //get an iterator for components attached to this entity
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var components = &world._components;
        return .{ .ctx = components,
                  .filter_type = typeToId(comp_type),
                  .alive = CHUNK_SIZE * world.components_len,
                  .world = world };
    }

    pub fn iteratorFilterByEntity(ctx: *SuperComponents, entity: *Entity, comptime comp_type: type) SuperComponents.MaskedEntityIterator {
        //get an iterator for components attached to this entity
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var components = &world._components;
        return .{ .ctx = components,
                  .filter_type = typeToId(comp_type),
                  .components_alive = ctx.alive,
                  .entities_alive = world.entities.alive,
                  .world = world,
                  .entity = entity };
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
        //count of all living components

        return ctx.alive;
    }

    pub fn create(ctx: *_Components, comptime comp_type: type) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        if(ctx.alive > CHUNK_SIZE)
            return error.NoFreeComponentSlots;

        if(ctx.free_idx >= CHUNK_SIZE)
            ctx.free_idx = 0;

        //find end of sparse array
        var wrapped = false;
        while(ctx.sparse[ctx.free_idx].alive == true) {
            if(wrapped and ctx.free_idx > CHUNK_SIZE)
                return error.NoFreeComponentSlots;

            ctx.free_idx += 1;
            if(ctx.free_idx >= CHUNK_SIZE) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }
        if(!wrapped)
            ctx.len += 1;

        var component = &ctx.sparse[ctx.free_idx];

        component.world = world;
        component.attached = false;
        component.magic = MAGIC;
        
        //Optimize: Match free indexes to like components
        if(component.allocated and component.typeId != null and component.typeId != typeToId(comp_type))
            opaqueDestroy(world.allocator, component.data.?, types_size[typeToId(comp_type)], types_align[typeToId(comp_type)]);

        if(component.typeId != typeToId(comp_type))
            component.allocated = false;

        component.typeId = typeToId(comp_type);
        component.id = ctx.free_idx;
        component.alive = true;
        component.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        component.type_node = .{.data = component};
        component.chunk = ctx.chunk;

        ctx.free_idx += 1;
        ctx.created += 1;
        ctx.alive += 1;

        if(typeToId(comp_type) > MAX_COMPONENTS - 1)
            return error.ComponentNotInContainer;

        return component;
    }

    pub fn create_c(ctx: *_Components, comp_type: c_type) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        if(ctx.alive > CHUNK_SIZE)
            return error.NoFreeComponentSlots;

        if(ctx.free_idx >= CHUNK_SIZE)
            ctx.free_idx = 0;

        //find end of sparse array
        var wrapped = false;
        while(ctx.sparse[ctx.free_idx].alive == true) {
            if(wrapped and ctx.free_idx > CHUNK_SIZE)
                return error.NoFreeComponentSlots;

            ctx.free_idx += 1;
            if(ctx.free_idx >= CHUNK_SIZE) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }
        if(!wrapped)
            ctx.len += 1;

        var component = &ctx.sparse[ctx.free_idx];

        component.world = world;
        component.attached = false;
        component.magic = MAGIC;
        
        //Optimize: Match free indexes to like components
        if(component.allocated and component.typeId != null and component.typeId != typeToIdC(comp_type))
            opaqueDestroy(world.allocator, component.data.?, types_size[typeToIdC(comp_type)], types_align[typeToIdC(comp_type)]);

        if(component.typeId != typeToIdC(comp_type))
            component.allocated = false;

        component.typeId = typeToIdC(comp_type);
        component.id = ctx.free_idx;
        component.alive = true;
        component.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        component.type_node = .{.data = component};
        component.chunk = ctx.chunk;

        ctx.free_idx += 1;
        ctx.created += 1;
        ctx.alive += 1;

        if(typeToIdC(comp_type) > MAX_COMPONENTS - 1)
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
        if(builtin.os.tag != .windows)
            try Rp.init(null, .{});

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
        while(i < MAX_COMPONENTS) {
            world._entities[entities_idx].component_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
            world._components[components_idx].entity_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
            i += 1;
        }

        return world;
    }

    pub fn destroy(self: *World) void {
        var it = self.components.iterator();
        while(it.next()) |component|
            component.destroy();

        self.components.gc();
        var i: usize = 0;
        while(i < self.components_len) : (i += 1)
            self.allocator.free(self._components[i].sparse);

        self.allocator.free(self._components);

        i = 0;
        while(i < self.entities_len) : (i += 1)
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
    type_node: std.TailQueue(*Component).Node,
    magic: usize = MAGIC,

    pub inline fn is(self: *const Component, comp_type: anytype) bool {
        if(self.typeId == typeToId(comp_type)) {
            return true;
        } else {
            return false;
        }
    }

    pub inline fn set(component: *Component, comptime comp_type: type, members: anytype) !void {
        var field_ptr = @ptrCast(*comp_type, @alignCast(@alignOf(comp_type), component.data));
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
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        if(!self.alive and self.magic == MAGIC and self.allocated) {
            opaqueDestroy(world.allocator, self.data.?, types_size[@intCast(usize, self.typeId.?)], types_align[@intCast(usize, self.typeId.?)]);
            self.allocated = false;
        }
    }

    pub inline fn destroy(self: *Component) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        //TODO: Destroy data? If allocated just hold to reuse.
        if(self.alive and self.magic == MAGIC) {
            self.attached = false;
            self.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
            self.alive = false;

            if(world._components[self.chunk].alive > 0)
                world._components[self.chunk].alive -= 1;

            world._components[self.chunk].free_idx = self.id;
            world.components_free_idx = self.chunk;

            if(world.components.alive > 0)
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
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var component = try world.components.create(@TypeOf(comp_val));
        try ctx.attach(component, comp_val);
        return component;
    }

    pub inline fn getOneComponent(ctx: *Entity, comptime comp_type: type) ?*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var it = world.components.iteratorFilterByEntity(ctx, comp_type);
        var next = it.next();
        return next;
    }

    pub fn attach(self: *Entity, component: *Component, comp_type: anytype) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), component.world));

        if(@sizeOf(@TypeOf(comp_type)) > 0) {
            var ref = @TypeOf(comp_type){};
            ref = comp_type;
            if(!component.allocated) {
                var data = try world.allocator.create(@TypeOf(comp_type));
                data.* = comp_type;
                var oref = @ptrCast(?*anyopaque, data);
                component.data = oref;
            } else {
                if(component.allocated and component.typeId == typeToId(@TypeOf(comp_type))) {
                    var data = CastData(@TypeOf(comp_type), component.data);
                    data.* = comp_type;
                } else {
                    if(component.allocated and component.typeId != typeToId(@TypeOf(comp_type))) {
                        opaqueDestroy(world.allocator, component.data, types_size[@intCast(usize, typeToId(@TypeOf(comp_type)))], types_align[@intCast(usize, typeToId(@TypeOf(comp_type)))]);
                        var data = try world.allocator.create(@TypeOf(comp_type));
                        data.* = comp_type;
                        var oref = @ptrCast(?*anyopaque, data);
                        component.data = oref;
                    }
                }
            }
        }
        component.attached = true;
        component.allocated = true;
        
        world._entities[self.chunk].component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, true);
        world._components[component.chunk].entity_mask[@intCast(usize, component.typeId.?)].setValue(self.id, true);
        component.owners.setValue(self.id, true);
    }

    pub fn attach_c(self: *Entity, component: *Component, comp_type: *c_type) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), component.world));

        if(@sizeOf(@TypeOf(comp_type)) > 0) {
            var ref = @TypeOf(comp_type){};
            ref = comp_type;
            if(!component.allocated) {
                var data = try world.allocator.alloc(u1, comp_type.size);
                data.* = comp_type;
                var oref = @ptrCast(?*anyopaque, data);
                component.data = oref;
            } else {
                if(component.allocated and component.typeId == typeToId(@TypeOf(comp_type))) {
                    var data = CastData(@TypeOf(comp_type), component.data);
                    data.* = comp_type;
                } else {
                    if(component.allocated and component.typeId != typeToId(@TypeOf(comp_type))) {
                        opaqueDestroy(world.allocator, component.data, types_size[@intCast(usize, typeToIdC(comp_type))], types_align[@intCast(usize, typeToIdC(comp_type))]);
                        var data = try world.allocator.alloc(u1, comp_type.size);
                        data.* = comp_type;
                        var oref = @ptrCast(?*anyopaque, data);
                        component.data = oref;
                    }
                }
            }
        }
        component.attached = true;
        component.allocated = true;
        
        world._entities[self.chunk].component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, true);
        world._components[component.chunk].entity_mask[@intCast(usize, component.typeId.?)].setValue(self.id, true);
        component.owners.setValue(self.id, true);
    }

    pub inline fn detach(self: *Entity, component: *Component) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        component.attached = false;
        component.owners.setValue(self.id, false);
        world._entities[self.chunk].component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, false);
    }

    pub inline fn destroy(self: *Entity) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        self.alive = false;
        world._entities[self.chunk].alive -= 1;
        world._entities[self.chunk].free_idx = self.id;
        world.entities_free_idx = self.chunk;
        world.entities.alive -= 1;
    }

    pub inline fn set(self: *Entity, component: *Component, comptime comp_type: type, members: anytype) !void {
        var field_ptr = @ptrCast(*comp_type, @alignCast(@alignOf(comp_type), component.data));
        inline for (std.meta.fields(@TypeOf(members))) |sets| {
            @field(field_ptr, sets.name) = @field(members, sets.name);
        }
        _ = self;
    }
};

//Do not inline
pub fn typeToId(comptime T: type) u32 {
    var longId = @intCast(usize, @ptrToInt(&struct { var x: u8 = 0; }.x));

    var found = false;
    var i: usize = 0;
    while(i < type_idx) : (i += 1) {
        if(types[i] == longId) {
            found = true;
            break;
        }
    }
    if(!found) {
        types[type_idx] = longId;
        types_size[type_idx] = @sizeOf(T);
        types_align[type_idx] = @alignOf(T);
        type_idx += 1;
    }
    return  @intCast(u32, i);
}

pub fn typeToIdC(comp_type: c_type) u32 {
    var longId = comp_type.id;

    var found = false;
    var i: usize = 0;
    while(i < type_idx) : (i += 1) {
        if(types[i] == longId) {
            found = true;
            break;
        }
    }
    if(!found) {
        types[type_idx] = longId;
        types_size[type_idx] = comp_type.size;
        types_align[type_idx] = comp_type.alignof;
        type_idx += 1;
    }
    return @intCast(u32, i);
}

pub inline fn Cast(comptime T: type, component: ?*Component) *T {
        var field_ptr = @ptrCast(*T, @alignCast(@alignOf(T), component.?.data));
        return field_ptr;
}

pub inline fn CastData(comptime T: type, component: ?*anyopaque) *T {
        var field_ptr = @ptrCast(*T, @alignCast(@alignOf(T), component));
        return field_ptr;
}

pub const SuperEntities = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    alive: usize,

    pub inline fn count(ctx: *SuperEntities) u32 {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        var i: usize = 0;
        var total: u32 = 0;
        while(i < world.entities_len) : (i += 1) {
            total += world._entities[i].alive;
        }
        return total;
    }

    pub fn create(ctx: *SuperEntities) !*Entity {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        defer ctx.alive += 1;

        if(world._entities[world.entities_free_idx].len < CHUNK_SIZE) {
            return try world._entities[world.entities_free_idx].create();
        } else { //Create new chunk
            try ctx.expand();
            return try world._entities[world.entities_free_idx].create();
        }
    }

    pub fn expand(ctx: *SuperEntities) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        world._entities = try world.allocator.realloc(world._entities, world.entities_len + 1);
        world._entities[world.entities_len].world = world;
        world._entities[world.entities_len].len = 0;
        world._entities[world.entities_len].alive = 0;
        world._entities[world.entities_len].created = 0;
        world._entities[world.entities_len].free_idx = 0;
        world._entities[world.entities_len].sparse = try world.allocator.alloc(Entity, CHUNK_SIZE);

        var i: usize = 0;
        while(i < MAX_COMPONENTS) : (i += 1) {
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
                var mod = it.index / CHUNK_SIZE;
                var rem = @rem(it.index, CHUNK_SIZE);
                if (it.ctx.*[mod].sparse[rem].alive) {
                    var sparse_index = rem;
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
                var mod = it.index / CHUNK_SIZE;
                var rem = @rem(it.index, CHUNK_SIZE);
                if (it.world._components[mod].entity_mask[it.filter_type].isSet(rem)) {
                    var sparse_index = rem;
                    it.index += 1;
                    return &it.ctx.*[mod].sparse[sparse_index];
                }
            }

            return null;
        }
    };

    pub inline fn iterator(ctx: *SuperEntities) SuperEntities.Iterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var entities = &world._entities;
        return .{ .ctx = entities, .alive = ctx.alive};
    }

    pub fn iteratorFilter(ctx: *SuperEntities, comptime comp_type: type) SuperEntities.MaskedIterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var entities = &world._entities;

        //TODO: Go through each chunk
        //get an iterator for entities attached to this entity
        return .{ .ctx = entities,
                  .filter_type = typeToId(comp_type),
                  .alive = world.components.alive,
                  .world = world };
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
        while(ctx.sparse[ctx.free_idx].alive == true) {
            if(wrapped and ctx.free_idx > CHUNK_SIZE)
                return error.NoFreeEntitySlots;

            ctx.free_idx = ctx.alive + 1;
            if(ctx.free_idx > CHUNK_SIZE - 1) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }

        if(!wrapped)
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
        if (@typeInfo(@TypeOf(ret)) == .ErrorUnion) try ret;
    }
};

pub fn opaqueDestroy(self: std.mem.Allocator, ptr: anytype, sz: usize, alignment: u8) void {
    const non_const_ptr = @intToPtr([*]u8, @ptrToInt(ptr));
    self.rawFree(non_const_ptr[0..sz], std.math.log2(alignment), @returnAddress());
}