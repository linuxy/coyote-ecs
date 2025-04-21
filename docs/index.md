# Coyote ECS Documentation

Welcome to the Coyote ECS documentation! Coyote ECS is a fast and simple Entity Component System (ECS) written in Zig.

## Quick Links

- [Getting Started](getting-started.md)
- [Core Concepts](core-concepts.md)
- [API Reference](api-reference.md)
- [Examples](examples.md)
- [C API Guide](c-api-guide.md)
- [Performance Guide](performance-guide.md)

## What is Coyote ECS?

Coyote ECS is a lightweight, high-performance Entity Component System designed for Zig applications. It provides a simple yet powerful way to manage game objects, simulations, and other entity-based systems.

### Key Features

- Fast and efficient component storage
- Simple and intuitive API
- C bindings for cross-language compatibility
- Zero dependencies
- Built with Zig 0.14.0

## Quick Example

```zig
const std = @import("std");
const ecs = @import("coyote-ecs");

// Define your components
pub const Components = struct {
    pub const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };
};

// Create a world and entities
var world = try World.create();
defer world.deinit();

var entity = try world.entities.create();
var position = try world.components.create(Components.Position);
try entity.attach(position, Components.Position{ .x = 0, .y = 0 });
```

## Getting Started

Check out our [Getting Started Guide](getting-started.md) to begin using Coyote ECS in your project.

## Contributing

We welcome contributions! Please see our [Contributing Guide](contributing.md) for details on how to get involved.

## License

Coyote ECS is licensed under the same terms as Zig. See the [LICENSE](../LICENSE) file for details. 