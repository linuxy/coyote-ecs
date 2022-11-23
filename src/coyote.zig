const std = @import("std");
const Arena = @import("./mimalloc_arena.zig").Arena;

const COMPONENT_CONTAINER = "Components"; //Struct containing component definitions
const CHUNK_SIZE = 1024; //Only operate on one chunk at a time

//No chunk should know of another chunk
//Modulo hash ID->CHUNK

//SuperComponents map component chunks to current layout
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

        if(world._components[world.components_free_idx].len < CHUNK_SIZE) {
            return try world._components[world.components_free_idx].create(comp_type);
        } else {
            try ctx.expand();
            return try world._components[world.components_free_idx].create(comp_type);
        }
    }

    pub fn expand(ctx: *SuperComponents) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        var temp = try world.allocator.realloc(world._components, world.components_len + 1);
        world._components = temp;
        //std.log.info("Expanding components to {}", .{world.components_len});
        world._components[world.components_len].world = world;
        world._components[world.components_len].len = 0;
        world._components[world.components_len].alive = 0;
        world._components[world.components_len].free_idx = 0;
        world._components[world.components_len].sparse = try world.allocator.alloc(Component, CHUNK_SIZE);

        world.components_len += 1;
        world.components_free_idx = world.components_len - 1;

        components_idx = world.components_free_idx;
    }

    //TODO: By attached vs unattached
    pub inline fn iterator(ctx: *SuperComponents) _Components.Iterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var components = &world._components;
        //std.log.info("new iterator: {}", .{ctx.alive});
        return .{ .ctx = components, .alive = ctx.alive, .world = world };
    }

    //TODO: Go through each chunk
    pub fn iteratorFilter(ctx: *SuperComponents, comptime comp_type: type) _Components.MaskedIterator {
        //get an iterator for components attached to this entity
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var components = &world._components;
        return .{ .ctx = components,
                  .filter_type = typeToId(comp_type),
                  .alive = ctx.alive,
                  .world = world };
    }
};

pub const _Components = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    len: u32,
    alive: u32,
    sparse: []Component,
    free_idx: u32 = 0,
    created: u32 = 0,
    entity_mask: [componentCount()]std.StaticBitSet(CHUNK_SIZE), //Owns at least one component of type

    pub const Iterator = struct {
        ctx: *[]_Components,
        index: usize = 0,
        alive: usize = 0,
        world: *World,

        pub inline fn next(it: *Iterator) ?*Component {

            while (it.index < it.alive) : (it.index += 1) {
                var mod = it.index / CHUNK_SIZE;
                var rem = @rem(it.index, CHUNK_SIZE);
                //std.log.info("iterator: {} {}", .{mod, rem});
                if (it.ctx.*[mod].sparse[rem].alive) {
                    var sparse_index = rem;
                    it.index += 1;
                    //std.log.info("mod {} rem {} alive!", .{mod,rem});
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

        pub inline fn next(it: *MaskedIterator) ?*Component {
            //TODO: Count unique types

            while (it.index < it.alive) : (it.index += 1) {
                var mod = it.index / CHUNK_SIZE;
                var rem = @rem(it.index, CHUNK_SIZE);
                if (it.world._entities[mod].component_mask[it.filter_type].isSet(rem)) {
                    var sparse_index = rem;
                    it.index += 1;
                    return &it.ctx.*[mod].sparse[sparse_index];
                }
            }

            return null;
        }
    };

    pub inline fn count(ctx: *_Components) u32 {
        //count of all living components

        return ctx.alive;
    }

    //don't inline to avoid branch quota issues
    pub fn create(ctx: *_Components, comptime comp_type: type) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        if(ctx.alive > CHUNK_SIZE)
            return error.NoFreeComponentSlots;

        //find end of sparse array
        var wrapped = false;
        while(ctx.sparse[ctx.free_idx].allocated == true) {
            if(wrapped and ctx.free_idx > CHUNK_SIZE)
                return error.NoFreeComponentSlots;

            ctx.free_idx = ctx.alive + 1;
            if(ctx.free_idx > CHUNK_SIZE - 1) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }
        if(!wrapped)
            ctx.len += 1;

        var component = &ctx.sparse[ctx.free_idx];

        component.world = world;
        component.attached = false;
        component.typeId = typeToId(comp_type);
        component.id = ctx.free_idx;
        component.allocated = false;
        component.alive = true;
        component.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        component.type_node = .{.data = component};
        component.chunk = components_idx;

        ctx.free_idx += 1;
        ctx.created += 1;
        ctx.alive += 1;

        //std.log.info("Created component: {} in chunk: {}", .{component.id, world.components_free_idx});
        if(typeToId(comp_type) > componentCount() - 1)
            return error.ComponentNotInContainer;

        return component;
    }

    pub inline fn iterator(ctx: *const _Components) Iterator {
        return .{ .ctx = ctx, .alive = ctx.alive };
    }

    pub fn iteratorFilter(ctx: *const _Components, comptime comp_type: type) _Components.MaskedIterator {
        //get an iterator for components attached to this entity
        return .{ .ctx = ctx,
                  .filter_type = typeToId(comp_type),
                  .alive = ctx.alive };
    }
};

//Global
var types: [componentCount()]u32 = undefined;
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
    arena: Arena,

    pub fn create() !*World {
        var arena = try Arena.init();
        var allocator = arena.allocator();
        var world = allocator.create(World) catch unreachable;

        world.allocator = allocator;
        world.arena = arena;
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
        world._components[components_idx].sparse = try allocator.alloc(Component, CHUNK_SIZE);

        var i: usize = 0;
        while(i < componentCount()) {
            world._entities[entities_idx].component_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
            world._components[components_idx].entity_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
            i += 1;
        }

        return world;
    }

    pub fn destroy(self: *World) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

};

const Component = struct {
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

    pub inline fn destroy(self: *Component) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        //TODO: Destroy data? If allocated just hold to reuse.
        self.data = null;
        self.attached = false;
        self.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        self.typeId = null;
        self.allocated = false;
        self.alive = false;
        
        //std.log.info("Component destroy, chunk: {}, alive: {}", .{self.chunk, world._components[self.chunk].alive});
        world._components[self.chunk].alive -= 1;
        world._components[self.chunk].free_idx = self.id;
        world.components_free_idx = self.chunk;
        world.components.alive -= 1;
    }
};

pub const Entity = struct {
    chunk: usize,
    id: u32,
    alive: bool,
    world: ?*anyopaque,
    allocated: bool = false,
    type_components: [componentCount()]std.TailQueue(*Component),
    type_entities: [componentCount()]std.TailQueue(*Entity),

    pub const ComponentMaskedIterator = struct {
        ctx: *const Entity,

        filter_type: u32,
        index: ?*std.TailQueue(*Component).Node = null,

        pub inline fn next(it: *ComponentMaskedIterator) ?*Component {
            while (it.index) |node| : (it.index = node.next) {
                it.index = node.next;
                return node.data;
            }
            return null;
        }
    };

    pub fn iteratorFilter(ctx: *const Entity, comptime comp_type: type) Entity.ComponentMaskedIterator {
        //get an iterator for components attached to this entity

        return .{ .ctx = ctx,
                  .filter_type = typeToId(comp_type), 
                  .index = ctx.type_components[typeToId(comp_type)].first};
    }

    pub inline fn addComponent(ctx: *Entity, comptime comp_type: type, comp_val: anytype) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var component = try world.components.create(comp_type);
        try ctx.attach(component, comp_val);
        return component;
    }

    pub inline fn getOneComponent(ctx: *Entity, comptime comp_type: type) ?*Component {
        std.log.info("getOneComponent id: {} type: {}", .{ctx.id, typeToId(comp_type)});
        std.log.info("{}", .{ctx.type_components[typeToId(comp_type)]});
        if(ctx.type_components[typeToId(comp_type)].first != null) {
            return ctx.type_components[typeToId(comp_type)].first.?.data;
        } else {
            return null;
        }
    }

    //inlining this causes compiler issues
    pub fn attach(self: *Entity, component: *Component, comp_type: anytype) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), component.world));

        if(@sizeOf(@TypeOf(comp_type)) > 0) {
            var ref = @TypeOf(comp_type){};
            ref = comp_type;

            var data = try world.allocator.create(@TypeOf(comp_type));
            data.* = comp_type;
            var oref = @ptrCast(?*anyopaque, data);
            component.data = oref;
        }
        component.attached = true;
        component.allocated = true;
        
        world._entities[self.chunk].component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, true);
        world._components[component.chunk].entity_mask[@intCast(usize, component.typeId.?)].setValue(self.id, true);
        component.owners.setValue(self.id, true);

        //Link entity by component type
        var i: usize = 0;
        while(i < componentCount()) : (i += 1) {
            var queue = std.TailQueue(*Entity){};
            self.type_entities[i] = queue;
        }

        //Append to the linked list of components
        self.type_components[@intCast(usize, component.typeId.?)].append(&component.type_node);
    }

    pub inline fn detach(self: *Entity, component: *Component) !void {
        component.attached = false;
        component.owner = null;
        component.owners.setValue(self.id, false);
        self.world._entities[self.chunk].component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, false);
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
    var longId = @intCast(u32, @ptrToInt(&struct { var x: u8 = 0; }.x));

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
        type_idx += 1;
    }
    _ = T;
    return  @intCast(u32, i);
}

pub inline fn componentCount() usize {
    @setEvalBranchQuota(CHUNK_SIZE * 2);
    var idx: u32 = 0;
    inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
        const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
        if (decl.is_pub and comptime comp_eql) {
            inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                if(@typeInfo(@TypeOf(member)) == .Struct) {
                    idx += 1;
                }
            }
        }
    }

    return idx;
}

pub inline fn Cast(comptime T: type, component: ?*Component) *T {
        //std.log.info("Cast: {}", .{component.?});
        var field_ptr = @ptrCast(*T, @alignCast(@alignOf(T), component.?.data));
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
            //std.log.info("entities_free_idx: {}", .{world.entities_free_idx});
            return try world._entities[world.entities_free_idx].create();
        }
    }

    pub fn expand(ctx: *SuperEntities) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        world._entities = try world.allocator.realloc(world._entities, world.entities_len + 1);
        //std.log.info("Expanding to {}", .{world.entities_len});
        world._entities[world.entities_len].world = world;
        world._entities[world.entities_len].len = 0;
        world._entities[world.entities_len].alive = 0;
        world._entities[world.entities_len].free_idx = 0;
        world._entities[world.entities_len].sparse = try world.allocator.alloc(Entity, CHUNK_SIZE);

        var i: usize = 0;
        while(i < componentCount()) : (i += 1) {
            world._entities[world.entities_len].component_mask[i] = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        }
        world.entities_len += 1;
        world.entities_free_idx = world.entities_len - 1;
        entities_idx = world.entities_free_idx;
    }

    pub inline fn iterator(ctx: *SuperEntities) Entities.Iterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var entities = &world._entities;
        return .{ .ctx = entities, .alive = ctx.alive};
    }

    pub fn iteratorFilter(ctx: *SuperEntities, comptime comp_type: type) Entities.MaskedIterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var entities = &world._entities;

        //TODO: Go through each chunk
        //get an iterator for entities attached to this entity
        return .{ .ctx = entities,
                  .filter_type = typeToId(comp_type),
                  .alive = ctx.alive,
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
    component_mask: [componentCount()]std.StaticBitSet(CHUNK_SIZE),

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
                if (it.world._entities[mod].component_mask[it.filter_type].isSet(rem)) {
                    var sparse_index = rem;
                    it.index += 1;
                    return &it.ctx.*[mod].sparse[sparse_index];
                }
            }

            return null;
        }
    };

    pub inline fn create(ctx: *Entities) !*Entity {
        //most ECS cheat here and don't allocate memory until a component is assigned

        //find end of sparse array
        var wrapped = false;
        //std.log.info("len: {}", .{ctx.len});
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
        
        var i: usize = 0;
        while(i < componentCount()) : (i += 1) {
            var queue = std.TailQueue(*Component){};
            entity.type_components[i] = queue;
        }

        ctx.alive += 1;
        ctx.free_idx += 1;
        
        return entity;
    }

    pub inline fn iterator(ctx: *const Entities) Iterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var entities = &world._entities;
        return .{ .ctx = entities, .alive = entities.alive };
    }

    pub fn iteratorFilter(ctx: *Entities, comptime comp_type: type) MaskedIterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var entities = &world._entities;

        //get an iterator for entities attached to this entity
        return .{ .ctx = entities,
                  .filter_type = typeToId(comp_type),
                  .alive = entities.alive };
    }

    pub inline fn count(ctx: *Entities) u32 {
        //count of all living entities
        return ctx.alive;
    }
};

pub const Systems = struct {
    pub fn run(comptime f: anytype, args: anytype) !void {
        const ret = @call(.{}, f, args);
        if (@typeInfo(@TypeOf(ret)) == .ErrorUnion) try ret;
    }
};