# coyote-ecs
A fast and simple zig native ECS.

Builds against zig 0.14.0

📚 [Documentation](https://linuxy.github.io/coyote-ecs/docs/)

```git clone --recursive https://github.com/linuxy/coyote-ecs.git```

To build:
* zig build

A more complete example:
[coyote-snake](https://github.com/linuxy/coyote-snake)

Benchmark:
[coyote-bunnies](https://github.com/linuxy/coyote-bunnies)

Define your components
```zig
const std = @import("std");
const ecs = @import("coyote-ecs");

const World = ecs.World;
const Cast = ecs.Cast;
const Systems = ecs.Systems;

pub const Apple = struct {
    color: u32 = 0,
    ripe: bool = false,
    harvested: bool = false,
};

pub const Orange = struct {
    color: u32 = 0,
    ripe: bool = false,
    harvested: bool = false,
};

pub const Pear = struct {
    color: u32 = 0,
    ripe: bool = false,
    harvested: bool = false,
};
```

Create some entities and components in a world
```zig
pub fn main() !void {
    //Create a world
    var world = try World.create();
    defer world.deinit();
    
    //Create an entity
    var anOrange = try world.entities.create();
    var anApple = try world.entities.create();
    var aPear = try world.entities.create();

    std.log.info("Created an Orange ID: {}", .{anOrange.id});

    //Create a unique component
    var orangeComponent = try world.components.create(Components.Orange);
    var appleComponent = try world.components.create(Components.Apple);

    //Attach and assign a component. Do not use an anonymous struct.
    try anOrange.attach(orangeComponent, Components.Orange{.color = 0, .ripe = false, .harvested = false});
    try anApple.attach(appleComponent, Components.Apple{.color = 0, .ripe = false, .harvested = false});
    _ = try aPear.addComponent(Components.Pear{.color = 1, .ripe = false, .harvested = false});

    //Create 50k entities and attach 50k unique components
    var i: usize = 0;
    while(i < 50000) : (i += 1) {
        var anEntity = try world.entities.create();
        var anOrangeComponent = try world.components.create(Components.Orange);
        try anEntity.attach(anOrangeComponent, Components.Orange{.color = 1, .ripe = false, .harvested = false});
    }

    //Filter components by type
    var it = world.components.iteratorFilter(Components.Orange);
    i = 0;
    while(it.next()) |_| : (i += 1) {
        //...
    }

    std.log.info("Orange components: {}", .{i});

    //Filter entities by type
    var it2 = world.entities.iteratorFilter(Components.Apple);
    i = 0;
    while(it2.next()) |_| : (i += 1) {
        //...
    }

    std.log.info("Apple entities: {}", .{i});

    if(aPear.getOneComponent(Components.Pear) != null)
        std.log.info("Pear entities: >= 1", .{})
    else
        std.log.info("Pear entities: 0", .{});

    try Systems.run(Grow, .{world});
    try Systems.run(Harvest, .{world});
    try Systems.run(Raze, .{world});

    std.log.info("Entities: {}", .{world.entities.count()});
    std.log.info("Components: {}", .{world.components.count()});
}
```

Create some systems
```zig
pub fn Grow(world: *World) void {
    var it = world.components.iterator();
    var i: u32 = 0;
    while(it.next()) |component| : (i += 1) {
        if(component.is(Components.Orange)) {
            try component.set(Components.Orange, .{.ripe = true});
        }

        if(component.is(Components.Apple)) {
            try component.set(Components.Apple, .{.ripe = true});
        }

        if(component.is(Components.Pear)) {
            try component.set(Components.Pear, .{.ripe = true});
        }
        //Fruits fall from the tree
        component.detach();
    }
    std.log.info("Fruits grown: {}", .{i});
}

pub fn Harvest(world: *World) void {
    var it = world.components.iterator();
    var i: u32 = 0;
    while(it.next()) |component| {
        if(component.is(Components.Orange)) {
            if(Cast(Components.Orange, component).ripe == true) {
                try component.set(Components.Orange, .{.harvested = true});
                i += 1;
            }
        }
        if(component.is(Components.Apple)) {
            if(Cast(Components.Apple, component).ripe == true) {
                try component.set(Components.Apple, .{.harvested = true});
                i += 1;
            }
        }
        if(component.is(Components.Pear)) {
            if(Cast(Components.Pear, component).ripe == true) {
                try component.set(Components.Pear, .{.harvested = true});
                i += 1;
            }
        }
        component.destroy();
    }
    
    world.components.gc();
    std.log.info("Fruits harvested: {}", .{i});
}

pub fn Raze(world: *World) void {
    var it = world.entities.iterator();
    var i: u32 = 0;

    while(it.next()) |entity| {
        entity.destroy();
        i += 1;
    }

    std.log.info("Entities destroyed: {}", .{i});
}
```

With C bindings
```c
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

    coyote_entity_detach(e_apple, c_apple);
    coyote_component_destroy(c_apple);
    coyote_entity_destroy(e_apple);
    coyote_entity_destroy(e_pear);

    printf("Number of entities: %d == 1\n", coyote_entities_count(world));
    printf("Number of components: %d == 3\n", coyote_components_count(world));

    coyote_world_destroy(world);
    printf("World destroyed.\n");
    return 0;
}
```
