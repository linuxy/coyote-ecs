#include <stddef.h>
#include <stdio.h>
#include "../include/coyote.h"

static const coyote_type apple = COYOTE_MAKE_TYPE(0, apple);
static const coyote_type orange = COYOTE_MAKE_TYPE(1, orange);

int main(void) {
    world world = coyote_world_create();

    if(world != 0)
        printf("Created world @%d\n", world);
    else
        printf("World creation failed.\n");

    entity e_apple = coyote_entity_create(world);
    entity e_aorange = coyote_entity_create(world);
    entity e_pear = coyote_entity_create(world);

    component c_orange = coyote_component_create(world, orange);
    component c_apple = coyote_component_create(world, apple);

    printf("Created an orange component @%d\n", c_orange);
    printf("Created an apple component @%d\n", c_apple);

    coyote_entity_attach(e_apple, c_apple, apple);
    coyote_entity_destroy(e_apple);
    coyote_entity_destroy(e_pear);

    coyote_world_destroy(world);
    printf("World destroyed.\n");
    return 0;
}