#import "PrivateAPIs.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

// ============================================================================
// MARK: - DFRFoundation (System-Modal Touch Bar)
// ============================================================================

typedef void (*DFRSystemModalShowsCloseBoxFn)(BOOL);

static void *DFRHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    });
    return handle;
}

void TBConfigureSystemModal(BOOL showCloseBox) {
    void *h = DFRHandle();
    if (!h) return;
    DFRSystemModalShowsCloseBoxFn fn = (DFRSystemModalShowsCloseBoxFn)dlsym(h, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    if (fn) {
        fn(showCloseBox);
    }
}

void TBPresentSystemModalTouchBar(NSTouchBar *touchBar, NSString *identifier) {
    // Ensure DFRFoundation is loaded
    DFRHandle();
    SEL selPlacement = NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:");
    SEL selBasic = NSSelectorFromString(@"presentSystemModalTouchBar:systemTrayItemIdentifier:");
    if ([NSTouchBar respondsToSelector:selPlacement]) {
        ((void (*)(id, SEL, id, NSInteger, id))objc_msgSend)(
            [NSTouchBar class], selPlacement, touchBar, 1, identifier
        );
    } else if ([NSTouchBar respondsToSelector:selBasic]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            [NSTouchBar class], selBasic, touchBar, identifier
        );
    }
}

void TBDismissSystemModalTouchBar(NSTouchBar *touchBar) {
    SEL sel = NSSelectorFromString(@"dismissSystemModalTouchBar:");
    if ([NSTouchBar respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBar class], sel, touchBar);
    }
}

void TBMinimizeSystemModalTouchBar(NSTouchBar *touchBar) {
    SEL sel = NSSelectorFromString(@"minimizeSystemModalTouchBar:");
    if ([NSTouchBar respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBar class], sel, touchBar);
    }
}

// ============================================================================
// MARK: - Display Brightness (DisplayServices)
// ============================================================================

typedef int (*DSGetBrightnessFn)(uint32_t display, float *brightness);
typedef int (*DSSetBrightnessFn)(uint32_t display, float brightness);

static void *DSHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
    });
    return handle;
}

static CGDirectDisplayID TBFindBuiltinDisplay(void) {
    uint32_t count = 0;
    CGGetOnlineDisplayList(0, NULL, &count);
    if (count > 0 && count <= 16) {
        CGDirectDisplayID displays[16];
        if (CGGetOnlineDisplayList(count, displays, &count) == kCGErrorSuccess) {
            for (uint32_t i = 0; i < count; i++) {
                if (CGDisplayIsBuiltin(displays[i])) {
                    return displays[i];
                }
            }
        }
    }
    return CGMainDisplayID();
}

BOOL TBGetDisplayBrightness(float *outBrightness) {
    void *h = DSHandle();
    if (!h || !outBrightness) return NO;
    DSGetBrightnessFn fn = (DSGetBrightnessFn)dlsym(h, "DisplayServicesGetBrightness");
    if (!fn) return NO;
    CGDirectDisplayID disp = TBFindBuiltinDisplay();
    return fn(disp, outBrightness) == 0;
}

BOOL TBSetDisplayBrightness(float brightness) {
    void *h = DSHandle();
    if (!h) return NO;
    DSSetBrightnessFn fn = (DSSetBrightnessFn)dlsym(h, "DisplayServicesSetBrightness");
    if (!fn) return NO;
    float clamped = fmaxf(0.0f, fminf(1.0f, brightness));
    CGDirectDisplayID disp = TBFindBuiltinDisplay();
    return fn(disp, clamped) == 0;
}

// ============================================================================
// MARK: - Keyboard Backlight (CoreBrightness)
// ============================================================================

static id TBKeyboardClient(void) {
    static id client = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
        Class cls = NSClassFromString(@"KeyboardBrightnessClient");
        if (cls) {
            client = [[cls alloc] init];
        }
    });
    return client;
}

float TBGetKeyboardBrightness(void) {
    id client = TBKeyboardClient();
    if (!client) return 0.0f;
    SEL sel = NSSelectorFromString(@"brightnessForKeyboard:");
    if ([client respondsToSelector:sel]) {
        return ((float (*)(id, SEL, uint64_t))objc_msgSend)(client, sel, 1);
    }
    return 0.0f;
}

void TBSetKeyboardBrightness(float brightness) {
    id client = TBKeyboardClient();
    if (!client) return;
    float clamped = fmaxf(0.0f, fminf(1.0f, brightness));
    SEL sel = NSSelectorFromString(@"setBrightness:forKeyboard:");
    if ([client respondsToSelector:sel]) {
        ((BOOL (*)(id, SEL, float, uint64_t))objc_msgSend)(client, sel, clamped, 1);
    }
}

void TBStepKeyboardBrightness(float delta) {
    float cur = TBGetKeyboardBrightness();
    TBSetKeyboardBrightness(cur + delta);
}

// ============================================================================
// MARK: - Media Keys & System Actions
// ============================================================================

void TBPostMediaKey(int32_t keyType) {
    TBPostAuxKey(keyType, NO);
}

void TBPostAuxKey(int32_t keyType, BOOL fineStep) {
    void (^post)(BOOL) = ^(BOOL down) {
        NSEventModifierFlags mods = (NSEventModifierFlags)(down ? 0xa00 : 0xb00);
        if (fineStep) {
            mods |= (NSEventModifierFlagOption | NSEventModifierFlagShift);
        }
        NSInteger data1 = ((NSInteger)keyType << 16) | ((down ? 0xa : 0xb) << 8);
        NSEvent *ev = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                         location:NSZeroPoint
                                    modifierFlags:mods
                                        timestamp:0
                                     windowNumber:0
                                          context:nil
                                          subtype:8
                                            data1:data1
                                            data2:-1];
        CGEventRef cgEv = [ev CGEvent];
        if (cgEv) {
            if (fineStep) {
                CGEventSetFlags(cgEv, kCGEventFlagMaskAlternate | kCGEventFlagMaskShift);
            }
            CGEventPost(kCGHIDEventTap, cgEv);
        }
    };
    post(YES);
    post(NO);
}

BOOL TBMediaRemoteSkip(double deltaSeconds) {
    typedef BOOL (*MRSendCommandFn)(uint32_t command, CFDictionaryRef options);
    static MRSendCommandFn sendCmd = NULL;
    static CFStringRef skipIntervalKey = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (h) {
            sendCmd = (MRSendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
            CFStringRef *keyPtr = (CFStringRef *)dlsym(h, "kMRMediaRemoteOptionSkipInterval");
            if (keyPtr) {
                skipIntervalKey = *keyPtr;
            }
        }
    });
    if (!sendCmd) return NO;
    // kMRSkipForward = 17, kMRSkipBackward = 18
    uint32_t cmd = (deltaSeconds >= 0) ? 17 : 18;
    NSString *key = skipIntervalKey ? (__bridge NSString *)skipIntervalKey : @"kMRMediaRemoteOptionSkipInterval";
    NSDictionary *opts = @{ key: @(fabs(deltaSeconds)) };
    return sendCmd(cmd, (__bridge CFDictionaryRef)opts);
}

void TBPostKeyCode(uint16_t keyCode) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keyCode, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keyCode, false);
    if (down) {
        CGEventPost(kCGHIDEventTap, down);
        CFRelease(down);
    }
    if (up) {
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(up);
    }
}

BOOL TBIsAccessibilityTrusted(BOOL prompt) {
    if (prompt) {
        NSDictionary *opts = @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES };
        return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    }
    return AXIsProcessTrusted();
}

void TBLockScreenImmediate(void) {
    static void (*lockFn)(void) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY);
        if (h) {
            lockFn = (void (*)(void))dlsym(h, "SACLockScreenImmediate");
        }
    });
    if (lockFn) {
        lockFn();
    }
}

void TBTriggerSiri(void) {
    NSURL *siriURL = [NSURL fileURLWithPath:@"/System/Applications/Siri.app"];
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:siriURL
                                          configuration:[NSWorkspaceOpenConfiguration configuration]
                                      completionHandler:nil];
}

void TBTriggerScreenshotUI(void) {
    NSURL *url = [NSURL fileURLWithPath:@"/System/Applications/Utilities/Screenshot.app"];
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                          configuration:[NSWorkspaceOpenConfiguration configuration]
                                      completionHandler:nil];
}

// ============================================================================
// MARK: - Native macOS On-Screen Display (OSD.framework)
// ============================================================================

typedef void (*OSDShowImageFn)(id, SEL, int64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, BOOL);

static id TBOSDSharedManager(void) {
    static id manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY);
        Class cls = NSClassFromString(@"OSDManager");
        SEL sharedSel = NSSelectorFromString(@"sharedManager");
        if (cls && [cls respondsToSelector:sharedSel]) {
            manager = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
        }
    });
    return manager;
}

static void TBShowOSDInternal(int64_t imageID, float value01, BOOL forceShow) {
    id mgr = TBOSDSharedManager();
    if (!mgr) return;

    const uint32_t totalChiclets = 64;
    float clamped = fmaxf(0.0f, fminf(1.0f, value01));
    uint32_t filled = (uint32_t)lroundf(clamped * (float)totalChiclets);

    // Avoid flooding OSDUIHelper XPC when sliding across identical sub-steps
    static int64_t lastImage = -1;
    static uint32_t lastFilled = UINT32_MAX;
    static CFAbsoluteTime lastTime = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!forceShow && imageID == lastImage && filled == lastFilled && (now - lastTime) < 0.25) {
        return;
    }
    lastImage = imageID;
    lastFilled = filled;
    lastTime = now;

    SEL sel = NSSelectorFromString(@"showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:");
    if ([mgr respondsToSelector:sel]) {
        uint32_t displayID = (uint32_t)CGMainDisplayID();
        ((OSDShowImageFn)objc_msgSend)(mgr, sel, imageID, displayID, 0x1f4, 1000, filled, totalChiclets, NO);
    }
}

void TBShowVolumeOSD(float volume, BOOL muted) {
    // 3 = Volume speaker, 4 = Mute speaker slash
    if (muted || volume <= 0.004f) {
        TBShowOSDInternal(4, 0.0f, YES);
    } else {
        TBShowOSDInternal(3, volume, NO);
    }
}

void TBShowBrightnessOSD(float brightness) {
    // 1 = Display Brightness sun
    TBShowOSDInternal(1, brightness, NO);
}

void TBShowKeyboardBrightnessOSD(float brightness) {
    // 11 = Keyboard Brightness, 12 = Keyboard Brightness Off
    if (brightness <= 0.004f) {
        TBShowOSDInternal(12, 0.0f, YES);
    } else {
        TBShowOSDInternal(11, brightness, NO);
    }
}

// ============================================================================
// MARK: - Apple Silicon Thermal Sensors (IOHIDEventSystemClient)
// ============================================================================

typedef CFTypeRef TBIOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern TBIOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(TBIOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventFieldTemperatureLevel (kIOHIDEventTypeTemperature << 16)

static void TBReadSoCTempsInternal(double *outAvg, double *outPeak) {
    *outAvg = -1.0;
    *outPeak = -1.0;

    static IOHIDEventSystemClientRef client = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (client) {
            NSDictionary *matching = @{
                @"PrimaryUsagePage": @(0xff00),
                @"PrimaryUsage": @(5)
            };
            IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);
        }
    });
    if (!client) return;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return;

    double sum = 0.0;
    int count = 0;
    double peak = 0.0;

    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef name = (CFStringRef)IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (!name) continue;
        NSString *nsName = (__bridge_transfer NSString *)name;

        // Apple Silicon M2 SoC die sensors: "PMU tdie*", "eACC MTR Temp*", "pACC MTR Temp*", "SOC MTR Temp*"
        BOOL isSoC = ([nsName hasPrefix:@"PMU tdie"] ||
                      [nsName hasPrefix:@"pACC MTR Temp"] ||
                      [nsName hasPrefix:@"eACC MTR Temp"] ||
                      [nsName hasPrefix:@"SOC MTR Temp"]);
        if (!isSoC) continue;

        TBIOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (ev) {
            double temp = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldTemperatureLevel);
            CFRelease(ev);
            if (temp > 10.0 && temp < 125.0) {
                sum += temp;
                count++;
                if (temp > peak) peak = temp;
            }
        }
    }
    CFRelease(services);

    if (count > 0) {
        *outAvg = sum / (double)count;
        *outPeak = peak;
    }
}

double TBReadSoCTemperature(void) {
    double avg = -1.0, peak = -1.0;
    TBReadSoCTempsInternal(&avg, &peak);
    return avg;
}

double TBReadSoCPeakTemperature(void) {
    double avg = -1.0, peak = -1.0;
    TBReadSoCTempsInternal(&avg, &peak);
    return peak;
}

// ============================================================================
// MARK: - AppleSMC Fan Telemetry
// ============================================================================

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

static uint32_t FourCC(const char *str) {
    return ((uint32_t)(uint8_t)str[0] << 24) |
           ((uint32_t)(uint8_t)str[1] << 16) |
           ((uint32_t)(uint8_t)str[2] << 8)  |
           ((uint32_t)(uint8_t)str[3]);
}

static io_connect_t TBSMCConnection(void) {
    static io_connect_t conn = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (svc != 0) {
            if (IOServiceOpen(svc, mach_task_self_, 0, &conn) != KERN_SUCCESS) {
                conn = 0;
            }
            IOObjectRelease(svc);
        }
    });
    return conn;
}

static BOOL TBSMCReadKey(io_connect_t conn, const char *keyStr, SMCKeyData_t *outData) {
    SMCKeyData_t input;
    memset(&input, 0, sizeof(input));
    memset(outData, 0, sizeof(*outData));

    input.key = FourCC(keyStr);
    input.data8 = SMC_CMD_READ_KEYINFO;

    size_t outSize = sizeof(SMCKeyData_t);
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &input, sizeof(input), outData, &outSize);
    if (kr != KERN_SUCCESS || outData->keyInfo.dataSize == 0) {
        return NO;
    }

    input.keyInfo.dataSize = outData->keyInfo.dataSize;
    input.data8 = SMC_CMD_READ_BYTES;
    uint32_t dataType = outData->keyInfo.dataType;

    memset(outData, 0, sizeof(*outData));
    outSize = sizeof(SMCKeyData_t);
    kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &input, sizeof(input), outData, &outSize);
    outData->keyInfo.dataSize = input.keyInfo.dataSize;
    outData->keyInfo.dataType = dataType;
    return kr == KERN_SUCCESS;
}

static double TBSMCDecodeNumber(const SMCKeyData_t *d) {
    uint32_t dt = d->keyInfo.dataType;
    // 'flt ' (Apple Silicon SMC fan values are IEEE 754 float32 little-endian!)
    if (dt == FourCC("flt ") && d->keyInfo.dataSize == 4) {
        float val = 0;
        memcpy(&val, d->bytes, 4);
        return (double)val;
    }
    // 'fpe2' (legacy big-endian fixed-point 14.2)
    if (dt == FourCC("fpe2") && d->keyInfo.dataSize == 2) {
        uint16_t raw = ((uint16_t)d->bytes[0] << 8) | d->bytes[1];
        return (double)raw / 4.0;
    }
    // 'ui8 '
    if (dt == FourCC("ui8 ") && d->keyInfo.dataSize == 1) {
        return (double)d->bytes[0];
    }
    return -1.0;
}

TBFanInfo TBReadFanInfo(void) {
    TBFanInfo info;
    memset(&info, 0, sizeof(info));
    io_connect_t conn = TBSMCConnection();
    if (conn == 0) return info;

    SMCKeyData_t d;
    if (TBSMCReadKey(conn, "FNum", &d)) {
        info.fanCount = (int32_t)TBSMCDecodeNumber(&d);
    }
    if (TBSMCReadKey(conn, "F0Ac", &d)) {
        double rpm = TBSMCDecodeNumber(&d);
        if (rpm >= 0.0) {
            info.available = YES;
            info.currentRPM = rpm;
        }
    }
    if (TBSMCReadKey(conn, "F0Mn", &d)) {
        info.minRPM = TBSMCDecodeNumber(&d);
    }
    if (TBSMCReadKey(conn, "F0Mx", &d)) {
        info.maxRPM = TBSMCDecodeNumber(&d);
    }
    return info;
}
