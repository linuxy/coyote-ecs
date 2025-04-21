# Core Concepts

This guide explains the fundamental concepts of Entity Component Systems (ECS) and how they are implemented in Coyote ECS.

## What is an ECS?

An Entity Component System (ECS) is a software architectural pattern that is commonly used in game development and simulation software. It is based on the principle of composition over inheritance and focuses on data-oriented design.

## Key Concepts

### Entities

Entities are the basic units in an ECS. They are essentially just IDs that can have components attached to them. In Coyote ECS, entities are created through the world:

```zig
var entity = try world.entities.create();
```

### Components

Components are pure data structures that define the properties and state of entities. They contain no logic or behavior. In Coyote ECS, components are defined as Zig structs:

```zig
pub const Components = struct {
    pub const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };
};
```

### Systems

Systems contain the logic and behavior of your application. They operate on entities that have specific components. In Coyote ECS, systems are just functions that take a world as a parameter:

```zig
pub fn UpdatePosition(world: *World) void {
    var it = world.entities.iteratorFilter(Components.Position);
    while(it.next()) |entity| {
        // Update position logic here
    }
}
```

### World

The world is the container that manages all entities, components, and systems. It provides the interface for creating and managing the ECS structure:

```zig
var world = try World.create();
defer world.deinit();
```

## Component Management

### Creating Components

Components are created through the world's component manager:

```zig
var component = try world.components.create(Components.Position);
```

### Attaching Components

Components are attached to entities using the `attach` method:

```zig
try entity.attach(component, Components.Position{ .x = 0, .y = 0 });
```

### Detaching Components

Components can be detached from entities:

```zig
entity.detach(component);
```

### Destroying Components

When components are no longer needed, they should be destroyed:

```zig
component.destroy();
```

## Entity Management

### Creating Entities

Entities are created through the world:

```zig
var entity = try world.entities.create();
```

### Destroying Entities

Entities can be destroyed when they are no longer needed:

```zig
entity.destroy();
```

## Querying and Iteration

### Component Iteration

Iterate over all components of a specific type:

```zig
var it = world.components.iteratorFilter(Components.Position);
while(it.next()) |component| {
    // Work with the component
}
```

### Entity Iteration

Iterate over entities with specific components:

```zig
var it = world.entities.iteratorFilter(Components.Position);
while(it.next()) |entity| {
    // Work with the entity
}
```

### Component Access

Access components attached to an entity:

```zig
if(entity.getOneComponent(Components.Position)) |position| {
    // Work with the position component
}
```

## System Execution

Systems are executed using the `Systems.run` function:

```zig
try Systems.run(UpdatePosition, .{world});
```

## Memory Management

Coyote ECS handles memory management automatically, but you should:

1. Always call `defer world.deinit()` after creating a world
2. Destroy components when they are no longer needed
3. Destroy entities when they are no longer needed
4. Use the garbage collector when appropriate:

```zig
world.components.gc();
```

## Best Practices

1. Keep components small and focused
2. Use systems to implement behavior
3. Avoid storing references to components or entities
4. Use the iterator pattern for querying
5. Clean up resources properly
6. Use appropriate component types for your data
7. Consider performance implications of component access patterns

## Performance Considerations

1. Components are stored in contiguous memory for better cache utilization
2. Iteration is optimized for common access patterns
3. Component creation and destruction is designed to be efficient
4. The garbage collector helps manage memory without fragmentation

## Next Steps

- Check out the [Examples](examples.md) for practical usage patterns
- Read the [API Reference](api-reference.md) for detailed documentation
- Learn about [Performance Optimization](performance-guide.md) 