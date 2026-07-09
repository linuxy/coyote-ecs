# Advanced Optimizations

This guide covers advanced optimization techniques for Coyote ECS, including SIMD operations, vectorization, and other performance enhancements.

## SIMD Optimizations

SIMD (Single Instruction, Multiple Data) lets you process multiple `f32` values per instruction. Coyote ECS stores sole-owner components in **SoA archetype columns**, so hot systems can walk dense typed slices instead of sparse component slots.

### Column-oriented queries

Prefer `queryViewSimd` for bulk numeric work. It yields entire archetype columns for each matching signature:

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };

pub fn IntegrateMotion(world: *World, dt: f32) void {
    var qv = world.entities.queryViewSimd(.{ Position, Velocity });
    qv.integratePosition2D(Position, Velocity, dt);
}
```

For custom per-element updates on one component type:

```zig
const SetRipe = struct {
    fn set(fruit: *Components.Apple) void {
        fruit.ripe = true;
    }
};

var qv = world.entities.queryViewSimd(.{Components.Apple});
qv.processColumn(Components.Apple, SetRipe.set);
```

`forEachColumn` exposes the raw `[]T` slice when you want manual SIMD:

```zig
const Update = struct {
    fn update(slice: []f32, _: u32) void {
        ColumnSimd.fillUniformSimd(f32, slice, 0);
    }
};
var qv = world.entities.queryViewSimd(.{MyFloatComponent});
qv.forEachColumn(MyFloatComponent, Update.update);
```

### Type-wide column passes

When you do not need a multi-component query filter, use `processComponentsSimd`:

```zig
world.components.processComponentsSimd(Components.Velocity, ApplyDrag.apply);
```

Parallel chunking can target row ranges inside each archetype column:

```zig
world.components.processComponentsRangeSimd(Components.Velocity, start, end, ApplyDrag.apply);
```

### Low-level helpers

```zig
// dst[i] += src[i] * scale
ColumnSimd.f32AddMulSimd(dst, src, scale);

// SIMD fill for f32 columns
ColumnSimd.fillUniformSimd(f32, slice, value);

// Integrate matched position/velocity columns across all archetypes
SimdSystems.integratePosition2DQuery(world, Position, Velocity, dt);
```

### Per-entity vs column APIs

| Use case | API |
|----------|-----|
| Need entity handle + several components | `queryView` |
| Bulk update one component column | `queryViewSimd.processColumn` |
| 2D motion integration | `integratePosition2D` |
| Structural changes (attach/detach/destroy) | `iteratorFilter` / commands |

### Parallel processing with column ranges

`processComponentsRangeSimd` and `queryViewSimd` operate on archetype row indices. For threading, partition row ranges per archetype (or per type via `processComponentsRangeSimd`) instead of using sparse global component indices:

```zig
pub fn UpdateVelocitiesParallel(world: *World, start: usize, end: usize) void {
    world.components.processComponentsRangeSimd(Components.Velocity, start, end, ApplyGravity.apply);
}
```

## Vectorized Entity and Component Storage

### SoA archetype columns

Coyote ECS groups entities by component signature and stores sole-owner component data in dense columns inside each archetype table:

```zig
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

// Column access via queryView / queryViewSimd
var qv = world.entities.queryView(.{ Position });
while (qv.next()) |row| {
    row.get(Position).x += 1;
}
```

`queryViewSimd` skips per-entity iteration and hands systems the full `[]Position` slice for each matching archetype.

Batch spawning (`createBatchUniform`, `createBatchValues`, `createBatchComponents`) fills those columns without per-entity attach overhead.

## Memory Alignment for SIMD

Archetype columns respect each component type's natural alignment (`@alignOf(T)`). For `f32` fields inside structs, the column stores whole `T` values; `SimdSystems.integratePosition2D` gathers/scatters `x`/`y` lanes with the host's suggested vector width.

## Benchmarking column vs scalar iteration

Compare `queryView` (per-entity) against `queryViewSimd.integratePosition2D` (column SIMD):

```zig
pub fn IntegrateScalar(world: *World, dt: f32) void {
    var qv = world.entities.queryView(.{ Position, Velocity });
    while (qv.next()) |row| {
        const vel = row.get(Velocity);
        const pos = row.get(Position);
        pos.x += vel.dx * dt;
        pos.y += vel.dy * dt;
    }
}

pub fn IntegrateSimd(world: *World, dt: f32) void {
    var qv = world.entities.queryViewSimd(.{ Position, Velocity });
    qv.integratePosition2D(Position, Velocity, dt);
}
```

Spawn test data with `createBatchUniform` or `createBatchComponents` so benchmarks measure column iteration, not entity creation.

## Next Steps

- Check out the [Performance Guide](performance-guide.md) for general optimization tips
- Explore the [Examples](examples.md) for practical usage patterns
- Read the [Core Concepts](core-concepts.md) for a deeper understanding of ECS 