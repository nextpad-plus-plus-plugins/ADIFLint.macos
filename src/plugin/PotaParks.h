// POTA's park list (adif::PotaParks) for the Map's POTA overlay. Settings downloads it, only
// when asked, into the plugin config folder; it is never shipped with the plugin.
#pragma once

#import <Foundation/Foundation.h>

#include "adif_parks.h"

// The parks downloaded; empty before the first download. Read from the config folder once.
const adif::PotaParks &ADIFPotaParks(void);
// "96,624 parks (92,313 active), downloaded 2026-10-14.", "Not downloaded."
NSString *ADIFPotaParksStatus(void);
// Download the list, check it, save it, use it. Completion on the main queue.
void ADIFUpdatePotaParks(void (^done)(BOOL ok, NSString *message));
