# Core Concepts

This guide explains the fundamental concepts of Entity Component Systems (ECS) and how they are implemented in Coyote ECS.

## What is an ECS?

An Entity Component System (ECS) is a software architectural pattern commonly used in game development and simulation software. It is based on composition over inheritance and focuses on data-oriented design.

## Key Concepts

### Entities

Entities are the basic units in an ECS — essentially IDs that can have components attached. In Coyote ECS:

```zig
var entity = try world.entities.create();
```

Each entity has a **generation** counter. When an entity is destroyed, its slot may be recycled for a new entity with a bumped generation, so stale pointers are detectable via `EntityRef`.

### Components

Components are pure data structures. They contain no logic. Define them as Zig structs:

```zig
pub const Components = struct {
    pub const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };
};
```

Components are stored in chunks and tracked with an **owner set** keyed by global entity id, so ownership is exact even across multiple entity chunks.

### Systems

Systems contain the logic of your application. They operate on entities with specific components.

Simple systems take a `*World`:

```zig
pub fn UpdatePosition(world: *World) !void {
    var q = world.entities.query(.{ Components.Position, Components.Velocity });
    while (q.next()) |entity| {
        // ...
    }
}
```

Staged systems receive a `SystemContext` with world, command buffer, and resource access — see [Game Loop](game-loop.md).

### World

The world manages entities, components, resources, events, observers, and the type registry:

```zig
var world = try World.create();
defer world.destroy();
```

## Component Management

### Creating Components

```zig
var component = try world.components.create(Components.Position);
```

Or use `entity.addComponent` to create and attach in one step.

### Attaching Components

```zig
try entity.attach(component, Components.Position{ .x = 0, .y = 0 });
```

### Accessing Components

```zig
if (entity.has(Components.Position)) { /* ... */ }

if (entity.get(Components.Position)) |pos| {
    pos.x += 1;
}

try entity.remove(Components.Position);
```

`getOneComponent` returns the underlying `*Component` handle if you need the ECS object rather than typed data.

### Detaching and Destroying

```zig
try entity.detach(component);
component.destroy(); // when no owners remain
```

When an entity is destroyed, all owned components are released automatically.

## Entity Management

### Creating and Destroying

```zig
var entity = try world.entities.create();
entity.destroy(); // bumps generation, releases owned components
```

### Generational Handles

```zig
const handle = entity.ref();                    // EntityRef
const resolved = world.entities.resolve(handle); // ?*Entity
const valid = world.entities.isValid(handle);    // bool
```

Handles pack generation in the high 32 bits of a global id. Resolving a stale handle returns `null` instead of aliasing a recycled slot.

## Querying and Iteration

### Single-Type Filters

```zig
var it = world.components.iteratorFilter(Components.Position);
while (it.next()) |component| { /* ... */ }

var it2 = world.entities.iteratorFilter(Components.Position);
while (it2.next()) |entity| { /* ... */ }
```

### Multi-Component Queries

```zig
// AND: must have every type in the tuple
var q = world.entities.query(.{ Components.Position, Components.Velocity });

// AND + NOT: must have include types, must not have exclude types
var q2 = world.entities.queryExclude(.{Components.Position}, .{Components.Velocity});

while (q.next()) |entity| { /* ... */ }
```

Queries perform a linear scan with `hasById` per filter type. This is fine for modest worlds; archetype caching is a future optimization.

## Command Buffer

Record structural changes during iteration and apply them later:

```zig
var cb = world.commandBuffer();
defer cb.deinit();

try cb.destroyEntity(entity.ref());
const spawned = try cb.createEntity();
try cb.attachDeferred(spawned, Components.Apple{});

try cb.flush();
```

The scheduler flushes the command buffer after each stage automatically.

## Scheduler

Group systems into ordered stages. Structural changes from stage *N* are visible to stage *N+1* but never mid-stage:

```zig
var sched = world.scheduler();
defer sched.deinit();

try sched.addSystem(0, PhysicsSystem);
try sched.addSystem(1, CleanupSystem);
try sched.run();
```

## Resources

World-scoped singletons — one value per type:

```zig
try world.insertResource(GameTime, .{ .tick = 0 });
if (world.getResource(GameTime)) |time| { /* ... */ }
world.removeResource(GameTime);
```

## Events and Observers

**Events** queue lifecycle notifications for deferred processing:

- `entity_spawned`, `entity_destroyed`
- `component_added`, `component_removed`, `component_changed`

```zig
world.events.drainStructural(myHandler);
try world.emitEvent(DamageEvent, .{ .amount = 10 });
```

**Observers** run synchronously when changes commit:

```zig
try world.onComponentAdd(Components.Apple, onAppleAdded);
try world.onEntitySpawn(onSpawn);
```

Use `observe_all` (via `onComponentAddId`) to match every component type.

## System Execution

### Ad-hoc

```zig
try Systems.run(UpdatePosition, .{world});
```

### Staged (recommended for game loops)

See [Game Loop](game-loop.md).

## Memory Management

1. Always call `defer world.destroy()` after creating a world
2. Destroy components when they have no owners
3. Destroy entities when no longer needed (releases owned components)
4. Run garbage collection to reclaim detached component slots:

```zig
world.components.gc();
```

## Best Practices

1. Keep components small and focused
2. Use systems for behavior; use resources for shared state
3. Prefer `EntityRef` over raw `*Entity` when storing references across frames
4. Use queries instead of nested `iteratorFilter` + `getOneComponent` when possible
5. Defer structural changes during iteration via the command buffer
6. Drain events in a dedicated stage after simulation

## Next Steps

- [Game Loop](game-loop.md) — scheduler, command buffer, resources, events
- [Examples](examples.md) — practical usage patterns
- [API Reference](api-reference.md) — detailed documentation
- [Performance Guide](performance-guide.md)
