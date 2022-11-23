const std = @import("std");
const Arena = @import("./mimalloc_arena.zig").Arena;

//If zig_probe_stack segfaults this is too high, use heap if needed.
//TODO: Use heap past 10k-20k components

const COMPONENT_CONTAINER = "Components"; //Struct containing component definitions
const CHUNK_SIZE = 1024; //Only operate on one chunk at a time

//No chunk should know of another chunk

//SuperComponents map component chunks to current layout
pub const SuperComponents = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking

    pub fn create(ctx: *SuperComponents, comptime comp_type: type) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        //TODO: This doesn't find free component slots from deleted components
        if(world._components[world.components_len - 1].len < CHUNK_SIZE) {
            return try world._components[world.components_len - 1].create(comp_type);
        } else {
            return try world.allocator.create(Component);
        }
    }

    pub inline fn count(ctx: *SuperComponents) u32 {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        var i: usize = 0;
        var total: u32 = 0;
        while(i < world.components_len) : (i += 1) {
            total += world._components[i].alive;
        }
        return total;
    }

    pub inline fn iterator(ctx: *SuperComponents) _Components.Iterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var components = &world._components[world.components_len - 1];
        return .{ .ctx = components, .alive = components.alive };
    }

    //TODO: Go through each chunk
    pub fn iteratorFilter(ctx: *SuperComponents, comptime comp_type: type) _Components.MaskedIterator {
        //get an iterator for components attached to this entity
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var components = &world._components[world.components_len - 1];
        return .{ .ctx = components,
                  .filter_type = typeToId(comp_type),
                  .alive = components.alive };
    }
};

pub const _Components = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    len: u32,
    alive: u32,
    sparse: [CHUNK_SIZE]*Component,
    sparse_data: [CHUNK_SIZE]Component,
    free_idx: u32 = 0,
    resized: u32 = 0,
    created: u32 = 0,
    entity_mask: [componentCount()]std.StaticBitSet(CHUNK_SIZE), //Owns at least one component of type

    pub const Iterator = struct {
        ctx: *const _Components,
        index: usize = 0,
        alive: u32 = 0,

        pub inline fn next(it: *Iterator) ?*Component {
            if (it.ctx.alive == 0) return null;

            const end = it.alive;
            var metadata = it.index;

            while (metadata < end) : ({
                metadata += 1;
                it.index += 1;
            }) {
                if (it.ctx.sparse[it.index].alive) {
                    var sparse_index = it.index;
                    it.index += 1;
                    return it.ctx.sparse[sparse_index];
                }
            }

            return null;
        }
    };

    pub const MaskedIterator = struct {
        ctx: *const _Components,
        index: usize = 0,
        filter_type: u32,
        alive: u32 = 0,

        pub inline fn next(it: *MaskedIterator) ?*Component {
            if (it.ctx.alive == 0) return null;

            var world = @ptrCast(*World, @alignCast(@alignOf(World), it.ctx.world));
            //TODO: Count unique types
            const end = it.ctx.alive;
            var metadata = it.index;

            while (metadata < end) : ({
                metadata += 1;
                it.index += 1;
            }) {
                if (world._entities[world.entities_len - 1].component_mask[it.filter_type].isSet(it.index)) {
                    var sparse_index = it.index;
                    it.index += 1;
                    return it.ctx.sparse[sparse_index];
                }
            }

            return null;
        }
    };

    //don't inline to avoid branch quota issues
    pub fn create(ctx: *_Components, comptime comp_type: type) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        if(ctx.alive >= CHUNK_SIZE)
            return error.NoFreeComponentSlots;

        //find end of sparse array
        var wrapped = false;
        while(ctx.sparse_data[ctx.free_idx].allocated == true) {
            if(wrapped and ctx.free_idx > CHUNK_SIZE)
                return error.NoFreeComponentSlots;

            ctx.free_idx = ctx.alive + 1;
            if(ctx.free_idx > CHUNK_SIZE - 1) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }
        
        var component = &ctx.sparse_data[ctx.free_idx];

        component.world = world;
        component.attached = false;
        component.typeId = typeToId(comp_type);
        component.id = ctx.free_idx;
        component.allocated = false;
        component.alive = true;
        component.owners = std.StaticBitSet(CHUNK_SIZE).initEmpty();
        component.type_node = .{.data = component};
        component.chunk = components_idx;

        ctx.sparse[ctx.free_idx] = component;

        ctx.free_idx += 1;
        ctx.created += 1;
        ctx.alive += 1;

        if(typeToId(comp_type) > componentCount() - 1)
            return error.ComponentNotInContainer;

        return component;
    }

    pub inline fn count(ctx: *_Components) u32 {
        //count of all living components

        return ctx.alive;
    }

    pub inline fn iterator(self: *const _Components) Iterator {
        return .{ .ctx = self, .alive = self.alive };
    }

    pub fn iteratorFilter(self: *const _Components, comptime comp_type: type) _Components.MaskedIterator {
        //get an iterator for components attached to this entity
        return .{ .ctx = self,
                  .filter_type = typeToId(comp_type),
                  .alive = self.alive };
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
        world._entities = try allocator.alloc(Entities, 1);
        world._entities[entities_idx] = Entities{.sparse = undefined,
                                  .sparse_data = undefined,
                                  .world = world,
                                  .component_mask = undefined,
                                 };
        world.systems = Systems{};
        world._components = try allocator.alloc(_Components, 1);
        world._components[components_idx] = _Components{.sparse = undefined,
                                       .sparse_data = undefined,
                                       .world = world,
                                       .len = 0,
                                       .alive = 0,
                                       .entity_mask = undefined,
                                      };
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
        
        world._components[self.chunk].alive -= 1;
        world._components[self.chunk].free_idx = self.id;

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

    pub fn iteratorFilter(self: *const Entity, comptime comp_type: type) Entity.ComponentMaskedIterator {
        //get an iterator for components attached to this entity

        return .{ .ctx = self,
                  .filter_type = typeToId(comp_type), 
                  .index = self.type_components[typeToId(comp_type)].first};
    }

    pub inline fn addComponent(self: *Entity, comptime comp_type: type, comp_val: anytype) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));
        var component = try world.components.create(comp_type);
        try self.attach(component, comp_val);
        return component;
    }

    pub inline fn getOneComponent(self: *Entity, comptime comp_type: type) ?*Component {
        if(self.type_components[typeToId(comp_type)].first != null) {
            return self.type_components[typeToId(comp_type)].first.?.data;
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
        
        //world._entities.component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, true);
        //world._components.entity_mask[@intCast(usize, component.typeId.?)].setValue(self.id, true);
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
        //self.world.entities.component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, false);
    }

    pub inline fn destroy(self: *Entity) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        self.alive = false;
        world._entities[self.chunk].alive -= 1;
        world._entities[self.chunk].free_idx = self.id;
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
        var field_ptr = @ptrCast(*T, @alignCast(@alignOf(T), component.?.data));
        return field_ptr;
}

pub const SuperEntities = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking

    pub inline fn count(ctx: *SuperEntities) u32 {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        var i: usize = 0;
        var total: u32 = 0;
        while(i < world.entities_len) : (i += 1) {
            total += world._entities[i].alive;
        }
        return total;
    }

    //TODO: This doesn't find free entity slots from deleted entities
    pub fn create(ctx: *SuperEntities) !*Entity {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        if(world._entities[world.entities_len - 1].len < CHUNK_SIZE) {
            return try world._entities[world.entities_len - 1].create();
        } else { //Create new chunk
            return try world.allocator.create(Entity);
        }
    }

    pub inline fn iterator(ctx: *SuperEntities) Entities.Iterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var entities = &world._entities[world.entities_len - 1];
        return .{ .ctx = entities, .alive = entities.alive };
    }

    pub fn iteratorFilter(ctx: *SuperEntities, comptime comp_type: type) Entities.MaskedIterator {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));
        var entities = &world._entities[world.entities_len - 1];

        //TODO: Go through each chunk
        //get an iterator for entities attached to this entity
        return .{ .ctx = entities,
                  .filter_type = typeToId(comp_type),
                  .alive = entities.alive };
    }
};

const Entities = struct {
    len: u32 = 0,
    sparse: [CHUNK_SIZE]*Entity,
    sparse_data: [CHUNK_SIZE]Entity,
    alive: u32 = 0,
    free_idx: u32 = 0,
    resized: u32 = 0,
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    created: u32 = 0,
    component_mask: [componentCount()]std.StaticBitSet(CHUNK_SIZE),

    pub const Iterator = struct {
        ctx: *const Entities,
        index: usize = 0,
        alive: u32 = 0,

        pub inline fn next(it: *Iterator) ?*Entity {
            if (it.ctx.alive == 0) return null;

            const end = it.alive;
            var metadata = it.index;

            while (metadata < end) : ({
                metadata += 1;
                it.index += 1;
            }) {
                if (it.ctx.sparse[it.index].alive) {
                    var sparse_index = it.index;
                    it.index += 1;
                    return it.ctx.sparse[sparse_index];
                }
            }

            return null;
        }
    };

    //TODO: Rewrite to use bitset iterator?
    pub const MaskedIterator = struct {
        ctx: *const Entities,
        index: usize = 0,
        filter_type: u32,
        alive: u32 = 0,

        pub fn next(it: *MaskedIterator) ?*Entity {
            if (it.ctx.alive == 0) return null;

            var world = @ptrCast(*World, @alignCast(@alignOf(World), it.ctx.world));
            //TODO: Count unique types
            const end = it.ctx.alive;

            while (it.index < end) : (it.index += 1) {
                if (world._components[world.components_len - 1].entity_mask[it.filter_type].isSet(it.index)) {
                    var sparse_index = it.index;
                    it.index += 1;
                    return it.ctx.sparse[sparse_index];
                }
            }

            return null;
        }
    };

    pub inline fn create(ctx: *Entities) !*Entity {
        //most ECS cheat here and don't allocate memory until a component is assigned

        //find end of sparse array
        var wrapped = false;
        while(ctx.sparse_data[ctx.free_idx].alive == true) {
            if(wrapped and ctx.free_idx > CHUNK_SIZE)
                return error.NoFreeEntitySlots;

            ctx.free_idx = ctx.alive + 1;
            if(ctx.free_idx > CHUNK_SIZE - 1) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }

        var entity = &ctx.sparse_data[ctx.free_idx];
        entity.id = ctx.free_idx;
        entity.alive = true;
        entity.world = ctx.world;
        entity.chunk = entities_idx;
        
        var i: usize = 0;
        while(i < componentCount()) : (i += 1) {
            var queue = std.TailQueue(*Component){};
            entity.type_components[i] = queue;
        }

        ctx.sparse[ctx.free_idx] = entity;
        ctx.alive += 1;
        ctx.free_idx += 1;
        
        return entity;
    }

    pub inline fn remove(ctx: *Entities, entity: []*Entity) void {
        //mark as removed
        for(entity[0..]) |ent| {
            if(ctx.sparse[@intCast(usize, ent.id)].alive == true) {
                ctx.sparse[@intCast(usize, ent.id)].alive = false;
                ctx.free_idx = ent.id;
                ctx.alive -= 1;
            }
        }
    }

    pub inline fn iterator(self: *const Entities) Iterator {
        return .{ .ctx = self, .alive = self.alive };
    }

    pub fn iteratorFilter(self: *Entities, comptime comp_type: type) MaskedIterator {
        //get an iterator for entities attached to this entity
        return .{ .ctx = self,
                  .filter_type = typeToId(comp_type),
                  .alive = self.alive };
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