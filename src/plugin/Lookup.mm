#import "Lookup.h"

#import <Security/Security.h>

#include "adif_upload.h"

// Endpoints (checked 2026-10-07):
//   QRZ.com XML 1.34: https://xmldata.qrz.com/xml/current/  login with username, password, agent
//     (GET or POST; this client POSTs so the password is not in a URL), then ?s=KEY;callsign=
//     The spec: "requires ... a valid QRZ.COM username and password"; there is no API-key login.
//   HamQTH 2.8:       https://www.hamqth.com/xml.php?u=&p=  then ?id=SESSION&callsign=&prg=
//   LoTW:             https://lotw.arrl.org/lotwuser/lotwreport.adi?login=&password=&qso_query=1&...
static NSString *const kQrzBase = @"https://xmldata.qrz.com/xml/current/";
static NSString *const kHamQthBase = @"https://www.hamqth.com/xml.php";
static NSString *const kLotwBase = @"https://lotw.arrl.org/lotwuser/lotwreport.adi";
// Uploads (see src/core/adif_upload.h for the documents these follow):
static NSString *const kQrzLogbookApi = @"https://logbook.qrz.com/api";
static NSString *const kClubLogPutLogs = @"https://clublog.org/putlogs.php";
static NSString *const kEqslImport = @"https://www.eQSL.cc/qslcard/ImportADIF.cfm";

NSString *ADIFSourceName(ADIFSource source) {
    switch (source) {
        case ADIFSourceQRZ: return @"QRZ.com";
        case ADIFSourceHamQTH: return @"HamQTH";
        case ADIFSourceLoTW: return @"LoTW";
        case ADIFSourceQRZLogbook: return @"QRZ.com Logbook";
        case ADIFSourceClubLog: return @"Club Log";
        case ADIFSourceClubLogKey: return @"Club Log API key";
        case ADIFSourceEQSL: return @"eQSL";
        case ADIFSourceTqsl: return @"TQSL certificate";
        case ADIFSourceCountryData: return @"Country Data";
    }
    return @"";
}

ADIFCredentialKind ADIFSourceCredentialKind(ADIFSource source) {
    return source == ADIFSourceQRZLogbook || source == ADIFSourceClubLogKey || source == ADIFSourceTqsl ? ADIFCredentialAPIKey
                                                                                                       : ADIFCredentialAccount;
}

NSString *ADIFSourceUserLabel(ADIFSource source) { return source == ADIFSourceClubLog ? @"Email" : @"Username"; }
NSString *ADIFSourceSecretLabel(ADIFSource source) {
    return ADIFSourceCredentialKind(source) == ADIFCredentialAPIKey && source != ADIFSourceTqsl ? @"API key" : @"Password";
}

BOOL ADIFSourceCanTest(ADIFSource source) { return source <= ADIFSourceQRZLogbook; }

NSString *ADIFSourceCredentialHelp(ADIFSource source) {
    switch (source) {
        case ADIFSourceQRZ:
            return @"Your QRZ.com username and password. QRZ's callsign lookups (the XML interface) sign in with these, "
                   @"not an API key. Grid, county and zones need a QRZ XML Logbook Data subscription.";
        case ADIFSourceHamQTH:
            return @"Your HamQTH.com username and password (a free account).";
        case ADIFSourceQRZLogbook:
            return @"The API access key from your QRZ.com Logbook's settings, for Upload to and Import from QRZ.com Logbook. Each "
                   @"logbook (callsign) has its own key; QSOs go to the logbook the key belongs to.";
        case ADIFSourceClubLog:
            return @"The email address of your Club Log account and an Application Password (Club Log: Settings > App "
                   @"Passwords), not your normal password. Club Log blocks programs that keep sending a wrong password, "
                   @"so uploads stop at the first sign-in error.";
        case ADIFSourceClubLogKey:
            return @"Club Log gives each program that uploads its own API key. Request one at clublog.org/requestapikey.php "
                   @"for your copy of ADIF Lint and paste it here. Don't share or publish it: Club Log deletes keys found "
                   @"online.";
        case ADIFSourceEQSL:
            return @"Your eQSL.cc username (usually your callsign) and password. eQSL receives them over HTTPS with each "
                   @"upload, and in the address of the InBox download, which is how eQSL documents it.";
        case ADIFSourceTqsl:
            return @"Only if your TQSL callsign certificate has a password: Upload to LoTW gives it to TQSL with -p. While "
                   @"TQSL runs (seconds), other programs on this Mac can see it in the process list. Leave it empty to "
                   @"have no password, or if TQSL should ask.";
        case ADIFSourceCountryData: return @"";
        case ADIFSourceLoTW:
            return @"Your LoTW website username (not always your callsign) and password, not your TQSL certificate "
                   @"password, for Import from LoTW. LoTW's report API receives them in an HTTPS request.";
    }
    return @"";
}

static NSString *fakeDir() {
    const char *d = getenv("ADIFLINT_FAKE_LOOKUP_DIR");
    return d && *d ? @(d) : nil;
}

BOOL ADIFLookupFakeMode(void) { return fakeDir() != nil; }

// ── Credentials ─────────────────────────────────────────────────────────────

static NSString *keychainService(ADIFSource source) {
    return [@"ADIF Lint: " stringByAppendingString:ADIFSourceName(source)];
}

// Test mode: an in-memory store instead of the Keychain.
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *fakeStore() {
    static NSMutableDictionary *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [NSMutableDictionary dictionary];
        for (NSInteger s = 0; s < ADIFSourceCount; ++s) store[keychainService((ADIFSource)s)] = @[ @"TEST", @"test" ];
    });
    return store;
}

NSString *ADIFSavedAccount(ADIFSource source) {
    if (ADIFLookupFakeMode()) return fakeStore()[keychainService(source)].firstObject;
    NSDictionary *query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : keychainService(source),
        (__bridge id)kSecReturnAttributes : @YES,
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSDictionary *attrs = CFBridgingRelease(result);
    return attrs[(__bridge id)kSecAttrAccount];
}

static NSString *savedSecret(ADIFSource source) {
    if (ADIFLookupFakeMode()) return fakeStore()[keychainService(source)].lastObject;
    NSDictionary *query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : keychainService(source),
        (__bridge id)kSecReturnData : @YES,
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

BOOL ADIFHasSecret(ADIFSource source) { return savedSecret(source).length > 0; }

BOOL ADIFDeleteCredential(ADIFSource source) {
    if (ADIFLookupFakeMode()) {
        [fakeStore() removeObjectForKey:keychainService(source)];
        return YES;
    }
    NSDictionary *match = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : keychainService(source),
    };
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)match);
    return st == errSecSuccess || st == errSecItemNotFound;
}

BOOL ADIFSaveCredential(ADIFSource source, NSString *user, NSString *secret, NSString **error) {
    if (ADIFSourceCredentialKind(source) == ADIFCredentialAPIKey) user = @"API key";
    if (!user.length || !secret.length) {
        if (error) *error = @"Enter both fields.";
        return NO;
    }
    if (ADIFLookupFakeMode()) {
        fakeStore()[keychainService(source)] = @[ user, secret ];
        return YES;
    }
    ADIFDeleteCredential(source);  // one credential per source
    NSDictionary *item = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : keychainService(source),
        (__bridge id)kSecAttrAccount : user,
        (__bridge id)kSecAttrLabel : keychainService(source),
        (__bridge id)kSecValueData : [secret dataUsingEncoding:NSUTF8StringEncoding],
    };
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (st != errSecSuccess && error) {
        NSString *msg = CFBridgingRelease(SecCopyErrorMessageString(st, NULL));
        *error = msg ?: [NSString stringWithFormat:@"Keychain error %d", (int)st];
    }
    return st == errSecSuccess;
}

// ── HTTP and XML helpers ────────────────────────────────────────────────────

static NSURLSession *lookupSession() {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForRequest = 20;
        c.timeoutIntervalForResource = 120;
        c.URLCache = nil;
        session = [NSURLSession sessionWithConfiguration:c];
    });
    return session;
}

static NSString *encode(NSString *v) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                                      @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [v stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

// Completion on the main queue with the body or an error message.
static void httpSend(NSURLRequest *request, void (^done)(NSData *body, NSString *error)) {
    NSURLSessionDataTask *task = [lookupSession()
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
              NSString *problem = nil;
              NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
              if (err) problem = err.localizedDescription;
              else if (status != 200) problem = [NSString stringWithFormat:@"HTTP %ld from %@", (long)status, request.URL.host];
              dispatch_async(dispatch_get_main_queue(), ^{ done(problem ? nil : data, problem); });
          }];
    [task resume];
}

static void httpGet(NSURL *url, void (^done)(NSData *body, NSString *error)) {
    httpSend([NSURLRequest requestWithURL:url], done);
}

static void httpPostForm(NSURL *url, NSString *form, void (^done)(NSData *body, NSString *error)) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [form dataUsingEncoding:NSUTF8StringEncoding];
    httpSend(r, done);
}

static NSXMLElement *child(NSXMLElement *parent, NSString *localName) {
    for (NSXMLNode *n in parent.children)
        if (n.kind == NSXMLElementKind && [n.localName caseInsensitiveCompare:localName] == NSOrderedSame)
            return (NSXMLElement *)n;
    return nil;
}

// ASCII only (ADI §II.B): transliterate accented letters ("Jürg" -> "Jurg").
static std::string asciiValue(NSString *s) {
    NSString *t = [s stringByApplyingTransform:@"Any-Latin; Latin-ASCII" reverse:NO] ?: s;
    return t.UTF8String ?: "";
}

static std::map<std::string, std::string> childrenMap(NSXMLElement *e) {
    std::map<std::string, std::string> out;
    for (NSXMLNode *n in e.children)
        if (n.kind == NSXMLElementKind && n.localName) out[n.localName.UTF8String] = asciiValue(n.stringValue ?: @"");
    return out;
}

static NSXMLElement *parseRoot(NSData *data) {
    if (!data) return nil;
    // Responses come from the network: never fetch external entities or DTDs.
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:NSXMLNodeLoadExternalEntitiesNever error:nil];
    return doc.rootElement;
}

// Sign in to a callbook. Completion: the session key, or an error; `notice`
// carries a message the service wants shown (QRZ <Message>, non-subscriber).
static void callbookLogin(ADIFSource source, NSString *agent, void (^done)(NSString *session, NSString *notice, NSString *error)) {
    NSString *user = ADIFSavedAccount(source), *pass = savedSecret(source);
    if (!user.length || !pass.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            done(nil, nil, [NSString stringWithFormat:@"No %@ account. Add one in Settings.", ADIFSourceName(source)]);
        });
        return;
    }
    void (^handle)(NSData *, NSString *) = ^(NSData *body, NSString *error) {
        if (error) {
            done(nil, nil, error);
            return;
        }
        NSXMLElement *session = child(parseRoot(body), @"Session");
        NSString *key = [child(session, source == ADIFSourceQRZ ? @"Key" : @"session_id") stringValue];
        NSString *err = [child(session, @"Error") stringValue];
        NSString *notice = nil;
        if (source == ADIFSourceQRZ) {
            // The QRZ spec asks clients to show Error and Message to the user.
            NSString *message = [child(session, @"Message") stringValue];
            NSString *sub = [child(session, @"SubExp") stringValue];
            if (message.length) notice = [@"QRZ.com: " stringByAppendingString:message];
            else if ([sub caseInsensitiveCompare:@"non-subscriber"] == NSOrderedSame)
                notice = @"QRZ.com returns only a few fields without an XML Logbook Data subscription.";
            else if (sub.length) notice = [@"QRZ.com XML subscription until " stringByAppendingString:sub];
        }
        if (key.length) done(key, notice, nil);
        else done(nil, nil, [NSString stringWithFormat:@"%@ sign-in failed: %@", ADIFSourceName(source), err.length ? err : @"no session"]);
    };
    if (ADIFLookupFakeMode()) {
        NSString *xml = source == ADIFSourceQRZ
                            ? @"<QRZDatabase><Session><Key>fake</Key><SubExp>Thu Jan 1 00:00:00 2099</SubExp></Session></QRZDatabase>"
                            : @"<HamQTH><session><session_id>fake</session_id></session></HamQTH>";
        dispatch_async(dispatch_get_main_queue(), ^{ handle([xml dataUsingEncoding:NSUTF8StringEncoding], nil); });
        return;
    }
    if (source == ADIFSourceQRZ) {
        httpPostForm([NSURL URLWithString:kQrzBase],
                     [NSString stringWithFormat:@"username=%@&password=%@&agent=%@", encode(user), encode(pass), encode(agent)],
                     handle);
    } else {
        httpGet([NSURL URLWithString:[NSString stringWithFormat:@"%@?u=%@&p=%@", kHamQthBase, encode(user), encode(pass)]],
                handle);
    }
}

// ── Callbook clients ────────────────────────────────────────────────────────

@implementation ADIFCallbookClient {
    ADIFSource _source;
    NSString *_agent;
    NSString *_session;  // QRZ Key or HamQTH session_id
    NSString *_notice;
    std::map<std::string, std::pair<bool, std::map<std::string, std::string>>> _cache;
}

- (instancetype)initWithSource:(ADIFSource)source agent:(NSString *)agent {
    if (!(self = [super init])) return nil;
    _source = source;
    _agent = agent;
    return self;
}

- (NSString *)notice {
    return _notice;
}

- (NSURL *)lookupURL:(NSString *)call {
    if (_source == ADIFSourceQRZ)
        return [NSURL URLWithString:[NSString stringWithFormat:@"%@?s=%@;callsign=%@", kQrzBase, encode(_session), encode(call)]];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@?id=%@&callsign=%@&prg=%@", kHamQthBase, encode(_session),
                                                           encode(call), encode(_agent)]];
}

- (void)finish:(NSString *)call found:(BOOL)found raw:(const std::map<std::string, std::string> &)raw done:(ADIFCallbookDone)done {
    _cache[call.UTF8String] = {found, raw};
    done(found, raw, nil, NO);
}

- (void)handle:(NSData *)body call:(NSString *)call retried:(BOOL)retried done:(ADIFCallbookDone)done {
    NSXMLElement *root = parseRoot(body);
    if (!root) {
        done(NO, std::map<std::string, std::string>(),
             [NSString stringWithFormat:@"%@ sent a response that is not XML.", ADIFSourceName(_source)], YES);
        return;
    }
    NSXMLElement *record = child(root, _source == ADIFSourceQRZ ? @"Callsign" : @"search");
    if (record) {
        [self finish:call found:YES raw:childrenMap(record) done:done];
        return;
    }
    NSXMLElement *session = child(root, @"Session");
    NSString *err = [child(session, @"Error") stringValue] ?: @"";
    if ([err rangeOfString:@"not found" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [self finish:call found:NO raw:std::map<std::string, std::string>() done:done];
        return;
    }
    // Expired or invalid session: QRZ drops <Key>; HamQTH says so. Sign in again once.
    BOOL expired = (_source == ADIFSourceQRZ && !child(session, @"Key")) ||
                   [err rangeOfString:@"expired" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [err rangeOfString:@"timeout" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [err rangeOfString:@"invalid session" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (expired && !retried) {
        _session = nil;
        [self request:call retried:YES done:done];
        return;
    }
    done(NO, std::map<std::string, std::string>(),
         [NSString stringWithFormat:@"%@: %@", ADIFSourceName(_source), err.length ? err : @"unexpected response"], expired);
}

- (void)request:(NSString *)call retried:(BOOL)retried done:(ADIFCallbookDone)done {
    if (!_session) {
        callbookLogin(_source, _agent, ^(NSString *session, NSString *notice, NSString *error) {
            if (error) {
                done(NO, std::map<std::string, std::string>(), error, YES);
                return;
            }
            self->_session = session;
            self->_notice = notice;
            [self request:call retried:retried done:done];
        });
        return;
    }
    httpGet([self lookupURL:call], ^(NSData *body, NSString *error) {
        if (error) done(NO, std::map<std::string, std::string>(), error, NO);
        else [self handle:body call:call retried:retried done:done];
    });
}

- (void)lookup:(NSString *)call completion:(ADIFCallbookDone)done {
    auto cached = _cache.find(call.UTF8String);
    if (cached != _cache.end()) {
        bool found = cached->second.first;
        std::map<std::string, std::string> raw = cached->second.second;
        dispatch_async(dispatch_get_main_queue(), ^{ done(found, raw, nil, NO); });
        return;
    }
    if (NSString *dir = fakeDir()) {
        if (!ADIFSavedAccount(_source)) {  // tests can remove the account to check the message
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, std::map<std::string, std::string>(),
                     [NSString stringWithFormat:@"No %@ account. Add one in Settings.", ADIFSourceName(self->_source)], YES);
            });
            return;
        }
        NSString *path = [NSString stringWithFormat:@"%@/%@/%@.xml", dir, _source == ADIFSourceQRZ ? @"qrz" : @"hamqth", call];
        NSData *body = [NSData dataWithContentsOfFile:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!body) [self finish:call found:NO raw:std::map<std::string, std::string>() done:done];
            else [self handle:body call:call retried:YES done:done];
        });
        return;
    }
    [self request:call retried:NO done:done];
}

@end

// ── LoTW ────────────────────────────────────────────────────────────────────

static NSURL *lotwURL(NSString *query) {
    NSString *user = ADIFSavedAccount(ADIFSourceLoTW), *pass = savedSecret(ADIFSourceLoTW);
    if (!user.length || !pass.length) return nil;
    // The LoTW API takes the login as query parameters (over HTTPS); that is its documented form.
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@?login=%@&password=%@&%@", kLotwBase, encode(user), encode(pass), query]];
}

// A failed query returns an HTML page without <eoh> (LoTW developer docs).
static NSString *lotwText(NSData *body) {
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]
                         ?: [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding];
    if (!text || [text rangeOfString:@"<eoh>" options:NSCaseInsensitiveSearch].location == NSNotFound) return nil;
    return text;
}

// LoTW lotwreport.adi (lotw.arrl.org/lotw-help/developer-query-qsos-qsls/, read
// 2026-10-08): qso_qsl=no returns your uploaded QSO records, each with QSL_RCVD;
// qso_qsorxsince must be given (left out, LoTW uses the last query's date and
// returns only newer records); qso_withown adds STATION_CALLSIGN, qso_mydetail
// your station's details, qso_qsldetail the confirming station's.
static void lotwDownload(NSString *from, NSString *to, void (^done)(NSString *adif, NSString *error)) {
    NSString *const kBadLogin = @"LoTW did not return a report. Check your LoTW username and password in Settings.";
    if (NSString *dir = fakeDir()) {
        NSData *body = ADIFSavedAccount(ADIFSourceLoTW)
                           ? [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"lotw/lotwreport.adi"]]
                           : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *text = body ? lotwText(body) : nil;
            done(text, text ? nil : kBadLogin);
        });
        return;
    }
    NSMutableString *query = [NSMutableString
        stringWithString:@"qso_query=1&qso_qsl=no&qso_qsorxsince=1900-01-01&qso_withown=yes&qso_mydetail=yes&qso_qsldetail=yes"];
    if (from.length == 8 && to.length == 8)
        [query appendFormat:@"&qso_startdate=%@-%@-%@&qso_enddate=%@-%@-%@", [from substringToIndex:4],
                            [from substringWithRange:NSMakeRange(4, 2)], [from substringFromIndex:6], [to substringToIndex:4],
                            [to substringWithRange:NSMakeRange(4, 2)], [to substringFromIndex:6]];
    NSURL *url = lotwURL(query);
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"No LoTW account. Add one in Settings."); });
        return;
    }
    httpGet(url, ^(NSData *body, NSString *error) {
        if (error) done(nil, [@"LoTW: " stringByAppendingString:error]);
        else {
            NSString *text = lotwText(body);
            done(text, text ? nil : kBadLogin);
        }
    });
}

// ── Test a saved credential ─────────────────────────────────────────────────

void ADIFTestCredential(ADIFSource source, void (^done)(BOOL ok, NSString *message)) {
    if (!ADIFSavedAccount(source) || !ADIFHasSecret(source)) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(NO, @"Nothing saved yet."); });
        return;
    }
    if (source == ADIFSourceQRZLogbook) {
        NSString *key = savedSecret(source);
        void (^handle)(NSString *) = ^(NSString *body) {
            adif::QrzReply r = adif::parseQrzReply(body.UTF8String ?: "");
            if (r.result == "OK") done(YES, @"QRZ.com accepted the key.");
            else done(NO, [NSString stringWithFormat:@"QRZ.com: %s", r.reason.empty() ? "the key was not accepted" : r.reason.c_str()]);
        };
        if (ADIFLookupFakeMode()) {
            dispatch_async(dispatch_get_main_queue(), ^{ handle(@"RESULT=OK&COUNT=1"); });
            return;
        }
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kQrzLogbookApi]];
        r.HTTPMethod = @"POST";
        [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        [r setValue:@"ADIFLint-test" forHTTPHeaderField:@"User-Agent"];
        r.HTTPBody = [@(adif::qrzStatusBody(key.UTF8String ?: "").c_str()) dataUsingEncoding:NSUTF8StringEncoding];
        httpSend(r, ^(NSData *body, NSString *error) {
            if (error) done(NO, [@"QRZ.com: " stringByAppendingString:error]);
            else handle([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
        });
        return;
    }
    if (!ADIFSourceCanTest(source)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            done(YES, [NSString stringWithFormat:@"Saved. %@ has no sign-in test; the first upload checks it.", ADIFSourceName(source)]);
        });
        return;
    }
    if (source == ADIFSourceLoTW) {
        if (ADIFLookupFakeMode()) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(YES, @"LoTW accepted the login (test data)."); });
            return;
        }
        // A query for confirmations since today: small, and it proves the login.
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyy-MM-dd";
        f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSString *today = [f stringFromDate:[NSDate date]];
        httpGet(lotwURL([@"qso_query=1&qso_qsl=yes&qso_qslsince=" stringByAppendingString:today]), ^(NSData *body, NSString *error) {
            if (error) done(NO, [@"LoTW: " stringByAppendingString:error]);
            else if (lotwText(body)) done(YES, @"LoTW accepted the login.");
            else done(NO, @"LoTW did not accept this username and password.");
        });
        return;
    }
    callbookLogin(source, @"ADIFLint-test", ^(NSString *session, NSString *notice, NSString *error) {
        if (error) done(NO, error);
        else done(YES, notice.length ? [@"Signed in. " stringByAppendingString:notice] : @"Signed in.");
    });
}

// ── POTA spots ──────────────────────────────────────────────────────────────

static NSArray<NSDictionary *> *spotObjects(NSData *data, NSString **error) {
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSArray.class]) {
        *error = @"POTA sent something other than a list of spots";
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (id o in (NSArray *)json)
        if ([o isKindOfClass:NSDictionary.class]) [out addObject:o];
    return out;
}

void ADIFFetchPotaSpots(NSString *agent, void (^done)(NSArray<NSDictionary *> *spots, NSString *error)) {
    if (NSString *dir = fakeDir()) {
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"pota/spots.json"]];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = nil;
            NSArray *spots = spotObjects(d, &error);
            done(spots, error);
        });
        return;
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.pota.app/spot/activator"]];
    [r setValue:agent forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    httpSend(r, ^(NSData *body, NSString *error) {
        if (error) {
            done(nil, error);
            return;
        }
        NSString *problem = nil;
        NSArray *spots = spotObjects(body, &problem);
        done(spots, problem);
    });
}

// ── Uploads ─────────────────────────────────────────────────────────────────

// Test mode: note each upload in <fake dir>/uploads.log and answer like the service.
static void fakeUploadLog(NSString *line) {
    NSString *path = [fakeDir() stringByAppendingPathComponent:@"uploads.log"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [h seekToEndOfFile];
    [h writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

// POST and hand back the status and body whatever the status (Club Log explains its 403 and 400 in the body).
static void httpExchange(NSURLRequest *request, void (^done)(NSInteger status, NSData *body, NSString *error)) {
    NSURLSessionDataTask *task = [lookupSession()
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
              NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
              NSString *problem = err ? err.localizedDescription : nil;
              dispatch_async(dispatch_get_main_queue(), ^{ done(status, data, problem); });
          }];
    [task resume];
}

static NSString *text(NSData *d) {
    if (!d) return @"";
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
}

static NSMutableURLRequest *multipartRequest(NSString *url, NSString *agent, const std::vector<adif::MultipartPart> &parts) {
    std::string boundary = "ADIFLint-" + std::string([NSUUID UUID].UUIDString.UTF8String);
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = @"POST";
    [r setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%s", boundary.c_str()] forHTTPHeaderField:@"Content-Type"];
    [r setValue:agent forHTTPHeaderField:@"User-Agent"];
    std::string body = adif::multipartBody(parts, boundary);
    r.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
    return r;
}

void ADIFQrzLogbookInsert(NSString *agent, NSString *adi, BOOL replace, void (^done)(NSString *reply, NSString *error)) {
    NSString *key = savedSecret(ADIFSourceQRZLogbook);
    if (!key.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"No QRZ.com Logbook API key yet. Add it in Settings."); });
        return;
    }
    if (ADIFLookupFakeMode()) {
        fakeUploadLog([NSString stringWithFormat:@"QRZ%@ %@", replace ? @" REPLACE" : @"", adi]);
        static int logid = 1000;
        NSString *reply = [adi containsString:@"<CALL:4>DUPE"]
                              ? @"RESULT=FAIL&REASON=Unable to add QSO to database: duplicate&COUNT=0"
                              : [NSString stringWithFormat:@"RESULT=OK&LOGID=%d&COUNT=1", ++logid];
        dispatch_async(dispatch_get_main_queue(), ^{ done(reply, nil); });
        return;
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kQrzLogbookApi]];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [r setValue:agent forHTTPHeaderField:@"User-Agent"];  // QRZ requires an identifiable User-Agent
    std::string body = adif::qrzInsertBody(key.UTF8String ?: "", adi.UTF8String ?: "", replace);
    r.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
    httpExchange(r, ^(NSInteger status, NSData *data, NSString *error) {
        if (error) done(nil, error);
        else if (status != 200) done(nil, [NSString stringWithFormat:@"HTTP %ld from QRZ.com", (long)status]);
        else done(text(data), nil);
    });
}

void ADIFClubLogUpload(NSString *agent, NSString *callsign, NSString *adiFile, NSString *fileName,
                       void (^done)(NSInteger status, NSString *message, NSString *error)) {
    NSString *email = ADIFSavedAccount(ADIFSourceClubLog), *password = savedSecret(ADIFSourceClubLog);
    NSString *key = savedSecret(ADIFSourceClubLogKey);
    if (!email.length || !password.length || !key.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            done(0, nil, @"Club Log needs your email, an Application Password and an API key. Add them in Settings.");
        });
        return;
    }
    if (ADIFLookupFakeMode()) {
        fakeUploadLog([NSString stringWithFormat:@"CLUBLOG %@ %@\n%@", callsign, fileName, adiFile]);
        dispatch_async(dispatch_get_main_queue(), ^{ done(200, @"OK", nil); });
        return;
    }
    std::vector<adif::MultipartPart> parts = {{"email", email.UTF8String, ""},
                                              {"password", password.UTF8String, ""},
                                              {"callsign", callsign.UTF8String ?: "", ""},
                                              {"api", key.UTF8String, ""},
                                              {"file", adiFile.UTF8String ?: "", fileName.UTF8String ?: "log.adi"}};
    httpExchange(multipartRequest(kClubLogPutLogs, agent, parts), ^(NSInteger status, NSData *data, NSString *error) {
        NSString *msg = [text(data) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (msg.length > 400) msg = [[msg substringToIndex:400] stringByAppendingString:@"..."];
        done(status, msg, error);
    });
}

void ADIFEqslUpload(NSString *agent, NSString *adiFile, NSString *fileName, void (^done)(NSString *reply, NSString *error)) {
    NSString *user = ADIFSavedAccount(ADIFSourceEQSL), *password = savedSecret(ADIFSourceEQSL);
    if (!user.length || !password.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"No eQSL account yet. Add it in Settings."); });
        return;
    }
    if (ADIFLookupFakeMode()) {
        fakeUploadLog([@"EQSL " stringByAppendingString:adiFile]);
        NSString *reply = [adiFile containsString:@"<CALL:4>DUPE"]
                              ? @"Result: 0 out of 1 records added<BR>Warning: Y=2026 M=10 D=06 DUPE Bad record: Duplicate<BR>"
                              : @"<!-- Reply form eQSL.cc ADIF Real-time Interface -->Result: 1 out of 1 records added<BR>";
        dispatch_async(dispatch_get_main_queue(), ^{ done(reply, nil); });
        return;
    }
    std::vector<adif::MultipartPart> parts = {{"EQSL_USER", user.UTF8String, ""},
                                              {"EQSL_PSWD", password.UTF8String, ""},
                                              {"Filename", adiFile.UTF8String ?: "", fileName.UTF8String ?: "log.adi"}};
    httpExchange(multipartRequest(kEqslImport, agent, parts), ^(NSInteger status, NSData *data, NSString *error) {
        if (error) done(nil, error);
        else if (status != 200) done(nil, [NSString stringWithFormat:@"HTTP %ld from eQSL (the service may be down; try again later)", (long)status]);
        else done(text(data), nil);
    });
}

NSString *ADIFTqslPassword(void) { return ADIFHasSecret(ADIFSourceTqsl) ? savedSecret(ADIFSourceTqsl) : nil; }

// ── Your QSOs from LoTW, QRZ.com Logbook and eQSL (Import) ──────────────────

static NSString *fakeText(NSString *relative) {
    NSData *d = [NSData dataWithContentsOfFile:[fakeDir() stringByAppendingPathComponent:relative]];
    return d ? text(d) : nil;
}

// One FETCH page; then the next from the highest APP_QRZLOG_LOGID + 1, until a short page.
static void qrzFetchPage(NSString *agent, NSString *key, std::string between, long long after, NSMutableString *all, int pages,
                         void (^done)(NSString *adif, NSString *error)) {
    const int kMax = 250;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kQrzLogbookApi]];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [r setValue:agent forHTTPHeaderField:@"User-Agent"];
    std::string body = adif::qrzFetchBody(key.UTF8String ?: "", after, kMax, between);
    r.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
    httpExchange(r, ^(NSInteger status, NSData *data, NSString *error) {
        if (error || status != 200) {
            done(nil, error ?: [NSString stringWithFormat:@"HTTP %ld from QRZ.com", (long)status]);
            return;
        }
        adif::QrzReply reply;
        std::string page;
        std::string raw = text(data).UTF8String ?: "";
        if (!adif::parseQrzFetch(raw, &reply, &page)) {
            done(nil, @"QRZ.com sent something unexpected");
            return;
        }
        if (reply.result != "OK") {
            // No records match is not an error.
            if (reply.reason.find("no log entries") != std::string::npos || reply.count == "0") done(all, nil);
            else done(nil, [NSString stringWithFormat:@"QRZ.com: %s", reply.reason.empty() ? "FETCH failed" : reply.reason.c_str()]);
            return;
        }
        [all appendString:@(page.c_str()) ?: @""];
        [all appendString:@"\n"];
        // The highest logid on this page, and how many records it held.
        adif::LintOptions opt;
        opt.buildModel = true;
        adif::LintResult lr = adif::lint(page, opt);
        long long highest = -1;
        size_t n = 0;
        for (const adif::ModelGroup &g : lr.model.groups) {
            if (g.header) continue;
            ++n;
            std::string id(adif::groupValue(page, lr.model, g, "APP_QRZLOG_LOGID"));
            if (!id.empty()) highest = std::max(highest, std::atoll(id.c_str()));
        }
        if ((int)n < kMax || highest < after || pages >= 200) {
            done(all, nil);
            return;
        }
        qrzFetchPage(agent, key, between, highest + 1, all, pages + 1, done);
    });
}

// QRZ.com Logbook FETCH (www.qrz.com/docs/logbook/QRZLogbookAPI.html, updated
// 2025-03-07): every record (STATUS:ALL is the default), or those BETWEEN two
// QSO dates, 250 at a time.
static void qrzDownload(NSString *agent, NSString *from, NSString *to, void (^done)(NSString *adif, NSString *error)) {
    if (ADIFLookupFakeMode()) {
        NSString *body = fakeText(@"qrzlog/fetch.txt");
        dispatch_async(dispatch_get_main_queue(), ^{
            adif::QrzReply reply;
            std::string page;
            if (!body || !adif::parseQrzFetch(body.UTF8String, &reply, &page)) done(nil, @"QRZ.com sent something unexpected");
            else done(@(page.c_str()), nil);
        });
        return;
    }
    NSString *key = savedSecret(ADIFSourceQRZLogbook);
    if (!key.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"No QRZ.com Logbook API key yet. Add it in Settings."); });
        return;
    }
    std::string between;
    if (from.length == 8 && to.length == 8) {
        std::string f = from.UTF8String, t = to.UTF8String;
        between = f.substr(0, 4) + "-" + f.substr(4, 2) + "-" + f.substr(6) + "+" + t.substr(0, 4) + "-" + t.substr(4, 2) + "-" + t.substr(6);
    }
    qrzFetchPage(agent, key, between, 0, [NSMutableString string], 1, done);
}

// eQSL DownloadInBox (www.eqsl.cc/qslcard/DownloadInBox.txt, revised 2025-10-12):
// the eQSLs other stations sent you, optionally for QSO dates LimitDateLo to
// LimitDateHi (MM/DD/YYYY).
static void eqslDownload(NSString *agent, NSString *from, NSString *to, void (^done)(NSString *adif, NSString *error)) {
    if (ADIFLookupFakeMode()) {
        NSString *adif = fakeText(@"eqsl/inbox.adi");
        dispatch_async(dispatch_get_main_queue(), ^{ done(adif, adif ? nil : @"no test InBox"); });
        return;
    }
    NSString *user = ADIFSavedAccount(ADIFSourceEQSL), *password = savedSecret(ADIFSourceEQSL);
    if (!user.length || !password.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"No eQSL account yet. Add it in Settings."); });
        return;
    }
    // DownloadInBox takes the login in the address (over HTTPS); that is how eQSL documents it.
    NSMutableString *address = [NSMutableString stringWithFormat:@"https://www.eQSL.cc/qslcard/DownloadInBox.cfm?UserName=%@&Password=%@",
                                                                 encode(user), encode(password)];
    if (from.length == 8 && to.length == 8) {
        auto us = ^(NSString *d) {  // YYYYMMDD -> MM/DD/YYYY
            return [NSString stringWithFormat:@"%@/%@/%@", [d substringWithRange:NSMakeRange(4, 2)], [d substringFromIndex:6],
                                              [d substringToIndex:4]];
        };
        [address appendFormat:@"&LimitDateLo=%@&LimitDateHi=%@", encode(us(from)), encode(us(to))];
    }
    NSURL *url = [NSURL URLWithString:address];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    [r setValue:agent forHTTPHeaderField:@"User-Agent"];
    httpExchange(r, ^(NSInteger status, NSData *data, NSString *error) {
        if (error || status != 200) {
            done(nil, error ?: [NSString stringWithFormat:@"HTTP %ld from eQSL", (long)status]);
            return;
        }
        std::string problem;
        std::string link = adif::eqslInboxLink(text(data).UTF8String ?: "", &problem);
        if (link.empty()) {
            done(nil, [@"eQSL: " stringByAppendingString:@(problem.c_str())]);
            return;
        }
        NSURL *file = [NSURL URLWithString:@(link.c_str()) relativeToURL:url];
        if (!file || ![file.host.lowercaseString hasSuffix:@"eqsl.cc"]) {
            done(nil, @"eQSL linked to an unexpected place");
            return;
        }
        NSMutableURLRequest *get = [NSMutableURLRequest requestWithURL:file.absoluteURL];
        [get setValue:agent forHTTPHeaderField:@"User-Agent"];
        httpExchange(get, ^(NSInteger st, NSData *adi, NSString *err) {
            if (err || st != 200) done(nil, err ?: [NSString stringWithFormat:@"HTTP %ld from eQSL", (long)st]);
            else done(text(adi), nil);
        });
    });
}

void ADIFDownloadSiteQsos(adif::ImportSite site, NSString *from, NSString *to, void (^done)(NSString *adif, NSString *error)) {
    NSString *agent = [NSString stringWithFormat:@"ADIFLint/%s", ADIFLINT_VERSION];
    switch (site) {
        case adif::ImportSite::LoTW: lotwDownload(from, to, done); return;
        case adif::ImportSite::QRZLogbook: qrzDownload(agent, from, to, done); return;
        case adif::ImportSite::EQSL: eqslDownload(agent, from, to, done); return;
    }
}

void ADIFFetchWwffSpots(NSString *agent, void (^done)(NSArray<NSDictionary *> *spots, NSString *error)) {
    if (NSString *dir = fakeDir()) {
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"wwff/spots.json"]];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = nil;
            NSArray *spots = spotObjects(d, &error);
            done(spots, error);
        });
        return;
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://spots.wwff.co/static/spots.json"]];
    [r setValue:agent forHTTPHeaderField:@"User-Agent"];
    httpSend(r, ^(NSData *body, NSString *error) {
        if (error) {
            done(nil, error);
            return;
        }
        NSString *problem = nil;
        NSArray *spots = spotObjects(body, &problem);
        done(spots, problem ? @"WWFF sent something other than a list of spots" : nil);
    });
}

void ADIFFetchZlotaSpots(NSString *agent, void (^done)(NSArray<NSDictionary *> *spots, NSString *error)) {
    if (NSString *dir = fakeDir()) {
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"zlota/spots.json"]];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = nil;
            NSArray *spots = spotObjects(d, &error);
            done(spots, error);
        });
        return;
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://ontheair.nz/api/spots?zlota_only=true"]];
    [r setValue:agent forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    httpSend(r, ^(NSData *body, NSString *error) {
        if (error) {
            done(nil, error);
            return;
        }
        NSString *problem = nil;
        NSArray *spots = spotObjects(body, &problem);
        done(spots, problem ? @"ontheair.nz sent something other than a list of spots" : nil);
    });
}

// ── Country data ────────────────────────────────────────────────────────────

void ADIFDownloadCountryData(NSString *agent, void (^done)(NSString *ctyCsv, NSString *release, NSString *error)) {
    if (ADIFLookupFakeMode()) {
        NSString *csv = fakeText(@"cty/cty.csv");
        dispatch_async(dispatch_get_main_queue(), ^{ done(csv, @"bigcty-test", csv ? nil : @"no test country file"); });
        return;
    }
    NSURL *list = [NSURL URLWithString:@"https://www.country-files.com/category/big-cty/"];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:list];
    [r setValue:agent forHTTPHeaderField:@"User-Agent"];
    httpExchange(r, ^(NSInteger status, NSData *data, NSString *error) {
        if (error || status != 200) {
            done(nil, nil, error ?: [NSString stringWithFormat:@"HTTP %ld from country-files.com", (long)status]);
            return;
        }
        NSString *page = text(data);
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"https://www\\.country-files\\.com/bigcty/download/[0-9]{4}/(bigcty-[0-9]{8})\\.zip"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:page options:0 range:NSMakeRange(0, page.length)];
        if (!m) {
            done(nil, nil, @"no Big CTY release found on country-files.com");
            return;
        }
        NSString *zipURL = [page substringWithRange:m.range], *release = [page substringWithRange:[m rangeAtIndex:1]];
        NSMutableURLRequest *get = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:zipURL]];
        [get setValue:agent forHTTPHeaderField:@"User-Agent"];
        httpExchange(get, ^(NSInteger st, NSData *zip, NSString *err) {
            if (err || st != 200 || zip.length < 100) {
                done(nil, nil, err ?: [NSString stringWithFormat:@"HTTP %ld downloading %@", (long)st, release]);
                return;
            }
            // unzip -p prints one member to stdout: no files written outside our temporary copy.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"adiflint-%@.zip", NSUUID.UUID.UUIDString]];
                [zip writeToFile:tmp atomically:YES];
                NSTask *t = [[NSTask alloc] init];
                t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/unzip"];
                t.arguments = @[ @"-p", tmp, @"cty.csv" ];
                NSPipe *out = [NSPipe pipe];
                t.standardOutput = out;
                t.standardError = [NSFileHandle fileHandleWithNullDevice];
                NSString *csv = nil;
                if ([t launchAndReturnError:nil]) {
                    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
                    [t waitUntilExit];
                    if (t.terminationStatus == 0) csv = text(d);
                }
                [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (csv.length) done(csv, release, nil);
                    else done(nil, nil, [NSString stringWithFormat:@"%@ had no cty.csv", release]);
                });
            });
        });
    });
}
