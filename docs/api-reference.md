# Coyote ECS API Reference

This document provides a comprehensive reference for the Coyote ECS API, including all major functions, structs, and types.

## Table of Contents

- [World](#world)
- [Entity](#entity)
- [Component](#component)
- [SuperComponents](#supercomponents)
- [SuperEntities](#superentities)
- [Command Buffer](#command-buffer)
- [Scheduler](#scheduler)
- [Resources](#resources)
- [Events and Observers](#events-and-observers)
- [Systems](#systems)
- [Iterators](#iterators)
- [SIMD Optimizations](#simd-optimizations)
- [C API](#c-api)
- [Utility Functions](#utility-functions)

## World

The `World` struct is the main container for all entities, components, and systems in the ECS.

### Functions

#### `create() !*World`

Creates a new ECS world.

```zig
var world = try World.create();
defer world.destroy();
```

#### `destroy(self: *World) void`

Destroys the world and all its entities and components.

```zig
world.destroy();
```

## Entity

The `Entity` struct represents an entity in the ECS.

### Functions

#### `create(ctx: *SuperEntities) !*Entity`

Creates a new entity.

```zig
const entity = try world.entities.create();
```

#### `destroy(self: *Entity) void`

Destroys the entity, releases all owned components, and bumps generation.

```zig
entity.destroy();
```

#### `addComponent(ctx: *Entity, comp_val: anytype) !*Component`

Adds a component to the entity.

```zig
const component = try entity.addComponent(MyComponent{ .value = 42 });
```

#### `getOneComponent(ctx: *Entity, comptime comp_type: type) ?*const Component`

Gets the underlying component handle of the specified type (legacy accessor).

```zig
if (entity.getOneComponent(MyComponent)) |component| {
    // Use component handle
}
```

#### `has(ctx: *Entity, comptime comp_type: type) bool`

Returns true if the entity owns a component of the given type.

```zig
if (entity.has(MyComponent)) { /* ... */ }
```

#### `get(ctx: *Entity, comptime comp_type: type) ?*comp_type`

Returns a typed pointer to component data, or null.

```zig
if (entity.get(MyComponent)) |data| {
    data.value += 1;
}
```

#### `remove(ctx: *Entity, comptime comp_type: type) !void`

Detaches and destroys all components of the given type owned by this entity.

```zig
try entity.remove(MyComponent);
```

#### `ref(self: *const Entity) EntityRef`

Returns a stable, copyable handle for this entity.

```zig
const handle = entity.ref();
```

#### `attach(self: *Entity, component: *Component, comp_type: anytype) !void`

Attaches a component to the entity.

```zig
try entity.attach(component, MyComponent{ .value = 42 });
```

#### `detach(self: *Entity, component: *Component) !void`

Detaches a component from the entity.

```zig
try entity.detach(component);
```

#### `set(self: *Entity, component: *Component, comptime comp_type: type, members: anytype) !void`

Sets the values of a component.

```zig
try entity.set(component, MyComponent, .{ .value = 42 });
```

## Component

The `Component` struct represents a component in the ECS.

### Functions

#### `is(self: *const Component, comp_type: anytype) bool`

Checks if the component is of the specified type.

```zig
if (component.is(MyComponent)) {
    // Component is of type MyComponent
}
```

#### `set(component: *Component, comptime comp_type: type, members: anytype) !void`

Sets the values of the component.

```zig
try component.set(MyComponent, .{ .value = 42 });
```

#### `detach(self: *Component) void`

Detaches the component from all entities.

```zig
component.detach();
```

#### `dealloc(self: *Component) void`

Deallocates the component's data.

```zig
component.dealloc();
```

#### `destroy(self: *Component) void`

Destroys the component.

```zig
component.destroy();
```

## SuperComponents

The `SuperComponents` struct manages all components in the ECS.

### Functions

#### `count(ctx: *SuperComponents) u32`

Returns the total number of components.

```zig
const count = world.components.count();
```

#### `create(ctx: *SuperComponents, comptime comp_type: type) !*Component`

Creates a new component of the specified type.

```zig
const component = try world.components.create(MyComponent);
```

#### `create_c(ctx: *SuperComponents, comp_type: c_type) !*Component`

Creates a new component from a C type.

```zig
const component = try world.components.create_c(my_c_type);
```

#### `expand(ctx: *SuperComponents) !void`

Expands the component storage.

```zig
try world.components.expand();
```

#### `gc(ctx: *SuperComponents) void`

Runs garbage collection on components.

```zig
world.components.gc();
```

#### `iterator(ctx: *SuperComponents) SuperComponents.Iterator`

Returns an iterator over all components.

```zig
var it = world.components.iterator();
while (it.next()) |component| {
    // Process component
}
```

#### `iteratorFilter(ctx: *SuperComponents, comptime comp_type: type) SuperComponents.MaskedIterator`

Returns an iterator over components of the specified type.

```zig
var it = world.components.iteratorFilter(MyComponent);
while (it.next()) |component| {
    // Process component
}
```

#### `iteratorFilterRange(ctx: *SuperComponents, comptime comp_type: type, start_idx: usize, end_idx: usize) SuperComponents.MaskedRangeIterator`

Returns an iterator over components of the specified type within a range.

```zig
var it = world.components.iteratorFilterRange(MyComponent, 0, 100);
while (it.next()) |component| {
    // Process component
}
```

#### `iteratorFilterByEntity(ctx: *SuperComponents, entity: *Entity, comptime comp_type: type) SuperComponents.MaskedEntityIterator`

Returns an iterator over components of the specified type attached to an entity.

```zig
var it = world.components.iteratorFilterByEntity(entity, MyComponent);
while (it.next()) |component| {
    // Process component
}
```

## SuperEntities

The `SuperEntities` struct manages all entities in the ECS.

### Functions

#### `count(ctx: *SuperEntities) u32`

Returns the total number of entities.

```zig
const count = world.entities.count();
```

#### `create(ctx: *SuperEntities) !*Entity`

Creates a new entity.

```zig
const entity = try world.entities.create();
```

#### `expand(ctx: *SuperEntities) !void`

Expands the entity storage.

```zig
try world.entities.expand();
```

#### `iterator(ctx: *SuperEntities) SuperEntities.Iterator`

Returns an iterator over all entities.

```zig
var it = world.entities.iterator();
while (it.next()) |entity| {
    // Process entity
}
```

#### `iteratorFilter(ctx: *SuperEntities, comptime comp_type: type) SuperEntities.MaskedIterator`

Returns an iterator over entities with components of the specified type.

```zig
var it = world.entities.iteratorFilter(MyComponent);
while (it.next()) |entity| {
    // Process entity
}
```

#### `query(ctx: *SuperEntities, comptime include: anytype) SuperEntities.QueryIterator`

Multi-component AND query. Yields entities owning every type in the tuple.

```zig
var q = world.entities.query(.{ Position, Velocity });
while (q.next()) |entity| { /* ... */ }
```

#### `queryExclude(ctx: *SuperEntities, comptime include: anytype, comptime exclude: anytype) SuperEntities.QueryIterator`

AND + NOT query. Yields entities with all include types and none of the exclude types.

```zig
var q = world.entities.queryExclude(.{Position}, .{Velocity});
while (q.next()) |entity| { /* ... */ }
```

#### `resolve(ctx: *SuperEntities, handle: EntityRef) ?*Entity`

Resolves a stored handle to the live entity, or null if stale.

```zig
if (world.entities.resolve(handle)) |entity| { /* ... */ }
```

#### `isValid(ctx: *SuperEntities, handle: EntityRef) bool`

Returns true if the handle still refers to a live entity.

```zig
if (world.entities.isValid(handle)) { /* ... */ }
```

## Command Buffer

Deferred structural mutations. Apply with `flush()`.

| Function | Description |
|----------|-------------|
| `world.commandBuffer()` | Create a buffer bound to the world |
| `cb.deinit()` | Free the buffer |
| `cb.createEntity()` | Record a deferred spawn (`Deferred` placeholder) |
| `cb.destroyEntity(ref)` | Record destroy by `EntityRef` |
| `cb.destroyDeferred(d)` | Record destroy by placeholder |
| `cb.attachDeferred(d, component, T)` | Attach to deferred entity |
| `cb.attach(ref, component, T)` | Attach to resolved entity |
| `cb.remove(ref, T)` / `cb.removeDeferred(d, T)` | Remove component type |
| `cb.flush()` | Apply all commands in order, then reset |
| `cb.reset()` | Discard without applying |

## Scheduler

Staged system execution. Flushes the command buffer after each stage.

| Function | Description |
|----------|-------------|
| `world.scheduler()` | Create a scheduler bound to the world |
| `sched.deinit()` | Free the scheduler |
| `sched.addSystem(stage, fn)` | Register a `SystemFn` |
| `sched.addSystemC(stage, cb, user_data)` | Register a C callback |
| `sched.run()` | Run all stages in order |

### SystemContext

Passed to scheduler systems:

```zig
pub fn MySystem(ctx: *SystemContext) !void {
    _ = ctx.world;
    _ = ctx.commands;           // shared CommandBuffer
    _ = ctx.resource(GameTime); // optional singleton access
    _ = ctx.events();           // Events queue
}
```

## Resources

World-scoped singletons (`World.resources`).

| Function | Description |
|----------|-------------|
| `world.insertResource(T, value)` | Insert or replace |
| `world.getResource(T) ?*T` | Get mutable pointer |
| `world.removeResource(T)` | Remove and free |

## Events and Observers

### Events (queued)

| Function | Description |
|----------|-------------|
| `world.events.drainStructural(handler)` | Process lifecycle events |
| `world.events.drainCustom(T, handler)` | Process typed custom events |
| `world.events.clearAll()` | Discard all queued events |
| `world.emitEvent(T, value)` | Enqueue a custom event |

`StructuralEvent` fields: `kind` (`EventKind`), `entity` (`EntityRef`), `component`, `type_id`.

### Observers (synchronous)

| Function | Description |
|----------|-------------|
| `world.onEntitySpawn(cb)` | Fires when entity spawns |
| `world.onEntityDestroy(cb)` | Fires when entity destroyed |
| `world.onComponentAdd(T, cb)` | Fires when component attached |
| `world.onComponentRemove(T, cb)` | Fires when component detached |
| `world.onComponentChange(T, cb)` | Fires when component data set |
| `observe_all` | Wildcard type id for `onComponentAddId` etc. |

### EntityRef

```zig
pub const EntityRef = extern struct {
    chunk: u32,
    id: u32,
    generation: u32,
    pub fn toGlobalId(self: EntityRef) u64;
};
```

Helper: `entityRefFromGlobalId(gid: u64) EntityRef`

## Systems

The `Systems` struct provides functionality for running systems in the ECS.

### Functions

#### `run(comptime f: anytype, args: anytype) !void`

Runs a system function.

```zig
try Systems.run(updateSystem, .{world});
```

## Iterators

Coyote ECS provides several iterator types for iterating over entities and components.

### Iterator Types

#### `SuperComponents.Iterator`

Iterates over all components.

#### `SuperComponents.MaskedIterator`

Iterates over components of a specific type.

#### `SuperComponents.MaskedRangeIterator`

Iterates over components of a specific type within a range.

#### `SuperComponents.MaskedEntityIterator`

Iterates over components of a specific type attached to an entity.

#### `SuperEntities.Iterator`

Iterates over all entities.

#### `SuperEntities.MaskedIterator`

Iterates over entities with components of a specific type.

### Iterator Methods

#### `next(it: *Iterator) ?*Component`

Returns the next component in the iterator.

```zig
while (it.next()) |component| {
    // Process component
}
```

## SIMD Optimizations

Coyote ECS provides SIMD (Single Instruction, Multiple Data) optimizations for efficient processing of components.

### Functions

#### `processComponentsSimd(ctx: *_Components, comptime comp_type: type, processor: fn (*comp_type) void) void`

Processes components of the specified type using SIMD operations.

```zig
world._components[0].processComponentsSimd(MyComponent, |component| {
    // Process component
});
```

#### `processComponentsRangeSimd(ctx: *_Components, comptime comp_type: type, start_idx: usize, end_idx: usize, processor: fn (*comp_type) void) void`

Processes components of the specified type within a range using SIMD operations.

```zig
world._components[0].processComponentsRangeSimd(MyComponent, 0, 100, |component| {
    // Process component
});
```

### Iterator Types with SIMD Support

#### `SuperComponents.MaskedIterator`

Iterates over components of a specific type using SIMD operations for mask checks.

```zig
var it = world.components.iteratorFilter(MyComponent);
while (it.next()) |component| {
    // Process component
}
```

#### `SuperComponents.MaskedRangeIterator`

Iterates over components of a specific type within a range using SIMD operations for mask checks.

```zig
var it = world.components.iteratorFilterRange(MyComponent, 0, 100);
while (it.next()) |component| {
    // Process component
}
```

#### `SuperComponents.MaskedEntityIterator`

Iterates over components of a specific type attached to an entity using SIMD operations for mask checks.

```zig
var it = world.components.iteratorFilterByEntity(entity, MyComponent);
while (it.next()) |component| {
    // Process component
}
```

For more details on SIMD optimizations, see the [Advanced Optimizations](advanced-optimizations.md) guide.

## C API

Coyote ECS provides a C API for cross-language compatibility. See [c-api-guide.md](c-api-guide.md) for full examples.

### Types

```c
typedef uintptr_t world;
typedef uintptr_t entity;
typedef uintptr_t component;
typedef uintptr_t iterator;
typedef uint64_t coyote_entity_ref;
typedef uintptr_t command_buffer;
typedef uintptr_t scheduler;

typedef struct coyote_type {
    uintptr_t id;
    uintptr_t size;
    uint8_t alignof;
    const char* name;
} coyote_type;

#define COYOTE_MAKE_TYPE(TypeId, TypeName) { ... }
```

### World and Entity

| Function | Description |
|----------|-------------|
| `coyote_world_create()` | Create world |
| `coyote_world_destroy(world)` | Destroy world |
| `coyote_entity_create(world)` | Create entity |
| `coyote_entity_destroy(entity)` | Destroy entity |
| `coyote_entity_handle(entity)` | Get `coyote_entity_ref` |
| `coyote_entity_generation(entity)` | Get generation |
| `coyote_entity_resolve(world, handle)` | Resolve handle to entity |
| `coyote_entity_is_valid(world, handle)` | Check handle validity |
| `coyote_entity_has(entity, type)` | Check component ownership |
| `coyote_entity_get(entity, type)` | Get component data pointer |
| `coyote_entity_remove(entity, type)` | Remove component type |
| `coyote_entity_attach(entity, component, type)` | Attach component |
| `coyote_entity_detach(entity, component)` | Detach component |
| `coyote_entities_count(world)` | Live entity count |

### Components and Iteration

| Function | Description |
|----------|-------------|
| `coyote_component_create(world, type)` | Create component |
| `coyote_component_destroy(component)` | Destroy component |
| `coyote_component_get(component)` | Get data pointer |
| `coyote_component_is(component, type)` | Type check |
| `coyote_components_count(world)` | Live component count |
| `coyote_components_gc(world)` | Garbage collect |
| `coyote_components_iterator_filter(world, type)` | Filter by type |
| `coyote_components_iterator_filter_next(it)` | Next component |
| `coyote_entities_iterator_filter(world, type)` | Entities by type |
| `coyote_entities_iterator_filter_next(it)` | Next entity |
| `coyote_entities_query(world, include, n, exclude, n)` | Multi-component query |
| `coyote_entities_query_next(it)` | Next query result |

### Command Buffer

| Function | Description |
|----------|-------------|
| `coyote_command_buffer_create(world)` | Create buffer |
| `coyote_command_buffer_destroy(cb)` | Destroy buffer |
| `coyote_command_buffer_flush(cb)` | Apply + reset |
| `coyote_command_buffer_reset(cb)` | Discard without apply |
| `coyote_cb_spawn(cb)` | Deferred entity placeholder |
| `coyote_cb_destroy_entity(cb, handle)` | Record destroy |
| `coyote_cb_attach(cb, handle, component, type)` | Record attach |
| `coyote_cb_remove(cb, handle, type)` | Record remove |
| `coyote_cb_*_deferred(...)` | Same for placeholder entities |

### Scheduler

| Function | Description |
|----------|-------------|
| `coyote_scheduler_create(world)` | Create scheduler |
| `coyote_scheduler_destroy(sched)` | Destroy scheduler |
| `coyote_scheduler_add_stage(sched)` | Add stage, returns index |
| `coyote_scheduler_add_system(sched, stage, fn, user_data)` | Register system |
| `coyote_scheduler_run(sched)` | Run all stages |

### Resources

| Function | Description |
|----------|-------------|
| `coyote_resource_insert(world, type, data)` | Insert singleton |
| `coyote_resource_get(world, type)` | Get pointer |
| `coyote_resource_has(world, type)` | Check existence |
| `coyote_resource_remove(world, type)` | Remove singleton |

### Events and Observers

| Function | Description |
|----------|-------------|
| `coyote_events_count(world)` | Queued event count |
| `coyote_events_emit(world, type, data)` | Emit custom event |
| `coyote_events_drain_structural(world, handler, user_data)` | Drain lifecycle |
| `coyote_events_clear(world)` | Clear queue |
| `coyote_observer_on_entity_spawn(...)` | Spawn observer |
| `coyote_observer_on_entity_destroy(...)` | Destroy observer |
| `coyote_observer_on_component_add(...)` | Add observer |
| `coyote_observer_on_component_add_any(...)` | Add observer (all types) |
| `coyote_observer_on_component_remove(...)` | Remove observer |
| `coyote_observer_on_component_change(...)` | Change observer |

For more details, see the [C API Guide](c-api-guide.md).

## Utility Functions

### `Cast(comptime T: type, component: ?*Component) *T`

Casts a component to a specific type.

```zig
const typed_component = Cast(MyComponent, component);
```

### `CastData(comptime T: type, component: ?*anyopaque) *T`

Casts component data to a specific type.

```zig
const typed_data = CastData(MyComponent, component.data);
```

### `typeToId(comptime T: type) u32`

Converts a type to an ID.

```zig
const id = typeToId(MyComponent);
```

### `typeToIdC(comp_type: c_type) u32`

Converts a C type to an ID.

```zig
const id = typeToIdC(my_c_type);
```

### `opaqueDestroy(self: std.mem.Allocator, ptr: anytype, sz: usize, alignment: u8) void`

Destroys an opaque pointer.

```zig
opaqueDestroy(allocator, ptr, size, alignment);
``` 