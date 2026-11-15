class_name ShipsTick
extends RefCounted

## Daily step for every ship: upkeep, movement, trade execution. Runs AFTER the
## town daily ticks, so ships trade at this morning's prices (set at the end of
## yesterday's [method MarketSystem.update_market]). A ship that arrives at its
## destination docks, trades its route at that port, and departs for the next
## stop — all in the same day it arrives.

var trade_system: TradeSystem
var market_system: MarketSystem
var ai_brain: AIBrain   # Price-responsive decision engine for AI ships

func _init(p_trade: TradeSystem, p_market: MarketSystem) -> void:
	trade_system = p_trade
	market_system = p_market
	ai_brain = AIBrain.new()

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
		upkeep_town.add_to_all_pops(base_upkeep)
	# the player's daily upkeep is a silent wallet drain — log it so the
	# player sees where the money went (answers "money just decreases"). AI
	# companies stay quiet: their books are off-screen and logging 3 rivals/day
	# would push the player's own trade lines out of the 14-line log.
	if ship.owner_id == "player" and base_upkeep > 0.0:
		EventBus.message.emit("upkeep -%.1f (%s)" % [base_upkeep, ship.id])
	if storm_extra > 0.0 and company.money >= storm_extra:
		company.money -= storm_extra
		if upkeep_town != null:
			upkeep_town.add_to_all_pops(storm_extra)
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
			# A docked captain sees today's real prices — snapshot them
			# into the company's price memory (refreshes this port, others age on).
			if company.memory != null:
				company.memory.snapshot(dest, SimulationClock.day)
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
		if town == null:
			return
		# Stage B2b: disembark passengers whose destination is this town.
		_disembark_passengers(ship, town)
		# Stage B2b: board waiting passengers going to the ship's next destination.
		_board_passengers(ship, town)
		if company.is_ai:
			if ship.ship_type == "packet":
				# Packet ships follow fixed ferry routes (not AIBrain).
				_packet_step(ship, company, town)
			else:
				_ai_step(ship, company, town)
		else:
			var route: TradeRoute = WorldState.get_route(ship.route_id)
			if route != null:
				trade_system.execute_route(ship, company, town, route)
			if route != null and not route.stops.is_empty():
				ship.destination_id = route.next_stop_after(ship.current_town_id)
				ship.state = "sailing"

# AI ships decide via AIBrain (price-responsive arbitrage from the
# company's PriceMemory) instead of a fixed data-route loop. The brain returns
# {trade: StopRule|null, dest: town_id}; we execute the trade here (if any)
# through the same money-conserving execute_buy/sell the player's route uses,
# then sail to dest. One decide, one trade, one depart per dock.
func _ai_step(ship: Ship, company: Company, town: Town) -> void:
	var plan: Dictionary = ai_brain.decide(ship, company, town, SimulationClock.day)
	var trade: Variant = plan.get("trade", null)
	if trade != null:
		var rule: TradeRoute.StopRule = trade
		if rule.action == "buy":
			trade_system.execute_buy(ship, company, town, rule)
		else:
			trade_system.execute_sell(ship, company, town, rule)
	var dest: String = String(plan.get("dest", ""))
	if dest != "" and dest != town.id:
		ship.destination_id = dest
		ship.state = "sailing"
	elif trade != null:
		# traded but the brain gave no/own port as dest — sail to a scout port so
		# we don't re-trade here next tick (avoids same-port loops).
		ship.destination_id = ai_brain.explore_dest(company.memory, town, SimulationClock.day)
		ship.state = "sailing"
	# else: no trade + no dest → stay docked, re-decide next day (rare).

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

## Stage B2b: packet ships follow fixed ferry routes (not AIBrain).
## They visit the same stops in a loop, executing empty trade rules (just travel),
## and serve as the primary passenger transport.
func _packet_step(ship: Ship, company: Company, town: Town) -> void:
	var route: TradeRoute = WorldState.get_route(ship.route_id)
	if route != null:
		# Execute trade rules (may be empty for packet routes — just travel).
		trade_system.execute_route(ship, company, town, route)
	if route != null and not route.stops.is_empty():
		ship.destination_id = route.next_stop_after(ship.current_town_id)
		ship.state = "sailing"

## Stage B2b: disembark passengers whose destination is this town.
## Moves Pop.count from ship → destination town's Pop (creates Pop if needed).
func _disembark_passengers(ship: Ship, town: Town) -> void:
	if ship.passengers.is_empty():
		return
	var to_remove: Array = []
	for prof in ship.passengers.keys():
		var count: float = float(ship.passengers[prof])
		if count <= 0.0:
			continue
		# Find or create Pop of this profession in destination town.
		var dest_pop: Pop = null
		for p in town.pops:
			if p.profession == String(prof):
				dest_pop = p
				break
		if dest_pop != null:
			dest_pop.count += count
		else:
			# Immigration creates a new Pop group in this town.
			var cls: String = _class_for_profession(String(prof))
			var new_pop := Pop.new("%s_pop_%s_imm" % [town.id, String(prof)], town.id, cls, String(prof), count)
			town.pops.append(new_pop)
		to_remove.append(prof)
	for prof in to_remove:
		ship.remove_passengers(String(prof), float(ship.passengers[prof]))

## Stage B2b: board waiting passengers from town onto ship.
## Passengers board only if the ship is going to their destination.
## For packet ships: destination must be in route.stops.
## For AIBrain/player: destination must match ship.destination_id (next port).
func _board_passengers(ship: Ship, town: Town) -> void:
	if town.waiting_passengers.is_empty() or ship.passenger_free() <= 0.0:
		return
	# Determine which destinations this ship can serve.
	var serves_destinations: Array = []
	if ship.ship_type == "packet":
		var route: TradeRoute = WorldState.get_route(ship.route_id)
		if route != null:
			serves_destinations = route.stops.duplicate()
	else:
		# AIBrain/player ships: serve next destination only.
		if ship.destination_id != "":
			serves_destinations.append(ship.destination_id)
	if serves_destinations.is_empty():
		return
	# Try to board each waiting passenger group.
	var remaining: Array = []
	for entry in town.waiting_passengers:
		var prof: String = String(entry["profession"])
		var count: float = float(entry["count"])
		var dest: String = String(entry["destination"])
		if count <= 0.0:
			continue
		if not serves_destinations.has(dest):
			remaining.append(entry)
			continue
		# Ship goes to this destination — board up to passenger_free.
		var board: float = min(count, ship.passenger_free())
		if board <= 0.0:
			remaining.append(entry)
			continue
		# Stage B3: ticket cost. Passengers pay from their savings to the
		# ship's company. 0.5 per person per estimated sailing day (distance
		# based — rough estimate using ship speed). Gives packet lines income.
		var dest_town: Town = WorldState.get_town(dest)
		var ticket_per_person: float = 0.5   # base rate per person
		if dest_town != null:
			var dist: float = town.coords.distance_to(dest_town.coords)
			var sail_days: float = ceil(dist / ship.speed) if ship.speed > 0.0 else 1.0
			ticket_per_person = 0.5 * sail_days
		# Pop pays from savings; if can't afford full ticket, fewer board.
		for p in town.pops:
			if p.profession == prof:
				var max_affordable: float = p.savings / ticket_per_person if ticket_per_person > 0.0 else board
				board = min(board, max_affordable)
				if board <= 0.0:
					break
				var ticket_total: float = board * ticket_per_person
				p.savings -= ticket_total
				# Ship company earns the ticket revenue.
				var company: Company = _owner_of(ship)
				if company != null:
					company.money += ticket_total
				break
		if board <= 0.0:
			remaining.append(entry)
			continue
		# Remove boarded count from origin Pop.
		for p in town.pops:
			if p.profession == prof:
				p.count = max(0.0, p.count - board)
				break
		ship.add_passengers(prof, board)
		# If some couldn't board (ship full), keep remainder in queue.
		if board < count:
			remaining.append({"profession": prof, "count": count - board, "destination": dest})
	town.waiting_passengers = remaining

## Map profession → social_class for immigration (creates new Pop with correct class).
func _class_for_profession(prof: String) -> String:
	match prof:
		"laborer", "sailor", "servant":
			return "poor"
		"artisan", "smith", "merchant", "small_planter":
			return "middle"
		"planter", "official", "financier":
			return "rich"
		_:
			return "poor"

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
			local_town.add_to_all_pops(extra_upkeep)
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
