const std = @import("std");
const builtin = @import("builtin");
const coyote = @import("coyote.zig");

inline fn coyote_error(err: anyerror) c_int {
    return @intFromError(err);
}

export fn coyote_world_create() usize {
    const new_world = @as(?*anyopaque, @ptrCast(coyote.World.create() catch return 0));
    return @intFromPtr(new_world);
}

export fn coyote_world_destroy(world_ptr: usize) void {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.destroy();
}

export fn coyote_entity_create(world_ptr: usize) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const entity = (world.entities.create() catch return 0);
    return @intFromPtr(entity);
}

export fn coyote_entity_destroy(entity_ptr: usize) void {
    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return;
    }

    const entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));
    entity.destroy();
}

//Returns a stable, generation-tagged handle for an entity. Store this instead
//of the raw pointer if the entity may be destroyed and its slot recycled.
export fn coyote_entity_handle(entity_ptr: usize) u64 {
    if (entity_ptr == 0) return 0;
    const entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));
    return coyote.entityGlobalId(entity);
}

//The entity's current generation. Bumped each time the slot is destroyed.
export fn coyote_entity_generation(entity_ptr: usize) u32 {
    if (entity_ptr == 0) return 0;
    const entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));
    return entity.generation;
}

//Resolves a handle back to a live entity pointer, or 0 if it is stale
//(the entity was destroyed, or its slot now holds a newer entity).
export fn coyote_entity_resolve(world_ptr: usize, handle: u64) usize {
    if (world_ptr == 0) return 0;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    if (coyote.resolveGlobalId(world, handle)) |entity| {
        return @intFromPtr(entity);
    }
    return 0;
}

//1 if `handle` still refers to the same live entity, 0 otherwise.
export fn coyote_entity_is_valid(world_ptr: usize, handle: u64) c_int {
    if (world_ptr == 0) return 0;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    return if (coyote.resolveGlobalId(world, handle) != null) 1 else 0;
}
//static const coy_type transform_type = { .coy_id = 0, .coy_sizeof = sizeof(transform) , .name = "transform"};
//static const coy_type velocity_type = COYOTE_MAKE_TYPE(1, velocity);
export fn coyote_component_create(world_ptr: usize, c_type: coyote.c_type) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const component = world.components.create_c(c_type) catch |err| return @as(usize, @intCast(coyote_error(err)));

    return @intFromPtr(component);
}

export fn coyote_component_destroy(component_ptr: usize) void {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return;
    }

    const component = @as(*coyote.Component, @ptrFromInt(component_ptr));
    component.destroy();
}

export fn coyote_components_gc(world_ptr: usize) void {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.components.gc();
}

export fn coyote_component_get(component_ptr: usize) ?*anyopaque {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return null;
    }

    const component = @as(*coyote.Component, @ptrFromInt(component_ptr));
    return component.data;
}

export fn coyote_entity_attach(entity_ptr: usize, component_ptr: usize, c_type: coyote.c_type) c_int {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    const component = @as(*coyote.Component, @ptrFromInt(component_ptr));

    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return 1;
    }

    const entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));

    entity.attach(component, c_type) catch return 1;

    return 0;
}

export fn coyote_entity_detach(entity_ptr: usize, component_ptr: usize) c_int {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    const component = @as(*coyote.Component, @ptrFromInt(component_ptr));

    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return 1;
    }

    const entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));

    _ = entity;
    component.detach();
    return 0;
}

export fn coyote_entity_has(entity_ptr: usize, c_type: coyote.c_type) c_int {
    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return 0;
    }

    const entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));
    return if (entity.hasById(coyote.typeToIdC(c_type))) 1 else 0;
}

export fn coyote_entity_get(entity_ptr: usize, c_type: coyote.c_type) ?*anyopaque {
    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return null;
    }

    const entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));
    const component = entity.getOneComponentById(coyote.typeToIdC(c_type)) orelse return null;
    return component.data;
}

export fn coyote_entity_remove(entity_ptr: usize, c_type: coyote.c_type) c_int {
    if (entity_ptr == 0) {
        std.log.err("Invalid entity.", .{});
        return 1;
    }

    const entity = @as(*coyote.Entity, @ptrFromInt(entity_ptr));
    entity.removeById(coyote.typeToIdC(c_type)) catch return 1;
    return 0;
}

export fn coyote_component_detach(component_ptr: usize) c_int {
    if (component_ptr == 0) {
        std.log.err("Invalid component.", .{});
        return 1;
    }

    const component = @as(*coyote.Entity, @ptrFromInt(component_ptr));
    _ = component;

    return 0;
}

export fn coyote_components_iterator(world_ptr: usize, out_iterator: *coyote.SuperComponents.Iterator) c_int {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const it = world.components.iterator();
    out_iterator.* = it;
    return 0;
}

export fn coyote_components_iterator_next(iterator_ptr: usize) usize {
    const iterator = @as(*coyote.SuperComponents.Iterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |bind| {
        return @intFromPtr(bind);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

export fn coyote_components_iterator_filter(world_ptr: usize, c_type: coyote.c_type) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const components = &world._components;
    const iterator = coyote.allocator.create(coyote.SuperComponents.MaskedIterator) catch unreachable;
    iterator.* = coyote.SuperComponents.MaskedIterator{ .ctx = components, .filter_type = coyote.typeToIdC(c_type), .alive = coyote.CHUNK_SIZE * world.components_len, .world = world };
    return @intFromPtr(iterator);
}

export fn coyote_components_iterator_filter_next(iterator_ptr: usize) usize {
    const iterator = @as(*coyote.SuperComponents.MaskedIterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |bind| {
        return @intFromPtr(bind);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

export fn coyote_entities_iterator(world_ptr: usize, out_iterator: *coyote.SuperEntities.Iterator) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const it = world.entities.iterator();
    out_iterator.* = it;
    return 0;
}

export fn coyote_entities_iterator_next(iterator_ptr: usize) usize {
    const iterator = @as(*coyote.SuperEntities.Iterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |bind| {
        return @intFromPtr(bind);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

export fn coyote_entities_query(world_ptr: usize, include: [*c]const coyote.c_type, include_n: usize, exclude: [*c]const coyote.c_type, exclude_n: usize) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const iterator = coyote.allocator.create(coyote.SuperEntities.QueryIterator) catch unreachable;
    iterator.* = coyote.SuperEntities.QueryIterator{
        .ctx = &world._entities,
        .world = world,
        .total = coyote.CHUNK_SIZE * world.entities_len,
    };

    var i: usize = 0;
    while (i < include_n and iterator.include_len < coyote.MAX_COMPONENTS) : (i += 1) {
        iterator.include_ids[iterator.include_len] = coyote.typeToIdC(include[i]);
        iterator.include_len += 1;
    }

    i = 0;
    while (i < exclude_n and iterator.exclude_len < coyote.MAX_COMPONENTS) : (i += 1) {
        iterator.exclude_ids[iterator.exclude_len] = coyote.typeToIdC(exclude[i]);
        iterator.exclude_len += 1;
    }

    return @intFromPtr(iterator);
}

export fn coyote_entities_query_next(iterator_ptr: usize) usize {
    const iterator = @as(*coyote.SuperEntities.QueryIterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |entity| {
        return @intFromPtr(entity);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

export fn coyote_entities_iterator_filter(world_ptr: usize, c_type: coyote.c_type) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const entities = &world._entities;
    const iterator = coyote.allocator.create(coyote.SuperEntities.MaskedIterator) catch unreachable;
    iterator.* = coyote.SuperEntities.MaskedIterator{ .ctx = entities, .filter_type = coyote.typeToIdC(c_type), .alive = coyote.CHUNK_SIZE * world.components_len, .world = world };
    return @intFromPtr(iterator);
}

export fn coyote_entities_iterator_filter_next(iterator_ptr: usize) usize {
    const iterator = @as(*coyote.SuperEntities.MaskedIterator, @ptrFromInt(iterator_ptr));
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
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    return @as(c_int, @intCast(world.entities.count()));
}

export fn coyote_components_count(world_ptr: usize) c_int {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    return @as(c_int, @intCast(world.components.count()));
}

export fn coyote_components_iterator_filter_range(world_ptr: usize, c_type: coyote.c_type, start_idx: usize, end_idx: usize) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const components = &world._components;
    const iterator = coyote.allocator.create(coyote.SuperComponents.MaskedRangeIterator) catch unreachable;
    iterator.* = coyote.SuperComponents.MaskedRangeIterator{ .ctx = components, .filter_type = coyote.typeToIdC(c_type), .index = start_idx, .start_index = start_idx, .end_index = end_idx, .world = world };
    return @intFromPtr(iterator);
}

export fn coyote_components_iterator_filter_range_next(iterator_ptr: usize) usize {
    const iterator = @as(*coyote.SuperComponents.MaskedRangeIterator, @ptrFromInt(iterator_ptr));
    if (iterator.next()) |bind| {
        return @intFromPtr(bind);
    } else {
        coyote.allocator.destroy(iterator);
        return 0;
    }
}

// --- Command buffer: deferred structural mutations ---

const CB_BAD_INDEX: u32 = std.math.maxInt(u32);

export fn coyote_command_buffer_create(world_ptr: usize) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const cb = coyote.allocator.create(coyote.CommandBuffer) catch return 0;
    cb.* = coyote.CommandBuffer.init(world);
    return @intFromPtr(cb);
}

export fn coyote_command_buffer_destroy(cb_ptr: usize) void {
    if (cb_ptr == 0) return;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    cb.deinit();
    coyote.allocator.destroy(cb);
}

export fn coyote_command_buffer_flush(cb_ptr: usize) c_int {
    if (cb_ptr == 0) return 1;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    cb.flush() catch return 1;
    return 0;
}

export fn coyote_command_buffer_reset(cb_ptr: usize) void {
    if (cb_ptr == 0) return;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    cb.reset();
}

//Records a deferred spawn; returns a placeholder index for use as a target.
//Returns UINT32_MAX on allocation failure.
export fn coyote_cb_spawn(cb_ptr: usize) u32 {
    if (cb_ptr == 0) return CB_BAD_INDEX;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    return cb.cSpawn();
}

export fn coyote_cb_destroy_entity(cb_ptr: usize, handle: u64) c_int {
    if (cb_ptr == 0) return 1;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    return if (cb.cDestroyExisting(handle)) 0 else 1;
}

export fn coyote_cb_destroy_entity_deferred(cb_ptr: usize, placeholder: u32) c_int {
    if (cb_ptr == 0) return 1;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    return if (cb.cDestroyDeferred(placeholder)) 0 else 1;
}

//Records attaching an already-created component to an existing entity. As with
//the eager C path, populate the component's data (via coyote_component_get)
//after the buffer is flushed.
export fn coyote_cb_attach(cb_ptr: usize, handle: u64, component_ptr: usize, c_type: coyote.c_type) c_int {
    if (cb_ptr == 0 or component_ptr == 0) return 1;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    const component = @as(*coyote.Component, @ptrFromInt(component_ptr));
    return if (cb.cAttachExisting(handle, component, c_type)) 0 else 1;
}

export fn coyote_cb_attach_deferred(cb_ptr: usize, placeholder: u32, component_ptr: usize, c_type: coyote.c_type) c_int {
    if (cb_ptr == 0 or component_ptr == 0) return 1;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    const component = @as(*coyote.Component, @ptrFromInt(component_ptr));
    return if (cb.cAttachDeferred(placeholder, component, c_type)) 0 else 1;
}

export fn coyote_cb_remove(cb_ptr: usize, handle: u64, c_type: coyote.c_type) c_int {
    if (cb_ptr == 0) return 1;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    return if (cb.cRemoveExisting(handle, coyote.typeToIdC(c_type))) 0 else 1;
}

export fn coyote_cb_remove_deferred(cb_ptr: usize, placeholder: u32, c_type: coyote.c_type) c_int {
    if (cb_ptr == 0) return 1;
    const cb = @as(*coyote.CommandBuffer, @ptrFromInt(cb_ptr));
    return if (cb.cRemoveDeferred(placeholder, coyote.typeToIdC(c_type))) 0 else 1;
}

// --- Scheduler: ordered, staged system runner ---

export fn coyote_scheduler_create(world_ptr: usize) usize {
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const sched = coyote.allocator.create(coyote.Scheduler) catch return 0;
    sched.* = coyote.Scheduler.init(world);
    return @intFromPtr(sched);
}

export fn coyote_scheduler_destroy(sched_ptr: usize) void {
    if (sched_ptr == 0) return;
    const sched = @as(*coyote.Scheduler, @ptrFromInt(sched_ptr));
    sched.deinit();
    coyote.allocator.destroy(sched);
}

//Appends a new stage; returns its id (stages run in id order). Returns
//UINT32_MAX on allocation failure.
export fn coyote_scheduler_add_stage(sched_ptr: usize) u32 {
    if (sched_ptr == 0) return std.math.maxInt(u32);
    const sched = @as(*coyote.Scheduler, @ptrFromInt(sched_ptr));
    const id = sched.addStage() catch return std.math.maxInt(u32);
    return @intCast(id);
}

//Registers a C system callback into `stage`. The callback receives the world
//pointer, command buffer pointer, and the user_data passed here.
export fn coyote_scheduler_add_system(sched_ptr: usize, stage: u32, cb: coyote.Scheduler.CSystemFn, user_data: ?*anyopaque) c_int {
    if (sched_ptr == 0) return 1;
    const sched = @as(*coyote.Scheduler, @ptrFromInt(sched_ptr));
    sched.addSystemC(stage, cb, user_data) catch return 1;
    return 0;
}

export fn coyote_scheduler_run(sched_ptr: usize) c_int {
    if (sched_ptr == 0) return 1;
    const sched = @as(*coyote.Scheduler, @ptrFromInt(sched_ptr));
    sched.run() catch return 1;
    return 0;
}

// --- Resources: world-scoped singletons ---

export fn coyote_resource_insert(world_ptr: usize, c_type: coyote.c_type, data: *const anyopaque) c_int {
    if (world_ptr == 0 or @intFromPtr(data) == 0) return 1;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.resources.cInsert(world.allocator, c_type, data) catch return 1;
    return 0;
}

export fn coyote_resource_get(world_ptr: usize, c_type: coyote.c_type) ?*anyopaque {
    if (world_ptr == 0) return null;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    return world.resources.cGet(c_type);
}

export fn coyote_resource_has(world_ptr: usize, c_type: coyote.c_type) c_int {
    if (world_ptr == 0) return 0;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    return if (world.resources.cContains(c_type)) 1 else 0;
}

export fn coyote_resource_remove(world_ptr: usize, c_type: coyote.c_type) void {
    if (world_ptr == 0) return;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.resources.cRemove(world.allocator, c_type);
}

// --- Events and observers ---

export fn coyote_events_count(world_ptr: usize) c_int {
    if (world_ptr == 0) return 0;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    return @intCast(world.events.count());
}

export fn coyote_events_emit(world_ptr: usize, c_type: coyote.c_type, data: *const anyopaque) c_int {
    if (world_ptr == 0 or @intFromPtr(data) == 0) return 1;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.events.cEmit(world.allocator, c_type, data) catch return 1;
    return 0;
}

export fn coyote_events_clear(world_ptr: usize) void {
    if (world_ptr == 0) return;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.events.clearAll();
}

export fn coyote_events_drain_structural(
    world_ptr: usize,
    handler: *const fn (usize, coyote.EventKind, u64, usize, u32, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) void {
    if (world_ptr == 0) return;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    const items = world.events.queue.items;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const ev = items[i];
        const comp_ptr: usize = if (ev.component) |c| @intFromPtr(c) else 0;
        handler(@intFromPtr(world), ev.kind, ev.entity.toGlobalId(), comp_ptr, ev.type_id, user_data);
    }
    world.events.queue.clearRetainingCapacity();
}

export fn coyote_observer_on_entity_spawn(
    world_ptr: usize,
    cb: coyote.Observers.CEntityFn,
    user_data: ?*anyopaque,
) c_int {
    if (world_ptr == 0) return 1;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.observers.cOnEntitySpawn(world.allocator, cb, user_data) catch return 1;
    return 0;
}

export fn coyote_observer_on_entity_destroy(
    world_ptr: usize,
    cb: coyote.Observers.CEntityFn,
    user_data: ?*anyopaque,
) c_int {
    if (world_ptr == 0) return 1;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.observers.cOnEntityDestroy(world.allocator, cb, user_data) catch return 1;
    return 0;
}

export fn coyote_observer_on_component_add(
    world_ptr: usize,
    c_type: coyote.c_type,
    cb: coyote.Observers.CComponentFn,
    user_data: ?*anyopaque,
) c_int {
    if (world_ptr == 0) return 1;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.observers.cOnComponentAdd(world.allocator, coyote.typeToIdC(c_type), cb, user_data) catch return 1;
    return 0;
}

export fn coyote_observer_on_component_add_any(
    world_ptr: usize,
    cb: coyote.Observers.CComponentFn,
    user_data: ?*anyopaque,
) c_int {
    if (world_ptr == 0) return 1;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.observers.cOnComponentAdd(world.allocator, coyote.observe_all, cb, user_data) catch return 1;
    return 0;
}

export fn coyote_observer_on_component_remove(
    world_ptr: usize,
    c_type: coyote.c_type,
    cb: coyote.Observers.CComponentFn,
    user_data: ?*anyopaque,
) c_int {
    if (world_ptr == 0) return 1;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.observers.cOnComponentRemove(world.allocator, coyote.typeToIdC(c_type), cb, user_data) catch return 1;
    return 0;
}

export fn coyote_observer_on_component_change(
    world_ptr: usize,
    c_type: coyote.c_type,
    cb: coyote.Observers.CComponentFn,
    user_data: ?*anyopaque,
) c_int {
    if (world_ptr == 0) return 1;
    const world = @as(*coyote.World, @ptrFromInt(world_ptr));
    world.observers.cOnComponentChange(world.allocator, coyote.typeToIdC(c_type), cb, user_data) catch return 1;
    return 0;
}
