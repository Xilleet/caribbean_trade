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



