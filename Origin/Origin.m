//
//  Origin.m
//  Origin
//
//  Created by Luka Mirosevic on 25/05/2014.
//  Copyright (c) 2014 Goonbee. All rights reserved.
//

#import "Origin.h"

#import <MessagePack/MessagePack.h>
#import "zmq.h"

static BOOL const kDefaultShouldRunProcessorBlockOnBackgroundThread =   NO;
static NSTimeInterval const kHeartbeatEmissionInterval =                10;// seconds. The period when heartbeats are emitted.
static NSTimeInterval const kServerHeartbeatMonitorInterval =           1;// seconds. The time period when a TTL exceedance is checked.
static NSTimeInterval const kServerHeartbeatTTL =                       30;// seconds. The period of silence after which we consider the server dead.
static NSTimeInterval const kReconnectionInterval =                     3;// seconds. Time to wait before retrying the initial server connection again.

static NSString * const kInprocEndpointName =                           @"internalProxy";// used for sending messages between threads

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
@property (strong, nonatomic) id                                        payload;

@end

@implementation OriginPacket

+(instancetype)packetWithData:(NSData *)data {
    //convert to json using msgpack
    NSDictionary *dictionary = [MessagePackParser parseData:data];
    if (!dictionary) @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"MsgPack deserialization failed" userInfo:nil];
    
    //convert nsdictionary to object
    NSString *typeString = dictionary[@"type"];
    id payload = dictionary[@"payload"];
    
    PacketType type;
    if ([typeString isEqualToString:@"subscription"]) {
        type = PacketTypeSubscription;
    }
    else if ([typeString isEqualToString:@"subscriptionAck"]) {
        type = PacketTypeSubscriptionAck;
    }
    else if ([typeString isEqualToString:@"unsubscription"]) {
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
    
    return [[self alloc] initWithType:type payload:payload];
}

-(id)initWithType:(PacketType)type payload:(id)payload {
    if (self = [self init]) {
        self.type = type;
        self.payload = payload;
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
        @"payload": self.payload ?: @{},// if there's no payload then make it an empty dictionary as a failsafe
    };
    
    // convert to data from dictionary with msgpack
    NSData *data = [MessagePackPacker pack:dictionary];
    if (!data) @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"MsgPack serialization failed" userInfo:nil];
    
    return data;
}

@end

@interface Origin ()

@property (copy, nonatomic) OriginDeserializerBlock                     myDefaultDeserializer;
@property (strong, nonatomic) NSMutableDictionary                       *channelDeserializers;
@property (strong, nonatomic) NSMutableDictionary                       *channelUpdateBlocks;
@property (strong, nonatomic) NSMutableSet                              *subscribedChannels;
@property (strong, nonatomic) NSMutableSet                              *subscribedChannelsOptimistic;
@property (strong, nonatomic) dispatch_queue_t                          processorQueue;
@property (strong, nonatomic) NSMutableDictionary                       *cache;

@property (strong, nonatomic) NSTimer                                   *clientHeartbeatEmitterTimer;

@property (strong, nonatomic) NSTimer                                   *serverHeartbeatMonitorTimer;
@property (strong, nonatomic) NSDate                                    *dateLastServerHeartbeatReceived;

@property (assign, nonatomic) BOOL                                      canSendPlumbingPacket;

@property (assign, nonatomic, readwrite) BOOL                           isConnected;

@property (copy, atomic) NSString                                       *server;
@property (assign, atomic) NSUInteger                                   port;

@property (strong, atomic) NSThread                                     *backgroundThread;

@property (assign, nonatomic) void                                      *context;
@property (assign, nonatomic) void                                      *dealerSocketBackground;
@property (assign, nonatomic) void                                      *pairSocketMain;
@property (assign, nonatomic) void                                      *pairSocketBackground;

@property (assign, nonatomic) BOOL                                      dealerConnected;
@property (assign, nonatomic) BOOL                                      pairBound;

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
        self.subscribedChannels = [NSMutableSet new];
        self.subscribedChannelsOptimistic = [NSMutableSet new];
        self.shouldRunProcessorBlocksOnBackgroundThread = kDefaultShouldRunProcessorBlockOnBackgroundThread;
        self.processorQueue = dispatch_queue_create("com.goonbee.origin.processorQueue", DISPATCH_QUEUE_CONCURRENT);
        self.cache = [NSMutableDictionary new];
    }
    
    return self;
}

-(void)dealloc {
    [self _stopClientHeartbeatEmitterTimer];
    [self _stopServerHeartbeatMonitorTimer];
    [self _disconnectFromServer];
}

#pragma mark - API

-(void)connectToServer:(NSString *)server port:(NSUInteger)port {
    if (!self.isConnected) {
        if (!server || !([server isKindOfClass:NSString.class] && server.length > 0)) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Server must be a non-empty string." userInfo:nil];
        if (!(port >= 1 || port <= 65535)) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Post must be a valid port between 1 and 65535." userInfo:nil];
        
        // remember that we are connected to that we don't run this method more than once.
        self.isConnected = YES;
        
        // store our settings
        self.server = server;
        self.port = port;
        
        // set up the stuff on the main thread
        [self _createZMQContext];
        [self _setupForegroundGateway];
        
        // set up the background stuff
        self.backgroundThread = [[NSThread alloc] initWithTarget:self selector:@selector(_setupBackgroundMachine) object:nil];
        [self.backgroundThread start];
        
        // start the heartbeat stuff
        [self _startClientHeartbeatEmitterTimer];
        [self _startServerHeartbeatMonitorTimer];
    }
    else {
        NSLog(@"Origin is already connected. Skipping operation...");
    }
}

-(void)subscribeToChannel:(NSString *)channel withBlock:(OriginChannelUpdateBlock)block {
    [self.class _validateChannel:channel];

    // add this block to the listeners for this channel
    [self _addBlock:block forChannel:channel];
    
    // if we're subscribed properly, then immediately respond with a LCV
    if ([self.subscribedChannels containsObject:channel]) {
        [self _callUpateBlock:block onChannel:channel withUnsubscribedState:NO];
    }
    // if we're subscribed tentatively, then do nothing
    else if ([self.subscribedChannelsOptimistic containsObject:channel]) {
        //noop
    }
    // otherwise, we need to trigger a subscription on the server
    else {
        // subscribe with the server on a particular channel
        [self _sendSubscriptionRequestForChannel:channel];
        
        // bookkeeping
        [self.subscribedChannelsOptimistic addObject:channel];
    }
}

-(void)unsubscribeFromChannel:(NSString *)channel withBlock:(OriginChannelUpdateBlock)block {
    [self.class _validateChannel:channel];
    
    // call the block one last time to let him know we're unsubscribing
    [self _callUpateBlock:block onChannel:channel withUnsubscribedState:YES];
    
    // remove the update block
    BOOL noMoreListeners = [self _removeBlock:block forChannel:channel];
    
    // if this was the last listener, we need to clean up
    if (noMoreListeners) {
        [self _cleanUpForChannel:channel];
    }
}

-(void)unsubscribeAllBlocksFromChannel:(NSString *)channel {
    [self _cleanUpForChannel:channel];
}

-(void)currentValueForChannel:(NSString *)channel block:(OriginChannelUpdateBlock)block {
    [self.class _validateChannel:channel];
    if (!block) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Block must not be nil." userInfo:nil];
    
    // try and get the cached value
    NSData *data = self.cache[channel];
    // process it
    [self _processDataForChannel:channel message:data block:^(id object) {
        // pass it back to the caller
        block(channel, data, object, NO);
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
    
    self.myDefaultDeserializer = deserializerBlock;// block gets copied onto heap automaticaly by setter
}

-(void)removeDefaultDeserializer {
    self.myDefaultDeserializer = nil;
}

#pragma mark - Util

+(void)_validateChannel:(NSString *)channel {
    if (!channel || !([channel isKindOfClass:NSString.class] && channel.length > 0)) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Channel must be a non-empty string." userInfo:nil];
}

-(void)_addBlock:(id)block forChannel:(NSString *)channel {
    // lazy creation of container for channel subscription blocks
    if (!self.channelUpdateBlocks[channel]) {
        self.channelUpdateBlocks[channel] = [NSMutableOrderedSet new];
    }
    
    // store the block
    if (block) [self.channelUpdateBlocks[channel] addObject:[block copy]];
};

-(BOOL)_removeBlock:(id)block forChannel:(NSString *)channel {
    if (block) [self.channelUpdateBlocks[channel] removeObject:block];
    
    return ([self.channelUpdateBlocks[channel] count] == 0);// returns YES if this was the last block
}

-(void)_removeAllBlocksForChannel:(NSString *)channel {
    // this removes the set inside, which removes all blocks. it's ok since it's lazy in there
    [self.channelUpdateBlocks removeObjectForKey:channel];
}

-(void)_callUpateBlock:(OriginChannelUpdateBlock)block onChannel:(NSString *)channel withUnsubscribedState:(BOOL)unsubscribed {
    if (block) {
        id cachedValue = self.cache[channel];
        [self _processDataForChannel:channel message:cachedValue block:^(id object) {
            block(channel, cachedValue, object, unsubscribed);
        }];
    }
}

-(void)_cleanUpForChannel:(NSString *)channel {
    // bookkeeping
    [self.subscribedChannelsOptimistic removeObject:channel];// this has the dual purpose of setting up a kind of synchronization barrier, as update callbacks will check this value to make sure the channel is still subscribed to before firing
    [self.subscribedChannels removeObject:channel];
    
    // notify our listeners
    [self _processAllUpdateBlocksForChannel:channel withMessage:self.cache[channel] unsubscribed:YES];
    
    // clear the cache
    [self.cache removeObjectForKey:channel];
    
    // tell the server we are no longer intersted
    [self _sendUnsubscriptionRequestForChannel:channel];
}

-(void)_processAllUpdateBlocksForChannel:(NSString *)channel withMessage:(id)message unsubscribed:(BOOL)unsubscribed {
    // make sure we have some blocks
    if ([self.channelUpdateBlocks[channel] count] > 0) {
        // process the data first
        [self _processDataForChannel:channel message:message block:^(id object) {
            // make sure we're still subscribed, or we're unsubscribing now
            if ([self isSubscribedToChannelOptimistically:channel] || unsubscribed) {
                // now run through the handlers and pipe the message through
                for (OriginChannelUpdateBlock block in self.channelUpdateBlocks[channel]) {
                    block(channel, message, object, unsubscribed);
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
    else if (self.myDefaultDeserializer) {
        processor = self.myDefaultDeserializer;
    }
    
    if (!processor) {
        // just send the message straight through
        block(message);
    }
    else {
        // run it on the FG thread
        if (!self.shouldRunProcessorBlocksOnBackgroundThread) {
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
        if (message) {
            self.cache[channel] = message;
        }
    
        // bookkeeping
        [self.subscribedChannels addObject:channel];
        
        // fire the subscription handlers
        [self _processAllUpdateBlocksForChannel:channel withMessage:message unsubscribed:NO];
    }
}

-(void)_receivedChannelUpdateForChannel:(NSString *)channel message:(id)message {
    if (message) {
        // cache the data
        self.cache[channel] = message;
    }
    
    // fire the update handlers
    [self _processAllUpdateBlocksForChannel:channel withMessage:message unsubscribed:NO];
}

-(void)_startClientHeartbeatEmitterTimer {
    // clear any potential old one
    [self _stopClientHeartbeatEmitterTimer];
    
    // create and schedule a new one
    self.clientHeartbeatEmitterTimer = [NSTimer scheduledTimerWithTimeInterval:kHeartbeatEmissionInterval target:self selector:@selector(_sendHeartbeatToServer) userInfo:nil repeats:YES];
}

-(void)_stopClientHeartbeatEmitterTimer {
    [self.clientHeartbeatEmitterTimer invalidate];
    self.clientHeartbeatEmitterTimer = nil;
}

-(void)_startServerHeartbeatMonitorTimer {
    // stop the old one if we had one
    [self _stopServerHeartbeatMonitorTimer];
    
    // set the current time
    [self _resetServerHeartbeatTTL];
    
    // create and schedule a new one
    self.serverHeartbeatMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:kServerHeartbeatMonitorInterval target:self selector:@selector(_checkHeartbeatFromServer) userInfo:nil repeats:YES];
}

-(void)_stopServerHeartbeatMonitorTimer {
    [self.serverHeartbeatMonitorTimer invalidate];
    self.serverHeartbeatMonitorTimer = nil;
}

-(void)_resetServerHeartbeatTTL {
    self.dateLastServerHeartbeatReceived = [NSDate date];
}

-(void)_lockPlumbingSending {
    self.canSendPlumbingPacket = NO;
}

-(void)_unlockPlumbingSending {
    self.canSendPlumbingPacket = YES;
}

-(BOOL)_isPlumbingSendingUnlocked {
    return self.canSendPlumbingPacket;
}

#pragma mark - Util:Networking

-(void)_sendHeartbeatToServer {
    if ([self _isPlumbingSendingUnlocked]) {
        OriginPacket *heartbeat = [[OriginPacket alloc] initWithType:PacketTypeHeartbeat payload:nil];
        
        [self _sendPacketToServer:heartbeat];
    }
}

-(void)_checkHeartbeatFromServer {
    // get current date
    NSDate *currentDate = [NSDate date];

    // see when we got the last heartbeat
    NSTimeInterval timeElapsedSinceLastHeartbeat = [currentDate timeIntervalSinceDate:self.dateLastServerHeartbeatReceived];
    
    // check to see if we haven't heard from the server in a while and consider it dead, but make sure we only send a single resub per death
    if (timeElapsedSinceLastHeartbeat > kServerHeartbeatTTL && [self _isPlumbingSendingUnlocked]) {
        // if so trigger a resub on all channels
        [self _resubscribeOnAllChannels];
        
        // and reset the server heartbeat TTL
        [self _resetServerHeartbeatTTL];
        
        // lock the resubscriptions so we don't send them again until we're resurrected
        [self _lockPlumbingSending];
    }
}

-(void)_resubscribeOnAllChannels {
    // send a subscription request to all channels which the user has the intention of being subscribed to
    for (NSString *channel in self.subscribedChannelsOptimistic) {
        [self _sendSubscriptionRequestForChannel:channel];
    }
}

-(void)_sendSubscriptionRequestForChannel:(NSString *)channel {
    OriginPacket *subscription = [[OriginPacket alloc] initWithType:PacketTypeSubscription payload:@{@"channel": channel}];

    [self _sendPacketToServer:subscription];
}

-(void)_sendUnsubscriptionRequestForChannel:(NSString *)channel {
    OriginPacket *unsubscription = [[OriginPacket alloc] initWithType:PacketTypeUnsubscription payload:@{@"channel": channel}];

    [self _sendPacketToServer:unsubscription];
}

-(void)_processReceivedPacket:(OriginPacket *)packet {
    // we treat all packets as heartbeats
    [self _resetServerHeartbeatTTL];
    
    // the server is now considered alive, so in case of death we can now send a resub
    [self _unlockPlumbingSending];
    
    // process the packet
    switch (packet.type) {
        case PacketTypeSubscription:
        case PacketTypeUnsubscription:
        case PacketTypeHeartbeat:
        case PacketTypeUnsubscriptionAck:
        case PacketTypeUnknown: {
            //noop
        } break;
            
        case PacketTypeSubscriptionAck: {
            NSDictionary *payload = packet.payload;
            NSString *channel = payload[@"channel"];
            id message = payload[@"message"];
            
            [self _successfullySubscribedToChannel:channel withInitialMessage:message];
        } break;
            
        case PacketTypeUpdate: {
            NSDictionary *model = packet.payload;
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
    [self _sendDataToInprocSocket:serializedPacket];
}

-(void)_receivedDataFromServer:(NSData *)data {
    OriginPacket *packet = [OriginPacket packetWithData:data];
    
    [self _processReceivedPacket:packet];
}

#pragma mark - Util:ZMQ

-(void)_setupForegroundGateway {
    [self _connectMainPairSocketToBackgroundPairSocketOnInprocEndpoint:kInprocEndpointName];
}

-(void)_setupBackgroundMachine {
    @autoreleasepool {
        while (YES) {
            // Setup
            if (!self.dealerConnected) self.dealerConnected = [self _connectDealerSocketToServer:self.server port:self.port];
            if (!self.pairBound) self.pairBound = [self _bindPairSocketToInprocEndpoint:kInprocEndpointName];
            
            // make sure they're both up, otherwise loop, with a while and sleep
            if (self.dealerConnected && self.pairBound) {
                [self _startMessageListenerLoop];
                
                // we got our first aliveness, so unlock resub sending
                [self _unlockPlumbingSending];
            }
            else {
                usleep(kReconnectionInterval * 1000000);
                continue;
            }
        }
    }
}

-(BOOL)_connectDealerSocketToServer:(NSString *)server port:(NSUInteger)port {
    // Connect the DEALER socket to the server
    self.dealerSocketBackground = zmq_socket(self.context, ZMQ_DEALER);
    const char *endpoint = [[NSString stringWithFormat:@"tcp://%@:%ld", server, (unsigned long)port] UTF8String];
    int rc = zmq_connect(self.dealerSocketBackground, endpoint);
    return (rc == 0);
}

-(BOOL)_bindPairSocketToInprocEndpoint:(NSString *)inprocEndpoint {
    // Bind the inproc PAIR socket on the known endpoint, so we can message it from other threads
    self.pairSocketBackground = zmq_socket(self.context, ZMQ_PAIR);
    int rc = zmq_bind(self.pairSocketBackground, [[NSString stringWithFormat:@"inproc://%@", inprocEndpoint] UTF8String]);
    return (rc == 0);
}

-(void)_startMessageListenerLoop {
    //  Process messages from both sockets
    while (true) {
        zmq_pollitem_t items [] = {
            { self.pairSocketBackground,   0, ZMQ_POLLIN, 0 },
            { self.dealerSocketBackground, 0, ZMQ_POLLIN, 0 }
        };
        zmq_poll(items, 2, -1);
        
        
        // Incoming message from main thread on the PAIR socket
        if (items[0].revents & ZMQ_POLLIN) {
            int err;
            
            // Read the message from the PAIR socket
            zmq_msg_t incomingMessage;
            err = zmq_msg_init(&incomingMessage);
            if (err) {
                NSLog(@"something whent wrong creating msg");
            };
            
            err = zmq_recvmsg(self.pairSocketBackground, &incomingMessage, 0);
            if (err == -1) {
                NSLog(@"something whent wrong receiving");
                
                err = zmq_msg_close(&incomingMessage);
                if (err) {
                    NSLog(@"something went wrong closing the message");
                }
                
                // if the context got destroyed, clean ourselves up
                if (errno == ETERM) {
                    NSLog(@"going down, close background thread");
                    break;// break out of the while loop, so we can reach the socket closing code
                }
            }

            // Send the raw message on the DEALER socket
            err = zmq_sendmsg(self.dealerSocketBackground, &incomingMessage, 0);
            if (err == -1) {
                NSLog(@"something went wrong passing message on to dealer");
            }
            
            // Close the message
            err = zmq_msg_close(&incomingMessage);
            if (err) {
                NSLog(@"could not close the msg");
            }
        }
        
        // Incoming messages from the server on the DEALER socket
        if (items [1].revents & ZMQ_POLLIN) {
            NSData *incomingData = [self _readDataFromZMQSocket:self.dealerSocketBackground];
            
            [self performSelectorOnMainThread:@selector(_receivedDataFromServer:) withObject:incomingData waitUntilDone:NO];
        }
    }
    
    // close the BG sockets
    zmq_close(self.dealerSocketBackground);
    zmq_close(self.pairSocketBackground);
}

-(void)_connectMainPairSocketToBackgroundPairSocketOnInprocEndpoint:(NSString *)inprocEndpoint {
    self.pairSocketMain = zmq_socket(self.context, ZMQ_PAIR);
    int rc = zmq_connect(self.pairSocketMain, [[NSString stringWithFormat:@"inproc://%@", inprocEndpoint] UTF8String]);
    assert (rc == 0);
}

-(void)_sendDataToInprocSocket:(NSData *)data {
	zmq_msg_t message;
	int err = zmq_msg_init_size(&message, [data length]);
	if (err) {
        NSLog(@"could not make msg");
	}
    
	[data getBytes:zmq_msg_data(&message) length:zmq_msg_size(&message)];

	err = zmq_sendmsg(self.pairSocketMain, &message, 0);
	BOOL didSendData = (-1 != err);
	if (!didSendData) {
        NSLog(@"could not send data");
	}
    
	err = zmq_msg_close(&message);
	if (err) {
        NSLog(@"could not close msg");
	}
}

-(NSData *)_readDataFromZMQSocket:(void *)socket {
    zmq_msg_t msg;
    int err = zmq_msg_init(&msg);
    if (err) {
        NSLog(@"some error occured creatong the zmq message");
    }
    
    err = zmq_recvmsg(socket, &msg, 0);
    if (err == -1) {
        NSLog(@"something whent wrong receiving");
        
        err = zmq_msg_close(&msg);
        if (err) {
            NSLog(@"something went wrong closing the message");
        }
    }
    
    
    size_t length = zmq_msg_size(&msg);
    NSData *data = [NSData dataWithBytes:zmq_msg_data(&msg) length:length];
    
    err = zmq_msg_close(&msg);
    if (err) {
        NSLog(@"could not close the msg");
    }
    
    return data;
}

-(void)_createZMQContext {
    self.context = zmq_ctx_new();
}

-(void)_disconnectFromServer {
    // Close the main socket
    zmq_close(self.pairSocketMain);

    // Destroy the context, which will trigger ETERM on the background thread triggering it to clean up
    zmq_ctx_destroy(self.context);
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
