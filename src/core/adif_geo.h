// Maidenhead locators, great-circle distance and bearing, for ADIF DISTANCE.
// ADIF 3.1.7: DISTANCE is "the distance between the logging station and the
// contacted station in kilometers via the specified signal path" (a Number
// >= 0); GRIDSQUARE and MY_GRIDSQUARE hold 2, 4, 6 or 8 characters. ANT_AZ is
// the antenna's azimuth, not the bearing, so only DISTANCE is written.
#pragma once

#include <string>
#include <string_view>

namespace adif {

// The centre of a 2, 4, 6 or 8 character locator, in degrees (north and east
// positive); false when it is not one.
bool gridToLatLon(std::string_view grid, double *lat, double *lon);
// An ADIF Location (§III.A: XDDD MM.MMM, as LAT and LON hold) in degrees, north and east
// positive; false when it is not one, or is a longitude where a latitude is wanted (or
// the other way round).
bool locationToDegrees(std::string_view v, bool latitude, double *degrees);
// Short-path great-circle distance in km (a sphere of radius 6371 km), and the
// initial bearing from the first point, in degrees clockwise from true north.
double greatCircleKm(double lat1, double lon1, double lat2, double lon2);
double initialBearing(double lat1, double lon1, double lat2, double lon2);
// DISTANCE between two locators, rounded to whole km; "" unless both are locators.
std::string gridDistanceKm(std::string_view myGrid, std::string_view grid);
// "1,804 km at 268°" between two locators, for showing; "" unless both are locators.
std::string gridDistanceText(std::string_view myGrid, std::string_view grid);

}  // namespace adif
