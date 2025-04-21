# Getting Started with Coyote ECS

This guide will help you get started with Coyote ECS in your Zig project.

## Installation

1. Clone the repository:
```bash
git clone --recursive https://github.com/linuxy/coyote-ecs.git
```

2. Add Coyote ECS to your project's `build.zig.zon`:
```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .coyote_ecs = .{
            .url = "https://github.com/linuxy/coyote-ecs/archive/main.tar.gz",
            .hash = "your-hash-here",
        },
    },
}
```

3. Import Coyote ECS in your `build.zig`:
```zig
const coyote_ecs = b.dependency("coyote_ecs", .{
    .target = target,
    .optimize = optimize,
});
```

## Basic Usage

### 1. Define Your Components

First, define your components in a container:

```zig
const std = @import("std");
const ecs = @import("coyote-ecs");

pub const Components = struct {
    pub const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    pub const Velocity = struct {
        x: f32 = 0,
        y: f32 = 0,
    };
};
```

### 2. Create a World

Create a world to manage your entities and components:

```zig
var world = try World.create();
defer world.deinit();
```

### 3. Create Entities and Components

```zig
// Create an entity
var entity = try world.entities.create();

// Create components
var position = try world.components.create(Components.Position);
var velocity = try world.components.create(Components.Velocity);

// Attach components to the entity
try entity.attach(position, Components.Position{ .x = 0, .y = 0 });
try entity.attach(velocity, Components.Velocity{ .x = 1, .y = 1 });
```

### 4. Create Systems

Systems are functions that operate on entities with specific components:

```zig
pub fn UpdatePosition(world: *World) void {
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

### 5. Run Your Systems

```zig
try Systems.run(UpdatePosition, .{world});
```

## Next Steps

- Check out the [Core Concepts](core-concepts.md) guide to learn more about how Coyote ECS works
- Explore the [Examples](examples.md) for more complex usage patterns
- Read the [API Reference](api-reference.md) for detailed documentation
- Learn about [Performance Optimization](performance-guide.md)

## Common Patterns

### Iterating Over Components

```zig
var it = world.components.iteratorFilter(Components.Position);
while(it.next()) |component| {
    // Work with the component
}
```

### Querying Entities

```zig
var it = world.entities.iteratorFilter(Components.Position);
while(it.next()) |entity| {
    if(entity.getOneComponent(Components.Velocity)) |velocity| {
        // Entity has both Position and Velocity components
    }
}
```

### Component Lifecycle

```zig
// Create
var component = try world.components.create(Components.Position);

// Attach
try entity.attach(component, Components.Position{ .x = 0, .y = 0 });

// Detach
entity.detach(component);

// Destroy
component.destroy();
``` 