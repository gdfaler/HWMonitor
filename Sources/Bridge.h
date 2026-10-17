// Закрытые функции libIOReport: частоты ядер и энергия GPU без root.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c) CF_RETURNS_RETAINED;
void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef nul);
IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desired, CFMutableDictionaryRef *subbed, uint64_t channel_id, CFTypeRef b);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subbed, CFTypeRef a) CF_RETURNS_RETAINED;
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef a) CF_RETURNS_RETAINED;
CFStringRef IOReportChannelGetGroup(CFDictionaryRef ch) CF_RETURNS_NOT_RETAINED;
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef ch) CF_RETURNS_NOT_RETAINED;
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef ch) CF_RETURNS_NOT_RETAINED;
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef ch) CF_RETURNS_NOT_RETAINED;
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t idx);
int32_t IOReportStateGetCount(CFDictionaryRef ch);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef ch, int32_t idx) CF_RETURNS_NOT_RETAINED;
int64_t IOReportStateGetResidency(CFDictionaryRef ch, int32_t idx);
