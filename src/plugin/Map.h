// Map... : the log on a world map, offline. Worked grid squares (green when
// confirmed), DXCC from country data, the parks you hunted and your
// own grid, over Natural Earth's land outline (adif_world.h); PNG export.
#pragma once

namespace worldmap {

void cmdMap();
void documentChanged();  // the log changed or another became active
void iotaGroupsChanged();  // IOTA's group list was downloaded (Settings)

}  // namespace worldmap
