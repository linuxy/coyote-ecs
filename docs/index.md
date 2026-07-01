# Coyote ECS Documentation

Welcome to the Coyote ECS documentation! Coyote ECS is a fast and simple Entity Component System (ECS) written in Zig.

## Quick Links

- [Getting Started](getting-started.md)
- [Core Concepts](core-concepts.md)
- [Game Loop](game-loop.md) — scheduler, command buffer, resources, events
- [API Reference](api-reference.md)
- [Examples](examples.md)
- [C API Guide](c-api-guide.md)
- [Performance Guide](performance-guide.md)

## What is Coyote ECS?

Coyote ECS is a lightweight, high-performance Entity Component System designed for Zig applications. It provides a simple yet powerful way to manage game objects, simulations, and other entity-based systems.

### Key Features

- **Zig 0.17** — current build API and stdlib compatibility
- **Entity/component accessors** — `has`, `get`, `remove` with C API parity
- **Multi-component queries** — `query` / `queryExclude` with AND + NOT filtering
- **Generational handles** — `EntityRef` survives slot recycling safely
- **Chunk-aware ownership** — exact queries and filters across entity chunks
- **Command buffer** — defer structural changes during iteration
- **Staged scheduler** — ordered systems with per-stage command flush
- **Resources** — world-scoped singletons (time, input, config)
- **Events & observers** — queued lifecycle events and synchronous hooks
- **C bindings** — full parity for the above
- Zero dependencies beyond libc

## Quick Example

```zig
const std = @import("std");
const ecs = @import("coyote-ecs");

const World = ecs.World;
const Components = struct {
    pub const Position = struct { x: f32 = 0, y: f32 = 0 };
};

pub fn main() !void {
    var world = try World.create();
    defer world.destroy();

    const entity = try world.entities.create();
    _ = try entity.addComponent(Components.Position{ .x = 10, .y = 20 });

    if (entity.get(Components.Position)) |pos| {
        std.log.info("pos: {} {}", .{ pos.x, pos.y });
    }

    var q = world.entities.query(.{Components.Position});
    while (q.next()) |e| {
        _ = e;
    }
}
```

## Getting Started

Check out the [Getting Started Guide](getting-started.md) to begin using Coyote ECS in your project.

For simulation and game loops, read the [Game Loop Guide](game-loop.md).

## License

Coyote ECS is licensed under the same terms as Zig. See the [LICENSE](../LICENSE) file for details.
