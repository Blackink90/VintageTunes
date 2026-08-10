#include "iPodUSBReconnect.h"

#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <IOKit/usb/USBSpec.h>

static bool vt_string_contains_ci(const char *hay, const char *needle) {
    if (!hay || !needle) return false;
    size_t nlen = strlen(needle);
    if (nlen == 0) return true;
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < nlen) {
            char a = p[i], b = needle[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) break;
            i++;
        }
        if (i == nlen) return true;
    }
    return false;
}

static bool vt_is_apple_ipod(io_service_t service) {
    CFNumberRef vendRef = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBVendorID), kCFAllocatorDefault, 0);
    CFNumberRef prodRef = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBProductID), kCFAllocatorDefault, 0);
    CFStringRef nameRef = IORegistryEntryCreateCFProperty(service, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
    if (!nameRef) {
        nameRef = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBProductString), kCFAllocatorDefault, 0);
    }

    int vendor = 0;
    int product = 0;
    if (vendRef) {
        CFNumberGetValue(vendRef, kCFNumberIntType, &vendor);
        CFRelease(vendRef);
    }
    if (prodRef) {
        CFNumberGetValue(prodRef, kCFNumberIntType, &product);
        CFRelease(prodRef);
    }

    char name[128] = {0};
    if (nameRef) {
        CFStringGetCString(nameRef, name, sizeof(name), kCFStringEncodingUTF8);
        CFRelease(nameRef);
    }

    if (vendor != kIOUSBVendorIDAppleComputer) return false;
    if (vt_string_contains_ci(name, "iphone") || vt_string_contains_ci(name, "ipad")
        || vt_string_contains_ci(name, "airpod") || vt_string_contains_ci(name, "watch")
        || vt_string_contains_ci(name, "pencil")) {
        return false;
    }
    if (vt_string_contains_ci(name, "ipod")) return true;

    int p = product & 0xFFFF;
    return (p >= 0x1200 && p <= 0x12FF) || (p >= 0x1300 && p <= 0x13FF);
}

static bool vt_reenumerate_service(io_service_t service) {
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugIn,
        &score
    );
    if (kr != KERN_SUCCESS || plugIn == NULL) return false;

    IOUSBDeviceInterface500 **device = NULL;
    HRESULT hr = (*plugIn)->QueryInterface(
        plugIn,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500),
        (LPVOID *)&device
    );
    (*plugIn)->Release(plugIn);
    if (hr != 0 || device == NULL) return false;

    kr = (*device)->USBDeviceOpenSeize(device);
    if (kr != KERN_SUCCESS) {
        kr = (*device)->USBDeviceOpen(device);
    }
    if (kr != KERN_SUCCESS) {
        (*device)->Release(device);
        return false;
    }

    kr = (*device)->USBDeviceReEnumerate(device, 0);
    (*device)->USBDeviceClose(device);
    (*device)->Release(device);
    return kr == KERN_SUCCESS;
}

int VTReenumerateConnectediPods(void) {
    const char *classes[] = { "IOUSBHostDevice", kIOUSBDeviceClassName, NULL };
    int count = 0;

    for (int i = 0; classes[i] != NULL; i++) {
        CFMutableDictionaryRef matching = IOServiceMatching(classes[i]);
        if (matching == NULL) continue;

        io_iterator_t iterator = 0;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
        if (kr != KERN_SUCCESS || iterator == 0) continue;

        io_service_t service;
        while ((service = IOIteratorNext(iterator)) != 0) {
            if (vt_is_apple_ipod(service) && vt_reenumerate_service(service)) {
                count += 1;
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
        if (count > 0) break;
    }

    return count;
}
