# Coyote ECS API Reference

This document provides a comprehensive reference for the Coyote ECS API, including all major functions, structs, and types.

## Table of Contents

- [World](#world)
- [Entity](#entity)
- [Component](#component)
- [SuperComponents](#supercomponents)
- [SuperEntities](#superentities)
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

Destroys the entity.

```zig
entity.destroy();
```

#### `addComponent(ctx: *Entity, comp_val: anytype) !*Component`

Adds a component to the entity.

```zig
const component = try entity.addComponent(MyComponent{ .value = 42 });
```

#### `getOneComponent(ctx: *Entity, comptime comp_type: type) ?*const Component`

Gets a component of the specified type from the entity.

```zig
if (entity.getOneComponent(MyComponent)) |component| {
    // Use component
}
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

Coyote ECS provides a C API for cross-language compatibility.

### Types

#### `coyote_world`

A handle to a Coyote ECS world.

```c
coyote_world world = coyote_world_create();
```

#### `coyote_entity`

A handle to a Coyote ECS entity.

```c
coyote_entity entity = coyote_entities_create(world);
```

#### `coyote_component`

A handle to a Coyote ECS component.

```c
coyote_component component = coyote_components_create(world, type);
```

#### `coyote_type`

A C type definition for components.

```c
coyote_type type = {
    .id = 1,
    .size = sizeof(MyComponent),
    .alignof = alignof(MyComponent),
    .name = "MyComponent"
};
```

#### `coyote_iterator`

A handle to a Coyote ECS iterator.

```c
coyote_iterator iterator = coyote_components_iterator(world);
```

### Functions

#### World Management

##### `coyote_world_create()`

Creates a new Coyote ECS world.

```c
coyote_world world = coyote_world_create();
```

##### `coyote_world_destroy(world)`

Destroys a Coyote ECS world.

```c
coyote_world_destroy(world);
```

#### Entity Management

##### `coyote_entities_create(world)`

Creates a new entity.

```c
coyote_entity entity = coyote_entities_create(world);
```

##### `coyote_entities_destroy(entity)`

Destroys an entity.

```c
coyote_entities_destroy(entity);
```

##### `coyote_entities_count(world)`

Returns the number of entities.

```c
size_t count = coyote_entities_count(world);
```

#### Component Management

##### `coyote_components_create(world, type)`

Creates a new component.

```c
coyote_component component = coyote_components_create(world, type);
```

##### `coyote_components_destroy(component)`

Destroys a component.

```c
coyote_components_destroy(component);
```

##### `coyote_components_count(world)`

Returns the number of components.

```c
size_t count = coyote_components_count(world);
```

##### `coyote_components_gc(world)`

Runs garbage collection on components.

```c
coyote_components_gc(world);
```

#### Component Attachment

##### `coyote_entity_attach_component(entity, component, data, size)`

Attaches a component to an entity.

```c
coyote_entity_attach_component(entity, component, &my_component_data, sizeof(MyComponent));
```

##### `coyote_entity_detach_component(entity, component)`

Detaches a component from an entity.

```c
coyote_entity_detach_component(entity, component);
```

#### Iterators

##### `coyote_components_iterator(world)`

Returns an iterator over all components.

```c
coyote_iterator iterator = coyote_components_iterator(world);
```

##### `coyote_components_iterator_next(iterator)`

Returns the next component in the iterator.

```c
coyote_component component = coyote_components_iterator_next(iterator);
```

##### `coyote_components_iterator_filter(world, type)`

Returns an iterator over components of the specified type.

```c
coyote_iterator iterator = coyote_components_iterator_filter(world, type);
```

##### `coyote_components_iterator_filter_next(iterator)`

Returns the next component in the filtered iterator.

```c
coyote_component component = coyote_components_iterator_filter_next(iterator);
```

##### `coyote_components_iterator_filter_range(world, type, start_idx, end_idx)`

Returns an iterator over components of the specified type within a range.

```c
coyote_iterator iterator = coyote_components_iterator_filter_range(world, type, 0, 100);
```

##### `coyote_components_iterator_filter_range_next(iterator)`

Returns the next component in the range iterator.

```c
coyote_component component = coyote_components_iterator_filter_range_next(iterator);
```

##### `coyote_entities_iterator(world)`

Returns an iterator over all entities.

```c
coyote_iterator iterator = coyote_entities_iterator(world);
```

##### `coyote_entities_iterator_next(iterator)`

Returns the next entity in the iterator.

```c
coyote_entity entity = coyote_entities_iterator_next(iterator);
```

##### `coyote_entities_iterator_filter(world, type)`

Returns an iterator over entities with components of the specified type.

```c
coyote_iterator iterator = coyote_entities_iterator_filter(world, type);
```

##### `coyote_entities_iterator_filter_next(iterator)`

Returns the next entity in the filtered iterator.

```c
coyote_entity entity = coyote_entities_iterator_filter_next(iterator);
```

For more details on the C API, see the [C API Guide](c-api-guide.md).

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