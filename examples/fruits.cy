import os 'os'

lib = os.bindLib('../zig-out/lib/coyote.dll', [
    os.CFunc{ sym: 'coyote_world_create', args: [], ret: #usize }
    os.CFunc{ sym: 'coyote_entity_create', args: [#usize], ret: #usize }
    os.CStruct{ fields: [#usize, #usize, #charPtrZ], type: t_apple }
    os.CFunc{ sym: 'coyote_component_create', args: [#usize, t_apple], ret: #usize }
    os.CFunc{ sym: 'coyote_entity_attach', args: [#usize, #usize, #usize], ret: #int }
    os.CFunc{ sym: 'coyote_component_get', args: [#usize], ret: #voidPtr }
    os.CStruct{ fields: [#int, #int, #int], type: apple }
])

object apple:
    color
    ripe
    harvested

object t_apple:
    id
    size
    name
    func type():
        return t_apple{ id: 0, size: 1024, name: "apple" }

object orange:
    color
    ripe
    harvested

object t_orange:
    id
    size
    name
    func type():
        return t_orange{ id: 1, size: 1024, name: "orange" }

object pear:
    color
    ripe
    harvested

object t_pear:
    id
    size
    name
    func type():
        return t_pear{ id: 2, size: 1024, name: "pear" }

world = lib.coyote_world_create()
e_apple = lib.coyote_entity_create(world)
e_orange = lib.coyote_entity_create(world)
e_pear = lib.coyote_entity_create(world)

c_apple = lib.coyote_component_create(world, t_apple.type())
c_orange = lib.coyote_component_create(world, t_orange.type())
c_pear = lib.coyote_component_create(world, t_pear.type())

lib.coyote_entity_attach(e_apple, c_apple, t_apple.type())

a1obj = lib.coyote_component_get(c_apple)
print a1obj

a1 = lib.ptrToapple(a1obj) -- Segfault

-- a1.color = 255