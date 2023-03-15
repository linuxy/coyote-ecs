#include <stddef.h>
#include <stdio.h>
#include "../include/coyote.h"

typedef struct apple {
    int color;
    int ripe;
    int harvested;
} apple;

typedef struct orange {
    int color;
    int ripe;
    int harvested;
} orange;

typedef struct pear {
    int color;
    int ripe;
    int harvested;
} pear;

static const coyote_type t_apple = COYOTE_MAKE_TYPE(0, apple);
static const coyote_type t_orange = COYOTE_MAKE_TYPE(1, orange);
static const coyote_type t_pear = COYOTE_MAKE_TYPE(2, pear);

int main(void) {
    world world = coyote_world_create();

    if(world != 0)
        printf("Created world @%d\n", world);
    else
        printf("World creation failed.\n");

    entity e_apple = coyote_entity_create(world);
    entity e_orange = coyote_entity_create(world);
    entity e_pear = coyote_entity_create(world);

    component c_apple = coyote_component_create(world, t_apple);
    component c_orange = coyote_component_create(world, t_orange);
    component c_pear = coyote_component_create(world, t_pear);
 
    printf("Created an apple component @%d\n", c_apple);
    printf("Created an orange component @%d\n", c_orange);
    printf("Created an pear component @%d\n", c_pear);

    iterator it = coyote_components_iterator_filter(world, t_orange);
    component next = coyote_components_iterator_filter_next(it);
    if(next)
        printf("Another orange component @%d\n", c_orange);
    else
        printf("NOT another orange component @%d\n", c_orange);

    if(coyote_component_is(c_orange, t_orange))
        printf("Component is an orange @%d\n", c_orange);
    else
        printf("Component is NOT an orange @%d\n", c_orange);

    coyote_entity_attach(e_apple, c_apple, t_apple);
    coyote_entity_attach(e_orange, c_orange, t_orange);

    //Assignment must happen after attach, TODO: Change?
    apple* a1 = coyote_component_get(c_apple); a1->color = 255; a1->ripe = 0; a1->harvested = 0;
    orange* o1 = coyote_component_get(c_orange); o1->color = 125; o1->ripe = 1; o1->harvested = 0;
    printf("Got and assigned an apple component @%d\n", a1);
    printf("Apple  : color %d : ripe %d : harvested %d\n", a1->color, a1->ripe, a1->harvested);
    printf("Orange : color %d : ripe %d : harvested %d\n", o1->color, o1->ripe, o1->harvested);
    
    coyote_entity_detach(e_apple, c_apple);
    coyote_component_destroy(c_apple);
    coyote_entity_destroy(e_apple);
    coyote_entity_destroy(e_pear);

    printf("Number of entities: %d == 1\n", coyote_entities_count(world));
    printf("Number of components: %d == 2\n", coyote_components_count(world));

    coyote_world_destroy(world);
    printf("World destroyed.\n");
    return 0;
}
