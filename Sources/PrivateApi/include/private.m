#import "private.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>

typedef int (*SLSMainConnectionIDFn)(void);
typedef CFArrayRef (*SLSCopyManagedDisplaySpacesFn)(int);
typedef CFArrayRef (*SLSCopyWindowsWithOptionsAndTagsFn)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
typedef CFArrayRef (*SLSCopySpacesForWindowsFn)(int, int, CFArrayRef);

static atomic_bool aerospace_SLSCopySpacesForWindowsTimedOut = false;

struct AerospaceCopyArrayState {
    atomic_int refCount;
    pthread_mutex_t lock;
    CFArrayRef result;
    bool timedOut;
};

static void aerospace_CopyArrayStateRelease(struct AerospaceCopyArrayState *state) {
    if (atomic_fetch_sub(&state->refCount, 1) != 1) {
        return;
    }
    if (state->result != NULL) {
        CFRelease(state->result);
    }
    pthread_mutex_destroy(&state->lock);
    free(state);
}

static void *aerospace_SkyLight(void) {
    static void *skyLight = NULL;
    if (skyLight == NULL) {
        skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    }
    return skyLight;
}

static int aerospace_SLSMainConnectionID(void) {
    void *skyLight = aerospace_SkyLight();
    if (skyLight == NULL) {
        return 0;
    }
    SLSMainConnectionIDFn fn = (SLSMainConnectionIDFn)dlsym(skyLight, "SLSMainConnectionID");
    return fn != NULL ? fn() : 0;
}

static bool aerospace_awaitCopyArray(CFArrayRef (^block)(void), CFArrayRef *result) {
    struct AerospaceCopyArrayState *state = calloc(1, sizeof(struct AerospaceCopyArrayState));
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
        aerospace_CopyArrayStateRelease(state);
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
        aerospace_CopyArrayStateRelease(state);
        return false;
    }
    pthread_mutex_lock(&state->lock);
    *result = state->result;
    state->result = NULL;
    pthread_mutex_unlock(&state->lock);
    aerospace_CopyArrayStateRelease(state);
    return true;
}

CFArrayRef aerospace_SLSCopyManagedDisplaySpaces(void) {
    void *skyLight = aerospace_SkyLight();
    if (skyLight == NULL) {
        return NULL;
    }
    SLSCopyManagedDisplaySpacesFn fn = (SLSCopyManagedDisplaySpacesFn)dlsym(skyLight, "SLSCopyManagedDisplaySpaces");
    return fn != NULL ? fn(aerospace_SLSMainConnectionID()) : NULL;
}

CFArrayRef aerospace_SLSCopyWindowsForSpace(uint64_t sid) {
    void *skyLight = aerospace_SkyLight();
    if (skyLight == NULL) {
        return NULL;
    }
    SLSCopyWindowsWithOptionsAndTagsFn fn = (SLSCopyWindowsWithOptionsAndTagsFn)dlsym(skyLight, "SLSCopyWindowsWithOptionsAndTags");
    if (fn == NULL) {
        return NULL;
    }
    uint64_t setTags = 0;
    uint64_t clearTags = 0;
    NSArray *spaces = @[@(sid)];
    return fn(aerospace_SLSMainConnectionID(), 0, (__bridge CFArrayRef)spaces, 0x7, &setTags, &clearTags);
}

CFArrayRef aerospace_SLSCopySpacesForWindow(uint32_t wid) {
    if (atomic_load(&aerospace_SLSCopySpacesForWindowsTimedOut)) {
        return NULL;
    }
    void *skyLight = aerospace_SkyLight();
    if (skyLight == NULL) {
        return NULL;
    }
    SLSCopySpacesForWindowsFn fn = (SLSCopySpacesForWindowsFn)dlsym(skyLight, "SLSCopySpacesForWindows");
    if (fn == NULL) {
        return NULL;
    }
    NSArray *windows = @[@(wid)];
    int connection = aerospace_SLSMainConnectionID();
    CFArrayRef result = NULL;
    bool didFinish = aerospace_awaitCopyArray(^{
        return fn(connection, 0x7, (__bridge CFArrayRef)windows);
    }, &result);
    if (!didFinish) {
        atomic_store(&aerospace_SLSCopySpacesForWindowsTimedOut, true);
    }
    return result;
}

bool aerospace_SLSCopySpacesForWindowsDidTimeout(void) {
    return atomic_load(&aerospace_SLSCopySpacesForWindowsTimedOut);
}
