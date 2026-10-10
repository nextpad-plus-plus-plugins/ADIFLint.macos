#import "LotwUsers.h"

#import "Lookup.h"
#import "PluginHost.h"
#include "adif_qsl.h"

#include <sys/stat.h>

#include <ctime>

namespace {

adif::LotwUsers users;
bool loaded = false, refreshing = false, refreshedThisRun = false;
std::string listDate;  // the file's date, YYYY-MM-DD

std::string cachePath() {
    std::string dir = adifhost::configDir();
    return dir.empty() ? std::string() : dir + "/lotw-user-activity.csv";
}

std::string fileDate(const std::string &path, double *ageDays) {
    struct stat st{};
    if (path.empty() || stat(path.c_str(), &st) != 0) return "";
    if (ageDays) *ageDays = difftime(time(nullptr), st.st_mtime) / 86400.0;
    struct tm tm{};
    gmtime_r(&st.st_mtime, &tm);
    char buf[16];
    strftime(buf, sizeof buf, "%Y-%m-%d", &tm);
    return buf;
}

void loadCache() {
    loaded = true;
    NSData *d = [NSData dataWithContentsOfFile:@(cachePath().c_str())];
    if (d.length) users.load(std::string_view((const char *)d.bytes, d.length));
    listDate = fileDate(cachePath(), nullptr);
}

std::string grouped(size_t n) {
    std::string s = std::to_string(n);
    for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert((size_t)i, ",");
    return s;
}

}  // namespace

bool ADIFLotwUsersOn(void) { return adifhost::setting("lotwUsers") == "1"; }
void ADIFSetLotwUsersOn(bool on) { adifhost::setSetting("lotwUsers", on ? "1" : "0"); }

NSString *ADIFLotwUsersStatus(void) {
    if (!loaded) loadCache();
    if (!users.size()) return ADIFLotwUsersOn() ? @"Not downloaded yet: press Update." : @"Off.";
    std::string s = grouped(users.size()) + " calls, downloaded " + listDate + (ADIFLotwUsersOn() ? "." : " (off).");
    return @(s.c_str());
}

void ADIFUpdateLotwUsers(void (^done)(BOOL ok, NSString *message)) {
    refreshing = true;
    NSString *agent = [NSString stringWithFormat:@"ADIFLint/%s", ADIFLINT_VERSION];
    ADIFDownloadLotwUsers(agent, ^(NSData *body, NSString *error) {
        refreshing = false;
        if (error) {
            done(NO, [@"Could not download the LoTW user list: " stringByAppendingString:error]);
            return;
        }
        adif::LotwUsers fresh;
        if (fresh.load(std::string_view((const char *)body.bytes, body.length)) < 1) {
            done(NO, @"The download wasn't ARRL's LoTW user list; the old copy is kept.");
            return;
        }
        std::string path = cachePath();
        if (!path.empty()) [body writeToFile:@(path.c_str()) options:NSDataWritingAtomic error:nil];
        users = std::move(fresh);
        loaded = true;
        listDate = fileDate(path, nullptr);
        done(YES, ADIFLotwUsersStatus());
    });
}

std::string ADIFLotwLastUpload(const std::string &call) {
    if (!ADIFLotwUsersOn()) return "";
    if (!loaded) loadCache();
    double age = 0;
    if (!refreshing && !refreshedThisRun && (fileDate(cachePath(), &age).empty() || age > 7)) {
        refreshedThisRun = true;
        ADIFUpdateLotwUsers(^(BOOL, NSString *) {});
    }
    return users.lastUpload(call);
}

std::string ADIFLotwNote(const std::string &call) {
    std::string d = ADIFLotwLastUpload(call);
    if (d.empty()) return "";
    char buf[16];
    time_t yearAgo = time(nullptr) - 365 * 86400;
    struct tm tm{};
    gmtime_r(&yearAgo, &tm);
    strftime(buf, sizeof buf, "%Y-%m-%d", &tm);
    return d >= buf ? "LoTW user (last upload " + d + ")" : "LoTW: last upload " + d;
}
