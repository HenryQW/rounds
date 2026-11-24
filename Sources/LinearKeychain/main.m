#import <Foundation/Foundation.h>
#import <Security/Security.h>

// Keep the protocol and identifiers in sync with LinearKey.swift.
@protocol RoundsLinearKeychain
- (void)readKeyWithReply:(void (^)(NSData *, int32_t))reply;
- (void)saveKey:(NSData *)data withReply:(void (^)(int32_t))reply;
- (void)removeKeyWithReply:(void (^)(int32_t))reply;
@end

static NSDictionary *item(void) {
    return @{
        (__bridge NSString *)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge NSString *)kSecAttrService: @"com.henryqw.rounds.linear",
        (__bridge NSString *)kSecAttrAccount: @"api-key",
    };
}

@interface LinearKeychain : NSObject <NSXPCListenerDelegate, RoundsLinearKeychain>
@end

@implementation LinearKeychain {
    dispatch_queue_t _keychain;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _keychain = dispatch_queue_create("com.henryqw.rounds.linear-keychain.items", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    if (connection.effectiveUserIdentifier != geteuid()) { return NO; }
    [connection setCodeSigningRequirement:@"identifier \"com.henryqw.rounds\" and "
        "certificate leaf = H\"981b67fc67872c2a9dd89da60aa84ed6690c62a8\" and "
        "info[\"RoundsLinearKeychainHelper\"] exists"];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RoundsLinearKeychain)];
    connection.exportedObject = self;
    [connection activate];
    return YES;
}

- (void)readKeyWithReply:(void (^)(NSData *, int32_t))reply {
    dispatch_async(_keychain, ^{
        NSMutableDictionary *query = [item() mutableCopy];
        query[(__bridge NSString *)kSecReturnData] = @YES;
        CFTypeRef data = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &data);
        reply(CFBridgingRelease(data), status);
    });
}

- (void)saveKey:(NSData *)data withReply:(void (^)(int32_t))reply {
    dispatch_async(_keychain, ^{
        if (!data.length) { reply(errSecParam); return; }
        NSDictionary *query = item();
        NSDictionary *changes = @{(__bridge NSString *)kSecValueData: data};
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)changes);
        if (status == errSecItemNotFound) {
            NSMutableDictionary *attributes = [query mutableCopy];
            [attributes addEntriesFromDictionary:changes];
            status = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
        }
        reply(status);
    });
}

- (void)removeKeyWithReply:(void (^)(int32_t))reply {
    dispatch_async(_keychain, ^{
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)item());
        reply(status == errSecItemNotFound ? errSecSuccess : status);
    });
}
@end

int main(void) {
    @autoreleasepool {
        NSXPCListener *listener = [NSXPCListener serviceListener];
        LinearKeychain *delegate = [LinearKeychain new];
        listener.delegate = delegate;
        // This call hands control of the process to the listener.
        [listener resume];
        return 1;
    }
}
