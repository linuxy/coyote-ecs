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

- Check out the [Performance Guide](performance-guide.md) for optimization tips
- Explore the [Advanced Optimizations Guide](advanced-optimizations.md) for SIMD and parallel processing
- Read the [Core Concepts](core-concepts.md) for a deeper understanding of ECS 