#ifndef PRIVATE_APIS_H
#define PRIVATE_APIS_H

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Touch Bar System Modal (DFRFoundation)
void TBConfigureSystemModal(BOOL showCloseBox);
void TBPresentSystemModalTouchBar(NSTouchBar *touchBar, NSString *identifier);
void TBDismissSystemModalTouchBar(NSTouchBar *touchBar);
void TBMinimizeSystemModalTouchBar(NSTouchBar *touchBar);

// MARK: - Display Brightness (DisplayServices)
BOOL TBGetDisplayBrightness(float *outBrightness);
BOOL TBSetDisplayBrightness(float brightness);

// MARK: - Keyboard Backlight (CoreBrightness)
float TBGetKeyboardBrightness(void);
void TBSetKeyboardBrightness(float brightness);
void TBStepKeyboardBrightness(float delta);

// MARK: - Media & System Actions
void TBPostMediaKey(int32_t keyType); // NX_KEYTYPE_PLAY=16, NEXT/FAST=19, PREVIOUS/REWIND=20
void TBPostAuxKey(int32_t keyType, BOOL fineStep); // SOUND_UP=0, SOUND_DOWN=1, BRIGHTNESS_UP=2, BRIGHTNESS_DOWN=3, MUTE=7, ILLUM_UP=21, ILLUM_DOWN=22
BOOL TBMediaRemoteSkip(double deltaSeconds);
void TBPostKeyCode(uint16_t keyCode);
BOOL TBIsAccessibilityTrusted(BOOL prompt);
void TBLockScreenImmediate(void);
void TBTriggerSiri(void);
void TBTriggerScreenshotUI(void);

// MARK: - Native macOS On-Screen Display (OSD.framework)
void TBShowVolumeOSD(float volume, BOOL muted);
void TBShowBrightnessOSD(float brightness);
void TBShowKeyboardBrightnessOSD(float brightness);

// MARK: - Apple Silicon Thermal (IOHIDEventSystemClient)
typedef struct {
    double avgTempC;
    double peakTempC;
} TBThermalInfo;

/// Single-pass cached M2 SoC die temperature read (avg & peak in Celsius, negative if unavailable)
TBThermalInfo TBReadThermalInfo(void);

// MARK: - Lock-Free ARM64 Atomics for Audio Ring Buffer
void TBAtomicStoreInt32(int32_t *ptr, int32_t value);
int32_t TBAtomicLoadInt32(const int32_t *ptr);

// MARK: - AppleSMC Fan Telemetry
typedef struct {
    BOOL available;
    double currentRPM;
    double minRPM;
    double maxRPM;
    int32_t fanCount;
} TBFanInfo;

TBFanInfo TBReadFanInfo(void);

// MARK: - AppleSMC Real-Time 1Hz Power Telemetry (PSTR / PDTR / PPBR)
typedef struct {
    BOOL hasSystemTotal;
    double systemTotalWatts;
    BOOL hasDCIn;
    double dcInWatts;
    BOOL hasBatteryPower;
    double batteryPowerWatts;
} TBSMCPowerInfo;

TBSMCPowerInfo TBReadSMCPowerInfo(void);

NS_ASSUME_NONNULL_END

#endif /* PRIVATE_APIS_H */
