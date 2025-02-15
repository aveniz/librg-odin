package worldnet

import "core:mem"
import runtime "base:runtime"

// defines how many max chunks an entity
// can be located in simultaneously
ENTITY_MAXCHUNKS :: 8

// defines how many max entity ids could be used
// inside of the world_write call
WORLDWRITE_MAXQUERY :: 16384

ENABLE_EXTENDED_EVENTBUFFER : bool : false

I64_MAX :: max(i64)
I32_MAX :: max(i32)
U16_MAX :: max(u16)

// enables the increased data-buffer size for world packing
when ENABLE_EXTENDED_EVENTBUFFER {
    WORLDWRITE_DATATYPE :: u32
} else {
    WORLDWRITE_DATATYPE :: u16
}

OFFSET_BEG :: i32(0x8000)
OFFSET_MID :: i32(0x0000)
OFFSET_END :: i32(0x7fff)

EventType :: enum u8 {
    WRITE_CREATE,
    WRITE_UPDATE,
    WRITE_REMOVE,
    READ_CREATE,
    READ_UPDATE,
    READ_REMOVE,
    ERROR_CREATE,
    ERROR_UPDATE,
    ERROR_REMOVE,
}

EventHandler :: #type proc(world: ^World, event: ^Event) -> (i32, []byte)

Visibility :: enum u8 {
    DEFAULT,
    NEVER,
    ALWAYS,
}

// Errors, statuses, warnings and information message codes
OK :: 0
FAIL :: proc(code: int) -> bool { return code < 0 }

WORLD_INVALID :: -1
OWNER_INVALID :: -2
CHUNK_INVALID :: -3
ENTITY_INVALID :: -4
ENTITY_FOREIGN :: -5
EVENT_INVALID :: -6

HANDLER_REPLACED :: -2
HANDLER_EMPTY :: -2
ENTITY_UNTRACKED :: -2
ENTITY_ALREADY_TRACKED :: -2
ENTITY_VISIBILITY_IGNORED :: -3

WRITE_REJECT :: -1
READ_INVALID :: -3
NULL_REFERENCE :: -7

// Enums
PackagingType :: enum u8 {
    WRITE_OWNER = u8(EventType.ERROR_REMOVE) + 1,
    READ_OWNER,
    ERROR_OWNER,
    PACKAGING_TOTAL,
}

// Structures
Entity :: struct {
    type: u8,                               
    visibility_global: u8,                  
    flag_owner_updated: bool,               
    flag_foreign: bool,                     
    flag_visbility_owner_enabled: bool,     
    flag_unused2: bool,                     

    ownership_token: u16,

    dimension: i32,
    owner_id: i64,

    chunks: [ENTITY_MAXCHUNKS]Chunk,
    owner_visibility_map: map[i64]i8,

    userdata: rawptr,
}

Event :: struct {
    type: u8,           // type of the event that was called, might be useful in bindings
    owner_id: i64,      // id of the owner who this event is called for
    entity_id: i64,     // id of an entity which this event is called about
    buffer: []byte,     // buffer data
    size: int,          // depending on the event type, can show maximum amount of data you are able to write, or amount of data you can read
    userdata: rawptr,   // userpointer that is passed from librg_world_write/librg_world_read fns
}

OwnerEntityPair :: struct {
    owner_id: i64,      // id of the owner who this event is called for
    entity_id: i64,     // id of an entity which this event is called about
}

World :: struct {
    valid: bool,
    allocator: mem.Allocator,
    random: runtime.Default_Random_State,

    worldsize: struct { x, y, z: u32 },
    chunksize: struct { x, y, z: u32 },
    chunkoffset: struct { x, y, z: i32 },

    handlers: [PackagingType.PACKAGING_TOTAL]EventHandler,
    entity_map: map[i64]Entity,
    owner_map: map[i64]map[i64]i64,

    dimensions: map[i64]map[i64]i64,

    /* 
        owner-entity pair, needed for more effective query
        achieved by caching only owned entities and reducing the first iteration cycle
    */
    owner_entity_pairs: [dynamic]OwnerEntityPair,

    userdata: rawptr,
}

// Type aliases
Chunk :: distinct i64

// Helper functions
librg_min :: proc(a, b: $T) -> T {
    return min(a, b)
}

librg_max :: proc(a, b: $T) -> T {
    return max(a, b)
}
