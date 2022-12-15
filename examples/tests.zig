const std = @import("std");
const ecs = @import("coyote-ecs");

const World = ecs.World;
const Cast = ecs.Cast;
const Systems = ecs.Systems;

const NUM = 1_000_000;

pub const Components = struct {
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

    pub const Pear = struct {
        color: u32 = 0,
        ripe: bool = false,
        harvested: bool = false,
    };
};


pub fn main() !void {
    var world = try World.create();
    defer world.destroy();

    std.debug.print("Creating {} entities ... ", .{NUM});
    try elapsed(tests_entity_create, .{world});
    std.debug.print("Iterating {} entities ... ", .{NUM});
    try elapsed(tests_entity_iterate, .{world});
    std.debug.print("Creating {} emplaced components and entities ... ", .{NUM});
    try elapsed(tests_component_create, .{world});
    std.debug.print("Iterating {} components ... ", .{NUM});
    try elapsed(tests_component_iterate, .{world});
    std.debug.print("Destroying and deallocating {} components ... ", .{NUM});
    try elapsed(tests_component_destroy, .{world});
    std.debug.print("Destroying {} entities ... ", .{NUM});
    try elapsed(tests_entity_destroy, .{world});
}

pub fn tests_entity_create(world: *World) !void {

    var i: usize = 0;
    while(i < NUM) : (i += 1) {
        var anEntity = try world.entities.create();
        _ = anEntity;
    }
}

pub fn tests_entity_iterate(world: *World) !void {
    var it = world.entities.iterator();

    while(it.next()) |_| {
        //
    }
}

pub fn tests_entity_destroy(world: *World) !void {
    var it = world.entities.iterator();

    while(it.next()) |entity| {
        entity.destroy();
    }
}

pub fn tests_component_create(world: *World) !void {

    var i: usize = 0;
    while(i < NUM) : (i += 1) {
        var anEntity = try world.entities.create();
        _ = try anEntity.addComponent(Components.Pear{.color = 1, .ripe = false, .harvested = false});
    }
}

pub fn tests_component_iterate(world: *World) !void {
    var it = world.components.iterator();

    while(it.next()) |_| {
        //
    }
}

pub fn tests_component_destroy(world: *World) !void {
    var it = world.components.iterator();

    while(it.next()) |component| {
        component.destroy();
    }
    try world.components.gc();
}

pub fn elapsed(comptime f: anytype, args: anytype) !void {
    var then = std.time.milliTimestamp();
    const ret = @call(.{}, f, args);
    if (@typeInfo(@TypeOf(ret)) == .ErrorUnion) try ret;
    std.debug.print("completed in {}ms.\n", .{std.time.milliTimestamp() - then});
}