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
typedef uint64_t coyote_entity_ref;
typedef uintptr_t command_buffer;
typedef uintptr_t scheduler;

typedef struct coyote_type {
    uintptr_t id;
    uintptr_t size;
    uint8_t alignof;
    const char* name;
} coyote_type;
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

## Iterating Over Components in Chunks

For parallel processing, you can iterate over components in chunks:

```c
// Get the total number of components
int total_components = coyote_components_count(world);
int thread_count = 4; // Or use a thread pool
int chunk_size = (total_components + thread_count - 1) / thread_count;

// Process components in parallel
for (int i = 0; i < thread_count; i++) {
    size_t start_idx = i * chunk_size;
    size_t end_idx = (i + 1) * chunk_size;
    if (end_idx > total_components) {
        end_idx = total_components;
    }
    
    // Create an iterator for this chunk
    iterator chunk_it = coyote_components_iterator_filter_range(world, t_position, start_idx, end_idx);
    
    // Process the chunk
    component next;
    while ((next = coyote_components_iterator_filter_range_next(chunk_it)) != 0) {
        position* pos = coyote_component_get(next);
        // Work with the position component in this chunk
    }
}
```

## Iterating Over Entities

```c
// Iterate over entities with specific components
iterator it = coyote_entities_iterator_filter(world, t_position);
entity next;
while ((next = coyote_entities_iterator_filter_next(it)) != 0) {
    // Work with the entity
}
```

## Component Management

### Checking Component Type

```c
if (coyote_component_is(component, t_position)) {
    // This is a position component
}
```

### Destroying Components

```c
coyote_component_destroy(component);
```

## Memory Management

### Garbage Collection

Call the garbage collector when appropriate:

```c
coyote_components_gc(world);
```

### Counting Entities and Components

```c
int entity_count = coyote_entities_count(world);
int component_count = coyote_components_count(world);
```

## Iterating Over Entities

```c
// Single-type filter
iterator it = coyote_components_entities_filter(world, t_position);
entity next;
while ((next = coyote_entities_iterator_filter_next(it)) != 0) {
    // Work with the entity
}

// Multi-component query (AND)
const coyote_type include[] = { t_position, t_velocity };
iterator q = coyote_entities_query(world, include, 2, NULL, 0);
while ((next = coyote_entities_query_next(q)) != 0) {
    void* pos = coyote_entity_get(next, t_position);
    void* vel = coyote_entity_get(next, t_velocity);
    (void)pos; (void)vel;
}
```

## Entity Handles and Accessors

Generational handles survive slot recycling:

```c
coyote_entity_ref handle = coyote_entity_handle(e);

coyote_entity_destroy(e);

if (!coyote_entity_is_valid(world, handle)) {
    // handle is stale
}

entity resolved = coyote_entity_resolve(world, handle); // 0 if stale
```

Typed accessors without managing component handles directly:

```c
if (coyote_entity_has(e, t_position)) {
    position* pos = coyote_entity_get(e, t_position);
    pos->x += 1.0f;
}

coyote_entity_remove(e, t_velocity);
```

## Command Buffer

Record structural changes during iteration and apply later:

```c
command_buffer cb = coyote_command_buffer_create(world);

uint32_t placeholder = coyote_cb_spawn(cb);
component c = coyote_component_create(world, t_apple);
coyote_cb_attach_deferred(cb, placeholder, c, t_apple);

coyote_entity_ref old = coyote_entity_handle(e);
coyote_cb_destroy_entity(cb, old);

coyote_command_buffer_flush(cb); // apply in order
coyote_command_buffer_destroy(cb);
```

## Scheduler

```c
typedef struct { int tick; } game_time;

static void setup(world w, command_buffer cb, void* user_data) {
    (void)cb; (void)user_data;
    game_time t = { .tick = 0 };
    coyote_resource_insert(w, t_game_time, &t);
}

static void spawn(world w, command_buffer cb, void* user_data) {
    (void)w; (void)user_data;
    uint32_t p = coyote_cb_spawn(cb);
    component c = coyote_component_create(w, t_apple);
    coyote_cb_attach_deferred(cb, p, c, t_apple);
}

scheduler sched = coyote_scheduler_create(world);
uint32_t stage0 = coyote_scheduler_add_stage(sched);
uint32_t stage1 = coyote_scheduler_add_stage(sched);
coyote_scheduler_add_system(sched, stage0, setup, NULL);
coyote_scheduler_add_system(sched, stage1, spawn, NULL);
coyote_scheduler_run(sched);
coyote_scheduler_destroy(sched);
```

## Resources

```c
static const coyote_type t_game_time = COYOTE_MAKE_TYPE(10, game_time);

game_time t = { .tick = 0 };
coyote_resource_insert(world, t_game_time, &t);

if (coyote_resource_has(world, t_game_time)) {
    game_time* time = coyote_resource_get(world, t_game_time);
    time->tick += 1;
}

coyote_resource_remove(world, t_game_time);
```

## Events and Observers

```c
static void on_spawn(world w, coyote_entity_ref entity, void* user_data) {
    (void)w; (void)entity; (void)user_data;
}

static void on_structural(world w, coyote_event_kind kind,
    coyote_entity_ref entity, component c, uint32_t type_id, void* user_data) {
    (void)w; (void)entity; (void)c; (void)type_id; (void)user_data;
    if (kind == COYOTE_EVENT_ENTITY_SPAWNED) { /* ... */ }
}

coyote_observer_on_entity_spawn(world, on_spawn, NULL);
coyote_observer_on_component_add(world, t_apple, on_apple_add, NULL);
coyote_observer_on_component_add_any(world, on_any_add, NULL);

coyote_events_drain_structural(world, on_structural, NULL);
coyote_events_clear(world);
```

## Advanced Usage

### Parallel Processing

For high-performance applications, you can use the chunked iterator to process components in parallel:

```c
#include <pthread.h>

#define NUM_THREADS 4

typedef struct {
    world world;
    coyote_type component_type;
    size_t start_idx;
    size_t end_idx;
} thread_data;

void* process_chunk(void* arg) {
    thread_data* data = (thread_data*)arg;
    
    iterator it = coyote_components_iterator_filter_range(
        data->world, 
        data->component_type, 
        data->start_idx, 
        data->end_idx
    );
    
    component next;
    while ((next = coyote_components_iterator_filter_range_next(it)) != 0) {
        // Process the component
    }
    
    return NULL;
}

void process_components_parallel(world world, coyote_type component_type) {
    int total_components = coyote_components_count(world);
    int chunk_size = (total_components + NUM_THREADS - 1) / NUM_THREADS;
    
    pthread_t threads[NUM_THREADS];
    thread_data thread_args[NUM_THREADS];
    
    // Create threads
    for (int i = 0; i < NUM_THREADS; i++) {
        size_t start_idx = i * chunk_size;
        size_t end_idx = (i + 1) * chunk_size;
        if (end_idx > total_components) {
            end_idx = total_components;
        }
        
        thread_args[i].world = world;
        thread_args[i].component_type = component_type;
        thread_args[i].start_idx = start_idx;
        thread_args[i].end_idx = end_idx;
        
        pthread_create(&threads[i], NULL, process_chunk, &thread_args[i]);
    }
    
    // Wait for all threads to complete
    for (int i = 0; i < NUM_THREADS; i++) {
        pthread_join(threads[i], NULL);
    }
}
```

## Next Steps

- [Game Loop](game-loop.md) — scheduler, command buffer, resources, events in Zig
- [Performance Guide](performance-guide.md) for optimization tips
- [Advanced Optimizations Guide](advanced-optimizations.md) for SIMD and parallel processing
- [Core Concepts](core-concepts.md) for a deeper understanding of ECS 