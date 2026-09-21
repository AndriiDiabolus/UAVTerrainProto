extends RefCounted
## ПОЛИГОН «СЕТЕВОЙ ЗАСЛОН» — физическая модель.
##
## Чистый расчётный слой (без узлов сцены): свойства сети и носителей, геометрия барьера,
## один акт перехвата, взрывное поражение объекта, Монте-Карло по конфигурациям.
## Тот же код считает и 3D-сцену полигона, и headless-прогон (--netbatch) — «что видишь, то и посчитано».
##
## ВСЕ ЧИСЛА — ОЦЕНОЧНЫЕ, из открытых источников; допущения вынесены в docs/netdef_model.md.
## Модель намеренно консервативна: где данные расходятся, берётся худший для защиты вариант.

const G := 9.81
const RHO_AIR := 1.225           # кг/м³, МСА на уровне моря
const RHO_HE := 0.1664           # кг/м³, гелий 15 °C
const H_SCALE := 8400.0          # шкала высоты атмосферы, м


# ─────────────────────────── УГРОЗЫ ───────────────────────────
# mass  — стартовая масса, кг
# wh    — масса БЧ (ВВ), кг
# v     — характерная скорость на подходе, м/с (v_sd — разброс)
# span  — наибольший поперечный габарит, м (размах / диаметр окружности винтов)
# body  — поперечник корпуса, м
# prop  — движитель: pusher (толкающий винт) / quad / none (планер, реактивный)
# fuze  — взрыватель: impact (инерционно-ударный) / contact (контактный чувствительный) / none (ложная цель)
# guid  — наведение: ins (инерциальная — сеть не видит) / optic (оператор видит картинку) / ai (автозахват)
# g_lim — предел перегрузки планера (разрушение конструкции)
# alt   — типовая высота подхода, м AGL; prof — профиль подхода
# cost  — оценка стоимости изделия, USD (для экономики, этап 2)
const THREATS := {
	"shahed": {
		"name": "Шахед-136 / Герань-2", "short": "ШАХЕД",
		"mass": 200.0, "wh": 50.0, "v": 50.0, "v_sd": 6.0,
		"span": 2.5, "body": 0.5, "prop": "pusher", "fuze": "impact", "guid": "ins",
		"g_lim": 6.0, "alt": 120.0, "alt_sd": 60.0, "prof": "low", "cost": 35000.0,
		"note": "поршневой, инерциальная+СРНС, терминальный участок часто на малой высоте"
	},
	"shahed_jet": {
		"name": "Шахед-238 (реактивный)", "short": "ШАХЕД-Р",
		"mass": 240.0, "wh": 50.0, "v": 110.0, "v_sd": 12.0,
		"span": 2.5, "body": 0.55, "prop": "none", "fuze": "impact", "guid": "ins",
		"g_lim": 6.0, "alt": 250.0, "alt_sd": 120.0, "prof": "mid", "cost": 120000.0,
		"note": "турбореактивный; проверка верхней границы применимости заслона"
	},
	"gerbera": {
		"name": "Гербера (фанера/пенопласт)", "short": "ГЕРБЕРА",
		"mass": 18.0, "wh": 5.0, "v": 38.0, "v_sd": 5.0,
		"span": 2.5, "body": 0.35, "prop": "pusher", "fuze": "impact", "guid": "ins",
		"g_lim": 3.5, "alt": 150.0, "alt_sd": 80.0, "prof": "low", "cost": 10000.0,
		"note": "ложная цель / лёгкий ударный; планер слабый — рвётся о сеть заведомо"
	},
	"lancet": {
		"name": "Ланцет-3 (изд. 52)", "short": "ЛАНЦЕТ",
		"mass": 12.0, "wh": 3.0, "v": 80.0, "v_sd": 10.0,
		"span": 1.6, "body": 0.22, "prop": "pusher", "fuze": "contact", "guid": "ai",
		"g_lim": 8.0, "alt": 300.0, "alt_sd": 150.0, "prof": "dive", "cost": 35000.0,
		"note": "пикирование на цель с высоты — главный сценарий обхода заслона сверху"
	},
	"molniya": {
		"name": "«Молния» (фанерный планер)", "short": "МОЛНИЯ",
		"mass": 6.0, "wh": 3.0, "v": 28.0, "v_sd": 5.0,
		"span": 1.8, "body": 0.18, "prop": "pusher", "fuze": "contact", "guid": "optic",
		"g_lim": 3.0, "alt": 90.0, "alt_sd": 50.0, "prof": "low", "cost": 700.0,
		"note": "дешёвый массовый; оператор видит сеть в камеру — часть попыток уклоняется"
	},
	"fpv7": {
		"name": "FPV 7\" ударный", "short": "FPV-7",
		"mass": 2.6, "wh": 1.2, "v": 32.0, "v_sd": 7.0,
		"span": 0.36, "body": 0.14, "prop": "quad", "fuze": "contact", "guid": "optic",
		"g_lim": 12.0, "alt": 60.0, "alt_sd": 40.0, "prof": "low", "cost": 500.0,
		"note": "винты в плоскости сети — намотка почти гарантирована"
	},
	"fpv_fiber": {
		"name": "FPV на оптоволокне", "short": "FPV-ОПТ",
		"mass": 3.4, "wh": 1.2, "v": 26.0, "v_sd": 6.0,
		"span": 0.40, "body": 0.16, "prop": "quad", "fuze": "contact", "guid": "optic",
		"g_lim": 12.0, "alt": 40.0, "alt_sd": 25.0, "prof": "low", "cost": 900.0,
		"note": "РЭБ не берёт — заслон остаётся единственным физическим рубежом"
	}
}

# Профили подхода: изделие держит крейсерскую высоту и снижается на объект
# с дальности r_dive (для пикирования — доля высоты, угол ~50°).
const PROFILES := {
	"low":  {"r_dive": 350.0, "r_dive_k": 0.0,  "name": "мала висота, полога атака"},
	"mid":  {"r_dive": 700.0, "r_dive_k": 0.0,  "name": "середня висота"},
	"dive": {"r_dive": 0.0,   "r_dive_k": 0.84, "name": "пікірування з висоти (~50°)"}
}


# ─────────────────────────── СЕТИ ───────────────────────────
# cell — шаг ячейки, м; d — диаметр шнура, мм; mat — материал
# stroke — ход полотна при ударе (провис + упругость), м
const CORD := {
	# sigma — удельная разрывная, кН/мм²; rho — плотность, кг/м³; k_fill — заполнение сечения плетения
	"dyneema":   {"sigma": 0.80, "rho": 970.0,  "k_fill": 1.00, "name": "Dyneema SK75"},
	"nylon":     {"sigma": 0.25, "rho": 1140.0, "k_fill": 1.00, "name": "поліамід"},
	"polyester": {"sigma": 0.28, "rho": 1380.0, "k_fill": 1.00, "name": "поліефір"},
	"steel":     {"sigma": 1.15, "rho": 7850.0, "k_fill": 0.75, "name": "сталевий трос"}
}

const NETS := {
	"light_05": {"name": "лёгкая 0.5 м / D3", "cell": 0.5, "d": 3.0, "mat": "dyneema", "stroke": 4.0},
	"mid_03":   {"name": "средняя 0.3 м / D4", "cell": 0.3, "d": 4.0, "mat": "dyneema", "stroke": 4.5},
	"heavy_10": {"name": "тяжёлая 1.0 м / D6", "cell": 1.0, "d": 6.0, "mat": "dyneema", "stroke": 6.0},
	"nylon_04": {"name": "нейлон 0.4 м / N5", "cell": 0.4, "d": 5.0, "mat": "nylon", "stroke": 6.5},
	"steel_08": {"name": "трос 0.8 м / S4", "cell": 0.8, "d": 4.0, "mat": "steel", "stroke": 2.5}
}

# Якорный энергопоглотитель на оттяжках: разрывная лента / фрикционный тормоз
const ABSORBERS := {
	"none":     {"name": "без поглинача", "force": 0.0,  "stroke": 0.0,  "cost": 0.0},
	"tearweb":  {"name": "розривна стрічка", "force": 12.0, "stroke": 6.0,  "cost": 120.0},
	"brake":    {"name": "фрикційний гальмівник", "force": 20.0, "stroke": 12.0, "cost": 450.0},
	"brake_hd": {"name": "гальмівник посилений", "force": 35.0, "stroke": 15.0, "cost": 900.0}
}


# ─────────────────────────── НОСИТЕЛИ ───────────────────────────
const CARRIERS := {
	"aero_60": {
		"kind": "aerostat", "name": "аеростат 60 м³", "vol": 60.0, "skin": 0.22,
		"h_max": 300.0, "wind_max": 18.0, "up_time": 900.0, "cost": 9000.0,
		"note": "прив'язний, гелій; підйом/спуск лебідкою"
	},
	"aero_150": {
		"kind": "aerostat", "name": "аеростат 150 м³", "vol": 150.0, "skin": 0.22,
		"h_max": 400.0, "wind_max": 20.0, "up_time": 1200.0, "cost": 18000.0,
		"note": "несе важче полотно і вищий рубіж"
	},
	"aero_400": {
		"kind": "aerostat", "name": "аеростат 400 м³", "vol": 400.0, "skin": 0.20,
		"h_max": 500.0, "wind_max": 22.0, "up_time": 1800.0, "cost": 42000.0,
		"note": "клас загороджувального аеростата ППО"
	},
	"multi_25": {
		"kind": "multirotor", "name": "мультикоптер 25 кг", "payload": 12.0,
		"h_max": 200.0, "wind_max": 14.0, "up_time": 75.0, "endur": 1500.0, "cost": 14000.0,
		"note": "піднімає полотно за тривогою, тримає 25 хв"
	},
	"multi_60": {
		"kind": "multirotor", "name": "мультикоптер 60 кг", "payload": 30.0,
		"h_max": 250.0, "wind_max": 16.0, "up_time": 110.0, "endur": 1200.0, "cost": 38000.0,
		"note": "важкий носій, полотно 30×40 м на двох бортах"
	},
	"mast_50": {
		"kind": "mast", "name": "щогла 50 м", "payload": 400.0,
		"h_max": 50.0, "wind_max": 30.0, "up_time": 0.0, "cost": 22000.0,
		"note": "постійний рубіж; дешевий, але низький — тільки ближній периметр"
	}
}


# ─────────────────────────── ОБЪЕКТЫ ЗАЩИТЫ ───────────────────────────
# Элементы: r — вынос от центра площадки, м; area — миделева площадь, м²;
# dp — критическое избыточное давление, кПа; crit — вывод объекта из строя при поражении
const SITES := {
	"azs": {
		"name": "АЗС (траса, 8 колонок + СВГ)", "radius": 40.0,
		"elements": [
			{"id": "tanks", "name": "підземні резервуари", "r": 12.0, "area": 30.0, "dp": 70.0, "crit": true, "fire": true},
			{"id": "pumps", "name": "ПРК (колонки)", "r": 7.0, "area": 5.0, "dp": 20.0, "crit": true, "fire": true},
			{"id": "canopy", "name": "навіс", "r": 8.0, "area": 70.0, "dp": 7.0, "crit": false, "fire": false},
			{"id": "shop", "name": "операторна / магазин", "r": 20.0, "area": 45.0, "dp": 12.0, "crit": false, "fire": false},
			{"id": "lpg", "name": "модуль СВГ (газ)", "r": 24.0, "area": 14.0, "dp": 35.0, "crit": true, "fire": true},
			{"id": "tanker", "name": "бензовоз під зливом", "r": 16.0, "area": 22.0, "dp": 25.0, "crit": false, "fire": true}
		],
		"cost_usd": 1200000.0, "note": "втрата = об'єкт + пожежа + зупинка логістики палива в районі"
	},
	"substation": {
		"name": "Підстанція 150/35 кВ", "radius": 60.0,
		"elements": [
			{"id": "tr1", "name": "автотрансформатор №1", "r": 14.0, "area": 40.0, "dp": 45.0, "crit": true, "fire": true},
			{"id": "tr2", "name": "автотрансформатор №2", "r": 26.0, "area": 40.0, "dp": 45.0, "crit": true, "fire": true},
			{"id": "ourn", "name": "ВРП / ошинування", "r": 34.0, "area": 90.0, "dp": 12.0, "crit": true, "fire": false},
			{"id": "ctrl", "name": "ЗРП / щитова", "r": 20.0, "area": 50.0, "dp": 20.0, "crit": false, "fire": false}
		],
		"cost_usd": 9000000.0, "note": "ключова вразливість енергосистеми"
	},
	"depot": {
		"name": "Нафтобаза (резервуарний парк)", "radius": 90.0,
		"elements": [
			{"id": "rvs1", "name": "РВС-2000 №1", "r": 25.0, "area": 160.0, "dp": 35.0, "crit": true, "fire": true},
			{"id": "rvs2", "name": "РВС-2000 №2", "r": 50.0, "area": 160.0, "dp": 35.0, "crit": true, "fire": true},
			{"id": "pump", "name": "насосна", "r": 15.0, "area": 40.0, "dp": 20.0, "crit": true, "fire": true},
			{"id": "rack", "name": "естакада наливу", "r": 65.0, "area": 70.0, "dp": 15.0, "crit": false, "fire": true}
		],
		"cost_usd": 6000000.0, "note": "велика площа — суцільний заслон дорогий, потрібні сектори"
	}
}


# ═══════════════════ СВОЙСТВА СЕТИ ═══════════════════

## Погонная масса шнура, кг/м.
static func cord_lin_mass(d_mm: float, mat: String) -> float:
	var c: Dictionary = CORD.get(mat, CORD["dyneema"])
	var r: float = float(c["rho"]) * float(c["k_fill"])
	return r * PI * pow(d_mm * 0.001, 2.0) * 0.25


## Разрывное усилие шнура, кН.
static func cord_break(d_mm: float, mat: String) -> float:
	var c: Dictionary = CORD.get(mat, CORD["dyneema"])
	return float(c["sigma"]) * d_mm * d_mm


## Полные свойства полотна: удельная масса, заполненность, разрывная нити.
static func net_props(net_id: String) -> Dictionary:
	var n: Dictionary = NETS.get(net_id, NETS["light_05"])
	var cell: float = float(n["cell"])
	var d: float = float(n["d"])
	var mat: String = str(n["mat"])
	var mu := cord_lin_mass(d, mat)
	# две системы нитей: суммарная длина 2/cell метров на м²; +25 % на узлы, кромку, ремонтные вставки
	var areal := 2.0 / cell * mu * 1.25
	var s := d * 0.001 / cell
	var solidity: float = clampf(1.0 - pow(1.0 - s, 2.0), 0.0, 1.0)
	return {
		"id": net_id, "name": str(n["name"]), "cell": cell, "d": d, "mat": mat,
		"areal": areal, "solidity": solidity,
		"break_kn": cord_break(d, mat), "stroke": float(n["stroke"])
	}


## Лобовое сопротивление полотна при ветре/ударе потока, Н.
static func net_drag(props: Dictionary, area_m2: float, v: float) -> float:
	# Cd решётки ≈ 1.2 по перекрытой площади (для малой заполненности близко к линейному)
	return 0.5 * RHO_AIR * v * v * area_m2 * float(props["solidity"]) * 1.2


# ═══════════════════ НОСИТЕЛИ ═══════════════════

## Свободная подъёмная сила носителя на высоте h, кг (полезная нагрузка сверх собственной массы).
static func carrier_payload(carrier_id: String, h: float) -> float:
	var c: Dictionary = CARRIERS.get(carrier_id, CARRIERS["aero_60"])
	if str(c["kind"]) != "aerostat":
		return float(c["payload"])
	var vol: float = float(c["vol"])
	var dens_k: float = exp(-h / H_SCALE)
	var gross := (RHO_AIR - RHO_HE) * vol * dens_k
	# оболочка: площадь поверхности эквивалентной сферы ×1.15 (вытянутая форма + стабилизаторы)
	var r_sphere := pow(vol * 0.75 / PI, 1.0 / 3.0)
	var skin_area := 4.0 * PI * r_sphere * r_sphere * 1.15
	var m_skin := skin_area * float(c["skin"])
	# привязной трос: Dyneema 8 мм ≈ 0.049 кг/м на полную высоту
	var m_tether := float(c["h_max"]) * cord_lin_mass(8.0, "dyneema")
	return maxf(gross - m_skin - m_tether, 0.0)


# ═══════════════════ БАРЬЕР ═══════════════════

## Собрать барьер по конфигурации и посчитать его физику.
## cfg: {site, carrier, net, absorber, r_stand, h_top, h_bot, seg_w, n_seg, arc_deg}
static func build_barrier(cfg: Dictionary) -> Dictionary:
	var site: Dictionary = SITES.get(str(cfg.get("site", "azs")), SITES["azs"])
	var carrier_id := str(cfg.get("carrier", "aero_150"))
	var carrier: Dictionary = CARRIERS.get(carrier_id, CARRIERS["aero_150"])
	var net := net_props(str(cfg.get("net", "light_05")))
	var abs_id := str(cfg.get("absorber", "brake"))
	var absorber: Dictionary = ABSORBERS.get(abs_id, ABSORBERS["brake"])

	var r_stand: float = float(cfg.get("r_stand", 220.0))
	var h_top: float = float(cfg.get("h_top", 180.0))
	var h_bot: float = float(cfg.get("h_bot", 15.0))
	var seg_w: float = float(cfg.get("seg_w", 40.0))
	var arc_deg: float = float(cfg.get("arc_deg", 360.0))
	var n_seg: int = int(cfg.get("n_seg", 0))

	var front := TAU * r_stand * (arc_deg / 360.0)
	if n_seg <= 0:
		n_seg = int(ceil(front / seg_w))
	var panel_h: float = maxf(h_top - h_bot, 1.0)
	var panel_area := seg_w * panel_h
	var net_mass_seg := panel_area * float(net["areal"])
	# полотно висит между двумя носителями; на сегмент приходится один носитель (крайний общий)
	var carriers_n := n_seg + (0 if arc_deg >= 359.9 else 1)
	var per_carrier := net_mass_seg   # носитель держит вес своего полотна (кромки разделены пополам, но берём худший)

	var payload := carrier_payload(carrier_id, h_top)
	var lift_ok: bool = payload >= per_carrier and h_top <= float(carrier.get("h_max", 300.0))
	var lift_margin: float = (payload / maxf(per_carrier, 0.001) - 1.0) * 100.0
	# инженерное правило загородительных аэростатов: свободная подъёмная сила должна
	# вдвое перекрывать вес полотна, иначе привязь ложится по ветру и рубеж теряет высоту
	var reserve: float = payload / maxf(per_carrier, 0.001)

	# покрытие фронта: между сегментами остаются зазоры на разнос носителей
	var gap: float = float(cfg.get("gap", 4.0))
	var coverage: float = clampf(seg_w / (seg_w + gap), 0.0, 1.0)

	var hcap := carrier_break_energy(net, absorber)
	return {
		"cfg": cfg, "site": site, "site_id": str(cfg.get("site", "azs")),
		"carrier_id": carrier_id, "carrier": carrier, "net": net,
		"absorber_id": abs_id, "absorber": absorber,
		"r_stand": r_stand, "h_top": h_top, "h_bot": h_bot,
		"seg_w": seg_w, "n_seg": n_seg, "carriers_n": carriers_n, "gap": gap,
		"arc_deg": arc_deg, "front_m": front, "coverage": coverage,
		"anchor_share": float(cfg.get("anchor_share", 0.6)),
		"panel_area": panel_area, "net_mass_seg": net_mass_seg,
		"net_mass_total": net_mass_seg * n_seg,
		"payload": payload, "lift_ok": lift_ok, "lift_margin": lift_margin, "reserve": reserve,
		"e_net": hcap["e_net"], "e_abs": hcap["e_abs"],
		"up_time": float(carrier.get("up_time", 0.0)),
		"wind_max": float(carrier.get("wind_max", 15.0))
	}


## Энергоёмкость узла «полотно + якорный поглотитель» на один удар, Дж.
static func carrier_break_energy(net: Dictionary, absorber: Dictionary) -> Dictionary:
	# базовая справка; точное число нитей зависит от габарита угрозы (см. engage)
	return {
		"e_net": float(net["break_kn"]) * 1000.0 * float(net["stroke"]),   # на одну нить
		"e_abs": float(absorber["force"]) * 1000.0 * float(absorber["stroke"])
	}


## Состояние барьера при ветре: натяжение, наклон троса, фактическая высота верхней кромки.
static func wind_state(bar: Dictionary, wind: float) -> Dictionary:
	var net: Dictionary = bar["net"]
	var carrier: Dictionary = bar["carrier"]
	var area: float = float(bar["panel_area"])
	var drag := net_drag(net, area, wind)
	var down := false
	var h_eff: float = float(bar["h_top"])
	var tilt := 0.0
	if not bool(bar.get("lift_ok", true)):
		return {
			"wind": wind, "drag_n": drag, "tilt_deg": 90.0, "h_eff": 0.0, "down": true,
			"tension_kn": 0.0,
			"reason": "носій не піднімає полотно: треба %.0f кг, тягне %.0f кг"
				% [bar["net_mass_seg"], bar["payload"]]
		}
	# нижняя кромка полотна притянута к грунтовым анкерам: большая часть лобового
	# сопротивления сети реагируется анкерами, на носитель приходит остаток
	var anchor_share: float = float(bar.get("anchor_share", 0.6))
	var drag_carrier := drag * (1.0 - anchor_share)
	if str(carrier["kind"]) == "aerostat":
		var lift_n: float = (float(bar["payload"]) - float(bar["net_mass_seg"])) * G   # свободный остаток, Н
		lift_n = maxf(lift_n, 1.0)
		# сопротивление самой оболочки: обтекаемый корпус, Cd·S ≈ 0.12·V^(2/3)
		var aero_drag := 0.5 * RHO_AIR * wind * wind * pow(float(carrier["vol"]), 2.0 / 3.0) * 0.12
		tilt = atan2(drag_carrier + aero_drag, lift_n)
		h_eff = float(bar["h_top"]) * cos(tilt)
	elif str(carrier["kind"]) == "multirotor":
		# коптер держит позицию, пока тяга на компенсацию сноса в пределах запаса
		tilt = atan2(drag_carrier, float(carrier["payload"]) * G * 2.0)
		h_eff = float(bar["h_top"]) * cos(tilt) * (1.0 - clampf(wind / float(carrier["wind_max"]), 0.0, 1.0) * 0.15)
	else:
		h_eff = float(bar["h_top"])
	var reason := ""
	if wind > float(bar["wind_max"]):
		down = true
		h_eff = 0.0
		reason = "вітер %.0f м/с > межі носія %.0f м/с — заслін спущено" % [wind, bar["wind_max"]]
	return {
		"wind": wind, "drag_n": drag, "tilt_deg": rad_to_deg(tilt),
		"h_eff": h_eff, "down": down, "reason": reason,
		"tension_kn": (drag + float(bar["net_mass_seg"]) * G) * 0.001,
		"anchor_kn": drag * anchor_share * 0.001
	}


## Сила, которую держит зацепленный участок полотна до разрыва, Н.
## Работают нити, накрытые габаритом изделия; нагружены неравномерно (η = 0.5).
static func net_hold_force(net: Dictionary, span: float) -> float:
	var cell: float = float(net["cell"])
	var n_cords: int = clampi(2 * (int(ceil(span / cell)) + 1), 2, 48)
	return float(n_cords) * float(net["break_kn"]) * 1000.0 * 0.5


## Силовая схема задержания.
## Полотно натягивается упруго (ход s_net) до порога тормоза F_b, дальше тормоз на анкере
## травит ленту с постоянной силой F_b на ходе до s_abs. Условие работы: F_b ниже силы,
## которую держит полотно, иначе сеть рвётся раньше, чем тормоз стронется.
## Пиковое замедление = F / m — именно оно ломает планер и будит взрыватель.
static func capture(bar: Dictionary, span: float, mass: float, e_n: float) -> Dictionary:
	var net: Dictionary = bar["net"]
	var s_net: float = maxf(float(net["stroke"]), 0.5)
	var f_net := net_hold_force(net, span)
	var f_b: float = float(bar["absorber"]["force"]) * 1000.0
	var s_abs: float = float(bar["absorber"]["stroke"])
	var out := {"caught": false, "e_cap": 0.0, "n_g": 0.0, "travel": 0.0, "brake_used": 0.0,
		"f_net": f_net, "f_b": f_b, "mode": ""}
	if f_b > 0.0 and f_b < f_net:
		var e_el := 0.5 * f_b * s_net
		out["e_cap"] = e_el + f_b * s_abs
		if e_n <= e_el:
			# остановлен ещё на упругом участке, тормоз не стронулся
			var k := f_b / s_net
			var x := sqrt(2.0 * e_n / k)
			out["caught"] = true
			out["travel"] = x
			out["n_g"] = k * x / (mass * G)
			out["mode"] = "elastic"
		else:
			var s_b := (e_n - e_el) / f_b
			out["caught"] = s_b <= s_abs
			out["brake_used"] = minf(s_b, s_abs)
			out["travel"] = s_net + minf(s_b, s_abs)
			out["n_g"] = f_b / (mass * G)
			out["mode"] = "brake"
	else:
		# поглотителя нет или он жёстче полотна — работает одна сеть до разрыва
		var k := f_net / s_net
		out["e_cap"] = 0.5 * f_net * s_net
		if e_n <= float(out["e_cap"]):
			var x := sqrt(2.0 * e_n / k)
			out["caught"] = true
			out["travel"] = x
			out["n_g"] = k * x / (mass * G)
		else:
			out["travel"] = s_net
			out["n_g"] = f_net / (mass * G)
		out["mode"] = "net_only"
	return out


## Окно сил секции — главное правило настройки тормоза:
## ветровая нагрузка на анкеры < порог тормоза < сила, которую держит полотно.
## Ниже окна тормоз травит от ветра, выше — полотно рвётся раньше, чем тормоз стронется.
static func force_window(bar: Dictionary, wind: float, span := 2.5) -> Dictionary:
	var ws := wind_state(bar, wind)
	var w_kn: float = float(ws.get("anchor_kn", 0.0))
	var b_kn: float = float(bar["absorber"]["force"])
	var n_kn: float = net_hold_force(bar["net"], span) * 0.001
	return {"wind_kn": w_kn, "brake_kn": b_kn, "net_kn": n_kn,
		"ok": b_kn > w_kn and b_kn < n_kn}


# ═══════════════════ ОДИН АКТ ПЕРЕХВАТА ═══════════════════

## Сгенерировать попытку атаки: азимут, высота подхода, скорость, боковое смещение.
static func make_shot(threat_id: String, bar: Dictionary, rng: RandomNumberGenerator, opts: Dictionary = {}) -> Dictionary:
	var th: Dictionary = THREATS[threat_id]
	var prof_id := str(opts.get("prof", th["prof"]))
	var az: float = float(opts.get("az", deg_to_rad(rng.randf_range(0.0, 360.0))))
	var v: float = maxf(float(th["v"]) + rng.randfn(0.0, float(th["v_sd"])), 5.0)
	var h_travel: float = maxf(float(th["alt"]) + rng.randfn(0.0, float(th["alt_sd"])), 15.0)
	# боковое смещение прицеливания (КВО изделия)
	var cep: float = float(opts.get("cep", 12.0))
	var miss := Vector2(rng.randfn(0.0, cep), rng.randfn(0.0, cep))
	return shot_of(threat_id, h_travel, v, prof_id, az, miss)


## Собрать попытку с явными параметрами (используется и в сцене, и в тестах).
static func shot_of(threat_id: String, h: float, v: float, prof_id := "",
		az := 0.0, miss := Vector2.ZERO) -> Dictionary:
	var th: Dictionary = THREATS[threat_id]
	if prof_id == "":
		prof_id = str(th["prof"])
	var prof: Dictionary = PROFILES.get(prof_id, PROFILES["low"])
	var r_dive: float = float(prof["r_dive"])
	if float(prof["r_dive_k"]) > 0.0:
		r_dive = h * float(prof["r_dive_k"])
	r_dive = maxf(r_dive, 50.0)
	return {
		"threat": threat_id, "az": az, "v": maxf(v, 5.0), "h": maxf(h, 5.0),
		"r_dive": r_dive, "dive": atan2(h, r_dive), "prof": prof_id, "miss": miss
	}


## Высота трассы на удалении d от объекта: крейсер до рубежа снижения, дальше — по глиссаде.
static func shot_height_at(shot: Dictionary, d: float) -> float:
	var h: float = float(shot["h"])
	var r_dive: float = maxf(float(shot.get("r_dive", 350.0)), 1.0)
	if d >= r_dive:
		return h
	return h * d / r_dive


## Угол наклона траектории в точке пересечения рубежа (0 на крейсерском участке).
static func shot_path_angle(shot: Dictionary, d: float) -> float:
	if d >= maxf(float(shot.get("r_dive", 350.0)), 1.0):
		return 0.0
	return float(shot["dive"])


## Один акт: угроза против барьера. Возвращает исход, точку падения и ущерб объекту.
static func engage(bar: Dictionary, shot: Dictionary, rng: RandomNumberGenerator, wind: float = 4.0) -> Dictionary:
	var th: Dictionary = THREATS[str(shot["threat"])]
	var ws := wind_state(bar, wind)
	var r_stand: float = float(bar["r_stand"])
	var h_top: float = float(ws["h_eff"])
	var h_bot: float = float(bar["h_bot"])
	var v: float = float(shot["v"])
	var mass: float = float(th["mass"])
	var res := {
		"threat": str(shot["threat"]), "v": v, "wind": wind,
		"h_cross": 0.0, "outcome": "", "stopped": false, "deton": false,
		"n_g": 0.0, "e_kj": 0.5 * mass * v * v * 0.001,
		"fall_r": 0.0, "fall_h": 0.0, "v_res": 0.0, "note": ""
	}

	# 0. барьер лёг по ветру / носитель не поднимает полотно
	if bool(ws["down"]):
		res.outcome = "leak_down"
		res.note = str(ws.get("reason", "заслін опущено за вітром %.0f м/с" % wind))
		_apply_direct_hit(bar, th, res, rng, shot)
		return res

	# 1. высота пересечения рубежа
	var h_cross := shot_height_at(shot, r_stand)
	res.h_cross = h_cross

	# 2. попал ли в полотно. Щель шириной gap пропускает изделие размахом span только
	# «чистой» частью (gap − span): крылом за кромку полотна оно всё равно цепляется.
	var gap_eff: float = maxf(float(bar["gap"]) - float(th["span"]), 0.0)
	var p_gap: float = gap_eff / maxf(float(bar["seg_w"]) + float(bar["gap"]), 0.001)
	if rng.randf() < p_gap:
		res.outcome = "leak_gap"
		res.note = "пройшов у чисту частину щілини (%.1f м з %.1f м)" % [gap_eff, bar["gap"]]
		_apply_direct_hit(bar, th, res, rng, shot)
		return res
	if h_cross > h_top:
		res.outcome = "leak_over"
		res.note = "перевищив верхню кромку (%.0f м > %.0f м)" % [h_cross, h_top]
		_apply_direct_hit(bar, th, res, rng, shot)
		return res
	if h_cross < h_bot:
		res.outcome = "leak_under"
		res.note = "пройшов під нижньою кромкою (%.0f м < %.0f м)" % [h_cross, h_bot]
		_apply_direct_hit(bar, th, res, rng, shot)
		return res

	# 3. оператор видит полотно и уклоняется (только для управляемых по видео)
	if str(th["guid"]) == "optic" and rng.randf() < 0.22:
		res.outcome = "evaded"
		res.note = "оператор побачив полотно і відвернув"
		_apply_direct_hit(bar, th, res, rng, shot)
		return res

	# 4. геометрия ячейки: может ли вообще проскочить сквозь окно
	var net: Dictionary = bar["net"]
	var cell: float = float(net["cell"])
	var span: float = float(th["span"])
	var p_pass := 0.0
	if span < cell:
		p_pass = pow((cell - span) / cell, 2.0)
	# вращающиеся винты ловят шнур даже при формальном пролёте
	var p_prop := 0.0
	match str(th["prop"]):
		"quad": p_prop = 0.92
		"pusher": p_prop = 0.55
		_: p_prop = 0.0
	var p_through: float = p_pass * (1.0 - p_prop)
	if rng.randf() < p_through:
		res.outcome = "through_cell"
		res.note = "проскочив крізь вічко %.2f м" % cell
		_apply_direct_hit(bar, th, res, rng, shot)
		return res

	# 5. торможение: силовая схема «полотно → тормоз на анкере»
	var v_n: float = v * cos(shot_path_angle(shot, r_stand))   # нормальная к полотну составляющая
	var e_n := 0.5 * mass * v_n * v_n
	var cap := capture(bar, span, mass, e_n)
	var e_cap: float = float(cap["e_cap"])
	var n_g: float = float(cap["n_g"])
	res.n_g = n_g
	res["travel"] = float(cap["travel"])
	res["brake_used"] = float(cap["brake_used"])

	var airframe_break: bool = n_g > float(th["g_lim"])
	var caught: bool = bool(cap["caught"])

	# 6. подрыв БЧ на сети (инерционный взрыватель чувствует замедление)
	var p_det := 0.0
	match str(th["fuze"]):
		"impact": p_det = clampf((n_g - 8.0) / 45.0, 0.02, 0.75)
		"contact": p_det = clampf((n_g - 4.0) / 25.0, 0.05, 0.85)
		_: p_det = 0.0
	res.deton = rng.randf() < p_det

	if caught:
		res.outcome = "caught"
		res.stopped = true
		res.note = "затримано полотном: E=%.0f кДж ≤ ємність %.0f кДж, %.0f g" % [e_n * 0.001, e_cap * 0.001, n_g]
		res.fall_r = r_stand + rng.randf_range(-8.0, 8.0)
		res.fall_h = (h_cross if res.deton else 0.0)
	else:
		var e_res := e_n - e_cap
		var v_res := sqrt(2.0 * e_res / mass)
		res.v_res = v_res
		if airframe_break:
			# планер разрушен: обломки летят по баллистике с остаточной скоростью
			var t_fall := sqrt(2.0 * maxf(h_cross, 1.0) / G)
			var carry := v_res * t_fall * 0.7         # обломки тормозятся о воздух
			res.outcome = "breach_wreck"
			res.stopped = carry < r_stand - float(bar["site"]["radius"])
			res.note = "полотно прорвано, планер зруйновано (%.0f g); уламки пронесло %.0f м" % [n_g, carry]
			res.fall_r = maxf(r_stand - carry, 0.0)
			res.fall_h = (h_cross * 0.5 if res.deton else 0.0)
		else:
			res.outcome = "breach"
			res.stopped = false
			res.note = "прорив: залишкова швидкість %.0f м/с" % v_res
			_apply_direct_hit(bar, th, res, rng, shot)
			res.v_res = v_res
			return res

	res["damage"] = damage_at(bar, th, float(res.fall_r), float(res.fall_h), res.deton, rng)
	return res


## Прямое попадание в объект (барьер не сработал).
static func _apply_direct_hit(bar: Dictionary, th: Dictionary, res: Dictionary,
		rng: RandomNumberGenerator, shot: Dictionary = {}) -> void:
	res.stopped = false
	res.deton = str(th["fuze"]) != "none"
	# промах прицеливания (КВО): изделие ложится не в центр площадки
	var miss: Vector2 = shot.get("miss", Vector2.ZERO)
	res.fall_r = miss.length()
	res.fall_h = 0.0
	res["damage"] = damage_at(bar, th, float(res.fall_r), 0.0, res.deton, rng, true)


# ═══════════════════ ПОРАЖЕНИЕ ОБЪЕКТА ═══════════════════

## Избыточное давление на фронте УВ, кПа (формула Садовского, ТНТ-эквивалент).
static func overpressure(w_tnt: float, r: float) -> float:
	if w_tnt <= 0.0:
		return 0.0
	var rr: float = maxf(r, 0.5)
	var w13 := pow(w_tnt, 1.0 / 3.0)
	return 95.0 * w13 / rr + 390.0 * pow(w_tnt, 2.0 / 3.0) / (rr * rr) + 1300.0 * w_tnt / pow(rr, 3.0)


## Вероятность поражения элемента осколками.
static func frag_kill(w_tnt: float, area: float, r: float) -> float:
	if w_tnt <= 0.0:
		return 0.0
	var n_frag := 900.0 * w_tnt                       # ~900 убойных осколков на кг ВВ (ОФ БЧ)
	var rr: float = maxf(r, 1.0)
	var dens := n_frag / (4.0 * PI * rr * rr)          # осколков на м²
	var eff: float = exp(-rr / 120.0)                  # потеря убойности с дальностью
	return clampf(1.0 - exp(-dens * area * 0.25 * eff), 0.0, 1.0)


## Ущерб объекту от взрыва на удалении fall_r от центра площадки и высоте fall_h.
static func damage_at(bar: Dictionary, th: Dictionary, fall_r: float, fall_h: float,
		deton: bool, rng: RandomNumberGenerator, direct := false) -> Dictionary:
	var site: Dictionary = bar["site"]
	var hit: Array = []
	var crit := false
	var fire := false
	if not deton:
		# неразорвавшееся изделие: кинетика + пожар от топлива при прямом попадании
		if direct and float(th["mass"]) > 50.0:
			hit.append("кінетичне ураження конструкцій")
			crit = true
			fire = true
		return {"elements": hit, "crit": crit, "fire": fire, "dp_max": 0.0, "deton": false}
	var w_tnt: float = float(th["wh"]) * 1.1           # тротиловый эквивалент смесевого ВВ
	var dp_max := 0.0
	for e_v: Variant in site["elements"]:
		var e: Dictionary = e_v
		# расстояние от точки взрыва до элемента: элемент на радиусе e.r от центра,
		# взрыв на радиусе fall_r; берём средний по азимуту разнос
		var dr: float = absf(fall_r - float(e["r"]))
		var dmean := sqrt(dr * dr + pow(float(e["r"]) * 0.6, 2.0))
		if direct:
			# изделие легло в fall_r от центра: средний разнос до элемента на радиусе e.r
			dmean = sqrt(pow(maxf(float(e["r"]) - fall_r, 0.0), 2.0) + pow(float(e["r"]) * 0.5, 2.0))
			dmean = maxf(dmean, 2.0)
		var slant := sqrt(dmean * dmean + fall_h * fall_h)
		var dp := overpressure(w_tnt, slant)
		dp_max = maxf(dp_max, dp)
		var killed: bool = dp >= float(e["dp"])
		if not killed:
			killed = rng.randf() < frag_kill(w_tnt, float(e["area"]), slant)
		if killed:
			hit.append(str(e["name"]))
			if bool(e["crit"]):
				crit = true
			if bool(e.get("fire", false)):
				fire = true
	return {"elements": hit, "crit": crit, "fire": fire, "dp_max": dp_max, "deton": true}


# ═══════════════════ МОНТЕ-КАРЛО ═══════════════════

## Прогон N попыток одной угрозы против барьера. Возвращает агрегаты.
static func monte(bar: Dictionary, threat_id: String, n: int, rng: RandomNumberGenerator,
		wind: float = 4.0, opts: Dictionary = {}) -> Dictionary:
	var counts := {}
	var stopped := 0
	var site_crit := 0
	var site_fire := 0
	var deton := 0
	var sum_ng := 0.0
	for i in n:
		var shot := make_shot(threat_id, bar, rng, opts)
		var r := engage(bar, shot, rng, wind)
		var oc := str(r["outcome"])
		counts[oc] = int(counts.get(oc, 0)) + 1
		if bool(r["stopped"]):
			stopped += 1
		if bool(r["deton"]):
			deton += 1
		sum_ng += float(r["n_g"])
		var dmg: Dictionary = r.get("damage", {})
		if bool(dmg.get("crit", false)):
			site_crit += 1
		if bool(dmg.get("fire", false)):
			site_fire += 1
	var nf := float(maxi(n, 1))
	return {
		"threat": threat_id, "n": n, "wind": wind,
		"p_stop": stopped / nf,
		"p_site_crit": site_crit / nf,
		"p_site_fire": site_fire / nf,
		"p_deton": deton / nf,
		"avg_ng": sum_ng / nf,
		"counts": counts
	}


## Базовый уровень: тот же объект без всякого заслона — сколько попыток выводят его из строя.
static func baseline(site_id: String, threat_id: String, n: int, rng: RandomNumberGenerator) -> Dictionary:
	var bar := {"site": SITES.get(site_id, SITES["azs"])}
	var th: Dictionary = THREATS[threat_id]
	var crit := 0
	var fire := 0
	for i in n:
		var miss := Vector2(rng.randfn(0.0, 12.0), rng.randfn(0.0, 12.0))
		var dmg := damage_at(bar, th, miss.length(), 0.0, str(th["fuze"]) != "none", rng, true)
		if bool(dmg["crit"]):
			crit += 1
		if bool(dmg["fire"]):
			fire += 1
	var nf := float(maxi(n, 1))
	return {"p_site_crit": crit / nf, "p_site_fire": fire / nf}


## Человекочитаемое имя исхода.
static func outcome_name(oc: String) -> String:
	match oc:
		"caught": return "затримано сіткою"
		"breach_wreck": return "полотно прорвано, планер зруйновано"
		"breach": return "прорив на об'єкт"
		"leak_over": return "перельот над кромкою"
		"leak_under": return "пройшов під кромкою"
		"leak_gap": return "розрив між секціями"
		"leak_down": return "заслін опущено (вітер)"
		"through_cell": return "проскочив крізь вічко"
		"evaded": return "оператор ухилився"
	return oc
