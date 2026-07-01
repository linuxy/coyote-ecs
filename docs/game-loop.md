# Game Loop: Scheduler, Command Buffer, Resources, and Events

Coyote ECS provides the building blocks for a standard game/simulation loop: deferred structural changes, staged systems, shared singleton state, and lifecycle notifications.

## Overview

| Feature | Purpose |
|---------|---------|
| **Command buffer** | Record spawns/despawns/attaches during iteration; apply later |
| **Scheduler** | Run systems in ordered stages; flush the command buffer between stages |
| **Resources** | World-scoped singletons (time, input, config) |
| **Events** | Queued lifecycle notifications for deferred reaction |
| **Observers** | Synchronous callbacks when changes commit |

Typical frame flow:

```zig
try world.insertResource(GameTime, .{ .tick = frame });

var sched = world.scheduler();
defer sched.deinit();
try sched.addSystem(0, InputSystem);
try sched.addSystem(1, SimulationSystem);   // records into command buffer
try sched.addSystem(2, DrainEvents);         // drains event queue
try sched.addSystem(3, RenderSystem);
try sched.run(); // flushes commands after each stage
```

## Command Buffer

Use a command buffer when you must not mutate the world mid-iteration (during a query or entity loop). Record changes now, apply them on `flush()`.

```zig
var cb = world.commandBuffer();
defer cb.deinit();

// Existing entity
try cb.destroyEntity(entity.ref());

// Deferred spawn: placeholder usable in the same batch
const spawned = try cb.createEntity();
try cb.attachDeferred(spawned, Components.Apple{ .color = 1, .ripe = false, .harvested = false });

try cb.flush(); // apply in order, then reset
```

Commands targeting an entity destroyed earlier in the same batch are skipped (no stale resurrection).

### System integration

Systems receive a shared command buffer through `SystemContext`:

```zig
pub fn SpawnEnemies(ctx: *SystemContext) !void {
    const e = try ctx.commands.createEntity();
    try ctx.commands.attachDeferred(e, Components.Enemy{ .hp = 10 });
}
```

The scheduler owns the buffer and calls `flush()` at the end of each stage.

## Scheduler

Systems are grouped into **stages**. Stages run in creation order; within a stage, systems run in registration order. The command buffer is flushed after every stage, so structural changes from stage *N* are visible to stage *N+1* but never mid-stage.

```zig
var sched = world.scheduler();
defer sched.deinit();

try sched.addSystem(0, PhysicsSystem);
try sched.addSystem(0, CollisionSystem); // same stage, runs after Physics
try sched.addSystem(1, CleanupSystem);   // next stage, sees stage-0 flushes

try sched.run();
```

System signature:

```zig
pub fn MySystem(ctx: *SystemContext) !void {
    _ = ctx.world;
    _ = ctx.commands;
}
```

## Resources (Singletons)

One value per type per world — ideal for frame time, RNG, input state, or asset tables.

```zig
const GameTime = struct { tick: u32 = 0, dt: f32 = 0 };

try world.insertResource(GameTime, .{ .tick = 0, .dt = 1.0 / 60.0 });

if (world.getResource(GameTime)) |time| {
    time.tick += 1;
}

// Inside a system:
if (ctx.resource(GameTime)) |time| {
    // ...
}

world.removeResource(GameTime);
```

Inserting again replaces the previous value. Resources are freed when the world is destroyed.

## Events (Queued)

Structural lifecycle changes are recorded automatically:

- `entity_spawned`, `entity_destroyed`
- `component_added`, `component_removed`, `component_changed`

Drain them in a dedicated stage (after simulation, before render):

```zig
const Counters = struct {
    var spawns: u32 = 0;
    fn onEvent(ev: ecs.StructuralEvent) void {
        if (ev.kind == .entity_spawned) spawns += 1;
    }
};

pub fn DrainEvents(ctx: *SystemContext) !void {
    ctx.events().drainStructural(Counters.onEvent);
}
```

Custom typed events:

```zig
const DamageEvent = struct { amount: u32 };

try world.emitEvent(DamageEvent, .{ .amount = 42 });
ctx.events().drainCustom(DamageEvent, handleDamage);
```

Call `world.events.clearAll()` to discard queued events without processing.

## Observers (Immediate)

Observers run synchronously when a change commits (including during command-buffer flush). Use them for logging, debug hooks, or tight coupling; use the event queue for decoupled systems.

```zig
fn onAppleAdded(world: *World, entity: *Entity, component: *Component, type_id: u32) void {
    _ = world;
    _ = type_id;
    _ = component;
    std.log.info("Apple attached to entity {}", .{entity.id});
}

try world.onComponentAdd(Components.Apple, onAppleAdded);
try world.onEntitySpawn(onSpawn);
try world.onComponentChange(Components.Health, onHealthChanged);
```

Register with a specific component type, or use `observe_all` (via `onComponentAddId`) to match every type.

## Generational Entity Handles

Store `EntityRef` instead of raw `*Entity` pointers when an entity may be destroyed and its slot recycled:

```zig
const handle = entity.ref();

entity.destroy();

try std.testing.expect(!world.entities.isValid(handle));
try std.testing.expect(world.entities.resolve(handle) == null);
```

Handles pack generation into the high 32 bits of the global id, so recycled slots never alias stale references.

## Next Steps

- [C API Guide](c-api-guide.md) — C bindings for scheduler, command buffer, resources, events
- [API Reference](api-reference.md) — full function list
- [Core Concepts](core-concepts.md) — entities, components, queries
