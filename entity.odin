package worldnet

import "core:mem"
import "core:fmt"
import rand "core:math/rand"
import runtime "base:runtime"


// Basic entity manipulation

entity_track :: proc(world: ^World, entity_id: i64) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID

    if entity_tracked(world, entity_id) == true do return ENTITY_ALREADY_TRACKED
    if entity_id < 0 || entity_id > I64_MAX do return ENTITY_INVALID

    entity := Entity{}
    world.entity_map[entity_id] = entity

    // Set defaults
    entity_chunk_set(world, entity_id, CHUNK_INVALID)
    entity_owner_set(world, entity_id, OWNER_INVALID)
    return OK
}

entity_untrack :: proc(world: ^World, entity_id: i64) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID

    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    if entity.flag_foreign == true do return ENTITY_FOREIGN

    // Cleanup owner snapshots
    if entity.owner_id != OWNER_INVALID {
        owned := 0
        total := len(world.entity_map)
        
        // Count already owned entities by this user
        for _, e in world.entity_map {
            if e.owner_id == entity.owner_id do owned += 1
        }

        snapshot, ok := &world.owner_map[entity.owner_id]

        // Free up our snapshot storage, if owner does not own other entities (except current one)
        if ok && owned <= 1 {
            runtime.clear(snapshot)
            runtime.delete_key(&world.owner_map, entity.owner_id)
        }

        // Cleanup owner-entity pair
        for i := 0; i < len(world.owner_entity_pairs); i += 1 {
            if world.owner_entity_pairs[i].entity_id == entity_id {
                ordered_remove(&world.owner_entity_pairs, i)
                break
            }
        }
    }

    // Cleanup owner visibility
    if entity.flag_visbility_owner_enabled {
        entity.flag_visbility_owner_enabled = false
        delete(entity.owner_visibility_map)
    }

    delete_key(&world.entity_map, entity_id)
    return OK
}

entity_tracked :: proc(world: ^World, entity_id: i64) -> bool {
    assert(world != nil)
    if world == nil do return false
    _, ok := world.entity_map[entity_id]
    return ok
}

entity_foreign :: proc(world: ^World, entity_id: i64) -> bool {
    assert(world != nil)
    if world == nil do return false
    entity, ok := &world.entity_map[entity_id]
    if !ok do return false
    return entity.flag_foreign
}

entity_owned :: proc(world: ^World, entity_id: i64) -> bool {
    assert(world != nil)
    if world == nil do return false
    entity, ok := &world.entity_map[entity_id]
    if !ok do return false
    return entity.owner_id != OWNER_INVALID
}

entity_count :: proc(world: ^World) -> i32 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    return i32(len(world.entity_map))
}

// Main entity data methods

entity_chunk_set :: proc(world: ^World, entity_id: i64, chunk: Chunk) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    for i := 0; i < ENTITY_MAXCHUNKS; i += 1 do entity.chunks[i] = CHUNK_INVALID
    entity.chunks[0] = chunk
    return OK
}

entity_chunk_get :: proc(world: ^World, entity_id: i64) -> Chunk {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    return entity.chunks[0]
}

entity_owner_set :: proc(world: ^World, entity_id: i64, owner_id: i64) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    if entity.flag_foreign == true do return ENTITY_FOREIGN

    // Update owner-entity pairing
    if owner_id != OWNER_INVALID {
        ownership_pair_found := false
        for &pair, i in &world.owner_entity_pairs {
            if pair.entity_id == entity_id {
                ownership_pair_found = true

                // update owner if we found the entity 
                if pair.owner_id != owner_id {
                    pair.owner_id = owner_id
                }
                break
            }
        }
        if !ownership_pair_found {
            append(&world.owner_entity_pairs, OwnerEntityPair{owner_id, entity_id})
        }
    } else if entity.owner_id != OWNER_INVALID {
        // Cleanup owner-entity pair
        for pair, i in &world.owner_entity_pairs {
            if pair.entity_id == entity_id {
                ordered_remove(&world.owner_entity_pairs, i)
                break
            }
        }
    }

    entity.owner_id = owner_id
    entity.flag_owner_updated = true
    if entity.owner_id != OWNER_INVALID {
        // Set new token, and make sure to prevent collisions
        newtoken: u16 = 0
        for {
            generator := runtime.default_random_generator(&world.random)
            newtoken = u16(u16(rand.uint32(generator)) % max(u16))
            if newtoken != 0 && newtoken != entity.ownership_token do break
        }
        entity.ownership_token = newtoken

        // Fetch or create a new subtable
        snapshot, ok := &world.owner_map[owner_id]
        if !ok {
            world.owner_map[owner_id] = make(map[i64]i64)
            owner_map := &world.owner_map[owner_id]
            owner_map[entity_id] = 0
        }
    } else {
        entity.ownership_token = 0
    }

    return OK
}

entity_owner_get :: proc(world: ^World, entity_id: i64) -> i64 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    return entity.owner_id
}

entity_dimension_set :: proc(world: ^World, entity_id: i64, dimension: i32) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    entity.dimension = dimension
    return OK
}

entity_dimension_get :: proc(world: ^World, entity_id: i64) -> i32 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    return entity.dimension
}

entity_userdata_set :: proc(world: ^World, entity_id: i64, data: rawptr) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    entity.userdata = data
    return OK
}

entity_userdata_get :: proc(world: ^World, entity_id: i64) -> rawptr {
    assert(world != nil)
    if world == nil do return nil
    entity, ok := &world.entity_map[entity_id]
    if !ok do return nil
    return entity.userdata
}

entity_chunkarray_set :: proc(world: ^World, entity_id: i64, values: []Chunk) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    assert(len(values) > 0 && len(values) < ENTITY_MAXCHUNKS)
    for i := 0; i < ENTITY_MAXCHUNKS; i += 1 do entity.chunks[i] = CHUNK_INVALID
    copy(entity.chunks[:], values)
    return OK
}

entity_chunkarray_get :: proc(world: ^World, entity_id: i64, results: []Chunk) -> (chunk_amount: int, err: i8) {
    assert(world != nil)
    if world == nil do return 0, WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return 0, ENTITY_UNTRACKED
    assert(results != nil)
    count := 0
    buffer_limit := len(results)
    for i := 0; i < min(buffer_limit, ENTITY_MAXCHUNKS); i += 1 {
        if entity.chunks[i] != CHUNK_INVALID {
            results[count] = entity.chunks[i]
            count += 1
        }
    }
    return count, i8(ENTITY_MAXCHUNKS - buffer_limit)
}

entity_visibility_global_set :: proc(world: ^World, entity_id: i64, value: Visibility) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    entity.visibility_global = u8(value)
    return OK
}

entity_visibility_global_get :: proc(world: ^World, entity_id: i64) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    return i8(entity.visibility_global)
}

entity_visibility_owner_set :: proc(world: ^World, entity_id: i64, owner_id: i64, value: Visibility) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    if !entity.flag_visbility_owner_enabled {
        entity.flag_visbility_owner_enabled = true
        entity.owner_visibility_map = make(map[i64]i8)
    }
    entity.owner_visibility_map[owner_id] = i8(value)
    return OK
}

entity_visibility_owner_get :: proc(world: ^World, entity_id: i64, owner_id: i64) -> i8 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID
    entity, ok := &world.entity_map[entity_id]
    if !ok do return ENTITY_UNTRACKED
    if !entity.flag_visbility_owner_enabled do return i8(Visibility.DEFAULT)
    value, exist := entity.owner_visibility_map[owner_id]
    return exist ? i8(value) : i8(Visibility.DEFAULT)
}
