#ifndef COYOTE_H
#define COYOTE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef struct coyote_type {
    int id; // component unique id
    size_t size; // component sizeof
    const char* name; // component name
} coyote_type;

#define COYOTE_MAKE_TYPE(TypeId, TypeName) { .id = TypeId, .size = sizeof(TypeName) , .name = #TypeName }

typedef uintptr_t entity;
typedef uintptr_t component;
typedef uintptr_t world;

uintptr_t coyote_world_create();
void coyote_world_destroy();
entity coyote_entity_create(world world);
void coyote_entity_destroy(entity entity);
component coyote_component_create(world world, coyote_type type);

#ifdef __cplusplus
}
#endif

#endif /* COYOTE_H */
