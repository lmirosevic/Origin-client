//
//  Origin.h
//  Origin
//
//  Created by Luka Mirosevic on 25/05/2014.
//  Copyright (c) 2014 Goonbee. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void(^OriginChannelUpdateBlock)(NSString *channel, id rawMessage, id deserializedObject, BOOL isLCVUpdate);
//typedef void(^OriginValueBlock)(NSString *channel, id rawMessage, id deserializedObject);
//typedef void(^OriginChannelSubscriptionBlock)(NSString *channel, id rawMessage, id deserializedObject, BOOL cancelled);
typedef id(^OriginDeserializerBlock)(id message);

@interface Origin : NSObject

/**
 Returns a shared singleton instance of Origin. You can also instantiate your own instances and use them with different servers.
 */
+(instancetype)sharedOrigin;

/**
 Initializes a new instance.
 */
-(id)init;

/**
 Connects to an Origin server.
 */
-(void)connectToServer:(NSString *)server port:(NSUInteger)port;

/**
 Subscribes to a channel and start sending updates to the client, with an initial LCV update when calling this method.
 */
-(void)subscribeToChannel:(NSString *)channel withBlock:(OriginChannelUpdateBlock)block;

/**
 Removes the block from the channel listening, and if it's the last block listening on the channel, sends an unsub request to the server
 */
-(void)unsubscribeFromChannel:(NSString *)channel withBlock:(OriginChannelUpdateBlock)block;

/**
 Removes all update handlers for a channel.
 */
-(void)unsubscribeAllHandlersFromChannelChannel:(NSString *)channel;

///**
// Subscribes to an Origin channel. Upon succesful subscription, the Origin server will immediately send an update to handlers added using `-[addUpdateHandlerForChannel:block:]` with the channel's current value.
// */
//-(void)subscribeToChannel:(NSString *)channel;
//
///**
// Subscribes to an Origin channel. Upon succesful subscription, the Origin server will send an update to handlers added using `-[addUpdateHandlerForChannel:block:]` with the channel's current value. The block will be called with the latest value of the channel, and indicates subscription success, except if `cancelled` is set to YES in which case the channel was unsubsribed from before the initial subscription acknowledgement was received.
// */
//-(void)subscribeToChannel:(NSString *)channel block:(OriginChannelSubscriptionBlock)block;
//
///**
// Unsubscribes from an Origin channel. Immediately removes and releases all update handlers added for the channel. Any subscription which is still in flight is cancelled and it's block is immediately called with the `cancelled` flag set to YES.
// */
//-(void)unsubscribeFromChannel:(NSString *)channel;
//
///**
// Adds a handler which will be called each time the channel emits an update.
// */
//-(void)addUpdateHandlerForChannel:(NSString *)channel block:(OriginValueBlock)block;
//
///**
// Removes a particular update handler from a channel.
// */
//-(void)removeUpdateHandlerForChannel:(NSString *)channel block:(OriginValueBlock)block;
//
///**
// Removes all update handlers for a channel.
// */
//-(void)removeAllUpdateHandlerForChannel:(NSString *)channel;

/**
 Gets the current value for a channel. This calls the block immediately with the currently cached value for the channel, if it exists, nil otherwise. If you have not subscribed to the channel the block is called with nil values for `data` and `object`.
 */
-(void)currentValueForChannel:(NSString *)channel block:(OriginValueBlock)block;//lm fix this one to use the new block type

/**
 Check whether you are subscribed to a channel. This method returns YES only once the server subscription acknowledgement has been received.
 */
-(BOOL)isSubscribedToChannel:(NSString *)channel;

/**
 Check whether you are subscribed to a channel. This method returns YES before the server subscription acknowledgement has been received, i.e. as soon as you have called `-[subscribeToChannel:]`
 */
-(BOOL)isSubscribedToChannelOptimistically:(NSString *)channel;

/**
 Sets a deserializer which converts the raw NSData object passed in from the channel, to some native object which is more usable in the client context. This overrides the common deserializer. If a deserializer is set for a channel, it's output value is passed into the `object` field of the `OriginUpdateBlock`, this field returns the raw data otherwise.
 */
-(void)setDeserializerForChannel:(NSString *)channel deserializerBlock:(OriginDeserializerBlock)deserializerBlock;

/**
 Removes the deserializer from a particular channel.
 */
-(void)removeDeserializerForChannel:(NSString *)channel;

/**
 If the origin server always returns the same type of data, e.g. JSON, which you always just want as an NSDictionary, then you can set a default deserializer. Deserializers which you set on a specific channel will override this one for that specific channel.
 */
-(void)setDefaultDeserializer:(OriginDeserializerBlock)deserializerBlock;

/**
 Removes the default deserializer.
 */
-(void)removeDefaultDeserializer;

/**
 Set whether the processor block should be run on a background thread or not. Default: NO
 */
@property (assign, nonatomic) BOOL shouldRunProcessorBlocksOnBackgroundThread;

/**
 Returns YES if you have previously called -[connectToServer:port:]
 */
@property (assign, nonatomic, readonly) BOOL isConnected;

@end
