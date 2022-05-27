const std = @import("std");

var allocator = std.heap.c_allocator;

const CHUNK = 10000; //Allocate at a time. You want this at the same O() as # of entities
const COMPONENT_CONTAINER = "Components";

pub fn main() void {
    var ctx = &World.add();
    var entities = &ctx.entities;

    //Create an entity and add a component
    _ = Entities.add(ctx, Components.Apple{.color = 0, .sweet = true, .harvested = false});
    _ = Entities.add(ctx, Components.Orange{.color = 1, .sweet = false, .harvested = false});

    //Create an entity
    _ = Entities.add(ctx, .{});

    var i: usize = 0;
    while(i < 50000) : (i += 1)
        _ = Entities.add(ctx, Components.Orange{.color = 1, .sweet = false, .harvested = false});

    var anApple = Entities.add(ctx, Components.Apple{.color = 0, .sweet = true, .harvested = false});

    //Get an entity by reference
    const thatApple = Cast(Components.Apple).get(ctx, anApple);
    std.log.info("that Apple: {}", .{thatApple});

    var apples = Entities.query(entities, Components.Apple);
    var oranges = Entities.query(entities, Components.Orange);
    defer allocator.free(apples);
    defer allocator.free(oranges);

    Systems.run(Grow, .{ctx, apples});
    Systems.run(Grow, .{ctx, oranges});
    Systems.run(Harvest, .{ctx});
    Entities.remove(ctx, oranges); //Rotten
    std.log.info("Entities: {}", .{Entities.count(ctx)});
    //}
    //update FSM with yield of run?
    //describe FSM with struct?
    //support multiple components for each entity?
}

//Components
pub const Components = struct {
    pub const Apple = struct {
        color: u32,
        sweet: bool,
        harvested: bool,
    };

    pub const Orange = struct {
        color: u32,
        sweet: bool,
        harvested: bool,
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
        _ = Entities.set(ctx, entity, .{ .harvested = true });
    }
    std.log.info("Harvested {} fruits.", .{i});
}

const World = struct {
    //Superset of Entities and Systems
    entities: Entities,
    systems: Systems,

    pub fn add() World {
        return World{.entities = Entities{.sparse = undefined,
                                          .dense = std.AutoHashMap(u32, u32).init(allocator)},
                     .systems = Systems{}} ;
    }
};

const Entity = struct {
    id: u32,
    data: ?*anyopaque,
    alive: bool,
};

pub fn typeToId(t: anytype) u32 {
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

pub fn Cast(comptime T: type) type {
    return struct {
        pub fn get(ctx: *World, entity: *Entity) ?*T {
            var id = ctx.entities.dense.get(entity.id).?;
            var field_ptr = @ptrCast(*T, @alignCast(@alignOf(T), ctx.entities.sparse[id].data));
            return field_ptr;
        }
    };
}

const Entities = struct {
    len: u32 = 0,
    sparse: []Entity,
    dense: std.AutoHashMap(u32, u32),
    alive: u32 = 0,
    free_idx: u32 = 0,
    resized: u32 = 0,

    pub fn add(ctx: *World, entity: anytype) *Entity {
        //create sparse list of entities
        if(ctx.entities.alive + 1 > ctx.entities.len)
            sparse_resize(ctx);

        //find end of sparse array
        while(ctx.entities.sparse[ctx.entities.free_idx].alive == true)
            ctx.entities.free_idx = ctx.entities.alive + 1;

        if(@sizeOf(@TypeOf(entity)) > 0) {
            var ref = allocator.create(@TypeOf(entity)) catch unreachable;
            ref.* = entity;

            ctx.entities.sparse[ctx.entities.free_idx] = Entity{.id = ctx.entities.free_idx, .data = ref, .alive = true};
        } else {
            ctx.entities.sparse[ctx.entities.free_idx] = Entity{.id = ctx.entities.free_idx, .data = null, .alive = true};
        }
        ctx.entities.dense.put(ctx.entities.free_idx, typeToId(entity)) catch unreachable;
        ctx.entities.alive += 1;
        ctx.entities.free_idx += 1;

        return &ctx.entities.sparse[ctx.entities.free_idx];
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

    pub fn set(ctx: *World, entity: u32, members: anytype) bool {
        var ret: bool = false;
        var idx: u32 = 0;
        var id = ctx.entities.dense.get(entity).?;
        _ = members;
        inline for (@typeInfo(@import("root")).Struct.decls) |decl| {
            const comp_eql = comptime std.mem.eql(u8, decl.name, COMPONENT_CONTAINER);
            if (decl.is_pub and comptime comp_eql) {
                inline for (@typeInfo((@field(@import("root"), decl.name))).Struct.decls) |member| {
                    if(idx == id) {
                        const comp_type = @field(@field(@import("root"), decl.name), member.name);
                        var field_ptr = @ptrCast(*comp_type, @alignCast(@alignOf(comp_type), ctx.entities.sparse[id].data));
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

    pub fn count(ctx: *World) u32 {
        //count of all living entities
        std.log.info("Sparse len: {}", .{ctx.entities.len});
        return ctx.entities.alive;
    }

    pub fn sparse_resize(ctx: *World) void {
        if(ctx.entities.resized > 0)
            ctx.entities.sparse = allocator.realloc(ctx.entities.sparse, CHUNK * (ctx.entities.resized + 1)) catch unreachable
        else
            ctx.entities.sparse = allocator.alignedAlloc(Entity, 32, CHUNK) catch unreachable;

        ctx.entities.resized += 1;
        ctx.entities.len = CHUNK * ctx.entities.resized - 1;
    }
};

const Systems = struct {
    pub fn run(comptime f: anytype, args: anytype) void {
        @call(.{}, f, args);
    }
};