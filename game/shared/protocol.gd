class_name Protocol
extends RefCounted
## Constants shared by client and server. Bump PROTOCOL_VERSION on any
## change to RPC signatures or the binary snapshot/input layout.

const PROTOCOL_VERSION := 7
const CLIENT_BUILD := "0.3.0-alpha"
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
const EMOTES := ["wave", "nod", "dance"]
## Benches: how close you must be to sit down, and two seats per bench.
const SIT_RANGE := 2.2
const BENCH_SEATS := [-0.45, 0.45]
## Every request kind goes through the same consent flow: "talk" opens a
## conversation, "group" invites into your group, "rps" and "slap" challenge
## to a minigame, "hide" asks to play hide-and-seek (the server starts it only
## after an accept).
const REQUEST_KINDS := ["talk", "group", "rps", "slap", "hide"]
## Groups: at most ten live at once, one colour each (no two share one).
const GROUP_MAX_MEMBERS := 8
const GROUP_NAME_MAX := 16
const GROUP_COLORS := [Color("e6194b"), Color("4363d8"), Color("3cb44b"), Color("ffe119"), Color("f58231"),
	Color("911eb4"), Color("42d4f4"), Color("f032e6"), Color("9a6324"), Color("bfef45")]
const GROUP_COLOR_NAMES := ["Kırmızı", "Mavi", "Yeşil", "Sarı", "Turuncu", "Mor", "Turkuaz", "Pembe", "Kahverengi", "Limon"]
## Minigames between two people: a match is cancelled when they drift apart.
const GAME_KINDS := ["rps", "slap"]
const GAME_RANGE := 8.0
const GAME_INTRO := 1.2
const GAME_REVEAL := 2.4
## Taş-kâğıt-makas (0 rock, 1 paper, 2 scissors): best of three, the fists
## shake for three beats, then a short window to lock in a choice.
const RPS_WINS := 2
const RPS_MAX_ROUNDS := 6  # draws replay the round, up to this many
const RPS_COUNT_STEP := 0.8
const RPS_PICK_TIME := 2.0
## El kızartmaca: one is on top, one has palms up. At the cue the top slaps
## and the bottom pulls away; whoever reacts faster wins the round (the top
## wins ties within SLAP_TIE). Five rounds, roles swap every round.
const SLAP_WINS := 3
const SLAP_ROUNDS := 5
const SLAP_READY := 1.0
const SLAP_DELAY_MIN := 1.5
const SLAP_DELAY_MAX := 4.0
const SLAP_WINDOW := 1.2  # seconds after the cue in which a press counts
const SLAP_MIN_REACTION := 0.08  # faster than this (latency removed) is a guess
const SLAP_TIE := 0.03
const SLAP_MAX_RTT := 0.5  # latency credit is capped, so lag cannot be faked
## Saklambaç (hide-and-seek): the seeker, who asked for the game, counts with
## eyes covered while the hiders run off; then the hunt starts. The server
## decides "found" by distance AND an unobstructed line (a raycast against the
## world), and a hider that taps E at the base before that is "kurtuldu".
const HIDE_COUNT := 15.0
const HIDE_HUNT_TIME := 120.0
const HIDE_FIND_RADIUS := 4.0
const HIDE_FIND_HEIGHT := 3.0  # vertical slack: no finding someone on a roof
const HIDE_BASE_RADIUS := 3.0  # how close to the base a hider must be to tap in
const HIDE_JOIN_RANGE := 30.0  # group mates this close are drawn into the round
const HIDE_AREA := 150.0  # leave this far from the base and you are out of the round
const HIDE_LANDMARK_RANGE := 150.0  # the seeker counts facing the nearest named place within this
## Seksek (hopscotch): chalk grids at fixed spots (Hopscotch); a turn hops
## square to square, the server judges every landing.
const SEKSEK_IDLE_TIMEOUT := 8.0
const SEKSEK_MAX_TIME := 60.0
## Server-sent poses for the minigames (players cannot trigger these).
const GAME_EMOTES := ["shake", "rock", "paper", "scissors", "slap", "dodge"]
const REPORT_REASONS := ["harassment", "hate", "spam", "impersonation", "other"]

# Movement. Identical on both sides so client prediction matches the server.
# A brisk real walk and a run: the city should feel its size, and trams
# should be worth taking.
const WALK_SPEED := 2.4
const SPRINT_SPEED := 5.2
const JUMP_VELOCITY := 4.6
## Hop-walk ("sekerek yürüme"): one-legged hopping, slow and no sprint. Part
## of the shared motor so prediction matches the server.
const HOP_SPEED := 1.5
const GRAVITY := 15.0
const GROUND_ACCEL := 40.0
const AIR_ACCEL := 8.0

const BOARD_RADIUS := 8.0
const POPULATION_CELL := 64.0
const POPULATION_EVERY_TICKS := 90  # 3 s

const LAYER_WORLD := 1
const LAYER_PLAYERS := 2
const LAYER_PROPS := 4  # server-simulated loose objects
const LAYER_TRAMS := 8  # kinematic tram bodies that push props (server only)
