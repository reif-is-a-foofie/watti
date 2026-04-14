#import <Cocoa/Cocoa.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>

#include <fcntl.h>
#include <float.h>
#include <signal.h>
#include <unistd.h>

static NSString *const WNPowerSourceStateKey = @"Power Source State";
static NSString *const WNACPowerValue = @"AC Power";

static int WNLogFD = -1;
static NSString *WNLogPathCache = nil;

@interface PowerSnapshot : NSObject
@property(nonatomic) double watts;
@property(nonatomic) BOOL onAC;
@property(nonatomic) BOOL charging;
@property(nonatomic) double inputWatts;
@property(nonatomic) double systemLoadWatts;
@property(nonatomic) double adapterRatedWatts;
@property(nonatomic) double negotiatedWatts;
@property(nonatomic) double batteryPercent;
@property(nonatomic) double batteryHealthPercent;
@property(nonatomic) double remainingWattHours;
@property(nonatomic) double averageUsageWatts;
@property(nonatomic) double predictedMinutesRemaining;
@property(nonatomic) double systemTimeToEmptyMinutes;
@property(nonatomic) double systemTimeToFullMinutes;
@property(nonatomic) BOOL fullyCharged;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) NSString *caption;
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSString *powerSourceState;
@property(nonatomic, copy) NSString *chargerFingerprint;
@property(nonatomic, copy) NSString *chargerSuggestedName;
@property(nonatomic, copy) NSString *chargerDisplayName;
@property(nonatomic) BOOL externalConnectedReported;
@property(nonatomic, strong) NSColor *dotColor;
@end

@implementation PowerSnapshot
@end

static NSColor *WNColor(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
}

static NSString *WNDurationString(double minutes) {
    if (minutes <= 0) {
        return @"--";
    }

    NSInteger roundedMinutes = (NSInteger)(minutes + 0.5);
    NSInteger hours = roundedMinutes / 60;
    NSInteger leftoverMinutes = roundedMinutes % 60;

    return [NSString stringWithFormat:@"%ldh %02ldm", (long)hours, (long)leftoverMinutes];
}

static NSString *WNLogDirectoryPath(void) {
    NSArray<NSString *> *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryPath = libraryPaths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    return [libraryPath stringByAppendingPathComponent:@"Logs/Watti"];
}

static NSString *WNLogFilePath(void) {
    if (WNLogPathCache == nil) {
        WNLogPathCache = [[WNLogDirectoryPath() stringByAppendingPathComponent:@"watti.log"] copy];
    }

    return WNLogPathCache;
}

static NSString *WNAppSupportDirectoryPath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *basePath = paths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    return [basePath stringByAppendingPathComponent:@"Watti"];
}

static NSString *WNChargerNamesFilePath(void) {
    return [WNAppSupportDirectoryPath() stringByAppendingPathComponent:@"charger-names.plist"];
}

static NSString *WNTimestampString(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS Z";
    });

    return [formatter stringFromDate:[NSDate date]];
}

static void WNEnsureLogFile(void) {
    if (WNLogFD != -1) {
        return;
    }

    NSString *directoryPath = WNLogDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *filePath = WNLogFilePath();
    WNLogFD = open(filePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void WNLogLine(NSString *level, NSString *message) {
    WNEnsureLogFile();

    if (WNLogFD == -1) {
        return;
    }

    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", WNTimestampString(), level, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0) {
        write(WNLogFD, data.bytes, data.length);
    }
}

static const char *WNSignalName(int signalNumber) {
    switch (signalNumber) {
        case SIGABRT:
            return "SIGABRT";
        case SIGBUS:
            return "SIGBUS";
        case SIGFPE:
            return "SIGFPE";
        case SIGILL:
            return "SIGILL";
        case SIGSEGV:
            return "SIGSEGV";
        case SIGTRAP:
            return "SIGTRAP";
        default:
            return "SIGNAL";
    }
}

static void WNSignalHandler(int signalNumber) {
    if (WNLogFD != -1) {
        char buffer[256];
        int length = snprintf(buffer, sizeof(buffer), "signal [%s] pid=%d\n", WNSignalName(signalNumber), getpid());
        if (length > 0) {
            write(WNLogFD, buffer, (size_t)length);
        }
    }

    signal(signalNumber, SIG_DFL);
    kill(getpid(), signalNumber);
}

static void WNExceptionHandler(NSException *exception) {
    NSString *stack = [[exception callStackSymbols] componentsJoinedByString:@" || "];
    NSString *message = [NSString stringWithFormat:@"%@: %@ | stack=%@",
                                                   exception.name,
                                                   exception.reason ?: @"(no reason)",
                                                   stack ?: @"(no stack)"];
    WNLogLine(@"EXCEPTION", message);
}

static void WNInstallMonitoring(void) {
    WNEnsureLogFile();
    WNLogLine(@"INFO", [NSString stringWithFormat:@"launch pid=%d macOS=%@ log=%@",
                                                  getpid(),
                                                  NSProcessInfo.processInfo.operatingSystemVersionString,
                                                  WNLogFilePath()]);

    NSSetUncaughtExceptionHandler(&WNExceptionHandler);
    signal(SIGABRT, WNSignalHandler);
    signal(SIGBUS, WNSignalHandler);
    signal(SIGFPE, WNSignalHandler);
    signal(SIGILL, WNSignalHandler);
    signal(SIGSEGV, WNSignalHandler);
    signal(SIGTRAP, WNSignalHandler);
}

static double WNNumber(id value, BOOL *valid) {
    if ([value isKindOfClass:[NSNumber class]]) {
        if (valid) {
            *valid = YES;
        }
        return [(NSNumber *)value doubleValue];
    }

    if ([value isKindOfClass:[NSString class]]) {
        if (valid) {
            *valid = YES;
        }
        return [(NSString *)value doubleValue];
    }

    if (valid) {
        *valid = NO;
    }
    return 0;
}

static NSString *WNStringValue(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        return string.length > 0 ? string : nil;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }

    return nil;
}

static NSString *WNTitleCasedString(NSString *string) {
    if (string.length == 0) {
        return nil;
    }

    return [string capitalizedStringWithLocale:[NSLocale currentLocale]];
}

static NSString *WNDefaultChargerSetupName(NSString *descriptionText, double watts, double negotiatedWatts) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    double headlineWatts = watts > 0 ? watts : negotiatedWatts;
    if (headlineWatts > 0) {
        [parts addObject:[NSString stringWithFormat:@"%.0fW", headlineWatts]];
    }

    NSString *namedDescription = WNTitleCasedString(descriptionText ?: @"");
    if (namedDescription.length > 0) {
        [parts addObject:namedDescription];
    } else if (parts.count > 0) {
        [parts addObject:@"Charger"];
    } else {
        [parts addObject:@"Charger Setup"];
    }

    return [parts componentsJoinedByString:@" "];
}

static BOOL WNBool(id value, BOOL *valid) {
    if ([value isKindOfClass:[NSNumber class]]) {
        if (valid) {
            *valid = YES;
        }
        return [(NSNumber *)value boolValue];
    }

    if (valid) {
        *valid = NO;
    }
    return NO;
}

static int64_t WNSignedInt64(id value, BOOL *valid) {
    if (![value isKindOfClass:[NSNumber class]]) {
        if (valid) {
            *valid = NO;
        }
        return 0;
    }

    if (valid) {
        *valid = YES;
    }

    return (int64_t)[(NSNumber *)value unsignedLongLongValue];
}

static NSDictionary *WNBatteryRegistry(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service == IO_OBJECT_NULL) {
        return nil;
    }

    CFMutableDictionaryRef properties = NULL;
    kern_return_t status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
    IOObjectRelease(service);

    if (status != KERN_SUCCESS || properties == NULL) {
        return nil;
    }

    return CFBridgingRelease(properties);
}

static NSString *WNActivePowerSource(void) {
    CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
    if (snapshot == NULL) {
        return nil;
    }

    NSString *source = nil;
    CFArrayRef sources = IOPSCopyPowerSourcesList(snapshot);
    if (sources != NULL && CFArrayGetCount(sources) > 0) {
        CFTypeRef powerSource = CFArrayGetValueAtIndex(sources, 0);
        NSDictionary *description = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(snapshot, powerSource);
        id state = [description objectForKey:WNPowerSourceStateKey];
        if ([state isKindOfClass:[NSString class]]) {
            source = [state copy];
        }
    }

    if (sources != NULL) {
        CFRelease(sources);
    }

    CFRelease(snapshot);
    return source;
}

static NSDictionary *WNExternalPowerAdapterDetails(void) {
    CFDictionaryRef details = IOPSCopyExternalPowerAdapterDetails();
    if (details == NULL) {
        return nil;
    }

    return CFBridgingRelease(details);
}

static double WNBatteryWatts(NSNumber *voltageMV, NSNumber *amperageMA) {
    if (voltageMV == nil || amperageMA == nil) {
        return 0;
    }

    return fabs(voltageMV.doubleValue * amperageMA.doubleValue) / 1000000.0;
}

static NSNumber *WNAverageMilliwatts(id sumValue, id countValue) {
    BOOL hasSum = NO;
    BOOL hasCount = NO;
    double sum = WNNumber(sumValue, &hasSum);
    double count = WNNumber(countValue, &hasCount);

    if (!hasSum || !hasCount || sum <= 0 || count <= 0) {
        return nil;
    }

    return @(sum / count / 1000.0);
}

static double WNMaximumPortControllerWatts(NSArray *ports) {
    double maxMilliwatts = 0;

    for (id entry in ports) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        BOOL valid = NO;
        double value = WNNumber(entry[@"PortControllerMaxPower"], &valid);
        if (valid && value > maxMilliwatts) {
            maxMilliwatts = value;
        }
    }

    return maxMilliwatts > 0 ? maxMilliwatts / 1000.0 : 0;
}

static PowerSnapshot *WNSnapshot(void) {
    NSDictionary *registry = WNBatteryRegistry() ?: @{};
    NSDictionary *batteryData = [registry[@"BatteryData"] isKindOfClass:[NSDictionary class]] ? registry[@"BatteryData"] : @{};
    NSDictionary *chargerData = [registry[@"ChargerData"] isKindOfClass:[NSDictionary class]] ? registry[@"ChargerData"] : @{};
    NSDictionary *telemetry = [registry[@"PowerTelemetryData"] isKindOfClass:[NSDictionary class]] ? registry[@"PowerTelemetryData"] : @{};
    NSDictionary *adapterDetails = WNExternalPowerAdapterDetails();
    if (![adapterDetails isKindOfClass:[NSDictionary class]]) {
        adapterDetails = [registry[@"AdapterDetails"] isKindOfClass:[NSDictionary class]] ? registry[@"AdapterDetails"] : @{};
    }
    NSArray *portControllerInfo = [registry[@"PortControllerInfo"] isKindOfClass:[NSArray class]] ? registry[@"PortControllerInfo"] : @[];

    BOOL hasExternal = NO;
    BOOL externalConnected = WNBool(registry[@"ExternalConnected"], &hasExternal);
    NSString *powerSource = WNActivePowerSource();
    BOOL onAC = powerSource != nil ? [powerSource isEqualToString:WNACPowerValue] : (hasExternal && externalConnected);

    BOOL hasCharging = NO;
    BOOL isCharging = WNBool(registry[@"IsCharging"], &hasCharging);
    (void)hasCharging;
    BOOL hasFullyCharged = NO;
    BOOL fullyCharged = WNBool(registry[@"FullyCharged"], &hasFullyCharged);

    BOOL hasVoltage = NO;
    double voltageMV = WNNumber(registry[@"Voltage"], &hasVoltage);
    if (!hasVoltage) {
        voltageMV = WNNumber(batteryData[@"Voltage"], &hasVoltage);
    }

    BOOL hasAmperage = NO;
    int64_t amperageMA = WNSignedInt64(registry[@"Amperage"], &hasAmperage);
    if (!hasAmperage) {
        amperageMA = WNSignedInt64(registry[@"InstantAmperage"], &hasAmperage);
    }

    BOOL hasCurrentCapacity = NO;
    double currentCapacity = WNNumber(registry[@"CurrentCapacity"], &hasCurrentCapacity);
    if (!hasCurrentCapacity) {
        currentCapacity = WNNumber(batteryData[@"CurrentCapacity"], &hasCurrentCapacity);
    }

    BOOL hasMaxCapacity = NO;
    double maxCapacity = WNNumber(registry[@"MaxCapacity"], &hasMaxCapacity);
    if (!hasMaxCapacity) {
        maxCapacity = WNNumber(batteryData[@"MaxCapacity"], &hasMaxCapacity);
    }

    BOOL hasDesignCapacity = NO;
    double designCapacity = WNNumber(registry[@"DesignCapacity"], &hasDesignCapacity);
    if (!hasDesignCapacity) {
        designCapacity = WNNumber(batteryData[@"DesignCapacity"], &hasDesignCapacity);
    }

    BOOL hasUISoc = NO;
    double uiSoc = WNNumber(batteryData[@"UISoc"], &hasUISoc);
    BOOL hasAvgTimeToFull = NO;
    double avgTimeToFull = WNNumber(registry[@"AvgTimeToFull"], &hasAvgTimeToFull);
    BOOL hasAvgTimeToEmpty = NO;
    double avgTimeToEmpty = WNNumber(registry[@"AvgTimeToEmpty"], &hasAvgTimeToEmpty);
    BOOL hasTimeRemaining = NO;
    double timeRemaining = WNNumber(registry[@"TimeRemaining"], &hasTimeRemaining);

    NSNumber *batteryWatts = (hasVoltage && hasAmperage && amperageMA != 0) ? @(WNBatteryWatts(@(voltageMV), @(amperageMA))) : nil;

    BOOL hasAdapterPower = NO;
    double adapterPower = WNNumber(batteryData[@"AdapterPower"], &hasAdapterPower);

    BOOL hasSystemPowerIn = NO;
    double systemPowerIn = WNNumber(telemetry[@"SystemPowerIn"], &hasSystemPowerIn);
    BOOL hasSystemLoad = NO;
    double systemLoad = WNNumber(telemetry[@"SystemLoad"], &hasSystemLoad);
    BOOL hasSystemCurrentIn = NO;
    BOOL hasSystemVoltageIn = NO;
    double systemCurrentIn = WNNumber(telemetry[@"SystemCurrentIn"], &hasSystemCurrentIn);
    double systemVoltageIn = WNNumber(telemetry[@"SystemVoltageIn"], &hasSystemVoltageIn);

    BOOL hasChargingCurrent = NO;
    BOOL hasChargingVoltage = NO;
    double chargingCurrent = WNNumber(chargerData[@"ChargingCurrent"], &hasChargingCurrent);
    double chargingVoltage = WNNumber(chargerData[@"ChargingVoltage"], &hasChargingVoltage);
    BOOL hasAdapterWatts = NO;
    double adapterWatts = WNNumber(adapterDetails[@"Watts"], &hasAdapterWatts);
    BOOL hasAdapterVoltage = NO;
    double adapterVoltage = WNNumber(adapterDetails[@"AdapterVoltage"], &hasAdapterVoltage);
    BOOL hasAdapterCurrent = NO;
    double adapterCurrent = WNNumber(adapterDetails[@"Current"], &hasAdapterCurrent);
    NSString *adapterDescription = WNStringValue(adapterDetails[@"Description"]);
    NSString *familyCode = WNStringValue(adapterDetails[@"FamilyCode"]);

    PowerSnapshot *snapshot = [PowerSnapshot new];
    snapshot.onAC = onAC;
    snapshot.charging = isCharging;
    snapshot.fullyCharged = hasFullyCharged && fullyCharged;
    snapshot.powerSourceState = powerSource ?: @"unknown";
    snapshot.externalConnectedReported = hasExternal && externalConnected;
    snapshot.inputWatts = hasSystemPowerIn && systemPowerIn > 0 ? systemPowerIn / 1000.0 : 0;
    if (snapshot.inputWatts <= 0 && hasSystemCurrentIn && hasSystemVoltageIn && systemCurrentIn > 0 && systemVoltageIn > 0) {
        snapshot.inputWatts = (systemCurrentIn * systemVoltageIn) / 1000000.0;
    }
    snapshot.systemLoadWatts = hasSystemLoad && systemLoad > 0 ? systemLoad / 1000.0 : 0;
    snapshot.adapterRatedWatts = hasAdapterWatts && adapterWatts > 0 ? adapterWatts : 0;
    snapshot.negotiatedWatts = WNMaximumPortControllerWatts(portControllerInfo);
    snapshot.batteryPercent = hasUISoc && uiSoc > 0 ? uiSoc : ((hasCurrentCapacity && hasMaxCapacity && maxCapacity > 0) ? ((currentCapacity / maxCapacity) * 100.0) : 0);
    snapshot.batteryHealthPercent = (hasMaxCapacity && hasDesignCapacity && designCapacity > 0) ? ((maxCapacity / designCapacity) * 100.0) : 0;
    snapshot.remainingWattHours = (hasCurrentCapacity && currentCapacity > 0 && hasVoltage && voltageMV > 0) ? ((currentCapacity * voltageMV) / 1000000.0) : 0;
    snapshot.systemTimeToEmptyMinutes = hasAvgTimeToEmpty && avgTimeToEmpty > 0 && avgTimeToEmpty < 65535 ? avgTimeToEmpty : 0;
    if (snapshot.systemTimeToEmptyMinutes <= 0 && hasTimeRemaining && timeRemaining > 0 && timeRemaining < 65535) {
        snapshot.systemTimeToEmptyMinutes = timeRemaining;
    }
    snapshot.systemTimeToFullMinutes = hasAvgTimeToFull && avgTimeToFull > 0 && avgTimeToFull < 65535 ? avgTimeToFull : 0;
    if (snapshot.systemTimeToFullMinutes <= 0 && onAC && isCharging && hasCurrentCapacity && hasMaxCapacity && maxCapacity > currentCapacity && hasVoltage && voltageMV > 0 && batteryWatts.doubleValue > 0) {
        double remainingWhToFull = ((maxCapacity - currentCapacity) * voltageMV) / 1000000.0;
        snapshot.systemTimeToFullMinutes = (remainingWhToFull / batteryWatts.doubleValue) * 60.0;
    }
    snapshot.chargerSuggestedName = WNDefaultChargerSetupName(adapterDescription, snapshot.adapterRatedWatts, snapshot.negotiatedWatts);
    if (familyCode.length > 0 || adapterDescription.length > 0 || snapshot.adapterRatedWatts > 0 || hasAdapterVoltage || hasAdapterCurrent || snapshot.negotiatedWatts > 0) {
        snapshot.chargerFingerprint = [NSString stringWithFormat:@"family=%@|desc=%@|watts=%.0f|voltage=%.0f|current=%.0f|max=%.0f",
                                       familyCode ?: @"",
                                       adapterDescription ?: @"",
                                       snapshot.adapterRatedWatts,
                                       hasAdapterVoltage ? adapterVoltage : 0,
                                       hasAdapterCurrent ? adapterCurrent : 0,
                                       snapshot.negotiatedWatts];
    }

    if (snapshot.inputWatts > 0 && onAC) {
        snapshot.watts = snapshot.inputWatts;
        snapshot.subtitle = @"Receiving External Power";
        snapshot.caption = @"Measured from live charger telemetry";
        snapshot.source = @"system_power_in";
        snapshot.dotColor = WNColor(0.93, 0.45, 0.29, 1.0);
        return snapshot;
    }

    if (onAC && hasAdapterPower && adapterPower > 0) {
        snapshot.watts = adapterPower;
        snapshot.subtitle = @"Receiving External Power";
        snapshot.caption = @"Reported by the adapter, not live input";
        snapshot.source = @"adapter_power";
        snapshot.dotColor = WNColor(0.93, 0.45, 0.29, 1.0);
        return snapshot;
    }

    if (onAC && hasChargingCurrent && hasChargingVoltage && chargingCurrent > 0 && chargingVoltage > 0) {
        snapshot.watts = (chargingCurrent * chargingVoltage) / 1000000.0;
        snapshot.subtitle = @"Receiving External Power";
        snapshot.caption = @"Estimated from battery charge telemetry";
        snapshot.source = @"charging_rate";
        snapshot.dotColor = WNColor(0.92, 0.53, 0.29, 1.0);
        return snapshot;
    }

    if (batteryWatts != nil && batteryWatts.doubleValue > 0) {
        snapshot.watts = batteryWatts.doubleValue;

        if (onAC && amperageMA < 0) {
            snapshot.subtitle = @"Receiving External Power";
            snapshot.caption = @"AC is connected and the battery is assisting";
            snapshot.source = @"battery_assist";
            snapshot.dotColor = WNColor(0.80, 0.43, 0.33, 1.0);
            return snapshot;
        }

        if (onAC) {
            snapshot.subtitle = @"Receiving External Power";
            snapshot.caption = @"Estimated from battery flow";
            snapshot.source = @"battery_charge_flow";
            snapshot.dotColor = WNColor(0.92, 0.53, 0.29, 1.0);
            return snapshot;
        }

        snapshot.subtitle = @"Running on Battery";
        snapshot.caption = @"Estimated from battery voltage and current";
        snapshot.source = @"battery_power";
        snapshot.dotColor = WNColor(0.42, 0.69, 0.45, 1.0);
        return snapshot;
    }

    NSNumber *average = WNAverageMilliwatts(telemetry[@"AccumulatedSystemPowerIn"], telemetry[@"SystemPowerInAccumulatorCount"]);
    if (average == nil) {
        average = WNAverageMilliwatts(telemetry[@"AccumulatedBatteryPower"], telemetry[@"BatteryPowerAccumulatorCount"]);
    }
    if (average == nil) {
        average = WNAverageMilliwatts(telemetry[@"AccumulatedSystemLoad"], telemetry[@"SystemLoadAccumulatorCount"]);
    }

    if (average != nil && average.doubleValue > 0) {
        snapshot.watts = average.doubleValue;
        snapshot.subtitle = onAC ? @"Receiving External Power" : @"Running on Battery";
        snapshot.caption = @"Estimated from smoothed telemetry";
        snapshot.source = @"smoothed_telemetry";
        snapshot.dotColor = WNColor(0.80, 0.57, 0.31, 1.0);
        return snapshot;
    }

    snapshot.watts = 0;
    snapshot.subtitle = onAC ? @"Receiving External Power" : @"Waiting for Live Power Data";
    snapshot.caption = @"Live power telemetry is unavailable";
    snapshot.source = @"no_live_data";
    snapshot.dotColor = WNColor(0.80, 0.65, 0.30, 1.0);
    return snapshot;
}

static NSImage *WNStatusImage(BOOL onPower) {
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"bolt.fill" accessibilityDescription:@"Watti"];
    if (symbol == nil) {
        return nil;
    }

    NSImage *image = [symbol copy];
    image.size = NSMakeSize(13, 13);

    if (onPower) {
        if (@available(macOS 11.0, *)) {
            NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.systemGreenColor];
            NSImage *colored = [symbol imageWithSymbolConfiguration:configuration];
            image = [colored copy];
            image.size = NSMakeSize(13, 13);
            image.template = NO;
            return image;
        }
    }

    image.template = YES;
    return image;
}

static NSAttributedString *WNStatusItemTitle(BOOL onPower, NSString *text) {
    NSMutableAttributedString *result = [NSMutableAttributedString new];

    NSImage *image = WNStatusImage(onPower);
    if (image != nil) {
        NSTextAttachment *attachment = [NSTextAttachment new];
        attachment.image = image;
        NSAttributedString *icon = [NSAttributedString attributedStringWithAttachment:attachment];
        NSMutableAttributedString *adjustedIcon = [[NSMutableAttributedString alloc] initWithAttributedString:icon];
        [adjustedIcon addAttributes:@{
            NSBaselineOffsetAttributeName: @(-1.0)
        } range:NSMakeRange(0, adjustedIcon.length)];
        [result appendAttributedString:adjustedIcon];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
    }

    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.labelColor,
        NSKernAttributeName: @(-0.15)
    };
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    return result;
}

static NSImage *WNBrandMarkImage(BOOL onPower, BOOL charging) {
    NSSize size = NSMakeSize(14, 14);
    NSImage *image = [[NSImage alloc] initWithSize:size];
    BOOL pulse = charging && (((NSInteger)(CFAbsoluteTimeGetCurrent() * 2.0)) % 2 == 0);

    NSColor *fillColor = nil;
    NSColor *strokeColor = nil;
    NSColor *symbolColor = nil;

    if (charging) {
        fillColor = pulse ? WNColor(0.84, 0.98, 0.89, 1.0) : WNColor(0.90, 0.98, 0.93, 1.0);
        strokeColor = pulse ? WNColor(0.31, 0.78, 0.42, 1.0) : WNColor(0.56, 0.84, 0.63, 1.0);
        symbolColor = WNColor(0.10, 0.61, 0.22, 1.0);
    } else if (onPower) {
        fillColor = WNColor(0.92, 0.97, 0.93, 1.0);
        strokeColor = WNColor(0.77, 0.89, 0.79, 1.0);
        symbolColor = NSColor.systemGreenColor;
    } else {
        fillColor = WNColor(0.97, 0.95, 0.92, 1.0);
        strokeColor = WNColor(0.84, 0.79, 0.72, 1.0);
        symbolColor = WNColor(0.31, 0.25, 0.19, 1.0);
    }

    [image lockFocus];

    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.5, 0.5, 13.0, 13.0) xRadius:4 yRadius:4];
    [fillColor setFill];
    [background fill];
    [strokeColor setStroke];
    background.lineWidth = 1.0;
    [background stroke];

    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"bolt.fill" accessibilityDescription:@"Watti"];
    if (symbol != nil) {
        if (@available(macOS 11.0, *)) {
            NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithHierarchicalColor:symbolColor];
            symbol = [symbol imageWithSymbolConfiguration:configuration];
        }
        [symbol drawInRect:NSMakeRect(3.0, 2.0, 8.0, 10.0)
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:1.0];
    }

    [image unlockFocus];
    image.template = NO;
    return image;
}

@interface FoldView : NSView
@end

@implementation FoldView

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    [[WNColor(1.0, 1.0, 1.0, 0.72) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] setFill];

    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(NSMaxX(self.bounds), NSMaxY(self.bounds))];
    [path lineToPoint:NSMakePoint(NSMaxX(self.bounds), NSMinY(self.bounds))];
    [path lineToPoint:NSMakePoint(NSMinX(self.bounds), NSMaxY(self.bounds))];
    [path closePath];
    [path fill];
}

@end

@interface RollingWattsView : NSView
@property(nonatomic, strong) NSTextField *currentLabel;
@property(nonatomic) double displayedWatts;
@property(nonatomic) BOOL hasDisplayedValue;
@property(nonatomic) BOOL animating;
- (void)setWatts:(double)watts;
@end

@implementation RollingWattsView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self == nil) {
        return nil;
    }

    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    self.currentLabel = [self makeLabel];
    self.currentLabel.frame = self.bounds;
    [self addSubview:self.currentLabel];
    return self;
}

- (void)layout {
    [super layout];

    if (!self.animating) {
        self.currentLabel.frame = self.bounds;
    }
}

- (NSTextField *)makeLabel {
    NSTextField *label = [NSTextField labelWithString:@"+0.0 W"];
    label.font = [NSFont monospacedDigitSystemFontOfSize:42 weight:NSFontWeightBold];
    label.textColor = WNColor(0.16, 0.13, 0.11, 1.0);
    label.alignment = NSTextAlignmentLeft;
    label.lineBreakMode = NSLineBreakByClipping;
    label.frame = self.bounds;
    return label;
}

- (void)setWatts:(double)watts {
    NSString *nextText = [NSString stringWithFormat:@"%+.1f W", watts];

    if (!self.hasDisplayedValue) {
        self.hasDisplayedValue = YES;
        self.displayedWatts = watts;
        self.currentLabel.stringValue = nextText;
        self.currentLabel.frame = self.bounds;
        return;
    }

    if (fabs(watts - self.displayedWatts) < 0.05) {
        self.currentLabel.stringValue = nextText;
        return;
    }

    CGFloat height = NSHeight(self.bounds);
    if (height <= 0) {
        self.displayedWatts = watts;
        self.currentLabel.stringValue = nextText;
        return;
    }

    BOOL increase = watts > self.displayedWatts;
    NSTextField *outgoingLabel = self.currentLabel;
    NSTextField *incomingLabel = [self makeLabel];
    incomingLabel.stringValue = nextText;
    incomingLabel.frame = NSOffsetRect(self.bounds, 0, increase ? -height : height);
    [self addSubview:incomingLabel];

    self.currentLabel = incomingLabel;
    self.displayedWatts = watts;
    self.animating = YES;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        outgoingLabel.animator.frame = NSOffsetRect(self.bounds, 0, increase ? height : -height);
        incomingLabel.animator.frame = self.bounds;
    } completionHandler:^{
        [outgoingLabel removeFromSuperview];
        self.animating = NO;
    }];
}

@end

@interface SparklineView : NSView
@property(nonatomic, copy) NSArray<NSNumber *> *samples;
@end

@implementation SparklineView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self == nil) {
        return nil;
    }

    self.wantsLayer = YES;
    self.layer.backgroundColor = WNColor(1.0, 1.0, 1.0, 0.58).CGColor;
    self.layer.cornerRadius = 10;
    self.layer.borderWidth = 1;
    self.layer.borderColor = WNColor(0.0, 0.0, 0.0, 0.05).CGColor;
    return self;
}

- (void)setSamples:(NSArray<NSNumber *> *)samples {
    _samples = [samples copy];
    [self setNeedsDisplay:YES];
}

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    (void)dirtyRect;

    NSArray<NSNumber *> *samples = self.samples;
    if (samples.count < 2) {
        return;
    }

    CGFloat inset = 10;
    NSRect plotRect = NSInsetRect(self.bounds, inset, inset);
    if (plotRect.size.width <= 0 || plotRect.size.height <= 0) {
        return;
    }

    CGFloat minValue = CGFLOAT_MAX;
    CGFloat maxValue = -CGFLOAT_MAX;
    for (NSNumber *sample in samples) {
        CGFloat value = sample.doubleValue;
        if (value < minValue) {
            minValue = value;
        }
        if (value > maxValue) {
            maxValue = value;
        }
    }

    CGFloat range = MAX(maxValue - minValue, 0.5);
    CGFloat stepX = plotRect.size.width / MAX((CGFloat)(samples.count - 1), 1);

    [[WNColor(0.0, 0.0, 0.0, 0.05) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath];
    [grid moveToPoint:NSMakePoint(NSMinX(plotRect), NSMidY(plotRect))];
    [grid lineToPoint:NSMakePoint(NSMaxX(plotRect), NSMidY(plotRect))];
    grid.lineWidth = 1;
    [grid stroke];

    NSBezierPath *line = [NSBezierPath bezierPath];
    NSBezierPath *fill = [NSBezierPath bezierPath];

    for (NSUInteger index = 0; index < samples.count; index++) {
        CGFloat x = NSMinX(plotRect) + ((CGFloat)index * stepX);
        CGFloat normalized = (samples[index].doubleValue - minValue) / range;
        CGFloat y = NSMinY(plotRect) + (normalized * plotRect.size.height);
        NSPoint point = NSMakePoint(x, y);

        if (index == 0) {
            [line moveToPoint:point];
            [fill moveToPoint:NSMakePoint(x, NSMinY(plotRect))];
            [fill lineToPoint:point];
        } else {
            [line lineToPoint:point];
            [fill lineToPoint:point];
        }
    }

    [fill lineToPoint:NSMakePoint(NSMaxX(plotRect), NSMinY(plotRect))];
    [fill closePath];
    [[WNColor(0.17, 0.66, 0.35, 0.14) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] setFill];
    [fill fill];

    [[WNColor(0.15, 0.58, 0.31, 0.95) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] setStroke];
    line.lineWidth = 2;
    [line stroke];
}

@end

@interface MonitoringToggleControl : NSControl
@property(nonatomic) BOOL on;
@property(nonatomic, strong) NSTextField *labelField;
@property(nonatomic, strong) NSView *knobView;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

@implementation MonitoringToggleControl

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self == nil) {
        return nil;
    }

    self.wantsLayer = YES;
    self.layer.cornerRadius = 12;
    self.layer.borderWidth = 1;
    self.layer.borderColor = WNColor(0.0, 0.0, 0.0, 0.08).CGColor;

    self.labelField = [NSTextField labelWithString:@"ON"];
    self.labelField.translatesAutoresizingMaskIntoConstraints = NO;
    self.labelField.font = [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold];
    self.labelField.alignment = NSTextAlignmentCenter;
    [self addSubview:self.labelField];

    self.knobView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.knobView.translatesAutoresizingMaskIntoConstraints = NO;
    self.knobView.wantsLayer = YES;
    self.knobView.layer.cornerRadius = 7;
    self.knobView.layer.shadowColor = NSColor.blackColor.CGColor;
    self.knobView.layer.shadowOpacity = 0.12;
    self.knobView.layer.shadowRadius = 2;
    self.knobView.layer.shadowOffset = CGSizeMake(0, -1);
    [self addSubview:self.knobView];

    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:52],
        [self.heightAnchor constraintEqualToConstant:20],
        [self.labelField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.labelField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:7],
        [self.labelField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-7],
        [self.knobView.widthAnchor constraintEqualToConstant:14],
        [self.knobView.heightAnchor constraintEqualToConstant:14],
        [self.knobView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    [self setOn:YES animated:NO];
    return self;
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    [self setOn:!self.on animated:YES];
    [self sendAction:self.action to:self.target];
}

- (void)setOn:(BOOL)on {
    [self setOn:on animated:NO];
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;

    CGFloat inset = 3;
    CGFloat knobWidth = 14;
    CGFloat knobX = on ? (NSWidth(self.bounds) - knobWidth - inset) : inset;
    NSRect knobFrame = NSMakeRect(knobX, inset, knobWidth, knobWidth);

    self.layer.backgroundColor = on ? WNColor(0.90, 0.95, 1.0, 1.0).CGColor : WNColor(0.92, 0.92, 0.93, 1.0).CGColor;
    self.layer.borderColor = on ? WNColor(0.74, 0.84, 0.98, 1.0).CGColor : WNColor(0.0, 0.0, 0.0, 0.08).CGColor;
    self.labelField.stringValue = on ? @"ON" : @"OFF";
    self.labelField.textColor = on ? WNColor(0.16, 0.43, 0.86, 1.0) : WNColor(0.48, 0.49, 0.52, 1.0);
    self.labelField.alignment = on ? NSTextAlignmentLeft : NSTextAlignmentRight;
    self.knobView.layer.backgroundColor = NSColor.whiteColor.CGColor;

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.16;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            self.knobView.animator.frame = knobFrame;
        } completionHandler:nil];
    } else {
        self.knobView.frame = knobFrame;
    }
}

@end

@interface PowerNoteView : NSView
@property(nonatomic, strong) RollingWattsView *wattsView;
@property(nonatomic, strong) NSTextField *headlineLabel;
@property(nonatomic, strong) NSTextField *subtitleLabel;
@property(nonatomic, strong) NSTextField *captionLabel;
@property(nonatomic, strong) NSLayoutConstraint *captionHeightConstraint;
@property(nonatomic, strong) NSTextField *brandLabel;
@property(nonatomic, strong) NSTextField *runtimeLabel;
@property(nonatomic, strong) NSTextField *runtimeValueLabel;
@property(nonatomic, strong) NSTextField *batteryValueLabel;
@property(nonatomic, strong) NSTextField *timeToFullValueLabel;
@property(nonatomic, strong) NSTextField *chargerValueLabel;
@property(nonatomic, strong) MonitoringToggleControl *monitoringToggle;
@property(nonatomic, copy) void (^monitoringChanged)(BOOL enabled);
- (void)applySnapshot:(PowerSnapshot *)snapshot monitoringEnabled:(BOOL)monitoringEnabled samples:(NSArray<NSNumber *> *)samples;
@end

@implementation PowerNoteView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self == nil) {
        return nil;
    }

    self.wantsLayer = YES;
    self.layer.backgroundColor = WNColor(0.97, 0.975, 0.98, 1.0).CGColor;
    self.layer.cornerRadius = 18;
    self.layer.borderWidth = 1;
    self.layer.borderColor = WNColor(0.0, 0.0, 0.0, 0.06).CGColor;

    self.brandLabel = [self labelWithString:@"Watti"
                                       size:15
                                     weight:NSFontWeightSemibold
                                      color:WNColor(0.31, 0.25, 0.19, 1.0)];
    self.brandLabel.wantsLayer = YES;
    [self addSubview:self.brandLabel];

    self.monitoringToggle = [[MonitoringToggleControl alloc] initWithFrame:NSZeroRect];
    self.monitoringToggle.translatesAutoresizingMaskIntoConstraints = NO;
    self.monitoringToggle.target = self;
    self.monitoringToggle.action = @selector(monitoringToggleChanged:);
    [self addSubview:self.monitoringToggle];

    self.headlineLabel = [self labelWithString:@"--"
                                          size:11
                                        weight:NSFontWeightSemibold
                                         color:WNColor(0.16, 0.13, 0.11, 1.0)];
    self.headlineLabel.alignment = NSTextAlignmentRight;
    [self addSubview:self.headlineLabel];

    self.wattsView = [[RollingWattsView alloc] initWithFrame:NSZeroRect];
    self.wattsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.wattsView];

    self.subtitleLabel = [self labelWithString:@"--"
                                          size:13
                                        weight:NSFontWeightMedium
                                         color:WNColor(0.16, 0.13, 0.11, 1.0)];
    self.subtitleLabel.alignment = NSTextAlignmentRight;
    [self addSubview:self.subtitleLabel];

    self.captionLabel = [self labelWithString:@"Waiting for telemetry"
                                         size:10
                                       weight:NSFontWeightMedium
                                        color:WNColor(0.55, 0.58, 0.63, 1.0)];
    [self addSubview:self.captionLabel];
    self.captionHeightConstraint = [self.captionLabel.heightAnchor constraintEqualToConstant:0];

    NSTextField *setupLabel = [self labelWithString:@"Charger Setup"
                                               size:11
                                             weight:NSFontWeightMedium
                                              color:WNColor(0.43, 0.47, 0.52, 1.0)];
    [self addSubview:setupLabel];

    NSTextField *sourceLabel = [self labelWithString:@"Power Source"
                                                size:11
                                              weight:NSFontWeightMedium
                                               color:WNColor(0.43, 0.47, 0.52, 1.0)];
    [self addSubview:sourceLabel];

    self.runtimeLabel = [self labelWithString:@"Predicted Runtime"
                                         size:11
                                       weight:NSFontWeightMedium
                                        color:WNColor(0.43, 0.47, 0.52, 1.0)];
    [self addSubview:self.runtimeLabel];

    self.runtimeValueLabel = [self labelWithString:@"--"
                                              size:11
                                            weight:NSFontWeightSemibold
                                             color:WNColor(0.16, 0.13, 0.11, 1.0)];
    self.runtimeValueLabel.alignment = NSTextAlignmentRight;
    [self addSubview:self.runtimeValueLabel];

    NSTextField *timeToFullLabel = [self labelWithString:@"Time to Full"
                                                    size:11
                                                  weight:NSFontWeightMedium
                                                   color:WNColor(0.43, 0.47, 0.52, 1.0)];
    [self addSubview:timeToFullLabel];

    self.timeToFullValueLabel = [self labelWithString:@"--"
                                                 size:11
                                               weight:NSFontWeightSemibold
                                                color:WNColor(0.16, 0.13, 0.11, 1.0)];
    self.timeToFullValueLabel.alignment = NSTextAlignmentRight;
    [self addSubview:self.timeToFullValueLabel];

    NSTextField *chargerLabel = [self labelWithString:@"Charger Profile"
                                                 size:11
                                               weight:NSFontWeightMedium
                                                color:WNColor(0.43, 0.47, 0.52, 1.0)];
    [self addSubview:chargerLabel];

    self.chargerValueLabel = [self labelWithString:@"--"
                                              size:11
                                            weight:NSFontWeightSemibold
                                             color:WNColor(0.16, 0.13, 0.11, 1.0)];
    self.chargerValueLabel.alignment = NSTextAlignmentRight;
    [self addSubview:self.chargerValueLabel];

    NSTextField *monitoringLabel = [self labelWithString:@"Monitoring"
                                                    size:10
                                                  weight:NSFontWeightMedium
                                                   color:WNColor(0.50, 0.53, 0.58, 1.0)];
    [self addSubview:monitoringLabel];

    NSView *divider = [[NSView alloc] initWithFrame:NSZeroRect];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = WNColor(0.0, 0.0, 0.0, 0.07).CGColor;
    [self addSubview:divider];

    [NSLayoutConstraint activateConstraints:@[
        [self.brandLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
        [self.brandLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],

        [self.wattsView.topAnchor constraintEqualToAnchor:self.brandLabel.bottomAnchor constant:18],
        [self.wattsView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.wattsView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.wattsView.heightAnchor constraintEqualToConstant:50],

        [divider.topAnchor constraintEqualToAnchor:self.wattsView.bottomAnchor constant:18],
        [divider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [divider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [divider.heightAnchor constraintEqualToConstant:1],

        [setupLabel.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:16],
        [setupLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.headlineLabel.centerYAnchor constraintEqualToAnchor:setupLabel.centerYAnchor],
        [self.headlineLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.headlineLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:setupLabel.trailingAnchor constant:12],

        [sourceLabel.topAnchor constraintEqualToAnchor:setupLabel.bottomAnchor constant:10],
        [sourceLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.subtitleLabel.centerYAnchor constraintEqualToAnchor:sourceLabel.centerYAnchor],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.subtitleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:sourceLabel.trailingAnchor constant:12],

        [self.runtimeLabel.topAnchor constraintEqualToAnchor:sourceLabel.bottomAnchor constant:10],
        [self.runtimeLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.runtimeValueLabel.centerYAnchor constraintEqualToAnchor:self.runtimeLabel.centerYAnchor],
        [self.runtimeValueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.runtimeValueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.runtimeLabel.trailingAnchor constant:12],

        [timeToFullLabel.topAnchor constraintEqualToAnchor:self.runtimeLabel.bottomAnchor constant:10],
        [timeToFullLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.timeToFullValueLabel.centerYAnchor constraintEqualToAnchor:timeToFullLabel.centerYAnchor],
        [self.timeToFullValueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.timeToFullValueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:timeToFullLabel.trailingAnchor constant:12],

        [chargerLabel.topAnchor constraintEqualToAnchor:timeToFullLabel.bottomAnchor constant:10],
        [chargerLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.chargerValueLabel.centerYAnchor constraintEqualToAnchor:chargerLabel.centerYAnchor],
        [self.chargerValueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.chargerValueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:chargerLabel.trailingAnchor constant:12],

        [monitoringLabel.topAnchor constraintEqualToAnchor:chargerLabel.bottomAnchor constant:12],
        [monitoringLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [monitoringLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14],
        [self.monitoringToggle.centerYAnchor constraintEqualToAnchor:monitoringLabel.centerYAnchor],
        [self.monitoringToggle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
    ]];

    return self;
}

- (NSTextField *)labelWithString:(NSString *)string
                            size:(CGFloat)size
                          weight:(NSFontWeight)weight
                           color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:string];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (NSString *)detailTextForSnapshot:(PowerSnapshot *)snapshot {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if (snapshot.adapterRatedWatts > 0) {
        [parts addObject:[NSString stringWithFormat:@"%.0f W rated", snapshot.adapterRatedWatts]];
    }

    if (snapshot.negotiatedWatts > 0) {
        [parts addObject:[NSString stringWithFormat:@"%.1f W max", snapshot.negotiatedWatts]];
    }

    if (parts.count == 0 && snapshot.inputWatts > 0) {
        [parts addObject:[NSString stringWithFormat:@"%.1f W live", snapshot.inputWatts]];
    }

    return parts.count > 0 ? [parts componentsJoinedByString:@" / "] : @"--";
}

- (NSString *)runtimeTextForSnapshot:(PowerSnapshot *)snapshot {
    double minutes = snapshot.predictedMinutesRemaining > 0 ? snapshot.predictedMinutesRemaining : snapshot.systemTimeToEmptyMinutes;
    if (minutes <= 0) {
        return @"--";
    }

    return WNDurationString(minutes);
}

- (NSString *)runtimeTitleForSnapshot:(PowerSnapshot *)snapshot {
    if (snapshot.onAC && ![snapshot.source isEqualToString:@"battery_assist"]) {
        return @"If Unplugged Now";
    }

    return @"Battery Life";
}

- (NSString *)powerSourceTextForSnapshot:(PowerSnapshot *)snapshot {
    NSString *batteryPart = snapshot.batteryPercent > 0 ? [NSString stringWithFormat:@" · %.0f%% battery", snapshot.batteryPercent] : @"";

    if (!snapshot.onAC) {
        return [NSString stringWithFormat:@"Battery%@", batteryPart];
    }

    if ([snapshot.source isEqualToString:@"battery_assist"]) {
        return [NSString stringWithFormat:@"AC + Battery%@", batteryPart];
    }

    return [NSString stringWithFormat:@"AC Charger%@", batteryPart];
}

- (NSString *)batteryTextForSnapshot:(PowerSnapshot *)snapshot {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if (snapshot.batteryPercent > 0) {
        [parts addObject:[NSString stringWithFormat:@"%.0f%% now", snapshot.batteryPercent]];
    }

    if (snapshot.batteryHealthPercent > 0) {
        [parts addObject:[NSString stringWithFormat:@"%.0f%% health", snapshot.batteryHealthPercent]];
    }

    return parts.count > 0 ? [parts componentsJoinedByString:@" / "] : @"--";
}

- (NSString *)timeToFullTextForSnapshot:(PowerSnapshot *)snapshot {
    if (snapshot.fullyCharged) {
        return @"Full";
    }

    if (snapshot.systemTimeToFullMinutes > 0) {
        return WNDurationString(snapshot.systemTimeToFullMinutes);
    }

    if (snapshot.onAC && snapshot.charging) {
        return @"Charging";
    }

    if (snapshot.onAC) {
        return @"Not Charging";
    }

    return @"--";
}

- (void)monitoringToggleChanged:(id)sender {
    (void)sender;
    if (self.monitoringChanged != nil) {
        self.monitoringChanged(self.monitoringToggle.on);
    }
}

- (void)applySnapshot:(PowerSnapshot *)snapshot monitoringEnabled:(BOOL)monitoringEnabled samples:(NSArray<NSNumber *> *)samples {
    (void)samples;
    double displayWatts = snapshot.onAC ? fabs(snapshot.watts) : -fabs(snapshot.watts);
    [self.wattsView setWatts:displayWatts];
    self.headlineLabel.stringValue = snapshot.chargerDisplayName.length > 0 ? snapshot.chargerDisplayName : (snapshot.onAC ? @"Charger Setup" : @"Battery Power");
    self.subtitleLabel.stringValue = monitoringEnabled ? [self powerSourceTextForSnapshot:snapshot] : @"Monitoring Paused";
    self.captionLabel.stringValue = @"";
    self.captionLabel.hidden = YES;
    self.captionHeightConstraint.constant = 0;
    self.runtimeLabel.stringValue = [self runtimeTitleForSnapshot:snapshot];
    self.runtimeValueLabel.stringValue = [self runtimeTextForSnapshot:snapshot];
    self.timeToFullValueLabel.stringValue = [self timeToFullTextForSnapshot:snapshot];
    self.chargerValueLabel.stringValue = [self detailTextForSnapshot:snapshot];

    BOOL chargingPulse = snapshot.charging;
    BOOL brightPhase = (((NSInteger)(CFAbsoluteTimeGetCurrent() * 2.5)) % 2 == 0);
    self.brandLabel.textColor = chargingPulse ? (brightPhase ? WNColor(0.11, 0.72, 0.24, 1.0) : WNColor(0.22, 0.60, 0.24, 1.0)) : WNColor(0.31, 0.25, 0.19, 1.0);
    self.brandLabel.layer.shadowColor = chargingPulse ? WNColor(0.26, 0.94, 0.42, 1.0).CGColor : NSColor.clearColor.CGColor;
    self.brandLabel.layer.shadowOpacity = chargingPulse ? (brightPhase ? 0.95 : 0.45) : 0.0;
    self.brandLabel.layer.shadowRadius = chargingPulse ? (brightPhase ? 8.0 : 4.0) : 0.0;
    self.brandLabel.layer.shadowOffset = CGSizeZero;

    [self.monitoringToggle setOn:monitoringEnabled animated:NO];
}

@end

@interface NotePopoverController : NSViewController
@property(nonatomic, strong) PowerNoteView *noteView;
@property(nonatomic, copy) void (^monitoringChanged)(BOOL enabled);
- (void)applySnapshot:(PowerSnapshot *)snapshot monitoringEnabled:(BOOL)monitoringEnabled samples:(NSArray<NSNumber *> *)samples;
@end

@implementation NotePopoverController

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 284)];
    container.wantsLayer = YES;
    container.layer.backgroundColor = WNColor(0.945, 0.952, 0.962, 1.0).CGColor;
    self.view = container;

    self.noteView = [[PowerNoteView alloc] initWithFrame:NSZeroRect];
    self.noteView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    self.noteView.monitoringChanged = ^(BOOL enabled) {
        if (weakSelf.monitoringChanged != nil) {
            weakSelf.monitoringChanged(enabled);
        }
    };
    [container addSubview:self.noteView];

    [NSLayoutConstraint activateConstraints:@[
        [self.noteView.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [self.noteView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [self.noteView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],
        [self.noteView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12],
    ]];
}

- (void)applySnapshot:(PowerSnapshot *)snapshot monitoringEnabled:(BOOL)monitoringEnabled samples:(NSArray<NSNumber *> *)samples {
    [self.noteView applySnapshot:snapshot monitoringEnabled:monitoringEnabled samples:samples];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, strong) NotePopoverController *popoverController;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSTimer *popoverAutoCloseTimer;
@property(nonatomic, strong) PowerSnapshot *latestSnapshot;
@property(nonatomic, strong) PowerSnapshot *lastLoggedSnapshot;
@property(nonatomic, strong) NSDate *lastSnapshotLogDate;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *recentInputSamples;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *recentUsageSamples;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *chargerNames;
@property(nonatomic, copy) NSString *lastPromptedFingerprint;
@property(nonatomic) BOOL monitoringEnabled;
@end

@implementation AppDelegate

- (NSMutableDictionary<NSString *,NSString *> *)loadChargerNames {
    NSString *filePath = WNChargerNamesFilePath();
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:filePath];
    if ([saved isKindOfClass:[NSDictionary class]]) {
        return [saved mutableCopy];
    }

    return [NSMutableDictionary dictionary];
}

- (void)saveChargerNames {
    NSString *directoryPath = WNAppSupportDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [self.chargerNames writeToFile:WNChargerNamesFilePath() atomically:YES];
}

- (void)applyChargerIdentityToSnapshot:(PowerSnapshot *)snapshot {
    if (snapshot.chargerFingerprint.length == 0) {
        snapshot.chargerDisplayName = snapshot.onAC ? (snapshot.chargerSuggestedName ?: @"Charger Setup") : @"Battery Power";
        return;
    }

    NSString *savedName = self.chargerNames[snapshot.chargerFingerprint];
    snapshot.chargerDisplayName = savedName.length > 0 ? savedName : (snapshot.chargerSuggestedName ?: @"Unnamed Charger");
}

- (void)maybePromptToNameChargerForSnapshot:(PowerSnapshot *)snapshot {
    if (!snapshot.onAC || snapshot.chargerFingerprint.length == 0) {
        self.lastPromptedFingerprint = nil;
        return;
    }

    if (self.chargerNames[snapshot.chargerFingerprint].length > 0) {
        return;
    }

    if ([self.lastPromptedFingerprint isEqualToString:snapshot.chargerFingerprint]) {
        return;
    }

    self.lastPromptedFingerprint = snapshot.chargerFingerprint;

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Name This Charger Setup?";
    alert.informativeText = @"Watti found a charger setup it hasn’t seen before. Save a name for it and reuse it automatically next time.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Skip"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.stringValue = snapshot.chargerSuggestedName ?: @"";
    alert.accessoryView = field;

    NSModalResponse response = [alert runModal];
    NSString *proposedName = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (response == NSAlertFirstButtonReturn && proposedName.length > 0) {
        self.chargerNames[snapshot.chargerFingerprint] = proposedName;
        snapshot.chargerDisplayName = proposedName;
        [self saveChargerNames];
        [self.popoverController applySnapshot:snapshot monitoringEnabled:self.monitoringEnabled samples:self.recentInputSamples];
        [self updateStatusItemWithSnapshot:snapshot];
        WNLogLine(@"INFO", [NSString stringWithFormat:@"named charger fingerprint=%@ name=%@", snapshot.chargerFingerprint, proposedName]);
    }
}

- (void)restartPopoverAutoCloseTimer {
    [self.popoverAutoCloseTimer invalidate];
    self.popoverAutoCloseTimer = nil;

    if (!self.popover.isShown) {
        return;
    }

    self.popoverAutoCloseTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                                  target:self
                                                                selector:@selector(closePopoverAfterDelay:)
                                                                userInfo:nil
                                                                 repeats:NO];
}

- (void)closePopoverAfterDelay:(NSTimer *)timer {
    (void)timer;
    if (self.popover.isShown) {
        [self.popover close];
        WNLogLine(@"INFO", @"popover auto-closed after 30s");
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    WNLogLine(@"INFO", @"applicationDidFinishLaunching");
    [self installSystemObservers];
    [self buildStatusItem];
    [self buildPopover];
    self.recentInputSamples = [NSMutableArray array];
    self.recentUsageSamples = [NSMutableArray array];
    self.chargerNames = [self loadChargerNames];
    self.monitoringEnabled = YES;
    [self refreshSnapshotWithReason:@"launch"];
    [self configureMonitoringTimer];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.timer invalidate];
    WNLogLine(@"INFO", @"applicationWillTerminate");
}

- (void)installSystemObservers {
    NSNotificationCenter *workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter addObserver:self selector:@selector(systemWillSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(systemDidWake:) name:NSWorkspaceDidWakeNotification object:nil];
}

- (void)buildStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.image = nil;
    button.title = @"";
    button.target = self;
    button.action = @selector(statusItemPressed:);
    [button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    button.toolTip = @"Watti";
    WNLogLine(@"INFO", @"status item created");
}

- (void)buildPopover {
    self.popoverController = [NotePopoverController new];
    __weak typeof(self) weakSelf = self;
    self.popoverController.monitoringChanged = ^(BOOL enabled) {
        [weakSelf setMonitoringEnabled:enabled reason:@"switch"];
    };
    self.popover = [NSPopover new];
    self.popover.animates = YES;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.delegate = self;
    self.popover.contentViewController = self.popoverController;
    self.popover.contentSize = NSMakeSize(320, 284);
    WNLogLine(@"INFO", @"popover created");
}

- (void)refreshSnapshotTimer:(NSTimer *)timer {
    (void)timer;
    [self refreshSnapshotWithReason:@"timer"];
}

- (void)configureMonitoringTimer {
    [self.timer invalidate];
    self.timer = nil;

    if (!self.monitoringEnabled) {
        WNLogLine(@"INFO", @"refresh timer paused");
        return;
    }

    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                  target:self
                                                selector:@selector(refreshSnapshotTimer:)
                                                userInfo:nil
                                                 repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    WNLogLine(@"INFO", @"refresh timer started interval=2.0s");
}

- (void)setMonitoringEnabled:(BOOL)enabled reason:(NSString *)reason {
    if (_monitoringEnabled == enabled) {
        [self.popoverController applySnapshot:self.latestSnapshot ?: WNSnapshot() monitoringEnabled:self.monitoringEnabled samples:self.recentInputSamples];
        [self updateStatusItemWithSnapshot:self.latestSnapshot ?: WNSnapshot()];
        return;
    }

    _monitoringEnabled = enabled;
    WNLogLine(@"INFO", [NSString stringWithFormat:@"monitoring %@ via %@", enabled ? @"enabled" : @"disabled", reason]);
    [self configureMonitoringTimer];

    if (enabled) {
        [self refreshSnapshotWithReason:@"monitoring_enabled"];
    } else {
        [self.popoverController applySnapshot:self.latestSnapshot ?: WNSnapshot() monitoringEnabled:self.monitoringEnabled samples:self.recentInputSamples];
        [self updateStatusItemWithSnapshot:self.latestSnapshot ?: WNSnapshot()];
    }
}

- (void)refreshSnapshotWithReason:(NSString *)reason {
    if (!self.monitoringEnabled && [reason isEqualToString:@"timer"]) {
        return;
    }

    PowerSnapshot *snapshot = WNSnapshot();
    [self applyChargerIdentityToSnapshot:snapshot];
    self.latestSnapshot = snapshot;
    [self recordInputSample:snapshot];
    [self recordUsageSample:snapshot];
    [self applyForecastToSnapshot:snapshot];
    [self.popoverController applySnapshot:snapshot monitoringEnabled:self.monitoringEnabled samples:self.recentInputSamples];
    [self updateStatusItemWithSnapshot:snapshot];
    [self maybeLogSnapshot:snapshot reason:reason];
    [self maybePromptToNameChargerForSnapshot:snapshot];
}

- (void)recordInputSample:(PowerSnapshot *)snapshot {
    if (!self.monitoringEnabled) {
        return;
    }

    NSNumber *sample = @(snapshot.inputWatts > 0 ? snapshot.inputWatts : snapshot.watts);
    [self.recentInputSamples addObject:sample];

    while (self.recentInputSamples.count > 300) {
        [self.recentInputSamples removeObjectAtIndex:0];
    }
}

- (double)usageSampleForSnapshot:(PowerSnapshot *)snapshot {
    if (snapshot.systemLoadWatts > 0) {
        return snapshot.systemLoadWatts;
    }

    if (!snapshot.onAC && snapshot.watts > 0) {
        return snapshot.watts;
    }

    if (snapshot.inputWatts > 0) {
        return snapshot.inputWatts;
    }

    return snapshot.watts;
}

- (void)recordUsageSample:(PowerSnapshot *)snapshot {
    if (!self.monitoringEnabled) {
        return;
    }

    double sampleValue = [self usageSampleForSnapshot:snapshot];
    if (sampleValue <= 0) {
        return;
    }

    [self.recentUsageSamples addObject:@(sampleValue)];

    while (self.recentUsageSamples.count > 300) {
        [self.recentUsageSamples removeObjectAtIndex:0];
    }
}

- (double)averageValueForSamples:(NSArray<NSNumber *> *)samples {
    if (samples.count == 0) {
        return 0;
    }

    double total = 0;
    NSUInteger count = 0;
    for (NSNumber *sample in samples) {
        double value = sample.doubleValue;
        if (value <= 0) {
            continue;
        }
        total += value;
        count += 1;
    }

    return count > 0 ? (total / (double)count) : 0;
}

- (void)applyForecastToSnapshot:(PowerSnapshot *)snapshot {
    snapshot.averageUsageWatts = [self averageValueForSamples:self.recentUsageSamples];

    if (snapshot.remainingWattHours > 0 && snapshot.averageUsageWatts > 0) {
        snapshot.predictedMinutesRemaining = (snapshot.remainingWattHours / snapshot.averageUsageWatts) * 60.0;
    } else {
        snapshot.predictedMinutesRemaining = 0;
    }
}

- (void)updateStatusItemWithSnapshot:(PowerSnapshot *)snapshot {
    NSStatusBarButton *button = self.statusItem.button;
    if (button == nil) {
        return;
    }

    NSString *title = nil;
    if (!self.monitoringEnabled) {
        title = @"off";
    } else {
        double displayWatts = snapshot.onAC ? fabs(snapshot.watts) : -fabs(snapshot.watts);
        title = [NSString stringWithFormat:@"%+.1fW", displayWatts];
    }

    button.attributedTitle = WNStatusItemTitle(self.monitoringEnabled && snapshot.onAC, title);
    button.toolTip = self.monitoringEnabled ? [NSString stringWithFormat:@"%@\n%@", snapshot.subtitle, snapshot.caption] : @"Monitoring off";
}

- (void)maybeLogSnapshot:(PowerSnapshot *)snapshot reason:(NSString *)reason {
    NSDate *now = [NSDate date];
    BOOL shouldLog = (self.lastLoggedSnapshot == nil);

    if (!shouldLog) {
        shouldLog = ![self.lastLoggedSnapshot.source isEqualToString:snapshot.source];
    }

    if (!shouldLog) {
        shouldLog = self.lastLoggedSnapshot.onAC != snapshot.onAC;
    }

    if (!shouldLog) {
        shouldLog = fabs(self.lastLoggedSnapshot.watts - snapshot.watts) >= 3.0;
    }

    if (!shouldLog) {
        NSTimeInterval sinceLast = self.lastSnapshotLogDate ? [now timeIntervalSinceDate:self.lastSnapshotLogDate] : DBL_MAX;
        shouldLog = sinceLast >= 60.0;
    }

    if (!shouldLog && ![reason isEqualToString:@"timer"]) {
        shouldLog = YES;
    }

    if (!shouldLog) {
        return;
    }

    WNLogLine(@"POWER", [NSString stringWithFormat:@"%@ watts=%.1f input=%.1f system=%.1f avg=%.1f runtime=%.0fm battery=%.0f%% health=%.0f%% rated=%.1f negotiated=%.1f charger=%@ source=%@ onAC=%@ powerState=%@ externalHint=%@ subtitle=%@ caption=%@",
                                                   reason,
                                                   snapshot.watts,
                                                   snapshot.inputWatts,
                                                   snapshot.systemLoadWatts,
                                                   snapshot.averageUsageWatts,
                                                   snapshot.predictedMinutesRemaining,
                                                   snapshot.batteryPercent,
                                                   snapshot.batteryHealthPercent,
                                                   snapshot.adapterRatedWatts,
                                                   snapshot.negotiatedWatts,
                                                   snapshot.chargerDisplayName ?: @"",
                                                   snapshot.source,
                                                   snapshot.onAC ? @"yes" : @"no",
                                                   snapshot.powerSourceState,
                                                   snapshot.externalConnectedReported ? @"yes" : @"no",
                                                   snapshot.subtitle,
                                                   snapshot.caption]);

    self.lastLoggedSnapshot = snapshot;
    self.lastSnapshotLogDate = now;
}

- (void)statusItemPressed:(id)sender {
    (void)sender;

    NSEvent *event = NSApp.currentEvent;
    BOOL wantsMenu = (event.type == NSEventTypeRightMouseUp) || ((event.modifierFlags & NSEventModifierFlagControl) != 0);

    if (wantsMenu) {
        [self showStatusMenu];
        return;
    }

    [self togglePopover:nil];
}

- (void)showStatusMenu {
    [self.popover close];

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Watti"];
    NSString *summaryTitle = self.latestSnapshot ? [NSString stringWithFormat:@"%.1fW  %@", self.latestSnapshot.watts, self.latestSnapshot.subtitle] : @"Watti";
    NSMenuItem *summaryItem = [[NSMenuItem alloc] initWithTitle:summaryTitle action:nil keyEquivalent:@""];
    summaryItem.enabled = NO;
    [menu addItem:summaryItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *toggleItem = [[NSMenuItem alloc] initWithTitle:(self.popover.isShown ? @"Hide Panel" : @"Show Panel")
                                                        action:@selector(togglePopoverFromMenu:)
                                                 keyEquivalent:@""];
    toggleItem.target = self;
    [menu addItem:toggleItem];

    NSMenuItem *monitoringItem = [[NSMenuItem alloc] initWithTitle:(self.monitoringEnabled ? @"Pause Monitoring" : @"Resume Monitoring")
                                                            action:@selector(toggleMonitoringFromMenu:)
                                                     keyEquivalent:@""];
    monitoringItem.target = self;
    [menu addItem:monitoringItem];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh Now"
                                                         action:@selector(refreshNow:)
                                                  keyEquivalent:@"r"];
    refreshItem.target = self;
    [menu addItem:refreshItem];

    NSMenuItem *logsItem = [[NSMenuItem alloc] initWithTitle:@"Open Logs"
                                                      action:@selector(openLogs:)
                                               keyEquivalent:@"l"];
    logsItem.target = self;
    [menu addItem:logsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Watti"
                                                      action:@selector(quitApp:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

- (void)togglePopoverFromMenu:(id)sender {
    (void)sender;
    [self togglePopover:nil];
}

- (void)toggleMonitoringFromMenu:(id)sender {
    (void)sender;
    [self setMonitoringEnabled:!self.monitoringEnabled reason:@"menu"];
}

- (void)togglePopover:(id)sender {
    (void)sender;

    if (self.popover.isShown) {
        [self.popover close];
        return;
    }

    NSStatusBarButton *button = self.statusItem.button;
    if (button == nil) {
        return;
    }

    [self.popover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMinY];
    [self restartPopoverAutoCloseTimer];
    WNLogLine(@"INFO", @"popover opened");
}

- (void)popoverDidClose:(NSNotification *)notification {
    (void)notification;
    [self.popoverAutoCloseTimer invalidate];
    self.popoverAutoCloseTimer = nil;
    WNLogLine(@"INFO", @"popover closed");
}

- (void)refreshNow:(id)sender {
    (void)sender;
    [self refreshSnapshotWithReason:@"manual_refresh"];
}

- (void)openLogs:(id)sender {
    (void)sender;
    NSURL *logURL = [NSURL fileURLWithPath:WNLogFilePath()];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ logURL ]];
    WNLogLine(@"INFO", @"openLogs requested");
}

- (void)quitApp:(id)sender {
    (void)sender;
    WNLogLine(@"INFO", @"quit requested");
    [NSApp terminate:nil];
}

- (void)systemWillSleep:(NSNotification *)notification {
    (void)notification;
    WNLogLine(@"INFO", @"system will sleep");
}

- (void)systemDidWake:(NSNotification *)notification {
    (void)notification;
    WNLogLine(@"INFO", @"system did wake");
    if (self.monitoringEnabled) {
        [self refreshSnapshotWithReason:@"wake"];
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        WNInstallMonitoring();

        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        application.activationPolicy = NSApplicationActivationPolicyAccessory;
        return NSApplicationMain(argc, argv);
    }
}
