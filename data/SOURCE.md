# Country data

`cty.csv` is Jim Reisert AD1C's Big CTY country file, release of 15 September 2026,
from https://www.country-files.com/bigcty/download/2026/bigcty-20260915.zip
(downloaded 2026-10-07). It is MIT-licensed; the notice is in `cty-copyright.txt`.

The plugin installs this copy next to `ADIFLint.dylib`. **Settings → Country Data →
Update** downloads the newest release into the plugin config folder, and that copy
is used from then on.

# Map overlays

The Map's **CQ zones** and **ITU zones** come from `cqzones.geojson` and `ituzones.geojson` in
HB9HIL's https://github.com/HB9HIL/hamradio-zones-geojson, commit
19599364fe316b36182f02dbe99deffab5801111 (2024-10-31; downloaded 2026-10-10). They are
MIT-licensed; the notice is in `zones-license.txt`. They are the zone files Wavelog uses. The
repository does not say where the lines were drawn from, so treat them as approximate: zone
lines across the sea are not exact in any source, and sources disagree in places.

**US states** and **Countries** come from Natural Earth's
`ne_50m_admin_1_states_provinces.geojson` and `ne_50m_admin_0_countries.geojson` (public
domain), from https://github.com/nvkelso/natural-earth-vector commit ca96624 (downloaded
2026-10-10).

`tools/gen_map_overlays.py` turns the four files into `src/core/adif_overlays_data.cpp`.
