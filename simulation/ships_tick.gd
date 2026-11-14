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
	if storm_extra > 0.0 and company.money >= storm_extra:
		company.money -= storm_extra
		if upkeep_town != null:
			upkeep_town.population_money += storm_extra

	# If idle with no destination, point it at the first stop of its route.
	if ship.state == "idle" or (ship.destination_id == "" and ship.state != "docked"):
		_start_route(ship)

	# Movement.
	if ship.state == "sailing":
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
