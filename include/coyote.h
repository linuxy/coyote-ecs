#ifndef COYOTE_H
#define COYOTE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef struct coyote_type {
    size_t id; // component unique id
    size_t size; // component sizeof
    const char* name; // component name
} coyote_type;

#define COYOTE_MAKE_TYPE(TypeId, TypeName) { .id = TypeId, .size = sizeof(TypeName) , .name = #TypeName }

uintptr_t coyote_world_create();
void coyote_world_destroy();

#ifdef __cplusplus
}
#endif

#endif /* COYOTE_H */
