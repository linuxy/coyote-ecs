#ifndef COYOTE_H
#define COYOTE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stddef.h>

typedef struct coyote_type {
    uintptr_t id;
    uintptr_t size;        // component sizeof
    uint8_t alignof;       // component alignment (must match Zig c_type ABI)
    const char* name;      // component name
} coyote_type;

// Portable (C99) alignment query via the classic offsetof trick.
#define COYOTE_ALIGNOF(TypeName) offsetof(struct { char coyote_pad; TypeName coyote_val; }, coyote_val)

#define COYOTE_MAKE_TYPE(TypeId, TypeName) { .id = TypeId, .size = sizeof(TypeName), .alignof = (uint8_t)COYOTE_ALIGNOF(TypeName), .name = #TypeName }

typedef uintptr_t entity;
typedef uintptr_t component;
typedef uintptr_t world;
typedef uintptr_t iterator;
typedef uint64_t coyote_entity_ref; // stable, generation-tagged entity handle

uintptr_t coyote_world_create();
void coyote_world_destroy(world world);
entity coyote_entity_create(world world);
void coyote_entity_destroy(entity entity);
coyote_entity_ref coyote_entity_handle(entity entity);
uint32_t coyote_entity_generation(entity entity);
entity coyote_entity_resolve(world world, coyote_entity_ref handle);
int coyote_entity_is_valid(world world, coyote_entity_ref handle);
component coyote_component_create(world world, coyote_type type);
int coyote_entity_attach(entity entity, component component, coyote_type type);
int coyote_entity_detach(entity entity, component component);
int coyote_entity_has(entity entity, coyote_type type);
void* coyote_entity_get(entity entity, coyote_type type);
int coyote_entity_remove(entity entity, coyote_type type);
int coyote_entities_iterator(world world, iterator iterator);
entity coyote_entities_iterator_next(iterator iterator);
int coyote_components_iterator(world world, iterator iterator);
component coyote_components_iterator_next(iterator iterator);
int coyote_component_is(component component, coyote_type type);
iterator coyote_components_iterator_filter(world world, coyote_type type);
iterator coyote_components_entities_filter(world world, coyote_type type);
component coyote_components_iterator_filter_next(iterator iterator);
entity coyote_entities_iterator_filter_next(iterator iterator);
iterator coyote_components_iterator_filter_range(world world, coyote_type type, size_t start_idx, size_t end_idx);
component coyote_components_iterator_filter_range_next(iterator iterator);
iterator coyote_entities_query(world world, const coyote_type* include, size_t include_n, const coyote_type* exclude, size_t exclude_n);
entity coyote_entities_query_next(iterator iterator);
void coyote_components_gc(world world);
int coyote_components_count(world world);
int coyote_entities_count(world world);
void* coyote_component_get(component component);
void coyote_component_destroy(component component);

// Command buffer: record structural mutations and apply them later (e.g.
// between scheduler stages, or after iterating a query).
typedef uintptr_t command_buffer;
#define COYOTE_CB_BAD_INDEX ((uint32_t)0xFFFFFFFF) // returned by spawn on failure

command_buffer coyote_command_buffer_create(world world);
void coyote_command_buffer_destroy(command_buffer cb);
int coyote_command_buffer_flush(command_buffer cb);   // apply + reset; 0 on success
void coyote_command_buffer_reset(command_buffer cb);  // discard without applying

uint32_t coyote_cb_spawn(command_buffer cb);          // deferred entity placeholder
int coyote_cb_destroy_entity(command_buffer cb, coyote_entity_ref handle);
int coyote_cb_destroy_entity_deferred(command_buffer cb, uint32_t placeholder);
int coyote_cb_attach(command_buffer cb, coyote_entity_ref handle, component component, coyote_type type);
int coyote_cb_attach_deferred(command_buffer cb, uint32_t placeholder, component component, coyote_type type);
int coyote_cb_remove(command_buffer cb, coyote_entity_ref handle, coyote_type type);
int coyote_cb_remove_deferred(command_buffer cb, uint32_t placeholder, coyote_type type);

// Scheduler: register systems into ordered stages and run them. The shared
// command buffer is flushed after each stage, so structural changes a stage
// records are visible to later stages but never mid-stage.
typedef uintptr_t scheduler;
// A system callback receives the world, a command buffer to record structural
// changes into, and the user_data registered alongside it.
typedef void (*coyote_system)(world world, command_buffer cb, void* user_data);

scheduler coyote_scheduler_create(world world);
void coyote_scheduler_destroy(scheduler sched);
uint32_t coyote_scheduler_add_stage(scheduler sched);
int coyote_scheduler_add_system(scheduler sched, uint32_t stage, coyote_system system, void* user_data);
int coyote_scheduler_run(scheduler sched);

// Resources: one singleton value per type per world (delta time, input, etc.).
int coyote_resource_insert(world world, coyote_type type, const void* data);
void* coyote_resource_get(world world, coyote_type type);
int coyote_resource_has(world world, coyote_type type);
void coyote_resource_remove(world world, coyote_type type);

#ifdef __cplusplus
}
#endif

#endif /* COYOTE_H */
