// IOTA's island groups (adif::IotaGroup) for the Map's IOTA overlay. The list is © RSGB and
// IOTA Ltd, who allow downloading it for personal non-commercial use, so none of it ships
// with the plugin: Settings downloads it, only when asked, into the plugin config folder.
#pragma once

#import <Foundation/Foundation.h>

#include "adif_world.h"

#include <vector>

// The groups downloaded; empty before the first download.
const std::vector<adif::IotaGroup> &ADIFIotaGroups(void);
// "1,178 groups, downloaded 2026-10-13.", "Not downloaded."
NSString *ADIFIotaGroupsStatus(void);
// Download the list, check it, save it, use it. Completion on the main queue.
void ADIFUpdateIotaGroups(void (^done)(BOOL ok, NSString *message));
