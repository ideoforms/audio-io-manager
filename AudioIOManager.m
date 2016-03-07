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
    audio_data_callback_t   callback;
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
    
    if (*cd.audioChainIsBeingReconstructed == NO)
    {
        err = AudioUnitRender(cd.audioIOUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
        
        if (cd.callback)
        {
            for (UInt32 c = 0; c < ioData->mNumberBuffers; ++c)
                channel_pointers[c] = (float *) ioData->mBuffers[c].mData;
            cd.callback(channel_pointers, ioData->mNumberBuffers, inNumberFrames);
        }
        else if (cd.delegate)
        {
            [cd.delegate audioCallback:ioData numFrames:inNumberFrames];
        }
    }
    
    return err;
}


@interface AudioIOManager ()

/**-----------------------------------------------------------------------------
 * Pointer to the C function called when samples have been read.
 *----------------------------------------------------------------------------*/
@property (assign) audio_data_callback_t callback;
@property (assign) audio_volume_change_callback_t volumeBlock;
@property (assign) AVAudioSessionPortOverride preferredPort;

@property (nonatomic, assign) AudioUnit audioIOUnit;
@property (nonatomic, assign) BOOL audioChainIsBeingReconstructed;


@end

@implementation AudioIOManager



////////////////////////////////////////////////////////////////////////////////
#pragma mark - Creation/deletion
////////////////////////////////////////////////////////////////////////////////

- (id)initWithCallback:(audio_data_callback_t)callback
{
    self = [super init];
    if (!self) return nil;

    self.callback = callback;
    [self reset:nil];

    return self;

}

- (id)initWithDelegate:(id<AudioIODelegate>)delegate
{
    self = [super init];
    if (!self) return nil;
    self.delegate = delegate;
    [self reset:nil];

    return self;
}

- (id)init
{
    return [self initWithCallback:NULL];
}

- (void) reset:(id)sender {
    
    self.volumeBlock = nil;
    self.preferredPort = AVAudioSessionPortOverrideSpeaker;
    self.isInitialised = [self setupAudioChain];
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
        
        if (interruptionType == AVAudioSessionInterruptionTypeBegan)
        {
            [self stop];
        }
        
        if (interruptionType == AVAudioSessionInterruptionTypeEnded)
        {
            // make sure to activate the session
            NSError *error = nil;
            [[AVAudioSession sharedInstance] setActive:YES error:&error];
            
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
    
    //TODO : is it safe to assume firstObject here?
    AVAudioSessionPortDescription *port = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject;

    DLog(@"%@ Sample Rate:%0.0fHz I/O Buffer Duration:%f \n%@", port.portType, [AVAudioSession sharedInstance].sampleRate, [AVAudioSession sharedInstance].IOBufferDuration, notification.userInfo[AVAudioSessionRouteChangeReasonKey]);
    
    if (reasonValue == AVAudioSessionRouteChangeReasonNewDeviceAvailable ||
        reasonValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable ||
        reasonValue == AVAudioSessionRouteChangeReasonOverride)
    {
        [self setupIOUnit];
        
        if (self.delegate && [self.delegate respondsToSelector:@selector(audioIOPortChanged)]) {
            [self.delegate audioIOPortChanged];
        }
    }
    
    if ([port.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
        [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
    }
    

}


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Audio setup
////////////////////////////////////////////////////////////////////////////////

- (BOOL)setupAudioSession
{
    @try
    {
        NSError *error = nil;

        /*---------------------------------------------------------------------*
         * Configure the audio session
         *--------------------------------------------------------------------*/
        AVAudioSession *sessionInstance = [AVAudioSession sharedInstance];

        
        AVAudioSessionPortDescription *port = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject;
        
        
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
            [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
        }
        
        /*---------------------------------------------------------------------*
         * Set preferred sample rate.
         *--------------------------------------------------------------------*/
        [sessionInstance setPreferredSampleRate:44100 error:&error];
        XThrowIfError((OSStatus)error.code, @"Couldn't set session's preferred sample rate");

        
        /*---------------------------------------------------------------------*
         * Register for audio input and output.
         *--------------------------------------------------------------------*/
        [sessionInstance setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
        XThrowIfError((OSStatus)error.code, @"Couldn't set session's audio category");

        /*---------------------------------------------------------------------*
         * Set up a low-latency buffer.
         *--------------------------------------------------------------------*/
        NSTimeInterval bufferDuration = (float) AUDIO_BUFFER_SIZE / sessionInstance.sampleRate;
        [sessionInstance setPreferredIOBufferDuration:bufferDuration error:&error];
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
         * If media services are reset, we need to rebuild our audio chain.
         *--------------------------------------------------------------------*/
        [notificationCenter addObserver:self
                               selector:@selector(reset:)
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
        [sessionInstance setActive:YES error:&error];
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
    
    if (self.audioIOUnit) {
        [self stop];
    }
    
    @try
    {
        
        DLog(@"setting up io unit : %f", [AVAudioSession sharedInstance].sampleRate);
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
        audioFormat.mSampleRate         = [AVAudioSession sharedInstance].sampleRate;
        audioFormat.mFormatID           = kAudioFormatLinearPCM;
        audioFormat.mFormatFlags        = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        audioFormat.mFramesPerPacket    = 1;
        audioFormat.mChannelsPerFrame   = 1;
        audioFormat.mBitsPerChannel     = 8 * sizeof(float);
        audioFormat.mBytesPerFrame      = sizeof(float) * audioFormat.mChannelsPerFrame;
        audioFormat.mBytesPerPacket     = audioFormat.mBytesPerFrame * audioFormat.mFramesPerPacket;

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
        cd.delegate = self.delegate;
        
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
        NSLog(@"could not setup audio unit");
        return NO;
    }
}

- (BOOL)setupAudioChain
{
    /*---------------------------------------------------------------------*
     * Initialise our audio chain:
     *  - set our AVAudioSession configuration
     *  - create a remote I/O unit and register an I/O callback
     *--------------------------------------------------------------------*/
    [self setupAudioSession];
    [self setupIOUnit];

    return YES;
}

- (void)dealloc
{
    /*---------------------------------------------------------------------*
     * Be a good citizen, remove any dangling observers when we depart.
     *--------------------------------------------------------------------*/
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter removeObserver:self];
    
    AVAudioSession *sessionInstance = [AVAudioSession sharedInstance];
    [sessionInstance removeObserver:self forKeyPath:@"outputVolume"];
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


- (double)sampleRate
{
    return [[AVAudioSession sharedInstance] sampleRate];
}

- (double)volume
{
	return [[AVAudioSession sharedInstance] outputVolume];
}

- (BOOL)audioChainIsBeingReconstructed
{
    return _audioChainIsBeingReconstructed;
}

- (void)setVolumeChangedBlock:(audio_volume_change_callback_t)block
{
    self.volumeBlock = block;
}



@end

