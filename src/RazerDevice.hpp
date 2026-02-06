#ifndef RAZER_DEVICE_HPP
#define RAZER_DEVICE_HPP

#include <cstdint>
#include <string>
#include <mutex>
#include <atomic>
#include <algorithm>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>

// Callback type for device change events
typedef void (*DeviceCallback)(void* context);

// Adaptive USB timing - adjusts wait time based on success/failure
class USBTimer {
private:
    static constexpr int BASE_DELAY_US = 100000;  // 100ms base delay
    int consecutiveFailures_;

public:
    USBTimer() : consecutiveFailures_(0) {}

    void waitForResponse() {
        // Increase delay for each failure, max 500ms
        int delay = BASE_DELAY_US * (1 + consecutiveFailures_ / 3);
        delay = std::min(delay, 500000);  // Cap at 500ms
        usleep(delay);
    }

    void onSuccess() {
        consecutiveFailures_ = 0;
    }

    void onFailure() {
        consecutiveFailures_++;
    }

    void reset() {
        consecutiveFailures_ = 0;
    }
};

// Supported Razer wireless mouse device information
struct RazerSupportedDevice {
    uint16_t wirelessPid;
    uint16_t wiredPid;
    const char* name;
};

class RazerDevice {
public:
    RazerDevice();
    ~RazerDevice();
    
    bool connect();
    void disconnect();
    bool queryBattery(uint8_t& batteryPercent);
    bool queryChargingStatus(bool& isCharging);
    bool isConnected() const;
    bool isDongle() const;
    bool isWiredDevicePresent() const;

    // Hotplug monitoring
    void startMonitoring(DeviceCallback callback, void* context);
    void stopMonitoring();

private:
    static constexpr uint16_t VENDOR_ID = 0x1532;
    static constexpr uint16_t PRODUCT_ID_DONGLE = 0x00A6;  // Wireless Dongle
    static constexpr uint16_t PRODUCT_ID_WIRED = 0x00A5;   // Wired Mouse (Charging)
    static constexpr size_t REPORT_SIZE = 90;
    static constexpr uint8_t TARGET_INTERFACE = 2;  // Interface 2 for control
    
    // USB HID Request types
    static constexpr uint8_t USB_TYPE_CLASS = 0x01 << 5;
    static constexpr uint8_t USB_RECIP_INTERFACE = 0x01;
    static constexpr uint8_t USB_DIR_OUT = 0x00;
    static constexpr uint8_t USB_DIR_IN = 0x80;
    static constexpr uint8_t HID_REQ_SET_REPORT = 0x09;
    static constexpr uint8_t HID_REQ_GET_REPORT = 0x01;
    
    IOUSBInterfaceInterface** usbInterface_;
    io_service_t interfaceService_;

    // Thread safety
    mutable std::mutex usbMutex_;          // Protects all USB operations
    std::atomic<bool> isShuttingDown_;     // Safe teardown flag

    // Adaptive timing
    USBTimer usbTimer_;                    // Adaptive USB operation timing

    // Wired vs. Wireless detection
    bool isDongle_;  // true = Wireless (Dongle), false = Wired (Direct USB)
    uint16_t connectedWiredPid_;  // Wired PID for the connected device (for cable detection)
    std::string deviceName_;  // Human-readable device name
    std::string getDeviceName(io_service_t device);
    std::string getDeviceNameByPid(uint16_t pid);
    
    // Supported devices list
    static const RazerSupportedDevice SUPPORTED_DEVICES[];
    static const size_t NUM_SUPPORTED_DEVICES;
    
    // IOKit notification members
    IONotificationPortRef notificationPort_;
    io_iterator_t addedIter_;
    io_iterator_t removedIter_;
    DeviceCallback callback_;
    void* callbackContext_;
    
    void calculateChecksum(uint8_t* report);
    bool sendReport(const uint8_t* report);
    bool readResponse(uint8_t* buffer, size_t bufferSize);
    bool sendReportLocked(const uint8_t* report);      // Requires usbMutex_ held
    bool readResponseLocked(uint8_t* buffer, size_t bufferSize);  // Requires usbMutex_ held
    bool findInterface2(io_service_t device);
    bool setDeviceMode(uint8_t mode, uint8_t param);
    
    // Static callbacks for IOKit
    static void deviceAddedCallback(void* refCon, io_iterator_t iterator);
    static void deviceRemovedCallback(void* refCon, io_iterator_t iterator);
};

#endif // RAZER_DEVICE_HPP
