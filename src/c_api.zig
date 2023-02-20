const std = @import("std");
const builtin = @import("builtin");
const coyote = @import("coyote.zig");

inline fn coyote_error(err: anyerror) c_int {
    return @errorToInt(err);
}

export fn coyote_world_create() usize {
    var new_world = @ptrCast(?*anyopaque, coyote.World.create() catch return 0);
    return @ptrToInt(new_world);
}

export fn coyote_world_destroy(world_ptr: usize) void {
    var world = @intToPtr(*coyote.World, world_ptr);
    world.destroy();
}

export fn coyote_entity_create(world_ptr: usize) usize {
    var world = @intToPtr(*coyote.World, world_ptr);
    var entity = (world.entities.create() catch return 0);
    return @ptrToInt(entity);
}

export fn coyote_entity_destroy(entity_ptr: usize) void {

    if(entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return;
    }

    var entity = @intToPtr(*coyote.Entity, entity_ptr);
    entity.destroy();
}

//#define TYPE_ALIGNMENT( t ) offsetof( struct { char x; t test; }, test )
//#define COYOTE_MAKE_TYPE(TypeId, TypeName) { .coy_id = TypeId, .cp_sizeof = sizeof(TypeName) , .name = #TypeName }
//static const coy_type transform_type = { .coy_id = 0, .coy_sizeof = sizeof(transform) , .name = "transform"};
//static const coy_type velocity_type = COYOTE_MAKE_TYPE(1, velocity);
export fn coyote_component_create(world_ptr: usize, id: usize, size: usize, name: [*c]u8) usize {
    var world = @intToPtr(*coyote.World, world_ptr);
    var type_info: coyote.c_type = .{.id = id, .size = size, .name = name, .alignof = 8};
    var component = world.components.create_c(type_info) catch |err| return @intCast(usize, coyote_error(err));

    return @ptrToInt(component);
}

export fn coyote_component_destroy(component_ptr: usize) void {

    if(component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return;
    }

    var component = @intToPtr(*coyote.Component, component_ptr);
    component.destroy();
}

export fn coyote_components_gc(world_ptr: usize) void {
    var world = @intToPtr(*coyote.World, world_ptr);
    world.components.gc();
}

export fn coyote_component_set(component_ptr: usize) c_int {

    if(component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    var component = @intToPtr(*coyote.Component, component_ptr);
    _ = component;

    return 0;
}

export fn coyote_component_get(component_ptr: usize) c_int {

    if(component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    var component = @intToPtr(*coyote.Component, component_ptr);

    _ = component;
    return 0;
}

export fn coyote_entity_attach(entity_ptr: usize, component_ptr: usize, id: usize, size: usize, name: [*c]u8) c_int {
    if(component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    var component = @intToPtr(*coyote.Component, component_ptr);

    if(entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return 1;
    }

    var entity = @intToPtr(*coyote.Entity, entity_ptr);
    var type_info: coyote.c_type = .{.id = id, .size = size, .name = name, .alignof = 8};

    entity.attach(component, type_info) catch return 1;

    return 0;
}

export fn coyote_entity_detach(entity_ptr: usize, component_ptr: usize) c_int {
    if(component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    var component = @intToPtr(*coyote.Entity, component_ptr);

    if(entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return 1;
    }

    var entity = @intToPtr(*coyote.Entity, entity_ptr);
    
    _ = entity;
    _ = component;
    return 0;
}

export fn coyote_component_detach(component_ptr: usize) c_int {
    if(component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    var component = @intToPtr(*coyote.Entity, component_ptr);
    _ = component;
    
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