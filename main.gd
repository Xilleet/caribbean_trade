extends Node

## Entry point.
##
## Windowed: launches the Stage UI-1 scene-based UI (ui/game_ui.tscn, declared
## as a child of Main in main.tscn) and runs a continuous, player-speed-
## controlled simulation — no hard 365-day stop. Headless: runs the 365-day
## Stage 1+2 verification and writes the CSV/summary report to
## user://sim_output/ (the same path the tests and the README point at).
##
## Speed (windowed): Pause / 1× / 2× / 3× (days per second = 0 / 4 / 16 / 60).
## Keys: ESC quit · Space pause/resume · 1 2 3 set speed.
##
## The UI reads state only from WorldState / SimulationClock and listens to
## EventBus; this controller owns the engine and the tick cadence and nothing
## else. Press ESC to quit.
##
## Stage UI-1: the world is built in _enter_tree (not _ready) so the GameUI
## sub-scene — instantiated as a child of Main — sees a populated WorldState
## when its own _ready fires (children's _ready runs before the parent's).

const SIM_DAYS_HEADLESS: int = 365
const CSV_SAMPLE_EVERY: int = 7
const OUT_DIR: String = "user://sim_output/"
const DAYS_PER_FRAME_HEADLESS: int = 8
# index = speed tier; value = days simulated per real second (0 = paused).
const SPEED_DPS: Array[int] = [0, 4, 16, 60]
# diplomacy costs / thresholds. These mirror the disable conditions
# computed in ui/game_ui.gd::_rebuild_diplo_panel — keep the two in sync if you
# retune. Bribes scale with how hostile the state is; citizenship is a flat fee.
const BRIBE_BASE_COST: float = 500.0
const BRIBE_REP_GAIN: float = 10.0
const BRIBE_COOLDOWN_WEEKS: int = 4
const CITIZENSHIP_COST: float = 5000.0
const CITIZENSHIP_REP_THRESHOLD: float = 50.0

var _engine: SimulationEngine = null
var _headless: bool = false
var _speed: int = 1            # 0 paused, 1..3
var _acc: float = 0.0
var _ui: Control = null    # Stage UI-1: now a child node of the main scene (was add_child'd in code)

# --- headless verification state (windowed mode ignores these) ---
var _day: int = 0
var _snapshots: Array[Dictionary] = []
var _pop_snapshots: Array[Dictionary] = []   # Stage B1.5: weekly Pop state per town per profession
var _company_traj: Array[Dictionary] = []
var _money_start: float = 0.0
var _company_start: float = 0.0
var _ai_starts: Dictionary = {}   # ai company id -> money at day 0 (for P/L)
var _done: bool = false

# Stage UI-1: build the world in _enter_tree (before any child's _ready runs)
# so the GameUI sub-scene — instantiated as a child of Main in main.tscn — sees
# a populated WorldState when its own _ready fires. _ready runs bottom-up
# (children before parent); _enter_tree runs top-down. Putting build_world()
# here keeps the old invariant "world built before UI subscribes" without
# deferring UI init or splitting _ready across frames. The engine is created
# here too so a deferred day_advanced (if any signal were ever emitted during
# build) would find it non-null — though build_world itself emits nothing.
func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	WorldState.build_world()
	_engine = SimulationEngine.new()

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_headless = DisplayServer.get_name() == "headless"
	if _headless:
		_init_headless()
	else:
		# Stage 4: the player directly captains the starting ship — no auto-trade,
		# no auto-depart. Docking auto-pauses so they can trade and plan the next
		# leg. Start paused, docked at Tortuga (its initial state), Tortuga
		# selected so the trade panel is open from the first frame. AI ships keep
		# auto_trade ON and trade autonomously — the player is one of several.
		var pship_ready: Ship = WorldState.get_player_ship()
		if pship_ready != null:
			pship_ready.auto_trade = false
		EventBus.ship_docked.connect(_on_ship_docked)
		_speed = 0
		DisplayServer.window_set_title("Caribbean Trade — Stage 4 (manual trade & routes)")
		# Stage UI-1: GameUI is now a child node declared in main.tscn — no more
		# load(...).new() + add_child. Grab the reference so the ship-dock handler
		# can call select_town on it exactly as before.
		_ui = $GameUI
		EventBus.message.emit("Stage 4 — docked at Tortuga. Trade here, edit the route, then Отплыть.")
		EventBus.message.emit("Space pause · 1/2/3 speed · click a town to inspect it.")
	EventBus.message.emit("World built — seed %d, %d towns, %d goods." %
			[WorldState.world_seed, WorldState.towns.size(), WorldState.goods.size()])

func _init_headless() -> void:
	_money_start = WorldState.total_money()
	var player: Company = WorldState.get_company("player")
	_company_start = player.money if player != null else 0.0
	_ai_starts.clear()
	for c in WorldState.companies:
		if c.is_ai:
			_ai_starts[c.id] = c.money
	print("=== Caribbean Trade — headless verification (Stage 1+2) ===")
	print("Seed: %d | towns: %d | goods: %d | ships: %d | world money: %.1f" %
			[WorldState.world_seed, WorldState.towns.size(), WorldState.goods.size(),
			 WorldState.ships.size(), _money_start])
	if player != null:
		print("Player company: money=%.1f" % player.money)
	_print_snapshot(0)

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _headless:
		_process_headless()
		return
	if _speed == 0:
		return
	_acc += delta * float(SPEED_DPS[_speed])
	# Cap the backlog so one stalled frame cannot spiral the sim into a freeze.
	if _acc > 30.0:
		_acc = 30.0
	while _acc >= 1.0:
		_engine.step_day()
		_acc -= 1.0

func _process_headless() -> void:
	if _done:
		return
	for _i in range(DAYS_PER_FRAME_HEADLESS):
		if _day >= SIM_DAYS_HEADLESS:
			break
		_day += 1
		_engine.step_day()
		if _day % CSV_SAMPLE_EVERY == 0:
			_capture(_day, _snapshots)
			var player: Company = WorldState.get_company("player")
			var ship: Ship = WorldState.get_player_ship()
			if player != null:
				_company_traj.append({
					"day": _day, "money": player.money,
					"cargo_used": ship.cargo_used if ship != null else 0.0,
					"state": ship.state if ship != null else "none",
					"town": ship.current_town_id if ship != null else "",
				})
	if _day >= SIM_DAYS_HEADLESS:
		_finish_headless()

func _finish_headless() -> void:
	_done = true
	_print_snapshot(SIM_DAYS_HEADLESS)
	var money_end: float = WorldState.total_money()
	print("Money: start=%.1f end=%.1f drift=%.4f (must be ~0 — money is conserved)" %
			[_money_start, money_end, money_end - _money_start])
	var player: Company = WorldState.get_company("player")
	var pship: Ship = WorldState.get_player_ship()
	var lb: float = pship.lifetime_buy_cost if pship != null else 0.0
	var ls: float = pship.lifetime_sell_revenue if pship != null else 0.0
	var upkeep_est: float = (pship.upkeep_daily * SIM_DAYS_HEADLESS) if pship != null else 0.0
	if player != null:
		var profit: float = player.money - _company_start
		print("Player: money %.1f -> %.1f  profit=%.1f  (buys=%.1f sells=%.1f upkeep~=%.1f)" %
				[_company_start, player.money, profit, lb, ls, upkeep_est])
	# AI companies use the exact same market/rules as the player — report each
	# one's result so the "world lives on its own" claim is verifiable, not just
	# asserted. A company that went broke or idle shows it honestly here.
	for c in WorldState.companies:
		if not c.is_ai:
			continue
		var aship: Ship = null
		for sid in c.ship_ids:
			aship = WorldState.get_ship(sid)
			if aship != null:
				break
		var abuy: float = aship.lifetime_buy_cost if aship != null else 0.0
		var asell: float = aship.lifetime_sell_revenue if aship != null else 0.0
		var astart: float = float(_ai_starts.get(c.id, c.money))
		print("AI %-20s money=%.1f->%.1f P/L=%+.1f net_trade=%.1f (buys=%.1f sells=%.1f)" %
				[c.name, astart, c.money, c.money - astart, asell - abuy, abuy, asell])
	# Stage 6: world events. Show how many fired (and are still active) so the
	# "world is alive" claim is verifiable, not just asserted.
	if _engine != null and _engine.event_system != null:
		var es = _engine.event_system
		print("Events fired: %d (drought=%d storm=%d famine=%d), still active=%d" %
				[es.fired_total, int(es.fired_by_type.get("drought", 0)),
				 int(es.fired_by_type.get("storm", 0)), int(es.fired_by_type.get("famine", 0)),
				 WorldState.active_events.size()])
	# war/diplomacy stats.
	var ws := _engine.war_system
	if ws != null:
		print("Wars: declared=%d, peaces=%d, incidents=%d, still active=%d" %
			[ws.wars_declared, ws.peaces_signed, ws.incidents, WorldState.active_wars.size()])
		if not WorldState.active_wars.is_empty():
			var war_parts: PackedStringArray = PackedStringArray()
			for w in WorldState.active_wars:
				war_parts.append("%s↔%s" % [w.state_a, w.state_b])
			print("Active wars: %s" % ", ".join(war_parts))
	# final state relations snapshot.
	var rel_parts: PackedStringArray = PackedStringArray()
	for k in WorldState.state_relations.keys():
		rel_parts.append("%s=%.0f" % [k, float(WorldState.state_relations[k])])
	print("Relations: %s" % ", ".join(rel_parts))
	_write_daily_csv(_snapshots)
	_write_pops_csv(_pop_snapshots)
	_write_company_csv(_company_traj)
	_write_summary(_money_start, money_end, _company_start)
	var total_pop: float = 0.0
	var total_poor: float = 0.0
	var total_middle: float = 0.0
	var total_rich: float = 0.0
	var prof_totals: Dictionary = {}
	var sat_weighted_sum: float = 0.0
	for t in WorldState.towns:
		var tpop: float = t.total_population()
		total_pop += tpop
		total_poor += t.poor
		total_middle += t.middle
		total_rich += t.rich
		sat_weighted_sum += t.satisfaction * tpop
		for p in t.pops:
			prof_totals[p.profession] = float(prof_totals.get(p.profession, 0.0)) + p.count
	var avg_sat: float = sat_weighted_sum / total_pop if total_pop > 0.0 else 0.0
	print("Population: total=%.0f (poor=%.0f middle=%.0f rich=%.0f)  avg_satisfaction=%.3f" %
			[total_pop, total_poor, total_middle, total_rich, avg_sat])
	var prof_keys: Array = prof_totals.keys()
	prof_keys.sort_custom(func(a, b): return float(prof_totals[a]) > float(prof_totals[b]))
	var prof_parts: PackedStringArray = PackedStringArray()
	for k in prof_keys:
		prof_parts.append("%s=%.0f" % [String(k), float(prof_totals[k])])
	print("  by profession: %s" % ", ".join(prof_parts))
	print("Done: %d days simulated." % SIM_DAYS_HEADLESS)
	print("Output in: %s" % ProjectSettings.globalize_path(OUT_DIR))
	# Self-terminate in headless mode so verification runs are script-friendly.
	get_tree().quit()

# --- speed control (called by the UI buttons and the keyboard) ---

func set_speed(s: int) -> void:
	_speed = clampi(s, 0, SPEED_DPS.size() - 1)

func get_speed() -> int:
	return _speed

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().quit()
			KEY_SPACE:
				set_speed(0 if _speed != 0 else 1)
			KEY_1:
				set_speed(1)
			KEY_2:
				set_speed(2)
			KEY_3:
				set_speed(3)

# --- Stage 4: player control (called by the UI buttons) ---

func _on_ship_docked(ship_id: String, town_id: String) -> void:
	# Only the player's docking pauses the clock. AI ships dock, trade and
	# depart on their own each day — their arrivals flow through the log without
	# interrupting the player. Without this guard every rival port call would
	# auto-pause the game.
	var pship: Ship = WorldState.get_player_ship()
	if pship == null or ship_id != pship.id:
		return
	set_speed(0)
	if _ui != null:
		_ui.call("select_town", town_id)
	var t: Town = WorldState.get_town(town_id)
	EventBus.message.emit("⚓ docked at %s — trade, then Отплыть" % (t.name if t != null else town_id))

func player_buy(good_id: String, qty: float) -> void:
	var s: Ship = _player_ship()
	if s == null:
		return
	if s.state != "docked" or s.current_town_id == "":
		EventBus.message.emit("not docked — cannot trade")
		return
	var co: Company = WorldState.get_company(s.owner_id)
	var town: Town = WorldState.get_town(s.current_town_id)
	if co == null or town == null:
		return
	_engine.trade_system.manual_buy(s, co, town, good_id, qty)

func player_sell(good_id: String, qty: float) -> void:
	var s: Ship = _player_ship()
	if s == null:
		return
	if s.state != "docked" or s.current_town_id == "":
		EventBus.message.emit("not docked — cannot trade")
		return
	var co: Company = WorldState.get_company(s.owner_id)
	var town: Town = WorldState.get_town(s.current_town_id)
	if co == null or town == null:
		return
	_engine.trade_system.manual_sell(s, co, town, good_id, qty)

func depart_ship() -> void:
	var s: Ship = _player_ship()
	if s == null or s.state != "docked":
		return
	var route: TradeRoute = WorldState.get_route(s.route_id)
	if route == null or route.stops.is_empty():
		EventBus.message.emit("no route — add at least one stop")
		return
	var dest: String
	if route.stops.has(s.current_town_id):
		dest = route.next_stop_after(s.current_town_id)
	else:
		dest = route.stops[0]
	if dest == "" or dest == s.current_town_id:
		EventBus.message.emit("nowhere to sail — edit the route")
		return
	s.destination_id = dest
	s.state = "sailing"
	set_speed(1)
	var d: Town = WorldState.get_town(dest)
	EventBus.message.emit("⛵ departing to %s" % (d.name if d != null else dest))

func route_add(town_id: String) -> void:
	var s: Ship = _player_ship()
	if s == null:
		return
	var route: TradeRoute = WorldState.get_route(s.route_id)
	if route == null:
		return
	if route.stops.has(town_id):
		EventBus.message.emit("%s already in the route" % town_id)
		return
	route.stops.append(town_id)
	var t: Town = WorldState.get_town(town_id)
	EventBus.message.emit("+ added %s to the route" % (t.name if t != null else town_id))

func route_remove(town_id: String) -> void:
	var s: Ship = _player_ship()
	if s == null:
		return
	var route: TradeRoute = WorldState.get_route(s.route_id)
	if route == null:
		return
	route.stops.erase(town_id)
	var t: Town = WorldState.get_town(town_id)
	EventBus.message.emit("x removed %s from the route" % (t.name if t != null else town_id))

func route_move(town_id: String, dir: int) -> void:
	var s: Ship = _player_ship()
	if s == null:
		return
	var route: TradeRoute = WorldState.get_route(s.route_id)
	if route == null:
		return
	var idx: int = route.stops.find(town_id)
	if idx < 0:
		return
	var j: int = idx + dir
	if j < 0 or j >= route.stops.size():
		return
	var tmp: String = route.stops[idx]
	route.stops[idx] = route.stops[j]
	route.stops[j] = tmp

# --- diplomacy (called by the UI Diplomacy panel buttons) ---
#
# Bribes and citizenship are the player's levers on the reputation system
# (Stage A3). Both move money company -> state.treasury, which is in
# total_money(), so the money-conservation invariant (drift=0) holds. Neither
# reads an rng, so determinism is unaffected.

# Bribe a state's officials: cost scales with how much they dislike you (500 at
# rep>=0, up to 1500 at rep=-100), raises rep by BRIBE_REP_GAIN, and is on a
# BRIBE_COOLDOWN_WEEKS cooldown. The fee is a payment to the state (conserved).
func bribe_state(state_id: String) -> void:
	var st: State = WorldState.get_state(state_id)
	if st == null:
		return
	var company: Company = WorldState.get_company("player")
	if company == null:
		return
	# Re-check the guards the UI already enforces — a deferred click or a stale
	# panel could otherwise let a broke / on-cooldown bribe slip through.
	var last_week: int = int(company.bribe_cooldowns.get(state_id, -999))
	if SimulationClock.week - last_week < BRIBE_COOLDOWN_WEEKS:
		EventBus.message.emit("bribe %s on cooldown" % st.name)
		return
	var rep: float = WorldState.get_player_rep(state_id)
	var cost: float = BRIBE_BASE_COST * (1.0 + max(0.0, -rep / 50.0))
	if company.money < cost:
		EventBus.message.emit("not enough money to bribe %s" % st.name)
		return
	company.money -= cost
	st.treasury += cost
	WorldState.adjust_player_rep(state_id, BRIBE_REP_GAIN)
	company.bribe_cooldowns[state_id] = SimulationClock.week
	EventBus.message.emit("bribed %s: -%.0f, rep %+d" % [st.name, cost, int(BRIBE_REP_GAIN)])

# Apply for citizenship with a state you're in good standing with (rep > 50).
# Flat naturalization fee; money -> state.treasury (conserved). Sets the ship's
# flag_state so it flies the new colours — this changes which ports it can dock
# at during wars (see ShipsTick._can_dock). Defection penalty: every other state
# (not the new flag, not the old one) loses 10 rep — switching sides is a real
# diplomatic rupture, not a free flag-swap. No money moves on the penalty.
func apply_citizenship(state_id: String) -> void:
	var st: State = WorldState.get_state(state_id)
	if st == null:
		return
	var company: Company = WorldState.get_company("player")
	var ship: Ship = WorldState.get_player_ship()
	if company == null or ship == null:
		return
	if ship.flag_state == state_id:
		EventBus.message.emit("already a citizen of %s" % st.name)
		return
	if WorldState.get_player_rep(state_id) <= CITIZENSHIP_REP_THRESHOLD:
		EventBus.message.emit("rep with %s too low for citizenship" % st.name)
		return
	if company.money < CITIZENSHIP_COST:
		EventBus.message.emit("not enough money for %s citizenship" % st.name)
		return
	company.money -= CITIZENSHIP_COST
	st.treasury += CITIZENSHIP_COST
	var old_flag: String = ship.flag_state
	ship.flag_state = state_id
	# Defection penalty: bystander states (not the new flag, not the old flag)
	# each lose 10 rep. No money moves here, so drift stays 0.
	for other in WorldState.states:
		if other.id == state_id or other.id == old_flag:
			continue
		WorldState.adjust_player_rep(other.id, -10.0)
	EventBus.message.emit("citizenship: %s -> %s (-%.0f, others -10 rep)" % [old_flag, st.name, CITIZENSHIP_COST])

# C4 follow-up: borrow from a state bank. Delegates to Company.take_loan, which
# moves money state.treasury -> company.money (conserved), caps at the state's
# available treasury, and records principal in company.loans[state_id]. The
# weekly interest accrues in SimulationEngine.step_week. No-op if bankrupt.
# Emits a message with the actual amount lent (may be < requested if the state
# is thin). The UI's borrow buttons are disabled at/below zero, but we re-check
# here the same way bribe_state does — a deferred click or a stale panel could
# otherwise slip a borrow through.
func take_loan(state_id: String, amount: float) -> void:
	var st: State = WorldState.get_state(state_id)
	if st == null:
		return
	var company: Company = WorldState.get_company("player")
	if company == null or company.bankrupt:
		return
	if amount <= 0.0:
		return
	var lent: float = company.take_loan(amount, state_id)
	if lent > 0.0:
		EventBus.message.emit("borrowed $%.0f from %s (treasury $%.0f)" % [lent, st.name, st.treasury])
	else:
		EventBus.message.emit("%s treasury too thin to lend $%.0f" % [st.name, amount])

# C4 follow-up: repay part of an outstanding loan. Delegates to
# Company.repay_loan, which caps the payment at both the outstanding principal
# and the company's available money (can't repay money you don't have). Emits
# a message with the actual amount repaid.
func repay_loan(state_id: String, amount: float) -> void:
	var st: State = WorldState.get_state(state_id)
	if st == null:
		return
	var company: Company = WorldState.get_company("player")
	if company == null or company.bankrupt:
		return
	if amount <= 0.0:
		return
	var paid: float = company.repay_loan(amount, state_id)
	if paid > 0.0:
		EventBus.message.emit("repaid $%.0f to %s (owed $%.0f)" % [paid, st.name, float(company.loans.get(state_id, 0.0))])
	else:
		EventBus.message.emit("can't repay %s: no outstanding loan or no cash" % st.name)

# Read-only queries the UI panels use for layout.
func player_dock_town_id() -> String:
	var s: Ship = _player_ship()
	if s == null or s.state != "docked":
		return ""
	return s.current_town_id

func player_next_destination() -> String:
	var s: Ship = _player_ship()
	if s == null:
		return ""
	if s.state == "docked":
		var route: TradeRoute = WorldState.get_route(s.route_id)
		if route != null and not route.stops.is_empty():
			if route.stops.has(s.current_town_id):
				return route.next_stop_after(s.current_town_id)
			return route.stops[0]
		return ""
	return s.destination_id

func _player_ship() -> Ship:
	return WorldState.ships[0] if not WorldState.ships.is_empty() else null

# --- headless report writers (unchanged from Stage 1+2) ---

func _capture(day: int, out: Array) -> void:
	for t in WorldState.towns:
		for v in t.market.entries.values():
			var e: Market.Entry = v
			out.append({
				"day": day, "town": t.name, "good": e.good_id,
				"stock": e.stock, "price": e.current_price,
				"demand": e.daily_demand, "supply": e.daily_supply,
			})
		# Stage B1.5: capture Pop state per town per profession for sim_pops.csv.
		for p in t.pops:
			_pop_snapshots.append({
				"day": day, "town": t.name, "profession": p.profession,
				"social_class": p.social_class, "count": p.count,
				"satisfaction": p.satisfaction, "employed_count": p.employed_count,
			})

func _print_snapshot(day: int) -> void:
	print("\n--- snapshot day %d ---" % day)
	print("%-11s %8s %8s %8s %8s %8s   %-11s %8s %8s" %
			["town", "pop", "poor", "mid", "rich", "sat", "good", "stock", "price"])
	for t in WorldState.towns:
		var shown: int = 0
		for v in t.market.entries.values():
			var e: Market.Entry = v
			# Show only goods that are produced or meaningfully stocked.
			var interesting: bool = e.stock > 0.01 or e.daily_supply > 0.01 or e.daily_demand > 0.01
			if not interesting:
				continue
			if shown == 0:
				print("%-11s %8.0f %8.0f %8.0f %8.0f %8.3f   %-11s %8.1f %8.2f" %
						[t.name, t.total_population(), t.poor, t.middle, t.rich, t.satisfaction,
						 e.good_id, e.stock, e.current_price])
			else:
				print("%-11s %43s   %-11s %8.1f %8.2f" %
						["", "", e.good_id, e.stock, e.current_price])
			shown += 1
		if shown == 0:
			print("%-11s %8.0f %8.0f %8.0f %8.0f %8.3f   (no active goods)" %
					[t.name, t.total_population(), t.poor, t.middle, t.rich, t.satisfaction])

func _write_daily_csv(snapshots: Array) -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var f := FileAccess.open(OUT_DIR + "sim_daily.csv", FileAccess.WRITE)
	if f == null:
		push_error("cannot write CSV")
		return
	f.store_line("day,town,good,stock,price,demand,supply")
	for s in snapshots:
		f.store_line("%d,%s,%s,%.3f,%.3f,%.3f,%.3f" %
				[int(s["day"]), String(s["town"]), String(s["good"]),
				 float(s["stock"]), float(s["price"]), float(s["demand"]), float(s["supply"])])
	f.close()

func _write_company_csv(traj: Array) -> void:
	var f := FileAccess.open(OUT_DIR + "company_money.csv", FileAccess.WRITE)
	if f == null:
		push_error("cannot write company CSV")
		return
	f.store_line("day,money,cargo_used,state,town")
	for s in traj:
		f.store_line("%d,%.3f,%.3f,%s,%s" %
				[int(s["day"]), float(s["money"]), float(s["cargo_used"]),
				 String(s["state"]), String(s["town"])])
	f.close()

## Stage B1.5: weekly Pop state per town per profession → sim_pops.csv.
## Columns: day,town,profession,social_class,count,satisfaction,employed_count
## 15 towns × 10 professions × ~52 weeks ≈ 7800 rows.
func _write_pops_csv(snapshots: Array) -> void:
	var f := FileAccess.open(OUT_DIR + "sim_pops.csv", FileAccess.WRITE)
	if f == null:
		push_error("cannot write pops CSV")
		return
	f.store_line("day,town,profession,social_class,count,satisfaction,employed_count")
	for s in snapshots:
		f.store_line("%d,%s,%s,%s,%.3f,%.3f,%.3f" %
					[int(s["day"]), String(s["town"]), String(s["profession"]),
					 String(s["social_class"]), float(s["count"]),
					 float(s["satisfaction"]), float(s["employed_count"])])
	f.close()

func _write_summary(money_start: float, money_end: float, company_start: float) -> void:
	var f := FileAccess.open(OUT_DIR + "sim_summary.txt", FileAccess.WRITE)
	if f == null:
		push_error("cannot write summary")
		return
	f.store_line("Caribbean Trade — %d-day simulation summary (Stage 1+2)" % SIM_DAYS_HEADLESS)
	f.store_line("Seed: %d" % WorldState.world_seed)
	f.store_line("Money conservation: start=%.2f end=%.2f drift=%.2f (must be ~0)" %
			[money_start, money_end, money_end - money_start])
	var n_ai: int = 0
	for c in WorldState.companies:
		if c.is_ai:
			n_ai += 1
	f.store_line("(no external/regional trade — inter-town trade is the player + %d AI companies, plus Stage 6 world events)" % n_ai)
	if _engine != null and _engine.event_system != null:
		var es2 = _engine.event_system
		f.store_line("Events fired: %d (drought=%d storm=%d famine=%d)" %
				[es2.fired_total, int(es2.fired_by_type.get("drought", 0)),
				 int(es2.fired_by_type.get("storm", 0)), int(es2.fired_by_type.get("famine", 0))])
	f.store_line("")
	var player: Company = WorldState.get_company("player")
	if player != null:
		f.store_line("=== Player ===")
		f.store_line("  money: %.1f -> %.1f  profit=%.1f" %
				[company_start, player.money, player.money - company_start])
		for ship in WorldState.ships:
			var town_name: String = ""
			var tt: Town = WorldState.get_town(ship.current_town_id)
			if tt != null:
				town_name = tt.name
			f.store_line("  ship %-10s type=%-9s state=%-8s at=%-11s cargo_used=%.1f/%.1f" %
					[ship.id, ship.ship_type, ship.state, town_name,
					 ship.cargo_used, ship.cargo_capacity])
			f.store_line("    lifetime: buys=%.1f sells=%.1f net_trade=%.1f" %
					[ship.lifetime_buy_cost, ship.lifetime_sell_revenue,
					 ship.lifetime_sell_revenue - ship.lifetime_buy_cost])
			if not ship.cargo.is_empty():
				var parts := PackedStringArray()
				for good_id in ship.cargo.keys():
					parts.append("%s=%.1f" % [String(good_id), float(ship.cargo[good_id])])
				f.store_line("    cargo: %s" % ", ".join(parts))
	f.store_line("")
	f.store_line("=== AI Companies ===")
	for c in WorldState.companies:
		if not c.is_ai:
			continue
		var astart2: float = float(_ai_starts.get(c.id, c.money))
		f.store_line("  %-22s money=%.1f->%.1f P/L=%+.1f" %
				[c.name, astart2, c.money, c.money - astart2])
		for sid in c.ship_ids:
			var as2: Ship = WorldState.get_ship(sid)
			if as2 == null:
				continue
			f.store_line("    ship %-16s state=%-8s net_trade=%.1f (buys=%.1f sells=%.1f)" %
					[as2.id, as2.state,
					 as2.lifetime_sell_revenue - as2.lifetime_buy_cost,
					 as2.lifetime_buy_cost, as2.lifetime_sell_revenue])
	f.store_line("")
	for t in WorldState.towns:
		f.store_line("=== %s ===" % t.name)
		f.store_line("  population: poor=%.0f middle=%.0f rich=%.0f (total %.0f)  satisfaction=%.3f" %
				[t.poor, t.middle, t.rich, t.total_population(), t.satisfaction])
		f.store_line("  Pops (%d):" % t.pops.size())
		for p in t.pops:
			var unemp_rate: float = (1.0 - p.employed_count / p.count) if p.count > 0.0 else 0.0
			f.store_line("    %-12s/%-14s count=%7.1f sat=%.3f employed=%6.1f (%.1f%%)" %
					[p.social_class, p.profession, p.count, p.satisfaction,
					 p.employed_count, unemp_rate * 100.0])
		f.store_line("  pop_money=%.1f  market_fund=%.1f  external_balance=%.1f" %
				[t.population_money, t.market.fund, t.external_balance])
		# Stage B2.1: wage_rate per profession (for diagnostics/balancing).
		if t.wage_rate.size() > 0:
			var wage_parts: PackedStringArray = PackedStringArray()
			var profs_sorted: Array = t.wage_rate.keys()
			profs_sorted.sort()
			for prof in profs_sorted:
				wage_parts.append("%s=%.2f" % [String(prof), float(t.wage_rate[prof])])
			f.store_line("  wages: %s" % ", ".join(wage_parts))
		f.store_line("  industries:")
		for ind in t.industries:
			f.store_line("    %-18s workers=%.1f money=%.1f weekly_profit=%.1f" %
					[ind.recipe_id, ind.workers, ind.money, ind.weekly_profit])
		f.store_line("  goods (active):")
		for v in t.market.entries.values():
			var e: Market.Entry = v
			if e.stock < 0.01 and e.daily_demand < 0.01 and e.daily_supply < 0.01:
				continue
			f.store_line("    %-12s stock=%8.1f price=%8.2f demand=%7.2f supply=%7.2f" %
					[e.good_id, e.stock, e.current_price, e.daily_demand, e.daily_supply])
		f.store_line("")
	f.close()
