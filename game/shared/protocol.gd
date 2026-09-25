class_name Protocol
extends RefCounted
## Constants shared by client and server. Bump PROTOCOL_VERSION on any
## change to RPC signatures or the binary snapshot/input layout.

const PROTOCOL_VERSION := 2
const CLIENT_BUILD := "0.2.0-alpha"
const DEFAULT_PORT := 7000
const DEFAULT_ZONE := "tr_istanbul_kadikoy_001"
const MAX_PEERS := 64

# ENet channels: movement never waits behind chat or social traffic.
const CHANNEL_MOVEMENT := 0
const CHANNEL_SOCIAL := 1

const TICK_RATE := 30
const DT := 1.0 / TICK_RATE
const SNAPSHOT_EVERY_TICKS := 2  # 15 Hz
const MAX_RESENT_INPUTS := 16  # each input packet repeats every unacknowledged input, up to this many
const MAX_GAP_FILL := 16  # inputs the server reconstructs if some never arrive
const HELLO_TIMEOUT := 10.0

# Interest management: which remote players a client hears about, and how often.
const INTEREST_CELL := 64.0
const INTEREST_NEAR := 50.0
const INTEREST_MID := 120.0
const INTEREST_FAR := 300.0
const INTEREST_HYSTERESIS := 20.0
const MID_EVERY := 3
const FAR_EVERY := 8

# Social rules.
const INTERACTION_RANGE := 4.0
const INTERACTION_RANGE_TOLERANCE := 1.0  # latency slack on the server check
const EMOTE_RANGE := 20.0
const CONVERSATION_RANGE := 30.0
const REQUEST_TIMEOUT := 20.0
const SAME_TARGET_COOLDOWN := 5.0
const REPEATED_REFUSAL_LIMIT := 3
const REPEATED_REFUSAL_COOLDOWN := 60.0
const MAX_INCOMING_REQUESTS := 3
const CHAT_MAX_LEN := 200
const CHAT_BURST := 5
const CHAT_REFILL_PER_SEC := 1.0
const EMOTE_COOLDOWN := 1.0
const EMOTES := ["wave", "nod"]
const REQUEST_KINDS := ["talk"]
const REPORT_REASONS := ["harassment", "hate", "spam", "impersonation", "other"]

# Movement. Identical on both sides so client prediction matches the server.
# A brisk real walk and a run: the city should feel its size, and trams
# should be worth taking.
const WALK_SPEED := 2.4
const SPRINT_SPEED := 5.2
const JUMP_VELOCITY := 4.6
const GRAVITY := 15.0
const GROUND_ACCEL := 40.0
const AIR_ACCEL := 8.0

const BOARD_RADIUS := 8.0
const POPULATION_CELL := 64.0
const POPULATION_EVERY_TICKS := 90  # 3 s

const LAYER_WORLD := 1
const LAYER_PLAYERS := 2
