class_name MarketSystem
extends RefCounted

## Price model + market transactions + external (regional) trade.
##
## Price:  price = base * exp(elasticity * (target - stock) / target)
## Shortage (stock < target) raises price; surplus lowers it. Clamped to
## [min_price, max_price]. target = max(TARGET_DAYS, daily_demand * TARGET_DAYS)
## so a good with high demand keeps a bigger buffer.
##
## Every buy/sell moves real stock and real money through [Market.fund]:
##   buy  -> stock down, buyer pays market.fund
##   sell -> stock up,   market.fund pays seller
## No transaction outside this class may touch [Entry.stock].

const ELASTICITY: float = 1.5
const TARGET_DAYS: float = 7.0
const EXT_IMPORT_BAND: float = 0.5   # import only on deep shortage (< 0.5 * target)
const EXT_EXPORT_BAND: float = 2.0   # export only on deep glut (> 2.0 * target)
const EXT_RATE: float = 0.05         # closes 5% of the gap per day (mild stabiliser)
const EXT_IMPORT_PRICE_MULT: float = 1.1
const EXT_EXPORT_PRICE_MULT: float = 0.9
# Tranche size for volume-weighted pricing. Each tranche is
# max(1.0, target * SLICE_FRAC) units; price is recalculated per tranche via
# calculate_price(e) AFTER previous tranches have moved e.stock. A trade that
# fits in one tranche (small qty vs target) pays the same flat price as before;
# a trade that drains/fills multiple tranches sees price rise/fall within the
# single transaction. Money conservation is preserved: total_cost =
# sum(tranche_qty * tranche_price), routed through market.fund exactly as before.
const SLICE_FRAC: float = 0.1
const MAX_TRANCHES: int = 1000   # safety cap; never hit in practice

func calculate_price(e: Market.Entry) -> float:
	var target: float = max(e.target_stock, 1.0)
	var ratio: float = (target - e.stock) / target
	var p: float = e.base_price * exp(ELASTICITY * ratio)
	return clamp(p, e.min_price, e.max_price)

func update_target(e: Market.Entry) -> void:
	e.target_stock = max(TARGET_DAYS, e.daily_demand * TARGET_DAYS)

func update_market(m: Market) -> void:
	# Recalculate targets + prices for every good at end of day.
	for v in m.entries.values():
		var e: Market.Entry = v
		update_target(e)
		e.current_price = calculate_price(e)
		e.price_history.append(e.current_price)
		if e.price_history.size() > 400:
			e.price_history.pop_front()

func external_trade(t: Town) -> void:
	# Regional trade with the wider Caribbean. Gentle stabiliser: closes 10% of
	# the gap to target per day, only outside the [0.7t, 1.5t] band, so local
	# supply/demand still drives prices inside the band. Import pays a 20%
	# premium, export takes a 20% discount — money leaves/enters via
	# [param external_balance].
	for v in t.market.entries.values():
		var e: Market.Entry = v
		var target: float = max(e.target_stock, 1.0)
		if e.stock < EXT_IMPORT_BAND * target:
			var qty: float = (target - e.stock) * EXT_RATE
			var price: float = e.current_price * EXT_IMPORT_PRICE_MULT
			e.stock += qty
			t.market.fund -= qty * price
			t.external_balance -= qty * price
		elif e.stock > EXT_EXPORT_BAND * target:
			var qty: float = (e.stock - target) * EXT_RATE
			qty = min(qty, e.stock)
			var price: float = e.current_price * EXT_EXPORT_PRICE_MULT
			e.stock -= qty
			t.market.fund += qty * price
			t.external_balance += qty * price

## Buy [param qty] of [param good_id] for a buyer who has [param buyer_money],
## optionally capped at [param max_price] per unit (0 = no cap). Stage 7.1:
## volume-weighted — the buy is split into tranches of SLICE_FRAC * target_stock
## (min 1 unit), and each tranche is priced via calculate_price(e) AFTER the
## previous tranche drained stock. So a buy that's small relative to the
## target buffer pays the same flat price as before; a buy that drains a
## noticeable fraction of stock pays a rising price within one transaction.
## Money conservation: total_cost = sum(tranche_qty * tranche_price); the
## caller routes that single sum through market.fund. Returns
## {"qty", "price" (volume-weighted average), "cost"} of the executed trade.
## Does NOT move money — the caller routes the cost through the right account.
func buy(m: Market, good_id: String, qty: float, buyer_money: float, max_price: float = 0.0) -> Dictionary:
	if not m.has_good(good_id) or qty <= 0.0:
		return {"qty": 0.0, "price": 0.0, "cost": 0.0}
	var e: Market.Entry = m.get_entry(good_id)
	if e.stock <= 0.0 or buyer_money <= 0.0:
		return {"qty": 0.0, "price": calculate_price(e), "cost": 0.0}
	var target: float = max(e.target_stock, 1.0)
	var slice: float = max(1.0, target * SLICE_FRAC)
	var remaining_qty: float = qty
	var remaining_money: float = buyer_money
	var total_qty: float = 0.0
	var total_cost: float = 0.0
	var n: int = 0
	while remaining_qty > 0.0 and e.stock > 0.0 and remaining_money > 0.0 and n < MAX_TRANCHES:
		var price: float = calculate_price(e)
		if price <= 0.0:
			break
		if max_price > 0.0 and price > max_price:
			break
		var tranche: float = min(min(remaining_qty, e.stock), slice)
		var affordable_now: float = remaining_money / price
		tranche = min(tranche, affordable_now)
		if tranche <= 0.0:
			break
		e.stock -= tranche
		total_qty += tranche
		total_cost += tranche * price
		remaining_money -= tranche * price
		remaining_qty -= tranche
		n += 1
	if total_qty <= 0.0:
		return {"qty": 0.0, "price": calculate_price(e), "cost": 0.0}
	return {"qty": total_qty, "price": total_cost / total_qty, "cost": total_cost}

## Sell [param qty] of [param good_id] into the market, optionally floored at
## [param min_price] per unit (0 = no floor). Stage 7.1: volume-weighted —
## each tranche of SLICE_FRAC * target_stock is priced via calculate_price(e)
## AFTER the previous tranche filled stock, so a sell that's small relative
## to target pays the same flat price; a sell that floods the market pays a
## falling price within one transaction. Money conservation: total_revenue =
## sum(tranche_qty * tranche_price). Returns {"qty", "price" (avg), "revenue"}.
## Market capacity is unbounded (surplus is handled by price collapse +
## external export, not by rejection), so the sell executes in full unless
## [param min_price] is hit — then it stops at the price floor.
func sell(m: Market, good_id: String, qty: float, min_price: float = 0.0) -> Dictionary:
	if not m.has_good(good_id) or qty <= 0.0:
		return {"qty": 0.0, "price": 0.0, "revenue": 0.0}
	var e: Market.Entry = m.get_entry(good_id)
	var target: float = max(e.target_stock, 1.0)
	var slice: float = max(1.0, target * SLICE_FRAC)
	var remaining: float = qty
	var total_qty: float = 0.0
	var total_revenue: float = 0.0
	var n: int = 0
	while remaining > 0.0 and n < MAX_TRANCHES:
		var price: float = calculate_price(e)
		if price <= 0.0:
			break
		if min_price > 0.0 and price < min_price:
			break
		var tranche: float = min(remaining, slice)
		if tranche <= 0.0:
			break
		e.stock += tranche
		total_qty += tranche
		total_revenue += tranche * price
		remaining -= tranche
		n += 1
	if total_qty <= 0.0:
		return {"qty": 0.0, "price": calculate_price(e), "revenue": 0.0}
	return {"qty": total_qty, "price": total_revenue / total_qty, "revenue": total_revenue}
