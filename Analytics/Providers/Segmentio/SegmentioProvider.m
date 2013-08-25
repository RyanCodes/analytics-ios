// SegmentioProvider.m
// Copyright 2013 Segment.io

#import "Analytics.h"
#import "AnalyticsUtils.h"
#import "AnalyticsRequest.h"
#import "SegmentioProvider.h"

#define SEGMENTIO_API_URL [NSURL URLWithString:@"https://api.segment.io/v1/import"]
#define SEGMENTIO_MAX_BATCH_SIZE 100
#define SESSION_ID_URL AnalyticsURLForFilename(@"segmentio.sessionID")
#define DISK_QUEUE_URL AnalyticsURLForFilename(@"segmentio.queue.plist")

NSString *const SegmentioDidSendRequestNotification = @"SegmentioDidSendRequest";
NSString *const SegmentioRequestDidSucceedNotification = @"SegmentioRequestDidSucceed";
NSString *const SegmentioRequestDidFailNotification = @"SegmentioRequestDidFail";

static NSString *GetSessionID(BOOL reset) {
    // We've chosen to generate a UUID rather than use the UDID (deprecated in iOS 5),
    // identifierForVendor (iOS6 and later, can't be changed on logout),
    // or MAC address (blocked in iOS 7). For more info see https://segment.io/libraries/ios#ids
    NSURL *url = SESSION_ID_URL;
    NSString *sessionID = [[NSString alloc] initWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    if (!sessionID || reset) {
        CFUUIDRef theUUID = CFUUIDCreate(NULL);
        sessionID = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, theUUID);
        CFRelease(theUUID);
        SOLog(@"New SessionID: %@", sessionID);
        [sessionID writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return sessionID;
}

@interface SegmentioProvider ()

@property (nonatomic, weak) Analytics *analytics;
@property (nonatomic, strong) NSTimer *flushTimer;
@property (nonatomic, strong) NSMutableArray *queue;
@property (nonatomic, strong) NSArray *batch;
@property (nonatomic, strong) AnalyticsRequest *request;

@end


@implementation SegmentioProvider {
    dispatch_queue_t _serialQueue;
}

- (id)initWithAnalytics:(Analytics *)analytics {
    if (self = [self initWithSecret:analytics.secret flushAt:20 flushAfter:30]) {
        self.analytics = analytics;
    }
    return self;
}

- (id)initWithSecret:(NSString *)secret flushAt:(NSUInteger)flushAt flushAfter:(NSUInteger)flushAfter {
    NSParameterAssert(secret.length);
    NSParameterAssert(flushAt > 0);
    NSParameterAssert(flushAfter > 0);
    
    if (self = [self init]) {
        _flushAt = flushAt;
        _flushAfter = flushAfter;
        _secret = secret;
        _sessionId = GetSessionID(NO);
        _queue = [NSMutableArray arrayWithContentsOfURL:DISK_QUEUE_URL];
        if (!_queue)
            _queue = [[NSMutableArray alloc] init];
        _flushTimer = [NSTimer scheduledTimerWithTimeInterval:self.flushAfter
                                                       target:self
                                                     selector:@selector(flush)
                                                     userInfo:nil
                                                      repeats:YES];
        _serialQueue = dispatch_queue_create("io.segment.analytics.segmentio", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_serialQueue, &_serialQueue, &_serialQueue, NULL);
        self.name = @"Segment.io";
        self.valid = NO;
        self.initialized = NO;
        self.settings = [NSDictionary dictionaryWithObjectsAndKeys:secret, @"secret", nil];
        [self validate];
        self.initialized = YES;

    }
    return self;
}

- (void)dispatchBackground:(void(^)(void))block {
    [self dispatchBackground:block forceSync:NO];
}

- (void)dispatchBackground:(void(^)(void))block forceSync:(BOOL)forceSync {
    if (dispatch_get_specific(&_serialQueue)) {
        block();
    } else if (forceSync) {
        dispatch_sync(_serialQueue, block);
    } else {
        dispatch_async(_serialQueue, block);
    }
}

- (void)updateSettings:(NSDictionary *)settings {
    
}

- (void)validate {
    BOOL hasSecret = [self.settings objectForKey:@"secret"] != nil;
    self.valid = hasSecret;
}

- (NSString *)getSessionId {
    return self.sessionId;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SegmentioProvider secret:%@>", self.secret];
}


#pragma mark - Analytics API

- (void)identify:(NSString *)userId traits:(NSDictionary *)traits context:(NSDictionary *)context {
    [self dispatchBackground:^{
        self.userId = userId;
    }];

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:traits forKey:@"traits"];

    [self enqueueAction:@"identify" dictionary:dictionary context:context];
}

 - (void)track:(NSString *)event properties:(NSDictionary *)properties context:(NSDictionary *)context {
    NSAssert(event.length, @"%@ track requires an event name.", self);

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:event forKey:@"event"];
    [dictionary setValue:properties forKey:@"properties"];
    
    [self enqueueAction:@"track" dictionary:dictionary context:context];
}

- (void)alias:(NSString *)from to:(NSString *)to context:(NSDictionary *)context {
    NSAssert(from.length, @"%@ alias requires a from id.", self);
    NSAssert(to.length, @"%@ alias requires a to id.", self);

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:from forKey:@"from"];
    [dictionary setValue:to forKey:@"to"];
    
    [self enqueueAction:@"alias" dictionary:dictionary context:context];
}

#pragma mark - Queueing

- (NSDictionary *)serverContextForContext:(NSDictionary *)context {
    NSMutableDictionary *serverContext = [context ?: @{} mutableCopy];
    NSMutableDictionary *providersDict = [context[@"providers"] ?: @{} mutableCopy];
    for (AnalyticsProvider *provider in self.analytics.providers)
        if (![provider isKindOfClass:[SegmentioProvider class]])
            providersDict[provider.name] = @NO;
    serverContext[@"providers"] = providersDict;
    serverContext[@"library"] = @"analytics-ios";
    return serverContext;
    
}

- (void)enqueueAction:(NSString *)action dictionary:(NSMutableDictionary *)dictionary context:(NSDictionary *)context {
    // attach these parts of the payload outside since they are all synchronous
    // and the timestamp will be more accurate.
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:dictionary];
    payload[@"action"] = action;
    payload[@"timestamp"] = [[NSDate date] description];
    payload[@"context"] = [self serverContextForContext:context];

    [self dispatchBackground:^{
        // attach userId and sessionId inside the dispatch_async in case
        // they've changed (see identify function)
        [payload setValue:self.userId forKey:@"userId"];
        [payload setValue:self.sessionId forKey:@"sessionId"];
        
        SOLog(@"%@ Enqueueing action: %@", self, payload);
        
        [self.queue addObject:payload];
        
        [self flushQueueByLength];
    }];
}

- (void)flush {
    [self dispatchBackground:^{
        if ([self.queue count] == 0) {
            SOLog(@"%@ No queued API calls to flush.", self);
            return;
        } else if (self.request != nil) {
            SOLog(@"%@ API request already in progress, not flushing again.", self);
            NSLog(@"%@ %@", self.batch, self.request);
            return;
        } else if ([self.queue count] >= SEGMENTIO_MAX_BATCH_SIZE) {
            self.batch = [self.queue subarrayWithRange:NSMakeRange(0, SEGMENTIO_MAX_BATCH_SIZE)];
        } else {
            self.batch = [NSArray arrayWithArray:self.queue];
        }
        
        SOLog(@"%@ Flushing %lu of %lu queued API calls.", self, (unsigned long)self.batch.count, (unsigned long)self.queue.count);
        
        NSMutableDictionary *payloadDictionary = [NSMutableDictionary dictionary];
        [payloadDictionary setObject:self.secret forKey:@"secret"];
        [payloadDictionary setObject:self.batch forKey:@"batch"];
        
        NSData *payload = [NSJSONSerialization dataWithJSONObject:payloadDictionary
                                                          options:0 error:NULL];
        [self sendData:payload];
    }];
}

- (void)flushQueueByLength {
    [self dispatchBackground:^{
        SOLog(@"%@ Length is %lu.", self, (unsigned long)self.queue.count);
        if (self.request == nil && [self.queue count] >= self.flushAt) {
            [self flush];
        }
    }];
}

- (void)reset {
    [self.flushTimer invalidate];
    self.flushTimer = nil;
    self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:self.flushAfter
                                                       target:self
                                                     selector:@selector(flush)
                                                     userInfo:nil
                                                      repeats:YES];
    [self dispatchBackground:^{
        self.sessionId = GetSessionID(YES); // changes the UUID
        self.userId = nil;
        self.queue = [NSMutableArray array];
//        self.request.completion = nil;
//        self.request = nil;
    } forceSync:YES];
}

- (void)notifyForName:(NSString *)name userInfo:(id)userInfo {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:self];
        NSLog(@"sent notification %@", name);
    });
}

- (void)sendData:(NSData *)data {
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:SEGMENTIO_API_URL];
    [urlRequest setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setHTTPMethod:@"POST"];
    [urlRequest setHTTPBody:data];
    SOLog(@"%@ Sending batch API request: %@", self,
          [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    self.request = [AnalyticsRequest startWithURLRequest:urlRequest completion:^{
        [self dispatchBackground:^{
            if (self.request.error) {
                SOLog(@"%@ API request had an error: %@", self, self.request.error);
                [self notifyForName:SegmentioRequestDidFailNotification userInfo:self.batch];
            } else {
                SOLog(@"%@ API request success 200", self);
                // TODO
                // Currently we don't actively retry sending any of batched calls
                [self.queue removeObjectsInArray:self.batch];
                [self notifyForName:SegmentioRequestDidSucceedNotification userInfo:self.batch];
            }
            
            self.batch = nil;
            self.request = nil;
        }];
    }];
    [self notifyForName:SegmentioDidSendRequestNotification userInfo:self.batch];
}

- (void)applicationDidEnterBackground {
    [self flush];
}

- (void)applicationWillTerminate {
    [self flush];
    [self dispatchBackground:^{
        if (self.queue.count)
            [self.queue writeToURL:DISK_QUEUE_URL atomically:YES];
    } forceSync:YES];
}

#pragma mark - Class Methods

+ (void)load {
    [Analytics registerProvider:self withIdentifier:@"Segment.io"];
}

@end
