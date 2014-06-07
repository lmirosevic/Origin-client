//
//  Origin.h
//  Origin
//
//  Created by Luka Mirosevic on 25/05/2014.
//  Copyright (c) 2014 Goonbee. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void(^OriginChannelUpdateBlock)(NSString *channel, id rawMessage, id deserializedObject, BOOL unsubscribed);
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
 Removes the block from the channel listening, and if it's the last block listening on the channel, sends an unsub request to the server.
 */
-(void)unsubscribeFromChannel:(NSString *)channel withBlock:(OriginChannelUpdateBlock)block;

/**
 Removes all update blocks for a channel.
 */
-(void)unsubscribeAllBlocksFromChannel:(NSString *)channel;

/**
 Gets the current value for a channel. This calls the block immediately with the currently cached value for the channel, if it exists, nil otherwise. If you have not subscribed to the channel the block is called with nil values for `data` and `object`.
 */
-(void)currentValueForChannel:(NSString *)channel block:(OriginChannelUpdateBlock)block;

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
