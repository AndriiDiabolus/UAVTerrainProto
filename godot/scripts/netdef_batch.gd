extends RefCounted
## ПОЛИГОН «СЕТЕВОЙ ЗАСЛОН» — пакетный прогон (Монте-Карло) и самопроверки модели.
##
## Запуск без сцены и без рельефа (мгновенно, headless):
##   ./run.sh -- --netbatch            # все сценарии × все угрозы × 3 ветра, 300 попыток
##   ./run.sh -- --netbatch=1000 --netscen=azs_aero
##   ./run.sh -- --nettest             # самопроверки физики (exit 0/1)
##
## Пишет netdef_runs.csv (машинно) и netdef_summary.md (читаемо) в --netout= или user://netdef/.

const M := preload("res://scripts/netdef_model.gd")


# ─────────── СЦЕНАРИИ: конфигурации заслона, которые сравниваем ───────────
const SCENARIOS := {
	"azs_mast": {
		"name": "АЗС · щогли 50 м (постійний ближній периметр)",
		"site": "azs", "carrier": "mast_50", "net": "mid_03", "absorber": "brake",
		"r_stand": 90.0, "h_top": 48.0, "h_bot": 6.0, "seg_w": 30.0, "gap": 3.0, "arc_deg": 360.0
	},
	"azs_aero": {
		"name": "АЗС · аеростати 150 м³, рубіж 200 м, полотно до 66 м",
		"site": "azs", "carrier": "aero_150", "net": "light_05", "absorber": "brake",
		"r_stand": 200.0, "h_top": 66.0, "h_bot": 10.0, "seg_w": 30.0, "gap": 4.0, "arc_deg": 360.0
	},
	"azs_aero_hd": {
		"name": "АЗС · аеростати 400 м³, рубіж 300 м, полотно до 190 м",
		"site": "azs", "carrier": "aero_400", "net": "light_05", "absorber": "brake_hd",
		"r_stand": 300.0, "h_top": 190.0, "h_bot": 12.0, "seg_w": 30.0, "gap": 4.0, "arc_deg": 360.0
	},
	"azs_opt": {
		"name": "АЗС · рекомендована геометрія: аеростати 400 м³, рубіж 140 м, полотно до 180 м",
		"site": "azs", "carrier": "aero_400", "net": "light_05", "absorber": "brake_hd",
		"r_stand": 140.0, "h_top": 180.0, "h_bot": 12.0, "seg_w": 31.5, "gap": 4.0, "arc_deg": 360.0
	},
	"azs_multi": {
		"name": "АЗС · мультикоптери за тривогою, рубіж 160 м",
		"site": "azs", "carrier": "multi_60", "net": "light_05", "absorber": "tearweb",
		"r_stand": 160.0, "h_top": 60.0, "h_bot": 32.0, "seg_w": 18.0, "gap": 5.0, "arc_deg": 360.0
	},
	"azs_sector": {
		"name": "АЗС · сектор загрози 120°, аеростати 400 м³",
		"site": "azs", "carrier": "aero_400", "net": "light_05", "absorber": "brake_hd",
		"r_stand": 300.0, "h_top": 190.0, "h_bot": 12.0, "seg_w": 30.0, "gap": 4.0, "arc_deg": 120.0
	},
	"azs_cheap": {
		"name": "АЗС · бюджет: аеростати 60 м³, нейлон, без поглинача",
		"site": "azs", "carrier": "aero_60", "net": "nylon_04", "absorber": "none",
		"r_stand": 150.0, "h_top": 110.0, "h_bot": 10.0, "seg_w": 30.0, "gap": 8.0, "arc_deg": 360.0
	},
	"sub_aero": {
		"name": "Підстанція · аеростати 400 м³, рубіж 350 м",
		"site": "substation", "carrier": "aero_400", "net": "light_05", "absorber": "brake_hd",
		"r_stand": 350.0, "h_top": 190.0, "h_bot": 15.0, "seg_w": 30.0, "gap": 4.0, "arc_deg": 360.0
	},
	"depot_sector": {
		"name": "Нафтобаза · сектор 180°, рубіж 400 м",
		"site": "depot", "carrier": "aero_400", "net": "light_05", "absorber": "brake_hd",
		"r_stand": 400.0, "h_top": 190.0, "h_bot": 15.0, "seg_w": 30.0, "gap": 4.0, "arc_deg": 180.0
	}
}

const THREAT_ORDER := ["shahed", "gerbera", "lancet", "molniya", "fpv7", "fpv_fiber", "shahed_jet"]
const WINDS := [3.0, 10.0, 17.0]


static func out_dir() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--netout="):
			return a.substr(9)
	var d := "user://netdef"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
	return d


## Полный прогон. Возвращает массив строк-результатов.
static func run() -> Array:
	var args := OS.get_cmdline_user_args()
	var n := 300
	var only := ""
	var winds: Array = WINDS.duplicate()
	for a in args:
		if a.begins_with("--netbatch="):
			n = maxi(int(a.substr(11)), 1)
		elif a.begins_with("--netscen="):
			only = a.substr(10)
		elif a.begins_with("--netwind="):
			winds = []
			for p in a.substr(10).split(","):
				winds.append(float(p))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260920

	var rows: Array = []
	var base: Dictionary = {}          # site → threat → доля попыток, выводящих объект из строя без заслона
	var keys: Array = SCENARIOS.keys()
	if only != "":
		keys = [only] if SCENARIOS.has(only) else []
		if keys.is_empty():
			push_error("нет сценария %s" % only)
			return []
	print("\n╔══ ПОЛІГОН «СІТЬОВИЙ ЗАСЛОН» — Монте-Карло, %d спроб на зв'язку ══╗\n" % n)
	# базовый уровень: те же удары по тем же объектам без всякого заслона
	var sites: Array = []
	for k_v: Variant in keys:
		var sid := str(SCENARIOS[str(k_v)]["site"])
		if not sites.has(sid):
			sites.append(sid)
	print("─── БЕЗ ЗАСЛОНУ (базовий рівень): частка спроб, що виводять об'єкт з ладу")
	for sid_v: Variant in sites:
		var sid := str(sid_v)
		base[sid] = {}
		var line: Array = []
		for t_v: Variant in THREAT_ORDER:
			var t := str(t_v)
			var b := M.baseline(sid, t, n, rng)
			base[sid][t] = float(b["p_site_crit"])
			line.append("%s %.0f%%" % [M.THREATS[t]["short"], float(b["p_site_crit"]) * 100.0])
		print("    %-34s %s" % [M.SITES[sid]["name"], ", ".join(line)])
	print("")
	for k_v: Variant in keys:
		var k := str(k_v)
		var cfg: Dictionary = SCENARIOS[k]
		var bar := M.build_barrier(cfg)
		_print_barrier(k, cfg, bar)
		for w_v: Variant in winds:
			var w := float(w_v)
			for t_v: Variant in THREAT_ORDER:
				var t := str(t_v)
				var agg := M.monte(bar, t, n, rng, w)
				agg["base_crit"] = float(base[str(cfg["site"])][t])
				agg["scen"] = k
				agg["scen_name"] = str(cfg["name"])
				agg["site"] = str(cfg["site"])
				rows.append(agg)
			_print_wind_block(bar, w, rows, k)
	_write_csv(rows, n)
	_write_summary(rows, n, keys, base)
	return rows


static func _print_barrier(k: String, cfg: Dictionary, bar: Dictionary) -> void:
	var net: Dictionary = bar["net"]
	print("─── [%s] %s" % [k, cfg["name"]])
	print("    рубіж %.0f м · кромка %.0f…%.0f м · фронт %.0f м · секцій %d (по %.0f м) · носіїв %d"
		% [bar["r_stand"], bar["h_bot"], bar["h_top"], bar["front_m"], bar["n_seg"], bar["seg_w"], bar["carriers_n"]])
	print("    полотно %s: вічко %.2f м, шнур %.1f мм %s → %.3f кг/м², заповненість %.1f%%, розривна нитки %.1f кН"
		% [net["name"], net["cell"], net["d"], net["mat"], net["areal"], float(net["solidity"]) * 100.0, net["break_kn"]])
	var verdict := "ПІДНІМЕ"
	if not bar["lift_ok"]:
		verdict = "НЕ ПІДНІМЕ — конфігурація нереалізована"
	elif float(bar["reserve"]) < 1.5:
		verdict = "піднімає без запасу (ляже за вітром)"
	print("    маса полотна: %.0f кг на секцію, %.0f кг усього · носій тягне %.0f кг (запас ×%.1f) → %s"
		% [bar["net_mass_seg"], bar["net_mass_total"], bar["payload"], bar["reserve"], verdict])
	print("    поглинач: %s (%.0f кН × %.0f м = %.0f кДж) · покриття фронту %.0f%% · вітер до %.0f м/с"
		% [bar["absorber"]["name"], bar["absorber"]["force"], bar["absorber"]["stroke"],
		   float(bar["e_abs"]) * 0.001, float(bar["coverage"]) * 100.0, bar["wind_max"]])
	var fw := M.force_window(bar, minf(17.0, float(bar["wind_max"])))
	print("    вікно сил (Шахед, вітер %.0f м/с): анкери %.1f кН < гальмо %.0f кН < полотно %.0f кН → %s"
		% [minf(17.0, float(bar["wind_max"])), fw["wind_kn"], fw["brake_kn"], fw["net_kn"],
		   "ОК" if fw["ok"] else "ПОЗА ВІКНОМ"])


static func _print_wind_block(bar: Dictionary, w: float, rows: Array, scen: String) -> void:
	var ws := M.wind_state(bar, w)
	print("\n    ВІТЕР %.0f м/с → нахил %.0f°, робоча кромка %.0f м (з %.0f), натяг %.0f кН, на анкери %.0f кН%s"
		% [w, ws["tilt_deg"], ws["h_eff"], bar["h_top"], ws["tension_kn"], ws["anchor_kn"],
		   "  ⚠ ЗАСЛІН ОПУЩЕНО" if ws["down"] else ""])
	print("    %-26s %8s %9s %10s   %s" % ["загроза", "затрим.", "об'єкт✗", "було→стало", "розподіл наслідків"])
	for r_v: Variant in rows:
		var r: Dictionary = r_v
		if str(r.get("scen", "")) != scen or absf(float(r["wind"]) - w) > 0.01:
			continue
		var th: Dictionary = M.THREATS[str(r["threat"])]
		var parts: Array = []
		var counts: Dictionary = r["counts"]
		var ck: Array = counts.keys()
		ck.sort_custom(func(a, b): return int(counts[a]) > int(counts[b]))
		for c_v: Variant in ck:
			var c := str(c_v)
			parts.append("%s %d%%" % [M.outcome_name(c), roundi(float(counts[c]) / float(r["n"]) * 100.0)])
		var b: float = float(r.get("base_crit", 1.0))
		var cur: float = float(r["p_site_crit"])
		print("    %-26s %7.0f%% %8.0f%% %9s   %s"
			% [th["short"], float(r["p_stop"]) * 100.0, cur * 100.0,
			   "%.0f→%.0f%%" % [b * 100.0, cur * 100.0], ", ".join(parts)])
	print("")


static func _write_csv(rows: Array, n: int) -> void:
	var path := out_dir() + "/netdef_runs.csv"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("не открыть %s" % path); return
	f.store_line("scenario,scenario_name,site,threat,threat_name,wind_ms,n,p_base_crit,p_stop,p_site_crit,p_site_fire,p_deton,avg_g,outcomes")
	for r_v: Variant in rows:
		var r: Dictionary = r_v
		var th: Dictionary = M.THREATS[str(r["threat"])]
		var counts: Dictionary = r["counts"]
		var oc: Array = []
		for c_v: Variant in counts.keys():
			oc.append("%s=%d" % [str(c_v), int(counts[c_v])])
		f.store_line("%s,\"%s\",%s,%s,\"%s\",%.1f,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,\"%s\"" % [
			r.get("scen", ""), r.get("scen_name", ""), r.get("site", ""), r["threat"], th["name"],
			r["wind"], n, r.get("base_crit", 1.0), r["p_stop"], r["p_site_crit"], r["p_site_fire"],
			r["p_deton"], r["avg_ng"], ";".join(oc)])
	f.close()
	print("CSV: %s" % ProjectSettings.globalize_path(path))


static func _write_summary(rows: Array, n: int, keys: Array, base: Dictionary) -> void:
	var path := out_dir() + "/netdef_summary.md"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("# Полігон «сітьовий заслон» — зведення Монте-Карло")
	f.store_line("")
	f.store_line("Спроб на зв'язку: **%d**. Дата прогону: %s." % [n, Time.get_date_string_from_system()])
	f.store_line("Модель і всі припущення: `docs/netdef_model.md`. Сирі дані: `netdef_runs.csv`.")
	f.store_line("")
	f.store_line("«Затримано» — заслін не пропустив виріб до об'єкта. «Об'єкт ✗» — уражено критичний")
	f.store_line("елемент (для АЗС: резервуари, ПРК або модуль СВГ), тобто заправка вибула з ладу.")
	f.store_line("")
	for k_v: Variant in keys:
		var k := str(k_v)
		if not SCENARIOS.has(k):
			continue
		var cfg: Dictionary = SCENARIOS[k]
		var bar := M.build_barrier(cfg)
		f.store_line("## %s" % cfg["name"])
		f.store_line("")
		f.store_line("- Рубіж **%.0f м**, полотно **%.0f…%.0f м**, секцій %d × %.0f м, носіїв **%d** (%s)"
			% [bar["r_stand"], bar["h_bot"], bar["h_top"], bar["n_seg"], bar["seg_w"],
			   bar["carriers_n"], bar["carrier"]["name"]])
		f.store_line("- Полотно: вічко %.2f м, %.1f мм %s → **%.0f кг на секцію** (носій піднімає %.0f кг — %s)"
			% [bar["net"]["cell"], bar["net"]["d"], bar["net"]["mat"], bar["net_mass_seg"],
			   bar["payload"], "ок" if bar["lift_ok"] else "**НЕ ПІДНІМЕ**"])
		f.store_line("- Поглинач: %s, **%.0f кДж** на якорях" % [bar["absorber"]["name"], float(bar["e_abs"]) * 0.001])
		f.store_line("")
		f.store_line("| вітер | загроза | затримано заслоном | об'єкт вибув: без заслону → із заслоном | середня перевантага |")
		f.store_line("|---|---|---|---|---|")
		for r_v: Variant in rows:
			var r: Dictionary = r_v
			if str(r.get("scen", "")) != k:
				continue
			var th: Dictionary = M.THREATS[str(r["threat"])]
			f.store_line("| %.0f м/с | %s | %.0f %% | **%.0f %% → %.0f %%** | %.0f g |"
				% [r["wind"], th["short"], float(r["p_stop"]) * 100.0,
				   float(r.get("base_crit", 1.0)) * 100.0, float(r["p_site_crit"]) * 100.0, r["avg_ng"]])
		f.store_line("")
	f.close()
	print("Зведення: %s" % ProjectSettings.globalize_path(path))


# ═══════════════════ РАЗВЁРТКА ПО ГЕОМЕТРИИ РУБЕЖА ═══════════════════
# Нетривиальный эффект: изделие снижается на объект, поэтому чем ближе рубеж,
# тем НИЖЕ точка пересечения полотна — ближний рубеж перехватывает лучше.
# Но подрыв тогда ближе к объекту. Развёртка ищет компромисс.

# Репрезентативная смесь угроз (доли одного массированного налёта)
const MIX := {"shahed": 0.40, "gerbera": 0.25, "molniya": 0.15, "fpv7": 0.10, "lancet": 0.10}


static func sweep() -> void:
	var args := OS.get_cmdline_user_args()
	var n := 250
	var site := "azs"
	var carrier := "aero_400"
	var net := "light_05"
	var absorber := "brake_hd"
	for a in args:
		if a.begins_with("--netsweep="):
			n = maxi(int(a.substr(11)), 20)
		elif a.begins_with("--netsite="):
			site = a.substr(10)
		elif a.begins_with("--netcarrier="):
			carrier = a.substr(13)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260921
	var winds: Array = [3.0, 9.0]
	print("\n╔══ РОЗГОРТКА ГЕОМЕТРІЇ РУБЕЖУ ══╗")
	print("об'єкт: %s · носій: %s · полотно: %s · поглинач: %s · %d спроб на клітинку"
		% [M.SITES[site]["name"], M.CARRIERS[carrier]["name"], M.NETS[net]["name"],
		   M.ABSORBERS[absorber]["name"], n])
	print("суміш нальоту: " + ", ".join(_mix_names()))
	print("у клітинці — частка спроб, що виводять об'єкт з ладу (менше = краще), у дужках — носіїв\n")
	var r_list: Array = [80.0, 140.0, 200.0, 260.0, 320.0, 400.0, 500.0]
	var h_list: Array = [60.0, 100.0, 140.0, 180.0, 220.0, 260.0]
	var best: Array = []
	for w_v: Variant in winds:
		var w := float(w_v)
		print("    ── вітер %.0f м/с" % w)
		var head := "    h\\r   "
		for r_v: Variant in r_list:
			head += "%8.0f" % float(r_v)
		print(head)
		for h_v: Variant in h_list:
			var h := float(h_v)
			var line := "    %5.0f  " % h
			for r_v: Variant in r_list:
				var r := float(r_v)
				var cfg := _fit_cfg(site, carrier, net, absorber, r, h)
				if cfg.is_empty():
					line += "       —"
					continue
				var bar := M.build_barrier(cfg)
				var p := _mix_risk(bar, n, rng, w)
				line += "%7.0f%%" % (p * 100.0)
				best.append({"r": r, "h": h, "w": w, "p": p, "carriers": int(bar["carriers_n"]),
					"seg_w": float(bar["seg_w"]), "mass": float(bar["net_mass_total"])})
			print(line)
		print("")
	# лучшие связки по худшему из ветров
	var by_key := {}
	for b_v: Variant in best:
		var b: Dictionary = b_v
		var key := "%.0f_%.0f" % [b["r"], b["h"]]
		var prev: float = float(by_key.get(key, {"p": 0.0}).get("p", 0.0))
		if float(b["p"]) >= prev:
			by_key[key] = b
	var arr: Array = by_key.values()
	arr.sort_custom(func(a, b): return float(a["p"]) < float(b["p"]))
	print("    ТОП-6 геометрій (за найгіршим з перевірених вітрів):")
	for i in mini(6, arr.size()):
		var b: Dictionary = arr[i]
		print("    %d) рубіж %.0f м, кромка %.0f м → ризик %.0f %% · носіїв %d (секція %.0f м) · полотна %.1f т"
			% [i + 1, b["r"], b["h"], float(b["p"]) * 100.0, b["carriers"], b["seg_w"], float(b["mass"]) * 0.001])
	print("")


static func _mix_names() -> Array:
	var out: Array = []
	for k_v: Variant in MIX.keys():
		out.append("%s %.0f%%" % [M.THREATS[str(k_v)]["short"], float(MIX[k_v]) * 100.0])
	return out


## Подобрать ширину секции так, чтобы носитель держал полотно с запасом ×1.8.
static func _fit_cfg(site: String, carrier: String, net: String, absorber: String,
		r: float, h_top: float) -> Dictionary:
	var h_bot := 12.0
	var panel_h: float = maxf(h_top - h_bot, 1.0)
	var areal: float = float(M.net_props(net)["areal"])
	var payload := M.carrier_payload(carrier, h_top)
	if h_top > float(M.CARRIERS[carrier].get("h_max", 300.0)):
		return {}
	var seg_w: float = payload / 1.8 / maxf(panel_h * areal, 0.001)
	if seg_w < 12.0:
		return {}                              # секция уже 12 м — конструктивно бессмысленно
	seg_w = minf(seg_w, 50.0)
	return {
		"name": "розгортка", "site": site, "carrier": carrier, "net": net, "absorber": absorber,
		"r_stand": r, "h_top": h_top, "h_bot": h_bot, "seg_w": seg_w, "gap": 4.0, "arc_deg": 360.0
	}


## Взвешенный риск вывода объекта из строя по смеси угроз.
static func _mix_risk(bar: Dictionary, n: int, rng: RandomNumberGenerator, wind: float) -> float:
	var acc := 0.0
	for k_v: Variant in MIX.keys():
		var k := str(k_v)
		var agg := M.monte(bar, k, maxi(int(float(n) * float(MIX[k])), 30), rng, wind)
		acc += float(MIX[k]) * float(agg["p_site_crit"])
	return acc


# ═══════════════════ АНАЛИЗ ЧУВСТВИТЕЛЬНОСТИ ═══════════════════
# Каждый неуверенный коэффициент модели качается в правдоподобном диапазоне,
# остальные — в базе. Размах риска объекта показывает, что мерить на стенде первым.
# Общие случайные числа: перед каждой оценкой генератор пересевается одним сидом.

const SENS := [
	["knot", "міцність вузла полотна / шнура", 0.5, 1.0, "розрив зразків полотна з вузлами на стенді"],
	["eta", "частка нитей, що реально тримають виріб", 0.3, 0.7, "скид вантажу в секцію, тензодатчики на нитках"],
	["stroke_k", "пружний хід полотна (×)", 0.5, 1.5, "прогин полотна при скиді вантажу"],
	["brake_k", "фактична сила гальма / номінал", 0.7, 1.25, "стендова крива «сила–хід» гальма"],
	["anchor_share", "частка вітру полотна на анкери", 0.4, 0.8, "тензодатчики на анкерах і прив'язі при підйомі"],
	["cd_net", "Cd сітки", 0.9, 1.6, "підйом секції з датчиками при різному вітрі"],
	["cd_aero", "Cd оболонки аеростата", 0.08, 0.2, "підйом секції з датчиками при різному вітрі"],
	["evade", "частка ухилень оператора FPV", 0.05, 0.4, "опитування операторів, пуски макетів FPV у полотно"],
	["prop_pusher", "намотування на штовхальний гвинт", 0.3, 0.8, "удари макетом із гвинтом, що обертається"],
	["fz_imp_g0", "поріг інерційного підривника, g", 4.0, 16.0, "дані піротехніків про підривники Шахеда"],
	["fz_con_g0", "поріг контактного підривника, g", 2.0, 8.0, "дані піротехніків про підривники FPV/«Молнії»"],
	["glim_k", "міцність планерів (×)", 0.5, 2.0, "руйнування макета планера при гальмуванні"],
	["alt_k", "висота підходу (×)", 0.6, 1.5, "треки радарів ППО на останніх кілометрах"],
	["rdive_k", "дальність початку зниження (×)", 0.6, 1.6, "треки радарів ППО на останніх кілометрах"],
	["v_k", "швидкість виробів (×)", 0.85, 1.2, "треки радарів ППО"],
	["cep", "КВО прицілювання, м", 6.0, 30.0, "розбір влучань по об'єктах"],
	["tnt", "тротиловий еквівалент БЧ", 0.9, 1.5, "дані піротехніків"],
	["frag", "уламків на кг ВВ", 450.0, 1800.0, "дані піротехніків, розбір уламкових полів"],
	["wreck_det", "підрив уламків об ґрунт після прориву", 0.1, 0.9, "дані піротехніків: спрацювання підривника зруйнованого виробу"]
]


static func _risk_at(cfg: Dictionary, wind: float, n: int, seed: int) -> Dictionary:
	var bar := M.build_barrier(cfg)
	var rng := RandomNumberGenerator.new()
	var acc := 0.0
	var stop_sh := 0.0
	for k_v: Variant in MIX.keys():
		var k := str(k_v)
		rng.seed = seed + hash(k)
		var agg := M.monte(bar, k, maxi(int(float(n) * float(MIX[k])), 40), rng, wind)
		acc += float(MIX[k]) * float(agg["p_site_crit"])
		if k == "shahed":
			stop_sh = float(agg["p_stop"])
	return {"risk": acc, "stop_shahed": stop_sh}


static func sensitivity() -> void:
	var n := 4000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--netsens="):
			n = maxi(int(a.substr(10)), 500)
	var scen_id := "azs_opt"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--netscen="):
			scen_id = a.substr(10)
	var cfg: Dictionary = SCENARIOS[scen_id]
	var winds: Array = [3.0, 9.0]
	var seed := 777
	M.reset_k()
	var base: Array = []
	var noise: Array = []
	for w_v: Variant in winds:
		base.append(_risk_at(cfg, float(w_v), n, seed))
		noise.append(absf(float(_risk_at(cfg, float(w_v), n, seed + 1000)["risk"]) - float(base[-1]["risk"])))
	print("\n╔══ ЧУТЛИВІСТЬ МОДЕЛІ ══╗")
	print("конфігурація: %s" % cfg["name"])
	print("метрика: ризик вивести АЗС з ладу для суміші нальоту (%s), %d спроб на оцінку" % [", ".join(_mix_names()), n])
	print("база: вітер 3 м/с — %.1f %%, вітер 9 м/с — %.1f %% · шум оцінки ≈ %.1f п.п.\n"
		% [float(base[0]["risk"]) * 100.0, float(base[1]["risk"]) * 100.0, maxf(float(noise[0]), float(noise[1])) * 100.0])
	var rows: Array = []
	for p_v: Variant in SENS:
		var p: Array = p_v
		var key := str(p[0])
		var res := {"key": key, "name": str(p[1]), "lo": float(p[2]), "hi": float(p[3]), "how": str(p[4]),
			"base": float(M.K_DEFAULT[key]), "r": []}
		var swing := 0.0
		for wi in winds.size():
			M.reset_k(); M.K[key] = float(p[2])
			var lo := _risk_at(cfg, float(winds[wi]), n, seed)
			M.reset_k(); M.K[key] = float(p[3])
			var hi := _risk_at(cfg, float(winds[wi]), n, seed)
			M.reset_k()
			res["r"].append([float(lo["risk"]), float(hi["risk"])])
			swing = maxf(swing, absf(float(hi["risk"]) - float(lo["risk"])))
		res["swing"] = swing
		rows.append(res)
	rows.sort_custom(func(a, b): return float(a["swing"]) > float(b["swing"]))
	var nf: float = maxf(float(noise[0]), float(noise[1]))
	print("    %-44s %-13s %-17s %-17s %6s" % ["параметр (база)", "діапазон", "3 м/с: низ → верх", "9 м/с: низ → верх", "розмах"])
	for r_v: Variant in rows:
		var r: Dictionary = r_v
		var rr: Array = r["r"]
		print("    %-44s %-13s %5.1f → %5.1f %%   %5.1f → %5.1f %%   %5.1f п.п.%s"
			% ["%s (%s)" % [r["name"], _fmt(float(r["base"]))], "%s…%s" % [_fmt(float(r["lo"])), _fmt(float(r["hi"]))],
			   float(rr[0][0]) * 100.0, float(rr[0][1]) * 100.0, float(rr[1][0]) * 100.0, float(rr[1][1]) * 100.0,
			   float(r["swing"]) * 100.0, "" if float(r["swing"]) > nf * 2.0 else "  (у межах шуму)"])
	_write_sens(rows, cfg, base, nf, n)


static func _fmt(v: float) -> String:
	if absf(v - roundf(v)) < 0.001:
		return "%d" % int(roundf(v))
	return ("%.2f" % v).rstrip("0")


static func _write_sens(rows: Array, cfg: Dictionary, base: Array, nf: float, n: int) -> void:
	var d := out_dir()
	var f := FileAccess.open(d + "/netdef_sensitivity.csv", FileAccess.WRITE)
	f.store_line("param,name,base,low,high,risk_w3_low,risk_w3_high,risk_w9_low,risk_w9_high,swing,how_to_measure")
	for r_v: Variant in rows:
		var r: Dictionary = r_v
		var rr: Array = r["r"]
		f.store_line("%s,\"%s\",%s,%s,%s,%.4f,%.4f,%.4f,%.4f,%.4f,\"%s\"" % [r["key"], r["name"], r["base"], r["lo"], r["hi"],
			rr[0][0], rr[0][1], rr[1][0], rr[1][1], r["swing"], r["how"]])
	f.close()
	var m := FileAccess.open(d + "/netdef_sensitivity.md", FileAccess.WRITE)
	m.store_line("# Чутливість моделі сітьового заслону")
	m.store_line("")
	m.store_line("Конфігурація: **%s**. Метрика — ризик вивести АЗС з ладу для суміші нальоту, %d спроб на оцінку." % [cfg["name"], n])
	m.store_line("База: вітер 3 м/с — **%.1f %%**, 9 м/с — **%.1f %%**. Шум оцінки ≈ %.1f п.п." % [float(base[0]["risk"]) * 100.0, float(base[1]["risk"]) * 100.0, nf * 100.0])
	m.store_line("")
	m.store_line("| параметр (база) | діапазон | 3 м/с: низ → верх | 9 м/с: низ → верх | розмах | як виміряти |")
	m.store_line("|---|---|---|---|---|---|")
	for r_v: Variant in rows:
		var r: Dictionary = r_v
		var rr: Array = r["r"]
		m.store_line("| %s (%s) | %s…%s | %.0f → %.0f %% | %.0f → %.0f %% | **%.1f п.п.** | %s |" % [r["name"], _fmt(float(r["base"])),
			_fmt(float(r["lo"])), _fmt(float(r["hi"])), float(rr[0][0]) * 100.0, float(rr[0][1]) * 100.0,
			float(rr[1][0]) * 100.0, float(rr[1][1]) * 100.0, float(r["swing"]) * 100.0, r["how"]])
	m.close()
	print("\nCSV: %s/netdef_sensitivity.csv" % ProjectSettings.globalize_path(d))


# ═══════════════════ РОЗА ВЕТРОВ: ДОСТУПНОСТЬ ПО РЕГИОНАМ ═══════════════════
# Реальный почасовой ветер ERA5 на 100 м (tools/fetch_wind.py) сворачивается с кривой
# риска модели r(ветер): ожидаемый риск объекта за год, ночью (время налётов), зимой и летом.

const ROSE_CFGS := ["azs_opt", "azs_aero_hd", "azs_mast"]


static func windrose() -> void:
	var txt := FileAccess.get_file_as_string("res://assets/netdef/wind_hist.json")
	if txt.is_empty():
		push_error("нет assets/netdef/wind_hist.json — запустите tools/fetch_wind.py")
		return
	var data: Dictionary = JSON.parse_string(txt)
	var n := 1500
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--netwindrose="):
			n = maxi(int(a.substr(14)), 300)
	M.reset_k()
	print("\n╔══ ДОСТУПНІСТЬ ЗАСЛОНУ ЗА РЕАЛЬНИМИ ВІТРАМИ ══╗")
	print("вітер: %s, %d–%d, почасово, висота 100 м" % [data["source"], data["years"][0], data["years"][1]])
	print("метрика: очікуваний ризик вивести АЗС з ладу на одну атаку суміші нальоту (%s)\n" % ", ".join(_mix_names()))
	var curves := {}
	for c_v: Variant in ROSE_CFGS:
		var cid := str(c_v)
		var cfg: Dictionary = SCENARIOS[cid]
		var bar := M.build_barrier(cfg)
		var curve: Array = []
		var over: Array = []
		for w in 31:
			var r := _risk_at(cfg, float(w), n, 4242)
			curve.append(float(r["risk"]))
			over.append(float(w) > float(bar["wind_max"]) or float(M.wind_state(bar, float(w))["h_eff"]) < M.shot_height_at(M.shot_of("shahed", 120.0, 50.0), float(bar["r_stand"])) + 3.0)
		curves[cid] = {"risk": curve, "over": over}
		var pts: Array = []
		for w: int in [0, 3, 6, 9, 12, 15, 18, 22]:
			pts.append("%d м/с %.0f%%" % [w, float(curve[w]) * 100.0])
		print("── %s" % cfg["name"])
		print("   крива ризику: " + " · ".join(pts))
	print("")
	var lines: Array = []
	var md: Array = []
	md.append("# Доступність сітьового заслону за реальними вітрами")
	md.append("")
	md.append("Вітер: %s, %d–%d, почасово, висота 100 м (середина полотна). Метрика — очікуваний ризик вивести АЗС з ладу на одну атаку суміші нальоту. «Шахед поверх» — частка годин, коли кромка нижча за висоту перетину рубежу типовим Шахедом або заслін спущено." % [data["source"], data["years"][0], data["years"][1]])
	md.append("")
	md.append("ERA5 — годинні середні по комірці ~30 км: пориви й локальні ефекти (пагорби, забудова) не враховані, реальний вітер на майданчику треба міряти.")
	for c_v: Variant in ROSE_CFGS:
		var cid := str(c_v)
		var cv: Dictionary = curves[cid]
		print("── %s" % SCENARIOS[cid]["name"])
		print("   %-12s %8s %8s %8s %8s %13s %9s" % ["місто", "рік", "ніч", "зима", "літо", "Шахед поверх", "вітер 100 м"])
		md.append("")
		md.append("## %s" % SCENARIOS[cid]["name"])
		md.append("")
		md.append("| місто | ризик за рік | вночі | взимку | влітку | Шахед поверх (ніч) | середній вітер 100 м |")
		md.append("|---|---|---|---|---|---|---|")
		for reg_v: Variant in data["regions"]:
			var reg: Dictionary = reg_v
			var hs: Dictionary = reg["hist"]
			var e_all := _fold(hs["all"], cv["risk"])
			var e_n := _fold(hs["night"], cv["risk"])
			var e_w := _fold(hs["winter"], cv["risk"])
			var e_s := _fold(hs["summer"], cv["risk"])
			var o_n := _fold_bool(hs["night"], cv["over"])
			print("   %-12s %7.1f%% %7.1f%% %7.1f%% %7.1f%% %12.1f%% %6.1f м/с"
				% [reg["name"], e_all * 100.0, e_n * 100.0, e_w * 100.0, e_s * 100.0, o_n * 100.0, reg["mean100"]])
			md.append("| %s | %.0f %% | %.0f %% | %.0f %% | %.0f %% | %.0f %% | %.1f м/с |"
				% [reg["name"], e_all * 100.0, e_n * 100.0, e_w * 100.0, e_s * 100.0, o_n * 100.0, reg["mean100"]])
		print("")
	var f := FileAccess.open(out_dir() + "/netdef_windrose.md", FileAccess.WRITE)
	f.store_string("\n".join(md) + "\n")
	f.close()
	print("Звіт: %s/netdef_windrose.md" % ProjectSettings.globalize_path(out_dir()))


static func _fold(hist: Array, curve: Array) -> float:
	var s := 0.0
	var t := 0.0
	for i in hist.size():
		var h := float(hist[i])
		s += h * float(curve[mini(i, curve.size() - 1)])
		t += h
	return s / maxf(t, 1.0)


static func _fold_bool(hist: Array, flags: Array) -> float:
	var s := 0.0
	var t := 0.0
	for i in hist.size():
		var h := float(hist[i])
		if bool(flags[mini(i, flags.size() - 1)]):
			s += h
		t += h
	return s / maxf(t, 1.0)


# ═══════════════════ САМОПРОВЕРКИ МОДЕЛИ ═══════════════════

static func self_test() -> bool:
	var fails: Array = [0]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7

	# 1. Свойства сети: удельная масса лёгкого полотна в разумных пределах
	var np := M.net_props("light_05")
	_chk(fails, "полотно 0.5 м/D3: %.3f кг/м² (ждём 0.01…0.10)" % np["areal"],
		float(np["areal"]) > 0.01 and float(np["areal"]) < 0.10)
	_chk(fails, "розривна нитки D3 Dyneema = %.1f кН (ждём 5…12)" % np["break_kn"],
		float(np["break_kn"]) > 5.0 and float(np["break_kn"]) < 12.0)

	# 2. Ударная волна: 50 кг ТНТ на 50 м ≈ 8…13 кПа (справочные таблицы)
	var dp50 := M.overpressure(50.0, 50.0)
	_chk(fails, "ΔP 50 кг / 50 м = %.1f кПа (ждём 8…13)" % dp50, dp50 > 8.0 and dp50 < 13.0)
	var dp20 := M.overpressure(50.0, 20.0)
	_chk(fails, "ΔP 50 кг / 20 м = %.0f кПа (ждём 30…50)" % dp20, dp20 > 30.0 and dp20 < 50.0)
	_chk(fails, "ΔP спадає з відстанню", M.overpressure(50.0, 100.0) < dp50)

	# 3. Подъёмная сила аэростата падает с высотой и положительна у земли
	var p0 := M.carrier_payload("aero_150", 0.0)
	var p300 := M.carrier_payload("aero_150", 300.0)
	_chk(fails, "аеростат 150 м³ несе %.0f кг біля землі (ждём 60…140)" % p0, p0 > 60.0 and p0 < 140.0)
	_chk(fails, "підйомна сила падає з висотою (%.0f → %.0f кг)" % [p0, p300], p300 < p0)

	# 4. Якорный поглотитель — решающий для «Шахеда»
	var cfg_yes: Dictionary = SCENARIOS["azs_aero_hd"].duplicate()
	cfg_yes["gap"] = 0.0                                   # тест энергетики — без розыгрыша зазоров
	cfg_yes["absorber"] = "brake"
	var cfg_no: Dictionary = cfg_yes.duplicate()
	cfg_no["absorber"] = "none"
	var bar_no := M.build_barrier(cfg_no)
	var bar_yes := M.build_barrier(cfg_yes)
	_chk(fails, "запас підйомної сили ×%.1f (потрібно ≥1.5)" % bar_yes["reserve"],
		bool(bar_yes["lift_ok"]) and float(bar_yes["reserve"]) >= 1.5)
	for k_v: Variant in SCENARIOS.keys():
		var k := str(k_v)
		if k == "azs_cheap":
			continue
		var b := M.build_barrier(SCENARIOS[k])
		_chk(fails, "сценарій %s: запас ×%.1f" % [k, b["reserve"]],
			bool(b["lift_ok"]) and float(b["reserve"]) >= 1.5)
	var shot := M.shot_of("shahed", 120.0, 50.0, "low")
	var r_no := M.engage(bar_no, shot, rng, 3.0)
	var r_yes := M.engage(bar_yes, shot, rng, 3.0)
	_chk(fails, "Шахед без поглинача: %s" % r_no["outcome"], str(r_no["outcome"]).begins_with("breach"))
	_chk(fails, "Шахед з гальмівником: %s (%.0f g)" % [r_yes["outcome"], r_yes["n_g"]],
		str(r_yes["outcome"]) == "caught")

	# 5. Перелёт над кромкой при пикировании с высоты
	var r_hi := M.engage(bar_yes, M.shot_of("lancet", 900.0, 80.0, "dive"), rng, 3.0)
	_chk(fails, "пікірування з 600 м → %s" % r_hi["outcome"], str(r_hi["outcome"]) == "leak_over")

	# 6. Ветер выше предела кладёт барьер
	var ws := M.wind_state(bar_yes, 30.0)
	_chk(fails, "вітер 30 м/с → заслін опущено", bool(ws["down"]))
	var ws4 := M.wind_state(bar_yes, 4.0)
	_chk(fails, "вітер 4 м/с → робочий, нахил %.0f°" % ws4["tilt_deg"],
		not bool(ws4["down"]) and float(ws4["tilt_deg"]) < 45.0)

	# 6б. Нереализуемая конфигурация распознаётся, а не «работает молча»
	var bar_bad := M.build_barrier(SCENARIOS["azs_cheap"])
	_chk(fails, "бюджетна конфігурація визнана нереалізованою (%.0f кг проти %.0f кг)"
		% [bar_bad["net_mass_seg"], bar_bad["payload"]], not bool(bar_bad["lift_ok"]))
	_chk(fails, "нереалізований заслін пропускає загрозу",
		str(M.engage(bar_bad, shot, rng, 3.0)["outcome"]) == "leak_down")

	# 6в. Окно сил: тормоз не травит от ветра и стронется раньше, чем порвётся полотно
	var fw := M.force_window(bar_yes, 17.0)
	_chk(fails, "вікно сил: вітер %.1f кН < гальмо %.0f кН < полотно %.0f кН"
		% [fw["wind_kn"], fw["brake_kn"], fw["net_kn"]], bool(fw["ok"]))
	# силовая схема: пиковое замедление = порог тормоза / масса
	var cap := M.capture(bar_yes, 2.5, 200.0, 224000.0)
	var g_exp: float = float(bar_yes["absorber"]["force"]) * 1000.0 / (200.0 * M.G)
	_chk(fails, "Шахед 224 кДж: хід %.1f м, %.1f g (чекаємо %.1f g від гальма)"
		% [cap["travel"], cap["n_g"], g_exp],
		bool(cap["caught"]) and absf(float(cap["n_g"]) - g_exp) < 0.1)

	# 7. Сплошное покрытие не даёт утечек в зазор
	var cfg_full: Dictionary = SCENARIOS["azs_aero"].duplicate()
	cfg_full["gap"] = 0.0
	var bar_full := M.build_barrier(cfg_full)
	var gaps := 0
	var through := 0
	for i in 200:
		var s_f := M.shot_of("fpv7", 60.0, 32.0, "low")
		var oc := str(M.engage(bar_full, s_f, rng, 3.0)["outcome"])
		if oc == "leak_gap":
			gaps += 1
		elif oc == "through_cell":
			through += 1
	_chk(fails, "суцільне полотно: витоків у розрив %d (ждём 0)" % gaps, gaps == 0)

	# 8. FPV с винтами не проскакивает сквозь ячейку 0.5 м
	_chk(fails, "FPV крізь вічко 0.5 м: %d з 200 (ждём <8)" % through, through < 8)

	# 9. Лёгкая «Гербера» гарантированно останавливается
	var r_g := M.engage(bar_yes, M.shot_of("gerbera", 60.0, 38.0, "low"), rng, 3.0)
	_chk(fails, "Гербера: %s, %.0f g" % [r_g["outcome"], r_g["n_g"]], bool(r_g["stopped"]))

	# 10. Прямое попадание в АЗС выводит объект из строя
	var dmg := M.damage_at(bar_yes, M.THREATS["shahed"], 0.0, 0.0, true, rng, true)
	_chk(fails, "пряме влучання Шахеда в АЗС → критичне ураження", bool(dmg["crit"]))
	# и он же, остановленный на рубеже 220 м, объект не убивает
	var dmg_far := M.damage_at(bar_yes, M.THREATS["shahed"], 220.0, 0.0, true, rng)
	_chk(fails, "підрив на рубежі 220 м → об'єкт цілий (ΔP %.1f кПа)" % dmg_far["dp_max"], not bool(dmg_far["crit"]))

	print("NETTEST: %s (провалов: %d)" % ["ВСЕ OK" if int(fails[0]) == 0 else "ЕСТЬ FAIL", fails[0]])
	return int(fails[0]) == 0


static func _chk(fails: Array, name: String, ok: bool) -> void:
	print("NETTEST [%s] %s" % ["OK" if ok else "FAIL", name])
	if not ok:
		fails[0] = int(fails[0]) + 1
