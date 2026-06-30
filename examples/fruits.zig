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

    //Multi-component queries. Build a small isolated scenario, then clean it up.
    var combo = try world.entities.create();
    _ = try combo.addComponent(Components.Orange{});
    _ = try combo.addComponent(Components.Apple{});

    var only_orange: usize = 0;
    var q1 = world.entities.query(.{Components.Orange});
    while (q1.next()) |_| only_orange += 1;
    std.log.info("Query [Orange]: {} (anOrange + combo)", .{only_orange});

    var both: usize = 0;
    var q2 = world.entities.query(.{ Components.Orange, Components.Apple });
    while (q2.next()) |_| both += 1;
    std.log.info("Query [Orange AND Apple]: {} (combo)", .{both});

    var orange_not_apple: usize = 0;
    var q3 = world.entities.queryExclude(.{Components.Orange}, .{Components.Apple});
    while (q3.next()) |_| orange_not_apple += 1;
    std.log.info("Query [Orange WITHOUT Apple]: {} (anOrange)", .{orange_not_apple});

    try combo.remove(Components.Orange);
    try combo.remove(Components.Apple);
    combo.destroy();
    world.components.gc();

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

    //Entity accessors: has / get / remove
    if (aPear.has(Components.Pear))
        std.log.info("Pear entities: >= 1", .{})
    else
        std.log.info("Pear entities: 0", .{});

    if (aPear.get(Components.Pear)) |pear| {
        pear.ripe = true;
        std.log.info("Pear ripe via get(): {}", .{pear.ripe});
    }

    try aPear.remove(Components.Pear);
    std.log.info("Pear present after remove(): {}", .{aPear.has(Components.Pear)});

    try Systems.run(Grow, .{world});
    try Systems.run(Harvest, .{world});
    try Systems.run(Raze, .{world});

    std.log.info("Entities: {}", .{world.entities.count()});
    std.log.info("Components: {}", .{world.components.count()});

    //Generational handles: a stored handle is invalidated when the entity is
    //destroyed and its slot recycled, instead of silently aliasing a new entity.
    const subject = try world.entities.create();
    const handle = subject.ref();
    std.log.info("Handle valid before destroy: {}", .{world.entities.isValid(handle)});
    subject.destroy();
    std.log.info("Handle valid after destroy: {}", .{world.entities.isValid(handle)});
    const recycled = try world.entities.create(); // reuses the freed slot
    std.log.info("Old handle resolves to recycled slot: {}", .{world.entities.resolve(handle) != null});
    recycled.destroy();
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
