# Performance Guide

This guide provides tips and best practices for optimizing your Coyote ECS applications.

## Memory Layout

Coyote ECS is designed with performance in mind. Understanding its memory layout can help you optimize your usage:

### Component Storage

Components are stored in contiguous memory blocks, which provides several benefits:

1. Better cache utilization
2. Reduced memory fragmentation
3. Efficient iteration over components of the same type

```zig
// Good: Components are stored contiguously
var it = world.components.iteratorFilter(Components.Position);
while(it.next()) |component| {
    // Fast iteration due to contiguous memory
}
```

## Component Design

### Keep Components Small

Small components are more efficient to copy and move:

```zig
// Good: Small, focused component
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

// Bad: Large component with mixed concerns
pub const GameObject = struct {
    position: Position,
    velocity: Velocity,
    health: f32,
    inventory: [100]Item,
    // ... many more fields
};
```

### Use Appropriate Types

Choose the most appropriate types for your data:

```zig
// Good: Using appropriate types
pub const Transform = struct {
    x: f32,  // For precise positioning
    y: f32,
    scale: f32,
    rotation: f32,
};

// Bad: Using larger types than needed
pub const Transform = struct {
    x: f64,  // Unnecessary precision
    y: f64,
    scale: f64,
    rotation: f64,
};
```

## Entity Management

### Batch Entity Creation

Create entities in batches when possible:

```zig
// Good: Batch creation
var i: usize = 0;
while(i < 1000) : (i += 1) {
    var entity = try world.entities.create();
    // ... setup entity
}

// Bad: Creating entities one at a time in different places
var entity1 = try world.entities.create();
// ... some code ...
var entity2 = try world.entities.create();
// ... more code ...
var entity3 = try world.entities.create();
```

### Efficient Entity Destruction

Destroy entities in batches when possible:

```zig
// Good: Batch destruction
var it = world.entities.iterator();
while(it.next()) |entity| {
    entity.destroy();
}

// Bad: Destroying entities one at a time
entity1.destroy();
// ... some code ...
entity2.destroy();
// ... more code ...
entity3.destroy();
```

## Component Access Patterns

### Minimize Component Access

Access components only when needed:

```zig
// Good: Minimal component access
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

// Bad: Frequent component access
pub fn UpdatePosition(world: *World) void {
    var it = world.entities.iterator();
    while(it.next()) |entity| {
        if(entity.getOneComponent(Components.Position)) |pos| {
            if(entity.getOneComponent(Components.Velocity)) |vel| {
                pos.x += vel.x;
                pos.y += vel.y;
            }
        }
    }
}
```

### Use Iterator Filters

Use iterator filters to process only relevant components:

```zig
// Good: Using iterator filters
var it = world.components.iteratorFilter(Components.Position);
while(it.next()) |component| {
    // Process only position components
}

// Bad: Checking component type manually
var it = world.components.iterator();
while(it.next()) |component| {
    if(component.is(Components.Position)) {
        // Process position component
    }
}
```

## System Design

### Keep Systems Focused

Design systems to do one thing well:

```zig
// Good: Focused systems
pub fn UpdatePosition(world: *World) void {
    // Only updates position
}

pub fn UpdateVelocity(world: *World) void {
    // Only updates velocity
}

// Bad: Systems doing too much
pub fn UpdatePhysics(world: *World) void {
    // Updates position, velocity, acceleration, forces, etc.
}
```

### Batch Processing

Process components in batches when possible:

```zig
// Good: Batch processing
pub fn UpdatePositions(world: *World) void {
    var it = world.components.iteratorFilter(Components.Position);
    while(it.next()) |component| {
        // Process multiple components at once
    }
}

// Bad: Processing one at a time
pub fn UpdatePosition(world: *World) void {
    var it = world.components.iteratorFilter(Components.Position);
    while(it.next()) |component| {
        // Process one component at a time
    }
}
```

## Memory Management

### Use the Garbage Collector

Call the garbage collector when appropriate:

```zig
// Good: Using GC after batch operations
world.components.gc();

// Bad: Calling GC too frequently
while(some_condition) {
    // ... process components
    world.components.gc();  // Too frequent
}
```

### Clean Up Resources

Destroy components and entities when they're no longer needed:

```zig
// Good: Proper cleanup
component.destroy();
entity.destroy();

// Bad: Leaving resources allocated
// component and entity remain allocated
```

## C API Performance

### Minimize C API Calls

Reduce the number of C API calls when possible:

```c
// Good: Fewer API calls
component c = coyote_component_create(world, t_position);
coyote_entity_attach(e, c, t_position);
position* pos = coyote_component_get(c);
pos->x = 0.0f;
pos->y = 0.0f;

// Bad: Many API calls
component c = coyote_component_create(world, t_position);
coyote_entity_attach(e, c, t_position);
position* pos = coyote_component_get(c);
coyote_component_set(c, t_position, &(position){0.0f, 0.0f});
```

### Use Appropriate Data Structures

Choose appropriate data structures for your C components:

```c
// Good: Simple struct
typedef struct position {
    float x;
    float y;
} position;

// Bad: Complex nested structures
typedef struct game_object {
    struct {
        float x;
        float y;
    } position;
    struct {
        float x;
        float y;
    } velocity;
    // ... many more nested structures
} game_object;
```

## Benchmarking

Use the [coyote-bunnies](https://github.com/linuxy/coyote-bunnies) benchmark to measure performance:

```zig
// Run the benchmark
zig build -Doptimize=ReleaseFast
./zig-out/bin/benchmark
```

## Advanced Optimizations

For more advanced optimization techniques, including SIMD operations, vectorization, and parallel processing, check out the [Advanced Optimizations Guide](advanced-optimizations.md).

## Next Steps

- Check out the [Examples](examples.md) for performance-oriented examples
- Read the [Core Concepts](core-concepts.md) for a deeper understanding of ECS
- Explore the [C API Guide](c-api-guide.md) for C-specific optimizations
- Learn about [Advanced Optimizations](advanced-optimizations.md) including SIMD and vectorization 