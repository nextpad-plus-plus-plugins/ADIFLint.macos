// Who uploads to LoTW, from ARRL's weekly lotw-user-activity.csv (adif_qsl.h), shown in
// New QSO's lookup line and the Spots window. Off until turned on in Settings; the
// copy is kept in the plugin config folder and refreshed when a week old.
#pragma once

#import <Foundation/Foundation.h>

#include <string>

bool ADIFLotwUsersOn(void);
void ADIFSetLotwUsersOn(bool on);
// "186,523 calls, ARRL's list of 2026-10-05", "Not downloaded yet", "Off".
NSString *ADIFLotwUsersStatus(void);
// Download the list, check it, save it, use it. Completion on the main queue.
void ADIFUpdateLotwUsers(void (^done)(BOOL ok, NSString *message));
// The call's last LoTW upload ("2026-07-27"), or "" (off, not downloaded, not a user).
// A list more than a week old is refreshed in the background, once per run.
std::string ADIFLotwLastUpload(const std::string &call);
// "LoTW user (last upload 2026-07-27)", "LoTW: last upload 2019-01-02", or "".
std::string ADIFLotwNote(const std::string &call);
