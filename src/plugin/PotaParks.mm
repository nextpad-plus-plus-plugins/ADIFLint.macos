#import "PotaParks.h"

#import "Lookup.h"
#import "PluginHost.h"

#include <sys/stat.h>

#include <ctime>

namespace {

adif::PotaParks parks;
bool loaded = false;
std::string listDate;  // when it was downloaded, YYYY-MM-DD

std::string cachePath() {
    std::string dir = adifhost::configDir();
    return dir.empty() ? std::string() : dir + "/ADIFLint-pota-parks.csv";
}

std::string fileDate(const std::string &path) {
    struct stat st{};
    if (path.empty() || stat(path.c_str(), &st) != 0) return "";
    struct tm tm{};
    gmtime_r(&st.st_mtime, &tm);
    char buf[16];
    strftime(buf, sizeof buf, "%Y-%m-%d", &tm);
    return buf;
}

void loadCache() {
    loaded = true;
    NSData *d = [NSData dataWithContentsOfFile:@(cachePath().c_str())];
    if (d.length) parks.load(std::string_view((const char *)d.bytes, d.length));
    listDate = fileDate(cachePath());
}

std::string grouped(size_t n) {
    std::string s = std::to_string(n);
    for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert((size_t)i, ",");
    return s;
}

}  // namespace

const adif::PotaParks &ADIFPotaParks(void) {
    if (!loaded) loadCache();
    return parks;
}

NSString *ADIFPotaParksStatus(void) {
    if (!ADIFPotaParks().size()) return @"Not downloaded.";
    std::string s = grouped(parks.size()) + " parks (" + grouped(parks.active()) + " active)" + (listDate.empty() ? "" : ", downloaded " + listDate) + ".";
    return @(s.c_str());
}

void ADIFUpdatePotaParks(void (^done)(BOOL ok, NSString *message)) {
    NSString *agent = [NSString stringWithFormat:@"ADIFLint/%s", ADIFLINT_VERSION];
    ADIFDownloadPotaParks(agent, ^(NSData *body, NSString *error) {
        if (error) {
            done(NO, [@"Could not download POTA's park list: " stringByAppendingString:error]);
            return;
        }
        adif::PotaParks fresh;
        if (body.length > 64 * 1024 * 1024 || !fresh.load(std::string_view((const char *)body.bytes, body.length))) {
            done(NO, parks.size() ? @"The download wasn't POTA's park list; the old copy is kept." : @"The download wasn't POTA's park list.");
            return;
        }
        std::string path = cachePath();
        if (!path.empty()) [body writeToFile:@(path.c_str()) options:NSDataWritingAtomic error:nil];
        parks = std::move(fresh);
        loaded = true;
        listDate = fileDate(path);
        done(YES, ADIFPotaParksStatus());
    });
}
