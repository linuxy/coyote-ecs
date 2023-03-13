#include <stddef.h>
#include <stdio.h>
#include "../include/coyote.h"

static const coyote_type apple = COYOTE_MAKE_TYPE(0, apple);
static const coyote_type orange = COYOTE_MAKE_TYPE(1, orange);
static const coyote_type pear = COYOTE_MAKE_TYPE(2, pear);

int main(void) {
    world world = coyote_world_create();

    if(world != 0)
        printf("Created world @%d\n", world);
    else
        printf("World creation failed.\n");

    entity e_apple = coyote_entity_create(world);
    entity e_orange = coyote_entity_create(world);
    entity e_pear = coyote_entity_create(world);

    component c_apple = coyote_component_create(world, apple);
    component c_orange = coyote_component_create(world, orange);
    component c_pear = coyote_component_create(world, pear);
 
    printf("Created an apple component @%d\n", c_apple);
    printf("Created an orange component @%d\n", c_orange);
    printf("Created an pear component @%d\n", c_pear);

    iterator it = coyote_components_iterator_filter(world, orange);
    component next = coyote_components_iterator_filter_next(it);
    if(next)
        printf("Another orange component @%d\n", c_orange);
    else
        printf("NOT another orange component @%d\n", c_orange);

    if(coyote_component_is(c_orange, orange))
        printf("Component is an orange @%d\n", c_orange);
    else
        printf("Component is NOT an orange @%d\n", c_orange);

    coyote_entity_attach(e_apple, c_apple, apple);
    coyote_entity_destroy(e_apple);
    coyote_entity_destroy(e_pear);

    printf("Number of entities: %d == 1\n", coyote_entities_count(world));
    printf("Number of components: %d == 3\n", coyote_components_count(world));

    coyote_world_destroy(world);
    printf("World destroyed.\n");
    return 0;
}