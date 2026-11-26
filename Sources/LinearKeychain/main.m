#import <Foundation/Foundation.h>
#import <Security/Security.h>

// Keep the protocol and identifiers in sync with LinearKey.swift.
// One service for every Rounds Keychain item: the Linear key and the values of each push channel.
@protocol RoundsLinearKeychain
- (void)readItem:(NSString *)service account:(NSString *)account withReply:(void (^)(NSData *, int32_t))reply;
- (void)saveItem:(NSString *)service account:(NSString *)account data:(NSData *)data withReply:(void (^)(int32_t))reply;
- (void)removeItem:(NSString *)service account:(NSString *)account withReply:(void (^)(int32_t))reply;
@end

// Only the Rounds items: the Linear key, and one item per push channel (a lowercase channel name).
static NSDictionary *item(NSString *service, NSString *account) {
    BOOL linear = [service isEqualToString:@"com.henryqw.rounds.linear"] && [account isEqualToString:@"api-key"];
    BOOL push = [service isEqualToString:@"com.henryqw.rounds.push"] && account.length > 0 && account.length <= 32 &&
        [account rangeOfString:@"^[a-z]+$" options:NSRegularExpressionSearch].location != NSNotFound;
    if (!linear && !push) { return nil; }
    return @{
        (__bridge NSString *)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge NSString *)kSecAttrService: service,
        (__bridge NSString *)kSecAttrAccount: account,
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

- (void)readItem:(NSString *)service account:(NSString *)account withReply:(void (^)(NSData *, int32_t))reply {
    dispatch_async(_keychain, ^{
        NSMutableDictionary *query = [item(service, account) mutableCopy];
        if (!query) { reply(nil, errSecParam); return; }
        query[(__bridge NSString *)kSecReturnData] = @YES;
        CFTypeRef data = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &data);
        reply(CFBridgingRelease(data), status);
    });
}

- (void)saveItem:(NSString *)service account:(NSString *)account data:(NSData *)data withReply:(void (^)(int32_t))reply {
    dispatch_async(_keychain, ^{
        NSDictionary *query = item(service, account);
        if (!query || !data.length) { reply(errSecParam); return; }
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

- (void)removeItem:(NSString *)service account:(NSString *)account withReply:(void (^)(int32_t))reply {
    dispatch_async(_keychain, ^{
        NSDictionary *query = item(service, account);
        if (!query) { reply(errSecParam); return; }
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
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
