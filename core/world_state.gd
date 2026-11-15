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
var states: Array[State] = []        # Stage A2: colonial powers Spain/England/France/Netherlands
var pirates_db: Dictionary = {}      # Stage A1: pirate_attack params + haven towns
var pirate_rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Stage A1: separate rng stream for pirate rolls (per-sailing-day) so the
# drought/storm/famine event_rng stream stays bit-stable.
var state_relations: Dictionary = {}   # Stage A3: "spain:england" -> float in [-100,+100]
var player_rep: Dictionary = {}         # Stage A3: state_id or "pirates" -> float in [-100,+100]
var active_wars: Array = []             # Stage A3: WarSystem.ActiveWar instances (untyped)
var war_rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Stage A3: separate rng stream for war rolls (declarations, peace, incidents)
# so the event_rng / pirate_rng streams stay bit-stable across this change.

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
	pirate_rng.seed = world_seed + 91137     # Stage A1: yet another stream
	war_rng.seed = world_seed + 4242       # Stage A3: war rolls stream

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
	states.clear()                  # Stage A2
	pirates_db.clear()              # Stage A1
	active_events.clear()
	rng.seed = world_seed
	event_rng.seed = world_seed + 12579023
	pirate_rng.seed = world_seed + 91137   # Stage A1
	state_relations.clear()             # Stage A3
	player_rep.clear()                  # Stage A3
	active_wars.clear()                 # Stage A3
	war_rng.seed = world_seed + 4242    # Stage A3
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
	pirates_db = _load_json("res://data/pirates.json")   # Stage A1
	# Stage A3: load bilateral state relations (historical ~1600).
	# Keys in JSON may be in any order; _pair_key normalises to sorted
	# alphabetical so "spain:england" and "england:spain" map to the same entry.
	var rel_data: Dictionary = _load_json("res://data/relations.json")
	for raw_key in rel_data.keys():
		var parts: PackedStringArray = String(raw_key).split(":")
		if parts.size() == 2:
			state_relations[_pair_key(parts[0], parts[1])] = float(rel_data[raw_key])
	# Stage A2: spawn colonial-power State objects. Each gets a starting treasury
	# and a tax_rate (customs duty on ship trades). Treasury grows as trades flow
	# through the state's ports; total_money() includes it so conservation holds.
	var states_data: Dictionary = _load_json("res://data/states.json")
	for sid in states_data.keys():
		var sd: Dictionary = states_data[sid]
		var st := State.new(String(sid), String(sd["name"]), float(sd["starting_treasury"]), float(sd["tax_rate"]))
		states.append(st)
	# Stage A3: init player_rep to 0 for every state + pirates.
	for s in states:
		player_rep[s.id] = 0.0
	player_rep["pirates"] = 0.0
	var towns_data: Dictionary = _load_json("res://data/towns.json")

	for town_id in towns_data.keys():
		var td: Dictionary = towns_data[town_id]
		var t := Town.new(town_id, td["name"])
		t.coords = Vector2(float(td["coords"][0]), float(td["coords"][1]))
		var pop: Dictionary = td["population"]
		var poor_total: float = float(pop["poor"])
		var middle_total: float = float(pop["middle"])
		var rich_total: float = float(pop["rich"])
		t.state_id = String(td.get("state", ""))   # Stage A2: colonial ownership
		# Stage B1 (combined): create 10 Pop groups per town — 3 poor,
		# 4 middle, 3 rich — with profession labels. Initial counts
		# distributed by ratio (laborer 60% of poor, artisan 40% of
		# middle, planter 50% of rich, etc.). B2 will use professions
		# for labour market hiring; B1 just sets the data model.
		# Money-neutral: Pop.count is NOT in total_money().
		var ti: int = towns.size()
		# Poor stratum: laborer 40%, sailor 30%, servant 30%
		# (B2.1: was 60/20/20 — caused 86-98% laborer unemployment
		# because too many laborers vs available farm/plantation jobs)
		t.pops.append(Pop.new("%s_pop_laborer" % town_id, town_id, "poor", "laborer", poor_total * 0.40))
		t.pops.append(Pop.new("%s_pop_sailor" % town_id, town_id, "poor", "sailor", poor_total * 0.30))
		t.pops.append(Pop.new("%s_pop_servant" % town_id, town_id, "poor", "servant", poor_total * 0.30))
		# Middle stratum: artisan 40%, smith 15%, merchant 25%, small_planter 20%
		t.pops.append(Pop.new("%s_pop_artisan" % town_id, town_id, "middle", "artisan", middle_total * 0.40))
		t.pops.append(Pop.new("%s_pop_smith" % town_id, town_id, "middle", "smith", middle_total * 0.15))
		t.pops.append(Pop.new("%s_pop_merchant" % town_id, town_id, "middle", "merchant", middle_total * 0.25))
		t.pops.append(Pop.new("%s_pop_small_planter" % town_id, town_id, "middle", "small_planter", middle_total * 0.20))
		# Rich stratum: planter 50%, official 30%, financier 20%
		t.pops.append(Pop.new("%s_pop_planter" % town_id, town_id, "rich", "planter", rich_total * 0.50))
		t.pops.append(Pop.new("%s_pop_official" % town_id, town_id, "rich", "official", rich_total * 0.30))
		t.pops.append(Pop.new("%s_pop_financier" % town_id, town_id, "rich", "financier", rich_total * 0.20))
		# Seeded per-Pop population perturbation — this is what makes
		# world_seed actually change the run. Each Pop gets its own phase
		# (prof_idx) so different professions perturb independently.
		# Money-neutral: population counts are NOT in total_money().
		# A plain sin() formula (not the RNG) so the Python reference
		# (econ_ref.py) reproduces it bit-for-bit with the same seed.
		var prof_idx: int = 0
		for p in t.pops:
			p.count *= 1.0 + 0.20 * sin(float(world_seed) + float(ti) * 7.0 + float(prof_idx))
			prof_idx += 1
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
			# Stage C1 (minimal): default_owner from template — currently
			# always "town" (stub for future C2/C8 where templates may
			# specify "player", "ai:<co_id>", "state:<sid>", or
			# "entrepreneur:<id>"). "town" is resolved to "town:<town_id>"
			# at instantiation; other values are passed through as-is.
			var default_owner_type: String = String(tmpl.get("default_owner", "town"))
			var owner_id: String = "town:" + town_id if default_owner_type == "town" else default_owner_type
			var ind := Industry.new(
				"%s_%s_%d" % [town_id, ind_type, i],
				tmpl["recipe_id"], town_id,
				float(tmpl["default_workers"]), float(tmpl["default_money"]),
				owner_id)
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
	ship.flag_state = "england"   # Stage A3: player flies English colours (Port Royal heritage)
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
		ai_ship.flag_state = home_t.state_id if home_t != null else ""   # Stage A3: AI flies home-port colours
		ai_co.ship_ids.append(aship_id)
		ships.append(ai_ship)
		companies.append(ai_co)

	# Give every company a price memory seeded with day-0 prices for
	# every port (the "starting rumour" — captains begin with common knowledge
	# of Caribbean prices that ages out as the world moves under them). Refreshed
	# on dock by ShipsTick; AI ships read it via AIBrain, the player reads it in
	# the planning view (_render_town). Both plan from the same stale-info model
	# rather than omniscient live prices.
	for c in companies:
		c.memory = PriceMemory.new()
		for t in towns:
			c.memory.snapshot(t, 0)

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

# Stage A2: lookup a colonial power by id (e.g. "spain").
func get_state(id: String) -> State:
	if id == "":
		return null
	for s in states:
		if s.id == id:
			return s
	return null

# Stage A3: bilateral state relations. Pair key is sorted so "spain:england"
# and "england:spain" map to the same entry.
func _pair_key(a: String, b: String) -> String:
	return a + ":" + b if a < b else b + ":" + a

func get_relation(a: String, b: String) -> float:
	return float(state_relations.get(_pair_key(a, b), 0.0))

func set_relation(a: String, b: String, val: float) -> void:
	state_relations[_pair_key(a, b)] = clamp(val, -100.0, 100.0)

func adjust_relation(a: String, b: String, delta: float) -> void:
	set_relation(a, b, get_relation(a, b) + delta)

# Stage A3: player reputation with a state or with "pirates".
func get_player_rep(actor_id: String) -> float:
	return float(player_rep.get(actor_id, 0.0))

func adjust_player_rep(actor_id: String, delta: float) -> void:
	var v: float = get_player_rep(actor_id) + delta
	player_rep[actor_id] = clamp(v, -100.0, 100.0)

# Stage A3: is there an active war between two states?
func at_war(a: String, b: String) -> bool:
	if a == "" or b == "" or a == b:
		return false
	for w in active_wars:
		if (w.state_a == a and w.state_b == b) or (w.state_a == b and w.state_b == a):
			return true
	return false

# is this state in ANY active war? Used by TradeSystem._collect_customs
# for the war tariff (a foreign trader in a wartime port pays double customs).
# Bilateral at_war above answers a specific pair; this answers "is the port's
# state at war at all". Same active_wars list, no rng, no money.
func state_at_war(id: String) -> bool:
	if id == "":
		return false
	for w in active_wars:
		if w.state_a == id or w.state_b == id:
			return true
	return false

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
	# Stage A2: state treasuries hold customs tax collected on ship trades.
	for st in states:
		s += st.treasury
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
