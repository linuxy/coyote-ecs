const std = @import("std");
const builtin = @import("builtin");
const coyote = @import("coyote.zig");

export fn coyote_error(err: c_int) c_int {
    if(err != 0)
        return 1
    else
        return 0;
}

export fn coyote_world_create(out_world: *coyote.World) c_int {
    out_world.* = coyote.World.create() catch |err| return coyote_error(err);
}

export fn coyote_world_destroy(world: *coyote.World) void {
    world.destroy();
}

export fn coyote_entity_create(world: *coyote.World, out_entity: *coyote.Entity) c_int {
   out_entity.* = world.entities.create() catch |err| return coyote_error(err);
}

export fn coyote_entity_destroy(entity: *coyote.Entity) void {
    entity.destroy();
}

export fn coyote_component_create(world: *coyote.World, out_component: *coyote.Component) c_int {
    out_component.* = world.components.create() catch |err| return coyote_error(err);
}

export fn coyote_component_destroy(component: *coyote.Component) void {
    component.destroy();
}

export fn coyote_components_gc(world: *coyote.World) void {
    world.components.gc();
}

export fn coyote_component_set(component: *coyote.Component) c_int {
    _ = component;
    return 0;
}

export fn coyote_component_get(component: *coyote.Component) c_int {
    _ = component;
    return 0;
}

export fn coyote_entity_attach(entity: *coyote.Entity, component: *coyote.Component) c_int {
    entity.attach(component) catch |err| return coyote_error(err);
    return 0;
}

export fn coyote_entity_detach(entity: *coyote.Entity, component: *coyote.Component) c_int {
    entity.detach(component) catch |err| return coyote_error(err);
    return 0;
}

export fn coyote_component_detach(component: *coyote.Component) c_int {
    component.detach();
    return 0;
}

export fn coyote_components_iterator(world: *coyote.World, out_iterator: *coyote.SuperComponents.Iterator) c_int {
    _ = world;
    _ = out_iterator;
    return 0;
}

export fn coyote_components_iterator_filter(world: *coyote.World, out_iterator: *coyote.SuperComponents.MaskedIterator) c_int {
    _ = world;
    _ = out_iterator;
    return 0;
}

export fn coyote_entities_iterator(world: *coyote.World, out_iterator: *coyote.SuperComponents.Iterator) c_int {
    _ = world;
    _ = out_iterator;
    return 0;
}

export fn coyote_entities_iterator_filter(world: *coyote.World, out_iterator: *coyote.SuperComponents.MaskedIterator) c_int {
    _ = world;
    _ = out_iterator;
    return 0;
}

export fn coyote_component_is(component: *coyote.Component) bool {
    _ = component;
    return true;
}