package librg

import "core:mem"
import slice "core:slice"
import runtime "base:runtime"

// Simple general fetching methods

world_fetch_all :: proc(world: ^World, entity_ids: []i64, entity_amount: ^int) -> i32 {
    assert(world != nil, "World is invalid")
    assert(entity_amount != nil, "Null reference")

    count := 0
    buffer_limit := entity_amount^
    total_count := len(world.entity_map)

    for i in 0..<min(buffer_limit, total_count) {
        all_entity_ids, err := slice.map_keys(world.entity_map)
        entity_ids[count] = all_entity_ids[i]
        count += 1
    }

    entity_amount^ = count
    return max(0, i32(total_count - buffer_limit))
}

world_fetch_chunk :: proc(world: ^World, chunk: Chunk, entity_ids: []i64, entity_amount: ^int) -> i32 {
    chunks := [1]Chunk{chunk}
    return world_fetch_chunkarray(world, chunks[:], entity_ids, entity_amount)
}

world_fetch_chunkarray :: proc(world: ^World, chunks: []Chunk, entity_ids: []i64, entity_amount: ^int) -> i32 {
    assert(world != nil, "World is invalid")
    assert(entity_amount != nil, "Null reference")

    count := 0
    iterated := 0
    buffer_limit := entity_amount^
    total_count := len(world.entity_map)

    for i in 0..<total_count {
        if count >= buffer_limit do break

        entities, err := slice.map_entries(world.entity_map)
        entity_id := entities[i].key
        entity := &entities[i].value
        iterated += 1

        for chunk in chunks {
            for j in 0..<ENTITY_MAXCHUNKS {
                if entity.chunks[j] == chunk {
                    entity_ids[count] = entity_id
                    count += 1
                    break
                }
                // immediately exit if chunk is invalid (the rest will also be invalid)
                if entity.chunks[j] == CHUNK_INVALID do break
            }
        }
    }

    entity_amount^ = count
    return max(0, i32(total_count - iterated))
}

world_fetch_owner :: proc(world: ^World, owner_id: i64, entity_ids: []i64, entity_amount: ^int) -> i32 {
    owner_ids := [1]i64{owner_id}
    return world_fetch_ownerarray(world, owner_ids[:], entity_ids, entity_amount)
}

world_fetch_ownerarray :: proc(world: ^World, owner_ids: []i64, entity_ids: []i64, entity_amount: ^int) -> i32 {
    assert(world != nil, "World is invalid")
    assert(entity_amount != nil, "Null reference")

    count := 0
    iterated := 0
    buffer_limit := entity_amount^
    total_count := len(world.entity_map)

    for i in 0..<total_count {
        if count >= buffer_limit do break

        entities_entries, err := slice.map_entries(world.entity_map)
        entity_id := entities_entries[i].key
        entity := &entities_entries[i].value
        iterated += 1

        for owner_id in owner_ids {
            if entity.owner_id == owner_id {
                entity_ids[count] = entity_id
                count += 1
            }
        }
    }

    entity_amount^ = count
    return max(0, i32(total_count - iterated))
}

// Main owner entity query method
util_chunkrange :: proc(w: ^World, ch: ^map[i64]i64, cx, cy, cz: int, radius: i8) {
    // precalculate the radius power 2 for quicker distance check
    radius2 := int(radius) * int(radius)

    // create a "bubble" by cutting off chunks outside of radius using distance checks
    for z := -int(radius); z <= int(radius); z += 1 {
        for y := -int(radius); y <= int(radius); y += 1 {
            for x := -int(radius); x <= int(radius); x += 1 {
                if x*x + y*y + z*z <= radius2 {
                    id := chunk_from_chunkpos(w, i16(cx+x), i16(cy+y), i16(cz+z))
                    if id != CHUNK_INVALID {
                        ch[i64(id)] = 1
                    }
                }
            }
        }
    }
}

// mini helper for pushing entity
// if it will overflow do not push, just increase counter for future statistics
@(private="file")
push_entity :: proc(entity_id: i64, buffer_limit: int,result_amount: ^i64, entity_ids: ^[]i64) {
    if (result_amount^ + 1) <= i64(buffer_limit) {
        entity_ids[result_amount^] = entity_id
    }
    result_amount^ += 1
}

world_query :: proc(world: ^World, owner_id: i64, chunk_radius: u8, entity_ids: ^[]i64, entity_amount: ^int) -> i32 {
    assert(world != nil, "World is invalid")
    assert(entity_amount != nil, "Null reference")

    buffer_limit := entity_amount^
    total_count := len(world.entity_map)
    result_amount: i64 = 0

    // generate a map of visible chunks (only counting owned entities)
    for pair in world.owner_entity_pairs {
        if pair.owner_id != owner_id do continue

        entity_id := pair.entity_id
        entity := &world.entity_map[entity_id]

        // allways add self-owned entities
        vis_owner := entity_visibility_owner_get(world, entity_id, owner_id)
        if vis_owner != i8(Visibility.NEVER) {
            // prevent from being included
            push_entity(entity_id, buffer_limit, &result_amount, entity_ids)
        }

        // immediately skip, if entity was not placed correctly
        if entity.chunks[0] == CHUNK_INVALID do continue
        // and skip, if used is not an owner of the entity
        if entity.owner_id != owner_id do continue

        // fetch, or create chunk set in this dimension if does not exist
        dim_chunks, ok := &world.dimensions[i64(entity.dimension)]
        if !ok {
            world.dimensions[i64(entity.dimension)] = make(map[i64]i64)
            dim_chunks = &world.dimensions[i64(entity.dimension)]
        }

        // add entity chunks to the total visible chunks
        for k in 0..<ENTITY_MAXCHUNKS {
            if entity.chunks[k] == CHUNK_INVALID do break
            chx, chy, chz: i16
            chunk_to_chunkpos(world, entity.chunks[k], &chx, &chy, &chz)
            util_chunkrange(world, dim_chunks, int(chx), int(chy), int(chz), i8(chunk_radius))
        }
    }

    // iterate on all entities, and check if they are inside of the interested chunks
    for entity_id, entity in &world.entity_map {
        if entity.owner_id == owner_id do continue

        chunks, ok := &world.dimensions[i64(entity.dimension)]
        if !ok do continue

        // owner visibility (personal)
        vis_owner := entity_visibility_owner_get(world, entity_id, owner_id)
        if vis_owner == i8(Visibility.NEVER) do continue
        if vis_owner == i8(Visibility.ALWAYS) {
            push_entity(entity_id, buffer_limit, &result_amount, entity_ids)
            continue // prevent from being included
        }

        // global entity visibility
        vis_global := entity_visibility_global_get(world, entity_id)
        if vis_global == i8(Visibility.NEVER) do continue // prevent from being included
        if vis_global == i8(Visibility.ALWAYS) {
            push_entity(entity_id, buffer_limit, &result_amount, entity_ids)
            continue
        }

        for chunk in chunks {
            for j in 0..<ENTITY_MAXCHUNKS {
                // immediately exit if chunk is invalid (the rest will also be invalid)
                if entity.chunks[j] == CHUNK_INVALID do break
                // add entity and continue to the next one
                if entity.chunks[j] == Chunk(chunk) {
                    push_entity(entity_id, buffer_limit, &result_amount, entity_ids)
                    break
                }
            }
        }
    }

    // free up temp data
    for dim, chunks in &world.dimensions {
        delete(chunks)
    }
    clear(&world.dimensions)

    entity_amount^ = int(min(i64(buffer_limit), result_amount))
    return max(0, i32(result_amount - i64(buffer_limit)))
}
