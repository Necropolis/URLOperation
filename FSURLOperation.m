//
//  FSURLOperation.m
//
//  Created by Christopher Miller on 10/31/11.
//  Copyright (c) 2011 Christopher Miller. All rights reserved.
//

#import "FSURLOperation.h"

enum FSURLOperationState {
    ready,
    executing,
    cancelled,
    finished
    } FSURLOperationState;

NSString * kThreadDataExecutingRequests = @"numberOfExecutingRequests";
NSString * kThreadDataAssignedRequests = @"numberOfAssignedRequets";

#ifndef FSURLMAXTHREADS
NSUInteger FSURLMaximumWorkThreads = 16;
#else
NSUInteger FSURLMaximumWorkThreads = FSURLMAXTHREADS;
#endif

@interface FSURLOperation ()

@property (readwrite, assign) enum FSURLOperationState state;
@property (strong) NSURLConnection* connection;
@property (strong) NSSet* runLoopModes;
@property (strong) NSMutableData* dataAccumulator;


+ (NSThread*)networkRequestThread;
+ (NSMutableArray *)networkRequestThreads;
+ (NSThread *)unusedNetworkRequestThread;
- (void)finish;

@end

NSNumber * FSURLOperation__getAssignedRequestsOnThreadAsNumber(NSThread *);
NSUInteger FSURLOperation__getAssignedRequestsOnThread(NSThread *);
void FSURLOperation__setAssignedRequestsOnThread(NSThread *, NSUInteger);

NSNumber * FSURLOperation__getRequestsRunningOnThreadAsNumber(NSThread *);
NSUInteger FSURLOperation__getRequestsRunningOnThread(NSThread *);
void FSURLOperation__setRequestsRunningOnThread(NSThread *, NSUInteger);

@implementation FSURLOperation

@synthesize request;
@synthesize response;
@synthesize payload;
@synthesize error;
@synthesize targetThread;
@synthesize onFinish;

@synthesize state;
@synthesize connection;
@synthesize runLoopModes;
@synthesize dataAccumulator;

+ (FSURLOperation*)URLOperationWithRequest:(NSURLRequest*)req
                           completionBlock:(void(^)(NSHTTPURLResponse* resp, NSData* payload, NSError* error))completion
{
    FSURLOperation* operation = [[self alloc] initWithRequest:req];
    operation.onFinish = completion;
    operation.targetThread = nil;
    return operation;
}

+ (FSURLOperation*)URLOperationWithRequest:(NSURLRequest*)req
                           completionBlock:(void(^)(NSHTTPURLResponse* resp, NSData* payload, NSError* error))completion
                                  onThread:(NSThread*)thread
{
    FSURLOperation* operation = [[self alloc] initWithRequest:req];
    operation.onFinish = completion;
    if (thread)
        operation.targetThread = thread;
    else
        operation.targetThread = nil;
    
    return operation;
}

#ifdef FSURLDEBUG
+ (NSMutableSet *)debugCallbacks
{
    static NSMutableSet * _debugCallbacks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _debugCallbacks = [[NSMutableSet alloc] init];
    });
    return _debugCallbacks;
}
#endif

+ (void)networkRequestThreadEntryPoint:(id)__unused object
{
    do {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] run];
        }
    } while (YES) ;
}

+ (NSThread*)networkRequestThread
{
    static NSThread* networkReqThread = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        networkReqThread = [[NSThread alloc] initWithTarget:self selector:@selector(networkRequestThreadEntryPoint:) object:nil];
        [networkReqThread setName:@"net.fsdev.FSURLOperation-Work-Thread"];
        [networkReqThread start];
    });
    
    return networkReqThread;
}

+ (dispatch_queue_t)networkRequestThreadsMutatorLock
{
    static dispatch_queue_t lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = dispatch_queue_create("FSURLOperation Network Worker Thread Pool", DISPATCH_QUEUE_SERIAL);
    });
    return lock;
}

+ (NSMutableArray *)networkRequestThreads
{
    static NSMutableArray * networkRequestThreads;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        networkRequestThreads = [[NSMutableArray alloc] initWithCapacity:FSURLMaximumWorkThreads];
    });
    return networkRequestThreads;
}

+ (NSThread *)unusedNetworkRequestThread
{
    __block NSThread * result;
    dispatch_sync([self networkRequestThreadsMutatorLock], ^{
        NSComparator orderByExecutingRequests = ^NSComparisonResult(id obj1, id obj2) {
            NSAssert([obj1 isKindOfClass:[NSThread class]], @"Dude, this really should be a thread");
            NSAssert([obj2 isKindOfClass:[NSThread class]], @"Dude, this really should be a thread");
            return [FSURLOperation__getRequestsRunningOnThreadAsNumber(obj1) compare:FSURLOperation__getRequestsRunningOnThreadAsNumber(obj2)];
        };
        NSComparator orderByAssignedRequests = ^NSComparisonResult(id obj1, id obj2) {
            NSAssert([obj1 isKindOfClass:[NSThread class]], @"Dude, this really should be a thread");
            NSAssert([obj2 isKindOfClass:[NSThread class]], @"Dude, this really should be a thread");
            return [FSURLOperation__getAssignedRequestsOnThreadAsNumber(obj1) compare:FSURLOperation__getAssignedRequestsOnThreadAsNumber(obj2)];
        };
        NSComparator orderByExecutingThenAssignedRequests = ^NSComparisonResult(id obj1, id obj2) {
            NSComparisonResult result = orderByExecutingRequests(obj1, obj2);
            if (result == NSOrderedSame) result = orderByAssignedRequests(obj1, obj2);
            return result;
        };
        
        NSMutableArray * networkRequestThreads = [self networkRequestThreads];
        [networkRequestThreads sortUsingComparator:orderByExecutingThenAssignedRequests];
        if ([networkRequestThreads count]==0||(FSURLOperation__getRequestsRunningOnThread([networkRequestThreads objectAtIndex:0])>0&&[networkRequestThreads count]<FSURLMaximumWorkThreads)) {
            NSThread * newThread = [[NSThread alloc] initWithTarget:self selector:@selector(networkRequestThreadEntryPoint:) object:nil];
            [newThread setName:[NSString stringWithFormat:@"net.fsdev.FSURLOperation-Work-Thread.%02lu", [networkRequestThreads count]]];
            [newThread start];
            [networkRequestThreads insertObject:newThread atIndex:0];
        }
        
        NSMutableString * output = [[NSMutableString alloc] init];
        [output appendString:@"FSURLOperation Threads:\n"];
        
        for (NSThread * t in networkRequestThreads) {
            [output appendFormat:@"  %@: Assigned: %02lu Executing: %02lu\n", [t name], FSURLOperation__getAssignedRequestsOnThread(t), FSURLOperation__getRequestsRunningOnThread(t)];
        }
        [output appendString:@"\n\n\n"];
        printf("%s", [output UTF8String]);

        result = [networkRequestThreads objectAtIndex:0];
    });
    return result;
}

- (id)initWithRequest:(NSURLRequest *)_request
{
    self = [super init];
    if (self) {
        request = _request;
        self.runLoopModes = [NSSet setWithObject:NSRunLoopCommonModes];
    }
    return self;
}

- (void)finish
{
    [self willChangeValueForKey:@"isFinished"];
    self.state = finished;
#ifdef FSURLDEBUG
    for (FSURLDebugBlockCallback callback in [[self class] debugCallbacks]) callback(self.request, RequestFinished, self.response, self.payload, self.error);
#endif
    if (self.onFinish) self.onFinish(self.response, self.payload, self.error);
    dispatch_sync([[self class] networkRequestThreadsMutatorLock], ^{
        FSURLOperation__setRequestsRunningOnThread(self.targetThread, FSURLOperation__getRequestsRunningOnThread(self.targetThread)-1);
    });
    // TODO: Delegate-based callbacks
    [self didChangeValueForKey:@"isFinished"];
}

- (void)operationDidStart
{
    if ([self isCancelled]) {
        [self finish];
        return;
    }
    
    dispatch_sync([[self class] networkRequestThreadsMutatorLock], ^{
        FSURLOperation__setAssignedRequestsOnThread(self.targetThread, FSURLOperation__getAssignedRequestsOnThread(self.targetThread)-1);
        FSURLOperation__setRequestsRunningOnThread(self.targetThread, FSURLOperation__getRequestsRunningOnThread(self.targetThread)+1);
    });
    
    self.connection = [[NSURLConnection alloc] initWithRequest:self.request delegate:self startImmediately:NO];
    
    NSRunLoop* runLoop = [NSRunLoop currentRunLoop];
    for (NSString* runLoopMode in self.runLoopModes) {
        [self.connection scheduleInRunLoop:runLoop forMode:runLoopMode];
    }
    
    [self.connection start];
}

#pragma mark NSOperation

- (void)start
{
    if (![self isReady])
        return;
    
    self.state = executing;
    
#ifdef FSURLDEBUG
    for (FSURLDebugBlockCallback callback in [[self class] debugCallbacks]) callback(self.request, RequestBegan, nil, nil, nil);
#endif
    
    NSThread * freeThread = [[self class] unusedNetworkRequestThread];
    NSAssert(freeThread != nil, @"Thread is nil when it shouldn't have been.");
    self.targetThread = freeThread;
    dispatch_sync([[self class] networkRequestThreadsMutatorLock], ^{
        FSURLOperation__setAssignedRequestsOnThread(self.targetThread, FSURLOperation__getAssignedRequestsOnThread(self.targetThread)+1);
    });
    
    [self performSelector:@selector(operationDidStart) onThread:self.targetThread withObject:nil waitUntilDone:YES modes:[self.runLoopModes allObjects]];
}

- (BOOL)isConcurrent
{
    return YES;
}

- (BOOL)isExecuting
{
    return self.state == executing;
}

- (BOOL)isFinished
{
    return self.state == finished;
}

#pragma mark NSURLConnectionDelegate

- (void)       connection:(NSURLConnection*)connection
          didSendBodyData:(NSInteger)bytesWritten
        totalBytesWritten:(NSInteger)totalBytesWritten
totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    
}

- (void)connection:(NSURLConnection*)__unused conn
didReceiveResponse:(NSURLResponse *)resp
{
    self.response = (NSHTTPURLResponse*)resp;
    
    NSUInteger maxCapacity = MAX((NSUInteger)llabs(response.expectedContentLength), 1024);
    NSUInteger capacity = MIN(maxCapacity, 1024 * 1024 * 8);
    
    self.dataAccumulator = [NSMutableData dataWithCapacity:capacity];
}

- (void)connection:(NSURLConnection*)__unused conn
    didReceiveData:(NSData*)data
{
    [self.dataAccumulator appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection*)__unused conn
{
    self.payload = [NSData dataWithData:self.dataAccumulator];
    dataAccumulator = nil;
    
    [self finish];
}

- (void)connection:(NSURLConnection*)__unused conn
  didFailWithError:(NSError *)err
{
    self.error = err;
    
    self.dataAccumulator = nil;
    
    [self finish];
}

@end

NSNumber * FSURLOperation__getAssignedRequestsOnThreadAsNumber(NSThread * thread)
{
    NSNumber * n = [[thread threadDictionary] objectForKey:kThreadDataAssignedRequests];
    if (n==nil) {
        n = [NSNumber numberWithUnsignedInteger:0];
        [[thread threadDictionary] setObject:n forKey:kThreadDataAssignedRequests];
    }
    return n;
}
NSUInteger FSURLOperation__getAssignedRequestsOnThread(NSThread * thread)
{
    return [FSURLOperation__getAssignedRequestsOnThreadAsNumber(thread) unsignedIntegerValue];
}
void FSURLOperation__setAssignedRequestsOnThread(NSThread * thread, NSUInteger number)
{
    [[thread threadDictionary] setObject:[NSNumber numberWithUnsignedInteger:number] forKey:kThreadDataAssignedRequests];
}

NSNumber * FSURLOperation__getRequestsRunningOnThreadAsNumber(NSThread * thread)
{
    NSNumber * n = [[thread threadDictionary] objectForKey:kThreadDataExecutingRequests];
    if (n==nil) { 
        n = [NSNumber numberWithUnsignedInteger:0];
        [[thread threadDictionary] setObject:n forKey:kThreadDataExecutingRequests];
    }
    return n;
}
NSUInteger FSURLOperation__getRequestsRunningOnThread(NSThread * thread)
{
    return [FSURLOperation__getRequestsRunningOnThreadAsNumber(thread) unsignedIntegerValue];
}
void FSURLOperation__setRequestsRunningOnThread(NSThread * thread, NSUInteger number)
{
    [[thread threadDictionary] setObject:[NSNumber numberWithUnsignedInteger:number] forKey:kThreadDataExecutingRequests];
}
