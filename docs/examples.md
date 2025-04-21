# Examples

This page contains practical examples of using Coyote ECS in different scenarios.

## Basic Example: Fruit Garden

This example demonstrates basic entity and component management using a fruit garden simulation.

### Components Definition

```zig
const std = @import("std");
const ecs = @import("coyote-ecs");

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
    defer world.deinit();
    
    // Create entities
    var anOrange = try world.entities.create();
    var anApple = try world.entities.create();
    var aPear = try world.entities.create();

    // Create and attach components
    var orangeComponent = try world.components.create(Components.Orange);
    var appleComponent = try world.components.create(Components.Apple);

    try anOrange.attach(orangeComponent, Components.Orange{
        .color = 0,
        .ripe = false,
        .harvested = false,
    });
    try anApple.attach(appleComponent, Components.Apple{
        .color = 0,
        .ripe = false,
        .harvested = false,
    });
    _ = try aPear.addComponent(Components.Pear{
        .color = 1,
        .ripe = false,
        .harvested = false,
    });

    // Run systems
    try Systems.run(Grow, .{world});
    try Systems.run(Harvest, .{world});
    try Systems.run(Raze, .{world});
}
```

### Systems Implementation

```zig
pub fn Grow(world: *World) void {
    var it = world.components.iterator();
    while(it.next()) |component| {
        if(component.is(Components.Orange)) {
            try component.set(Components.Orange, .{.ripe = true});
        }
        if(component.is(Components.Apple)) {
            try component.set(Components.Apple, .{.ripe = true});
        }
        if(component.is(Components.Pear)) {
            try component.set(Components.Pear, .{.ripe = true});
        }
        component.detach();
    }
}

pub fn Harvest(world: *World) void {
    var it = world.components.iterator();
    while(it.next()) |component| {
        if(component.is(Components.Orange)) {
            if(Cast(Components.Orange, component).ripe) {
                try component.set(Components.Orange, .{.harvested = true});
            }
        }
        // Similar for Apple and Pear
        component.destroy();
    }
    world.components.gc();
}

pub fn Raze(world: *World) void {
    var it = world.entities.iterator();
    while(it.next()) |entity| {
        entity.destroy();
    }
}
```

## Game Development Example: 2D Physics

This example shows how to implement a simple 2D physics system.

### Components

```zig
pub const Components = struct {
    pub const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    pub const Velocity = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    pub const Acceleration = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    pub const Mass = struct {
        value: f32 = 1.0,
    };
};
```

### Physics Systems

```zig
pub fn UpdatePhysics(world: *World, delta_time: f32) void {
    var it = world.entities.iteratorFilter(Components.Position);
    while(it.next()) |entity| {
        if(entity.getOneComponent(Components.Velocity)) |velocity| {
            var pos = entity.getOneComponent(Components.Position).?;
            pos.x += velocity.x * delta_time;
            pos.y += velocity.y * delta_time;
        }
    }
}

pub fn ApplyGravity(world: *World, gravity: f32) void {
    var it = world.entities.iteratorFilter(Components.Mass);
    while(it.next()) |entity| {
        if(entity.getOneComponent(Components.Velocity)) |velocity| {
            velocity.y += gravity;
        }
    }
}
```

## Performance Example: Particle System

This example demonstrates how to handle large numbers of entities efficiently.

```zig
pub fn CreateParticleSystem(world: *World, count: usize) !void {
    var i: usize = 0;
    while(i < count) : (i += 1) {
        var entity = try world.entities.create();
        var position = try world.components.create(Components.Position);
        var velocity = try world.components.create(Components.Velocity);
        
        try entity.attach(position, Components.Position{
            .x = @floatFromInt(i % 100),
            .y = @floatFromInt(i / 100),
        });
        try entity.attach(velocity, Components.Velocity{
            .x = 0,
            .y = 0,
        });
    }
}

pub fn UpdateParticles(world: *World) void {
    var it = world.entities.iteratorFilter(Components.Position);
    while(it.next()) |entity| {
        if(entity.getOneComponent(Components.Velocity)) |velocity| {
            var pos = entity.getOneComponent(Components.Position).?;
            pos.x += velocity.x;
            pos.y += velocity.y;
        }
    }
}
```

## Next Steps

- Check out the [C API Guide](c-api-guide.md) for C language integration
- Learn about [Performance Optimization](performance-guide.md) for large-scale applications
- Read the [Core Concepts](core-concepts.md) for a deeper understanding of ECS 