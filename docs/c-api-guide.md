# C API Guide

This guide explains how to use Coyote ECS from C code. Coyote ECS provides a C API that allows you to use the ECS functionality in C projects.

## Getting Started

### Including the Header

```c
#include <coyote.h>
```

### Basic Types

The C API provides the following basic types:

```c
typedef uintptr_t world;
typedef uintptr_t entity;
typedef uintptr_t component;
typedef uintptr_t iterator;
typedef uintptr_t coyote_type;
```

## Creating a World

```c
world world = coyote_world_create();
if (world == 0) {
    // Handle error
}
```

## Defining Components

Components in C are defined as structs:

```c
typedef struct position {
    float x;
    float y;
} position;

typedef struct velocity {
    float x;
    float y;
} velocity;
```

## Creating Component Types

Use the `COYOTE_MAKE_TYPE` macro to create component types:

```c
static const coyote_type t_position = COYOTE_MAKE_TYPE(0, position);
static const coyote_type t_velocity = COYOTE_MAKE_TYPE(1, velocity);
```

## Creating Entities and Components

```c
// Create an entity
entity e = coyote_entity_create(world);

// Create components
component c_pos = coyote_component_create(world, t_position);
component c_vel = coyote_component_create(world, t_velocity);

// Attach components to entity
coyote_entity_attach(e, c_pos, t_position);
coyote_entity_attach(e, c_vel, t_velocity);

// Set component data
position* pos = coyote_component_get(c_pos);
pos->x = 0.0f;
pos->y = 0.0f;

velocity* vel = coyote_component_get(c_vel);
vel->x = 1.0f;
vel->y = 1.0f;
```

## Iterating Over Components

```c
// Iterate over all components of a specific type
iterator it = coyote_components_iterator_filter(world, t_position);
component next;
while ((next = coyote_components_iterator_filter_next(it)) != 0) {
    position* pos = coyote_component_get(next);
    // Work with the position component
}
```

## Iterating Over Entities

```c
// Iterate over entities with specific components
iterator it = coyote_entities_iterator_filter(world, t_position);
entity next;
while ((next = coyote_entities_iterator_filter_next(it)) != 0) {
    component c = coyote_entity_get_component(next, t_velocity);
    if (c != 0) {
        velocity* vel = coyote_component_get(c);
        // Entity has both position and velocity
    }
}
```

## Component Management

### Checking Component Type

```c
if (coyote_component_is(component, t_position)) {
    // Component is a position
}
```

### Detaching Components

```c
coyote_entity_detach(entity, component);
```

### Destroying Components

```c
coyote_component_destroy(component);
```

## Entity Management

### Destroying Entities

```c
coyote_entity_destroy(entity);
```

### Getting Entity Count

```c
size_t count = coyote_entities_count(world);
```

## Complete Example

Here's a complete example showing how to use the C API:

```c
#include <stdio.h>
#include <coyote.h>

typedef struct position {
    float x;
    float y;
} position;

typedef struct velocity {
    float x;
    float y;
} velocity;

static const coyote_type t_position = COYOTE_MAKE_TYPE(0, position);
static const coyote_type t_velocity = COYOTE_MAKE_TYPE(1, velocity);

int main(void) {
    // Create world
    world world = coyote_world_create();
    if (world == 0) {
        printf("Failed to create world\n");
        return 1;
    }

    // Create entity
    entity e = coyote_entity_create(world);
    
    // Create and attach components
    component c_pos = coyote_component_create(world, t_position);
    component c_vel = coyote_component_create(world, t_velocity);
    
    coyote_entity_attach(e, c_pos, t_position);
    coyote_entity_attach(e, c_vel, t_velocity);

    // Set component data
    position* pos = coyote_component_get(c_pos);
    pos->x = 0.0f;
    pos->y = 0.0f;

    velocity* vel = coyote_component_get(c_vel);
    vel->x = 1.0f;
    vel->y = 1.0f;

    // Iterate over components
    iterator it = coyote_components_iterator_filter(world, t_position);
    component next;
    while ((next = coyote_components_iterator_filter_next(it)) != 0) {
        position* p = coyote_component_get(next);
        printf("Position: (%f, %f)\n", p->x, p->y);
    }

    // Cleanup
    coyote_entity_detach(e, c_pos);
    coyote_entity_detach(e, c_vel);
    coyote_component_destroy(c_pos);
    coyote_component_destroy(c_vel);
    coyote_entity_destroy(e);
    coyote_world_destroy(world);

    return 0;
}
```

## Best Practices

1. Always check return values from API functions
2. Clean up resources properly (destroy components and entities)
3. Use appropriate error handling
4. Keep component structs simple and focused
5. Use meaningful type IDs when creating component types
6. Consider using enums for component type IDs

## Next Steps

- Check out the [Examples](examples.md) for more usage patterns
- Learn about [Performance Optimization](performance-guide.md) for C code
- Read the [Core Concepts](core-concepts.md) for a deeper understanding of ECS 