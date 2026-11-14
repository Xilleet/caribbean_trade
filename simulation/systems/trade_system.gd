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

# Stage A2: customs duty on ship trades. Returns the tax amount collected
# and routes it company-side (caller already moved cost/revenue through
# market.fund). The caller subtracts the returned tax from company.money.
# Money flow: company.money -> state.treasury. state.treasury is in
# WorldState.total_money() so the conservation invariant holds.
#
# tax now SCALES with player_rep — at rep=0 base rate, at
# rep=-100 doubled (hostile trader pays double duty), at rep>=0 unchanged
# (no bonus below base). War tariff: a foreign trader (flag != port's
# state) in a wartime port pays double again (state_at_war) — own citizens
# (flag == port) are exempt, and enemy flags can't dock here at all
# (ShipsTick._can_dock blocks at_war(flag, port)). Trading also raises
# player_rep with the port's state (+0.5/trade) and with pirates (+1 if
# town is a pirate haven). AI companies do not earn rep — only the player.
func _collect_customs(town: Town, trade_value: float, company: Company, flag_state: String = "") -> float:
	var st: State = WorldState.get_state(town.state_id)
	if st == null or st.tax_rate <= 0.0 or trade_value <= 0.0:
		return 0.0
	# Stage A3: scale tax by player reputation (only for the player).
	var rep: float = WorldState.get_player_rep(st.id) if company != null and not company.is_ai else 0.0
	var tax_mult: float = 1.0 + max(0.0, -rep / 100.0)   # 1.0 at rep>=0, 2.0 at rep=-100
	# War tariff: foreign trader (flag != port) in a wartime port pays 2x.
	# Citizens (flag == port) pay normal; enemy flags never reach a trade
	# (_can_dock blocks them first). Money still routes to state.treasury.
	if flag_state != "" and flag_state != town.state_id and WorldState.state_at_war(town.state_id):
		tax_mult *= 2.0
	var tax: float = trade_value * st.tax_rate * tax_mult
	st.treasury += tax
	# Stage A3: trading builds player reputation. +0.5 with the port's state,
	# +1.0 with pirates if this town is a pirate haven (Tortuga historically).
	if company != null and not company.is_ai:
		WorldState.adjust_player_rep(st.id, 0.5)
		var haven_towns: Array = WorldState.pirates_db.get("pirate_attack", {}).get("haven_towns", [])
		if haven_towns.has(town.id):
			WorldState.adjust_player_rep("pirates", 1.0)
	return tax

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
	# Stage A2: reserve room for customs tax — pass money / (1 + tax_rate)
	# so the buy stops before exhausting the wallet, leaving enough to pay
	# the port tax that follows. With tax_rate=0 the divisor is 1 (no change).
	var eb_state: State = WorldState.get_state(town.state_id)
	var eb_tax_rate: float = eb_state.tax_rate if eb_state != null else 0.0
	var eb_money: float = company.money / (1.0 + eb_tax_rate) if (1.0 + eb_tax_rate) > 0.0 else company.money
	var res: Dictionary = market_system.buy(town.market, rule.good_id, qty, eb_money, rule.price_limit)
	var actual: float = float(res["qty"])
	var cost: float = float(res["cost"])
	company.money -= cost
	town.market.fund += cost
	var tax: float = _collect_customs(town, cost, company, ship.flag_state)   # Stage A2+A3
	company.money -= tax
	ship.add_cargo(rule.good_id, actual)
	ship.last_buy_cost = cost
	ship.lifetime_buy_cost += cost
	EventBus.trade_completed.emit(town.id, rule.good_id, actual, float(res["price"]))
	var tax_msg: String = ", tax %.1f" % tax if tax > 0.0 else ""
	EventBus.message.emit("bought %.0f %s @ %.2f in %s (-%.1f%s)" %
			[actual, rule.good_id, float(res["price"]), town.name, cost, tax_msg])
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
	var res: Dictionary = market_system.sell(town.market, rule.good_id, qty, rule.price_limit)
	var actual: float = float(res["qty"])
	var revenue: float = float(res["revenue"])
	ship.remove_cargo(rule.good_id, actual)
	town.market.fund -= revenue
	company.money += revenue
	var tax: float = _collect_customs(town, revenue, company, ship.flag_state)   # Stage A2+A3
	company.money -= tax
	ship.last_sell_revenue = revenue
	ship.lifetime_sell_revenue += revenue
	EventBus.trade_completed.emit(town.id, rule.good_id, actual, float(res["price"]))
	var tax_msg: String = ", tax %.1f" % tax if tax > 0.0 else ""
	EventBus.message.emit("sold %.0f %s @ %.2f in %s (+%.1f%s)" %
			[actual, rule.good_id, float(res["price"]), town.name, revenue, tax_msg])
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
	# Stage A2: reserve room for customs tax (same as execute_buy).
	var mb_state: State = WorldState.get_state(town.state_id)
	var mb_tax_rate: float = mb_state.tax_rate if mb_state != null else 0.0
	var mb_money: float = company.money / (1.0 + mb_tax_rate) if (1.0 + mb_tax_rate) > 0.0 else company.money
	var res: Dictionary = market_system.buy(town.market, good_id, capped, mb_money)
	var actual: float = float(res["qty"])
	var cost: float = float(res["cost"])
	var price: float = float(res["price"])
	if actual <= 0.0:
		EventBus.message.emit("cannot buy %s in %s (no stock or no funds)" % [good_id, town.name])
		return {"qty": 0.0, "cost": 0.0, "price": price}
	company.money -= cost
	town.market.fund += cost
	var tax: float = _collect_customs(town, cost, company, ship.flag_state)   # Stage A2+A3
	company.money -= tax
	ship.add_cargo(good_id, actual)
	ship.last_buy_cost = cost
	ship.lifetime_buy_cost += cost
	EventBus.trade_completed.emit(town.id, good_id, actual, price)
	var tax_msg: String = ", tax %.1f" % tax if tax > 0.0 else ""
	EventBus.message.emit("bought %.0f %s @ %.2f in %s (-%.1f%s)" %
			[actual, good_id, price, town.name, cost, tax_msg])
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
	var tax: float = _collect_customs(town, revenue, company, ship.flag_state)   # Stage A2+A3
	company.money -= tax
	ship.last_sell_revenue = revenue
	ship.lifetime_sell_revenue += revenue
	EventBus.trade_completed.emit(town.id, good_id, actual, price)
	var tax_msg: String = ", tax %.1f" % tax if tax > 0.0 else ""
	EventBus.message.emit("sold %.0f %s @ %.2f in %s (+%.1f%s)" %
			[actual, good_id, price, town.name, revenue, tax_msg])
	return {"qty": actual, "revenue": revenue, "price": price}
