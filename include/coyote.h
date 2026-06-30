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

uintptr_t coyote_world_create();
void coyote_world_destroy(world world);
entity coyote_entity_create(world world);
void coyote_entity_destroy(entity entity);
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
void coyote_components_gc(world world);
int coyote_components_count(world world);
int coyote_entities_count(world world);
void* coyote_component_get(component component);
void coyote_component_destroy(component component);

#ifdef __cplusplus
}
#endif

#endif /* COYOTE_H */
