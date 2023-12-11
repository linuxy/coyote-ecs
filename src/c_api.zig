const std = @import("std");
const builtin = @import("builtin");
const coyote = @import("coyote.zig");

inline fn coyote_error(err: anyerror) c_int {
    return @intFromError(err);
}

export fn coyote_world_create() usize {
    var new_world = @as(?*anyopaque, @ptrCast(coyote.World.create() catch return 0));
    return @intFromPtr(new_world);
}

export fn coyote_world_destroy(world_ptr: usize) void {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.destroy();
}

export fn coyote_entity_create(world_ptr: usize) usize {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    var entity = (world.entities.create() catch return 0);
    return @intFromPtr(entity);
}

export fn coyote_entity_destroy(entity_ptr: usize) void {
    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return;
    }

    var entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));
    entity.destroy();
}
//static const coy_type transform_type = { .coy_id = 0, .coy_sizeof = sizeof(transform) , .name = "transform"};
//static const coy_type velocity_type = COYOTE_MAKE_TYPE(1, velocity);
export fn coyote_component_create(world_ptr: usize, c_type: coyote.c_type) usize {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    var component = world.components.create_c(c_type) catch |err| return @as(usize, @intCast(coyote_error(err)));

    return @intFromPtr(component);
}

export fn coyote_component_destroy(component_ptr: usize) void {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return;
    }

    var component = @as(*coyote.Component, @ptrFromInt(component_ptr));
    component.destroy();
}

export fn coyote_components_gc(world_ptr: usize) void {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.components.gc();
}

export fn coyote_component_get(component_ptr: usize) ?*anyopaque {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return null;
    }

    var component = @as(*coyote.Component, @ptrFromInt(component_ptr));
    return component.data;
}

export fn coyote_entity_attach(entity_ptr: usize, component_ptr: usize, c_type: coyote.c_type) c_int {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    var component = @as(*coyote.Component, @ptrFromInt(component_ptr));

    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return 1;
    }

    var entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));

    entity.attach(component, c_type) catch return 1;

    return 0;
}

export fn coyote_entity_detach(entity_ptr: usize, component_ptr: usize) c_int {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    var component = @as(*coyote.Component, @ptrFromInt(component_ptr));

    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return 1;
    }

    var entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));

    _ = entity;
    component.detach();
    return 0;
}

export fn coyote_component_detach(component_ptr: usize) c_int {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    var component = @as(*coyote.Entity, @ptrFromInt(component_ptr));
    _ = component;

    return 0;
}

export fn coyote_components_iterator(world_ptr: usize, out_iterator: *coyote.SuperComponents.Iterator) c_int {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    var it = world.components.iterator();
    out_iterator.* = it;
    return 0;
}

export fn coyote_components_iterator_next(iterator_ptr: usize) usize {
    var iterator = @as(*coyote.SuperComponents.Iterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |bind| {
        return @intFromPtr(bind);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

export fn coyote_components_iterator_filter(world_ptr: usize, c_type: coyote.c_type) usize {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    var components = &world._components;
    var iterator = coyote.allocator.create(coyote.SuperComponents.MaskedIterator) catch unreachable;
    iterator.* = coyote.SuperComponents.MaskedIterator{ .ctx = components, .filter_type = coyote.typeToIdC(c_type), .alive = coyote.CHUNK_SIZE * world.components_len, .world = world };
    return @intFromPtr(iterator);
}

export fn coyote_components_iterator_filter_next(iterator_ptr: usize) usize {
    var iterator = @as(*coyote.SuperComponents.MaskedIterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |bind| {
        return @intFromPtr(bind);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

export fn coyote_entities_iterator(world_ptr: usize, out_iterator: *coyote.SuperEntities.Iterator) usize {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    var it = world.entities.iterator();
    out_iterator.* = it;
    return 0;
}

export fn coyote_entities_iterator_next(iterator_ptr: usize) usize {
    var iterator = @as(*coyote.SuperEntities.Iterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |bind| {
        return @intFromPtr(bind);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

export fn coyote_entities_iterator_filter(world_ptr: usize, c_type: coyote.c_type) usize {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    var entities = &world._entities;
    var iterator = coyote.allocator.create(coyote.SuperEntities.MaskedIterator) catch unreachable;
    iterator.* = coyote.SuperEntities.MaskedIterator{ .ctx = entities, .filter_type = coyote.typeToIdC(c_type), .alive = world.entities.alive, .world = world };
    return @intFromPtr(iterator);
}

export fn coyote_entities_iterator_filter_next(iterator_ptr: usize) usize {
    var iterator = @as(*coyote.SuperEntities.MaskedIterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |bind| {
        return @intFromPtr(bind);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

export fn coyote_component_is(component: *coyote.Component, c_type: coyote.c_type) usize {
    if (component.typeId.? == c_type.id) {
        return 1;
    } else {
        return 0;
    }
}

export fn coyote_entities_count(world_ptr: usize) c_int {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    return @as(c_int, @intCast(world.entities.count()));
}

export fn coyote_components_count(world_ptr: usize) c_int {
    var world = @as(*coyote.World, @ptrFromInt(world_ptr));
    return @as(c_int, @intCast(world.components.count()));
}
