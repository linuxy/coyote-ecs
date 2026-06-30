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

    //Assignment must happen after attach, TODO: Change?
    apple* a1 = coyote_component_get(c_apple); a1->color = 255; a1->ripe = 0; a1->harvested = 0;
    printf("Got and assigned an apple component @%d\n", a1);

    //Entity accessors: has / get / remove
    printf("Apple entity has apple component: %d\n", coyote_entity_has(e_apple, t_apple));
    apple* a2 = coyote_entity_get(e_apple, t_apple);
    if(a2)
        printf("Got apple via coyote_entity_get: color=%d\n", a2->color);

    //Multi-component query: entities owning an apple component (and no orange)
    coyote_type q_include[1] = { t_apple };
    coyote_type q_exclude[1] = { t_orange };
    iterator q = coyote_entities_query(world, q_include, 1, q_exclude, 1);
    int q_count = 0;
    while(coyote_entities_query_next(q)) q_count++;
    printf("Query [apple WITHOUT orange] entities: %d\n", q_count);

    coyote_entity_remove(e_apple, t_apple);
    printf("Apple entity has apple component after remove: %d\n", coyote_entity_has(e_apple, t_apple));

    // Generational handles: a stored handle survives slot recycling safely.
    coyote_entity_ref h = coyote_entity_handle(e_pear);
    printf("Handle valid before destroy: %d\n", coyote_entity_is_valid(world, h));

    coyote_entity_destroy(e_apple);
    coyote_entity_destroy(e_pear);

    printf("Handle valid after destroy: %d\n", coyote_entity_is_valid(world, h));
    entity recycled = coyote_entity_create(world); // reuses a freed slot
    printf("Old handle resolves after recycle: %d\n", coyote_entity_resolve(world, h) != 0);
    coyote_entity_destroy(recycled);

    printf("Number of entities: %d == 1\n", coyote_entities_count(world));
    printf("Number of components: %d == 2\n", coyote_components_count(world));

    // Command buffer: defer a spawn + attach, apply on flush.
    command_buffer cb = coyote_command_buffer_create(world);
    uint32_t spawned = coyote_cb_spawn(cb);
    component c_deferred = coyote_component_create(world, t_orange);
    coyote_cb_attach_deferred(cb, spawned, c_deferred, t_orange);
    printf("Entities before flush: %d\n", coyote_entities_count(world));
    coyote_command_buffer_flush(cb);
    printf("Entities after flush: %d\n", coyote_entities_count(world));
    coyote_command_buffer_destroy(cb);

    coyote_world_destroy(world);
    printf("World destroyed.\n");
    return 0;
}
