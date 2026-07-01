# Examples

This page contains practical examples of using Coyote ECS. See also the runnable demos in `examples/fruits.zig` and `examples/fruits.c`.

## Basic Example: Fruit Garden

This example demonstrates entity and component management using a fruit garden simulation.

### Components Definition

```zig
const std = @import("std");
const ecs = @import("coyote-ecs");

const World = ecs.World;
const Cast = ecs.Cast;
const Systems = ecs.Systems;

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
```

### Main Program

```zig
pub fn main() !void {
    var world = try World.create();
    defer world.destroy();

    var anOrange = try world.entities.create();
    var anApple = try world.entities.create();
    var aPear = try world.entities.create();

    const orangeComponent = try world.components.create(Components.Orange);
    const appleComponent = try world.components.create(Components.Apple);

    try anOrange.attach(orangeComponent, Components.Orange{ .color = 0, .ripe = false, .harvested = false });
    try anApple.attach(appleComponent, Components.Apple{ .color = 0, .ripe = false, .harvested = false });
    _ = try aPear.addComponent(Components.Pear{ .color = 1, .ripe = false, .harvested = false });

    // Multi-component query
    var combo = try world.entities.create();
    _ = try combo.addComponent(Components.Orange{});
    _ = try combo.addComponent(Components.Apple{});

    var both: usize = 0;
    var q = world.entities.query(.{ Components.Orange, Components.Apple });
    while (q.next()) |_| both += 1;

    try Systems.run(Grow, .{world});
    try Systems.run(Harvest, .{world});
    try Systems.run(Raze, .{world});
}
```

### Systems Implementation

```zig
pub fn Grow(world: *World) !void {
    var it = world.components.iterator();
    var i: u32 = 0;
    while (it.next()) |component| : (i += 1) {
        if (component.is(Components.Orange)) {
            try component.set(Components.Orange, .{ .ripe = true });
        }
        if (component.is(Components.Apple)) {
            try component.set(Components.Apple, .{ .ripe = true });
        }
        component.detach();
    }
    std.log.info("Fruits grown: {}", .{i});
}

pub fn Harvest(world: *World) !void {
    var it = world.components.iterator();
    var i: u32 = 0;
    while (it.next()) |component| {
        if (component.is(Components.Orange)) {
            if (Cast(Components.Orange, component).ripe) {
                try component.set(Components.Orange, .{ .harvested = true });
                i += 1;
            }
        }
        component.destroy();
    }
    world.components.gc();
    std.log.info("Fruits harvested: {}", .{i});
}

pub fn Raze(world: *World) !void {
    var it = world.entities.iterator();
    while (it.next()) |entity| {
        entity.destroy();
    }
}
```

## Game Loop: Scheduler + Command Buffer

See [Game Loop](game-loop.md) for the full guide. This example mirrors `examples/fruits.zig`:

```zig
const SystemContext = ecs.SystemContext;

const GameTime = struct { tick: u32 = 0 };

pub fn Setup(ctx: *SystemContext) !void {
    try ctx.world.insertResource(GameTime, .{ .tick = 0 });
}

pub fn SpawnApples(ctx: *SystemContext) !void {
    const e = try ctx.commands.createEntity();
    try ctx.commands.attachDeferred(e, Components.Apple{ .color = 1, .ripe = false, .harvested = false });
}

pub fn TickTime(ctx: *SystemContext) !void {
    if (ctx.resource(GameTime)) |time| {
        time.tick += 1;
    }
}

pub fn main() !void {
    var world = try World.create();
    defer world.destroy();

    var sched = world.scheduler();
    defer sched.deinit();

    try sched.addSystem(0, Setup);
    try sched.addSystem(1, SpawnApples);
    try sched.addSystem(2, TickTime);
    try sched.run();
}
```

## 2D Physics with Queries

```zig
pub const Components = struct {
    pub const Position = struct { x: f32 = 0, y: f32 = 0 };
    pub const Velocity = struct { x: f32 = 0, y: f32 = 0 };
};

pub fn UpdatePhysics(world: *World, delta_time: f32) !void {
    var q = world.entities.query(.{ Components.Position, Components.Velocity });
    while (q.next()) |entity| {
        if (entity.get(Components.Velocity)) |vel| {
            if (entity.get(Components.Position)) |pos| {
                pos.x += vel.x * delta_time;
                pos.y += vel.y * delta_time;
            }
        }
    }
}
```

## Entity Handles

```zig
const handle = entity.ref();
entity.destroy();

try std.testing.expect(!world.entities.isValid(handle));
try std.testing.expect(world.entities.resolve(handle) == null);
```

## Events and Observers

```zig
fn onAppleAdded(world: *World, entity: *Entity, component: *Component, type_id: u32) void {
    _ = world; _ = entity; _ = component; _ = type_id;
    std.log.info("Apple added", .{});
}

try world.onComponentAdd(Components.Apple, onAppleAdded);

// Drain queued spawn events in a system stage
ctx.events().drainStructural(struct {
    fn cb(ev: ecs.StructuralEvent) void {
        if (ev.kind == .entity_spawned) { /* ... */ }
    }
}.cb);
```

## Performance Example: Particle System

```zig
pub fn CreateParticleSystem(world: *World, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var entity = try world.entities.create();
        _ = try entity.addComponent(Components.Position{
            .x = @floatFromInt(i % 100),
            .y = @floatFromInt(i / 100),
        });
        _ = try entity.addComponent(Components.Velocity{ .x = 0, .y = 0 });
    }
}

pub fn UpdateParticles(world: *World) !void {
    var q = world.entities.query(.{ Components.Position, Components.Velocity });
    while (q.next()) |entity| {
        if (entity.get(Components.Velocity)) |vel| {
            if (entity.get(Components.Position)) |pos| {
                pos.x += vel.x;
                pos.y += vel.y;
            }
        }
    }
}
```

## Next Steps

- [C API Guide](c-api-guide.md) — C language integration
- [Game Loop](game-loop.md) — scheduler, command buffer, resources, events
- [Performance Guide](performance-guide.md) — large-scale applications
- [Core Concepts](core-concepts.md) — deeper ECS overview
