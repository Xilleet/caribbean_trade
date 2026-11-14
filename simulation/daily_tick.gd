class_name DailyTick
extends RefCounted

## One simulation day, in the fixed order from the v0.1 plan:
##  1. population demand          (ConsumptionSystem.calculate_demand)
##  2. industry input demand + plan (ProductionSystem.calculate_input_demand)
##  3. industry buys inputs       (ProductionSystem.purchase_inputs)
##  4. production                 (ProductionSystem.produce)
##  5. population consumption     (ConsumptionSystem.consume_goods)
##  6. wages & maintenance        (FinanceSystem.charge_wages)
##  7. recalculate prices         (MarketSystem.update_market)
## All transactions in a day use yesterday's closing price; prices update at
## the end for tomorrow. This fixed order is what makes runs reproducible.
##
## Note: [method MarketSystem.external_trade] exists but is NOT called in
## Stage 1. Regional trade is the player's job (Stage 2 ships + routes). With
## it off, money is perfectly conserved and unobtainable goods simply show as
## shortage (high price) — the signal for where to trade.

var market_system: MarketSystem
var production_system: ProductionSystem
var consumption_system: ConsumptionSystem
var finance_system: FinanceSystem
var recipes: Dictionary

func _init(p_market: MarketSystem, p_prod: ProductionSystem, p_cons: ConsumptionSystem,
		p_fin: FinanceSystem, p_recipes: Dictionary) -> void:
	market_system = p_market
	production_system = p_prod
	consumption_system = p_cons
	finance_system = p_fin
	recipes = p_recipes

func run(t: Town) -> void:
	production_system.reset_daily_stats(t)
	consumption_system.calculate_demand(t)
	production_system.calculate_input_demand(t, recipes)
	production_system.purchase_inputs(t, recipes)
	production_system.produce(t, recipes)
	consumption_system.consume_goods(t)
	finance_system.charge_wages(t, recipes)
	market_system.update_market(t.market)
