const std = @import("std");
const ecs = @import("coyote-ecs");

const World = ecs.World;
const Cast = ecs.Cast;
const Systems = ecs.Systems;

const NUM = 1_000_000;
const CHUNK_SIZE = 10_000; // Process in smaller chunks for debugging

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

    // Break down component creation into chunks
    std.debug.print("Creating {} emplaced components and entities in chunks of {} ", .{ NUM, CHUNK_SIZE });
    var chunk_start: usize = 0;
    const then = std.time.milliTimestamp();
    while (chunk_start < NUM) : (chunk_start += CHUNK_SIZE) {
        const chunk_end = @min(chunk_start + CHUNK_SIZE, NUM);
        //std.debug.print("Processing chunk {}/{} ({}-{})...\n", .{ chunk_start / CHUNK_SIZE + 1, (NUM + CHUNK_SIZE - 1) / CHUNK_SIZE, chunk_start, chunk_end });
        try tests_component_create_range(world, chunk_start, chunk_end);

        // Add a GC call after each chunk to prevent memory buildup
        world.components.gc();
    }
    std.debug.print("completed in {}ms.\n", .{std.time.milliTimestamp() - then});
    std.debug.print("Iterating {} components ... ", .{NUM});
    try elapsed(tests_component_iterate, .{world});
    std.debug.print("Destroying and deallocating {} components ... ", .{NUM});
    try elapsed(tests_component_destroy, .{world});
    std.debug.print("Destroying {} entities ... ", .{NUM});
    try elapsed(tests_entity_destroy, .{world});
}

pub fn tests_entity_create(world: *World) !void {
    var i: usize = 0;
    while (i < NUM) : (i += 1) {
        const anEntity = try world.entities.create();
        _ = anEntity;
    }
}

pub fn tests_entity_iterate(world: *World) !void {
    var it = world.entities.iterator();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    std.debug.print("(Found {} entities) ", .{count});
}

pub fn tests_entity_destroy(world: *World) !void {
    var it = world.entities.iterator();
    var count: usize = 0;
    while (it.next()) |entity| {
        entity.destroy();
        count += 1;
    }
    std.debug.print("(Destroyed {} entities) ", .{count});
}

pub fn tests_component_create_range(world: *World, start: usize, end: usize) !void {
    var i: usize = start;
    while (i < end) : (i += 1) {
        var anEntity = try world.entities.create();
        const component = try anEntity.addComponent(Components.Pear{ .color = 1, .ripe = false, .harvested = false });

        // Verify the component was properly attached
        if (!component.attached) {
            //std.debug.print("Component at index {} was not properly attached\n", .{i});
            return error.ComponentNotAttached;
        }

        // Add some debug info every 1000 components
        if (i % 1000 == 0) {
            //std.debug.print("Created component {} (chunk offset {})\n", .{ i, i - start });
        }
    }
}

pub fn tests_component_create(world: *World) !void {
    try tests_component_create_range(world, 0, NUM);
}

pub fn tests_component_iterate(world: *World) !void {
    var it = world.components.iterator();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    std.debug.print("(Found {} components) ", .{count});
}

pub fn tests_component_destroy(world: *World) !void {
    var it = world.components.iterator();
    var count: usize = 0;
    while (it.next()) |component| {
        component.destroy();
        count += 1;
    }
    world.components.gc();
    std.debug.print("(Destroyed {} components) ", .{count});
}

pub fn elapsed(comptime f: anytype, args: anytype) !void {
    const then = std.time.milliTimestamp();
    const ret = @call(.auto, f, args);
    if (@typeInfo(@TypeOf(ret)) == .error_union) try ret;
    std.debug.print("completed in {}ms.\n", .{std.time.milliTimestamp() - then});
}
