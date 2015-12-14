/*----------------------------------------------------------------------------*
 *
 *  AudioIOManager
 *
 *  Singleton object that creates an iOS audio session and registers
 *  a C function callback for input and output of audio samples:
 *
 *----------------------------------------------------------------------------*/

#import "AudioIOManager.h"

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
    BOOL*                   audioChainIsBeingReconstructed;
    audio_callback_t        callback;
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
    
    if (*cd.audioChainIsBeingReconstructed == NO)
    {

        err = AudioUnitRender(cd.audioIOUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
        
        if (cd.callback)
        {
            for (UInt32 c = 0; c < ioData->mNumberBuffers; ++c)
                channel_pointers[c] = (float *) ioData->mBuffers[c].mData;
            cd.callback(channel_pointers, ioData->mNumberBuffers, inNumberFrames);
        }
    }
    
    return err;
}


@interface AudioIOManager ()

- (BOOL)setupAudioSession;
- (BOOL)setupIOUnit;
- (BOOL)setupAudioChain;

/**-----------------------------------------------------------------------------
 * Pointer to the C function called when samples have been read.
 *----------------------------------------------------------------------------*/
@property (assign) audio_callback_t callback;

@property (nonatomic, assign) AudioUnit audioIOUnit;
@property (nonatomic, assign) BOOL audioChainIsBeingReconstructed;


@end

@implementation AudioIOManager



////////////////////////////////////////////////////////////////////////////////
#pragma mark - Creation/deletion
////////////////////////////////////////////////////////////////////////////////

- (id)initWithCallback:(audio_callback_t)callback
{
    self = [super init];
    if (!self) return nil;

    NSLog(@"**** RUNNING PROTOTYPE AUDIO DRIVER ****\n");
    
    self.callback = callback;
    self.isInitialised = [self setupAudioChain];

    return self;

}

- (id)init
{
    return [self initWithCallback:NULL];
}

- (void)dealloc
{
    // Remove KVO
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Audio I/O callbacks
////////////////////////////////////////////////////////////////////////////////

/*----------------------------------------------------------------------------*
 * Called when audio I/O is interrupted
 *----------------------------------------------------------------------------*/

- (void)handleInterruption:(NSNotification *)notification
{
    @try
    {
        UInt8 interruptionType = [[notification.userInfo valueForKey:AVAudioSessionInterruptionTypeKey] intValue];
        NSLog(@"Session interrupted > --- %@ ---\n", interruptionType == AVAudioSessionInterruptionTypeBegan ? @"Begin Interruption" : @"End Interruption");
        
        if (interruptionType == AVAudioSessionInterruptionTypeBegan)
        {
            [self stop];
        }
        
        if (interruptionType == AVAudioSessionInterruptionTypeEnded)
        {
            // make sure to activate the session
            NSError *error = nil;
            [[AVAudioSession sharedInstance] setActive:YES error:&error];
            if (nil != error) NSLog(@"AVAudioSession set active failed with error: %@", error);
            
            [self start];
        }
    }
    @catch (NSException *e)
    {
        NSLog(@"Error: %@", e);
    }
}

/*----------------------------------------------------------------------------*
 * Called when audio routing is altered.
 *----------------------------------------------------------------------------*/

- (void)handleRouteChange:(NSNotification *)notification
{
    UInt8 reasonValue = [[notification.userInfo valueForKey:AVAudioSessionRouteChangeReasonKey] intValue];
    AVAudioSessionRouteDescription *routeDescription = [notification.userInfo valueForKey:AVAudioSessionRouteChangePreviousRouteKey];
    
    NSLog(@"Route change:");
    switch (reasonValue)
    {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
            NSLog(@"     NewDeviceAvailable");
            break;
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
            NSLog(@"     OldDeviceUnavailable");
            break;
        case AVAudioSessionRouteChangeReasonCategoryChange:
            NSLog(@"     CategoryChange");
            NSLog(@" New Category: %@", [[AVAudioSession sharedInstance] category]);
            break;
        case AVAudioSessionRouteChangeReasonOverride:
            NSLog(@"     Override");
            break;
        case AVAudioSessionRouteChangeReasonWakeFromSleep:
            NSLog(@"     WakeFromSleep");
            break;
        case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory:
            NSLog(@"     NoSuitableRouteForCategory");
            break;
        default:
            NSLog(@"     ReasonUnknown");
    }
    
    NSLog(@"Previous route:\n");
    NSLog(@"%@", routeDescription);
}

- (void)handleMediaServerReset:(NSNotification *)notification
{
    NSLog(@"Media server has reset");
    self.audioChainIsBeingReconstructed = YES;
    
    usleep(25000);
    
    [self setupAudioChain];
    [self start];
    
    self.audioChainIsBeingReconstructed = NO;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Audio setup
////////////////////////////////////////////////////////////////////////////////

- (BOOL)setupAudioSession
{
    @try
    {
        /*---------------------------------------------------------------------*
         * Configure the audio session
         *--------------------------------------------------------------------*/
        AVAudioSession *sessionInstance = [AVAudioSession sharedInstance];

        /*---------------------------------------------------------------------*
         * Register for audio input and output.
         *--------------------------------------------------------------------*/
        NSError *error = nil;
        [sessionInstance setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
        XThrowIfError((OSStatus)error.code, @"Couldn't set session's audio category");

        /*---------------------------------------------------------------------*
         * Set up a low-latency buffer.
         *--------------------------------------------------------------------*/
        NSTimeInterval bufferDuration = 0.002;
        [sessionInstance setPreferredIOBufferDuration:bufferDuration error:&error];
        XThrowIfError((OSStatus)error.code, @"Couldn't set session's I/O buffer duration");
        
        /*---------------------------------------------------------------------*
         * Set preferred sample rate.
         *--------------------------------------------------------------------*/
        [sessionInstance setPreferredSampleRate:44100 error:&error];
        XThrowIfError((OSStatus)error.code, @"Couldn't set session's preferred sample rate");
        

        
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
         * If media services are reset, we need to rebuild our audio chain.
         *--------------------------------------------------------------------*/
        [notificationCenter addObserver:self
                               selector:@selector(handleMediaServerReset:)
                                   name:AVAudioSessionMediaServicesWereResetNotification
                                 object:sessionInstance];

        /*---------------------------------------------------------------------*
         * Receive notification when system volume changed (via KVO)
         *--------------------------------------------------------------------*/
        [sessionInstance addObserver:self
                          forKeyPath:@"outputVolume"
                             options:0
                             context:nil];
        
        /*---------------------------------------------------------------------*
         * Activate the audio session.
         *--------------------------------------------------------------------*/
        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        XThrowIfError((OSStatus) error.code, @"Couldn't set session active");
        
        return YES;
    }
    
    @catch (NSException *e)
    {
        NSLog(@"Error returned from setupAudioSession: %@", e);
        return NO;
    }
}


- (BOOL)setupIOUnit
{
    @try
    {
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
        XThrowIfError(AudioComponentInstanceNew(comp, &_audioIOUnit), @"couldn't create a new instance of AURemoteIO");
        
        
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
        audioFormat.mSampleRate         = 44100.00;
        audioFormat.mFormatID           = kAudioFormatLinearPCM;
        audioFormat.mFormatFlags        = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        audioFormat.mFramesPerPacket    = 1;
        audioFormat.mChannelsPerFrame   = 1;
        audioFormat.mBitsPerChannel     = 32;
        audioFormat.mBytesPerPacket     = 4;
        audioFormat.mBytesPerFrame      = 4;

        XThrowIfError(AudioUnitSetProperty(self.audioIOUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &audioFormat, sizeof(audioFormat)),
                      @"couldn't set the input client format on AURemoteIO");
        XThrowIfError(AudioUnitSetProperty(self.audioIOUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioFormat, sizeof(audioFormat)),
                      @"couldn't set the output client format on AURemoteIO");

        /*---------------------------------------------------------------------*
         * Create our callback data structure.
         * This is needed to pass the audio I/O unit to the lower-level
         * interface.
         *--------------------------------------------------------------------*/
        cd.audioIOUnit = self.audioIOUnit;
        cd.audioChainIsBeingReconstructed = &_audioChainIsBeingReconstructed;
        cd.callback = self.callback;
        
        /*---------------------------------------------------------------------*
         * Set the render callback on AURemoteIO
         *--------------------------------------------------------------------*/
        AURenderCallbackStruct renderCallback;
        renderCallback.inputProc = performRender;
        renderCallback.inputProcRefCon = NULL;
        
        XThrowIfError(AudioUnitSetProperty(self.audioIOUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, sizeof(renderCallback)),
                      @"couldn't set render callback on AURemoteIO");
        
        /*---------------------------------------------------------------------*
         * Initialize the AURemoteIO instance
         *--------------------------------------------------------------------*/
        XThrowIfError(AudioUnitInitialize(self.audioIOUnit),
                      @"couldn't initialize AURemoteIO instance");
        
        return YES;
    }
    
    @catch (NSException *e)
    {
        NSLog(@"Error returned from setupIOUnit: %@", e);
        return NO;
    }
}

- (BOOL)setupAudioChain
{
    BOOL ok;
    
    /*---------------------------------------------------------------------*
     * Initialise our audio chain:
     *  - set our AVAudioSession configuration
     *  - create a remote I/O unit and register an I/O callback
     *--------------------------------------------------------------------*/
    ok = [self setupAudioSession];
    if (!ok) return NO;
    
    ok = [self setupIOUnit];
    if (!ok) return NO;
    
    return YES;
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Key-value observation
////////////////////////////////////////////////////////////////////////////////


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    
    if ([keyPath isEqual:@"outputVolume"])
    {
        NSLog(@"volume changed: %f", [[AVAudioSession sharedInstance] outputVolume]);
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
    /*---------------------------------------------------------------------*
     * Kick off processing.
     *--------------------------------------------------------------------*/
    OSStatus err = AudioOutputUnitStart(self.audioIOUnit);
    if (err)
        NSLog(@"Couldn't start audio I/O: %d", (int) err);
    
    return err;
}

- (OSStatus)stop
{
    /*---------------------------------------------------------------------*
     * Terminate processing.
     *--------------------------------------------------------------------*/
    OSStatus err = AudioOutputUnitStop(self.audioIOUnit);
    if (err)
        NSLog(@"Couldn't stop audio I/O: %d", (int) err);
    return err;
}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Getters and setters
////////////////////////////////////////////////////////////////////////////////


- (double)sessionSampleRate
{
    return [[AVAudioSession sharedInstance] sampleRate];
}


- (BOOL)audioChainIsBeingReconstructed
{
    return _audioChainIsBeingReconstructed;
}


@end
