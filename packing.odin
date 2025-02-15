package worldnet

import "core:mem"
import "core:log"
import slice "core:slice"
import "core:fmt"
import "core:bytes"
import utils "../../utils"

// size of the segment
SEGMENT_SIZE :: 8
// size of the segment value
SEGVAL_SIZE :: 14 when ENABLE_EXTENDED_EVENTBUFFER else 12

SegVal :: struct #packed {
    id: u64,
    token: u16,
    size: WORLDWRITE_DATATYPE,
}

Segment :: struct #packed {
    type: u8,
    unused_: u8,
    amount: u16,
    size: u32,
}

WorldWrite :: struct #packed {
    segments: []Segment,
    segvals: []SegVal,
    length: int,
}

SegValOne :: struct{val: SegVal, event_buffer: []byte}

// World data packing method
world_write :: proc(world: ^World, owner_id: i64, chunk_radius: u8, buffer: ^bytes.Buffer, size: ^int, userdata: rawptr) -> i32 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID

    last_snapshot := world.owner_map[owner_id]

    // no snapshot - means we are asking an invalid owner
    if last_snapshot == nil {
        size^ = 0
        return OWNER_INVALID
    }

    // get old, and preapre new snapshot handlers
    next_snapshot := make(map[i64]i64)
    results := make([]i64, WORLDWRITE_MAXQUERY)
    total_amount := WORLDWRITE_MAXQUERY
    world_query(world, owner_id, chunk_radius, &results, &total_amount)

    total_written := 0
    evt := Event{}

    total_size := total_written + size_of(Segment)
    value_size := total_size + 0 + size_of(SegVal)

    action_id := u8(EventType.WRITE_CREATE)
    buffer_limit := size^
    insufficient_size := 0

    /*

        BUFFER SCHEMA :

        [ [ Segment | [Segval | event data ] | [Segval | event data ] ... ] | [ Segment | [Segval | event data ] | [Segval | event data ] ... ] ... ]

    */

    write_loop:
    for {
        // create and update
        if total_size < buffer_limit {
            seg := Segment{}

            amount := u16(0)
            value_written := 0
            total_size = total_written + size_of(Segment)
            // end of current segment
            segend := total_size
            value_size = total_size + value_written + size_of(SegVal)
            iterations := total_amount

            vals : [dynamic]SegValOne
            
            // for deletions we are iterating something else
            if action_id == u8(EventType.WRITE_REMOVE) {
                iterations = len(last_snapshot)
            }

            for i := 0; i < iterations; i += 1 {
                action_rejected := true
                data_size := i32(0)
                data_buffer : []byte

                // Preparation
                entity_id: i64
                entity_blob: ^Entity = nil
                condition := false

                switch action_id {
                    case u8(EventType.WRITE_CREATE):
                        entity_id = results[i]  // it did not exist && not foreign
                        entity_blob = &world.entity_map[entity_id]
                        condition = last_snapshot[entity_id] == 0 && !entity_foreign(world, entity_id)
                    case u8(EventType.WRITE_UPDATE):
                        entity_id = results[i]  // it did exist
                        entity_blob = &world.entity_map[entity_id]
                        condition = last_snapshot[entity_id] != 0 || entity_foreign(world, entity_id) == true

                        // mark entity as still alive, to prevent it from being removed
                        last_snapshot[entity_id] = 2
                    case u8(EventType.WRITE_REMOVE):
                        last_snapshot_entries, err := slice.map_entries(last_snapshot)
                        entity_id = last_snapshot_entries[i].key // it was not marked as updated && and not foreign
                        condition = last_snapshot_entries[i].value != 2 && !entity_foreign(world, entity_id)
                    case u8(PackagingType.WRITE_OWNER):
                        entity_id = results[i]  // if we are the owner and we havent yet notified reader about that
                        entity_blob = &world.entity_map[entity_id]
                        condition = entity_blob != nil && entity_blob.owner_id == owner_id && entity_blob.flag_owner_updated && next_snapshot[entity_id] != 0
                }

                // Data write
                if condition && value_size + size_of(SegVal) < buffer_limit {
                    val := SegVal{}

                    // Fill in event
                    evt.entity_id = entity_id
                    evt.type = action_id
                    evt.size = buffer_limit - value_size
                    //evt.buffer = valend
                    evt.owner_id = owner_id
                    evt.userdata = userdata

                    // Call event handlers
                    if world.handlers[action_id] != nil {
                        data_size, data_buffer = world.handlers[action_id](world, &evt)

                        evt.buffer = data_buffer

                        if data_size > I32_MAX {
                            panic(fmt.tprintf("librg: the data size returned by the event handler is too big for the event. \n Ensure that you are not returning more than %d bytes.", I32_MAX))
                        }

                        when ENABLE_EXTENDED_EVENTBUFFER {
                            if (data_size > i32(U16_MAX)) {
                                panic(fmt.tprintf("librg: the data size returned by the event handler is bigger than the event buffer size. \n Ensure that you are not returning more than %d bytes.", evt.size));
                            }
                        }
                    }

                    // Fill in segval
                    // if user returned < 0, we consider that event rejected
                    if data_size >= 0 {
                        val.id = u64(entity_id)
                        val.size = WORLDWRITE_DATATYPE(data_size)

                        if action_id == u8(PackagingType.WRITE_OWNER) {
                            val.token = entity_blob.ownership_token
                        } else if action_id == u8(EventType.WRITE_CREATE) && entity_blob.owner_id == owner_id {
                            val.token = 1
                        } else if action_id == u8(EventType.WRITE_UPDATE) && entity_blob.flag_foreign {
                            val.token = entity_blob.ownership_token
                        } else {
                            val.token = 0
                        }

                        // increase the total size written
                        value_written += size_of(SegVal) + int(val.size)
                        action_rejected = false
                        amount += 1

                        append(&vals, SegValOne{val = val, event_buffer = evt.buffer})
                    }
                }

                // Accumulate insufficient buffer size
                if condition && total_written + value_written + size_of(SegVal) >= buffer_limit {
                    insufficient_size += (value_size - buffer_limit)
                }

                // Finalization
                switch action_id {
                case u8(EventType.WRITE_CREATE):
                    // mark entity as created, so it can start updating
                    if !action_rejected do next_snapshot[entity_id] = 1
                case u8(EventType.WRITE_UPDATE):
                    // consider entitry updated, without regards was it written or not
                    if condition do next_snapshot[entity_id] = 1
                case u8(EventType.WRITE_REMOVE):
                    // consider entity alive, till we are able to send it
                    if condition && action_rejected do next_snapshot[entity_id] = 1
                case u8(PackagingType.WRITE_OWNER):
                    // mark reader as notified
                    if condition do entity_blob.flag_owner_updated = false
                }
            }

            if amount > 0 {
                seg.type = action_id
                seg.size = u32(value_written)
                seg.amount = amount

                seg_bytes := mem.byte_slice(&seg, size_of(Segment))
                bytes.buffer_write_at(buffer, seg_bytes, total_written)

                current_offset := total_written + size_of(Segment)
                for &v in vals {
                    segval_bytes := mem.byte_slice(&v.val, size_of(SegVal))
                    bytes.buffer_write_at(buffer, segval_bytes, current_offset)
                    bytes.buffer_write_at(buffer, v.event_buffer, current_offset + size_of(SegVal))

                    current_offset += size_of(SegVal) + int(v.val.size)
                }

                total_written += size_of(Segment) + int(seg.size)
            } else {
                insufficient_size += total_size - buffer_limit
            }            
        }

        // Iterate again till all tasks are finished
        switch action_id {
        case u8(EventType.WRITE_CREATE):
            action_id = u8(EventType.WRITE_UPDATE)
            continue write_loop
        case u8(EventType.WRITE_UPDATE):
            action_id = u8(EventType.WRITE_REMOVE)
            continue write_loop
        case u8(EventType.WRITE_REMOVE):
            action_id = u8(PackagingType.WRITE_OWNER)
            continue write_loop
        case:
            break write_loop
        }
    }
    // Swap snapshot tables
    delete(last_snapshot)
    world.owner_map[owner_id] = next_snapshot
    delete(results)

    // Write our total size
    size^ = total_written

    // if we didnt have enough space, value will be > 0
    return i32(insufficient_size)
}

// World data unpacking method
world_read :: proc(world: ^World, owner_id: i64, buffer: ^bytes.Buffer, size: int, userdata: rawptr) -> i32 {
    assert(world != nil)
    if world == nil do return WORLD_INVALID

    evt := Event{}
    total_read := 0

    segment_size := 0

    /*

        BUFFER SCHEMA :

        [ [ Segment | [Segval | event data ] | [Segval | event data ] ... ] | [ Segment | [Segval | event data ] | [Segval | event data ] ... ] ... ]

    */

    for (size-total_read) > size_of(Segment) {
        segment_read := 0

        segment_size = total_read + size_of(Segment)
        segval_size := segment_size + segment_read + size_of(SegVal)

        seg_bytes := bytes.buffer_next(buffer, size_of(Segment))
        seg, seg_ok := utils.read_from_bytes(seg_bytes, Segment)

        if seg_ok != true {
            break
        }

        // immediately exit if we will not be able to read the segment data
        if segment_size + int(seg.size) > size || segment_size + int(seg.amount) * size_of(SegVal) > size {
            break
        }

        for i := 0; i < int(seg.amount); i += 1 {
            val_bytes := bytes.buffer_next(buffer, size_of(SegVal))
            val, val_ok := utils.read_from_bytes(val_bytes, SegVal)

            if val_ok != true {
                break
            }

            entity_blob := &world.entity_map[i64(val.id)]
            action_id: i8 = -1

            // Do preparation for entity processing
            switch seg.type {
            case u8(EventType.WRITE_CREATE):
                // attempt to create an entity
                action_id = entity_track(world, i64(val.id)) == OK ? i8(EventType.READ_CREATE) : i8(EventType.ERROR_CREATE)
            case u8(EventType.WRITE_UPDATE):
                // try to check if entity exists, and if it is foreign OR owner and token are correct
                action_id = entity_tracked(world, i64(val.id)) && 
                            entity_blob != nil && 
                            (entity_blob.flag_foreign || 
                             (entity_blob.owner_id == owner_id && 
                              entity_blob.ownership_token == val.token)) ? i8(EventType.READ_UPDATE) : i8(EventType.ERROR_UPDATE)
            case u8(EventType.WRITE_REMOVE):
                // attempt to check if it does exist and only foreign
                action_id = entity_tracked(world, i64(val.id)) && 
                            entity_foreign(world, i64(val.id)) ? i8(EventType.READ_REMOVE) : i8(EventType.ERROR_REMOVE)
            case u8(PackagingType.WRITE_OWNER):
                // attempt to check if it does exist and only foreign
                action_id = entity_tracked(world, i64(val.id)) && 
                            entity_foreign(world, i64(val.id)) ? i8(PackagingType.READ_OWNER) : i8(PackagingType.ERROR_OWNER)
            }

            if action_id == -1 do return READ_INVALID

            // do the initial entity processing
            if action_id == i8(EventType.READ_CREATE) {
                // mark newly created entity as foreign
                entity := &world.entity_map[i64(val.id)]
                if entity == nil do return READ_INVALID
                entity.flag_foreign = true
                if val.token == 1 do entity.owner_id = owner_id
            }

            // read value stored be event
            data_byffer := bytes.buffer_next(buffer, int(val.size))

            // Fill in event
            evt.entity_id = i64(val.id)
            evt.type = u8(action_id)
            evt.size = int(val.size)
            evt.buffer = data_byffer
            evt.owner_id = owner_id
            evt.userdata = userdata

            // Call event handlers
            if world.handlers[action_id] != nil {
                // ignore response
                world.handlers[action_id](world, &evt)
            }

            // do the afterwork processing (Post-processing)
            if EventType(action_id) == EventType.READ_REMOVE {
                // remove foreign mark from entity
                entity := &world.entity_map[i64(val.id)]
                if entity == nil do return READ_INVALID
                entity.flag_foreign = false
                entity_untrack(world, i64(val.id))
            } else if PackagingType(action_id) == PackagingType.READ_OWNER {
                entity := &world.entity_map[i64(val.id)]
                if entity == nil do return READ_INVALID

                // immediately mark entity as owned, set up & override additional info
                entity.flag_foreign = false // unmark it temp, while owner is set
                entity_owner_set(world, i64(val.id), owner_id)
                entity.ownership_token = val.token
                entity.flag_owner_updated = false
                entity.flag_foreign = true
            }

            segment_read += size_of(SegVal) + int(val.size)
        }

        // validate sizes of the data we read
        if segment_read != int(seg.size) do return READ_INVALID

        total_read += size_of(Segment) + segment_read
    }

    if total_read != size do return i32(size - total_read)

    return OK
}
