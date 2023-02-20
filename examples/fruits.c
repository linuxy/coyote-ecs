#include <stddef.h>
#include <stdio.h>
#include "../include/coyote.h"

static const coyote_type apple = COYOTE_MAKE_TYPE(0, apple);

int main(void) {
    uintptr_t world = coyote_world_create();

    if(world != 0)
        printf("Created world of size: %d\n", world);
    else
        printf("World creation failed.\n");

    coyote_world_destroy(world);
    printf("World destroyed.\n");
    return 0;
}