class_name State
extends RefCounted

## A colonial power (Spain / England / France / Netherlands). Owns towns
## (via [param Town.state_id]), collects customs tax on ship trades in its
## ports (treasury grows), and — later, A3 — can wage war, blockade ports,
## change taxes. For A1+A2 only the customs-tax mechanism is active: state
## treasuries accumulate and are included in [method WorldState.total_money],
## so the conservation invariant still holds when a fraction of every ship
## trade (buy + sell sides) flows company -> state.treasury.

var id: String
var name: String
var treasury: float = 0.0
var tax_rate: float = 0.0          # customs duty on ship trades (both sides)

func _init(p_id: String, p_name: String, p_treasury: float, p_tax: float) -> void:
	id = p_id
	name = p_name
	treasury = p_treasury
	tax_rate = p_tax
