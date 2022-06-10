const std = @import("std");

var allocator = std.heap.c_allocator;

const MAX_ENTITIES = 96000; //Maximum number of entities alive at once
const MAX_COMPONENTS = 48000; //Maximum number of components alive at once
const COMPONENT_CONTAINER = "Comp"; //Struct containing component definitions
const PARALLELISM = 8;

//Components, must have default values
pub const Comp = struct {
    pub const Apple = struct {
        color: u32 = 0,
        ripe: bool = false,
        harvested: bool = false,
    };

    pub const Orange = struct {
        color: u32 = 0,
        ripe: bool = false,
        harvested: bool = false,
    };
};

pub fn main() !void {
    //Create a world
    var world = World.create();

    //Create an entity
    var anOrange = try world.entities.create();
    var anApple = try world.entities.create();
    std.log.info("Created an Orange ID: {}", .{anOrange.id});

    //Create a unique component
    var orangeComponent = try world.components.create(Comp.Orange{});
    var appleComponent = try world.components.create(Comp.Apple{});

    //Attach and assign a component. Do not use an anonymous struct.
    try anOrange.attach(orangeComponent, Comp.Orange{.color = 0, .ripe = false, .harvested = false});
    try anApple.attach(appleComponent, Comp.Apple{.color = 0, .ripe = false, .harvested = false});

    //Create 20k entities and attach 20k unique components
    var i: usize = 0;
    while(i < 20000) : (i += 1) {
        var anEntity = try world.entities.create();
        var anOrangeComponent = try world.components.create(Comp.Orange{});
        try anEntity.attach(anOrangeComponent, Comp.Orange{.color = 1, .ripe = false, .harvested = false});
    }

    //Filter entities by component
    var it = world.components.iteratorFilter(Comp.Orange{});
    i = 0;
    while(it.next()) |component| : (i += 1) {
        _ = component;
    }
    std.log.info("Orange components: {}", .{i});

    Systems.run(Grow, .{world});
    Systems.run(Harvest, .{world});
    Systems.run(Raze, .{world});

    std.log.info("Entities: {}", .{world.entities.count()});
    std.log.info("Components: {}", .{world.components.count()});
}

pub const Components = struct {
    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    len: u32,
    alive: u32,
    sparse: [MAX_ENTITIES]*Component,
    sparse_data: [MAX_ENTITIES]Component,
    free_idx: u32 = 0,
    resized: u32 = 0,
    created: u32 = 0,

    pub const Iterator = struct {
        ctx: *const Components,
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
        ctx: *const Components,
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

    pub inline fn create(ctx: *Components, comp_type: anytype) !*Component {
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

    pub inline fn count(ctx: *Components) u32 {
        //count of all living components

        return ctx.alive;
    }

    pub inline fn iterator(self: *const Components) Iterator {
        return .{ .ctx = self, .alive = self.alive };
    }

    pub inline fn iteratorFilter(self: *const Components, comp_type: anytype) Components.MaskedIterator {
        //get an iterator for components attached to this entity
        return .{ .ctx = self,
                  .filter_type = typeToId(comp_type),
                  .alive = self.alive };
    }
};

pub fn Grow(world: *World) void {
    var it = world.components.iterator();
    var i: u32 = 0;
    while(it.next()) |component| : (i += 1) {
        if(component.is(Comp.Orange{})) {
            try component.set(Comp.Orange, .{.ripe = true});
        }

        if(component.is(Comp.Apple{})) {
            try component.set(Comp.Apple, .{.ripe = true});
        }

        //Fruits fall from the tree
        component.detach();
    }
    std.log.info("Fruits grown: {}", .{i});
}

pub fn Harvest(world: *World) void {
    var it = world.components.iterator();
    var i: u32 = 0;
    while(it.next()) |component| {
        //async schedule in fiber
        //yield

        if(component.is(Comp.Orange{})) {
            if(Cast(Comp.Orange).get(component).?.ripe == true) {
                try component.set(Comp.Orange, .{.harvested = true});
                i += 1;
            }
        }
        if(component.is(Comp.Apple{})) {
            if(Cast(Comp.Apple).get(component).?.ripe == true) {
                try component.set(Comp.Apple, .{.harvested = true});
                i += 1;
            }
        }
        component.destroy();
    }
    
    std.log.info("Fruits harvested: {}", .{i});
}

pub fn Raze(world: *World) void {
    var it = world.entities.iterator();
    var i: u32 = 0;

    while(it.next()) |entity| {
        entity.destroy();
        i += 1;
    }

    std.log.info("Entities destroyed: {}", .{i});
}

const World = struct {
    //Superset of Entities and Systems
    entities: Entities,
    components: Components,
    systems: Systems,

    pub fn create() *World {
        var world = allocator.create(World) catch unreachable;
        world.entities = Entities{.sparse = undefined,
                                  .sparse_data = undefined,
                                  .world = world,
                                  .component_mask = undefined,
                                 };
        world.systems = Systems{};
        world.components = Components{.sparse = undefined,
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

    pub inline fn filteredIterator(self: *Entity, comp_type: anytype) Components.MaskedIterator {
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

const Systems = struct {
    pub fn run(comptime f: anytype, args: anytype) void {
        @call(.{}, f, args);
    }
};