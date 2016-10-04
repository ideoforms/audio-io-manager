/*----------------------------------------------------------------------------*
 *
 *  AudioIOManager
 *
 *  Singleton object that creates an iOS audio session and registers
 *  a C function callback for input and output of audio samples:
 *
 *----------------------------------------------------------------------------*/

#import "AudioIOManager.h"
#import <UIKit/UIKit.h>

/*----------------------------------------------------------------------------*
 * Helper macro to check the return values of CoreAudio functions.
 *----------------------------------------------------------------------------*/
#define XThrowIfError(error, operation)	if (error) { @throw [NSException exceptionWithName:@"AudioIOException" reason:operation userInfo:nil]; }

/*----------------------------------------------------------------------------*
 * Local storage to translate between AudioBufferList and a 2D array of floats.
 *----------------------------------------------------------------------------*/
static float *channel_pointers[32];

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Audio I/O callbacks
////////////////////////////////////////////////////////////////////////////////

/*----------------------------------------------------------------------------*
 * Struct to relay data to the C callback.
 *----------------------------------------------------------------------------*/
struct CallbackData
{
    AudioUnit               audioIOUnit;
    BOOL*                   isBeingReconstructed;
    audio_data_callback_t   callback;
    int                     samplerate;
    __unsafe_unretained id  delegate;
} cd;

/*----------------------------------------------------------------------------*
 * Universal render function.
 * If audio chain is ready:
 *  - render the input audio to a local buffer
 *  - translate AudioBufferList pointers to a float**
 *  - call the user-specified callback
 *----------------------------------------------------------------------------*/
static OSStatus	performRender (void                         *inRefCon,
                               AudioUnitRenderActionFlags 	*ioActionFlags,
                               const AudioTimeStamp 		*inTimeStamp,
                               UInt32 						inBusNumber,
                               UInt32 						inNumberFrames,
                               AudioBufferList              *ioData)
{
    OSStatus err = noErr;
    
    if (*cd.isBeingReconstructed == NO)
    {
        err = AudioUnitRender(cd.audioIOUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
        
        if (cd.callback)
        {
            for (UInt32 c = 0; c < ioData->mNumberBuffers; ++c)
                channel_pointers[c] = (float *) ioData->mBuffers[c].mData;
            cd.callback(channel_pointers, ioData->mNumberBuffers, inNumberFrames, cd.samplerate);
        }

    }
    
    return err;
}

@interface AudioIOManager ()

/**-----------------------------------------------------------------------------
 * Pointer to C callback functions.
 *----------------------------------------------------------------------------*/
@property (assign) audio_volume_change_callback_t volumeBlock;
@property (assign) audio_data_callback_t callback;

/**-----------------------------------------------------------------------------
 * AudioUnit object for input and output.
 *----------------------------------------------------------------------------*/
@property (nonatomic, assign) AudioUnit audioIOUnit;

/**-----------------------------------------------------------------------------
 * Used internally to track whether we're rebuilding our audio chain.
 *----------------------------------------------------------------------------*/
@property (nonatomic, assign) BOOL isBeingReconstructed;

/**-----------------------------------------------------------------------------
 * Used internally to track whether the AVAudioSession has been activated.
 *----------------------------------------------------------------------------*/
@property (nonatomic, assign) BOOL isAudioSessionActive;
@end

@implementation AudioIOManager
////////////////////////////////////////////////////////////////////////////////
#pragma mark - Creation/deletion
////////////////////////////////////////////////////////////////////////////////

- (id)initWithCallback:(audio_data_callback_t)callback
{
    self = [super init];
    if (!self) return nil;

    [self resetProperties];
    self.callback = callback;

    return self;

}

- (id)initWithDelegate:(id<AudioIODelegate>)delegate
{
    self = [super init];
    if (!self) return nil;
    
    [self resetProperties];
    self.delegate = delegate;

    return self;
}

- (id)init
{
    return [self initWithCallback:NULL];
}

- (void)resetProperties
{
    self.mixWithOtherAudio = NO;
    self.routeToSpeaker = NO;
    
    self.volumeBlock = nil;
    self.delegate = nil;
    self.callback = nil;
    
    self.isInitialised = NO;
    self.isStarted = NO;
    self.isAudioSessionActive = NO;
}

- (void)resetAudio
{
    if (self.isInitialised)
    {
        [self teardown];
    }
    
    [self setup];
    NSAssert(self.isInitialised, @"Initialised OK");
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Audio I/O callbacks
////////////////////////////////////////////////////////////////////////////////

/*----------------------------------------------------------------------------*
 * Called when audio I/O is interrupted
 *----------------------------------------------------------------------------*/

- (void)handleMediaServicesReset:(NSNotification *)notification
{
    DLog(@"Media services reset.");
}

- (void)handleApplicationBecameActive:(NSNotification *)notification
{
    BOOL ok = [self activateAudioSession];
    
    if (ok)
    {
        [self setupIOUnit];
    
        if (self.isStarted)
        {
            [self start];
        }
    }
}

- (void)handleInterruption:(NSNotification *)notification
{
    if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification])
    {
        if ([[notification.userInfo valueForKey:AVAudioSessionInterruptionTypeKey] isEqualToNumber:@(AVAudioSessionInterruptionTypeBegan)])
        {
            DLog(@"AVAudioSessionInterruptionTypeBegan");
            /*----------------------------------------------------------------------------*
             * Interruption started. Stop our audio unit and deactivate the session.
             * We can then safely activate and restart when the service resumes.
             * However, InterruptionTypeEnded is often not called, so this is handled
             * in handleApplicationBecameActive.
             *----------------------------------------------------------------------------*/
            [self teardownIOUnit];
            [self deactivateAudioSession];
        }
        else
        {
            DLog(@"AVAudioSessionInterruptionTypeEnded");
            
            if (!self.isAudioSessionActive)
            {
                [self activateAudioSession];
                [self setupIOUnit];
                
                if (self.isStarted)
                {
                    [self start];
                }
            }
        }
    }
}

/*----------------------------------------------------------------------------*
 * Called when audio routing is altered.
 *----------------------------------------------------------------------------*/

- (void)handleRouteChange:(NSNotification *)notification
{

    UInt8 reasonValue = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] intValue];
    
#ifdef DEBUG
    AVAudioSessionPortDescription *port = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject;
    DLog(@"Route changed, port type %@, new samplerate %.0fHz (reason: %d)\n",
          port.portType, [AVAudioSession sharedInstance].sampleRate,
          reasonValue);
#endif
    
    if (reasonValue == AVAudioSessionRouteChangeReasonNewDeviceAvailable ||
        reasonValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable ||
        reasonValue == AVAudioSessionRouteChangeReasonOverride)
     {
         /*----------------------------------------------------------------------------*
          * This situation occurs when a route is changed by hardware
          * (AVAudioSessionRouteChangeReasonNewDeviceAvailable occurs when
          * headphones plugged in, AVAudioSessionRouteChangeReasonOldDeviceUnavailable
          * when unplugged) or app-switching.
          *----------------------------------------------------------------------------*/
         if (self.isAudioSessionActive)
         {
             DLog(@"Audio changed device, rebuilding audio chain");
             [self teardown];
             [self setup];
             
             if (self.delegate && [self.delegate respondsToSelector:@selector(audioIOPortChanged)])
             {
                 /*----------------------------------------------------------------------------*
                  * If specified, trigger a delegate notification that the IO port has been
                  * changed. The audio I/O unit has been stopped by this point so it's safe to
                  * reallocate memory that may affect the audio I/O thread. Must do this
                  * before restarting processing.
                  *----------------------------------------------------------------------------*/
                 [self.delegate audioIOPortChanged];
             }
             
             if (self.isStarted)
             {
				 /*----------------------------------------------------------------------------*
				  * The isStarted flag indicates that the audio session had been started
				  * before this rebuild. Trigger the start method to resume playback.
				  *----------------------------------------------------------------------------*/
                 [self start];
             }
         }
         else
         {
             /*----------------------------------------------------------------------------*
              * Hardware may change when we don't have an active audio session
              * (for example, during a call or other interruption).
              *
              * If this happens, don't try to rebuild the audio chain.
              *----------------------------------------------------------------------------*/
             DLog(@"Audio changed device when inactive, not rebuilding");
         }
     }
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Audio setup
////////////////////////////////////////////////////////////////////////////////

- (BOOL)setupAudioSession
{
    NSAssert(!self.isInitialised, @"Audio session already initialised");
    
    @try
    {
        __block BOOL success = NO;
        __block NSError *error = nil;

        /*---------------------------------------------------------------------*
         * Configure the audio session
         *--------------------------------------------------------------------*/
        AVAudioSession *sessionInstance = [AVAudioSession sharedInstance];
        
        
        /*---------------------------------------------------------------------*
         * Set preferred sample rate.
         *--------------------------------------------------------------------*/
        success = [sessionInstance setPreferredSampleRate:AUDIO_PREFERRED_SAMPLE_RATE error:&error];
        XThrowIfError((OSStatus)error.code, @"Couldn't set session's preferred sample rate");

        /*---------------------------------------------------------------------*
         * Register for audio input and output.
         *--------------------------------------------------------------------*/
        NSUInteger options = 0;
        
        if (self.mixWithOtherAudio)
        {
            options |= AVAudioSessionCategoryOptionMixWithOthers;
        }
        
        if (self.routeToSpeaker)
        {
            options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
        }
        
        /*---------------------------------------------------------------------*
         * At the moment, we only support the PlayAndRecord category.
         *--------------------------------------------------------------------*/
        success = [sessionInstance setCategory:AVAudioSessionCategoryPlayAndRecord
                                   withOptions:options
                                         error:&error] && success;
        XThrowIfError((OSStatus)error.code, @"Couldn't set session's audio category");
        
        [sessionInstance.availableModes enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            
            if ([obj isEqual:AUDIO_PREFERRED_SESSION_MODE]) {
                success =  [sessionInstance setMode:AUDIO_PREFERRED_SESSION_MODE error:&error] && success;
                XThrowIfError((OSStatus)error.code, @"Couldn't set session's audio mode");
            }

        }];

        /*---------------------------------------------------------------------*
         * Set up a low-latency buffer.
         *--------------------------------------------------------------------*/
        NSTimeInterval bufferDuration = (float) AUDIO_BUFFER_SIZE / sessionInstance.sampleRate;
        success = [sessionInstance setPreferredIOBufferDuration:bufferDuration error:&error] && success;
        XThrowIfError((OSStatus)error.code, @"Couldn't set session's I/O buffer duration");
        
        /*---------------------------------------------------------------------*
         * NOTIFICATIONS
         *----------------------------------------------------------------------
         * Register for changes in various properties.
         *--------------------------------------------------------------------*/
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        
        /*---------------------------------------------------------------------*
         * Add interruption handler
         *--------------------------------------------------------------------*/
        [notificationCenter addObserver:self
                               selector:@selector(handleInterruption:)
                                   name:AVAudioSessionInterruptionNotification
                                 object:sessionInstance];
        
        /*---------------------------------------------------------------------*
         * Notify for change of route (eg. built-in speaker -> headphones)
         *--------------------------------------------------------------------*/
        [notificationCenter addObserver:self
                               selector:@selector(handleRouteChange:)
                                   name:AVAudioSessionRouteChangeNotification
                                 object:sessionInstance];

        /*---------------------------------------------------------------------*
         * When media services are reset, we need to rebuild our audio chain.
         *--------------------------------------------------------------------*/
        [notificationCenter addObserver:self
                               selector:@selector(handleMediaServicesReset:)
                                   name:AVAudioSessionMediaServicesWereResetNotification
                                 object:sessionInstance];
        
        /*---------------------------------------------------------------------*
         * When the app becomes active, we need to rebuild our audio chain.
         *--------------------------------------------------------------------*/
        [notificationCenter addObserver:self
                               selector:@selector(handleApplicationBecameActive:)
                                   name:UIApplicationDidBecomeActiveNotification
                                 object:nil];
        
        /*---------------------------------------------------------------------*
         * When the app is foregrounded, we need to rebuild our audio chain.
         * This may happen when the Control Center is closed.
         *--------------------------------------------------------------------*/
        [notificationCenter addObserver:self
                               selector:@selector(handleMediaServicesReset:)
                                   name:UIApplicationWillEnterForegroundNotification
                                 object:nil];

        /*---------------------------------------------------------------------*
         * Receive notification when system volume changed (via KVO)
         *--------------------------------------------------------------------*/
        [sessionInstance addObserver:self
                          forKeyPath:@"outputVolume"
                             options:0
                             context:nil];
        
        return success;

    }
    @catch (NSException *e)
    {
        DLog(@"Error returned from setupAudioSession: %@", e);
        return NO;
    }
}



- (BOOL)setupIOUnit
{
    if (self.audioIOUnit)
    {
        return YES;
    }
    
    @try
    {
        //DLog(@"Setting up audio unit, samplerate %fHz", [AVAudioSession sharedInstance].sampleRate);
        
        /*---------------------------------------------------------------------*
         * Set up a remote IO unit.
         *--------------------------------------------------------------------*/
        AudioComponentDescription desc;
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_RemoteIO;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        desc.componentFlags = 0;
        desc.componentFlagsMask = 0;
        
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        XThrowIfError(AudioComponentInstanceNew(comp, &_audioIOUnit), @"Couldn't create a new instance of AURemoteIO");
        
        /*---------------------------------------------------------------------*
         * Enable audio input (on input scope of input element)
         * and output (on output scope of output element).
         *--------------------------------------------------------------------*/
        
        UInt32 one = 1;
        XThrowIfError(AudioUnitSetProperty(self.audioIOUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof(one)),
                      @"Could not enable input on AURemoteIO");
        XThrowIfError(AudioUnitSetProperty(self.audioIOUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, sizeof(one)),
                      @"Could not enable output on AURemoteIO");
        
        /*---------------------------------------------------------------------*
         * Explicitly set the audio format to 32-bit float.
         *--------------------------------------------------------------------*/
        AudioStreamBasicDescription audioFormat;
        audioFormat.mSampleRate         = [AVAudioSession sharedInstance].sampleRate;
        audioFormat.mFormatID           = kAudioFormatLinearPCM;
        audioFormat.mFormatFlags        = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        audioFormat.mFramesPerPacket    = 1;
        audioFormat.mChannelsPerFrame   = 1;
        audioFormat.mBitsPerChannel     = 8 * sizeof(float);
        audioFormat.mBytesPerFrame      = sizeof(float) * audioFormat.mChannelsPerFrame;
        audioFormat.mBytesPerPacket     = audioFormat.mBytesPerFrame * audioFormat.mFramesPerPacket;

        XThrowIfError(AudioUnitSetProperty(self.audioIOUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &audioFormat, sizeof(audioFormat)),
                      @"Couldn't set the input client format on AURemoteIO");
        XThrowIfError(AudioUnitSetProperty(self.audioIOUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioFormat, sizeof(audioFormat)),
                      @"Couldn't set the output client format on AURemoteIO");

        /*---------------------------------------------------------------------*
         * Create our callback data structure.
         * This is needed to pass the audio I/O unit to the lower-level
         * interface.
         *--------------------------------------------------------------------*/
        cd.audioIOUnit = self.audioIOUnit;
        cd.isBeingReconstructed = &_isBeingReconstructed;
        cd.callback = self.callback;
        cd.delegate = self.delegate;
        cd.samplerate = [AVAudioSession sharedInstance].sampleRate;
        
        /*---------------------------------------------------------------------*
         * Set the render callback on AURemoteIO
         *--------------------------------------------------------------------*/
        AURenderCallbackStruct renderCallback;
        renderCallback.inputProc = performRender;
        renderCallback.inputProcRefCon = NULL;
        
        XThrowIfError(AudioUnitSetProperty(self.audioIOUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, sizeof(renderCallback)),
                      @"Couldn't set render callback on AURemoteIO");
        
        /*---------------------------------------------------------------------*
         * Initialize the AURemoteIO instance
         *--------------------------------------------------------------------*/
        XThrowIfError(AudioUnitInitialize(self.audioIOUnit),
                      @"Couldn't initialize AURemoteIO instance");
        
        return YES;
    }
    
    @catch (NSException *e)
    {
        DLog(@"Failed initializing audio unit: %@", e);
        return NO;
    }
}

- (BOOL)setup
{
    /*---------------------------------------------------------------------*
     * Initialise our audio chain:
     *  - set our AVAudioSession configuration
     *  - create a remote I/O unit and register an I/O callback
     *--------------------------------------------------------------------*/
    BOOL ok = YES;
    
    self.isBeingReconstructed = YES;
    
    ok = [self setupAudioSession];
    if (!ok) return NO;
    
    [self activateAudioSession];
    
    ok = [self setupIOUnit];
    if (!ok) return NO;
    
    self.isBeingReconstructed = NO;
    self.isInitialised = YES;

    return YES;
}

- (BOOL)activateAudioSession
{
    /*---------------------------------------------------------------------*
     * Activate the audio session.
     *--------------------------------------------------------------------*/
    
    NSError *error;
    AVAudioSession *sessionInstance = [AVAudioSession sharedInstance];
    [sessionInstance setActive:YES error:&error];
    if (error)
    {
        DLog(@"Couldn't set session active: %@", error);
        return NO;
    }
    else
    {
        self.isAudioSessionActive = YES;
        return YES;
    }
}

- (BOOL)deactivateAudioSession
{
    
    BOOL ok;
    
    NSError *error;
    @try
    {
        [[AVAudioSession sharedInstance] setActive:NO error:&error];
        if (error)
        {
            ok = NO;
        }
        else
        {
            ok = YES;
        }
    }
    @catch (NSException *exception)
    {
        ok = NO;
    }

    if (ok)
    {
        self.isAudioSessionActive = NO;
        return YES;
    }
    else
    {
        DLog(@"Couldn't set session active (%@)", error);
        return NO;
    }
}

- (BOOL) teardown
{
    /*---------------------------------------------------------------------*
     * Tear down our audio chain:
     *  - uninitialize and delete the remote I/O unit
     *  - deactivate the audio session
     *  - reset our AVAudioSession configuration and observers
     * Don't modify our `isStarted` state as this be an interim measure
     * before rebuilding the chain and resuming playback.
     *--------------------------------------------------------------------*/
    BOOL ok = YES;
    
    self.isBeingReconstructed = YES;

    ok = [self teardownIOUnit];
    if (!ok) return NO;
    
    [self deactivateAudioSession];
    
    ok = [self teardownAudioSession];
    if (!ok) return NO;

    self.isBeingReconstructed = NO;
    self.isInitialised = NO;

    return ok;
}

- (BOOL) teardownAudioSession
{
    /*---------------------------------------------------------------------*
     * Be a good citizen, remove any dangling observers when we depart.
     *--------------------------------------------------------------------*/
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    @try
    {
        [[AVAudioSession sharedInstance] removeObserver:self forKeyPath:@"outputVolume"];
    }
    @catch (NSException *exception)
    {
        /*---------------------------------------------------------------------*
         * Not observing AVAudioSession sharedInstance
         *--------------------------------------------------------------------*/
    }
    
    return YES;
}

- (BOOL) teardownIOUnit
{
    BOOL success = YES;
    
    /*---------------------------------------------------------------------*
     * Uninitialize the AURemoteIO instance and zero its memory.
     *--------------------------------------------------------------------*/
    if (self.audioIOUnit)
    {
        @try
        {
            /*---------------------------------------------------------------------*
             * In case the audio unit is still playing, stop it (ignoring
             * any error result). "All I/O must be stopped or paused prior to
             * deactivating the audio session."
             *--------------------------------------------------------------------*/
            AudioOutputUnitStop(self.audioIOUnit);
            
            XThrowIfError(AudioUnitUninitialize(self.audioIOUnit),
                          @"Couldn't uninitialize AudioUnit instance");
            self.audioIOUnit = NULL;
        }
        @catch (NSException *exception)
        {
            /*---------------------------------------------------------------------*
             * Couldn't uninitialize AURemoteIO instance
             *--------------------------------------------------------------------*/
            DLog(@"Failed to stop audio unit: %@", exception);
            success = NO;
        }
    }
    
    return success;
}


- (BOOL) selectInputOrientation:(NSString *)orientation polarPattern:(NSString *) pattern
{
    
    if (!self.isAudioSessionActive)
    {
        NSLog(@"Audio session should have session category and mode set, and then be activated prior to using any of the input selection features");
        return NO;
    }
    
    AVAudioSession *sessionInstance = [AVAudioSession sharedInstance];
    NSError *error;
    BOOL result = YES;
    
    AVAudioSessionPortDescription* micPort = nil;
    for (AVAudioSessionPortDescription* port in [sessionInstance availableInputs])
    {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic])
        {
            micPort = port;
            break;
        }
    }
    
    /*-------------------------------------------------------------------------*
     * Loop over the built-in mic's data sources and attempt to locate the
     * bottom mic first, or front microphone.
     *
     * DOES NOT WORK ON THE SIMULATOR.
     *------------------------------------------------------------------------*/
    AVAudioSessionDataSourceDescription* dataSource = nil;
    for (AVAudioSessionDataSourceDescription* source in micPort.dataSources)
    {
        if ([source.orientation isEqual:orientation])
        {
            dataSource = source;
            break;
        }
        
    }
    
    
    if (dataSource)
    {
        /*-------------------------------------------------------------------------*
         * Note that the direction of a polar pattern is relative to the
         * orientation of the data source. For example, you can use the cardioid
         * pattern with a back-facing data source to more clearly record sound
         * from behind the device, or with a front-facing data source to more
         * clearly record sound from in front of the device (such as the user’s voice).
         *------------------------------------------------------------------------*/
        result = [dataSource setPreferredPolarPattern:pattern error:&error];
        
        if (!result || error)
        {
            NSLog(@"Could not set polar pattern %@", error.description);
        }
        
        result = [micPort setPreferredDataSource:dataSource error:&error] && result;
        if (!result || error)
        {
            NSLog(@"setPreferredDataSource failed (%@)", error.description);
        }
        
    }
    
    /*-------------------------------------------------------------------------*
     * Select a preferred input port for audio routing. If the input port is
     * already part of the current audio route, this will have no effect.
     * Otherwise, selecting an input port for routing ___will initiate a route
     * change___ to use the preferred input port, provided that the 
     * application's session controls audio routing.
     *------------------------------------------------------------------------*/
    result = [sessionInstance setPreferredInput:micPort error:&error] && result;
    
    if (!result || error)
    {
        NSLog(@"setPreferredInput failed : %@", error);
    }
    
    DLog(@"Mic set : %@ %@", sessionInstance.inputDataSource.orientation, sessionInstance.inputDataSource.selectedPolarPattern);

    return result && !error;
}

- (void)dealloc
{
    [self teardown];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Key-value observation
////////////////////////////////////////////////////////////////////////////////


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    
    if ([keyPath isEqual:@"outputVolume"])
    {
        if (self.volumeBlock)
            self.volumeBlock([[AVAudioSession sharedInstance] outputVolume]);
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Start/stop
////////////////////////////////////////////////////////////////////////////////

- (OSStatus)start
{
    if (!self.isInitialised)
    {
        [self setup];
    }
    
    /*---------------------------------------------------------------------*
     * Start audio processing.
     *--------------------------------------------------------------------*/
    OSStatus err = AudioOutputUnitStart(self.audioIOUnit);
    if (err)
    {
        DLog(@"Couldn't start audio I/O: %d", (int) err);
        return err;
    }
    
    self.isStarted = YES;
    
    return err;
}

- (OSStatus)stop
{
    if (!self.isInitialised)
    {
        DLog(@"Attempting to stop audio IO when it is not started.");
        return 1;
    }
    
    /*---------------------------------------------------------------------*
     * Terminate audio processing.
     *--------------------------------------------------------------------*/
    OSStatus err = AudioOutputUnitStop(self.audioIOUnit);
    
    if (err)
    {
        DLog(@"Couldn't stop audio I/O: %d", (int) err);
        return err;
    }
    
    self.isStarted = NO;
    
    return err;
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Getters and setters
////////////////////////////////////////////////////////////////////////////////

- (double)sampleRate
{
    return [[AVAudioSession sharedInstance] sampleRate];
}

- (double)volume
{
	return [[AVAudioSession sharedInstance] outputVolume];
}

- (void)setVolumeChangedBlock:(audio_volume_change_callback_t)block
{
    self.volumeBlock = block;
}

@end

