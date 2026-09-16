# Источники данных и лицензии

Проект UAV Terrain Proto использует только открытые данные. При распространении билда этот файл
должен идти вместе с ним (требование лицензий Copernicus и ODbL).

| Слой | Источник | Лицензия | Требование |
|---|---|---|---|
| Рельеф (DEM) | Mapzen / AWS Terrain Tiles (terrarium), исходник SRTM/NASA + др. | открытая (см. https://github.com/tilezen/joerd/blob/master/docs/attribution.md) | указать «Terrain: Mapzen/AWS Terrain Tiles» |
| Спутниковая подложка | Copernicus Sentinel-2 L2A (ESA), через AWS Open Data `sentinel-cogs` | Copernicus Sentinel data — свободное использование, включая коммерческое | указать «Contains modified Copernicus Sentinel data [год]» и ID сцен (см. `godot/assets/meta.json` → `attribution`) |
| Дороги, здания, водотоки, водоёмы | © OpenStreetMap contributors, через Overpass API | ODbL 1.0 | указать «© OpenStreetMap contributors»; производные БД (`roads.json`, `buildings.json`, `water.json`, `lakes.json`) — под ODbL (share-alike для БД, не для рендеринга) |
| Фототекстуры (трава, грунт, скала, черепица, стена, асфальт, гравий) | Poly Haven | CC0 (public domain) | атрибуция не требуется |
| Фасады (окна/двери/ставни) | нарисованы в проекте (`tools/make_facades.py`) | собственные | — |
| Звук | синтезируется в рантайме | собственный | — |
| Музыка меню (`assets/audio/menu_theme.wav`) | сгенерирована `tools/make_menu_music.py` (numpy, без сэмплов) | собственная | — |
| Шрифты меню (Unbounded, Oswald, Manrope, IBM Plex Mono) | Google Fonts (`godot/assets/fonts/`) | SIL Open Font License 1.1 | тексты лицензий `OFL-*.txt` лежат рядом со шрифтами |

Строка атрибуции показывается внизу экрана в самом приложении.

## Что НЕ используется (намеренно)
- Google Maps / Photorealistic 3D Tiles — ToS запрещают военное/High-Risk применение и офлайн-кэш; нет покрытия Украины.
- EOX Sentinel-2 cloudless — CC-BY-NC (некоммерческая) — вычищено 13.08.2026.
- Аэрофото/кадастровая карта Украины — закрыты с 2022 г.
