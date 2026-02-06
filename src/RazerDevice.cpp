/**
 * RazerDevice.cpp - Razer Viper V2 Pro Battery Monitor
 * 
 * USB HID Protocol for Razer Viper V2 Pro (VID: 0x1532, PID: 0x00A6)
 * 
 * PROTOCOL DETAILS (discovered via librazermacos analysis):
 * - Transaction ID: 0x1F (Wireless protocol, works for Viper V2 Pro)
 * - Command Class: 0x07 (Power/Battery)
 * - Command ID: 0x80 (Get Battery Level)
 * - Data Size: 0x02
 * - Battery Data: Response byte 9 (0-255 scale, map to 0-100%)
 * - Valid Status: 0x00 (Success) OR 0x02 (Busy with data ready)
 * 
 * USB Control Transfer Parameters:
 * - bmRequestType: 0x21 (SET) / 0xA1 (GET)
 * - bRequest: 0x09 (SET_REPORT) / 0x01 (GET_REPORT)
 * - wValue: 0x0300 (Feature Report, ID 0)
 * - wIndex: 0x00 (protocol index for mice)
 * - wLength: 90 bytes
 * 
 * Report Structure (90 bytes):
 * [0]     Status: 0x00 = New Command
 * [1]     Transaction ID: 0x1F for wireless
 * [2-4]   Reserved
 * [5]     Data Size: 0x02
 * [6]     Command Class: 0x07 = Power
 * [7]     Command ID: 0x80 = Get Battery
 * [8-87]  Arguments (battery at byte 9)
 * [88]    Checksum (XOR of bytes 2-87)
 * [89]    Reserved
 */

#include "RazerDevice.hpp"
#include <cstring>
#include <iostream>
#include <unistd.h>
#include <string>
#include <algorithm>
#include <cctype>

// List of supported Razer wireless mice (from OpenRazer)
const RazerSupportedDevice RazerDevice::SUPPORTED_DEVICES[] = {
    {0x00A6, 0x00A5, "Razer Viper V2 Pro"},
    {0x007D, 0x007C, "Razer DeathAdder V2 Pro"},
    {0x007B, 0x007A, "Razer Viper Ultimate"},
    {0x0088, 0x0086, "Razer Basilisk Ultimate"},
    {0x0090, 0x008F, "Razer Naga Pro"},
    {0x00B7, 0x00B6, "Razer DeathAdder V3 Pro"},
    {0x00AB, 0x00AA, "Razer Basilisk V3 Pro"},
    {0x00B0, 0x00AF, "Razer Cobra Pro"},
    {0x00A8, 0x00A7, "Razer Naga V2 Pro"},
    {0x00BF, 0x00BE, "Razer DeathAdder V4 Pro"},
    {0x00C1, 0x00C0, "Razer Viper V3 Pro"},
    {0x0072, 0x0073, "Razer Mamba Wireless"},
    {0x006F, 0x0070, "Razer Lancehead Wireless"},
    {0x0094, 0x0095, "Razer Orochi V2"},
    {0x003F, 0x003E, "Razer Naga Epic Chroma"},
    {0x0045, 0x0044, "Razer Mamba"},
    {0x005A, 0x0059, "Razer Lancehead"},
    {0x0025, 0x0024, "Razer Mamba 2012"},
    {0x001F, 0x0000, "Razer Naga Epic"}
};

const size_t RazerDevice::NUM_SUPPORTED_DEVICES = sizeof(RazerDevice::SUPPORTED_DEVICES) / sizeof(RazerSupportedDevice);

RazerDevice::RazerDevice()
    : usbInterface_(nullptr),
      interfaceService_(0),
      isShuttingDown_(false),
      isDongle_(true),  // Assume wireless by default
      connectedWiredPid_(0),
      deviceName_("Unknown Razer Mouse"),
      notificationPort_(nullptr),
      addedIter_(0),
      removedIter_(0),
      callback_(nullptr),
      callbackContext_(nullptr) {
}

RazerDevice::~RazerDevice() {
    isShuttingDown_ = true;
    stopMonitoring();
    disconnect();
}

void RazerDevice::startMonitoring(DeviceCallback callback, void* context) {
    if (notificationPort_ != nullptr) {
        return; // Already monitoring
    }

    callback_ = callback;
    callbackContext_ = context;

    // Create notification port
    notificationPort_ = IONotificationPortCreate(kIOMainPortDefault);
    if (!notificationPort_) {
        std::cerr << "Failed to create IONotificationPort" << std::endl;
        return;
    }

    // Add to run loop
    CFRunLoopSourceRef runLoopSource = IONotificationPortGetRunLoopSource(notificationPort_);
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopDefaultMode);

    // Create matching dictionary for Razer devices
    // NOTE: We only match on VID (not PID) to detect both Dongle (0xA6) and Wired (0xA5)
    // Use "IOUSBHostDevice" (macOS 13+) instead of deprecated kIOUSBDeviceClassName
    CFMutableDictionaryRef matchingDict = IOServiceMatching("IOUSBHostDevice");
    if (!matchingDict) {
        std::cerr << "Failed to create matching dictionary" << std::endl;
        // Cleanup notification port on error
        IONotificationPortDestroy(notificationPort_);
        notificationPort_ = nullptr;
        return;
    }

    // Add VID only - monitor all Razer devices
    int vid = VENDOR_ID;
    CFNumberRef vidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), vidRef);
    CFRelease(vidRef);

    // Register for device added (retain dict for second use)
    CFRetain(matchingDict);

    kern_return_t kr = IOServiceAddMatchingNotification(
        notificationPort_,
        kIOFirstMatchNotification,
        matchingDict,
        deviceAddedCallback,
        (void*)this,
        &addedIter_
    );

    if (kr != KERN_SUCCESS) {
        std::cerr << "Failed to register for device added: " << std::hex << kr << std::dec << std::endl;
    } else {
        // Drain iterator to arm notification
        deviceAddedCallback(this, addedIter_);
    }

    // Register for device removed
    kr = IOServiceAddMatchingNotification(
        notificationPort_,
        kIOTerminatedNotification,
        matchingDict,
        deviceRemovedCallback,
        (void*)this,
        &removedIter_
    );

    if (kr != KERN_SUCCESS) {
        std::cerr << "Failed to register for device removed: " << std::hex << kr << std::dec << std::endl;
    } else {
        // Drain iterator to arm notification
        deviceRemovedCallback(this, removedIter_);
    }
}

void RazerDevice::stopMonitoring() {
    if (addedIter_) {
        IOObjectRelease(addedIter_);
        addedIter_ = 0;
    }
    if (removedIter_) {
        IOObjectRelease(removedIter_);
        removedIter_ = 0;
    }
    if (notificationPort_) {
        IONotificationPortDestroy(notificationPort_);
        notificationPort_ = nullptr;
    }
    callback_ = nullptr;
    callbackContext_ = nullptr;
}

void RazerDevice::deviceAddedCallback(void* refCon, io_iterator_t iterator) {
    RazerDevice* self = (RazerDevice*)refCon;
    io_service_t device;
    bool newDeviceFound = false;
    
    while ((device = IOIteratorNext(iterator))) {
        IOObjectRelease(device);
        newDeviceFound = true;
    }
    
    if (newDeviceFound && self->callback_) {
        self->callback_(self->callbackContext_);
    }
}

void RazerDevice::deviceRemovedCallback(void* refCon, io_iterator_t iterator) {
    RazerDevice* self = (RazerDevice*)refCon;
    io_service_t device;
    bool deviceRemoved = false;
    
    while ((device = IOIteratorNext(iterator))) {
        IOObjectRelease(device);
        deviceRemoved = true;
    }
    
    if (deviceRemoved && self->callback_) {
        self->callback_(self->callbackContext_);
    }
}

std::string RazerDevice::getDeviceName(io_service_t device) {
    std::string name = "Unknown";
    CFStringRef deviceName = (CFStringRef)IORegistryEntryCreateCFProperty(
        device,
        CFSTR("USB Product Name"),
        kCFAllocatorDefault,
        0
    );
    
    if (deviceName) {
        char buf[256];
        if (CFStringGetCString(deviceName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            name = buf;
        }
        CFRelease(deviceName);
    }
    return name;
}

std::string RazerDevice::getDeviceNameByPid(uint16_t pid) {
    for (size_t i = 0; i < NUM_SUPPORTED_DEVICES; i++) {
        if (SUPPORTED_DEVICES[i].wirelessPid == pid || SUPPORTED_DEVICES[i].wiredPid == pid) {
            return std::string(SUPPORTED_DEVICES[i].name);
        }
    }
    return "Unknown Razer Mouse";
}

bool RazerDevice::findInterface2(io_service_t device) {
    // Create iterator for device's interfaces
    io_iterator_t interfaceIterator;
    IOUSBFindInterfaceRequest request;
    request.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    request.bAlternateSetting = kIOUSBFindInterfaceDontCare;
    
    // We need to open the device first to iterate interfaces
    IOCFPlugInInterface** plugInInterface = nullptr;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(device, kIOUSBDeviceUserClientTypeID,
                                                          kIOCFPlugInInterfaceID, &plugInInterface, &score);
    if (kr != KERN_SUCCESS || plugInInterface == nullptr) {
        std::cerr << "Failed to create device plugin interface" << std::endl;
        return false;
    }
    
    IOUSBDeviceInterface** deviceInterface = nullptr;
    HRESULT hr = (*plugInInterface)->QueryInterface(plugInInterface,
                    CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                    (LPVOID*)&deviceInterface);
    (*plugInInterface)->Release(plugInInterface);
    
    if (hr != S_OK || deviceInterface == nullptr) {
        std::cerr << "Failed to get device interface" << std::endl;
        return false;
    }
    
    // Open device to iterate interfaces
    kr = (*deviceInterface)->USBDeviceOpen(deviceInterface);
    // Note: Device might already be open by system - this is OK, we proceed anyway
    
    // Create interface iterator
    kr = (*deviceInterface)->CreateInterfaceIterator(deviceInterface, &request, &interfaceIterator);
    if (kr != kIOReturnSuccess) {
        std::cerr << "Failed to create interface iterator" << std::endl;
        (*deviceInterface)->USBDeviceClose(deviceInterface);
        (*deviceInterface)->Release(deviceInterface);
        return false;
    }
    
    // Iterate through interfaces to find Interface 2
    io_service_t usbInterfaceRef;
    bool found = false;
    
    while ((usbInterfaceRef = IOIteratorNext(interfaceIterator)) != 0) {
        IOCFPlugInInterface** interfacePlugIn = nullptr;
        SInt32 interfaceScore;
        
        kr = IOCreatePlugInInterfaceForService(usbInterfaceRef, kIOUSBInterfaceUserClientTypeID,
                                                kIOCFPlugInInterfaceID, &interfacePlugIn, &interfaceScore);
        
        if (kr == KERN_SUCCESS && interfacePlugIn != nullptr) {
            IOUSBInterfaceInterface** interface = nullptr;
            hr = (*interfacePlugIn)->QueryInterface(interfacePlugIn,
                        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                        (LPVOID*)&interface);
            (*interfacePlugIn)->Release(interfacePlugIn);
            
            if (hr == S_OK && interface != nullptr) {
                UInt8 interfaceNumber;
                (*interface)->GetInterfaceNumber(interface, &interfaceNumber);
                
                if (interfaceNumber == TARGET_INTERFACE) {
                    // Open Interface 2 (vendor-specific control interface)
                    kr = (*interface)->USBInterfaceOpen(interface);
                    if (kr == kIOReturnSuccess || kr == kIOReturnExclusiveAccess) {
                        // Success or exclusive access (we can still send control requests)
                        usbInterface_ = interface;
                        interfaceService_ = usbInterfaceRef;
                        found = true;
                    } else {
                        (*interface)->Release(interface);
                        IOObjectRelease(usbInterfaceRef);
                    }
                    break;
                } else {
                    (*interface)->Release(interface);
                }
            }
        }
        
        if (!found) {
            IOObjectRelease(usbInterfaceRef);
        }
    }
    
    IOObjectRelease(interfaceIterator);
    
    // Close device (we'll use the interface directly)
    (*deviceInterface)->USBDeviceClose(deviceInterface);
    (*deviceInterface)->Release(deviceInterface);
    
    return found;
}

bool RazerDevice::connect() {
    if (usbInterface_ != nullptr) {
        return true; // Already connected
    }

    io_service_t deviceService = 0;
    int vid = VENDOR_ID;

    // RAII guard for CFMutableDictionary
    struct CFDictGuard {
        CFMutableDictionaryRef dict;
        CFDictGuard() : dict(nullptr) {}
        ~CFDictGuard() { if (dict) CFRelease(dict); }
    };

    // Lambda to try connecting to a specific device PID
    auto tryConnectToDevice = [&](uint16_t wirelessPid, uint16_t wiredPid, const char* deviceName) -> bool {
        // Always prefer dongle - the wired interface doesn't support HID control
        // transfers for battery queries. Cable detection uses isWiredDevicePresent().
        uint16_t pidsToTry[] = { wirelessPid, wiredPid };

        for (int j = 0; j < 2; j++) {
            uint16_t pid = pidsToTry[j];
            if (pid == 0) continue;  // Skip if PID not available

            CFDictGuard guardedDict;
            // Use "IOUSBHostDevice" (macOS 13+) instead of deprecated kIOUSBDeviceClassName
            guardedDict.dict = IOServiceMatching("IOUSBHostDevice");
            if (guardedDict.dict == nullptr) {
                continue;
            }

            CFNumberRef vidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
            int pidInt = pid;
            CFNumberRef pidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pidInt);
            CFDictionarySetValue(guardedDict.dict, CFSTR(kUSBVendorID), vidRef);
            CFDictionarySetValue(guardedDict.dict, CFSTR(kUSBProductID), pidRef);
            CFRelease(vidRef);
            CFRelease(pidRef);

            io_iterator_t iterator;
            // Note: IOServiceGetMatchingServices takes ownership of the dictionary
            kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, guardedDict.dict, &iterator);
            guardedDict.dict = nullptr;  // Dictionary now owned by IOKit, clear guard to prevent double-free
            if (kr != KERN_SUCCESS) {
                continue;
            }

            deviceService = IOIteratorNext(iterator);
            IOObjectRelease(iterator);

            if (deviceService != 0) {
                deviceName_ = deviceName;

                // DETECT MODE: Check if this is wireless or wired PID
                isDongle_ = (pid == wirelessPid);

                // Store wired PID for cable-charging detection
                connectedWiredPid_ = wiredPid;

                const char* mode = isDongle_ ? "Wireless/Dongle" : "Wired/Charging";
                std::cout << "Connected to " << deviceName_
                          << " via PID 0x" << std::hex << pid << std::dec
                          << " (Mode: " << mode << ")" << std::endl;
                return true;
            }
        }
        return false;
    };

    // Try all supported devices
    for (size_t i = 0; i < NUM_SUPPORTED_DEVICES; i++) {
        if (tryConnectToDevice(SUPPORTED_DEVICES[i].wirelessPid, SUPPORTED_DEVICES[i].wiredPid, SUPPORTED_DEVICES[i].name)) {
            break;
        }
    }

    // Check if device was found
    if (deviceService == 0) {
        std::cerr << "ERROR: No Razer device found" << std::endl;
        return false;  // Device not found
    }

    // Find and open Interface 2
    std::cout << "Attempting to open USB interface for device: " << deviceName_ << std::endl;
    bool success = findInterface2(deviceService);
    IOObjectRelease(deviceService);

    if (!success) {
        std::cerr << "ERROR: Failed to open USB interface" << std::endl;
        return false;
    }

    std::cout << "Successfully connected to " << deviceName_ << std::endl;

    // Initialize device to Driver Mode (0x03) - enables battery queries
    if (!setDeviceMode(0x03, 0x00)) {
        std::cerr << "WARNING: Failed to set device mode, battery queries may not work" << std::endl;
    }
    
    return success;
}

void RazerDevice::disconnect() {
    std::lock_guard<std::mutex> lock(usbMutex_);
    if (usbInterface_ != nullptr) {
        (*usbInterface_)->USBInterfaceClose(usbInterface_);
        (*usbInterface_)->Release(usbInterface_);
        usbInterface_ = nullptr;
        std::cout << "Disconnected from " << deviceName_ << std::endl;
    }
    if (interfaceService_ != 0) {
        IOObjectRelease(interfaceService_);
        interfaceService_ = 0;
    }
}

bool RazerDevice::isConnected() const {
    std::lock_guard<std::mutex> lock(usbMutex_);

    if (usbInterface_ == nullptr) {
        return false;
    }

    // Actively verify USB interface is still valid
    UInt8 interfaceNumber;
    IOReturn kr = (*usbInterface_)->GetInterfaceNumber(usbInterface_, &interfaceNumber);

    return (kr == kIOReturnSuccess && interfaceNumber == TARGET_INTERFACE);
}

bool RazerDevice::isDongle() const {
    return isDongle_;
}

bool RazerDevice::isWiredDevicePresent() const {
    // Check if the wired variant of the connected mouse exists in USB services.
    // Used to detect charging via cable while connected via dongle.
    if (connectedWiredPid_ == 0) {
        return false;
    }

    int vid = VENDOR_ID;
    int pid = connectedWiredPid_;

    CFMutableDictionaryRef matchDict = IOServiceMatching("IOUSBHostDevice");
    if (!matchDict) {
        return false;
    }

    CFNumberRef vidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFNumberRef pidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
    CFDictionarySetValue(matchDict, CFSTR(kUSBVendorID), vidRef);
    CFDictionarySetValue(matchDict, CFSTR(kUSBProductID), pidRef);
    CFRelease(vidRef);
    CFRelease(pidRef);

    // IOServiceGetMatchingServices takes ownership of matchDict
    io_iterator_t iterator;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator);
    if (kr != KERN_SUCCESS) {
        return false;
    }

    io_service_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    if (service != 0) {
        IOObjectRelease(service);
        return true;
    }

    return false;
}

bool RazerDevice::setDeviceMode(uint8_t mode, uint8_t param) {
    // Set Device Mode command - switches device to Driver Mode (0x03)
    // This enables battery queries on wireless Razer devices
    if (isShuttingDown_) {
        return false;
    }

    uint8_t report[REPORT_SIZE];
    std::memset(report, 0, REPORT_SIZE);

    report[0] = 0x00;   // Status: New Command
    report[1] = 0x1F;   // Transaction ID: Wireless
    report[5] = 0x02;   // Data Size
    report[6] = 0x00;   // Command Class: Device
    report[7] = 0x04;   // Command ID: Set Mode
    report[8] = mode;   // args[0]: Mode (0x03 = Driver Mode)
    report[9] = param;  // args[1]: Param

    calculateChecksum(report);

    std::lock_guard<std::mutex> lock(usbMutex_);

    if (!sendReportLocked(report)) {
        usbTimer_.onFailure();
        return false;
    }

    usbTimer_.waitForResponse();
    if (isShuttingDown_) return false;

    uint8_t response[REPORT_SIZE];
    std::memset(response, 0, REPORT_SIZE);

    if (!readResponseLocked(response, REPORT_SIZE)) {
        usbTimer_.onFailure();
        return false;
    }

    // Wait for mode switch to complete
    usleep(300000);  // 300ms

    // Accept Status 0x00 (Success) or 0x02 (Busy/Acknowledged)
    if (response[0] == 0x00 || response[0] == 0x02) {
        usbTimer_.onSuccess();
        return true;
    }

    usbTimer_.onFailure();
    return false;
}

void RazerDevice::calculateChecksum(uint8_t* report) {
    uint8_t checksum = 0;
    // XOR bytes 2 through 87 (indices 2-87) - matches librazermacos
    for (size_t i = 2; i < 88; ++i) {
        checksum ^= report[i];
    }
    report[88] = checksum; // Store checksum in byte 88 (CRC position)
}

bool RazerDevice::sendReportLocked(const uint8_t* report) {
    // Requires usbMutex_ to be held by caller
    if (usbInterface_ == nullptr) {
        return false;
    }

    // USB Control Transfer - SET_REPORT via Interface
    // NOTE: wIndex = 0x00 for mice (per librazermacos), NOT the interface number!
    IOUSBDevRequest request;
    request.bmRequestType = USB_TYPE_CLASS | USB_RECIP_INTERFACE | USB_DIR_OUT;  // 0x21
    request.bRequest = HID_REQ_SET_REPORT;  // 0x09
    request.wValue = 0x0300;  // Feature Report, Report ID 0
    request.wIndex = 0x00;  // Protocol index for mice (librazermacos default)
    request.wLength = REPORT_SIZE;  // 90 bytes
    request.pData = (void*)report;

    IOReturn kr = (*usbInterface_)->ControlRequest(usbInterface_, 0, &request);

    if (kr != kIOReturnSuccess) {
        std::cerr << "Failed to send report: 0x" << std::hex << kr << std::dec << std::endl;
        return false;
    }

    return true;
}

bool RazerDevice::readResponseLocked(uint8_t* buffer, size_t bufferSize) {
    // Requires usbMutex_ to be held by caller
    if (usbInterface_ == nullptr || bufferSize < REPORT_SIZE) {
        return false;
    }

    // USB Control Transfer - GET_REPORT via Interface
    // NOTE: wIndex = 0x00 for mice (per librazermacos), NOT the interface number!
    IOUSBDevRequest request;
    request.bmRequestType = USB_TYPE_CLASS | USB_RECIP_INTERFACE | USB_DIR_IN;  // 0xA1
    request.bRequest = HID_REQ_GET_REPORT;  // 0x01
    request.wValue = 0x0300;  // Feature Report, Report ID 0
    request.wIndex = 0x00;  // Protocol index for mice (librazermacos default)
    request.wLength = REPORT_SIZE;  // 90 bytes
    request.pData = buffer;

    IOReturn kr = (*usbInterface_)->ControlRequest(usbInterface_, 0, &request);

    if (kr != kIOReturnSuccess) {
        std::cerr << "Failed to read response: 0x" << std::hex << kr << std::dec << std::endl;
        return false;
    }

    return true;
}

bool RazerDevice::sendReport(const uint8_t* report) {
    if (isShuttingDown_) {
        return false;
    }
    std::lock_guard<std::mutex> lock(usbMutex_);
    return sendReportLocked(report);
}

bool RazerDevice::readResponse(uint8_t* buffer, size_t bufferSize) {
    if (isShuttingDown_) {
        return false;
    }
    std::lock_guard<std::mutex> lock(usbMutex_);
    return readResponseLocked(buffer, bufferSize);
}

bool RazerDevice::queryBattery(uint8_t& batteryPercent) {
    // Query battery level using Razer HID protocol
    // Try both Transaction IDs: 0x1F (Wireless) and 0xFF (Wired)

    if (isShuttingDown_) {
        return false;
    }

    const uint8_t transIds[] = {0x1F, 0xFF};

    std::lock_guard<std::mutex> lock(usbMutex_);

    if (usbInterface_ == nullptr) {
        return false;
    }

    for (int i = 0; i < 2; i++) {
        uint8_t report[REPORT_SIZE];
        std::memset(report, 0, REPORT_SIZE);

        report[0] = 0x00;
        report[1] = transIds[i];
        report[5] = 0x02;
        report[6] = 0x07;
        report[7] = 0x80;

        calculateChecksum(report);

        if (!sendReportLocked(report)) {
            usbTimer_.onFailure();
            continue;
        }

        if (isShuttingDown_) return false;
        usbTimer_.waitForResponse();
        if (isShuttingDown_) return false;

        uint8_t response[REPORT_SIZE];
        std::memset(response, 0, REPORT_SIZE);

        if (!readResponseLocked(response, REPORT_SIZE)) {
            usbTimer_.onFailure();
            continue;
        }

        uint8_t status = response[0];
        uint8_t rawBattery = response[9];

        // Status 0x00 or 0x02 = Success with data
        if ((status == 0x00 || status == 0x02) && rawBattery > 0) {
            batteryPercent = (rawBattery * 100) / 255;
            usbTimer_.onSuccess();
            return true;
        }

        // Status 0x04 = Command not supported on this interface.
        // Don't fake 100% - let caller use cached battery level.
        if (status == 0x04) {
            usbTimer_.onSuccess();
            return false;
        }
    }

    batteryPercent = 0;
    return false;
}

bool RazerDevice::queryChargingStatus(bool& isCharging) {
    // FAST PATH: If connected via USB cable (not dongle), we are charging
    if (!isDongle_) {
        isCharging = true;
        return true;
    }

    // Query charging status using Command 0x84 (per librazermacos)
    // Try both Transaction IDs: 0x1F (Wireless) and 0xFF (Wired)

    if (isShuttingDown_) {
        isCharging = false;
        return false;
    }

    const uint8_t transIds[] = {0x1F, 0xFF};

    std::lock_guard<std::mutex> lock(usbMutex_);

    if (usbInterface_ == nullptr) {
        isCharging = false;
        return false;
    }

    for (int i = 0; i < 2; i++) {
        uint8_t report[REPORT_SIZE];
        std::memset(report, 0, REPORT_SIZE);

        report[0] = 0x00;
        report[1] = transIds[i];
        report[5] = 0x02;
        report[6] = 0x07;
        report[7] = 0x84;  // Get Charging Status

        calculateChecksum(report);

        if (!sendReportLocked(report)) {
            usbTimer_.onFailure();
            continue;
        }

        if (isShuttingDown_) { isCharging = false; return false; }
        usbTimer_.waitForResponse();
        if (isShuttingDown_) { isCharging = false; return false; }

        uint8_t response[REPORT_SIZE];
        std::memset(response, 0, REPORT_SIZE);

        if (!readResponseLocked(response, REPORT_SIZE)) {
            usbTimer_.onFailure();
            continue;
        }

        uint8_t status = response[0];

        // Status 0x00 or 0x02 = Valid response
        // Charging status is in Byte 11 (index 11) per debug analysis
        if (status == 0x00 || status == 0x02) {
            isCharging = (response[11] == 0x01);
            usbTimer_.onSuccess();
            return true;
        }

        // Status 0x04 = Wired mode (command not supported = charging via cable)
        if (status == 0x04) {
            isCharging = true;  // Wired = Charging
            usbTimer_.onSuccess();
            return true;
        }
    }

    isCharging = false;
    usbTimer_.onFailure();
    return false;
}
