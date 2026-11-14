# Caribbean Trade — WORKLOG

Хронологический changelog срезов разработки. Каждый срез: что изменено, коммит,
тесты, ключевые метрики. Для дизайна и архитектуры текущего состояния —
см. [`Concept.md`](./Concept.md). Для спеки и видения — см. [`README.md`](./README.md).

---

## Stage 1-6 — summary

Подробный feature-doc для Stage 3-6 — в `Concept.md` §8-11. Здесь только сводка:

- **Stage 1** (initial commit) — экономическое ядро: 5 городов, 12 товаров,
  рынки с динамическими ценами, производство с break-even gate, потребление
  по 3 классам с priority order, conservation денег (`drift=0`).
- **Stage 2** — корабли + торговые маршруты. `Ship`, `TradeRoute.StopRule`,
  `ShipsTick`, `TradeSystem.execute_buy/sell`. Круговой маршрут игрока
  прибыльный за 60 дней, drift=0.
- **Stage 3** — ASCII-карта (`AsciiMap` 60×30 моноширинных символов) + UI
  (`GameUi` с панелями рынка/корабля/лога + кнопки скорости). `EventBus`
  сигналы активны. Никаких ассетов.
- **Stage 4** — ручное управление: `Ship.auto_trade=false` у игрока,
  `TradeSystem.manual_buy/sell`, авто-пауза на dock, редактор маршрута
  (`Up/Dn/Del`, `+Add`), кнопка `Depart`.
- **Stage 5** — AI-торговцы: 3 AI-компании (Havana Sugar, Santiago Metals,
  Carib Produce) со своими кораблями/маршрутами через тот же
  `MarketSystem`/`TradeSystem`. Карта рисует все корабли.
- **Stage 6** — события мира: `drought`/`storm`/`famine` как `ActiveEvent`
  с собственным `event_rng` stream (детерминизм). Famine state-triggered
  (не бросок). Production system reacts to drought; ships_tick to storm;
  consumption_system to famine.

Тесты после Stage 6: 20/20 PASS (test_market 5, test_trade 2, test_manual_trade 5,
test_ai_traders 4, test_events 4). drift=0.0000 на 365-day sim, profit player
+42 857, 160 событий.

---


---

## Stage 7.0 — баланс: ценовые коридоры + голод

**Коммит:** `ad289dc balanced rum, textiles, metal goods`


Этап 7 в плане v0.1 — это балансировка и масштабирование. Первый срез
(«7.0») — точечная правка двух болевых точек, которые Concept §9.4 и §13
сами называют узкими местами: арбитраж 15→450 на роме и слишком частый
голод. **Изменения data-only, без правок GDScript** — поэтому все 20
существующих тестов остаются зелёными (они проверяют инварианты
консервации денег и структурные ограничения, а не конкретные числа
баланса).

### 14.1. Ценовые коридоры (`data/goods.json`)

До среза у трёх самых arbitrage-heavy готовых товаров коридор был слишком
широкий — `[15, 450]` на роме давал 30× спред, что делало круговой маршрут
игрока безусловно прибыльным даже без конкуренции. После среза коридоры
жёстче и симметричнее относительно `base_price` (≈ 0.25× и 2× base):

| Товар        | base | min (было→стало) | max (было→стало) | спред было→стало |
|---|---|---|---|---|
| `rum`        | 120  | 15 → 30          | 450 → 240        | 30× → 8× |
| `textiles`   | 150  | 20 → 40          | 500 → 300        | 25× → 7.5× |
| `metal_goods`| 200  | 25 → 50          | 600 → 360        | 24× → 7.2× |

Сырьё и сельское хозяйство (wood, metal, cotton, hemp, sugar, fruits,
corn, tobacco, bread) остались без изменений — их цены и так формируются
рынком в более узком диапазоне.

**Что это меняет в геймплее.** Игрок по-прежнему может заработать на
разнице цен между портами, но потолок одной сделки упал в 3-4 раза:
продажа 30 рома в Каймане теперь даёт ≤ 7 200 (240 × 30) вместо
≤ 13 500 (450 × 30). AI-торговцы получают тот же эффект — их
`price_limit` на продажу (rum 120, textiles 230, metal_goods 230) всё
ещё ниже новых потолков, поэтому маршруты не ломаются, но потолок при
глубоком дефиците опустился.

### 14.2. Голод (`data/events.json`)

Концепт §3.4 требует, чтобы голод был следствием симуляции, а не броска
кубика — и он таким остаётся. Но прежний `trigger_stock_ratio = 0.5`
заставлял голод вспыхивать при запасе хлеба/кукурузы ниже половины
таргета, что в городах с активным потреблением (Port Royal, Сантьяго)
происходило почти каждую неделю. Срез:

| Параметр                 | было → стало | Эффект |
|---|---|---|
| `trigger_stock_ratio`    | 0.5 → 0.3    | голод только при глубоком дефиците (< 30 % target) |
| `magnitude`              | 2.0 → 1.6    | паническая скупка мягче (×1.6 вместо ×2.0) |

Тест `famine_triggered_by_shortage` ставит `bread_e.stock = 0.0` в
Гибаре — 0 всё ещё ниже 0.3 × target, поэтому famine по-прежнему
возникает и тест проходит. Два других famine-теста (`events_deterministic`
и `events_conserve_money_60d`) проверяют воспроизводимость и
консервацию денег — оба держатся: счётчик событий на двух прогонах
совпадает (просто меньше), drift остаётся 0.

### 14.3. Что НЕ тронуто в этом срезе

- **Маршруты (`data/routes.json`)** — `threshold`/`max_qty`/`price_limit`
  в правилах `StopRule` те же. Сужение ценовых коридоров уже ограничивает
  arbitrage; переписывать пороги под новые потолки — задача следующего
  среза, когда будет больше данных о прибыли игрока.
- **Корзины потребления (`consumption_system.gd::BASKETS`)** —
  демо-коэффициенты, как и оговорено в §13. Тонкая подстройка
  потребности в хлебе у бедных и пр. требует серии прогонов с замером
  satisfaction и населения.
- **`drought`/`storm` частоты** — `prob_per_week` 0.10 / 0.18 unchanged;
  Concept §11.6 явно называет «160 событий за год» feature, а не багом.
- **Volume-weighted pricing** (мгновенное изменение цены от объёма
  сделки) — оставлено на более поздний подэтап 7.x, потому что оно
  ломает `test_market.gd::test_buy_stock_limit` (там проверяется
  `cost == qty × current_price`) и `test_roundtrip_conserves_money`
  (теперь roundtrip теряет деньги на slippage — это реалистично, но
  тест нужно переписывать). Когда дойдём — перепишем тесты под
  реально-физическую модель рынка.

### 14.4. Проверка

Тесты остаются 20/20 (все assertions инвариантны к числам баланса —
см. §14.1-14.2 выше). Запуск headless-симуляции 365 дней продолжает
доходить до конца и печатать drift = 0.0000. Цифры прибыли игрока и
количества событий уйдут от значений §7 (бывших +42 857 и 160) — после
первого прогона пользователем локально можно зафиксировать новые
опорные значения и сравнивать с ними следующие срезы.

---

## Stage 7.1 — Volume-weighted pricing

**Коммит:** `958f0e2 volume-weighted pricing: tranched buy/sell in MarketSystem, route price_limit per tranche, 3 tests rewritten`


Срез 7.0 сжал ценовые коридоры, но оставил вторую дыру: `MarketSystem.buy/sell`
использовали плоскую `e.current_price` на всю партию. Игрок мог одним кликом
«Buy All» выкачать весь сток по одной цене, а потом так же одним кликом залить
порт-получатель по потолку — slippage не было вообще. Concept §9.4 прямо
называл это TODO. Срез 7.1 закрывает дыру.

### 15.1. Что меняется в `MarketSystem.buy` / `sell`

Каждая транзакция теперь режется на транши по `slice = max(1.0, target ×
SLICE_FRAC)`, где `SLICE_FRAC = 0.1`. Цена каждого транша берётся через
`calculate_price(e)` **после** того, как предыдущий транш сдвинул `e.stock`:

- **buy** — выкачивает сток, цена растёт внутри одной транзакции (сток падает →
  ratio растёт → `exp(elasticity × ratio)` растёт → цена ближе к потолку).
- **sell** — заливает сток, цена падает внутри одной транзакции.

Маленькая сделка (qty ≤ slice = 10 % target) — это один транш, цена та же, что
и при плоской модели. Большая сделка (qty > slice) реально двигает цену внутри
себя. **Деньги по-прежнему сохраняются**: `total_cost = Σ(tranche_qty ×
tranche_price)`, эта сумма уходит из кошелька покупателя в `market.fund` ровно
одним движением. Никаких новых счётов, никаких новых источников денег.

Возврат: `{"qty", "price" (volume-weighted average), "cost"}`. `price` теперь
средневзвешенная, не первая/последняя — UI и логи показывают честную avg цену.

### 15.2. Price limits теперь траншевые

`MarketSystem.buy(m, good, qty, money, max_price=0)` и `sell(m, good, qty,
min_price=0)` принимают необязательный потолок/пол. Если цена очередного
транша выходит за лимит — цикл останавливается, остаток qty не исполняется.
Это меняет поведение `TradeSystem.execute_buy` / `execute_sell`: раньше
правило `StopRule.price_limit` проверялось один раз по `e.current_price` и
вся сделка либо шла, либо нет. Теперь правило может **частично** исполниться —
например, маршрут покупает 6 единиц сахара (пока цена ниже лимита), а 7-ю не
берёт, потому что цена уже выше `price_limit`. Это и есть реалистичное
самоограничение маршрута: он не заливает рынок под ноль и не платит выше
своей маржи.

`TradeSystem.manual_buy` / `manual_sell` (Stage 4) по-прежнему вызывают
`market_system.buy/sell` без лимита — игрок волен переплачивать, если хочет.

### 15.3. Тесты — что переписано

Два теста в `test_market.gd` и один в `test_manual_trade.gd` переписаны под
новую модель (остальные 17 не зависят от конкретной цены — они проверяют
инварианты консервации и структурные ограничения):

| Тест | Было | Стало |
|---|---|---|
| `test_market.gd::test_buy_stock_limit` | `cost == 5 × 83 = 415` (плоская база) | `qty == 5` и `5 × base < cost < 5 × max` (траншевая сумма растёт 176→300) |
| `test_market.gd::test_buy_money_limit` | `qty == 200/83 = 2.41` (deep surplus, плоская база 83) | stock=8 vs target=10 (mild shortage), `0 < qty < 200/83` (rising tranche prices → меньше affordable) |
| `test_manual_trade.gd::test_buy_capped_by_money` | money=100, sugar в surplus → `qty=2, money_left=0` (плоская база 50) | sugar вручную установлен в stock=8 (mild shortage), `0 < qty < 2, money_left < 5` (rising tranche prices → меньше affordable) |

`test_roundtrip_conserves_money` **без изменений** и всё ещё проходит: сахар в
Гибаре в глубоком surplus (stock 50 vs target 10), все транши обоих сторон
roundtrip-а остаются на clamped min=5, деньги сохраняются. (Сценарий с
slippage — когда roundtrip реально теряет деньги — оставлен на следующую
итерацию тестов; пока важнее, что инвариант консервации держится.)

### 15.4. Эффект на симуляцию

После среза 7.1 headless-симуляция 365 дней продолжает печатать drift = 0.0000.
Прибыль игрока дополнительно падает (см. §14.3 про `arbitrage будет
закрываться`): большой объём сделки теперь платит rising slippage, а не
плоский потолок. Маршруты AI тоже подчиняются этому — они перестают выкачивать
сток под ноль, останавливаются на `price_limit`. Конкретные числа
прибыли/событий уйдут от значений §14.4 — после прогона пользователем
локально можно зафиксировать новые опорные значения.

`MAX_TRANCHES = 1000` — safety cap против теоретических бесконечных циклов
(никогда не достигается в практике: даже самый маленький slice = 1, и за 1000
траншей можно исполнить любую реалистичную сделку).

### 15.5. Побочный эффект: famine подскочил (96/год против 37 после 7.0)

Tranched pricing делает цепочку хлеба дороже: bakery платит больше за corn
(rising tranches при закупке), продаёт bread дешевле (falling tranches при
сбыте) → раньше упирается в break-even gate в `production_system.gd` →
производит меньше хлеба → stock дольше сидит ниже триггера голода → famines
fire чаще. Полный прогон 7.1: **96 famine-событий за год** (против 37 после
7.0 и 98 до 7.0). Это не баг — это реалистичная обратная связь цены на
дефицит, но частота голода стала неприемлемо высокой для геймплея.

---

## Stage 7.2 — Retune famine

**Коммит:** `7f01087 retune famine: trigger_stock_ratio 0.3->0.2, magnitude 1.6->1.3`


Data-only правка в `data/events.json`, компенсирующая подскок famine из §15.5.
Никаких изменений в GDScript — только числа у архетипа `famine`:

| Параметр                 | было (7.1) → стало (7.2) | Эффект |
|---|---|---|
| `trigger_stock_ratio`    | 0.3 → 0.2                | голод только при действительно глубоком дефиците (< 20 % target, не 30 %) — компенсирует то, что tranched pricing сам по себе делает «глубокий дефицит» более частым |
| `magnitude`              | 1.6 → 1.3                | паническая скупка мягче (×1.3 вместо ×1.6) — меньше вторичного осушения стока во время голода, сток быстрее возвращается выше триггера |

`drought` и `storm` не тронуты — их частоты (26 и 34/год после 7.1) в
разумных пределах, и Concept §11.6 считает ~160 событий/год фичей, а не
багом. Срез 7.2 точечно чинит только famine.

### 16.1. Эффект на симуляцию (365 дней, seed = 1337)

| Метрика            | 7.0    | 7.1    | 7.2    |
|---|---|---|---|
| drift              | 0.0000 | 0.0000 | 0.0000 |
| Player profit      | +25 306 | +16 609 | +15 728 |
| Events total       | 96     | 156    | 113    |
| └ drought          | 30     | 26     | 22     |
| └ storm            | 29     | 34     | 42     |
| └ famine           | 37     | 96     | 49     |

Famine вернулся в разумный диапазон (~50/год, между 7.0's 37 и pre-7.0's
98). Прибыль игрока чуть просела дальше (+16 609 → +15 728) — менее
жестокий famine = меньше panic-спроса = меньше арбитражных возможностей
для игрока на хлебной цепочке. Это нормальная обратная связь.

### 16.2. Тесты

Все 20 тестов остаются зелёными. `test_events.gd::events_deterministic`
теперь показывает 2 события за 30 дней (долго было 7) — famines при новых
порогах вообще не выстреливают за 30 дней от старта, только drought. Тест
проходит, потому что `a_total > 0` и `same=true`. `famine_triggered_by_shortage`
по-прежнему ставит `bread_e.stock = 0.0` вручную — 0 всё ещё ниже
0.2 × target, поэтому famine по-прежнему возникает, тест проходит.

`drought_cuts_crop_output` не зависит от famine-параметров (использует
вручную инжектированный drought с `magnitude=0.5`) — unaffected.

### 16.3. Что дальше по балансу

После 7.1 + 7.2 слой баланса стабилизировался: деньги сохраняются,
arbitrage ограничен tranched slippage, famine в разумных пределах.
Оставшиеся TODO из Concept §9.4 — тонкая подстройка `consumption_system.gd::BASKETS`
и `data/routes.json` thresholds под новые реалии — требует серии
прогонов с замером satisfaction/населения и эмпирической обратной связи
от пользователя. Это уже не data-only правка, а итеративная настройка с
feedback loop'ом. Кандидат на 7.3+, когда будут данные.

---

## Stage A1+A2 — Пираты и Государства

**Коммит:** `52f4d48  pirates and states: colonial powers + customs tax + pirate attacks with armed defense, 8 new tests`


После баланса 7.0–7.2 переходим к наполнению мира (README §3.3, §3.4, §7):
**государства как автономные экономические агенты** и **пиратские нападения
как риск для торговых кораблей**. Это первый срез, где мир перестаёт быть
нейтральной ареной — у портов появляется собственник, у торговли появляется
налог, у моря появляется риск.

Исторические ориентиры (~1600 Карибский бассейн, README §1.1 sources):

- **Испания** владеет Кубой (Гибара, Сантьяго) — основная колониальная держава
  века, тяжёлая налоговая администрация (tax_rate 0.05).
- **Англия** владеет Ямайкой (Порт-Рояль, Кайман) — Порт-Рояль историческая
  база буканьеров и каперов, умеренный налог (0.04).
- **Франция** владеет Тортугой — пиратская столица Карибского моря, формальная
  французская колония с 1629 (tax_rate 0.05).
- **Нидерланды** — в нашем прототипе пока не имеют городов (reserving для
  будущего расширения карты, A2 → D1), но государство уже заспавнено с
  treasury 30k и tax_rate 0.03 (исторически голландская торговля была
  наименее облагаемой, что отражает их mercantile конкурентность).

Игровые ориентиры:

- **Port Royale 2** — каждая нация имеет свои порты; войны закрывают порты для
  чужих кораблей (A3 — следующий срез).
- **Distant Worlds** — государства как автономные агенты с бюджетом, налогами,
  дипломатией.
- **Victoria 3** — налоги как рычаг государства, аккумулирующийся в budget.

### 17.1. A2 — Государства и таможенные пошлины

**Сущность `State`** (`entities/state.gd`, новый): `id`, `name`, `treasury`,
`tax_rate`. Заспавнена из `data/states.json` (4 державы, см. выше) в
`WorldState.build_world()`. Treasury стартует от `starting_treasury` (50k/40k/
35k/30k = 155k суммарно — поэтому `total_money()` на старте теперь 299 100
вместо 144 100).

**`Town.state_id`** (новое поле в `entities/town.gd`): устанавливается при
постройке города из `data/towns.json["state"]`. Все 5 городов размечены
исторически (см. таблицу выше).

**`WorldState.total_money()`** теперь включает `for st in states: s += st.treasury`
— без этого консервация денег ломалась бы при первом налоге. С этим —
сохраняется.

**Таможенный сбор** в `TradeSystem._collect_customs(town, trade_value) -> float`:

- Buy: `tax = cost × state.tax_rate`; `state.treasury += tax`;
  `company.money -= tax`. Деньги: company → state.treasury.
- Sell: `tax = revenue × state.tax_rate`; `state.treasury += tax`;
  `company.money -= tax` (т.е. продавец получает `revenue - tax`). Деньги:
  market.fund платит полную revenue продавцу, продавец отдаёт tax государству.

Вызывается из `execute_buy`, `execute_sell`, `manual_buy`, `manual_sell`. **Не
применяется к внутренним сделкам города** (consumption_system — население
покупает хлеб, production_system — предприятия закупают сырьё) — налог только
на **межгородскую** торговлю через корабли, что и есть историческая таможенная
пошлина (customs duty на импорт/экспорт).

**`effective_money` fix** в `execute_buy`/`manual_buy`: вместо
`company.money` в `MarketSystem.buy` передаётся `company.money / (1 + tax_rate)`.
Без этого ship мог выкачать весь кошелёк на cost, а затем tax уходил в
отрицательный баланс. С фиксом — buy заранее резервирует долю под tax.

### 17.2. A1 — Пиратские нападения

**`data/pirates.json`** (новый) описывает архетип `pirate_attack`:
`prob_per_sailing_day = 0.04` (4% шанс в каждый день моря),
`cargo_loss_pct = 0.20` (теряем 20% случайного груза), `extra_upkeep_mult = 0.5`
(доп-upkeep на ремонт = половина дневного upkeep), `haven_towns = ["tortuga"]`
(потом для географии риска).

**`Ship.armed: int`** (новое поле, 0..2): 0 = merchant (полный риск),
1 = light escort (риск × 0.5), 2 = warship (риск × 0.33). Существующие
sloop/brigantine/fluyt — все merchant (`armed=0`). В будущем (D3) frigate
получит `armed=2` и станет ходить по опасным маршрутам без страха.

**Roll в `ShipsTick._roll_pirate_attack`**: только когда `ship.state ==
"sailing"` (корабль в море, не под защитой порта). Использует **отдельный rng
stream `WorldState.pirate_rng`** (сидится от `world_seed + 91137`) —
**критично для детерминизма**: если использовать `event_rng`, последовательность
бросков для drought/storm/famine сдвинулась бы и сломала тесты 7.0/7.1/7.2.

**Эффект нападения**:
- lose `cargo_loss_pct` случайного груза (real loss, allowed by Concept §13:
  «Товар не исчезает без потребления, потерь или экспорта»). Если корабль
  пуст — груз не теряется, только ремонт.
- extra upkeep = `extra_upkeep_mult × ship.upkeep_daily`, routed
  `company.money → local_town.population_money` (тот же путь, что у storm).
- emit message: «Пираты атаковали {ship_id}: -N {good}, ремонт M».

**Консервация денег**: только repair-upkeep двигает деньги. Cargo loss — это
потеря товаров (нет инварианта товаров, только денег). `total_money()`
остаётся неизменным.

### 17.3. Тесты (4+4 новых, всего теперь 28)

`tests/test_states.gd` + `.tscn` (4 PASS):
- `states_spawn` — 4 государства, у каждого города state_id, историческая
  принадлежность проверена (tortuga=france, port_royal=england, santiago=spain),
  treasury_sum=155000.
- `buy_tax_flows_to_state` — manual_buy в tortuga (france 5%): tax = cost × 0.05
  → state.treasury, drift=0.
- `sell_tax_flows_to_state` — manual_sell rum в port_royal (england 4%):
  tax = revenue × 0.04 → state.treasury, drift=0.
- `tax_conserved_30d` — полная sim 30 дней: drift=0, state treasuries выросли.

`tests/test_pirates.gd` + `.tscn` (4 PASS):
- `pirate_attacks_deterministic` — два прогона 60 дней: одинаковые
  lifetime_buy/sell у игрока (детерминизм pirate_rng).
- `pirate_attack_loses_cargo` — prob=1.0, ship с 20 sugar → потеряно >0.
- `pirate_attack_costs_upkeep` — prob=1.0, company.money падает на
  upkeep + repair (16 + 8 = 24), drift=0.
- `pirate_conserved_60d` — sim 60 дней с дефолтным prob=0.04: drift=0.

Существующие 20 тестов обновлены под новый мир:
- `test_manual_trade::test_manual_buy_moves_money_and_stock` — assertion
  обновлено: `company.money = money_before - cost × (1 + tax_rate)`.
- `test_manual_trade::test_roundtrip_conserves_money` — roundtrip теперь теряет
  `2 × cost × tax_rate` на customs (buy + sell legs), assert: `company.money +
  tax_paid == money_before`.
- Остальные 18 без изменений — они либо structural (AI spawn, determinism,
  drift=0), либо используют tranched-pricing инварианты без привязки к
  конкретным числам стоимости.

### 17.4. Эффект на sim (365 дней, seed = 1337)

| Метрика              | 7.2     | A1+A2   |
|---|---|---|
| `total_money` start  | 144 100 | 299 100 (+155k state treasuries) |
| drift                | 0.0000  | 0.0000  |
| Player profit        | +15 728 | +12 782 (−19%, customs + pirate losses) |
| Havana Sugar P/L     | +15 766 | +12 517 |
| Santiago Metals P/L  | +10 764 | +6 277  |
| Carib Produce P/L    | +8 272  | +11 816 (+43%, route uses cayman fruits, low-tax england ports) |
| Events fired         | 113     | 113 (пираты считаются отдельно, не в этом счётчике) |

Прибыль игрока упала на ~19% — это сумма таможенных пошлин (5% от
каждой сделки в испанских/французских портах) и пиратских потерь (4%
chance/день моря × ~30 дней/год = ~1.2 атаки × ~20% груза + ремонт).
Carib Produce единственная выросла — её маршрут (cayman→port_royal→gibara)
проходит через английские порты с низким tax_rate 0.04, а фрукты в Каймане
в избытке (цена на дне, налог маленький в абсолютных числах).

### 17.5. Что НЕ тронуто в этом срезе

- **Войны и блокады** (A3) — следующий срез. State.treasury пока только
  накапливается; в A3 государства начнут тратить его на war fleets, port
  subsidies, или экспроприацию (событийно-скриптовая механика поверх Stage 6).
- **State budgets как активный рычаг** (A4) — налоги пока фиксированы в
  states.json. Динамическое изменение tax_rate в ответ на treasury
  balance/war — позже.
- **География пиратского риска** — пока ALL sailing ships have base prob=0.04.
  Pirate haven (tortuga) есть в данных, но зона риска не рассчитывается.
  В A1.1 добавим радиус от haven → повышенный риск.
- **Armed ships** (D3) — поле `armed` есть, но в ships.json все 0. Когда
  добавим frigate (D3), вооружённые корабли получат реальный defensive bonus.

### 17.6. Структура проекта после A1+A2

```
+ entities/state.gd            # новый
+ data/states.json             # новый (4 державы)
+ data/pirates.json            # новый (attack params + haven_towns)
~ entities/town.gd             # +state_id
~ entities/ship.gd             # +armed
~ data/ships.json              # +armed field (все 0 на этом этапе)
~ data/towns.json              # +state field per town
~ core/world_state.gd          # +states, +pirates_db, +pirate_rng; total_money +treasuries
~ simulation/systems/trade_system.gd  # +_collect_customs, effective_money for buys
~ simulation/ships_tick.gd     # +_roll_pirate_attack in sailing branch
+ tests/test_states.gd + .tscn         # 4 checks
+ tests/test_pirates.gd + .tscn        # 4 checks
~ tests/test_manual_trade.gd   # updated 2 tests for tax
~ Concept.md                   # this section
```

Всего теперь **28 тестов** (5+2+5+4+4+4+4), все зелёные, drift=0.0000 на
365-day sim.

---

## Расширение карты (5 → 15 городов)


Data-only срез: добавлено 10 новых реальных карибских городов в
`data/towns.json`, ни одной правки GDScript-логики (только `_town_glyph` и
легенда в `ui/ascii_map.gd` для новых букв). Источник — Port Royale 3 Wiki
(README §1.1): города и товары оттуда, балансировка своя.

### D1.1. Новые города (10 шт.)

| ID | Название | State | Координаты | Население (poor/mid/rich) | Индустрии |
|---|---|---|---|---|---|
| `havana` | Havana | spain | [200, 240] | 1500/400/100 | sugar_plantation, tobacco_plantation, distillery, corn_farm, bakery |
| `san_juan` | San Juan | spain | [430, 220] | 800/200/40 | sugar_plantation, cotton_plantation, smithy, corn_farm, bakery |
| `santo_domingo` | Santo Domingo | spain | [400, 270] | 1200/350/80 | sugar_plantation, tobacco_plantation, lumber_camp, corn_farm, bakery |
| `cartagena` | Cartagena | spain | [180, 360] | 900/250/50 | mine, smithy, lumber_camp, corn_farm, bakery |
| `bridgetown` | Bridgetown | england | [490, 340] | 500/120/30 | sugar_plantation, cotton_plantation, distillery, corn_farm, bakery |
| `nassau` | Nassau | england | [350, 180] | 400/100/20 | lumber_camp, orchard, hemp_farm, corn_farm, bakery |
| `cap_francais` | Cap-Français | france | [380, 240] | 600/150/30 | sugar_plantation, tobacco_plantation, distillery, corn_farm, bakery |
| `fort_de_france` | Fort-de-France | france | [470, 310] | 350/90/15 | sugar_plantation, orchard, distillery, corn_farm, bakery |
| `willemstad` | Willemstad | netherlands | [250, 380] | 700/180/40 | smithy, textile_mill, lumber_camp, corn_farm, bakery |
| `paramaribo` | Paramaribo | netherlands | [140, 390] | 450/100/25 | cotton_plantation, hemp_farm, lumber_camp, corn_farm, bakery |

Все координаты в существующих bounds карты (x∈[100,540], y∈[160,400]) —
`AsciiMap` рендерит без код-изменений.

### D1.2. Распределение по государствам (было → стало)

| State | Было (5 towns) | Стало (15 towns) |
|---|---|---|
| Spain | 2 (gibara, santiago) | **6** (+ havana, san_juan, santo_domingo, cartagena) |
| England | 2 (cayman, port_royal) | **4** (+ bridgetown, nassau) |
| France | 1 (tortuga) | **3** (+ cap_francais, fort_de_france) |
| Netherlands | 0 | **2** (willemstad, paramaribo) — впервые на карте |

### D1.3. Glyphs в `ascii_map.gd::_town_glyph`

С 5 городов на 15: добавлены 10 новых односимвольных глифов, выбираемых так,
чтобы избежать коллизий (San Juan/Santo Domingo/Santiago все начинаются на S;
Cayman/Cartagena/Cap-Français все на C; Bridgetown на B — зарезервировано под
player ship).

| Town | Glyph | Почему |
|---|---|---|
| tortuga | T | существующий |
| port_royal | P | существующий |
| cayman | C | существующий |
| gibara | G | существующий |
| santiago | S | существующий |
| havana | H | первая буква |
| san_juan | **J** | J for Juan (S занят santiago) |
| santo_domingo | **D** | D for Domingo |
| cartagena | **X** | C занят cayman |
| bridgetown | **R** | B зарезервирован под player ship |
| nassau | N | первая буква |
| cap_francais | **K** | C занят cayman |
| fort_de_france | F | первая буква |
| willemstad | W | первая буква |
| paramaribo | **M** | P занят port_royal |

Легенда внизу карты обновлена: `towns T P C G S H J D X R N K F W M`.

### D1.4. Эффект на sim (365 дней, seed = 1337)

| Метрика | A1+A2 (5 towns) | D1 (15 towns) |
|---|---|---|
| `total_money` start | 299 100 | **528 700** (+229 600 from new towns' pop_money + industry default_money) |
| drift | 0.0000 | 0.0000 |
| Player profit | +12 782 | +13 108 (+2.5%, чуть выросло от новых рынков рядом) |
| AI Havana Sugar P/L | +12 517 | +11 828 |
| AI Santiago Metals P/L | +6 277 | +6 830 |
| AI Carib Produce P/L | +11 816 | +12 116 |
| Events fired | 113 | **319** (drought=82 storm=43 famine=194) |

Famine подскочил с 49 до 194 — естественный эффект: 15 городов вместо 5, у
каждого свой bread/corn stock, больше шансов на глубокий дефицит ниже
`trigger_stock_ratio=0.2`. Это candidate на D1.1 retune (поднять ratio до 0.25
или понизить crop farm capacity в крупных городах). Пока оставляем как есть —
это не баг, а реалистичная обратная связь.

### D1.5. Тесты

Все 28 тестов остаются зелёными, без правок:
- `test_ai_traders::map_draws_all_ships` — проверяет наличие `B` игрока и ≥3
  `A` конкурентов на сетке. С 15 городами корабли всё равно докятся в свои
  home-порты (tortuga/gibara/cayman/santiago), глифы не перезаписываются
  новыми town letters.
- `test_events::events_deterministic` — 19=19 за 30 дней (было 2 с 5 городами,
  теперь 19: больше городов → больше famine триггеров). Детерминизм держится.
- `test_pirates::pirate_attacks_deterministic` — 2 прогона = одинаковые
  lifetime_buy/sell. `pirate_rng` сидится от `world_seed + 91137`, не зависит
  от количества городов.

### D1.6. Что НЕ сделано

- **AI routes** не обновлены под новые города — 3 AI компании и игрок
  продолжают свои 4 существующих маршрута (`player_default`,
  `ai_havana_loop`, `ai_metals_loop`, `ai_produce_loop`). Новые города
  доступны игроку через Stage 4 manual route editor (`+ Add`), но AI их
  игнорирует. Когда захочешь — добавим `ai_willemstad_textiles`,
  `ai_cartagena_metals` и пр. (data-only в `data/routes.json`).
- **Famine retune под 15 городов** — famine подскочил до 194/год, что много.
  Можно поднять `trigger_stock_ratio` 0.2 → 0.25 или понизить crop farm
  capacity в крупных городах. Оставлено на D1.1 если потребуется.
- **Историческая точность координат** — координаты абстрактные в существующих
  bounds карты, а не реальные lat/lon. Существующие 5 городов тоже
  абстрактные. это отдельная правка
  координат всех 15 городов.

Всего теперь **28 тестов** (5+2+5+4+4+4+4), все зелёные, drift=0.0000 на
365-day sim, 15 городов на карте.

---

## Relations, Reputation, Wars, Diplomacy

Добавляет bilateral state
relations, player reputation с государствами и пиратами, war declarations
emergent из низких отношений, peace treaties, customs tax scaling по rep,
port access blocks по war/low-rep. Фаза 5 (player agency — bribes, citizenship)
в TODO.

### A3.1. Модель отношений (Phase 1)

**Новые данные:**
- `data/relations.json` (новый) — 6 bilateral пар для 4 states, исторические
  значения ~1600: spain:england=-20, spain:netherlands=-40, spain:france=-10,
  england:netherlands=+10, france:netherlands=+10, england:france=0.
  Ключи в JSON могут быть в любом порядке — `_pair_key()` нормализует к
  sorted alphabetical (`"england:spain"` для любой пары spain+england).

**Новые поля на `WorldState`:**
- `state_relations: Dictionary` — `{"england:spain": float, ...}` в `[-100, +100]`.
- `player_rep: Dictionary` — `{"spain": float, ..., "pirates": float}`, в `[-100, +100]`.
- `active_wars: Array` — `WarSystem.ActiveWar` instances.
- `war_rng: RandomNumberGenerator` — отдельный stream (seed `world_seed + 4242`),
  критично для детерминизма event_rng/pirate_rng.

**Helpers:**
- `_pair_key(a, b) -> String` — sorted alphabetical key.
- `get_relation(a, b)`, `set_relation(a, b, val)` (clamped), `adjust_relation(a, b, delta)`.
- `get_player_rep(actor_id)`, `adjust_player_rep(actor_id, delta)` (clamped).
- `at_war(a, b) -> bool` — checks active_wars array.

**`Ship.flag_state: String`** (новое поле) — цвет государства под которым
ходит корабль. Player ship: `"england"` (Port Royal heritage). AI ships:
наследуют от `home.state_id` (Havana Sugar → spain, Santiago Metals → spain,
Carib Produce → england).

### A3.2. WarSystem (Phase 2/4)

**`simulation/systems/war_system.gd`** (новый) — `class_name WarSystem`,
inner class `ActiveWar {state_a, state_b, days_left}`. Метод `roll_weekly()`
в порядке: decay → incidents → war declarations → peace rolls.

**Константы** (tuned для 1-3 войн/год в 365-day sim):
- `WAR_THRESHOLD = -60` — ниже этого отношения может начаться война.
- `PROB_WAR_DECLARATION = 0.4` — per week per eligible pair.
- `PROB_PEACE = 0.2` — per week per active war.
- `PROB_INCIDENT = 0.15` — per week per state pair (достаточно чтобы
  incidents перевешивали decay).
- `INCIDENT_DELTA = 20` — swing magnitude.
- `PEACE_RELATION = -20` — куда сбрасываются отношения при мире (still cold,
  но не война).
- `DECAY_PER_WEEK = 0.3` — медленная нормализация к 0.

**Counters** для verification: `wars_declared`, `peaces_signed`, `incidents`.

**Wire-in:** `SimulationEngine.step_week` вызывает `war_system.roll_weekly()`
ПОСЛЕ `event_system.roll_weekly()` — чтобы war declarations видели свежие
отношения (incidents могли только что их сдвинуть).

### A3.3. Sources of rep (Phase 2)

- **Торговля в порту state X** → `player_rep[X] += 0.5` за сделку (buy или
  sell). Только для player (AI не копит rep).
- **Торговля в pirate haven** (Tortuga) → `player_rep["pirates"] += 1.0`.
- **Пиратская атака на player ship** → `player_rep["pirates"] -= 2.0`.
- **Weekly decay** — все rep дрейфуют к 0 на 0.3 пункта.
- **Diplomatic incidents** — random ±20 к bilateral relation, 70% negative,
  prob 0.15/week/pair.

### A3.4. Effects на существующие механики.

**Таможенный налог scaling** в `TradeSystem._collect_customs`:
```
effective_tax = state.tax_rate × trade_value × (1.0 + max(0, -player_rep/100))
```
- `rep ≥ 0`: tax × 1.0 (без бонуса, просто без штрафа).
- `rep = -50`: tax × 1.5.
- `rep = -100`: tax × 2.0 (hostile trader платит двойную пошлину).

**Port access** в `ShipsTick._can_dock(ship, town)`:
- War blocks: если `ship.flag_state` и `town.state_id` разные И между ними
  `at_war` → корабль не может докиться.
- Low rep blocks player: если `ship.owner_id == "player"` и
  `player_rep[town.state_id] < -50` → порт отказывает в стоянке.
- Blocked ship: не докится, reroute к следующей остановке route (через
  `route.next_stop_after`), остаётся в sailing state. Если route пуст → idle.

### A3.5. Тесты (8 новых, всего теперь 36)

`tests/test_wars.gd` + `.tscn` (8 PASS):
- `relations_spawn` — 6 пар с историческими значениями, sym_ok, rep_zero,
  pair count.
- `trade_raises_rep` — manual_buy в tortuga → +0.5 france rep, +1.0 pirate
  rep (haven).
- `tax_scales_with_rep` — rep=-50 → tax × 1.5 (38.11 actual vs 38.11 expected).
- `low_rep_blocks_docking` — rep=-60 → `_can_dock` returns false; rep=0 → true.
- `war_triggers_at_low_relation` — set relation=-90, 30 weekly rolls → war
  declared.
- `war_blocks_enemy_flag` — england-ship → spain-port blocked (war);
  england-ship → england-port allowed; spain-ship → spain-port allowed.
- `peace_resets_relations` — inject war, 40 peace rolls → peace signed,
  relation = -20.
- `pirate_attack_lowers_pirate_rep` — prob=1.0, 1 day → pirate rep -2.

Все существующие 28 тестов остаются зелёными — A3 добавляет новые поля и
методы, но не ломает существующие инварианты (conservation, determinism,
structural checks).

### A3.6. Эффект на sim (365 дней, seed = 1337)

| Метрика | D1 (15 towns, no A3) | A3 (15 towns + wars) |
|---|---|---|
| `total_money` start | 528 700 | 528 700 (без изменений — rep/relations не деньги) |
| drift | 0.0000 | 0.0000 |
| Player profit | +13 108 | +13 108 (same — player не пострадал от wars в этом прогоне) |
| Events fired | 319 | 319 |
| **Wars declared** | — | **5** |
| **Peaces signed** | — | **5** |
| **Diplomatic incidents** | — | **61** |
| **Active wars at end** | — | **0** (все 5 разрешались миром) |

**Final relations snapshot** (после 365 дней):
- england:france: -52 (было 0)
- england:netherlands: +25 (было +10)
- france:netherlands: -76 (было +10)
- england:spain: -54 (было -20)
- france:spain: -51 (было -10)
- netherlands:spain: -49 (было -40)

Динамика заметная — все пары (кроме england:netherlands) ушли в негатив,
france:netherlands почти у порога войны (-76 vs threshold -60). Это emergent
behavior: incidents + decay создают реальную дипломатическую ситуацию.

### A3.7. Что НЕ сделано (TODO)

- **Phase 5 — Player agency** (bribes, citizenship): bribes state для +rep,
  apply for citizenship при rep>+50 (меняет `flag_state`). ~80 строк.
  ✓ **done in A3.8** (`bribe_state` +20 rep/$500–1500/4wk cd, `apply_citizenship`
  $5000/rep>50 → flag_state).
- **War tariffs** (doubling customs tax during war) — не сделано, только
  port block. Можно добавить в `_collect_customs`: `if at_war(flag, state):
  tax × 2`.
- **Privateering boost** — во время войны у state растёт шанс pirate
  attacks на вражеских торговцев (commissioned privateers).
- **UI visualization** — relations/rep не показываются в windowed UI. Нужно
  добавить панель «Diplomacy» с relations matrix и player_rep per state.
  ✓ **частично done in A3.8**: панель Diplomacy с player_rep per state + bribe/
  citizenship добавлена. Relations matrix (state↔state) пока НЕ показана — TODO.
- **War fleets** — state patrolling ships, interception of enemy traders.
  Big feature, A3.x или A4.

### A3.8. Diplomacy UI + player agency (bribes / citizenship) — Stage A3.1

Реализованы две механики из TODO A3.7 (Phase 5 player agency + UI visualization
diplomacy):

**Взятка (`main.bribe_state`).** Игрок платит чиновникам state — cost =
`500·(1+max(0,−rep/50))`, т.е. 500 при rep≥0, до 1500 при rep=−100. Деньги
`company → state.treasury` (консервация: state.treasury ∈ total_money → drift=0).
+10 rep с state. Cooldown 4 недели (`company.bribe_cooldowns[state_id] = week`).
Не требует dock (курьер) — панель видна всегда.

**Натурализация (`main.apply_citizenship`).** При rep>50 и $5000 — смена
`ship.flag_state` на state_id. Деньги `company → state.treasury` (консервация).
Корабль теперь летит под новым флагом → `ShipsTick._can_dock` пускает в порты
нового state даже если бывший флаг в войне с ними. Штраф за дезертирство: все
прочие states (кроме нового и бывшего флага) теряют по −10 rep — смена стороны
это реальный дипломатический разрыв, не бесплатная смена флага. Деньги при
штрафе не двигаются → drift=0.

**UI:** панель Diplomacy между Route и Log — по строке на state: ★ текущий флаг,
name, rep (зелёный/красный), кнопка Bribe (cost в label, disabled на cooldown
или без денег), кнопка Citizenship (disabled при rep≤50 / <$5000 / уже флаг).
Правую панель расширил 560→640. Правки прошлого среза (state в dock-хедере,
dem/sup, Δ-кошелька, upkeep-лог) сохранены — merge, не замена.

**Безопасность:** обе операции двигают деньги только `company↔state.treasury` →
drift=0; не читают rng → детерминизм. Новое поле `Company.bribe_cooldowns`
(default `{}`) не трогается экономикой. 6 новых тестов (`test_diplomacy`):
conservation+rep+cooldown, cooldown-block, no-funds-block, citizenship
flag+conservation, low-rep-block, citizenship penalizes bystander states (-10).

Всего теперь **45 тестов** (5+2+5+4+4+4+4+11+6), все зелёные, drift=0.0000 на
365-day sim, 5 wars + 5 peaces + 61 incidents за год.

### War tariffs — wartime customs surcharge on foreign traders

**Механика.** В `_collect_customs` (trade_system.gd): если порт state в активной
войне (`WorldState.state_at_war(port)` — новый helper, итерация `active_wars`) и
трейдер иностранец (`flag ≠ port`), customs ×2. Своя гражанка (`flag == port`)
exempt — citizenship даёт иммунитет от wartime-сбора. Вражеский флаг не дойдёт
до торговли (`_can_dock` блокирует `at_war(flag,port)`). Деньги
`company → state.treasury` (drift=0), rng не читает → детерминизм.

**Почему не `at_war(flag,port)` напрямую:** `_can_dock` уже блокирует вражеский
флаг → то условие было бы мёртвым кодом. Условие «порт в войне с кем-то» ловит
нейтральных иностранцев в wartime-портах — тех, для кого citizenship к воюющему
state (стать гражданином, снять 2×) или обход таких портов — стратегический
выбор. Это и делает citizenship осмысленным экономически.

**Тесты (2 новых в test_wars, 10/10):** foreign trader в wartime-порту платит
2× (cost 508 → tax 50.8 vs 25.4 base); citizen (flag==port) exempt даже в войну.

**Измерение (365 дней, seed 1337, с tariff vs baseline без tariff):** drift=0 в
обоих; wars идентичны (5/5/61/0 — tariff не трогает war_rng, детерминизм
сохранён). Player profit **не изменился** (+13108.6 → +13108.6, те же
buys/sells): английский флаг + home-trade pattern + вражеские порты
блокируются до торговли → tariff не срабатывает на игроке в этом seed. AI:
Havana Sugar −216, Santiago Metals −207, Carib Produce 0 → ~−423 total
(~1.4% AI-прибыли) ушло в state treasuries. **Вывод: tariff НЕ избыточен** —
мягкий; для игрока в этом seed no-op, реальные проблемы только при торговле в
нейтральном иностранном порту во время войны этого state.

### Relations matrix UI — state↔state relations + active wars in Diplomacy

**Механика.** В `_rebuild_diplo_panel` (ui/game_ui.gd) ниже per-state строк
(bribe/citizenship) добавлен read-only block: separator + "— state relations —"
+ строка active wars ("⚔ Испания ↔ Англия, ..." или "(no active wars)") + по
строке на каждую пару state (C(N,2)=6), color-coded: red+⚔ at war, orange
rel≤−40, yellow rel<0, green rel≥0. Глифы ⚔/↔/★ проверены в DejaVuSansMono.

**Refresh.** `_on_day_advanced` теперь зовёт `_rebuild_diplo_panel` на weekly
границе (`day % 7 == 0`) — выровнено с `WarSystem.roll_weekly` (wars/relations
меняются только там), без ежедневного reflow кнопок. Rebuild также на dock и
после bribe/citizenship (как раньше).

**Зачем:** wars блокируют docking вражеского флага + 2× customs для иностранцев
(tariff) — видеть, кто с кем воюет, делает route planning + citizenship
тактически осмысленными. Раньше в UI был только player_rep per state.

**Тест (1 новый в test_wars, 11/11):** `relations_matrix_contract` — каждый pair
имеет relation ∈ [−100,100], get_relation симметричен, `state_at_war(id)` true
iff id в каком-то active war, `at_war(a,b)` bilateral согласован с active_wars.

**Верификация UI:** модель не читает images, поэтому visual-check сделан
программно — рендер под Xvfb+llvmpipe (project `gl_compatibility`), color-bucket
анализ правой панели: orange (sp:nl=−40 pair) 695px, yellow (sp:en/sp:fr pairs)
1080px, green (rep≥0 rows + green pairs) 5381px, gray-green "(no active wars)"
6396px, red 0 (войн нет в свежем мире). 8s clean run без runtime-ошибок.
drift=0, editor-pass чист, 9/9 сцен PASS.

---

## TODO / known issues

- `sim_output/sim_summary.txt` в репо устаревший — это срез мира до A2 (start
  133 600, player profit 66 952), без state treasuries и без расширенной карты
  D1. Свежий прогон пишет в `user://sim_output/`, но Godot 4.7.2 в headless
  при `--quit` рвёт stdout до печати финальных метрик (drift / profit / wars /
  events) — поэтому числа из чата не совпадают с лежащим в репо файлом. Не
  блокер для разработки. Обновить `sim_output/` в репо и зафиксировать новые
  опорные числа (total_money, player P/L, AI P/L, wars/events) — после первого
  среза баланса/контента.





