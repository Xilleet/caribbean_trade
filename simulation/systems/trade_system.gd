class_name TradeSystem
extends RefCounted

## Executes player trades through [MarketSystem]. Every buy/sell moves real
## stock AND real money:
##   buy  -> company.money down, market.fund up, ship cargo up;
##   sell -> ship cargo down, market.fund down, company.money up.
## The ship's free hold limits buys; the ship's cargo limits sells. Rules are
## self-limiting via [param threshold] (see [TradeRoute]): a buy drains market
## surplus down to the threshold, a sell fills shortage up to the threshold.
## A ship can never sell a good it does not carry — [method execute_sell]
## checks the hold first and returns 0.

var market_system: MarketSystem

func _init(p_market: MarketSystem) -> void:
	market_system = p_market

# `rule` is a TradeRoute.StopRule (untyped here only because inner-class type
# annotations can be finicky across Godot point releases; the fields used are
# accessed by name, which is safe on any RefCounted holding them).
func execute_buy(ship: Ship, company: Company, town: Town, rule) -> Dictionary:
	if rule.action != "buy" or not town.market.has_good(rule.good_id):
		return {"qty": 0.0, "cost": 0.0}
	var e: Market.Entry = town.market.get_entry(rule.good_id)
	# Only buy from a port that is in surplus (stock above the threshold).
	if e.stock <= rule.threshold:
		return {"qty": 0.0, "cost": 0.0}
	# Respect the price limit (don't buy if it's already too expensive).
	if rule.price_limit > 0.0 and e.current_price > rule.price_limit:
		return {"qty": 0.0, "cost": 0.0}
	var drainable: float = e.stock - rule.threshold
	var qty: float = min(min(rule.max_qty, drainable), ship.cargo_free())
	if qty <= 0.0:
		return {"qty": 0.0, "cost": 0.0}
	var res: Dictionary = market_system.buy(town.market, rule.good_id, qty, company.money)
	var actual: float = float(res["qty"])
	var cost: float = float(res["cost"])
	company.money -= cost
	town.market.fund += cost
	ship.add_cargo(rule.good_id, actual)
	ship.last_buy_cost = cost
	ship.lifetime_buy_cost += cost
	EventBus.trade_completed.emit(town.id, rule.good_id, actual, float(res["price"]))
	EventBus.message.emit("bought %.0f %s @ %.2f in %s (-%.1f)" %
			[actual, rule.good_id, float(res["price"]), town.name, cost])
	return {"qty": actual, "cost": cost}

func execute_sell(ship: Ship, company: Company, town: Town, rule) -> Dictionary:
	if rule.action != "sell" or not town.market.has_good(rule.good_id):
		return {"qty": 0.0, "revenue": 0.0}
	# A ship cannot sell what it does not carry.
	var have: float = ship.cargo_qty(rule.good_id)
	if have <= 0.0:
		return {"qty": 0.0, "revenue": 0.0}
	var e: Market.Entry = town.market.get_entry(rule.good_id)
	# Respect the price limit (don't sell if the price is too low).
	if rule.price_limit > 0.0 and e.current_price < rule.price_limit:
		return {"qty": 0.0, "revenue": 0.0}
	# Only sell into a port that is short (stock below the threshold).
	var fillable: float = max(0.0, rule.threshold - e.stock)
	if fillable <= 0.0:
		return {"qty": 0.0, "revenue": 0.0}
	var qty: float = min(min(rule.max_qty, have), fillable)
	if qty <= 0.0:
		return {"qty": 0.0, "revenue": 0.0}
	var res: Dictionary = market_system.sell(town.market, rule.good_id, qty)
	var actual: float = float(res["qty"])
	var revenue: float = float(res["revenue"])
	ship.remove_cargo(rule.good_id, actual)
	town.market.fund -= revenue
	company.money += revenue
	ship.last_sell_revenue = revenue
	ship.lifetime_sell_revenue += revenue
	EventBus.trade_completed.emit(town.id, rule.good_id, actual, float(res["price"]))
	EventBus.message.emit("sold %.0f %s @ %.2f in %s (+%.1f)" %
			[actual, rule.good_id, float(res["price"]), town.name, revenue])
	return {"qty": actual, "revenue": revenue}

func execute_route(ship: Ship, company: Company, town: Town, route: TradeRoute) -> void:
	if not route.active:
		return
	ship.last_buy_cost = 0.0
	ship.last_sell_revenue = 0.0
	for r in route.rules_for(town.id):
		if r.action == "buy":
			execute_buy(ship, company, town, r)
		else:
			execute_sell(ship, company, town, r)

# --- Stage 4: player-driven trades ------------------------------------------
# These bypass the route rule book entirely: the player picks a good and a
# fixed quantity, and the trade executes at today's market price up to the
# hard physical limits (stock + affordability for buys; cargo held for sells).
# Money moves company <-> market.fund exactly as the auto trades do, so the
# money-conservation invariant is preserved.

func manual_buy(ship: Ship, company: Company, town: Town, good_id: String, qty: float) -> Dictionary:
	if qty <= 0.0 or not town.market.has_good(good_id):
		return {"qty": 0.0, "cost": 0.0, "price": 0.0}
	# Three hard caps: requested qty, free hold space, and (inside
	# market_system.buy) stock + affordability. Auto trades fold the hold cap
	# into their rule qty; here we apply it explicitly so the player can never
	# overload the ship by clicking Buy 10 with a near-full hold.
	var capped: float = min(qty, ship.cargo_free())
	if capped <= 0.0:
		EventBus.message.emit("hold full — cannot buy %s" % good_id)
		return {"qty": 0.0, "cost": 0.0, "price": float(town.market.get_entry(good_id).current_price)}
	var res: Dictionary = market_system.buy(town.market, good_id, capped, company.money)
	var actual: float = float(res["qty"])
	var cost: float = float(res["cost"])
	var price: float = float(res["price"])
	if actual <= 0.0:
		EventBus.message.emit("cannot buy %s in %s (no stock or no funds)" % [good_id, town.name])
		return {"qty": 0.0, "cost": 0.0, "price": price}
	company.money -= cost
	town.market.fund += cost
	ship.add_cargo(good_id, actual)
	ship.last_buy_cost = cost
	ship.lifetime_buy_cost += cost
	EventBus.trade_completed.emit(town.id, good_id, actual, price)
	EventBus.message.emit("bought %.0f %s @ %.2f in %s (-%.1f)" %
			[actual, good_id, price, town.name, cost])
	return {"qty": actual, "cost": cost, "price": price}

func manual_sell(ship: Ship, company: Company, town: Town, good_id: String, qty: float) -> Dictionary:
	if qty <= 0.0:
		return {"qty": 0.0, "revenue": 0.0, "price": 0.0}
	var have: float = ship.cargo_qty(good_id)
	if have <= 0.0:
		EventBus.message.emit("no %s in hold to sell" % good_id)
		return {"qty": 0.0, "revenue": 0.0, "price": 0.0}
	var res: Dictionary = market_system.sell(town.market, good_id, min(qty, have))
	var actual: float = float(res["qty"])
	var revenue: float = float(res["revenue"])
	var price: float = float(res["price"])
	if actual <= 0.0:
		return {"qty": 0.0, "revenue": 0.0, "price": price}
	ship.remove_cargo(good_id, actual)
	town.market.fund -= revenue
	company.money += revenue
	ship.last_sell_revenue = revenue
	ship.lifetime_sell_revenue += revenue
	EventBus.trade_completed.emit(town.id, good_id, actual, price)
	EventBus.message.emit("sold %.0f %s @ %.2f in %s (+%.1f)" %
			[actual, good_id, price, town.name, revenue])
	return {"qty": actual, "revenue": revenue, "price": price}
