const std = @import("std");

var allocator = std.heap.c_allocator;

const CHUNK = 10000; //Allocate at a time. You want this at the same O() as # of entities
const COMPONENT_CONTAINER = "Components";

pub fn main() void {
    var world = World.create();
    //var entities = ctx.entities;
    std.log.info("World created @{}", .{&world});

    //Create an entity
    var anOrange = world.entities.create();
    var anApple = world.entities.create();
    std.log.info("Created an Orange ID: {}", .{anOrange.id});

    //Attach a component
    try anOrange.attach(Components.Orange{.color = 0, .sweet = true, .harvested = false});
    try anApple.attach(Components.Apple{.color = 0, .sweet = true, .harvested = false});

//    var i: usize = 0;
//    while(i < 50000) : (i += 1)
//        _ = Entities.add(ctx, Components.Orange{.color = 1, .sweet = false, .harvested = false});
//
//    var anApple = Entities.add(ctx, Components.Apple{.color = 0, .sweet = true, .harvested = false});
//
//    //Get an entity by reference
//    const thatApple = Cast(Components.Apple).get(ctx, anApple);
//    std.log.info("that Apple: {}", .{thatApple});
//
    var apples = world.entities.query(Components.Apple);
    var oranges = world.entities.query(Components.Orange);
    defer allocator.free(apples);
    defer allocator.free(oranges);

    Systems.run(Grow, .{world, apples});
    Systems.run(Grow, .{world, oranges});
    Systems.run(Harvest, .{world});
    //    Entities.remove(ctx, oranges); //Rotten
    std.log.info("Entities: {}", .{world.entities.count()});
    //}
    //update FSM with yield of run?
    //describe FSM with struct?
    //support multiple components for each entity?
    try anApple.detach(Components.Apple{});
    try anOrange.detach(Components.Orange{});
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
};

pub fn Grow(ctx: *World, fruit: []u32) void {
    for(fruit[0..]) |entity| {
        //async schedule in fiber
        //yield
        //std.log.info("Growing: {}", .{entity});
        _ = entity;
        _ = ctx;
    }
}

pub fn Harvest(ctx: *World) void {
    var i: usize = 0;
    for(ctx.entities.getAll()) |entity| {
        //async schedule in fiber
        //yield
        _ = entity;
        i += 1;
        std.log.info("Harvest: {}", .{entity});
        //set which component(s)?
        //_ = Entities.set(ctx, entity, .{ .harvested = true });
    }
    std.log.info("Harvested {} fruits.", .{i});
}

const World = struct {
    //Superset of Entities and Systems
    entities: Entities,
    systems: Systems,

    pub fn create() *World {
        var world = allocator.create(World) catch unreachable;
        world.entities = Entities{.sparse = undefined,
                                              .dense = std.AutoHashMap(u32, u32).init(allocator),
                                              .world = undefined,
                                 };
        world.systems = Systems{};
        world.entities.world = world;
        return world;
    }
};

const Entity = struct {
    id: u32,
    data: [componentCount()]?*anyopaque,
    alive: bool,
    world: *World,

    pub fn attach(self: *Entity, entity: anytype) !void {
        if(@sizeOf(@TypeOf(entity)) > 0) {
            var ref = allocator.create(@TypeOf(entity)) catch unreachable;
            ref.* = entity;

            var oref = @ptrCast(?*anyopaque, ref);
            self.data[typeToId(entity)] = oref;
            std.log.info("Attaching to self ID: {}", .{self.id});
        }
        self.world.entities.dense.put(self.id, typeToId(entity)) catch unreachable;
    }

    pub fn detach(self: *Entity, component: anytype) !void {
        var data_ptr = @ptrCast(*@TypeOf(component), @alignCast(@alignOf(@TypeOf(component)), self.data[typeToId(component)]));
        allocator.destroy(data_ptr);
        std.log.info("Detaching component ID: #{}", .{typeToId(component)});
        self.data[typeToId(component)] = null;
    }

    //rework, rethink
    pub fn set(self: *Entity, component: anytype, members: anytype) bool {
        var ret: bool = false;
        var idx: u32 = 0;
        inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
            const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
            if (decl.is_pub and comptime comp_eql) {
                inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                    if(idx == self.id) {
                        const comp_type = @field(@field(@import("root"), decl.name), member.name);
                        std.log.info("Comp type: {} Entity: {}", .{typeToId(@TypeOf(component)), self});
                        var field_ptr = @ptrCast(*comp_type, @alignCast(@alignOf(component), self.world.entities.sparse[self.id].data[typeToId(comp_type) - 2]));
                        inline for (std.meta.fields(@TypeOf(members))) |sets| {
                            @field(field_ptr, sets.name) = @field(members, sets.name);
                        }
                        _ = member;
                    }
                    idx += 1;
                }
            }
        }
        return ret;
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
                    std.log.info("typeToId MATCHED idx: {} member.name: {s}", .{idx, member.name});
                    break;
                }
                std.log.info("typeToId UNMATCHED idx: {} member.name: {s} {s}", .{idx, member.name, @typeName(@TypeOf(t))});
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
        pub fn get(ctx: *World, entity: *Entity) ?*T {
            var id = ctx.entities.dense.get(entity.id).?;
            var field_ptr = @ptrCast(*T, @alignCast(@alignOf(T), ctx.entities.sparse[id].data[typeToId(@TypeOf(T))]));
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

    pub fn create(ctx: *Entities) *Entity {
        //create sparse list of entities
        std.log.info("Creating entity in @{}", .{&ctx.world});
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

        ctx.sparse[ctx.free_idx] = entity;
        ctx.alive += 1;
        ctx.free_idx += 1;

        std.log.info("Entities created: {}", .{ctx.free_idx - 1});
        return entity;
    }

    pub fn remove(ctx: *World, entity: []u32) void {
        //mark as removed
        for(entity[0..]) |ent| {
            //std.log.info("Removed entity: {}", .{ent});
            ctx.entities.sparse[@intCast(usize, ent)].alive = false;
            ctx.entities.free_idx = ent;
            ctx.entities.alive -= 1;
        }
    }

    pub fn query(ctx: *Entities, search: anytype) []u32 {
        //find all entities by search term
        _ = search;
        _ = ctx;
        var matched = std.ArrayList(u32).init(allocator);
        //std.log.info("Search typeName: {s}", .{@typeName(search)});
        var it = ctx.dense.iterator();
        while(it.next()) |entity| {
            if(idEqualsType(entity.value_ptr.*, search)) {
                //std.log.info("Entity: {}", .{entity});
                //std.log.info("Matched type ID: {} ({s}) to search ID {}", .{typeToId(entity.key), @typeName(search), typeToId(search)});
                matched.append(entity.key_ptr.*) catch unreachable;
            } else {
                //std.log.info("No match: {}", .{entity});
            }
        }
        return matched.toOwnedSlice();
    }

    pub fn getAll(ctx: *Entities) []u32 {
        _ = ctx;
        var matched = std.ArrayList(u32).init(allocator);
        var it = ctx.dense.iterator();
        while(it.next()) |entity| {
            matched.append(entity.value_ptr.*) catch unreachable;
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
            //ditto down below
        } else {
            ctx.entities.sparse = allocator.alignedAlloc(*Entity, 32, CHUNK) catch unreachable;
            var idx: usize = 0;
            while(idx < CHUNK) {
                ctx.entities.sparse[idx] = allocator.create(Entity) catch unreachable;
                idx += 1;
            }
        }

        ctx.entities.resized += 1;
        ctx.entities.len = CHUNK * ctx.entities.resized - 1;
    }
};

const Systems = struct {
    pub fn run(comptime f: anytype, args: anytype) void {
        @call(.{}, f, args);
    }
};