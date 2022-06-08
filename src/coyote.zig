const std = @import("std");

var allocator = std.heap.c_allocator;

const CHUNK = 10000; //Allocate at a time. You want this at the same O() as # of entities
const COMPONENT_CONTAINER = "Components";

pub fn main() !void {
    var world = World.create();

    //Create an entity
    var anOrange = world.entities.create();
    var anApple = world.entities.create();
    std.log.info("Created an Orange ID: {}", .{anOrange.id});

    //Create a unique component
    var orangeComponent = try world.components.create(Components.Orange{});
    var appleComponent = try world.components.create(Components.Apple{});

    //Attach and assign a component. Do not use an anonymous struct.
    try anOrange.attach(orangeComponent, Components.Orange{.color = 0, .sweet = true, .harvested = false});
    try anApple.attach(appleComponent, Components.Apple{.color = 0, .sweet = true, .harvested = false});

    //70ms per 100k create
    //80ms per 100k attach

    //Create 100k entities and attach, detach and destroy 100k unique components
    var i: usize = 0;
    while(i < 5) : (i += 1) {
        var anEntity = world.entities.create();
        var anOrangeComponent = try world.components.create(Components.Orange{});
        try anEntity.attach(anOrangeComponent, Components.Orange{.color = 1, .sweet = false, .harvested = false});
        try anOrange.detach(anOrangeComponent);
        anOrange.destroy(anOrangeComponent, Components.Orange);
    }

//
//    //Get an entity by reference
//    const thatApple = Cast(Components.Apple).get(ctx, anApple);
//    std.log.info("that Apple: {}", .{thatApple});
//
    //Query entities by component
    var apples = world.entities.query(Components.Apple);
    //20ms per 100k for a query
    var oranges = world.entities.query(Components.Orange);
    defer allocator.free(apples);
    defer allocator.free(oranges);

    Systems.run(Grow, .{world, apples});
    //20ms per 100k to run a system
    Systems.run(Grow, .{world, oranges});
    Systems.run(Harvest, .{world});

    //12ms per 100k delete
    //Remove all entities containing an orange
    world.entities.remove(oranges); //Rotten
    anApple.remove();

    std.log.info("Entities: {}", .{world.entities.count()});
    //update FSM with yield of run?
    //describe FSM with struct?

    //You can detach a component and reattach it to another entity
    try anOrange.detach(orangeComponent);
    try anApple.detach(appleComponent);

    //Destroy a component and free it's memory, irrespective of whether it's attached or not
    anOrange.destroy(orangeComponent, Components.Orange);
    anApple.destroy(appleComponent, Components.Apple);
}

//Components, must have default values
pub const Components = struct {
    pub const Apple = struct {
        color: u32 = 0,
        sweet: bool = false,
        harvested: bool = false,
    };

    pub const Orange = struct {
        color: u32 = 0,
        sweet: bool = false,
        harvested: bool = false,
    };

    world: ?*anyopaque = undefined, //Defeats cyclical reference checking
    
    pub fn create(comp: *Components, comp_type: anytype) !*Component {
        var component = allocator.create(Component) catch unreachable;

        var world = @ptrCast(*World, @alignCast(@alignOf(World), comp.world));

        component.world = world;
        component.attached = false;
        component.typeId = null;
        component.id = world.entities.components_free_idx;

        //std.log.info("Created component of TypeId: {}", .{component.typeId});
        world.entities.components_free_idx += 1;

        if(typeToId(comp_type) > componentCount() - 1)
            return error.ComponentNotInContainer;

        return component;
    }
};

pub fn Grow(ctx: *World, fruit: []*Entity) void {
    for(fruit[0..]) |entity| {
        //async schedule in fiber
        //yield
        //std.log.info("Growing: {}", .{entity.id});
        _ = entity;
        _ = ctx;
    }
}

pub fn Harvest(world: *World) void {
    var i: usize = 0;
    for(world.entities.getAll()) |entity| {
        //async schedule in fiber
        //yield
        for(entity.getComponents(Components.Orange{})) |component| {
            std.log.info("Orange harvested", .{});
            try entity.set(component, Components.Orange, .{.harvested = true});
            i += 1;
        }
        for(entity.getComponents(Components.Apple{})) |component| {
            std.log.info("Apple harvested", .{});
            try entity.set(component, Components.Apple, .{.harvested = true});
            i += 1;
        }
    }
    std.log.info("Harvested {} fruits.", .{i});
}

const World = struct {
    //Superset of Entities and Systems
    entities: Entities,
    components: Components,
    systems: Systems,

    pub fn create() *World {
        var world = allocator.create(World) catch unreachable;
        world.entities = Entities{.sparse = undefined,
                                              .dense = std.AutoHashMap(u32, u32).init(allocator),
                                              .world = undefined,
                                              .components = undefined,
                                 };
        world.systems = Systems{};
        world.components = Components{};
        world.entities.world = world;
        world.components.world = world;
        return world;
    }
};

const Component = struct {
    id: u32,
    data: ?*anyopaque,
    owner: u32,
    world: *World,
    attached: bool,
    typeId: ?u32 = undefined,
};

const Entity = struct {
    id: u32,
    alive: bool,
    world: *World,
    components: std.ArrayList(*Component),

    pub fn remove(self: *Entity) void {
        if(self.alive == true) {
            self.alive = false;
            self.world.entities.alive -= 1;
            self.world.entities.free_idx = self.id;
        }
    }

    pub fn attach(self: *Entity, component: *Component, comp_type: anytype) !void {
        if(@sizeOf(@TypeOf(comp_type)) > 0) {
            var ref = allocator.create(@TypeOf(comp_type)) catch unreachable;
            ref.* = comp_type;

            var oref = @ptrCast(?*anyopaque, ref);
            component.data = oref;
        }
        component.owner = self.id;
        component.attached = true;
        component.typeId = typeToId(comp_type);

        self.components.append(component) catch unreachable;
        self.world.entities.dense.put(self.id, typeToId(comp_type)) catch unreachable;
    }

    pub fn detach(self: *Entity, component: *Component) !void {
        //std.log.info("Detach type: {s} from ID: {} typeId: {}", .{@typeName(comp_type), self.id, component.typeId});

        for(self.components.items) |item, i| {
            if(component == item) {
                component.attached = false;
                _ = self.components.swapRemove(i);
            }
        }
    }

    pub fn destroy(self: *Entity, component: *Component, comp_type: anytype) void {
        //std.log.info("Destroy component type: {s}", .{@typeName(comp_type)});

        var data_ptr = @ptrCast(*comp_type, @alignCast(@alignOf(comp_type), component.data.?));
        allocator.destroy(data_ptr);
        component.attached = false;
        _ = self;
    }

    pub fn get(self: *Entity, comptime T: type) type {
        _ = self;
        _ = T;
    }

    pub fn getComponents(entity: *Entity, comp_type: anytype) []*Component {
        //get all components attached to an entity, returned as slice
        //caller owns memory

        var matched = std.ArrayList(*Component).init(allocator);
        for(entity.components.items) |component| {
            if(typeToId(comp_type) != component.typeId) {
                matched.append(component) catch unreachable;
            }
        }
        return matched.toOwnedSlice();
    }

    pub fn set(self: *Entity, component: *Component, comp_type: anytype, members: anytype) !void {
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

pub fn typeToId(t: anytype) u32 {
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

pub fn idEqualsType(id: u32, t: anytype) bool {
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

pub fn componentCount() usize {
    var idx: u32 = 0;
    inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
        const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
        if (decl.is_pub and comptime comp_eql) {
            inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                idx += 1;
                _ = member;
            }
        }
    }

    return idx;
}

pub fn Cast(comptime T: type) type {
    return struct {
        pub fn get(ctx: *World, component: *Component) ?*T {
            std.log.info("Cast: {s}", .{@typeName(T)});
            var field_ptr = @ptrCast(*T, @alignCast(@alignOf(T), component.data));
            _ = ctx;
            return field_ptr;
        }
    };
}

const Entities = struct {
    len: u32 = 0,
    sparse: []*Entity,
    dense: std.AutoHashMap(u32, u32),
    alive: u32 = 0,
    free_idx: u32 = 0,
    resized: u32 = 0,
    world: *World,
    components: []*Component,
    components_free_idx: u32 = 0,

    pub fn create(ctx: *Entities) *Entity {
        //create sparse list of entities
        //std.log.info("Creating entity in @{}", .{&ctx.world});
        if(ctx.alive + 1 > ctx.len)
            sparse_resize(ctx.world);

        //find end of sparse array
        while(ctx.sparse[ctx.free_idx].alive == true)
            ctx.free_idx = ctx.alive + 1;

        ctx.dense.put(ctx.free_idx, 1024) catch unreachable;
        var entity = allocator.create(Entity) catch unreachable;
        entity.id = ctx.free_idx;
        entity.alive = true;
        entity.world = ctx.world;
        entity.components = std.ArrayList(*Component).init(allocator);

        ctx.sparse[ctx.free_idx] = entity;
        ctx.alive += 1;
        ctx.free_idx += 1;

        //std.log.info("Entities created: {}", .{ctx.free_idx - 1});
        return entity;
    }

    pub fn remove(ctx: *Entities, entity: []*Entity) void {
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

    pub fn query(ctx: *Entities, search: anytype) []*Entity {
        //find all entities by search term
        _ = search;
        _ = ctx;
        var matched = std.ArrayList(*Entity).init(allocator);
        //std.log.info("Search typeName: {s}", .{@typeName(search)});
        var it = ctx.dense.iterator();
        while(it.next()) |entity| {
            if(idEqualsType(entity.value_ptr.*, search)) {
                //std.log.info("Entity: {}", .{entity});
                //std.log.info("Matched type ID: {} ({s}) to search ID {}", .{typeToId(entity.key), @typeName(search), typeToId(search)});
                matched.append(ctx.sparse[entity.key_ptr.*]) catch unreachable;
            } else {
                //std.log.info("No match: {}", .{entity});
            }
        }
        return matched.toOwnedSlice();
    }

    pub fn getAll(ctx: *Entities) []*Entity {
        //get all entities in a context, returned as slice
        //caller owns memory
        _ = ctx;
        var matched = std.ArrayList(*Entity).init(allocator);
        var it = ctx.dense.iterator();
        while(it.next()) |entity| {
            matched.append(ctx.sparse[entity.value_ptr.*]) catch unreachable;
        }
        return matched.toOwnedSlice();
    }

    pub fn count(ctx: *Entities) u32 {
        //count of all living entities
        std.log.info("Sparse len: {}", .{ctx.len});
        return ctx.alive;
    }

    pub fn sparse_resize(ctx: *World) void {
        if(ctx.entities.resized > 0) {
            ctx.entities.sparse = allocator.realloc(ctx.entities.sparse, CHUNK * (ctx.entities.resized + 1)) catch unreachable;
            var idx: usize = CHUNK * ctx.entities.resized;
            while(idx < (CHUNK * (ctx.entities.resized + 1))) {
                ctx.entities.sparse[idx] = allocator.create(Entity) catch unreachable;
                idx += 1;
            }
            std.log.info("Realloc from: {} to {}", .{CHUNK * ctx.entities.resized, CHUNK * (ctx.entities.resized + 1)});
        } else {
            ctx.entities.sparse = allocator.alignedAlloc(*Entity, 32, CHUNK) catch unreachable;
            var idx: usize = 0;
            while(idx < CHUNK) {
                ctx.entities.sparse[idx] = allocator.create(Entity) catch unreachable;
                idx += 1;
            }
        }

        ctx.entities.resized += 1;
        ctx.entities.len = CHUNK * ctx.entities.resized;
        std.log.info("Resized to len: {}", .{ctx.entities.len});
    }
};

const Systems = struct {
    pub fn run(comptime f: anytype, args: anytype) void {
        @call(.{}, f, args);
    }
};