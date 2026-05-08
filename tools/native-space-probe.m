#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdlib.h>

typedef int (*SLSMainConnectionIDFn)(void);
typedef CFArrayRef (*SLSCopyManagedDisplaySpacesFn)(int);
typedef uint64_t (*SLSGetActiveSpaceFn)(int);
typedef CFArrayRef (*SLSCopyWindowsWithOptionsAndTagsFn)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
typedef CFArrayRef (*SLSCopySpacesForWindowsFn)(int, int, CFArrayRef);

struct CopyArrayState {
    atomic_int refCount;
    pthread_mutex_t lock;
    CFArrayRef result;
    bool timedOut;
};

static void copyArrayStateRelease(struct CopyArrayState *state) {
    if (atomic_fetch_sub(&state->refCount, 1) != 1) {
        return;
    }
    if (state->result != NULL) {
        CFRelease(state->result);
    }
    pthread_mutex_destroy(&state->lock);
    free(state);
}

static bool awaitCopyArray(CFArrayRef (^block)(void), CFArrayRef *result) {
    struct CopyArrayState *state = calloc(1, sizeof(struct CopyArrayState));
    if (state == NULL) {
        return false;
    }
    atomic_init(&state->refCount, 2);
    pthread_mutex_init(&state->lock, NULL);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFArrayRef blockResult = block();
        pthread_mutex_lock(&state->lock);
        if (state->timedOut) {
            if (blockResult != NULL) {
                CFRelease(blockResult);
            }
        } else {
            state->result = blockResult;
        }
        pthread_mutex_unlock(&state->lock);
        dispatch_semaphore_signal(done);
        copyArrayStateRelease(state);
    });
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC));
    if (dispatch_semaphore_wait(done, timeout) != 0) {
        pthread_mutex_lock(&state->lock);
        state->timedOut = true;
        if (state->result != NULL) {
            CFRelease(state->result);
            state->result = NULL;
        }
        pthread_mutex_unlock(&state->lock);
        copyArrayStateRelease(state);
        return false;
    }
    pthread_mutex_lock(&state->lock);
    *result = state->result;
    state->result = NULL;
    pthread_mutex_unlock(&state->lock);
    copyArrayStateRelease(state);
    return true;
}

static id jsonSafe(id value) {
    if (value == nil || value == (id)kCFNull) {
        return [NSNull null];
    }
    if ([NSJSONSerialization isValidJSONObject:@[value]]) {
        return value;
    }
    return [value description] ?: [NSNull null];
}

static NSNumber *spaceIdFromDictionary(NSDictionary *space) {
    id value = space[@"ManagedSpaceID"] ?: space[@"id64"] ?: space[@"id"];
    if ([value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    return nil;
}

int main(void) {
    @autoreleasepool {
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (skyLight == NULL) {
            fprintf(stderr, "dlopen SkyLight failed: %s\n", dlerror());
            return 1;
        }

        SLSMainConnectionIDFn SLSMainConnectionID = (SLSMainConnectionIDFn)dlsym(skyLight, "SLSMainConnectionID");
        SLSCopyManagedDisplaySpacesFn SLSCopyManagedDisplaySpaces = (SLSCopyManagedDisplaySpacesFn)dlsym(skyLight, "SLSCopyManagedDisplaySpaces");
        SLSGetActiveSpaceFn SLSGetActiveSpace = (SLSGetActiveSpaceFn)dlsym(skyLight, "SLSGetActiveSpace");
        SLSCopyWindowsWithOptionsAndTagsFn SLSCopyWindowsWithOptionsAndTags = (SLSCopyWindowsWithOptionsAndTagsFn)dlsym(skyLight, "SLSCopyWindowsWithOptionsAndTags");
        SLSCopySpacesForWindowsFn SLSCopySpacesForWindows = (SLSCopySpacesForWindowsFn)dlsym(skyLight, "SLSCopySpacesForWindows");

        if (SLSMainConnectionID == NULL || SLSCopyManagedDisplaySpaces == NULL) {
            fprintf(stderr, "Required SkyLight symbols missing\n");
            return 1;
        }

        int connection = SLSMainConnectionID();
        uint64_t focusedSpace = SLSGetActiveSpace != NULL ? SLSGetActiveSpace(connection) : 0;
        CFArrayRef managedRef = SLSCopyManagedDisplaySpaces(connection);
        if (managedRef == NULL) {
            fprintf(stderr, "SLSCopyManagedDisplaySpaces returned NULL\n");
            return 1;
        }

        NSArray *managedDisplays = CFBridgingRelease(managedRef);
        NSMutableArray *displays = [NSMutableArray array];
        NSMutableDictionary *windowSpacesByWindowId = [NSMutableDictionary dictionary];
        BOOL windowSpacesTimedOut = NO;
        for (NSDictionary *display in managedDisplays) {
            NSDictionary *currentSpace = display[@"Current Space"];
            NSNumber *currentSpaceId = spaceIdFromDictionary(currentSpace);
            NSArray *spaces = display[@"Spaces"] ?: @[];
            NSMutableArray *spaceIds = [NSMutableArray array];
            for (NSDictionary *space in spaces) {
                NSNumber *spaceId = spaceIdFromDictionary(space);
                if (spaceId != nil) {
                    [spaceIds addObject:spaceId];
                }
            }

            NSArray *currentSpaceWindows = @[];
            if (SLSCopyWindowsWithOptionsAndTags != NULL && currentSpaceId != nil) {
                uint64_t setTags = 0;
                uint64_t clearTags = 0;
                NSArray *spacesList = @[currentSpaceId];
                CFArrayRef windowsRef = SLSCopyWindowsWithOptionsAndTags(connection, 0, (__bridge CFArrayRef)spacesList, 0x7, &setTags, &clearTags);
                if (windowsRef != NULL) {
                    currentSpaceWindows = CFBridgingRelease(windowsRef);
                    if (SLSCopySpacesForWindows != NULL) {
                        for (NSNumber *windowId in currentSpaceWindows) {
                            if (windowSpacesTimedOut) {
                                break;
                            }
                            NSArray *windowList = @[windowId];
                            CFArrayRef windowSpacesRef = NULL;
                            bool didFinish = awaitCopyArray(^{
                                return SLSCopySpacesForWindows(connection, 0x7, (__bridge CFArrayRef)windowList);
                            }, &windowSpacesRef);
                            if (!didFinish) {
                                windowSpacesTimedOut = YES;
                                break;
                            }
                            if (windowSpacesRef != NULL) {
                                windowSpacesByWindowId[windowId.stringValue] = CFBridgingRelease(windowSpacesRef);
                            }
                        }
                    }
                }
            }

            [displays addObject:@{
                @"displayIdentifier": jsonSafe(display[@"Display Identifier"]),
                @"currentSpaceId": currentSpaceId ?: [NSNull null],
                @"currentSpaceWindowIds": currentSpaceWindows,
                @"spaceIds": spaceIds,
                @"currentSpaceRaw": jsonSafe(currentSpace),
            }];
        }

        NSDictionary *output = @{
            @"focusedSpaceId": @(focusedSpace),
            @"displays": displays,
            @"windowSpacesByWindowId": windowSpacesByWindowId,
            @"windowSpacesTimedOut": @(windowSpacesTimedOut),
            @"screensHaveSeparateSpaces": @([NSScreen screensHaveSeparateSpaces]),
        };

        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (json == nil) {
            fprintf(stderr, "JSON serialization failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
