extends Control

## Stage UI-1 HUD — the top bar: speed buttons + day/week clock + player money.
##
## Extracted from the monolithic game_ui.gd::_build_layout's top HBox. Reads
## state only from SimulationClock and WorldState (player company money),
## listens to EventBus.day_advanced for clock refresh, and forwards the only
## action it owns — speed tier — to the Main controller via set_speed. It does
## not touch the economy, so money conservation and determinism are
## unaffected.
##
## The four speed buttons are static (declared in hud.tscn) and wired here via
## @onready + pressed signals; the day/money labels are also static nodes. The
## highlight (active tier coloured yellow) recomputes on every day_advanced
## and after the player clicks a speed button — same cadence as before.

signal speed_changed(tier: int)

var _controller: Node = null
var _speed_buttons: Array[Button] = []

@onready var _day_label: Label = %DayLabel
@onready var _money_label: Label = %MoneyLabel
@onready var _pause_btn: Button = %PauseBtn
@onready var _speed1_btn: Button = %Speed1Btn
@onready var _speed2_btn: Button = %Speed2Btn
@onready var _speed3_btn: Button = %Speed3Btn

func _ready() -> void:
	# The HUD is a deep child of Main (Main -> GameUI -> Split -> Right -> HUD).
	# get_tree().current_scene is the main scene root (Main) — cleaner than
	# counting get_parent() hops, and stable if the scene tree is restructured
	# later (e.g. when GameController is introduced and Main stays the root).
	_controller = get_tree().current_scene
	_speed_buttons = [_pause_btn, _speed1_btn, _speed2_btn, _speed3_btn]
	# Static buttons declared in the scene; wire their pressed signals here so
	# the .tscn stays free of callables (and stays diff-friendly).
	_pause_btn.pressed.connect(_set_speed.bind(0))
	_speed1_btn.pressed.connect(_set_speed.bind(1))
	_speed2_btn.pressed.connect(_set_speed.bind(2))
	_speed3_btn.pressed.connect(_set_speed.bind(3))
	EventBus.day_advanced.connect(_on_day_advanced)
	# Apply the font/size/color overrides the old _mklabel/_mkbutton used, so the
	# HUD looks identical before and after the split. Doing it in code keeps the
	# .tscn lean and the .import-free font fallback path identical to before.
	_apply_theme()
	_render_clock()
	_render_money()
	_highlight_speed()

# Called by game_ui.gd when the player's ship docks (it pauses the clock and
# wants the active-tier highlight to follow). Same hook the old game_ui used.
func refresh() -> void:
	_highlight_speed()

# -------------------------------------------------------------------- private --

func _apply_theme() -> void:
	var f := UITheme.load_font()
	for b in _speed_buttons:
		b.add_theme_font_override("font", f)
		b.add_theme_font_size_override("font_size", 14)
	for l in [_day_label, _money_label]:
		l.add_theme_font_override("font", f)
		l.add_theme_font_size_override("font_size", 15)
	# Colors match the old _mklabel calls: day grey, money green.
	_day_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	_money_label.add_theme_color_override("font_color", Color(0.45, 0.9, 0.5))

func _set_speed(tier: int) -> void:
	_controller.call("set_speed", tier)
	speed_changed.emit(tier)
	_highlight_speed()

func _highlight_speed() -> void:
	var cur: int = int(_controller.call("get_speed"))
	for i in range(_speed_buttons.size()):
		var on: bool = (i == cur)
		_speed_buttons[i].add_theme_color_override("font_color",
				Color(1.0, 0.9, 0.2) if on else Color(0.75, 0.78, 0.82))

func _on_day_advanced(_day: int) -> void:
	_render_clock()
	_render_money()
	_highlight_speed()

func _render_clock() -> void:
	_day_label.text = "Day %d · Wk %d" % [SimulationClock.day, SimulationClock.week]

func _render_money() -> void:
	var co: Company = WorldState.get_company("player")
	if co == null:
		_money_label.text = "$ 0"
		_money_label.add_theme_color_override("font_color", Color(0.45, 0.9, 0.5))
		return
	_money_label.text = "$ %.0f" % co.money
	# C4 follow-up: colour-code the wallet by credit health.
	#   green  — solvent (money >= 0)
	#   yellow — in credit, but above half the floor (0 > money >= -limit/2)
	#   red    — deep in credit, approaching the -credit_limit game-over floor
	# (limit < 0 means deep in debt; -limit/2 is the halfway warning line.)
	# Bankrupt companies are frozen by SimulationEngine, so the red state here
	# is the last warning before the game-over modal (game_ui) fires.
	var color: Color
	if co.bankrupt:
		color = Color(0.95, 0.4, 0.4)
	elif co.money >= 0.0:
		color = Color(0.45, 0.9, 0.5)
	elif co.money >= -co.credit_limit() * 0.5:
		color = Color(1.0, 0.85, 0.3)
	else:
		color = Color(0.95, 0.4, 0.4)
	_money_label.add_theme_color_override("font_color", color)
