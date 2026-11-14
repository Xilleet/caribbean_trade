class_name WarSystem
extends RefCounted

## Stage A3 — wars and diplomacy. Tracks bilateral relations between states
## (stored on [member WorldState.state_relations]) and the player's reputation
## with each state + pirates ([member WorldState.player_rep]). Each week rolls
## for: relation/rep decay toward 0 (1 pt/week); diplomatic incidents (±10 to
## a random state pair); war declarations (when relation < -80, prob 0.3/week);
## peace treaties on existing wars (prob 0.2/week). Wars block port access for
## ships flying the enemy flag (see ShipsTick._can_dock); peace resets
## relations to -20.
##
## Determinism: a SEPARATE rng stream (WorldState.war_rng, seeded from
## world_seed + 4242) so the event_rng / pirate_rng streams stay bit-stable
## across this change.
##
## Money: wars move NO money directly. State treasuries still grow from customs
## tax (which scales with player_rep — see TradeSystem._collect_customs). The
## conservation invariant is untouched.

const WAR_THRESHOLD: float = -60.0        # below this, war can be declared
const PROB_WAR_DECLARATION: float = 0.4   # per week per eligible pair
const PROB_PEACE: float = 0.2             # per week per active war
const PROB_INCIDENT: float = 0.15        # per week per state pair
const INCIDENT_DELTA: float = 20.0       # was 10 — bigger swings push pairs past threshold faster
const PEACE_RELATION: float = -20.0      # relations reset here on peace
const DECAY_PER_WEEK: float = 0.3        # rep drifts toward 0
const HOSTILE_INCIDENT_PCT: float = 0.7   # 70% of incidents are negative

var rng: RandomNumberGenerator

# Counters for verification (headless report + tests).
var wars_declared: int = 0
var peaces_signed: int = 0
var incidents: int = 0


class ActiveWar:
        extends RefCounted
        var state_a: String
        var state_b: String
        var days_left: int = -1   # indefinite; peace comes via weekly roll, not countdown


func _init(p_rng: RandomNumberGenerator) -> void:
        rng = p_rng

# Called from SimulationEngine.step_week AFTER event_system.roll_weekly, so
# war declarations see the latest relations (which incidents may have just
# shifted). Order: decay -> incidents -> war declarations -> peace rolls.
func roll_weekly() -> void:
        _decay_relations()
        _decay_player_rep()
        _roll_incidents()
        _roll_war_declarations()
        _roll_peace()

func _decay_relations() -> void:
        for k in WorldState.state_relations.keys():
                var v: float = float(WorldState.state_relations[k])
                if v > 0.0:
                        v = max(0.0, v - DECAY_PER_WEEK)
                elif v < 0.0:
                        v = min(0.0, v + DECAY_PER_WEEK)
                WorldState.state_relations[k] = v

func _decay_player_rep() -> void:
        for k in WorldState.player_rep.keys():
                var v: float = float(WorldState.player_rep[k])
                if v > 0.0:
                        v = max(0.0, v - DECAY_PER_WEEK)
                elif v < 0.0:
                        v = min(0.0, v + DECAY_PER_WEEK)
                WorldState.player_rep[k] = v

func _roll_incidents() -> void:
        var pairs: Array = _all_state_pairs()
        for pair in pairs:
                if rng.randf() >= PROB_INCIDENT:
                        continue
                var delta: float = -INCIDENT_DELTA if rng.randf() < HOSTILE_INCIDENT_PCT else INCIDENT_DELTA
                var a: String = String(pair[0])
                var b: String = String(pair[1])
                WorldState.adjust_relation(a, b, delta)
                incidents += 1
                var sa: State = WorldState.get_state(a)
                var sb: State = WorldState.get_state(b)
                var an: String = sa.name if sa != null else a
                var bn: String = sb.name if sb != null else b
                var sign: String = "+" if delta > 0.0 else ""
                EventBus.message.emit("Дип. инцидент: %s ↔ %s (%s%.0f)" % [an, bn, sign, delta])

func _roll_war_declarations() -> void:
        var pairs: Array = _all_state_pairs()
        for pair in pairs:
                var a: String = String(pair[0])
                var b: String = String(pair[1])
                if WorldState.at_war(a, b):
                        continue
                if WorldState.get_relation(a, b) >= WAR_THRESHOLD:
                        continue
                if rng.randf() < PROB_WAR_DECLARATION:
                        _declare_war(a, b)

func _declare_war(a: String, b: String) -> void:
        var w := ActiveWar.new()
        w.state_a = a
        w.state_b = b
        w.days_left = -1
        WorldState.active_wars.append(w)
        wars_declared += 1
        var sa: State = WorldState.get_state(a)
        var sb: State = WorldState.get_state(b)
        var an: String = sa.name if sa != null else a
        var bn: String = sb.name if sb != null else b
        EventBus.message.emit("⚔ Война: %s объявила войну %s" % [an, bn])

func _roll_peace() -> void:
        var still: Array = []
        for w in WorldState.active_wars:
                if rng.randf() < PROB_PEACE:
                        _make_peace(w)
                else:
                        still.append(w)
        WorldState.active_wars = still

func _make_peace(w) -> void:
        WorldState.set_relation(w.state_a, w.state_b, PEACE_RELATION)
        peaces_signed += 1
        var sa: State = WorldState.get_state(w.state_a)
        var sb: State = WorldState.get_state(w.state_b)
        var an: String = sa.name if sa != null else w.state_a
        var bn: String = sb.name if sb != null else w.state_b
        EventBus.message.emit("✌ Мир: %s и %s подписали мирный договор" % [an, bn])

# All C(N,2) state pairs, deterministic order (states array order).
func _all_state_pairs() -> Array:
        var pairs: Array = []
        var arr: Array = WorldState.states
        for i in arr.size():
                for j in range(i + 1, arr.size()):
                        pairs.append([arr[i].id, arr[j].id])
        return pairs
