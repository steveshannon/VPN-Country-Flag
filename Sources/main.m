#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UserNotifications/UserNotifications.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netdb.h>
#import <arpa/inet.h>

static NSString * const kRefreshInterval = @"refreshInterval";
static NSString * const kNotifyChanges = @"notifyChanges";
static NSString * const kPlaySound = @"playSound";
static NSString * const kIPv4Format = @"ipv4Format";
static NSString * const kIPv6Format = @"ipv6Format";
static NSString * const kCountryFormat = @"countryFormat";
static NSString * const kCachedLocation = @"cachedLocation";
static NSString * const kLegacyMigrationComplete = @"legacyMigrationComplete";

static NSString *FlagForCountryCode(NSString *code) {
    NSString *upper = code.uppercaseString;
    if (upper.length != 2) return @"❓";
    NSMutableString *flag = [NSMutableString string];
    for (NSUInteger index = 0; index < 2; index++) {
        unichar character = [upper characterAtIndex:index];
        if (character < 'A' || character > 'Z') return @"❓";
        UTF32Char scalar = 0x1F1E6 + (character - 'A');
        if (scalar > 0xFFFF) {
            scalar -= 0x10000;
            unichar pair[2] = {(unichar)((scalar >> 10) + 0xD800), (unichar)((scalar & 0x3FF) + 0xDC00)};
            [flag appendString:[NSString stringWithCharacters:pair length:2]];
        }
    }
    return flag;
}

static NSString *NotificationTimestamp(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [formatter stringFromDate:NSDate.date];
}

static void MigrateLegacyPreferences(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kLegacyMigrationComplete]) return;
    NSArray<NSString *> *keys = @[kRefreshInterval, kNotifyChanges, kPlaySound,
                                  kIPv4Format, kIPv6Format, kCountryFormat, kCachedLocation];
    NSArray<NSString *> *legacyDomains = @[@"com.vpncountryflag.app", @"com.local.flagip"];
    for (NSString *domainName in legacyDomains) {
        NSDictionary *legacy = [defaults persistentDomainForName:domainName];
        if (legacy.count == 0) continue;
        for (NSString *key in keys) {
            id value = legacy[key];
            if (value) [defaults setObject:value forKey:key];
        }
        break;
    }
    [defaults setBool:YES forKey:kLegacyMigrationComplete];
}

@class AppDelegate;

@interface PreferencesController : NSWindowController
- (instancetype)initWithDelegate:(AppDelegate *)delegate;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate>
@property NSStatusItem *statusItem;
@property NSDictionary *location;
@property NSString *lastError;
@property NSString *lastChangeSummary;
@property NSDate *lastChangeDate;
@property NSTimer *refreshTimer;
@property NSURLSessionDataTask *dataTask;
@property PreferencesController *preferences;
@property SCDynamicStoreRef dynamicStore;
@property CFRunLoopSourceRef storeSource;
- (void)settingsDidChange;
@end

@implementation PreferencesController {
    __weak AppDelegate *_appDelegate;
    NSUserDefaults *_defaults;
}

- (instancetype)initWithDelegate:(AppDelegate *)delegate {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 535, 345)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        _appDelegate = delegate;
        _defaults = NSUserDefaults.standardUserDefaults;
        window.title = @"VPN Country Flag Preferences";
        window.releasedWhenClosed = NO;
        [window center];
        [self buildUI];
    }
    return self;
}

- (NSTextField *)label:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.alignment = NSTextAlignmentRight;
    return label;
}

- (NSButton *)checkbox:(NSString *)title state:(BOOL)state action:(SEL)action {
    NSButton *button = [NSButton checkboxWithTitle:title target:self action:action];
    button.state = state ? NSControlStateValueOn : NSControlStateValueOff;
    return button;
}

- (NSPopUpButton *)popup:(NSArray<NSString *> *)items selected:(NSString *)selected action:(SEL)action {
    NSPopUpButton *button = [[NSPopUpButton alloc] init];
    [button addItemsWithTitles:items];
    [button selectItemWithTitle:selected];
    button.target = self;
    button.action = action;
    return button;
}

- (void)buildUI {
    BOOL loginEnabled = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    NSArray *rows = @[
        @[[self label:@"Start at login"], [self checkbox:@"Launch VPN Country Flag when I log in" state:loginEnabled action:@selector(toggleLogin:)]],
        @[[self label:@"IPv4 format"], [self popup:@[@"Hidden", @"Address"] selected:[_defaults stringForKey:kIPv4Format] action:@selector(ipv4Changed:)]],
        @[[self label:@"IPv6 format"], [self popup:@[@"Hidden", @"Address"] selected:[_defaults stringForKey:kIPv6Format] action:@selector(ipv6Changed:)]],
        @[[self label:@"Country format"], [self popup:@[@"Emoji flag", @"Country code", @"Country name", @"Hidden"] selected:[_defaults stringForKey:kCountryFormat] action:@selector(countryChanged:)]],
        @[[self label:@"IP refresh interval"], [self popup:@[@"Off", @"1 minute", @"5 minutes", @"15 minutes"] selected:[self intervalTitle] action:@selector(intervalChanged:)]],
        @[[self label:@"Notifications"], [self checkbox:@"Notify when the public IP changes" state:[_defaults boolForKey:kNotifyChanges] action:@selector(notifyChanged:)]],
        @[[self label:@""], [self checkbox:@"Play sound for notifications" state:[_defaults boolForKey:kPlaySound] action:@selector(soundChanged:)]]
    ];
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.rowSpacing = 11;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
    [self.window.contentView addSubview:grid];

    NSTextField *note = [NSTextField wrappingLabelWithString:@"VPN Country Flag refreshes when macOS reports a network change. The interval is a backup check for VPN or public-IP changes that do not trigger a system event."];
    note.textColor = NSColor.secondaryLabelColor;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window.contentView addSubview:note];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:24],
        [grid.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:24],
        [grid.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-24],
        [note.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:18],
        [note.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:35],
        [note.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-35]
    ]];
}

- (NSString *)intervalTitle {
    switch ([_defaults integerForKey:kRefreshInterval]) {
        case 0: return @"Off";
        case 60: return @"1 minute";
        case 900: return @"15 minutes";
        default: return @"5 minutes";
    }
}

- (void)toggleLogin:(NSButton *)sender {
    NSError *error = nil;
    if (sender.state == NSControlStateValueOn) [SMAppService.mainAppService registerAndReturnError:&error];
    else [SMAppService.mainAppService unregisterAndReturnError:&error];
    if (error) {
        sender.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        NSAlert *alert = [NSAlert alertWithError:error];
        alert.messageText = @"Could not change Login Items";
        [alert runModal];
    }
}
- (void)ipv4Changed:(NSPopUpButton *)sender { [_defaults setObject:sender.titleOfSelectedItem forKey:kIPv4Format]; [_appDelegate settingsDidChange]; }
- (void)ipv6Changed:(NSPopUpButton *)sender { [_defaults setObject:sender.titleOfSelectedItem forKey:kIPv6Format]; [_appDelegate settingsDidChange]; }
- (void)countryChanged:(NSPopUpButton *)sender { [_defaults setObject:sender.titleOfSelectedItem forKey:kCountryFormat]; [_appDelegate settingsDidChange]; }
- (void)intervalChanged:(NSPopUpButton *)sender {
    NSDictionary *values = @{@"Off": @0, @"1 minute": @60, @"5 minutes": @300, @"15 minutes": @900};
    [_defaults setInteger:[values[sender.titleOfSelectedItem] integerValue] forKey:kRefreshInterval];
    [_appDelegate settingsDidChange];
}
- (void)notifyChanged:(NSButton *)sender {
    BOOL enabled = sender.state == NSControlStateValueOn;
    [_defaults setBool:enabled forKey:kNotifyChanges];
    if (enabled) {
        [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *error) {}];
    }
    [_appDelegate settingsDidChange];
}
- (void)soundChanged:(NSButton *)sender { [_defaults setBool:sender.state == NSControlStateValueOn forKey:kPlaySound]; [_appDelegate settingsDidChange]; }
@end

static void NetworkStoreChanged(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
    AppDelegate *delegate = (__bridge AppDelegate *)info;
    [NSObject cancelPreviousPerformRequestsWithTarget:delegate selector:@selector(networkChanged) object:nil];
    [delegate performSelector:@selector(networkChanged) withObject:nil afterDelay:1.5];
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"VPNCountryFlag" ofType:@"icns"];
    if (iconPath) NSApp.applicationIconImage = [[NSImage alloc] initWithContentsOfFile:iconPath];
    MigrateLegacyPreferences();
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kRefreshInterval: @300,
        kNotifyChanges: @NO,
        kPlaySound: @YES,
        kIPv4Format: @"Hidden",
        kIPv6Format: @"Hidden",
        kCountryFormat: @"Emoji flag"
    }];
    self.location = [NSUserDefaults.standardUserDefaults dictionaryForKey:kCachedLocation];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = self.location ? FlagForCountryCode(self.location[@"countryCode"]) : @"🌐";
    self.statusItem.button.toolTip = @"VPN Country Flag";
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    if ([NSUserDefaults.standardUserDefaults boolForKey:kNotifyChanges]) {
        [self requestNotificationAuthorizationShowingError:NO];
    }
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    self.statusItem.menu = menu;
    [self configureTimer];
    [self startNetworkMonitoring];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [self refresh];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.refreshTimer invalidate];
    [self.dataTask cancel];
    if (self.storeSource) CFRunLoopRemoveSource(CFRunLoopGetMain(), self.storeSource, kCFRunLoopCommonModes);
    if (self.storeSource) CFRelease(self.storeSource);
    if (self.dynamicStore) CFRelease(self.dynamicStore);
}

- (void)menuWillOpen:(NSMenu *)menu { [self rebuildMenu:menu]; }

- (void)addInfo:(NSString *)title toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:item];
}

- (void)rebuildMenu:(NSMenu *)menu {
    [menu removeAllItems];
    if (self.location) {
        [self addInfo:[NSString stringWithFormat:@"IP: %@", self.location[@"ip"]] toMenu:menu];
        [self addInfo:[NSString stringWithFormat:@"Country: %@ %@", self.location[@"country"], FlagForCountryCode(self.location[@"countryCode"])] toMenu:menu];
        NSDate *updated = self.location[@"updatedAt"];
        if (updated) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.timeStyle = NSDateFormatterShortStyle;
            [self addInfo:[NSString stringWithFormat:@"Updated: %@", [formatter stringFromDate:updated]] toMenu:menu];
        }
    } else [self addInfo:@"No IP information yet" toMenu:menu];
    if (self.lastError) [self addInfo:[NSString stringWithFormat:@"Error: %@", self.lastError] toMenu:menu];
    if (self.lastChangeSummary) {
        NSDateFormatter *changeFormatter = [[NSDateFormatter alloc] init];
        changeFormatter.timeStyle = NSDateFormatterShortStyle;
        [self addInfo:[NSString stringWithFormat:@"Last change: %@ (%@)", self.lastChangeSummary, [changeFormatter stringFromDate:self.lastChangeDate]] toMenu:menu];
    }
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *refresh = [menu addItemWithTitle:self.dataTask ? @"Refreshing…" : @"Refresh" action:@selector(refreshClicked:) keyEquivalent:@"r"];
    refresh.target = self;
    NSMenuItem *copy = [menu addItemWithTitle:@"Copy public IP" action:@selector(copyIP:) keyEquivalent:@"c"];
    copy.target = self;
    copy.enabled = self.location != nil;
    [menu addItem:NSMenuItem.separatorItem];
    [self addInfo:@"Local" toMenu:menu];
    NSArray<NSArray<NSString *> *> *addresses = [self localAddresses];
    if (addresses.count == 0) [self addInfo:@"  No active addresses" toMenu:menu];
    for (NSArray *entry in addresses) [self addInfo:[NSString stringWithFormat:@"  %@: %@", entry[0], entry[1]] toMenu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *preferences = [menu addItemWithTitle:@"Preferences…" action:@selector(showPreferences:) keyEquivalent:@","];
    preferences.target = self;
    NSMenuItem *testNotification = [menu addItemWithTitle:@"Test notification" action:@selector(testNotification:) keyEquivalent:@""];
    testNotification.target = self;
    NSMenuItem *about = [menu addItemWithTitle:@"About VPN Country Flag" action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit VPN Country Flag" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
}

- (NSArray<NSArray<NSString *> *> *)localAddresses {
    NSMutableArray *result = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return result;
    for (struct ifaddrs *current = interfaces; current; current = current->ifa_next) {
        if (!current->ifa_addr) continue;
        int family = current->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) continue;
        if (!(current->ifa_flags & IFF_UP) || (current->ifa_flags & IFF_LOOPBACK)) continue;
        char host[NI_MAXHOST];
        socklen_t length = family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
        if (getnameinfo(current->ifa_addr, length, host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0) {
            NSString *address = [[[NSString stringWithUTF8String:host] componentsSeparatedByString:@"%"] firstObject];
            NSArray *entry = @[[NSString stringWithUTF8String:current->ifa_name], address];
            if (![result containsObject:entry]) [result addObject:entry];
        }
    }
    freeifaddrs(interfaces);
    [result sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult name = [a[0] compare:b[0]];
        return name == NSOrderedSame ? [a[1] compare:b[1]] : name;
    }];
    return result;
}

- (void)configureTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    NSInteger interval = [NSUserDefaults.standardUserDefaults integerForKey:kRefreshInterval];
    if (interval <= 0) return;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(timerFired:) userInfo:nil repeats:YES];
    self.refreshTimer.tolerance = MIN(15, interval * 0.1);
}

- (void)startNetworkMonitoring {
    SCDynamicStoreContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    self.dynamicStore = SCDynamicStoreCreate(NULL, CFSTR("VPNCountryFlag"), NetworkStoreChanged, &context);
    if (!self.dynamicStore) return;
    NSArray *patterns = @[@"State:/Network/Global/IPv4", @"State:/Network/Global/IPv6", @"State:/Network/Interface/.*/IPv4", @"State:/Network/Interface/.*/IPv6"];
    SCDynamicStoreSetNotificationKeys(self.dynamicStore, NULL, (__bridge CFArrayRef)patterns);
    self.storeSource = SCDynamicStoreCreateRunLoopSource(NULL, self.dynamicStore, 0);
    if (self.storeSource) CFRunLoopAddSource(CFRunLoopGetMain(), self.storeSource, kCFRunLoopCommonModes);
}

- (void)settingsDidChange { [self configureTimer]; [self updateStatusTitle]; }
- (void)timerFired:(NSTimer *)timer { [self refresh]; }
- (void)networkChanged { [self refresh]; }
- (void)didWake:(NSNotification *)note { [self refresh]; }
- (void)refreshClicked:(id)sender { [self refresh]; }

- (void)refresh {
    if (self.dataTask) return;
    [self requestURL:[NSURL URLWithString:@"https://ipwho.is/"] primary:YES];
}

- (void)requestURL:(NSURL *)url primary:(BOOL)primary {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    request.HTTPMethod = @"GET";
    __weak typeof(self) weakSelf = self;
    self.dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *self = weakSelf;
            if (!self) return;
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *ip = json[@"ip"];
            NSString *country = primary ? json[@"country"] : json[@"country_name"];
            NSString *code = json[@"country_code"];
            BOOL serviceError = primary ? [json[@"success"] isEqual:@NO] : [json[@"error"] isEqual:@YES];
            if (!error && http.statusCode >= 200 && http.statusCode < 300 && !serviceError && ip.length && country.length && code.length == 2) {
                [self applyLocation:@{@"ip": ip, @"country": country, @"countryCode": code, @"updatedAt": NSDate.date}];
            } else if (primary) {
                self.dataTask = nil;
                [self requestURL:[NSURL URLWithString:@"https://ipapi.co/json/"] primary:NO];
            } else {
                NSString *message = error.localizedDescription ?: json[@"reason"] ?: @"Both lookup services failed.";
                [self applyFailure:message];
            }
        });
    }];
    [self.dataTask resume];
}

- (void)applyLocation:(NSDictionary *)newLocation {
    NSDictionary *old = self.location;
    self.location = newLocation;
    [NSUserDefaults.standardUserDefaults setObject:newLocation forKey:kCachedLocation];
    self.lastError = nil;
    self.dataTask = nil;
    [self updateStatusTitle];
    BOOL ipChanged = old && ![old[@"ip"] isEqual:newLocation[@"ip"]];
    BOOL countryChanged = old && ![[old[@"countryCode"] uppercaseString] isEqual:[newLocation[@"countryCode"] uppercaseString]];
    if (ipChanged || countryChanged) {
        self.lastChangeSummary = [NSString stringWithFormat:@"%@ → %@", FlagForCountryCode(old[@"countryCode"]), FlagForCountryCode(newLocation[@"countryCode"])];
        self.lastChangeDate = NSDate.date;
        if ([NSUserDefaults.standardUserDefaults boolForKey:kNotifyChanges]) {
            [self notifyFrom:old to:newLocation countryChanged:countryChanged];
        }
    }
}

- (void)applyFailure:(NSString *)message {
    self.lastError = message;
    self.dataTask = nil;
    self.statusItem.button.title = @"🆘";
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"VPN Country Flag lookup failed: %@", message];
}

- (void)updateStatusTitle {
    if (!self.location) { self.statusItem.button.title = @"🌐"; return; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *parts = [NSMutableArray array];
    NSString *countryFormat = [defaults stringForKey:kCountryFormat];
    if ([countryFormat isEqual:@"Country code"]) [parts addObject:[self.location[@"countryCode"] uppercaseString]];
    else if ([countryFormat isEqual:@"Country name"]) [parts addObject:self.location[@"country"]];
    else if (![countryFormat isEqual:@"Hidden"]) [parts addObject:FlagForCountryCode(self.location[@"countryCode"])];
    NSString *ip = self.location[@"ip"];
    if (![[defaults objectForKey:kIPv4Format] isEqual:@"Hidden"] && [ip containsString:@"."]) [parts addObject:ip];
    if (![[defaults objectForKey:kIPv6Format] isEqual:@"Hidden"] && [ip containsString:@":"]) [parts addObject:ip];
    self.statusItem.button.title = parts.count ? [parts componentsJoinedByString:@" "] : @"🌐";
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"%@ — %@", ip, self.location[@"country"]];
}

- (void)notifyFrom:(NSDictionary *)old to:(NSDictionary *)newLocation countryChanged:(BOOL)countryChanged {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = countryChanged ? @"VPN Country Changed" : @"Public IP Changed";
    content.subtitle = NotificationTimestamp();
    content.body = [NSString stringWithFormat:@"%@%@ → %@%@",
                    FlagForCountryCode(old[@"countryCode"]), old[@"ip"],
                    FlagForCountryCode(newLocation[@"countryCode"]), newLocation[@"ip"]];
    if ([NSUserDefaults.standardUserDefaults boolForKey:kPlaySound]) content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.lastError = [NSString stringWithFormat:@"Notification: %@", error.localizedDescription]; });
        }
    }];
}

- (void)requestNotificationAuthorizationShowingError:(BOOL)showError {
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *error) {
        if (showError && (!granted || error)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Notifications are not enabled";
                alert.informativeText = error.localizedDescription ?: @"Allow notifications for VPN Country Flag in System Settings → Notifications, then try again.";
                [alert addButtonWithTitle:@"Open Notification Settings"];
                [alert addButtonWithTitle:@"Cancel"];
                if ([alert runModal] == NSAlertFirstButtonReturn) {
                    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Notifications-Settings.extension"];
                    [NSWorkspace.sharedWorkspace openURL:url];
                }
            });
        }
    }];
}

- (void)testNotification:(id)sender {
    [self requestNotificationAuthorizationShowingError:YES];
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusAuthorized && settings.authorizationStatus != UNAuthorizationStatusProvisional) return;
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = @"Notification Test";
        content.subtitle = NotificationTimestamp();
        content.body = self.location ? [NSString stringWithFormat:@"%@%@", FlagForCountryCode(self.location[@"countryCode"]), self.location[@"ip"]] : @"VPN Country Flag is working";
        if ([NSUserDefaults.standardUserDefaults boolForKey:kPlaySound]) content.sound = UNNotificationSound.defaultSound;
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
    }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionBanner;
    if ([NSUserDefaults.standardUserDefaults boolForKey:kPlaySound]) options |= UNNotificationPresentationOptionSound;
    completionHandler(options);
}

- (void)copyIP:(id)sender {
    NSString *ip = self.location[@"ip"];
    if (!ip) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:ip forType:NSPasteboardTypeString];
}

- (void)showPreferences:(id)sender {
    if (!self.preferences) self.preferences = [[PreferencesController alloc] initWithDelegate:self];
    [self.preferences showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showAbout:(id)sender {
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName: @"VPN Country Flag",
        NSAboutPanelOptionApplicationVersion: @"1.1.3",
        NSAboutPanelOptionCredits: [[NSAttributedString alloc] initWithString:@"A quiet country-flag indicator for your current public IP."]
    }];
    [NSApp activateIgnoringOtherApps:YES];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
