class_name Town
extends RefCounted

## A town = population + market + industries. The town owns three money
## accounts: [param population_money] (aggregate wallet of residents),
## [param treasury] (taxes, unused in Stage 1) and the market's [param fund]
## stored on [Market]. Industries keep their own [param money].

var id: String
var name: String
var coords: Vector2 = Vector2.ZERO
var poor: float = 0.0
var middle: float = 0.0
var rich: float = 0.0
var population_money: float = 0.0
var market: Market
var industries: Array[Industry] = []
var treasury: float = 0.0
var development: float = 1.0
var satisfaction: float = 1.0
var external_balance: float = 0.0  # net money flow to/from the wider Caribbean
var port_capacity: float = 100.0
var state_id: String = ""        # Stage A2: which colonial power owns this town

func _init(p_id: String, p_name: String) -> void:
	id = p_id
	name = p_name
	market = Market.new()

func total_population() -> float:
	return poor + middle + rich

func labor_force() -> float:
	return (poor + middle) * 0.5
