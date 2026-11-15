class_name EventSystem
extends RefCounted

## Stage 6 — world events (concept §3.4). Adds timed MODIFIERS (drought, storm,
## famine) that the existing systems consult via the WorldState query methods
## (drought_multiplier / storm_multiplier / storm_extra_upkeep /
## famine_demand_multiplier). The economic core never branches on events
## directly — it just reads a multiplier, so the conservation invariant and the
## fixed tick order are untouched.
##
## Money is never created or destroyed by an event:
##   drought  -> cuts crop output (less supply -> prices rise); no money moved.
##   storm    -> slows the ship AND adds upkeep (damage repairs) paid to the
##               local town: company.money -> town.population_money.
##   famine   -> raises population demand for a staple (panic): more
##               population_money -> market.fund via the buy. Fires only when a
##               food good's stock is already below 0.2 * target — i.e. it is a
##               CONSEQUENCE of the simulation, not pure RNG (concept §3.4:
##               "значительная часть событий — следствие самой симуляции").
##
## Determinism: a SEPARATE rng stream (WorldState.event_rng, seeded from
## world_seed) so event rolls never perturb the population rng, and the same
## seed reproduces the same event sequence bit-for-bit. Famine has no roll — it
## is purely state-driven, so it is deterministic by construction.

var rng: RandomNumberGenerator
var db: Dictionary = {}

# Counters for verification (headless report + tests). Not economic state.
var fired_total: int = 0
var fired_by_type: Dictionary = {}   # type -> count


class ActiveEvent:
	extends RefCounted
	var type: String            # drought | storm | famine
	var scope: String           # town | ship | town_good
	var target_id: String       # town_id (drought/famine) or ship_id (storm)
	var good_id: String = ""    # only for town_good (famine)
	var days_left: int = 0
	var magnitude: float = 1.0
	var extra_upkeep_mult: float = 0.0


func _init(p_rng: RandomNumberGenerator, p_db: Dictionary) -> void:
	rng = p_rng
	db = p_db

# Roll new events once per week. Probabilistic types (drought/storm) use the
# seeded rng; famine is state-triggered (no roll). Called from step_week AFTER
# the weekly population/finance ticks, so a famine sees this week's stock.
func roll_weekly() -> void:
	var ddef: Dictionary = db.get("drought", {})
	for t in WorldState.towns:
		if _roll(float(ddef.get("prob_per_week", 0.0))):
			_add("drought", "town", t.id, "", ddef)
	var sdef: Dictionary = db.get("storm", {})
	for s in WorldState.ships:
		if _roll(float(sdef.get("prob_per_week", 0.0))):
			_add("storm", "ship", s.id, "", sdef)
	# Famine: state-triggered. A staple below the trigger ratio in a populated
	# town ignites a famine on that good (one per good per town — no stacking).
	var fdef: Dictionary = db.get("famine", {})
	var trigger_goods: Array = fdef.get("trigger_goods", [])
	var ratio: float = float(fdef.get("trigger_stock_ratio", 0.0))
	for t in WorldState.towns:
		if t.total_population() <= 0.0:
			continue
		for g in trigger_goods:
			var gid: String = String(g)
			if not t.market.has_good(gid):
				continue
			if _has_active("famine", t.id, gid):
				continue
			var e: Market.Entry = t.market.get_entry(gid)
			var target: float = max(e.target_stock, 1.0)
			if e.stock < ratio * target:
				_add("famine", "town_good", t.id, gid, fdef)

# Tick down every active event once per day; expire and log the ones that end.
# Called at the END of step_day (after ships_tick), so today's ticks always see
# the full duration and an event added this week is active for the next day.
func decay_daily() -> void:
	var still: Array = []
	for ev in WorldState.active_events:
		ev.days_left -= 1
		if ev.days_left <= 0:
			_emit_end(ev)
		else:
			still.append(ev)
	WorldState.active_events = still


func _add(type: String, scope: String, target_id: String, good_id: String, def: Dictionary) -> void:
	var ev := ActiveEvent.new()
	ev.type = type
	ev.scope = scope
	ev.target_id = target_id
	ev.good_id = good_id
	ev.days_left = _rand_int(int(def.get("min_days", 1)), int(def.get("max_days", 1)))
	ev.magnitude = float(def.get("magnitude", 1.0))
	ev.extra_upkeep_mult = float(def.get("extra_upkeep_mult", 0.0))
	WorldState.active_events.append(ev)
	fired_total += 1
	fired_by_type[type] = int(fired_by_type.get(type, 0)) + 1
	_emit_start(ev)

func _roll(prob: float) -> bool:
	return prob > 0.0 and rng.randf() < prob

func _rand_int(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	return lo + rng.randi() % (hi - lo + 1)

func _has_active(type: String, target_id: String, good_id: String) -> bool:
	for ev in WorldState.active_events:
		if ev.type == type and ev.target_id == target_id and ev.good_id == good_id:
			return true
	return false

func _emit_start(ev) -> void:
	var tname: String = _target_name(ev)
	match ev.type:
		"drought": EventBus.message.emit("Засуха в %s — %d дн., урожай x%.1f" % [tname, ev.days_left, ev.magnitude])
		"storm":   EventBus.message.emit("Шторм бьет по %s — %d дн., скорость x%.1f" % [tname, ev.days_left, ev.magnitude])
		"famine":  EventBus.message.emit("Голод в %s: %s в дефиците — %d дн., спрос x%.1f" % [tname, _good_name(ev.good_id), ev.days_left, ev.magnitude])
		_:         EventBus.message.emit("%s в %s — %d дн." % [ev.type, tname, ev.days_left])

func _emit_end(ev) -> void:
	var def: Dictionary = db.get(ev.type, {})
	var label: String = String(def.get("name", ev.type))
	EventBus.message.emit("%s в %s закончился" % [label, _target_name(ev)])

func _target_name(ev) -> String:
	if ev.scope == "ship":
		return ev.target_id
	var t: Town = WorldState.get_town(ev.target_id)
	return t.name if t != null else ev.target_id

func _good_name(good_id: String) -> String:
	if WorldState.goods.has(good_id):
		return String(WorldState.goods[good_id]["name"])
	return good_id
