import os 'os'

lib = os.bindLib('../zig-out/lib/coyote.dll', [
    os.CFunc{ sym: 'coyote_world_create', args: [], ret: #usize }
    os.CFunc{ sym: 'coyote_entity_create', args: [#usize], ret: #usize }
    os.CFunc{ sym: 'coyote_component_create', args: [#usize, #usize], ret: #usize }
    os.CFunc{ sym: 'coyote_entity_attach', args: [#usize, #usize, #usize], ret: #int }
    os.CFunc{ sym: 'coyote_component_get', args: [#usize], ret: #voidPtr }
    os.CStruct{ fields: [#int, #int, #int], type: apple }
])

object apple:
    id
    size
    name
    color
    ripe
    harvested
    func type():
        return apple{ id: 0, size: 1024, name: "apple" }

object orange:
    id
    size
    name
    color
    ripe
    harvested
    func type():
        return orange{ id: 1, size: 1024, name: "orange" }

object pear:
    id
    size
    name
    color
    ripe
    harvested
    func type():
        return pear{ id: 2, size: 1024, name: "pear" }

world = lib.coyote_world_create()
e_apple = lib.coyote_entity_create(world)
e_orange = lib.coyote_entity_create(world)
e_pear = lib.coyote_entity_create(world)

c_apple = lib.coyote_component_create(world, apple.type())
c_orange = lib.coyote_component_create(world, orange.type())
c_pear = lib.coyote_component_create(world, pear.type())

lib.coyote_entity_attach(e_apple, c_apple, apple.type())

a1obj = lib.coyote_component_get(c_apple)
a1 = lib.ptrToapple(a1obj)

a1.color = 255