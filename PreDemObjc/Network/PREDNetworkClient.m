//
//  PREDNetworkClient.m
//  PreDemObjc
//
//  Created by WangSiyu on 21/02/2017.
//  Copyright © 2017 pre-engineering. All rights reserved.
//

#import "PREDNetworkClient.h"
#import "PREDLogger.h"

#define PREDNetMaxRetryTimes    5
#define PREDNetRetryInterval    30

NSString * const kPREDNetworkClientBoundary = @"----FOO";

@implementation PREDNetworkClient
- (void)dealloc {
    [self cancelOperationsWithPath:nil method:nil];
}

- (instancetype)initWithBaseURL:(NSURL *)baseURL {
    self = [super init];
    if ( self ) {
        NSParameterAssert(baseURL);
        _baseURL = baseURL;
    }
    return self;
}

#pragma mark - Networking
- (NSMutableURLRequest *) requestWithMethod:(NSString*) method
                                       path:(NSString *) path
                                 parameters:(NSDictionary *)params {
    NSParameterAssert(self.baseURL);
    NSParameterAssert(method);
    NSParameterAssert(params == nil || [method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]);
    path = path ? : @"";
    
    NSString* url =  [NSString stringWithFormat:@"%@%@", _baseURL, path];
    NSURL *endpoint = [NSURL URLWithString:url];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = method;
    [NSURLProtocol setProperty:@YES
                        forKey:@"PREDInternalRequest"
                     inRequest:request];
    
    if (params) {
        if ([method isEqualToString:@"GET"]) {
            NSString *absoluteURLString = [endpoint absoluteString];
            //either path already has parameters, or not
            NSString *appenderFormat = [path rangeOfString:@"?"].location == NSNotFound ? @"?%@" : @"&%@";
            
            endpoint = [NSURL URLWithString:[absoluteURLString stringByAppendingFormat:appenderFormat,
                                             [self.class queryStringFromParameters:params withEncoding:NSUTF8StringEncoding]]];
            [request setURL:endpoint];
        } else {
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-type"];
            NSError *err;
            NSData *postBody;
            postBody = [NSJSONSerialization dataWithJSONObject:params options:0 error:&err];
            [request setHTTPBody:postBody];
        }
    }
    
    return request;
}

+ (NSData *)dataWithPostValue:(NSString *)value forKey:(NSString *)key boundary:(NSString *) boundary {
    return [self dataWithPostValue:[value dataUsingEncoding:NSUTF8StringEncoding] forKey:key contentType:@"text" boundary:boundary filename:nil];
}

+ (NSData *)dataWithPostValue:(NSData *)value forKey:(NSString *)key contentType:(NSString *)contentType boundary:(NSString *) boundary filename:(NSString *)filename {
    NSMutableData *postBody = [NSMutableData data];
    
    [postBody appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    // There's certainly a better way to check if we are supposed to send binary data here.
    if (filename){
        [postBody appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", key, filename] dataUsingEncoding:NSUTF8StringEncoding]];
        [postBody appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n", contentType] dataUsingEncoding:NSUTF8StringEncoding]];
        [postBody appendData:[[NSString stringWithFormat:@"Content-Transfer-Encoding: binary\r\n\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    } else {
        [postBody appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n", key] dataUsingEncoding:NSUTF8StringEncoding]];
        [postBody appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", contentType] dataUsingEncoding:NSUTF8StringEncoding]];
    }
    
    [postBody appendData:value];
    [postBody appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    
    return postBody;
}

+ (NSString *) queryStringFromParameters:(NSDictionary *) params withEncoding:(NSStringEncoding) encoding {
    NSMutableString *queryString = [NSMutableString new];
    [params enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSString* value, BOOL *stop) {
        NSAssert([key isKindOfClass:[NSString class]], @"Query parameters can only be string-string pairs");
        NSAssert([value isKindOfClass:[NSString class]], @"Query parameters can only be string-string pairs");
        
        [queryString appendFormat:queryString.length ? @"&%@=%@" : @"%@=%@", key, value];
    }];
    return queryString;
}

- (PREDHTTPOperation*) operationWithURLRequest:(NSURLRequest*) request
                                    completion:(PREDNetworkCompletionBlock) completion {
    PREDHTTPOperation *operation = [PREDHTTPOperation operationWithRequest:request
                                    ];
    [operation setCompletion:completion];
    
    return operation;
}

- (void)getPath:(NSString *)path parameters:(NSDictionary *)params completion:(PREDNetworkCompletionBlock)completion {
    [self getPath:path parameters:params completion:completion retried:0];
}
- (void)getPath:(NSString *)path parameters:(NSDictionary *)params completion:(PREDNetworkCompletionBlock)completion retried:(NSInteger)retried {
    NSURLRequest *request = [self requestWithMethod:@"GET" path:path parameters:params];
    __weak typeof(self) wSelf = self;
    PREDHTTPOperation *op = [self operationWithURLRequest:request
                                               completion:^(PREDHTTPOperation *operation, NSData *data, NSError *error) {
                                                   if ((error || operation.response.statusCode >= 400) && retried < PREDNetMaxRetryTimes) {
                                                       PREDLogWarning(@"%@ request failed for: %@ statusCode: %ld", request.URL.absoluteString, error, (long)operation.response.statusCode);
                                                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PREDNetRetryInterval * NSEC_PER_SEC)), dispatch_get_global_queue(0, DISPATCH_QUEUE_PRIORITY_BACKGROUND), ^{
                                                           __strong typeof(wSelf) strongSelf = wSelf;
                                                           [strongSelf getPath:path parameters:params completion:completion retried:retried + 1];
                                                       });
                                                   } else {
                                                       completion(operation, data, error);
                                                   }
                                               }];
    [self enqeueHTTPOperation:op];
}

- (void)postPath:(NSString *)path parameters:(NSDictionary *)params completion:(PREDNetworkCompletionBlock)completion {
    [self postPath:path parameters:params completion:completion retried:0];
}

- (void)postPath:(NSString *)path parameters:(NSDictionary *)params completion:(PREDNetworkCompletionBlock)completion retried:(NSInteger)retried {
    NSURLRequest *request = [self requestWithMethod:@"POST" path:path parameters:params];
    __weak typeof(self) wSelf = self;
    PREDHTTPOperation *op = [self operationWithURLRequest:request
                                               completion:^(PREDHTTPOperation *operation, NSData *data, NSError *error) {
                                                   if (error && retried < PREDNetMaxRetryTimes) {
                                                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PREDNetRetryInterval * NSEC_PER_SEC)), dispatch_get_global_queue(0, DISPATCH_QUEUE_PRIORITY_BACKGROUND), ^{
                                                           __strong typeof(wSelf) strongSelf = wSelf;
                                                           [strongSelf postPath:path parameters:params completion:completion retried:retried + 1];
                                                       });
                                                   } else {
                                                       completion(operation, data, error);
                                                   }
                                               }];
    [self enqeueHTTPOperation:op];
}

- (void) postPath:(NSString*) path
             data:(NSData *) data
          headers:(NSDictionary *)headers
       completion:(PREDNetworkCompletionBlock) completion {
    [self postPath:path data:data headers:headers completion:completion retried:0];
}

- (void) postPath:(NSString*) path
             data:(NSData *) data
          headers:(NSDictionary *)headers
       completion:(PREDNetworkCompletionBlock) completion
          retried:(NSInteger)retried {
    NSString* url =  [NSString stringWithFormat:@"%@%@", _baseURL, path];
    NSURL *endpoint = [NSURL URLWithString:url];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    [NSURLProtocol setProperty:@YES
                        forKey:@"PREDInternalRequest"
                     inRequest:request];
    if (headers) {
        [headers enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
            NSAssert([key isKindOfClass:[NSString class]], @"headers can only be string-string pairs");
            NSAssert([obj isKindOfClass:[NSString class]], @"headers can only be string-string pairs");
            [request setValue:obj forHTTPHeaderField:key];
        }];
    }
    [request setHTTPBody:data];
    __weak typeof(self) wSelf = self;
    PREDHTTPOperation *op = [self operationWithURLRequest:request
                                               completion:^(PREDHTTPOperation *operation, NSData *data, NSError *error) {
                                                   if (error && retried < PREDNetMaxRetryTimes) {
                                                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PREDNetRetryInterval * NSEC_PER_SEC)), dispatch_get_global_queue(0, DISPATCH_QUEUE_PRIORITY_BACKGROUND), ^{
                                                           __strong typeof(wSelf) strongSelf = wSelf;
                                                           [strongSelf postPath:path data:data headers:headers completion:completion];
                                                       });
                                                   } else {
                                                       completion(operation, data, error);
                                                   }
                                               }];
    [self enqeueHTTPOperation:op];
}

- (void) enqeueHTTPOperation:(PREDHTTPOperation *) operation {
    [self.operationQueue addOperation:operation];
}

- (NSUInteger) cancelOperationsWithPath:(NSString*) path
                                 method:(NSString*) method {
    NSUInteger cancelledOperations = 0;
    for(PREDHTTPOperation *operation in self.operationQueue.operations) {
        NSURLRequest *request = operation.URLRequest;
        
        BOOL matchedMethod = YES;
        if(method && ![request.HTTPMethod isEqualToString:method]) {
            matchedMethod = NO;
        }
        
        BOOL matchedPath = YES;
        if(path) {
            //method is not interesting here, we' just creating it to get the URL
            NSURL *url = [self requestWithMethod:@"GET" path:path parameters:nil].URL;
            matchedPath = [request.URL isEqual:url];
        }
        
        if(matchedPath && matchedMethod) {
            ++cancelledOperations;
            [operation cancel];
        }
    }
    return cancelledOperations;
}

- (NSOperationQueue *)operationQueue {
    if(nil == _operationQueue) {
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.maxConcurrentOperationCount = 1;
    }
    return _operationQueue;
}

@end