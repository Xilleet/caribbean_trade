class_name AIBrain
extends RefCounted

## Price-responsive decision engine for AI trading ships. Replaces the fixed
## data-route loop (TradeRoute.stops + predefined rules) with arbitrage logic
## driven by each company's [PriceMemory]: a captain only knows the prices they
## last saw, so they buy where they remember a good being cheap and sail to
## where they remember it being dear — and when their memory runs dry or no
## profit is in sight, they scout a stale port to refresh it.
##
## The brain only DECIDES; [method decide] returns {"trade": StopRule|null,
## "dest": town_id}. ShipsTick executes the trade (if any) via
## TradeSystem.execute_buy / execute_sell — the same money-conserving path the
## player's route trades use — then sails to [param dest]. One decide per dock,
## one trade per dock, one depart: no same-day trade loop. The brain never
## touches Market.Entry.stock or company.money directly, so total_money (drift)
## stays 0.
##
## Determinism: every choice is an argmax over memory estimates + port ids, with
## id-ascending tie-breaks and nearest-port-by-distance for exploration. No rng
## is read, so two runs at the same seed produce identical AI behaviour and the
## bit-stable rng streams (pirate / war / event) are untouched.

const MIN_MARGIN: float = 1.0   # est profit must clear this to bother trading

## Decide what [param ship] (docked at [param town]) should do on [param day].
## Returns {"trade": StopRule or null, "dest": town_id}:
##   - trade set + dest   → execute the trade here, then sail to dest
##   - trade null + dest  → just sail to dest (no profitable/possible trade here)
## The ship is assumed docked at [param town] with a real market in hand.
func decide(ship: Ship, company: Company, town: Town, day: int) -> Dictionary:
	var mem: PriceMemory = company.memory
	if mem == null:
		return {"trade": null, "dest": explore_dest(null, town, day)}

	# 1. Carrying cargo → liquidate at the best-known port. We know THIS port's
	# real prices (we're here); every other port is a memory estimate that may
	# be stale. If here is at least as good as anywhere we remember, sell now
	# rather than gamble on outdated info, then head to the next buy port.
	if ship.cargo_used > 0.1:
		var g: String = _top_cargo_good(ship)
		var here_price: float = _real_price(town, g)
		var best: Dictionary = _best_sell_port(mem, g, day, ship.flag_state, town.id)
		if here_price > 0.0 and (best.is_empty() or here_price >= float(best["price"])):
			return {"trade": _sell_rule(g, ship.cargo_qty(g), town), "dest": _empty_dest(mem, day, ship.flag_state, town)}
		if not best.is_empty():
			return {"trade": null, "dest": String(best["port"])}
		# Can't sell here and no known buyer → scout for one.
		return {"trade": null, "dest": explore_dest(mem, town, day)}

	# 2. Empty → best buy-low/sell-high leg from memory. Buy here if this is the
	# buy port (then sail to the sell port); otherwise sail to the buy port.
	var arb: Dictionary = _best_arbitrage(mem, day, ship)
	if not arb.is_empty() and float(arb["profit"]) > MIN_MARGIN:
		if String(arb["buy_port"]) == town.id:
			var est_buy: float = max(float(arb["est_buy"]), 1.0)
			var afford_qty: float = company.money / est_buy
			var qty: float = min(ship.cargo_free(), afford_qty)
			if qty > 0.5:
				var price_cap: float = float(arb["est_sell"]) * 0.90   # keep 10% margin vs est sell
				return {"trade": _buy_rule(String(arb["good"]), qty, price_cap), "dest": String(arb["sell_port"])}
			# can't afford even one unit → sail to the sell port to... no; scout
			return {"trade": null, "dest": explore_dest(mem, town, day)}
		return {"trade": null, "dest": String(arb["buy_port"])}

	# 3. No profitable leg in memory → scout the nearest stale/unknown port.
	return {"trade": null, "dest": explore_dest(mem, town, day)}

# --- helpers ---------------------------------------------------------------

## Destination for an empty ship: the buy port of the best arbitrage leg, or a
## scout port if none. (Used after a sell to send the now-empty ship for cargo.)
func _empty_dest(mem: PriceMemory, day: int, flag: String, from: Town) -> String:
	# _empty_dest is called after a sell with no ship in hand to score legs by;
	# it picks the buy port of the best NET-profitable leg. We don't have the
	# ship here (signature is historical), so we estimate with a per-unit gross
	# gate — a conservative proxy: any leg that clears gross is worth sailing
	# to for a fresh look at real prices. The full net-profit gate (upkeep,
	# duties) runs in _best_arbitrage once the ship is at the buy port.
	var arb: Dictionary = _best_arbitrage_gross(mem, day, flag)
	if not arb.is_empty() and float(arb["profit"]) > MIN_MARGIN:
		return String(arb["buy_port"])
	return explore_dest(mem, from, day)

func _top_cargo_good(ship: Ship) -> String:
	var best_g: String = ""
	var best_q: float = 0.0
	for gid in ship.cargo.keys():
		var q: float = float(ship.cargo[gid])
		if q > best_q or (q == best_q and (best_g == "" or String(gid) < best_g)):
			best_q = q
			best_g = String(gid)
	return best_g

func _real_price(town: Town, good_id: String) -> float:
	if town == null or town.market == null or not town.market.has_good(good_id):
		return 0.0
	return town.market.get_entry(good_id).current_price

## Best port (other than [param exclude]) to sell [param good] into, from memory.
## Returns {"port", "price"} (highest est price, id-ascending tie-break) or {}.
## Skips ports the [param flag] cannot dock at (enemy of an active war).
func _best_sell_port(mem: PriceMemory, good_id: String, day: int, flag: String, exclude: String) -> Dictionary:
	var best_port: String = ""
	var best_price: float = -1.0
	for tid in mem.known_towns(day):
		if tid == exclude:
			continue
		var t: Town = WorldState.get_town(tid)
		if not _dockable(flag, t):
			continue
		var est: Dictionary = mem.estimate(tid, good_id, day)
		if est.is_empty():
			continue
		var p: float = float(est["price"])
		if p > best_price or (p == best_price and tid < best_port):
			best_price = p
			best_port = tid
	if best_port == "":
		return {}
	return {"port": best_port, "price": best_price}

## Best buy-low/sell-high leg over all port pairs + goods, from memory, scored
## by NET profit per full cargo (audit #4: the old gate scored gross price
## difference per unit, so an AI would take a leg with +$2/unit spread that
## cost $320 in upkeep for the crossing and $X in customs — a losing voyage).
##
## Net profit of a full-cargo leg:
##   qty          = ship.cargo_capacity   (best case: full hold; AI buys as
##                                     much as it can afford, capped at hold)
##   gross        = (est_sell - est_buy) * qty
##   upkeep_cost  = trip_days(buy→sell) * ship.upkeep_daily
##   buy_duty     = est_buy * qty * tax_rate(buy_port)  * mult(buy, flag)
##   sell_duty    = est_sell * qty * tax_rate(sell_port) * mult(sell, flag)
##   net          = gross - upkeep_cost - buy_duty - sell_duty
## `net` is the leg's expected profit; the caller compares it to MIN_MARGIN.
## trip_days uses Euclidean distance / ship.speed (the same formula ShipsTick
## uses to advance the ship). Duties use each port's State.tax_rate, doubled
## when a foreign trader (flag != port's state) trades in a wartime port —
## mirroring TradeSystem._collect_customs. The AI does NOT predict pirate
## risk (a separate, probabilistic cost) — that remains a voyage hazard, not
## a planning input, matching the original design.
##
## Returns {"buy_port","good","sell_port","est_buy","est_sell","profit"(=net)}.
func _best_arbitrage(mem: PriceMemory, day: int, ship: Ship) -> Dictionary:
	var ports: Array = mem.known_towns(day)
	var best: Dictionary = {}
	var best_profit: float = MIN_MARGIN   # must strictly beat MIN_MARGIN to win
	var good_ids: Array = WorldState.goods.keys()
	good_ids.sort()
	var cap: float = ship.cargo_capacity
	for b in ports:
		var tb: Town = WorldState.get_town(String(b))
		if not _dockable(ship.flag_state, tb):
			continue
		for s in ports:
			if b == s:
				continue
			var ts: Town = WorldState.get_town(String(s))
			if not _dockable(ship.flag_state, ts):
				continue
			# Trip cost (upkeep) is per PAIR, not per good — precompute once.
			var trip_days: float = _est_trip_days(tb, ts, ship)
			var upkeep_cost: float = trip_days * ship.upkeep_daily
			var buy_tax: float = _duty_rate(tb, ship.flag_state)
			var sell_tax: float = _duty_rate(ts, ship.flag_state)
			for gid in good_ids:
				var eb: Dictionary = mem.estimate(String(b), String(gid), day)
				if eb.is_empty():
					continue
				var es: Dictionary = mem.estimate(String(s), String(gid), day)
				if es.is_empty():
					continue
				var est_buy: float = float(eb["price"])
				var est_sell: float = float(es["price"])
				var gross: float = (est_sell - est_buy) * cap
				var buy_duty: float = est_buy * cap * buy_tax
				var sell_duty: float = est_sell * cap * sell_tax
				var net: float = gross - upkeep_cost - buy_duty - sell_duty
				if net > best_profit:
					best_profit = net
					best = {"buy_port": String(b), "good": String(gid), "sell_port": String(s),
							"est_buy": est_buy, "est_sell": est_sell, "profit": net}
				elif net == best_profit and not best.is_empty():
					# deterministic tie-break: (buy_port, sell_port, good) ascending
					if [String(b), String(s), String(gid)] < [best["buy_port"], best["sell_port"], best["good"]]:
						best = {"buy_port": String(b), "good": String(gid), "sell_port": String(s),
								"est_buy": est_buy, "est_sell": est_sell, "profit": net}
	return best

## Gross-price arbitrage (per-unit spread), used only by _empty_dest which has
## no ship in hand to score a full-cargo net. A conservative proxy: any leg
## that clears gross > MIN_MARGIN is worth sailing to for a fresh price look;
## the net-profit gate runs in _best_arbitrage once the ship reaches the port.
func _best_arbitrage_gross(mem: PriceMemory, day: int, flag: String) -> Dictionary:
	var ports: Array = mem.known_towns(day)
	var best: Dictionary = {}
	var best_profit: float = MIN_MARGIN
	var good_ids: Array = WorldState.goods.keys()
	good_ids.sort()
	for b in ports:
		var tb: Town = WorldState.get_town(String(b))
		if not _dockable(flag, tb):
			continue
		for s in ports:
			if b == s:
				continue
			var ts: Town = WorldState.get_town(String(s))
			if not _dockable(flag, ts):
				continue
			for gid in good_ids:
				var eb: Dictionary = mem.estimate(String(b), String(gid), day)
				if eb.is_empty():
					continue
				var es: Dictionary = mem.estimate(String(s), String(gid), day)
				if es.is_empty():
					continue
				var profit: float = float(es["price"]) - float(eb["price"])
				if profit > best_profit:
					best_profit = profit
					best = {"buy_port": String(b), "good": String(gid), "sell_port": String(s),
							"est_buy": float(eb["price"]), "est_sell": float(es["price"]), "profit": profit}
				elif profit == best_profit and not best.is_empty():
					if [String(b), String(s), String(gid)] < [best["buy_port"], best["sell_port"], best["good"]]:
						best = {"buy_port": String(b), "good": String(gid), "sell_port": String(s),
								"est_buy": float(eb["price"]), "est_sell": float(es["price"]), "profit": profit}
	return best

# Estimated trip days between two towns for a ship. ShipsTick advances the
# ship by speed each day (minus a storm multiplier, which we ignore here as a
# probabilistic hazard), so days = ceil(distance / speed). At 1+ day this is
# the number of upkeep charges the voyage will cost.
func _est_trip_days(from: Town, to: Town, ship: Ship) -> float:
	var d: float = from.coords.distance_to(to.coords)
	return ceili(d / ship.speed) if ship.speed > 0.0 else 999.0

# Customs duty rate a ship flying [param flag] pays trading in [param town].
# Equals town's state tax_rate, doubled when a foreign trader (flag != port's
# state) trades in a wartime port — mirroring TradeSystem._collect_customs.
# Free ports (no state) and own-state ports pay base tax_rate; enemy wartime
# ports are unreachable (_dockable already filters them), so we never hit the
# 2× foreign-wartime branch in practice for enemy ports, but the 2× still
# applies for a foreign trader in a THIRD-party port at war with the flag's
# state (rare; handled for correctness).
func _duty_rate(town: Town, flag: String) -> float:
	if town == null:
		return 0.0
	var st: State = WorldState.get_state(town.state_id)
	if st == null:
		return 0.0
	var rate: float = st.tax_rate
	if flag != "" and flag != town.state_id and WorldState.at_war(flag, town.state_id):
		rate *= 2.0
	return rate

## Nearest town to [param from] whose memory is stale/missing (scout target).
## If all ports are fresh, the nearest OTHER town (a cruise re-exposes to
## current conditions). Distance tie-break by id-ascending. Never returns
## [param from] itself unless it is the only town in the world.
func explore_dest(mem: PriceMemory, from: Town, day: int) -> String:
	if from == null:
		# fallback: first town that isn't the player's (deterministic)
		for t in WorldState.towns:
			return t.id
		return ""
	var stale: Array = mem.unknown_or_stale_towns(_all_town_ids(), day) if mem != null else _all_town_ids()
	var candidates: Array = stale if stale.size() > 0 else _all_town_ids()
	var best_id: String = ""
	var best_d: float = -1.0
	for tid in candidates:
		if tid == from.id:
			continue
		var t: Town = WorldState.get_town(String(tid))
		if t == null:
			continue
		var d: float = from.coords.distance_squared_to(t.coords)
		if best_d < 0.0 or d < best_d or (d == best_d and String(tid) < best_id):
			best_d = d
			best_id = String(tid)
	if best_id == "":
		for tid in _all_town_ids():
			if tid != from.id:
				return String(tid)
		return from.id
	return best_id

func _all_town_ids() -> Array:
	var out: Array = []
	for t in WorldState.towns:
		out.append(t.id)
	out.sort()
	return out

## Can a ship flying [param flag] dock at [param town]? War blocks enemy colours.
func _dockable(flag: String, town: Town) -> bool:
	if town == null:
		return false
	var ps: String = town.state_id
	if ps == "":
		return true   # free port
	if flag == "" or flag == ps:
		return true
	return not WorldState.at_war(flag, ps)

func _sell_rule(good_id: String, qty: float, town: Town) -> TradeRoute.StopRule:
	var r := TradeRoute.StopRule.new()
	r.good_id = good_id
	r.action = "sell"
	r.max_qty = qty
	r.price_limit = 0.0   # sell to clear (we already chose this port as good)
	# Only fill the local shortage — don't dump into an oversupplied port and
	# crash its price. threshold = the good's target stock here.
	if town != null and town.market != null and town.market.has_good(good_id):
		r.threshold = town.market.get_entry(good_id).target_stock
	else:
		r.threshold = 0.0
	return r

func _buy_rule(good_id: String, qty: float, price_cap: float) -> TradeRoute.StopRule:
	var r := TradeRoute.StopRule.new()
	r.good_id = good_id
	r.action = "buy"
	r.max_qty = qty
	r.price_limit = price_cap
	r.threshold = 0.0   # buy regardless of local surplus (we came for this good)
	return r
