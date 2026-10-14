#include "adif_detail.h"

#include <cstdint>
#include <cstring>

namespace adif {
namespace {

// Little-endian reads that stop at the end of the bytes.
struct Reader {
    std::string_view b;
    size_t at = 0;
    bool ok = true;
    bool need(size_t n) {
        if (!ok || b.size() - at < n) ok = false;
        return ok;
    }
    uint64_t le(size_t n) {
        if (!need(n)) return 0;
        uint64_t v = 0;
        for (size_t i = 0; i < n; ++i) v |= (uint64_t)(unsigned char)b[at + i] << (8 * i);
        at += n;
        return v;
    }
    uint8_t u8() { return (uint8_t)le(1); }
    int16_t i16() { return (int16_t)(uint16_t)le(2); }
    uint32_t u32() { return (uint32_t)le(4); }
    int32_t i32() { return (int32_t)u32(); }
};

}  // namespace

bool MapDetail::load(std::string_view bytes, std::string *error) {
    auto fail = [&](const char *why) {
        if (error) *error = why;
        *this = MapDetail();
        return false;
    };
    *this = MapDetail();
    Reader r{bytes};
    if (bytes.size() < 8 || std::memcmp(bytes.data(), "ADIFMAP1", 8) != 0) return fail("not a map detail file");
    r.at = 8;
    uint32_t layers = r.u32();
    if (!r.ok || layers > 64) return fail("bad layer count");
    for (uint32_t l = 0; l < layers; ++l) {
        uint8_t kind = r.u8();
        uint32_t count = r.u32();
        if (!r.ok || kind >= kDetailLayers) return fail("bad layer");
        if (count > (bytes.size() - r.at) / 17) return fail("too many shapes for the file");  // a shape takes 17 bytes at least
        auto &shapes = shapes_[kind];
        auto &pts = pts_[kind];
        for (uint32_t s = 0; s < count; ++s) {
            DetailShape sh;
            sh.west = r.i16() / 100.0f, sh.south = r.i16() / 100.0f, sh.east = r.i16() / 100.0f, sh.north = r.i16() / 100.0f;
            sh.rank = r.u8();
            uint32_t n = r.u32();
            if (!r.ok || n == 0 || n > (bytes.size() - r.at) / 4 + 2) return fail("bad shape");
            sh.first = pts.size() / 2, sh.count = n;
            int32_t x = r.i32(), y = r.i32();
            pts.push_back(x / 1e4f), pts.push_back(y / 1e4f);
            for (uint32_t i = 1; i < n && r.ok; ++i) {
                int16_t dx = r.i16(), dy = r.i16();
                if (dx == -32768 && dy == -32768) x = r.i32(), y = r.i32();  // a long step
                else x += dx, y += dy;
                pts.push_back(x / 1e4f), pts.push_back(y / 1e4f);
            }
            if (!r.ok) return fail("truncated shape");
            shapes.push_back(sh);
        }
    }
    uint32_t cities = r.u32();
    if (!r.ok || cities > (bytes.size() - r.at) / 14) return fail("bad city count");
    for (uint32_t c = 0; c < cities; ++c) {
        DetailCity city;
        city.lon = r.i32() / 1e4, city.lat = r.i32() / 1e4;
        city.population = (long)r.u32();
        city.minZoom = r.u8() / 10.0;
        uint8_t len = r.u8();
        if (!r.need(len)) return fail("truncated city");
        city.name.assign(bytes.data() + r.at, len);
        r.at += len;
        cities_.push_back(std::move(city));
    }
    if (r.at != bytes.size()) return fail("bytes left over");
    return true;
}

std::vector<std::pair<double, double>> MapDetail::points(DetailLayer l, const DetailShape &s) const {
    const auto &pts = pts_[(size_t)l];
    std::vector<std::pair<double, double>> out;
    if ((s.first + s.count) * 2 > pts.size()) return out;
    out.reserve(s.count);
    for (size_t i = s.first; i < s.first + s.count; ++i) out.emplace_back(pts[2 * i], pts[2 * i + 1]);
    return out;
}

std::vector<size_t> MapDetail::within(DetailLayer l, double west, double south, double east, double north) const {
    std::vector<size_t> out;
    const auto &shapes = shapes_[(size_t)l];
    for (size_t i = 0; i < shapes.size(); ++i) {
        const DetailShape &s = shapes[i];
        if (s.east >= west && s.west <= east && s.north >= south && s.south <= north) out.push_back(i);
    }
    return out;
}

}  // namespace adif
