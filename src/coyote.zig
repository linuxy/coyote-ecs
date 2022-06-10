const std = @import("std");

var allocator = std.heap.c_allocator;

const MAX_ENTITIES = 96000; //Maximum number of entities alive at once
const MAX_COMPONENTS = 48000; //Maximum number of components alive at once
const COMPONENT_CONTAINER = "Components"; //Struct containing component definitions

pub const _Components = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    len: u32,
    alive: u32,
    sparse: [MAX_ENTITIES]*Component,
    sparse_data: [MAX_ENTITIES]Component,
    free_idx: u32 = 0,
    resized: u32 = 0,
    created: u32 = 0,

    pub const Iterator = struct {
        ctx: *const _Components,
        index: usize = 0,
        alive: u32 = 0,

        pub fn next(it: *Iterator) ?*Component {
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

        pub fn next(it: *MaskedIterator) ?*Component {
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

    pub inline fn create(ctx: *_Components, comp_type: anytype) !*Component {
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

pub const World = struct {
    //Superset of Entities and Systems
    entities: Entities,
    components: _Components,
    systems: Systems,

    pub fn create() *World {
        var world = allocator.create(World) catch unreachable;
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
                                      };
        var i: usize = 0;
        while(i < componentCount()) {
            world.entities.component_mask[i] = std.StaticBitSet(MAX_COMPONENTS).initEmpty();
            i += 1;
        }
        return world;
    }
};

const Component = struct {
    id: u32,
    data: ?*anyopaque,
    world: ?*anyopaque,
    owner: ?u32,
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

    pub inline fn detach(self: *Component) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        self.attached = false;
        self.owner = null;
        world.entities.component_mask[@intCast(usize, self.typeId.?)].setValue(self.id, false);   
    }

    pub inline fn destroy(self: *Component) void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), self.world));

        world.entities.component_mask[@intCast(usize, self.typeId.?)].setValue(self.id, false);

        self.data = null;
        self.attached = false;
        self.owner = null;
        self.typeId = null;
        self.allocated = false;
        self.alive = false;
        
        world.components.alive -= 1;
        world.components.free_idx = self.id;
    }
};

const Entity = struct {
    id: u32,
    alive: bool,
    world: ?*anyopaque,
    allocated: bool = false,

    pub inline fn remove(self: *Entity) void {
        if(self.alive == true) {
            self.alive = false;
            self.world.entities.alive -= 1;
            self.world.entities.free_idx = self.id;
        }
    }

    pub inline fn attach(self: *Entity, component: *Component, comp_type: anytype) !void {
        var world = @ptrCast(*World, @alignCast(@alignOf(World), component.world));

        if(@sizeOf(@TypeOf(comp_type)) > 0) {
            var ref = @TypeOf(comp_type){};
            ref = comp_type;

            var oref = @ptrCast(?*anyopaque, &ref);
            component.data = oref;
        }
        component.attached = true;
        component.owner = self.id;
        component.typeId = typeToId(comp_type);
        component.allocated = true;
        
        world.entities.component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, true);
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

    pub fn get(self: *Entity, comptime T: type) type {
        _ = self;
        _ = T;
    }

    pub inline fn iterator(self: *const Entities) Entities.Iterator {
        return .{ .ctx = self, .alive = self.alive };
    }

    pub inline fn filteredIterator(self: *Entity, comp_type: anytype) _Components.MaskedIterator {
        //get an iterator for components attached to this entity
        return .{ .ctx = self,
                  .filter_type = typeToId(comp_type),
                  .alive = self.alive };
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

pub inline fn typeToId(t: anytype) u32 {
    var idx: u32 = 0;
    inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
        const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
        if (decl.is_pub and comptime comp_eql) {
            inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                const comp_idx = comptime std.mem.indexOf(u8, @typeName(@TypeOf(t)), member.name);
                if(comp_idx != null) {
                    break;
                }
                idx += 1;
            }
        }
    }

    return idx;
}

pub inline fn idEqualsType(id: u32, t: anytype) bool {
    var idx: u32 = 0;
    inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
        const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
        if (decl.is_pub and comptime comp_eql) {
            inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                if(idx == id and std.mem.indexOf(u8, @typeName(t), member.name) != null) {
                    return true;
                }
                idx += 1;
            }
        }
    }

    return false;
}

pub inline fn componentCount() usize {
    var idx: u32 = 0;
    inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
        const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
        if (decl.is_pub and comptime comp_eql) {
            inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                if(@typeInfo(@TypeOf(member)) == .Struct) {
                    idx += 1;
                    _ = member;
                }
            }
        }
    }

    return idx;
}

pub inline fn Cast(comptime T: type) type {
    return struct {
        pub fn get(component: *Component) ?*T {
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
    component_mask: [componentCount()]std.StaticBitSet(MAX_COMPONENTS),

    pub const Iterator = struct {
        ctx: *const Entities,
        index: usize = 0,
        alive: u32 = 0,

        pub fn next(it: *Iterator) ?*Entity {
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

    pub inline fn count(ctx: *Entities) u32 {
        //count of all living entities
        return ctx.alive;
    }
};

pub const Systems = struct {
    pub fn run(comptime f: anytype, args: anytype) void {
        @call(.{}, f, args);
    }
};