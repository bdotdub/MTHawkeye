//
// Copyright (c) 2008-present, Meitu, Inc.
// All rights reserved.
//
// This source code is licensed under the license found in the LICENSE file in
// the root directory of this source tree.
//
// Created on: 2017/6/29
// Created by: YWH
//

#import "MTHFPSTrace.h"
#import <MTHawkeye/MTHawkeyeHooking.h>
#import <MTHawkeye/MTHawkeyeSignPosts.h>
#import <MTHawkeye/MTHawkeyeWeakProxy.h>
#import <sys/time.h>

@interface MTHFPSGLRenderCounter : NSObject
@property (nonatomic, assign) BOOL isStartRender;
@property (nonatomic, assign) NSUInteger renderCount;
@property (nonatomic, assign) NSUInteger signpostId;
@property (nonatomic, assign) NSUInteger fpsValue;
@property (nonatomic, strong) NSValue *lastRenderTime;
@end

@implementation MTHFPSGLRenderCounter

@end

@interface MTHFPSTrace ()
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) NSInteger fpsValue;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSUInteger fpsTickCount;
@property (nonatomic, assign) NSTimeInterval fpsTickLastTime;

@property (nonatomic, assign) BOOL gpuImageViewFPSEnable;
@property (nonatomic, assign) BOOL gpuImageViewDisplaying;
@property (nonatomic, assign) NSInteger gpuImageFPSValue;
@property (nonatomic, strong) NSHashTable<id<MTHFPSTraceDelegate>> *delegates;

@property (nonatomic, strong) NSArray<NSValue *> *renderInfos;
@property (atomic, copy, readwrite) NSHashTable *gpuImageRenderWeakTable;
@end

@implementation MTHFPSTrace
@synthesize gpuImageRenderWeakTable = _gpuImageRenderWeakTable;

- (void)dealloc {
    [_displayLink invalidate];
}

+ (instancetype)shared {
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

#pragma mark -
+ (void)registerGLESRenderInfo:(MTHFPSGLRenderInfo)renderInfo {
    if (!renderInfo.rendererClass || !renderInfo.startRenderSEL || !renderInfo.endRenderSEL || !renderInfo.renderProcessSEL) {
        return;
    }

    if (![renderInfo.rendererClass instancesRespondToSelector:renderInfo.startRenderSEL] || ![renderInfo.rendererClass instancesRespondToSelector:renderInfo.endRenderSEL] || ![renderInfo.rendererClass instancesRespondToSelector:renderInfo.renderProcessSEL]) {
        return;
    }

    NSValue *value = [NSValue value:&renderInfo withObjCType:@encode(MTHFPSGLRenderInfo)];
    if (![MTHFPSTrace shared].renderInfos) {
        [MTHFPSTrace shared].renderInfos = [NSArray array];
    }
    [[[MTHFPSTrace shared] mutableArrayValueForKey:@"renderInfos"] addObject:value];
}

- (void)addDelegate:(id<MTHFPSTraceDelegate>)delegate {
    if (!delegate) {
        return;
    }
    @synchronized(self.delegates) {
        [self.delegates addObject:delegate];
    }
}

- (void)removeDelegate:(id<MTHFPSTraceDelegate>)delegate {
    if (!delegate) {
        return;
    }
    @synchronized(self.delegates) {
        [self.delegates removeObject:delegate];
    }
}

- (void)start {
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.isRunning = YES;
    self.gpuImageViewDisplaying = NO;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [MTHFPSTrace registerGLESRenderInfo:(MTHFPSGLRenderInfo){
                                                NSClassFromString(@"GPUImageView"),
                                                NSSelectorFromString(@"createDisplayFramebuffer"),
                                                NSSelectorFromString(@"destroyDisplayFramebuffer"),
                                                NSSelectorFromString(@"presentFramebuffer")}];

        [MTHFPSTrace registerGLESRenderInfo:(MTHFPSGLRenderInfo){
                                                NSClassFromString(@"MTCameraGPUImageView"),
                                                NSSelectorFromString(@"createDisplayFramebuffer"),
                                                NSSelectorFromString(@"destroyDisplayFramebuffer"),
                                                NSSelectorFromString(@"presentFramebuffer")}];

        for (NSValue *value in self.renderInfos) {
            MTHFPSGLRenderInfo renderInfo;
            [value getValue:&renderInfo];

            if ([NSStringFromClass(renderInfo.rendererClass) isEqualToString:@"GPUImageView"] ||
                [NSStringFromClass(renderInfo.rendererClass) isEqualToString:@"MTCameraGPUImageView"]) {
                self.gpuImageViewFPSEnable = YES;
            }

            SEL swizzledSel = [MTHawkeyeHooking swizzledSelectorForSelector:renderInfo.startRenderSEL];
            void (^swizzleStartBlock)(id) = ^void(id obj) {
                ((void (*)(id, SEL))objc_msgSend)(obj, swizzledSel);
                [self glesRenderer:obj start:YES];
            };
            [MTHawkeyeHooking replaceImplementationOfKnownSelector:renderInfo.startRenderSEL
                                                           onClass:renderInfo.rendererClass
                                                         withBlock:swizzleStartBlock
                                                  swizzledSelector:swizzledSel];

            SEL swizzledSel1 = [MTHawkeyeHooking swizzledSelectorForSelector:renderInfo.endRenderSEL];
            void (^swizzleEndBlock)(id) = ^void(id obj) {
                ((void (*)(id, SEL))objc_msgSend)(obj, swizzledSel1);
                [self glesRenderer:obj start:NO];
            };
            [MTHawkeyeHooking replaceImplementationOfKnownSelector:renderInfo.endRenderSEL
                                                           onClass:renderInfo.rendererClass
                                                         withBlock:swizzleEndBlock
                                                  swizzledSelector:swizzledSel1];

            SEL swizzledSel2 = [MTHawkeyeHooking swizzledSelectorForSelector:renderInfo.renderProcessSEL];
            void (^swizzleRenderBlock)(id) = ^void(id obj) {
                ((void (*)(id, SEL))objc_msgSend)(obj, swizzledSel2);
                [self glesRenderProcess:obj];
            };
            [MTHawkeyeHooking replaceImplementationOfKnownSelector:renderInfo.renderProcessSEL
                                                           onClass:renderInfo.rendererClass
                                                         withBlock:swizzleRenderBlock
                                                  swizzledSelector:swizzledSel2];
        }
    });
}

- (void)stop {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.isRunning = NO;
}

#pragma mark - Tick Process
#pragma mark -FPS Tick
- (void)tickFPS:(CADisplayLink *)link {
    static NSInteger signpostId = 0;
    if (_fpsTickLastTime < DBL_EPSILON) {
        _fpsTickLastTime = link.timestamp;
        MTHSignpostStartCustom(999, signpostId, 0);
        return;
    }

    MTHSignpostEndCustom(999, signpostId, 0, 2);
    signpostId++;
    MTHSignpostStartCustom(999, signpostId, 0);

    _fpsTickCount++;
    NSTimeInterval delta = link.timestamp - _fpsTickLastTime;
    if (delta < 1) return;
    _fpsTickLastTime = link.timestamp;
    float fps = _fpsTickCount / delta;
    _fpsTickCount = 0;
    int newFPS = (int)round(fps);

    if (_fpsValue != newFPS) {
        [self.delegates.allObjects enumerateObjectsUsingBlock:^(id<MTHFPSTraceDelegate> _Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
            if ([obj respondsToSelector:@selector(fpsValueDidChanged:)]) {
                [obj fpsValueDidChanged:newFPS];
            }
        }];
    }
    _fpsValue = newFPS;
}

#pragma mark -GLES FPS Tick
- (void)glesRenderer:(id)reciver start:(BOOL)start {
    if (reciver == nil) {
        return;
    }
    __strong typeof(reciver) strongReciver = reciver;

    NSValue *surpportedRenderer = nil;
    for (NSValue *obj in self.renderInfos) {
        MTHFPSGLRenderInfo renderInfo;
        [obj getValue:&renderInfo];
        if ([strongReciver isKindOfClass:renderInfo.rendererClass]) {
            MTHFPSGLRenderCounter *counter = [self getDynamicAttachGLESCounter:strongReciver];
            counter.isStartRender = start;
            surpportedRenderer = obj;

            if ([NSStringFromClass(renderInfo.rendererClass) isEqualToString:@"GPUImageView"] ||
                [NSStringFromClass(renderInfo.rendererClass) isEqualToString:@"MTCameraGPUImageView"]) {
                @synchronized(self) {
                    if (![self.gpuImageRenderWeakTable containsObject:strongReciver]) {
                        [self.gpuImageRenderWeakTable addObject:strongReciver];
                    }
                }
            }
            break;
        }
    }

    NSArray *renderers = nil;
    @synchronized(self) {
        renderers = [self.gpuImageRenderWeakTable.allObjects copy];
    }
    BOOL isGPUImageViewDisplaying = NO;
    for (id renderer in renderers) {
        MTHFPSGLRenderCounter *counter = [self getDynamicAttachGLESCounter:renderer];
        if (counter.isStartRender) {
            isGPUImageViewDisplaying = YES;
            break;
        }
    }
    self.gpuImageViewDisplaying = isGPUImageViewDisplaying;

    if (!surpportedRenderer) {
        return;
    }

    for (id<MTHFPSTraceDelegate> delegate in self.delegates) {
        if (delegate && [delegate respondsToSelector:@selector(glesRenderer:fpsValueChanged:)]) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    [delegate glesRenderer:strongReciver displayStart:start];
                });
            });
        }
    }
}

- (void)glesRenderProcess:(id)reciver {
    if (reciver == nil) {
        return;
    }
    __strong typeof(reciver) strongReciver = reciver;

    NSValue *surpportedRenderer = nil;
    for (NSValue *obj in self.renderInfos) {
        MTHFPSGLRenderInfo renderInfo;
        [obj getValue:&renderInfo];
        if ([strongReciver isKindOfClass:renderInfo.rendererClass]) {
            surpportedRenderer = obj;
            break;
        }
    }

    if (!surpportedRenderer) {
        return;
    }

    MTHFPSGLRenderCounter *counter = [self getDynamicAttachGLESCounter:reciver];
    if (!counter.isStartRender) {
        return;
    }

    struct timeval lastRenderTime;
    if (!counter.lastRenderTime) {
        gettimeofday(&lastRenderTime, NULL);
        MTHSignpostStartCustom(998, counter.signpostId, 0);
        counter.lastRenderTime = [NSValue value:&lastRenderTime withObjCType:@encode(struct timeval)];
        return;
    }
    [counter.lastRenderTime getValue:&lastRenderTime];

    MTHSignpostEndCustom(998, counter.signpostId, 0, 3);
    counter.signpostId++;
    MTHSignpostStartCustom(998, counter.signpostId, 0);

    counter.renderCount++;
    struct timeval currentRenderTime;
    gettimeofday(&currentRenderTime, NULL);
    double differMs = (double)(currentRenderTime.tv_sec - lastRenderTime.tv_sec) * 1e3 + (double)(currentRenderTime.tv_usec - lastRenderTime.tv_usec) * 1e-3;
    if (differMs < 1000.f) {
        return;
    }

    if (differMs > 0) {
        NSInteger newGPUImageFPS = (NSInteger)round(counter.renderCount * 1000.f / differMs);
        if (newGPUImageFPS != self.gpuImageFPSValue) {
            for (id<MTHFPSTraceDelegate> delegate in self.delegates) {
                if (delegate && [delegate respondsToSelector:@selector(glesRenderer:fpsValueChanged:)]) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [delegate glesRenderer:strongReciver fpsValueChanged:newGPUImageFPS];
                        });
                    });
                }
            }
        }
        counter.fpsValue = newGPUImageFPS;
        self.gpuImageFPSValue = newGPUImageFPS;
    }

    counter.lastRenderTime = [NSValue value:&currentRenderTime withObjCType:@encode(struct timeval)];
    counter.renderCount = 0;
}

#pragma mark - Private
static void *MTHFPSGLRenderCounterPropertyKey = &MTHFPSGLRenderCounterPropertyKey;
id mthf_glesCounterGetter(id object, SEL _cmd1) {
    return objc_getAssociatedObject(object, MTHFPSGLRenderCounterPropertyKey);
}

void mthf_glesCounterSetter(id object, SEL _cmd1, id newValue) {
    objc_setAssociatedObject(object, MTHFPSGLRenderCounterPropertyKey, newValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (MTHFPSGLRenderCounter *)getDynamicAttachGLESCounter:(id)target {
    NSString *propertyName = @"mthGLFPSCounter";
    SEL counterSEL = NSSelectorFromString(propertyName);
    MTHFPSGLRenderCounter *counter = nil;
    if ([target respondsToSelector:counterSEL]) {
        counter = [target valueForKey:propertyName];
        if (!counter) {
            counter = [[MTHFPSGLRenderCounter alloc] init];
        }
        [target setValue:counter forKey:propertyName];
        return counter;
    }

    objc_property_attribute_t type = {"T", [[NSString stringWithFormat:@"@\"%@\"", NSStringFromClass([MTHFPSGLRenderCounter class])] UTF8String]};
    objc_property_attribute_t strong = {"&", ""};
    objc_property_attribute_t nonatomic = {"N", ""};
    objc_property_attribute_t ivarAttr = {"V", [[NSString stringWithFormat:@"_%@", propertyName] UTF8String]};
    objc_property_attribute_t attrs[] = {type, strong, nonatomic, ivarAttr};
    BOOL addCounterProperty = class_addProperty([target class], [propertyName UTF8String], attrs, 4);
    if (!addCounterProperty) {
        class_replaceProperty([target class], [propertyName UTF8String], attrs, 4);
    } else {
        class_addMethod([target class], counterSEL, (IMP)mthf_glesCounterGetter, "@@:");
        class_addMethod([target class], NSSelectorFromString(@"setMthGLFPSCounter:"), (IMP)mthf_glesCounterSetter, "v@:@");
    }

    counter = [[MTHFPSGLRenderCounter alloc] init];
    [target setValue:counter forKey:propertyName];
    return counter;
}

#pragma mark - Getter
- (void)setGpuImageRenderWeakTable:(NSHashTable *)gpuImageRenderWeakTable {
    @synchronized(self) {
        if (_gpuImageRenderWeakTable != gpuImageRenderWeakTable) {
            _gpuImageRenderWeakTable = gpuImageRenderWeakTable;
        }
    }
}

- (NSHashTable *)gpuImageRenderWeakTable {
    @synchronized(self) {
        if (_gpuImageRenderWeakTable == nil) {
            _gpuImageRenderWeakTable = [NSHashTable weakObjectsHashTable];
        }
        return _gpuImageRenderWeakTable;
    }
}

- (NSHashTable<id<MTHFPSTraceDelegate>> *)delegates {
    if (_delegates == nil) {
        _delegates = [NSHashTable weakObjectsHashTable];
    }
    return _delegates;
}

- (CADisplayLink *)displayLink {
    if (!_displayLink) {
        _displayLink = [CADisplayLink displayLinkWithTarget:[MTHawkeyeWeakProxy proxyWithTarget:self] selector:@selector(tickFPS:)];
    }
    return _displayLink;
}
@end
