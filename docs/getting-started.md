# Getting Started with Coyote ECS

This guide will help you get started with Coyote ECS in your Zig project.

Coyote ECS requires **Zig 0.17.0** or later.

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
defer world.destroy();
```

### 3. Create Entities and Components

```zig
// Create an entity
var entity = try world.entities.create();

// Shortcut: create + attach in one step
_ = try entity.addComponent(Components.Position{ .x = 0, .y = 0 });
_ = try entity.addComponent(Components.Velocity{ .x = 1, .y = 1 });

// Or create components separately and attach
var position = try world.components.create(Components.Position);
try entity.attach(position, Components.Position{ .x = 0, .y = 0 });
```

### 4. Access Components on an Entity

Use `has`, `get`, and `remove` for typed access:

```zig
if (entity.has(Components.Position)) {
    if (entity.get(Components.Position)) |pos| {
        pos.x += 1;
    }
}

try entity.remove(Components.Velocity);
```

### 5. Query Entities

Multi-component queries filter by AND / NOT:

```zig
// Entities with Position AND Velocity
var q = world.entities.query(.{ Components.Position, Components.Velocity });
while (q.next()) |e| {
    if (e.get(Components.Velocity)) |vel| {
        if (e.get(Components.Position)) |pos| {
            pos.x += vel.x;
            pos.y += vel.y;
        }
    }
}

// Entities with Position but NOT Velocity
var q2 = world.entities.queryExclude(.{Components.Position}, .{Components.Velocity});
while (q2.next()) |e| {
    _ = e;
}
```

Single-type filtering still works via `iteratorFilter`:

```zig
var it = world.entities.iteratorFilter(Components.Position);
while (it.next()) |e| {
    // ...
}
```

### 6. Run Systems

For simple scripts, use `Systems.run`:

```zig
pub fn UpdatePosition(world: *World) !void {
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

try Systems.run(UpdatePosition, .{world});
```

For staged game loops with deferred structural changes, use the [Scheduler and Command Buffer](game-loop.md).

## Next Steps

- [Core Concepts](core-concepts.md) — entities, components, queries, handles
- [Game Loop](game-loop.md) — scheduler, command buffer, resources, events
- [Examples](examples.md) — fruit garden, physics, scheduler demo
- [API Reference](api-reference.md) — full function list
- [Performance Guide](performance-guide.md)

## Common Patterns

### Generational Entity Handles

Store `EntityRef` when an entity may be destroyed and its slot recycled:

```zig
const handle = entity.ref();

entity.destroy();

try std.testing.expect(!world.entities.isValid(handle));
try std.testing.expect(world.entities.resolve(handle) == null);
```

### Component Lifecycle

```zig
// Create
var component = try world.components.create(Components.Position);

// Attach
try entity.attach(component, Components.Position{ .x = 0, .y = 0 });

// Detach
try entity.detach(component);

// Destroy (also called automatically when no owners remain)
component.destroy();
```

### World Resources

Singletons shared across systems:

```zig
const GameTime = struct { tick: u32 = 0 };

try world.insertResource(GameTime, .{ .tick = 0 });
if (world.getResource(GameTime)) |time| {
    time.tick += 1;
}
```
