//
//  Origin.m
//  Origin
//
//  Created by Luka Mirosevic on 25/05/2014.
//  Copyright (c) 2014 Goonbee. All rights reserved.
//

//lm in case of server reconnection, we should resend all sub commands just to be safe, because the server might have lost all of it's currently active connects. we should listen on the zmq socket, and resend the sub command in the case of reconnect
//(lm automatic reconnection, should be handled automatically by zmq)

#import "Origin.h"

static BOOL const kDefaultShouldRunProcessorBlockOnBackgroundThread =   NO;
static NSTimeInterval const kHeartbeatInterval =                        5;// seconds

typedef enum {
    PacketTypeUnknown,
    PacketTypeSubscription,
    PacketTypeSubscriptionAck,
    PacketTypeUnsubscription,
    PacketTypeUnsubscriptionAck,
    PacketTypeUpdate,
    PacketTypeHeartbeat,
} PacketType;

@interface OriginPacket : NSObject

@property (assign, nonatomic) PacketType                                type;
@property (strong, nonatomic) id                                        model;

@end

@implementation OriginPacket

+(instancetype)packetWithData:(NSData *)data {
    //convert to json using msgpack
    NSError *error;
    NSDictionary *dictionary = [MsgPackSerialization MsgPackObjectWithData:data options:0 error:&error];
    if (error) @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"MsgPack deserialization failed with error: %@", error] userInfo:@{@"error": error}];
    
    //convert nsdictionary to object
    NSString *typeString = dictionary[@"type"];
    id model = dictionary[@"payload"];
    
    PacketType type;
    if ([typeString isEqualToString:@"subscription"]) {
        type = PacketTypeSubscription;
    }
    else if ([typeString isEqualToString:@"subscriptionAck"]) {
        type = PacketTypeSubscriptionAck;
    }
    if ([typeString isEqualToString:@"unsubscription"]) {
        type = PacketTypeUnsubscription;
    }
    else if ([typeString isEqualToString:@"unsubscriptionAck"]) {
        type = PacketTypeUnsubscriptionAck;
    }
    else if ([typeString isEqualToString:@"update"]) {
        type = PacketTypeUpdate;
    }
    else if ([typeString isEqualToString:@"heartbeat"]) {
        type = PacketTypeHeartbeat;
    }
    else {
        type = PacketTypeUnknown;
    }
    
    return [[self alloc] initWithType:type model:model];
}

-(id)initWithType:(PacketType)type model:(id)model {
    if (self = [self init]) {
        self.type = type;
        self.model = model;
    }
    
    return self;
}

-(NSData *)dataRepresentation {
    //create a dictionary
    NSString *typeString;
    switch (self.type) {
        case PacketTypeSubscription: {
            typeString = @"subscription";
        } break;
            
        case PacketTypeSubscriptionAck: {
            typeString = @"subscriptionAck";
        } break;
            
        case PacketTypeUnsubscription: {
            typeString = @"unsubscription";
        } break;
            
        case PacketTypeUnsubscriptionAck: {
            typeString = @"unsubscriptionAck";
        } break;
            
        case PacketTypeUpdate: {
            typeString = @"update";
        } break;
            
        case PacketTypeHeartbeat: {
            typeString = @"heartbeat";
        } break;
            
        case PacketTypeUnknown: {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot serialize packet of unknown type" userInfo:nil];
        } break;
    }
    
    NSDictionary *dictionary = @{
        @"type": typeString,
        @"payload": self.model ?: @{},// if there's no model then make it an empty dictionary as a failsafe
    };
    
    //convert to data from dictionary with msgpack
    NSError *error;
    NSData *data = [MsgPackSerialization dataWithMsgPackObject:dictionary options:0 error:&error];
    if (error) @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"MsgPack serialization failed with error: %@", error] userInfo:@{@"error": error}];
    
    return data;
}

@end

@interface Origin ()

@property (copy, nonatomic) OriginDeserializerBlock                     defaultDeserializer;
@property (strong, nonatomic) NSMutableDictionary                       *channelDeserializers;
@property (strong, nonatomic) NSMutableDictionary                       *channelUpdateBlocks;
@property (strong, nonatomic) NSMutableDictionary                       *channelSubscriptionBlocks;
@property (strong, nonatomic) NSMutableSet                              *subscribedChannels;
@property (strong, nonatomic) NSMutableSet                              *subscribedChannelsOptimistic;
@property (strong, nonatomic) dispatch_queue_t                          processorQueue;
@property (strong, nonatomic) NSMutableDictionary                       *cache;
@property (strong, nonatomic) NSTimer                                   *heartbeatTimer;

@end

@implementation Origin

+(instancetype)sharedOrigin {
    static Origin *_sharedOrigin;
    @synchronized(self) {
        if (!_sharedOrigin) {
            _sharedOrigin = [self.class new];
        }
    }
    
    return _sharedOrigin;
}

-(id)init {
    if (self = [super init]) {
        self.channelDeserializers = [NSMutableDictionary new];
        self.channelUpdateBlocks = [NSMutableDictionary new];
        self.channelSubscriptionBlocks = [NSMutableDictionary new];
        self.subscribedChannels = [NSMutableSet new];
        self.subscribedChannelsOptimistic = [NSMutableSet new];
        self.shouldRunProcessorBlockOnBackgroundThread = kDefaultShouldRunProcessorBlockOnBackgroundThread;
        self.processorQueue = dispatch_queue_create("com.goonbee.origin.processorQueue", DISPATCH_QUEUE_CONCURRENT);
        self.cache = [NSMutableDictionary new];
    }
    
    return self;
}

-(void)dealloc {
    [self _stopHeartbeatTimer];
    [self _disconnectFromServer];
}

#pragma mark - API

-(void)connectToServer:(NSString *)server port:(NSUInteger)port {
    if (!server || !([server isKindOfClass:NSString.class] && server.length > 0)) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Server must be a non-empty string." userInfo:nil];
    if (!(port >= 1 || port <= 65535)) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Post must be a valid port between 1 and 65535." userInfo:nil];
    
    [self _connectToServer:server port:port];
    [self _startHeartbeatTimer];
}

-(void)subscribeToChannel:(NSString *)channel {
    [self subscribeToChannel:channel block:nil];
}

-(void)subscribeToChannel:(NSString *)channel block:(OriginChannelSubscriptionBlock)block {
    [self.class _validateChannel:channel];
    
    // send the subscription packet off
    [self _sendSubscriptionRequestForChannel:channel];
    
    // lazy creation of subscription blocks container set for the channel
    if (!self.channelSubscriptionBlocks[channel]) {
        self.channelSubscriptionBlocks[channel] = [NSMutableSet new];
    }
    
    // store the block
    [self.channelSubscriptionBlocks[channel] addObject:[block copy]];
    
    // bookkeeping
    [self.subscribedChannelsOptimistic addObject:channel];
}

-(void)unsubscribeFromChannel:(NSString *)channel {
    [self.class _validateChannel:channel];
    
    // send the unsubscription packet off
    [self _sendUnsubscriptionRequestForChannel:channel];
    
    // process the subscription in flight blocks
    [self _processAllSubscriptionBlocksForChannel:channel withMessage:self.cache[channel] cancelled:YES];
    
    // immediately remove all subscription and update blocks
    [self.channelSubscriptionBlocks removeObjectForKey:channel];
    [self.channelUpdateBlocks removeObjectForKey:channel];
    
    // bookkeeping
    [self.subscribedChannelsOptimistic removeObject:channel];// this has the dual purpose of setting up a kind of synchronization barrier, update and subscription callbacks will check this value to make sure the channel is still subscribed to
    [self.subscribedChannels removeObject:channel];
    
    // clear the cache
    [self.cache removeObjectForKey:channel];
}

-(void)addUpdateHandlerForChannel:(NSString *)channel block:(OriginValueBlock)block {
    [self.class _validateChannel:channel];
    if (!block) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Block must not be nil." userInfo:nil];
    
    // lazy creation of update blocks container set for the channel
    if (!self.channelUpdateBlocks[channel]) {
        self.channelUpdateBlocks[channel] = [NSMutableSet new];
    }
    
    // store the block
    [self.channelUpdateBlocks[channel] addObject:[block copy]];
}

-(void)removeUpdateHandlerForChannel:(NSString *)channel block:(OriginValueBlock)block {
    [self.channelUpdateBlocks[channel] removeObject:block];
}

-(void)removeAllUpdateHandlerForChannel:(NSString *)channel {
    [self.channelUpdateBlocks[channel] removeAllObjects];
}

-(void)currentValueForChannel:(NSString *)channel block:(OriginValueBlock)block {
    [self.class _validateChannel:channel];
    if (!block) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Block must not be nil." userInfo:nil];
    
    // try and get the cached value
    NSData *data = self.cache[channel];
    // process it
    [self _processDataForChannel:channel message:data block:^(id object) {
        // pass it back to the caller
        block(channel, data, object);
    }];
}

-(BOOL)isSubscribedToChannel:(NSString *)channel {
    [self.class _validateChannel:channel];
    
    return [self.subscribedChannels containsObject:channel];
}

-(BOOL)isSubscribedToChannelOptimistically:(NSString *)channel {
    [self.class _validateChannel:channel];
    
    return [self.subscribedChannelsOptimistic containsObject:channel];
}

-(void)setDeserializerForChannel:(NSString *)channel deserializerBlock:(OriginDeserializerBlock)deserializerBlock {
    [self.class _validateChannel:channel];
    if (!deserializerBlock) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Deserializer block must not be nil." userInfo:nil];
    
    // just remember the deserializer
    self.channelDeserializers[channel] = [deserializerBlock copy];
}

-(void)removeDeserializerForChannel:(NSString *)channel {
    [self.class _validateChannel:channel];
    
    // just remove the deserializer
    [self.channelDeserializers removeObjectForKey:channel];
}

-(void)setDefaultDeserializer:(OriginDeserializerBlock)deserializerBlock {
    if (!deserializerBlock) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Deserializer block must not be nil." userInfo:nil];
    
    self.defaultDeserializer = deserializerBlock;// block gets copied onto heap automaticaly by setter
}

-(void)removeDefaultDeserializer {
    self.defaultDeserializer = nil;
}

#pragma mark - Util

+(void)_validateChannel:(NSString *)channel {
    if (!channel || !([channel isKindOfClass:NSString.class] && channel.length > 0)) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Channel must be a non-empty string." userInfo:nil];
}

-(void)_processAllSubscriptionBlocksForChannel:(NSString *)channel withMessage:(NSData *)data cancelled:(BOOL)cancelled {
    // make sure we have some blocks
    if ([self.channelSubscriptionBlocks[channel] count] > 0) {
        // process the data first
        [self _processDataForChannel:channel message:data block:^(id object) {
            // make sure we're still subscribed (or we're in the process of cancelling)
            if ([self isSubscribedToChannelOptimistically:channel] || cancelled) {
                // now run through the handlers and pipe the data through
                for (OriginChannelSubscriptionBlock block in self.channelSubscriptionBlocks[channel]) {
                    block(channel, data, object, cancelled);
                }
            }
        }];
    }
}

-(void)_processAllUpdateBlocksForChannel:(NSString *)channel withMessage:(id)message {
    // make sure we have some blocks
    if ([self.channelUpdateBlocks[channel] count] > 0) {
        // process the data first
        [self _processDataForChannel:channel message:message block:^(id object) {
            // make sure we're still subscribed
            if ([self isSubscribedToChannelOptimistically:channel]) {
                // now run through the handlers and pipe the message through
                for (OriginValueBlock block in self.channelUpdateBlocks[channel]) {
                    block(channel, message, object);
                }
            }
        }];
    }
}

-(void)_processDataForChannel:(NSString *)channel message:(id)message block:(void(^)(id object))block {
    // first get the relevant processor
    OriginDeserializerBlock processor;
    if (self.channelDeserializers[channel]) {
        processor = self.channelDeserializers[channel];
    }
    else if (self.defaultDeserializer) {
        processor = self.defaultDeserializer;
    }
    
    if (!processor) {
        // just send the message straight through
        block(message);
    }
    else {
        // run it on the FG thread
        if (!self.shouldRunProcessorBlockOnBackgroundThread) {
            block(processor(message));
        }
        // run it on the BG thread
        else {
            // process on BG thread
            dispatch_async(self.processorQueue, ^{
                id object = processor(message);
                
                // send it back on FG thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    block(object);
                });
            });
        }
    }
}

-(void)_successfullySubscribedToChannel:(NSString *)channel withInitialMessage:(id)message {
    // make sure it's not cancelled yet
    if ([self isSubscribedToChannelOptimistically:channel]) {
        // cache the data
        self.cache[channel] = message;
    
        // bookkeeping
        [self.subscribedChannels addObject:channel];
        
        // fire the subscription handlers
        [self _processAllSubscriptionBlocksForChannel:channel withMessage:message cancelled:NO];
    }
}

-(void)_receivedChannelUpdateForChannel:(NSString *)channel message:(id)message {
    // cache the data
    self.cache[channel] = message;
    
    // fire the update handlers
    [self _processAllUpdateBlocksForChannel:channel withMessage:message];
}

-(void)_startHeartbeatTimer {
    // clear any potential old one
    [self _stopHeartbeatTimer];
    
    // create and schedule a new one
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:kHeartbeatInterval target:self selector:@selector(_sendHeartbeatToServer) userInfo:nil repeats:YES];
}

-(void)_stopHeartbeatTimer {
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
}

#pragma mark - Util:Networking

-(void)_connectToServer:(NSString *)server port:(NSUInteger)port {
    //lm TODO
}

-(void)_disconnectFromServer {
    //lm TODO
}

-(void)_sendHeartbeatToServer {
    OriginPacket *heartbeat = [[OriginPacket alloc] initWithType:PacketTypeHeartbeat model:nil];
    
    [self _sendPacketToServer:heartbeat];
}

-(void)_sendSubscriptionRequestForChannel:(NSString *)channel {
    OriginPacket *subscription = [[OriginPacket alloc] initWithType:PacketTypeSubscription model:@{@"channel": channel}];

    [self _sendPacketToServer:subscription];
}

-(void)_sendUnsubscriptionRequestForChannel:(NSString *)channel {
    OriginPacket *unsubscription = [[OriginPacket alloc] initWithType:PacketTypeUnsubscription model:@{@"channel": channel}];

    [self _sendPacketToServer:unsubscription];
}

-(void)_processReceivedPacket:(OriginPacket *)packet {
    switch (packet.type) {
        case PacketTypeSubscription:
        case PacketTypeUnsubscription:
        case PacketTypeHeartbeat:
        case PacketTypeUnsubscriptionAck:
        case PacketTypeUnknown: {
            //noop
        } break;
            
        case PacketTypeSubscriptionAck: {
            NSDictionary *model = packet.model;
            NSString *channel = model[@"channel"];
            id message = model[@"message"];
            
            [self _successfullySubscribedToChannel:channel withInitialMessage:message];
        } break;
            
        case PacketTypeUpdate: {
            NSDictionary *model = packet.model;
            NSString *channel = model[@"channel"];
            id message = model[@"message"];
            
            [self _receivedChannelUpdateForChannel:channel message:message];
        } break;
    }
}

-(void)_sendPacketToServer:(OriginPacket *)packet {
    // serialize it
    NSData *serializedPacket = [packet dataRepresentation];
    
    // send it off
    //lm todo
}

-(void)_receiveDataFromServer:(NSData *)data {
    OriginPacket *packet = [OriginPacket packetWithData:data];
    
    [self _processReceivedPacket:packet];
}

@end

//message format


//    Packet: {
//        type: String:MessageType,
//        payload: _
//    }
//
//
//    #Models
//
//    // client -> server
//    Subscription: {
//        channel: String
//    }
//
//    // client <- server
//    SubscriptionAck: {
//        channel: String,
//        message: _
//    }
//
//    // client -> server
//    Unsubscription: {
//        channel: String
//    }
//
//    // client <- server
//    UnsubscriptionAck: {
//        channel: String
//    }
//
//    // client <- server
//    Update: {
//        channel: String,
//        message: _
//    }
//
//    // client <-> server
//    Heartbeat: String
//
//

