package worldnet

import "core:mem"
import "core:fmt"
import "core:math"
import rand "core:math/rand"

// Constants
LIBRG_VERSION :: 1000 // Assuming version 1.0.0.0

// Utility functions
librg_version :: proc() -> u32 {
    return LIBRG_VERSION
}

world_create :: proc() -> ^World {
    when WORLDWRITE_MAXQUERY > U16_MAX do panic("LIBRG_WORLDWRITE_MAXQUERY must have value less than 65535")

    wld := new(World)
    wld.valid = true
    wld.allocator = context.allocator

    // Setup defaults
    config_chunksize_set(wld, 16, 16, 16)
    config_chunkamount_set(wld, 256, 256, 256)
    config_chunkoffset_set(wld, OFFSET_MID, OFFSET_MID, OFFSET_MID)

    // Initialize internal structures
    wld.entity_map = make(map[i64]Entity)
    wld.owner_map = make(map[i64]map[i64]i64)
    wld.random = rand.create(0)
    wld.owner_entity_pairs = make([dynamic]OwnerEntityPair)
    wld.dimensions = make(map[i64]map[i64]i64)

    return wld
}

world_destroy :: proc(world: ^World) -> i8 {
    if world == nil do return WORLD_INVALID

    // Free up entities
    for key, entity in &world.entity_map {
        if entity.flag_visbility_owner_enabled {
            // TODO: ENSURE THAT flag_visbility_owner_enabled is updated on the entity in the map
            ent := &world.entity_map[key]
            ent.flag_visbility_owner_enabled = false
            delete(entity.owner_visibility_map)
        }
    }
    delete(world.entity_map)

    // Free up owners
    for _, owner_map in &world.owner_map {
        delete(owner_map)
    }
    delete(world.owner_map)

    delete(world.owner_entity_pairs)
    delete(world.dimensions)

    // Mark it invalid
    world.valid = false
    free(world)
    return OK
}

world_valid :: proc(world: ^World) -> bool {
    return world != nil && world.valid
}

world_userdata_set :: proc(world: ^World, data: rawptr) -> i8 {
    if world == nil do return WORLD_INVALID
    world.userdata = data
    return OK
}

world_userdata_get :: proc(world: ^World) -> rawptr {
    if world == nil do return nil
    return world.userdata
}

world_entities_tracked :: proc(world: ^World) -> i64 {
    if world == nil do return WORLD_INVALID
    return i64(len(world.entity_map))
}

// Configuration methods
config_chunkamount_set :: proc(world: ^World, x, y, z: u32) -> i8 {
    if world == nil do return WORLD_INVALID
    world.worldsize = {x == 0 ? 1 : x, y == 0 ? 1 : y, z == 0 ? 1 : z}
    return OK
}

config_chunkamount_get :: proc(world: ^World) -> (x, y, z: u32) {
    if world == nil do return 0, 0, 0
    return world.worldsize.x, world.worldsize.y, world.worldsize.z
}

config_chunksize_set :: proc(world: ^World, x, y, z: u32) -> i8 {
    if world == nil do return WORLD_INVALID
    world.chunksize = {x == 0 ? 1 : x, y == 0 ? 1 : y, z == 0 ? 1 : z}
    return OK
}

config_chunksize_get :: proc(world: ^World) -> (x, y, z: u32) {
    if world == nil do return 0, 0, 0
    return world.chunksize.x, world.chunksize.y, world.chunksize.z
}

config_chunkoffset_set :: proc(world: ^World, x, y, z: i32) -> i8 {
    if world == nil do return WORLD_INVALID
    world.chunkoffset = {x, y, z}
    return OK
}

config_chunkoffset_get :: proc(world: ^World) -> (x, y, z: i32) {
    if world == nil do return 0, 0, 0
    return world.chunkoffset.x, world.chunkoffset.y, world.chunkoffset.z
}

// Event handling
event_set :: proc(world: ^World, id: EventType, handler: EventHandler) -> i8 {
    if world == nil do return WORLD_INVALID
    if world.handlers[id] != nil {
        world.handlers[id] = handler
        return HANDLER_REPLACED
    }
    world.handlers[id] = handler
    return OK
}

event_remove :: proc(world: ^World, id: EventType) -> i8 {
    if world == nil do return WORLD_INVALID
    if world.handlers[id] == nil do return HANDLER_EMPTY
    world.handlers[id] = nil
    return OK
}

event_type_get :: proc(event: ^Event) -> i8 {
    if event == nil do return EVENT_INVALID
    return i8(event.type)
}

event_owner_get :: proc(event: ^Event) -> i64 {
    if event == nil do return EVENT_INVALID
    return event.owner_id
}

event_entity_get :: proc(event: ^Event) -> i64 {
    if event == nil do return EVENT_INVALID
    return event.entity_id
}

// TODO: REMOVE
event_buffer_get :: proc(event: ^Event) -> []byte {
    if event == nil do return nil
    return event.buffer
}

event_size_get :: proc(event: ^Event) -> i32 {
    if event == nil do return EVENT_INVALID
    return i32(event.size)
}

event_userdata_get :: proc(event: ^Event) -> rawptr {
    if event == nil do return nil
    return event.userdata
}

// Utility functions
util_chunkoffset_line :: proc(v, off, size: i32) -> i32 {
    o: f32 = 0 // OFFSET_BEG
    switch off {
    case OFFSET_MID: o = f32(size) / 2
    case OFFSET_END: o = f32(size)
    }

    // integrate the offset
    o += f32(v)
    return i32(o >= 0 ? math.floor(o) : math.ceil(o))
}

chunk_from_chunkpos :: proc(world: ^World, chunk_x, chunk_y, chunk_z: i32) -> Chunk {
    if world == nil do return WORLD_INVALID
    chx := util_chunkoffset_line(chunk_x, world.chunkoffset.x, i32(world.worldsize.x))
    chy := util_chunkoffset_line(chunk_y, world.chunkoffset.y, i32(world.worldsize.y))
    chz := util_chunkoffset_line(chunk_z, world.chunkoffset.z, i32(world.worldsize.z))

    // return error if the size is too far off the max world limits
    if chx < 0 || chx >= i32(world.worldsize.x) ||
       chy < 0 || chy >= i32(world.worldsize.y) ||
       chz < 0 || chz >= i32(world.worldsize.z) {
        return CHUNK_INVALID
    }

    id := Chunk((chz * i32(world.worldsize.y) * i32(world.worldsize.x)) + (chy * i32(world.worldsize.x)) + chx)
    if id < 0 || id > Chunk(world.worldsize.x * world.worldsize.y * world.worldsize.z) {
        return CHUNK_INVALID
    }

    return id
}

// convert chunk to world x, y and z position 
chunk_to_chunkpos :: proc(world: ^World, id: Chunk, chunk_x, chunk_y, chunk_z: ^i32) -> (ok: i8) {
    if world == nil do return CHUNK_INVALID
    wld: ^World = world;

    if id < Chunk(0) || id > Chunk(wld.worldsize.x * wld.worldsize.y * wld.worldsize.z) {
        return CHUNK_INVALID
    }

    z := i64(id) / (i64(wld.worldsize.x) * i64(wld.worldsize.y))
    r1 := i64(id) % (i64(wld.worldsize.x) * i64(wld.worldsize.y))
    y := r1 / i64(wld.worldsize.x)
    x := r1 % i64(wld.worldsize.x)

    chunk_x^ = i32(x) - util_chunkoffset_line(0, wld.chunkoffset.x, i32(wld.worldsize.x))
    chunk_y^ = i32(y) - util_chunkoffset_line(0, wld.chunkoffset.y, i32(wld.worldsize.y))
    chunk_z^ = i32(z) - util_chunkoffset_line(0, wld.chunkoffset.z, i32(wld.worldsize.z))

    return OK
}

chunk_from_realpos :: proc(world: ^World, x, y, z: f64) -> Chunk {
    if world == nil do return WORLD_INVALID
    return chunk_from_chunkpos(world, 
        i32(x / f64(world.chunksize.x)),
        i32(y / f64(world.chunksize.y)),
        i32(z / f64(world.chunksize.z)))
}
