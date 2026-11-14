class_name ShipsTick
extends RefCounted

## Daily step for every ship: upkeep, movement, trade execution. Runs AFTER the
## town daily ticks, so ships trade at this morning's prices (set at the end of
## yesterday's [method MarketSystem.update_market]). A ship that arrives at its
## destination docks, trades its route at that port, and departs for the next
## stop — all in the same day it arrives.

var trade_system: TradeSystem
var market_system: MarketSystem

func _init(p_trade: TradeSystem, p_market: MarketSystem) -> void:
	trade_system = p_trade
	market_system = p_market

func run() -> void:
	for ship in WorldState.ships:
		_step_ship(ship)

func _step_ship(ship: Ship) -> void:
	var company: Company = _owner_of(ship)
	if company == null:
		return

	# Upkeep: paid to crew/port services, routed to the town the ship is
	# associated with so the money stays in circulation. A broke company
	# strands the ship (it goes idle until it has cash again).
	var upkeep_town: Town = _town_for(ship)
	# Stage 6: a storm adds damage-repair upkeep on top of the crew's wage,
	# paid to the same local town (company -> population_money, conserved).
	var storm_extra: float = WorldState.storm_extra_upkeep(ship)
	var base_upkeep: float = ship.upkeep_daily
	if company.money < base_upkeep:
		if ship.state != "idle":
			EventBus.message.emit("%s idle — no upkeep funds" % ship.id)
		ship.state = "idle"
		return
	company.money -= base_upkeep
	if upkeep_town != null:
		upkeep_town.population_money += base_upkeep
	# the player's daily upkeep is a silent wallet drain — log it so the
	# player sees where the money went (answers "money just decreases"). AI
	# companies stay quiet: their books are off-screen and logging 3 rivals/day
	# would push the player's own trade lines out of the 14-line log.
	if ship.owner_id == "player" and base_upkeep > 0.0:
		EventBus.message.emit("upkeep -%.1f (%s)" % [base_upkeep, ship.id])
	if storm_extra > 0.0 and company.money >= storm_extra:
		company.money -= storm_extra
		if upkeep_town != null:
			upkeep_town.population_money += storm_extra
		if ship.owner_id == "player":
			EventBus.message.emit("storm repair -%.1f (%s)" % [storm_extra, ship.id])

	# If idle with no destination, point it at the first stop of its route.
	if ship.state == "idle" or (ship.destination_id == "" and ship.state != "docked"):
		_start_route(ship)

	# Movement.
	if ship.state == "sailing":
		# Stage A1: pirate attack roll. Only fires while the ship is at sea
		# (a docked ship is under port protection). Uses a SEPARATE rng stream
		# (WorldState.pirate_rng) so drought/storm/famine event_rng stays
		# bit-stable across this change. armed ships reduce the probability.
		_roll_pirate_attack(ship, company, upkeep_town)
		var dest: Town = WorldState.get_town(ship.destination_id)
		if dest == null:
			ship.state = "idle"
			return
		# Stage 6: a storm slows the ship for the day (speed x storm_multiplier).
		var eff_speed: float = ship.speed * WorldState.storm_multiplier(ship.id)
		var d: float = ship.pos.distance_to(dest.coords)
		if d <= eff_speed:
			ship.pos = dest.coords
			ship.current_town_id = dest.id
			# Stage A3: port access check. War blocks ships flying the enemy
			# flag; low player rep (< -50) blocks the player specifically.
			# A blocked ship does NOT dock — it routes to the next stop.
			if not _can_dock(ship, dest):
				EventBus.message.emit("%s denied entry to %s — sailing on" % [ship.id, dest.name])
				var route: TradeRoute = WorldState.get_route(ship.route_id)
				if route != null and not route.stops.is_empty():
					ship.destination_id = route.next_stop_after(dest.id)
					ship.state = "sailing"
				else:
					ship.state = "idle"
				return
			ship.state = "docked"
			ship.days_sailing = 0
			EventBus.message.emit("%s docked at %s" % [ship.id, dest.name])
			# Stage 4: tell the controller we reached a port so it can auto-pause
			# for the player to trade. Auto ships keep going regardless.
			EventBus.ship_docked.emit(ship.id, dest.id)
		else:
			var dir: Vector2 = (dest.coords - ship.pos).normalized()
			ship.pos += dir * eff_speed
			ship.days_sailing += 1
			return   # still at sea, no trade today

	# Docked. Auto ships trade their route and depart the same day; a player-
	# controlled ship (auto_trade == false) just sits in port until the player
	# manually trades and clicks "Отплыть".
	if ship.state == "docked" and ship.current_town_id != "" and ship.auto_trade:
		var town: Town = WorldState.get_town(ship.current_town_id)
		var route: TradeRoute = WorldState.get_route(ship.route_id)
		if town != null and route != null:
			trade_system.execute_route(ship, company, town, route)
		if route != null and not route.stops.is_empty():
			ship.destination_id = route.next_stop_after(ship.current_town_id)
			ship.state = "sailing"

func _start_route(ship: Ship) -> void:
	var route: TradeRoute = WorldState.get_route(ship.route_id)
	if route == null or route.stops.is_empty():
		ship.state = "idle"
		return
	# If already at a stop, treat as docked there; else sail to the first stop.
	if ship.current_town_id != "" and route.stops.has(ship.current_town_id):
		ship.state = "docked"
	else:
		ship.destination_id = route.stops[0]
		ship.state = "sailing"

func _owner_of(ship: Ship) -> Company:
	for c in WorldState.companies:
		if c.id == ship.owner_id:
			return c
	return null

func _town_for(ship: Ship) -> Town:
	var tid: String = ship.current_town_id if ship.current_town_id != "" else ship.destination_id
	if tid == "":
		return null
	return WorldState.get_town(tid)

# Stage A3: can this ship dock at this town? War blocks ships flying the
# enemy flag (a Spanish-flagged ship cannot enter an English port during
# the Anglo-Spanish war). Low player rep (< -50) blocks the player even
# without formal war — the port authority simply denies entry to a known
# smuggler/hostile trader. AI ships are subject to war blockades too.
func _can_dock(ship: Ship, town: Town) -> bool:
	if town == null:
		return false
	var port_state: String = town.state_id
	if port_state == "":
		return true   # no state owner, free port
	# War blocks enemy-flagged ships.
	if ship.flag_state != "" and ship.flag_state != port_state:
		if WorldState.at_war(ship.flag_state, port_state):
			return false
	# Low player rep blocks the player (not AI).
	if ship.owner_id == "player":
		if WorldState.get_player_rep(port_state) < -50.0:
			return false
	return true

# Stage A1: roll for a pirate attack on a sailing ship and apply the
# outcome (cargo loss + repair upkeep). See header comment for money /
# goods conservation notes.
func _roll_pirate_attack(ship: Ship, company: Company, local_town: Town) -> void:
	var def: Dictionary = WorldState.pirates_db.get("pirate_attack", {})
	if def.is_empty():
		return
	var base_prob: float = float(def.get("prob_per_sailing_day", 0.0))
	if base_prob <= 0.0:
		return
	# armed ships cut the effective probability (1+armed divisor).
	var eff_prob: float = base_prob / (1.0 + float(ship.armed))
	if WorldState.pirate_rng.randf() >= eff_prob:
		return
	# Hit. Lose cargo_loss_pct of a random carried good (if any).
	var loss_pct: float = float(def.get("cargo_loss_pct", 0.0))
	var lost_good: String = ""
	var lost_qty: float = 0.0
	if loss_pct > 0.0 and ship.cargo_used > 0.0:
		var goods_in_hold: Array = ship.cargo.keys()
		# Deterministic pick: cycle through cargo keys with pirate_rng.
		var pick_idx: int = WorldState.pirate_rng.randi() % goods_in_hold.size()
		lost_good = String(goods_in_hold[pick_idx])
		var have: float = ship.cargo_qty(lost_good)
		lost_qty = ship.remove_cargo(lost_good, have * loss_pct)
	# Repair upkeep: extra_upkeep_mult × daily upkeep, paid to local town
	# (same routing as storm_extra_upkeep — company -> population_money).
	var extra_mult: float = float(def.get("extra_upkeep_mult", 0.0))
	var extra_upkeep: float = extra_mult * ship.upkeep_daily
	if extra_upkeep > 0.0 and company.money >= extra_upkeep:
		company.money -= extra_upkeep
		if local_town != null:
			local_town.population_money += extra_upkeep
	var msg: String = "Пираты атаковали %s" % ship.id
	if lost_qty > 0.0:
		msg += ": -%.1f %s" % [lost_qty, lost_good]
	if extra_upkeep > 0.0:
		msg += ", ремонт %.1f" % extra_upkeep
	EventBus.message.emit(msg)
	# Stage A3: pirate attack lowers player's pirate reputation — you're
	# a target now, pirates remember. AI ships don't track rep.
	if ship.owner_id == "player":
		WorldState.adjust_player_rep("pirates", -2.0)
