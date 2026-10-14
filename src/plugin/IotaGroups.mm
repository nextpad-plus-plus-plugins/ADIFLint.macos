#import "IotaGroups.h"

#import "Lookup.h"
#import "PluginHost.h"

#include <sys/stat.h>

#include <ctime>

namespace {

std::vector<adif::IotaGroup> groups;
bool loaded = false;
std::string listDate;  // when it was downloaded, YYYY-MM-DD

std::string cachePath() {
    std::string dir = adifhost::configDir();
    return dir.empty() ? std::string() : dir + "/ADIFLint-iota-groups.json";
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

// The file's groups: a JSON array of objects whose values are strings. Anything else in it
// (another type, a bad reference or coordinate) is skipped.
std::vector<adif::IotaGroup> parse(NSData *data) {
    std::vector<adif::IotaGroup> out;
    if (data.length == 0 || data.length > 16 * 1024 * 1024) return out;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class]) return out;
    auto field = [](NSDictionary *d, NSString *key) -> std::string {
        id v = d[key];
        if ([v isKindOfClass:NSString.class]) return ((NSString *)v).UTF8String ?: "";
        if ([v isKindOfClass:NSNumber.class]) return ((NSNumber *)v).stringValue.UTF8String ?: "";
        return "";
    };
    for (id item in (NSArray *)json) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *d = item;
        adif::IotaGroup g;
        if (adif::iotaGroup(field(d, @"refno"), field(d, @"name"), field(d, @"dxcc_num"), field(d, @"latitude_min"), field(d, @"latitude_max"),
                            field(d, @"longitude_min"), field(d, @"longitude_max"), &g))
            out.push_back(std::move(g));
    }
    return out;
}

void loadCache() {
    loaded = true;
    groups = parse([NSData dataWithContentsOfFile:@(cachePath().c_str())]);
    listDate = fileDate(cachePath());
}

std::string grouped(size_t n) {
    std::string s = std::to_string(n);
    for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert((size_t)i, ",");
    return s;
}

}  // namespace

const std::vector<adif::IotaGroup> &ADIFIotaGroups(void) {
    if (!loaded) loadCache();
    return groups;
}

NSString *ADIFIotaGroupsStatus(void) {
    if (ADIFIotaGroups().empty()) return @"Not downloaded.";
    return @((grouped(groups.size()) + " groups" + (listDate.empty() ? "" : ", downloaded " + listDate) + ".").c_str());
}

void ADIFUpdateIotaGroups(void (^done)(BOOL ok, NSString *message)) {
    NSString *agent = [NSString stringWithFormat:@"ADIFLint/%s", ADIFLINT_VERSION];
    ADIFDownloadIotaGroups(agent, ^(NSData *body, NSString *error) {
        if (error) {
            done(NO, [@"Could not download IOTA's group list: " stringByAppendingString:error]);
            return;
        }
        std::vector<adif::IotaGroup> fresh = parse(body);
        if (fresh.empty()) {
            done(NO, groups.empty() ? @"The download wasn't IOTA's group list." : @"The download wasn't IOTA's group list; the old copy is kept.");
            return;
        }
        std::string path = cachePath();
        if (!path.empty()) [body writeToFile:@(path.c_str()) options:NSDataWritingAtomic error:nil];
        groups = std::move(fresh);
        loaded = true;
        listDate = fileDate(path);
        done(YES, ADIFIotaGroupsStatus());
    });
}
