#include <stddef.h>
#include <stdio.h>
#include "../include/coyote.h"

static const coyote_type apple = COYOTE_MAKE_TYPE(0, apple);

int main(void) {
    void* world;    
    int ret = coyote_world_create((void*)world);

    if(ret != 0)
        printf("Created world of size: %d", ret);
    else
        printf("World creation failed.");

    // coyote_world_destroy(world);
    return 0;
}