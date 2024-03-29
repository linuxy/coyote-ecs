const std = @import("std");
const ecs = @import("coyote-ecs");

const World = ecs.World;
const Cast = ecs.Cast;
const Systems = ecs.Systems;

//Name configured in ECS constants
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
    //Create a world
    var world = try World.create();
    defer world.destroy();

    //Create an entity
    var anOrange = try world.entities.create();
    var anApple = try world.entities.create();
    var aPear = try world.entities.create();

    std.log.info("Created an Orange ID: {}", .{anOrange.id});

    //Create a unique component
    const orangeComponent = try world.components.create(Components.Orange);
    const appleComponent = try world.components.create(Components.Apple);

    //Attach and assign a component. Do not use an anonymous struct.
    try anOrange.attach(orangeComponent, Components.Orange{ .color = 0, .ripe = false, .harvested = false });
    try anApple.attach(appleComponent, Components.Apple{ .color = 0, .ripe = false, .harvested = false });

    //Create 50k entities and attach 50k unique components
    var i: usize = 0;
    while (i < 50000) : (i += 1) {
        const anEntity = try world.entities.create();
        const anOrangeComponent = try world.components.create(Components.Orange);
        try anEntity.attach(anOrangeComponent, Components.Orange{ .color = 1, .ripe = false, .harvested = false });
    }

    //Filter components by type
    var it = world.components.iteratorFilter(Components.Orange);
    i = 0;
    while (it.next()) |_| : (i += 1) {
        //...
    }

    std.log.info("Orange components: {}", .{i});

    //Filter entities by type
    var it2 = world.entities.iteratorFilter(Components.Apple);
    i = 0;
    while (it2.next()) |_| : (i += 1) {
        //...
    }

    std.log.info("Apple entities: {}", .{i});

    _ = try aPear.addComponent(Components.Pear{ .color = 1, .ripe = false, .harvested = false });

    if (aPear.getOneComponent(Components.Pear) != null)
        std.log.info("Pear entities: >= 1", .{})
    else
        std.log.info("Pear entities: 0", .{});

    try Systems.run(Grow, .{world});
    try Systems.run(Harvest, .{world});
    try Systems.run(Raze, .{world});

    std.log.info("Entities: {}", .{world.entities.count()});
    std.log.info("Components: {}", .{world.components.count()});
}

pub fn Grow(world: *World) void {
    var it = world.components.iterator();
    var i: u32 = 0;
    while (it.next()) |component| : (i += 1) {
        if (component.is(Components.Orange)) {
            try component.set(Components.Orange, .{ .ripe = true });
        }

        if (component.is(Components.Apple)) {
            try component.set(Components.Apple, .{ .ripe = true });
        }

        if (component.is(Components.Pear)) {
            try component.set(Components.Pear, .{ .ripe = true });
        }
        //Fruits fall from the tree
        component.detach();
    }
    std.log.info("Fruits grown: {}", .{i});
}

pub fn Harvest(world: *World) void {
    var it = world.components.iterator();
    var i: u32 = 0;
    while (it.next()) |component| {
        if (component.is(Components.Orange)) {
            if (Cast(Components.Orange, component).ripe == true) {
                try component.set(Components.Orange, .{ .harvested = true });
                i += 1;
            }
        }
        if (component.is(Components.Apple)) {
            if (Cast(Components.Apple, component).ripe == true) {
                try component.set(Components.Apple, .{ .harvested = true });
                i += 1;
            }
        }
        if (component.is(Components.Pear)) {
            if (Cast(Components.Pear, component).ripe == true) {
                try component.set(Components.Pear, .{ .harvested = true });
                i += 1;
            }
        }
        component.destroy();
    }

    world.components.gc();
    std.log.info("Fruits harvested: {}", .{i});
}

pub fn Raze(world: *World) void {
    var it = world.entities.iterator();
    var i: u32 = 0;

    while (it.next()) |entity| {
        entity.destroy();
        i += 1;
    }

    std.log.info("Entities destroyed: {}", .{i});
}
