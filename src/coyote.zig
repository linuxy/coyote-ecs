const std = @import("std");

var allocator = std.heap.c_allocator;

const MAX_ENTITIES = 96000; //Allocate at a time. You want this at the same O() as # of entities
const MAX_COMPONENTS = 48000;
const COMPONENT_CONTAINER = "Comp";
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

    //Destroy all components, entities and the world at end of scope
    //defer world.deinit();

    //Create an entity
    var anOrange = world.entities.create();
    var anApple = world.entities.create();
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
        var anEntity = world.entities.create();
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

    std.log.info("Entities: {}", .{world.entities.count()});
    std.log.info("Components: {}", .{world.components.count()});
    //update FSM with yield of run?
    //describe FSM with struct?
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

        pub fn next(it: *Iterator) ?*Component {
            if (it.ctx.alive == 0) return null;

            const end = it.ctx.alive;
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

        //find end of sparse array
        //TODO: wraparound from end to free_idx
        while(ctx.sparse_data[ctx.free_idx].allocated == true)
            ctx.free_idx = ctx.alive + 1;
        
        var component = &ctx.sparse_data[ctx.free_idx];

        component.world = world;
        component.attached = false;
        component.typeId = null;
        component.id = ctx.free_idx;
        component.allocated = false;
        component.alive = true;

        ctx.sparse[ctx.free_idx] = component;

        //std.log.info("Created component of ID: {}", .{component.id});
        ctx.free_idx += 1;
        ctx.created += 1;
        ctx.alive += 1;

        if(typeToId(comp_type) > componentCount() - 1)
            return error.ComponentNotInContainer;

        return component;
    }

    pub inline fn count(ctx: *Components) u32 {
        //count of all living components

        //std.log.info("Components alive: {}", .{ctx.len});
        return ctx.alive;
    }

    pub inline fn iterator(self: *const Components) Iterator {
        return .{ .ctx = self };
    }

    pub inline fn iteratorFilter(self: *const Components, comp_type: anytype) Components.MaskedIterator {
        //get an iterator for components attached to this entity
        return .{ .ctx = self,
                  .filter_type = typeToId(comp_type) };
    }

    pub fn sparse_resize(ctx: *Components) void {
        if(ctx.resized > 0) {
            ctx.sparse = allocator.realloc(ctx.sparse, MAX_ENTITIES * (ctx.resized + 1)) catch unreachable;
            var idx: usize = MAX_ENTITIES * ctx.resized;
            while(idx < (MAX_ENTITIES * (ctx.resized + 1))) {
                ctx.sparse[idx] = allocator.create(Component) catch unreachable;
                idx += 1;
            }
            std.log.info("Realloc components from: {} to {}", .{MAX_ENTITIES * ctx.resized, MAX_ENTITIES * (ctx.resized + 1)});
        } else {
            ctx.sparse = allocator.alloc(*Component, MAX_ENTITIES) catch unreachable;
            var idx: usize = 0;
            while(idx < MAX_ENTITIES) {
                ctx.sparse[idx] = allocator.create(Component) catch unreachable;
                idx += 1;
            }
        }

        ctx.resized += 1;
        ctx.len = MAX_ENTITIES * ctx.resized;
        std.log.info("Resized components to len: {}", .{ctx.len});
    }

    pub fn deinit(ctx: *Components) void {
        var i: usize = 0;
        var idata: usize = 0;
        var it = ctx.dense.iterator();
        while(it.next()) |component| {
            inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
                const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
                if (decl.is_pub and comptime comp_eql) {
                    inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member, did| {
                        if(comptime !std.mem.eql(u8, member.name, "create") and !std.mem.eql(u8, member.name, "deinit") and !std.mem.eql(u8, member.name, "world")
                        and !std.mem.eql(u8, member.name, "sparse_resize") and !std.mem.eql(u8, member.name, "count")) {
                            if(component.value_ptr.* != null and did == component.value_ptr.*.?) {
                                var member_type = @field(@field(@import("root"), decl.name), member.name){};
                                _ = member_type;
                                //std.log.info("matched component in deinit() {s} x {}", .{member.name, ctx.sparse[component.key_ptr.*]});
                                allocator.destroy(Cast(@TypeOf(member_type)).get(ctx.sparse[component.key_ptr.*]).?);
                                idata += 1;
                            }
                        }
                    }
                }
            }
            allocator.destroy(ctx.sparse[component.key_ptr.*]);
            i += 1;
        }
        while(i < ctx.len) {
            allocator.destroy(ctx.sparse[i]);
            i += 1;
        }
        std.log.info("Destroyed {} components and {} data", .{i, idata});
        ctx.dense.deinit();
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
        //component.destroy();
    }
    
    std.log.info("Fruits harvested: {}", .{i});
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
                                      .alive = 0,};
        var i: usize = 0;
        while(i < componentCount()) {
            std.log.info("Component index: {}", .{i});
            world.entities.component_mask[i] = std.StaticBitSet(MAX_COMPONENTS).initEmpty();
            i += 1;
        }
        return world;
    }

    pub fn deinit(ctx: *World) void {
        ctx.components.deinit();
        ctx.entities.deinit();
        allocator.destroy(ctx);
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

        world.entities.component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, true);
    }

    pub inline fn detach(self: *Entity, component: *Component) !void {
        component.attached = false;
        component.owner = null;
        self.world.entities.component_mask[@intCast(usize, component.typeId.?)].setValue(component.id, false);
    }

    pub inline fn destroy(self: *Entity) void {
        self.alive = false;
    }

    pub fn get(self: *Entity, comptime T: type) type {
        _ = self;
        _ = T;
    }

    pub inline fn iterator(self: *const Entities) Entities.Iterator {
        return .{ .ctx = self };
    }

    pub inline fn filteredIterator(self: *const Entity, comp_type: anytype) Components.MaskedIterator {
        //get an iterator for components attached to this entity
        return .{ .ctx = self,
                  .filter_type = typeToId(comp_type) };
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
                    //std.log.info("typeToId MATCHED idx: {} member.name: {s}", .{idx, member.name});
                    break;
                }
                //std.log.info("typeToId UNMATCHED idx: {} member.name: {s} {s}", .{idx, member.name, @typeName(@TypeOf(t))});
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
                    //std.log.info("Matched idx: {} to id: {} @ {s}", .{idx, id, @typeName(t)});
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
    sparse: [MAX_ENTITIES]*const Entity,
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

        pub fn next(it: *Iterator) ?*const Entity {
            if (it.ctx.alive == 0) return null;

            const end = it.ctx.alive;
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

    pub inline fn create(ctx: *Entities) *Entity {
        //most ECS cheat here and don't allocate memory until a component is assigned

        //find end of sparse array
        //TODO: wraparound from end to free_idx

        while(ctx.sparse_data[ctx.free_idx].alive == true)
            ctx.free_idx = ctx.alive + 1;

        var entity = &ctx.sparse_data[ctx.free_idx];
        entity.id = ctx.free_idx;
        entity.alive = true;
        entity.world = ctx.world;

        ctx.sparse[ctx.free_idx] = entity;
        ctx.alive += 1;
        ctx.free_idx += 1;

        //std.log.info("Entities created: {}", .{ctx.free_idx - 1});
        return entity;
    }

    pub inline fn remove(ctx: *Entities, entity: []*Entity) void {
        //mark as removed
        for(entity[0..]) |ent| {
            if(ctx.sparse[@intCast(usize, ent.id)].alive == true) {
                ctx.sparse[@intCast(usize, ent.id)].alive = false;
                ctx.free_idx = ent.id;
                ctx.alive -= 1;
                //std.log.info("Removed entity: {}", .{ent.id});
            }
        }
    }

    pub inline fn iterator(self: *const Entities) Iterator {
        return .{ .ctx = self };
    }

    pub inline fn count(ctx: *Entities) u32 {
        //count of all living entities
        return ctx.alive;
    }

    pub fn sparse_resize(ctx: *Entities) void {
        if(ctx.entities.resized > 0) {
            ctx.entities.sparse = allocator.realloc(ctx.entities.sparse, MAX_ENTITIES * (ctx.entities.resized + 1)) catch unreachable;
            var idx: usize = MAX_ENTITIES * ctx.entities.resized;
            while(idx < (MAX_ENTITIES * (ctx.entities.resized + 1))) {
                ctx.entities.sparse[idx] = allocator.create(Entity) catch unreachable;
                idx += 1;
            }
            std.log.info("Realloc from: {} to {}", .{MAX_ENTITIES * ctx.entities.resized, MAX_ENTITIES * (ctx.entities.resized + 1)});
        } else {
            ctx.entities.sparse = allocator.alloc(*Entity, MAX_ENTITIES) catch unreachable;
            var idx: usize = 0;
            while(idx < MAX_ENTITIES) {
                ctx.entities.sparse[idx] = allocator.create(Entity) catch unreachable;
                idx += 1;
            }
        }

        ctx.entities.resized += 1;
        ctx.entities.len = MAX_ENTITIES * ctx.entities.resized;
        std.log.info("Resized to len: {}", .{ctx.entities.len});
    }

    pub fn deinit(ctx: *Entities) void {
        var id: usize = 0;
        while(id <= ctx.created) {
            ctx.sparse[id].deinit();
            id += 1;
        }

        var idx: usize = 0;
        while(idx < (MAX_ENTITIES * (ctx.resized))) {
            allocator.destroy(ctx.sparse[idx]);            
            idx += 1;
        }

        ctx.dense.deinit();
        std.log.info("Destroyed {} entities.", .{idx});
    }
};

const Systems = struct {
    pub fn run(comptime f: anytype, args: anytype) void {
        @call(.{}, f, args);
    }
};