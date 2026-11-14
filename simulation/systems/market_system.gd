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

## Buy [param qty] of [param good_id] for a buyer who has [param buyer_money].
## Limited by stock and by what the buyer can afford. Returns
## {"qty", "price", "cost"} of the actually executed trade. Does NOT move
## money — the caller routes the cost through the right account.
func buy(m: Market, good_id: String, qty: float, buyer_money: float) -> Dictionary:
	if not m.has_good(good_id) or qty <= 0.0:
		return {"qty": 0.0, "price": 0.0, "cost": 0.0}
	var e: Market.Entry = m.get_entry(good_id)
	var price: float = e.current_price
	var affordable: float = buyer_money / price if price > 0.0 else qty
	var actual: float = min(min(qty, e.stock), affordable)
	if actual <= 0.0:
		return {"qty": 0.0, "price": price, "cost": 0.0}
	e.stock -= actual
	return {"qty": actual, "price": price, "cost": actual * price}

## Sell [param qty] of [param good_id] into the market. Returns
## {"qty", "price", "revenue"}. Market capacity is unbounded in Stage 1
## (surplus is handled by price collapse + external export, not by rejection).
func sell(m: Market, good_id: String, qty: float) -> Dictionary:
	if not m.has_good(good_id) or qty <= 0.0:
		return {"qty": 0.0, "price": 0.0, "revenue": 0.0}
	var e: Market.Entry = m.get_entry(good_id)
	var price: float = e.current_price
	e.stock += qty
	return {"qty": qty, "price": price, "revenue": qty * price}
