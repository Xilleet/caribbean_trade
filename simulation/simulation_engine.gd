class_name SimulationEngine
extends RefCounted

## Drives the tick loop. Owns the system instances and wires them into the
## daily/weekly ticks. Reads state only from the [WorldState] autoload and
## advances time via [SimulationClock] — it stores no economic state itself.

var market_system: MarketSystem
var production_system: ProductionSystem
var consumption_system: ConsumptionSystem
var finance_system: FinanceSystem
var population_system: PopulationSystem
var migration_system: MigrationSystem          # Stage B2b
var trade_system: TradeSystem
var event_system: EventSystem
var war_system: WarSystem               # Stage A3
var daily_tick: DailyTick
var weekly_tick: WeeklyTick
var ships_tick: ShipsTick

func _init() -> void:
	market_system = MarketSystem.new()
	production_system = ProductionSystem.new(market_system)
	consumption_system = ConsumptionSystem.new(market_system)
	finance_system = FinanceSystem.new()
	population_system = PopulationSystem.new()
	migration_system = MigrationSystem.new()
	trade_system = TradeSystem.new(market_system)
	event_system = EventSystem.new(WorldState.event_rng, WorldState.events_db)
	war_system = WarSystem.new(WorldState.war_rng)
	daily_tick = DailyTick.new(market_system, production_system, consumption_system,
			finance_system, WorldState.recipes)
	weekly_tick = WeeklyTick.new(population_system, finance_system, migration_system,
			WorldState.recipes, WorldState.rng)
	ships_tick = ShipsTick.new(trade_system, market_system)

func step_day() -> void:
	# snapshot each company's wallet at the start of the day, before any
	# ticks move money. The UI reads `money - last_day_money` on day_advanced to
	# show today's net delta — this is what makes the daily upkeep drain visible
	# instead of "money just decreases". No money moves here, no rng touched.
	for c in WorldState.companies:
		c.last_day_money = c.money
	# Town economy first (sets today's prices), then ships trade at those prices.
	for t in WorldState.towns:
		daily_tick.run(t)
		EventBus.town_updated.emit(t.id)
	ships_tick.run()
	# Stage 6: expire timed events at the END of the day, so today's ticks
	# always saw the full duration and an event added this week is active
	# tomorrow. (New events are added in step_week, called just below on the
	# week boundary.)
	event_system.decay_daily()
	SimulationClock.advance_day()
	EventBus.day_advanced.emit(SimulationClock.day)
	if SimulationClock.day_of_week() == 0:
		step_week()

func step_week() -> void:
	weekly_tick.reset_weekly()
	for t in WorldState.towns:
		weekly_tick.run(t)
	# Stage 6: roll new events AFTER the weekly economy ticks, so a
	# state-triggered famine sees this week's stock. Seeded (event_rng) so the
	# sequence is reproducible.
	event_system.roll_weekly()
	# Stage A3: war rolls AFTER event rolls, so war declarations see the
	# latest relations (which diplomatic incidents may have just shifted).
	war_system.roll_weekly()
	SimulationClock.advance_week()
	EventBus.week_advanced.emit(SimulationClock.week)

func run_days(n: int) -> void:
	for i in n:
		step_day()
