extends Node

## Single source of truth for the whole simulation. Built once from JSON in
## [method build_world]; [SimulationEngine] and the UI read from here. The
## economy never holds duplicate copies of stock — only [Market.Entry.stock]
## is authoritative.

var towns: Array[Town] = []
var companies: Array[Company] = []
var ships: Array[Ship] = []            # all ships in the world
var routes: Dictionary = {}            # route_id -> TradeRoute
var goods: Dictionary = {}           # good_id -> def
var recipes: Dictionary = {}         # recipe_id -> recipe
var industries_db: Dictionary = {}   # template id -> template
var ships_db: Dictionary = {}        # ship type -> def
var events_db: Dictionary = {}       # event type -> def (Stage 6)

var rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Stage 6: a SEPARATE rng stream for event rolls, so events never perturb the
# population rng and the same seed reproduces the same event sequence.
var event_rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Active timed modifiers (EventSystem.ActiveEvent). Untyped Array because the
# element type is an inner class (finicky to annotate); accessed by name.
var active_events: Array = []
var world_seed: int = 1337
var built: bool = false

func _ready() -> void:
	rng.seed = world_seed
	event_rng.seed = world_seed + 12579023   # distinct deterministic stream

func reset() -> void:
	towns.clear()
	companies.clear()
	ships.clear()
	routes.clear()
	goods.clear()
	recipes.clear()
	industries_db.clear()
	ships_db.clear()
	events_db.clear()
	active_events.clear()
	rng.seed = world_seed
	event_rng.seed = world_seed + 12579023
	# A fresh build must start on day 0 too — otherwise a second build_world in
	# the same process (tests, or a new-game button later) leaves the week
	# boundary misaligned with economy age, and state-triggered events (famine)
	# fire on a different phase. SimulationClock is a separate autoload.
	SimulationClock.reset()
	built = false

func build_world() -> void:
	reset()
	goods = _load_json("res://data/goods.json")
	recipes = _load_json("res://data/recipes.json")
	industries_db = _load_json("res://data/industries.json")
	ships_db = _load_json("res://data/ships.json")
	events_db = _load_json("res://data/events.json")
	var towns_data: Dictionary = _load_json("res://data/towns.json")

	for town_id in towns_data.keys():
		var td: Dictionary = towns_data[town_id]
		var t := Town.new(town_id, td["name"])
		t.coords = Vector2(float(td["coords"][0]), float(td["coords"][1]))
		var pop: Dictionary = td["population"]
		t.poor = float(pop["poor"])
		t.middle = float(pop["middle"])
		t.rich = float(pop["rich"])
		# Seeded per-class population perturbation — this is what makes
		# world_seed actually change the run. Money-neutral: population counts
		# are NOT in total_money(), so the conservation invariant still holds.
		# A plain sin() formula (not the RNG) so the Python reference
		# (econ_ref.py) reproduces it bit-for-bit with the same seed.
		var ti: int = towns.size()
		t.poor   *= 1.0 + 0.20 * sin(float(world_seed) + float(ti) * 7.0 + 0.0)
		t.middle *= 1.0 + 0.20 * sin(float(world_seed) + float(ti) * 7.0 + 3.0)
		t.rich   *= 1.0 + 0.20 * sin(float(world_seed) + float(ti) * 7.0 + 6.0)
		t.population_money = float(td["population_money"])

		# Every town gets a market entry for every good (price exists everywhere,
		# stock defaults to 0 unless initial_stock overrides it).
		var init: Dictionary = td.get("initial_stock", {})
		for good_id in goods.keys():
			var gd: Dictionary = goods[good_id]
			var init_stock: float = float(init.get(good_id, 0.0))
			t.market.add_good(good_id, float(gd["base_price"]), float(gd["min_price"]), float(gd["max_price"]), init_stock)

		# Industries: instantiate from templates.
		var inds: Array = td["industries"]
		for i in range(inds.size()):
			var ind_type: String = inds[i]
			var tmpl: Dictionary = industries_db[ind_type]
			var ind := Industry.new(
				"%s_%s_%d" % [town_id, ind_type, i],
				tmpl["recipe_id"], town_id,
				float(tmpl["default_workers"]), float(tmpl["default_money"]))
			t.industries.append(ind)

		towns.append(t)

	# Trade routes (data-driven).
	var routes_data: Dictionary = _load_json("res://data/routes.json")
	for rid in routes_data.keys():
		var rd: Dictionary = routes_data[rid]
		var route := TradeRoute.new(rid, String(rd.get("ship_id", "")))
		var stops_arr: Array = rd["stops"]
		for s in stops_arr:
			route.stops.append(String(s))
		var rules_data: Dictionary = rd.get("rules", {})
		for town_id in rules_data.keys():
			var stop_rules: Array = []
			var rarr: Array = rules_data[town_id]
			for rdef in rarr:
				var rdict: Dictionary = rdef
				var r := TradeRoute.StopRule.new()
				r.good_id = String(rdict["good"])
				r.action = String(rdict["action"])
				r.threshold = float(rdict["threshold"])
				r.max_qty = float(rdict["max_qty"])
				r.price_limit = float(rdict.get("price_limit", 0.0))
				r.priority = int(rdict.get("priority", 0))
				stop_rules.append(r)
			route.rules[town_id] = stop_rules
		routes[rid] = route

	# Player company + a starting brigantine on the default route, docked at
	# Tortuga so it trades on day 1.
	var player := Company.new("player", "Player Trading Co.", 5000.0, false)
	var sd: Dictionary = ships_db["brigantine"]
	var ship := Ship.new("ship_1", player.id, "brigantine",
			float(sd["speed"]), float(sd["cargo_capacity"]), float(sd["upkeep_daily"]))
	var home: Town = get_town("tortuga")
	if home != null:
		ship.pos = home.coords
	ship.current_town_id = "tortuga"
	ship.state = "docked"
	ship.route_id = "player_default"
	player.ship_ids.append("ship_1")
	ships.append(ship)
	companies.append(player)

	# AI trading companies — each gets one ship on its own route with
	# auto_trade ON, so they move and trade through the SAME MarketSystem /
	# TradeSystem as the player. Money flows company <-> market.fund, so the
	# conservation invariant still holds (total_money sums every company).
	# Spawned AFTER the player so ships[0] stays the player ship (older tests and
	# the headless trajectory rely on that) — get_player_ship() is the robust way.
	var ai_data: Dictionary = _load_json("res://data/ai_companies.json")
	for cid in ai_data.keys():
		var ad: Dictionary = ai_data[cid]
		var stype: String = String(ad.get("ship_type", "sloop"))
		var asd: Dictionary = ships_db[stype]
		var ai_co := Company.new(String(cid), String(ad["name"]), float(ad["money"]), true)
		var aship_id := "ship_%s" % String(cid)
		var ai_ship := Ship.new(aship_id, ai_co.id, stype,
				float(asd["speed"]), float(asd["cargo_capacity"]), float(asd["upkeep_daily"]))
		ai_ship.route_id = String(ad["route_id"])
		ai_ship.auto_trade = true
		var home_id: String = String(ad.get("home", ""))
		var home_t: Town = get_town(home_id)
		if home_t != null:
			ai_ship.pos = home_t.coords
		ai_ship.current_town_id = home_id
		ai_ship.state = "docked"
		ai_co.ship_ids.append(aship_id)
		ships.append(ai_ship)
		companies.append(ai_co)

	built = true

func get_town(id: String) -> Town:
	for t in towns:
		if t.id == id:
			return t
	return null

func get_route(id: String) -> TradeRoute:
	if routes.has(id):
		return routes[id]
	return null

func get_company(id: String) -> Company:
	for c in companies:
		if c.id == id:
			return c
	return null

func get_ship(id: String) -> Ship:
	for s in ships:
		if s.id == id:
			return s
	return null

# The player's ship — the one owned by the "player" company. Falls back to
# ships[0] only if no player-owned ship exists (defensive; build_world always
# creates one). Use this instead of indexing ships[0] directly so AI ships
# appended after the player never shift the index.
func get_player_ship() -> Ship:
	for s in ships:
		if s.owner_id == "player":
			return s
	return ships[0] if not ships.is_empty() else null

# --- Stage 6 event modifiers (consulted by ProductionSystem / ShipsTick /
# ConsumptionSystem). Each returns 1.0 (no effect) by default, or the combined
# magnitude of matching active events. Multiplicative so stacked events
# compound; in practice they rarely stack on the same target.

# Drought magnitude on a town's crop harvest (1.0 = no drought).
func drought_multiplier(town_id: String) -> float:
	var m: float = 1.0
	for ev in active_events:
		if ev.type == "drought" and ev.target_id == town_id:
			m *= ev.magnitude
	return m

# Storm speed multiplier on a ship (1.0 = clear weather).
func storm_multiplier(ship_id: String) -> float:
	var m: float = 1.0
	for ev in active_events:
		if ev.type == "storm" and ev.target_id == ship_id:
			m *= ev.magnitude
	return m

# Extra upkeep a ship pays today for storm damage (summed over active storms),
# routed to the local town as repair work. 0.0 in clear weather.
func storm_extra_upkeep(ship: Ship) -> float:
	var extra: float = 0.0
	for ev in active_events:
		if ev.type == "storm" and ev.target_id == ship.id:
			extra += ev.extra_upkeep_mult * ship.upkeep_daily
	return extra

# Famine demand multiplier on a (town, good) staple (1.0 = no famine).
func famine_demand_multiplier(town_id: String, good_id: String) -> float:
	var m: float = 1.0
	for ev in active_events:
		if ev.type == "famine" and ev.target_id == town_id and ev.good_id == good_id:
			m *= ev.magnitude
	return m

func total_money() -> float:
	# Conservation check: sum of EVERY money account in the world — towns
	# (population, market fund, treasury, industries) AND companies. Ships hold
	# cargo (goods), not money, so they are not summed here. With no external
	# trade in Stage 1/2 this total is constant.
	var s: float = 0.0
	for t in towns:
		s += t.population_money
		s += t.market.fund
		s += t.treasury
		for ind in t.industries:
			s += ind.money
	for c in companies:
		s += c.money
	return s

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[WorldState] cannot open %s" % path)
		return {}
	var text := f.get_as_text()
	f.close()
	var r: Variant = JSON.parse_string(text)
	if typeof(r) != TYPE_DICTIONARY:
		push_error("[WorldState] invalid JSON in %s" % path)
		return {}
	return r
