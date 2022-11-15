const std = @import("std");
const Arena = @import("./mimalloc_arena.zig").Arena;

//If zig_probe_stack segfaults this is too high, use heap if needed.
//TODO: Use heap past 10k-20k components
const MAX_ENTITIES = 5000; //Maximum number of entities alive at once
const MAX_COMPONENTS = 5000; //Maximum number of components alive at once
const COMPONENT_CONTAINER = "Components"; //Struct containing component definitions
const MAX_COMPONENTS_BY_TYPE = MAX_COMPONENTS / componentCount(); //Maximum number of components of a given type alive at once

pub const _Components = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    len: u32,
    alive: u32,
    sparse: [MAX_COMPONENTS]*Component,
    sparse_data: [MAX_COMPONENTS]Component,
    free_idx: u32 = 0,
    resized: u32 = 0,
    created: u32 = 0,
    entity_mask: [componentCount()]std.StaticBitSet(MAX_ENTITIES), //Owns at least one component of type

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
                if (world.entities.component_mask[it.filter_type].isSet(it.index)) {
                    var sparse_index = it.index;
                    it.index += 1;
                    return it.ctx.sparse[sparse_index];
                }
            }

            return null;
        }
    };

    //don't inline to avoid branch quota issues
    pub fn create(ctx: *_Components, comp_type: anytype) !*Component {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), ctx.world));

        if(ctx.alive >= MAX_COMPONENTS)
            return error.NoFreeComponentSlots;

        //find end of sparse array
        var wrapped = false;
        while(ctx.sparse_data[ctx.free_idx].allocated == true) {
            if(wrapped and ctx.free_idx > MAX_COMPONENTS)
                return error.NoFreeComponentSlots;

            ctx.free_idx = ctx.alive + 1;
            if(ctx.free_idx > MAX_COMPONENTS - 1) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }
        
        var component = &ctx.sparse_data[ctx.free_idx];

        component.world = world;
        component.attached = false;
        component.typeId = null;
        component.id = ctx.free_idx;
        component.allocated = false;
        component.alive = true;
        component.owners = std.StaticBitSet(MAX_ENTITIES).initEmpty();

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

    pub inline fn iteratorFilter(self: *const _Components, comp_type: anytype) _Components.MaskedIterator {
        //get an iterator for components attached to this entity
        return .{ .ctx = self,
                  .filter_type = typeToId(comp_type),
                  .alive = self.alive };
    }
};

var types: [componentCount()]u32 = undefined;
var type_idx: usize = 0;

pub const World = struct {
    //Superset of Entities and Systems
    entities: Entities,
    components: _Components,
    systems: Systems,
    allocator: std.mem.Allocator,
    arena: Arena,

    pub fn create() !*World {
        var arena = try Arena.init();
        var allocator = arena.allocator();
        var world = allocator.create(World) catch unreachable;
        world.allocator = allocator;
        world.arena = arena;
        world.entities = Entities{.sparse = undefined,
                                  .sparse_data = undefined,
                                  .world = world,
                                  .component_mask = undefined,
                                 };
        world.systems = Systems{};
        world.components = _Components{.sparse = undefined,
                                       .sparse_data = undefined,
                                       .world = world,
                                       .len = 0,
                                       .alive = 0,
                                       .entity_mask = undefined,
                                      };
        var i: usize = 0;
        while(i < componentCount()) {
            world.entities.component_mask[i] = std.StaticBitSet(MAX_COMPONENTS_BY_TYPE).initEmpty();
            world.components.entity_mask[i] = std.StaticBitSet(MAX_ENTITIES).initEmpty();
            i += 1;
        }

        return world;
    }

    pub fn deinit(self: *World) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

const Component = struct {
    id: u32,
    data: ?*anyopaque,
    world: ?*anyopaque,
    owners: std.StaticBitSet(MAX_ENTITIES),
    attached: bool,
    typeId: ?u32 = undefined,
    allocated: bool = false,
    alive: bool = false,
    
    pub inline fn is(self: *const Component, comp_type: anytype) bool {
        if(self.typeId == typeToId(comp_type)) {
            return true;
        } else {
            return false;
        }
    }

    pub inline fn set(component: *Component, comp_type: anytype, members: anytype) !void {
        var idx: u32 = 0;
        inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
            const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
            if (decl.is_pub and comptime comp_eql) {
                inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                    if(idx == component.typeId.?) {
                        var field_ptr = @ptrCast(*comp_type, @alignCast(@alignOf(comp_type), component.data));
                        inline for (std.meta.fields(@TypeOf(members))) |sets| {
                            @field(field_ptr, sets.name) = @field(members, sets.name);
                        }
                        _ = member;
                        return;
                    }
                    idx += 1;
                }
            }
        }
        return;
    }

    //Detaches from all entities
    pub inline fn detach(self: *Component) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        self.attached = false;
        world.entities.component_mask[@intCast(usize, self.typeId.?)].setValue(self.id, false);
        self.owners = std.StaticBitSet(MAX_ENTITIES).initEmpty();
    }

    pub inline fn destroy(self: *Component) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        world.entities.component_mask[@intCast(usize, self.typeId.?)].setValue(self.id, false);

        //TODO: Destroy data
        self.data = null;
        self.attached = false;
        self.owners = std.StaticBitSet(MAX_ENTITIES).initEmpty();
        self.typeId = null;
        self.allocated = false;
        self.alive = false;
        
        world.components.alive -= 1;
        world.components.free_idx = self.id;

    }
};

pub const Entity = struct {
    id: u32,
    alive: bool,
    world: ?*anyopaque,
    allocated: bool = false,
    next_type_component: [componentCount()]?*Component,

    pub const ComponentMaskedIterator = struct {
        ctx: *const _Components,
        entity: *const Entity,

        index: usize = 0,
        filter_type: u32,
        alive: u32 = 0,

        pub inline fn next(it: *ComponentMaskedIterator) ?*Component {
            if (it.ctx.alive == 0) return null;

            //TODO: Count unique types
            const end = it.ctx.alive;
            var metadata = it.index;

            while (metadata < end) : ({
                metadata += 1;
                it.index += 1;
            }) {
                if (it.ctx.sparse[it.index].owners.isSet(it.entity.id) and it.ctx.sparse[it.index].typeId == it.filter_type) {
                    var sparse_index = it.index;
                    it.index += 1;
                    return it.ctx.sparse[sparse_index];
                }
            }

            return null;
        }
    };

    pub inline fn iteratorFilter(self: *const Entity, comp_type: anytype) Entity.ComponentMaskedIterator {
        //get an iterator for components attached to this entity
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));
        var ctx = &world.components;

        return .{ .ctx = ctx,
                  .entity = self,
                  .filter_type = typeToId(comp_type),
                  .alive = ctx.alive };
    }

    //TODO: This will only get one component
    pub inline fn getByComponent(self: *Entity, comp_type: anytype) ?*Component {
        @setEvalBranchQuota(MAX_ENTITIES * 2);
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));
        if (world.components.entity_mask[typeToId(comp_type)].isSet(self.id)) { //Yes it owns one, search for it
            var it = iteratorFilter(self, comp_type);
            return it.next().?;
        } else {
            return null;
        }
    }

    pub inline fn remove(self: *Entity) void {
        if(self.alive == true) {
            self.alive = false;
            self.world.entities.alive -= 1;
            self.world.entities.free_idx = self.id;
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
        component.typeId = typeToId(comp_type);
        component.allocated = true;
        
        world.entities.component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, true);
        world.components.entity_mask[@intCast(usize, component.typeId.?)].setValue(self.id, true);
        component.owners.setValue(self.id, true);

        //Start the linked list of components
        if(self.next_type_component[typeToId(comp_type)] == null)
            self.next_type_component[typeToId(comp_type)] = component;
    }

    pub inline fn detach(self: *Entity, component: *Component) !void {
        component.attached = false;
        component.owner = null;
        self.world.entities.component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, false);
    }

    pub inline fn destroy(self: *Entity) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        self.alive = false;
        world.entities.alive -= 1;
    }

    pub inline fn set(self: *Entity, component: *Component, comp_type: anytype, members: anytype) !void {
        var idx: u32 = 0;
        inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
            const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
            if (decl.is_pub and comptime comp_eql) {
                inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                    if(idx == component.typeId.?) {
                        var field_ptr = @ptrCast(*comp_type, @alignCast(@alignOf(comp_type), component.data));
                        inline for (std.meta.fields(@TypeOf(members))) |sets| {
                            @field(field_ptr, sets.name) = @field(members, sets.name);
                        }
                        _ = member;
                        return;
                    }
                    idx += 1;
                }
            }
        }
        _ = self;
        return;
    }
};

//Do not inline
pub fn typeToId(T: anytype) u32 {
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
    @setEvalBranchQuota(MAX_COMPONENTS * 2);
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

pub inline fn Cast(comptime T: type) type {
    return struct {
        pub inline fn get(component: *Component) ?*T {
            var field_ptr = @ptrCast(*T, @alignCast(@alignOf(T), component.data));
            return field_ptr;
        }
    };
}

const Entities = struct {
    len: u32 = 0,
    sparse: [MAX_ENTITIES]*Entity,
    sparse_data: [MAX_ENTITIES]Entity,
    alive: u32 = 0,
    free_idx: u32 = 0,
    resized: u32 = 0,
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    created: u32 = 0,
    component_mask: [componentCount()]std.StaticBitSet(MAX_COMPONENTS_BY_TYPE),

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

        pub inline fn next(it: *MaskedIterator) ?*Entity {
            if (it.ctx.alive == 0) return null;

            var world = @ptrCast(*World, @alignCast(@alignOf(World), it.ctx.world));
            //TODO: Count unique types
            const end = it.ctx.alive;
            var metadata = it.index;

            while (metadata < end) : ({
                metadata += 1;
                it.index += 1;
            }) {
                if (world.entities.component_mask[it.filter_type].isSet(it.index)) {
                    var sparse_index = it.index;
                    it.index += 1;
                    return it.ctx.sparse[sparse_index - 1];
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
            if(wrapped and ctx.free_idx > MAX_ENTITIES)
                return error.NoFreeEntitySlots;

            ctx.free_idx = ctx.alive + 1;
            if(ctx.free_idx > MAX_ENTITIES - 1) {
                ctx.free_idx = 0;
                wrapped = true;
            }
        }

        var entity = &ctx.sparse_data[ctx.free_idx];
        entity.id = ctx.free_idx;
        entity.alive = true;
        entity.world = ctx.world;

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

    pub inline fn iteratorFilter(self: *Entities, comp_type: anytype) MaskedIterator {
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