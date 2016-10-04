/*----------------------------------------------------------------------------*
 *
 *  AudioIOManager
 *
 *  Singleton object that creates an iOS audio session and registers
 *  a callback to take place when new audio data is available.
 *
 *  The callback can either be in the form of a C function pointer
 *  (see below) or an Objective-C delegate following the AudioIODelegate
 *  protocol.
 *
 *  Example usage:
 *
 *  static int pos = 0;
 *
 *  void audio_callback(float **samples, int num_channels, int num_frames)
 *  {
 *    for (int c = 0; c < num_channels; c++)
 *    {
 *      for (int i = 0; i < num_frames; i++)
 *      {
 *         samples[c][i] = sin(M_PI * 2.0 * 440.0 * pos++ / 44100.0);
 *      }
 *    }
 *  }
 *
 *  AudioIOManager *manager = [[AudioIOManager alloc] initWithCallback:audio_callback];
 *  [manager start];
 *
 *  Copyright (c) Daniel Jones 2015-2016 <http://www.erase.net/>
 *  Provided under the MIT License. <https://opensource.org/licenses/MIT>
 * 
 *  AUTHORS
 *  Daniel Jones <http://www.erase.net/>      
 *  James Nesfield <http://jamesnesfield.com/>        
 *
 *----------------------------------------------------------------------------*/

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define AUDIO_BUFFER_SIZE 256
#define AUDIO_PREFERRED_SAMPLE_RATE 44100
#define AUDIO_PREFERRED_SESSION_MODE AVAudioSessionModeMeasurement

/**-----------------------------------------------------------------------------
 * Typedef for the audio data I/O callback.
 *
 * When this function is called, `data` contains input samples.
 * To write output samples, overwrite the contents of `data`.
 *----------------------------------------------------------------------------*/
typedef void (*audio_data_callback_t)(float **data, int num_channels, int num_frames, int samplerate);
typedef void (*audio_volume_change_callback_t)(float volume);


/**-----------------------------------------------------------------------------
 * Protocol for delegates to follow.
 *----------------------------------------------------------------------------*/
@protocol AudioIODelegate<NSObject>
@optional

/**-----------------------------------------------------------------------------
 * Called when a new audio buffer is available.
 *----------------------------------------------------------------------------*/
- (void)audioCallback:(AudioBufferList *)bufferList
            numFrames:(UInt32)numFrames;

/**-----------------------------------------------------------------------------
 * Called when the IO port is changed (eg, from speaker to headphones)
 *----------------------------------------------------------------------------*/
- (void) audioIOPortChanged;

@end


@interface AudioIOManager : NSObject

/**-----------------------------------------------------------------------------
 * Returns YES if the IO manager has initialised successfully.
 * Initialisation happens automatically when the object is created.
 *----------------------------------------------------------------------------*/
@property (assign) BOOL isInitialised;


/**-----------------------------------------------------------------------------
 * Returns YES if audio playback has started.
 *----------------------------------------------------------------------------*/
@property (assign) BOOL isStarted;

/**-----------------------------------------------------------------------------
 * Delegate.
 *----------------------------------------------------------------------------*/
@property (weak) id <AudioIODelegate> delegate;

/**-----------------------------------------------------------------------------
 * Create a new audio I/O unit.
 *
 * @param callback A pure C function called when an audio buffer is available.
 *----------------------------------------------------------------------------*/
- (id)          initWithCallback:(audio_data_callback_t)callback;

/**-----------------------------------------------------------------------------
 * Create a new audio I/O unit.
 *
 * @param delegate Delegate object, observing the AudioIODelegate protocol.
 *----------------------------------------------------------------------------*/
- (id)          initWithDelegate:(id <AudioIODelegate>)delegate;

/**-----------------------------------------------------------------------------
 * Set volume change callback.
 *
 * @param callback A pure C function called when system volume is changed.
 *----------------------------------------------------------------------------*/
- (void)        setVolumeChangedBlock:(audio_volume_change_callback_t)callback;

/**-----------------------------------------------------------------------------
 * Setup the audio chain. 
 *----------------------------------------------------------------------------*/
- (BOOL)        setup;

/**-----------------------------------------------------------------------------
 * Start audio.
 *----------------------------------------------------------------------------*/
- (OSStatus)    start;

/**-----------------------------------------------------------------------------
 * Stop audio.
 *----------------------------------------------------------------------------*/
- (OSStatus)    stop;

/**-----------------------------------------------------------------------------
 * Tear down audio IO.
 *----------------------------------------------------------------------------*/
- (BOOL)        teardown;

/**-----------------------------------------------------------------------------
 * Returns the current session's actual sample rate.
 *----------------------------------------------------------------------------*/
- (double)      sampleRate;

/**-----------------------------------------------------------------------------
 * Returns the current session's hardware output volume [0, 1]
 *----------------------------------------------------------------------------*/
- (double)      volume;

/**-----------------------------------------------------------------------------
 * Set to YES to route output audio to the device's speaker.
 * Must be set prior to initializing the audio chain.
 *----------------------------------------------------------------------------*/
@property (assign) BOOL routeToSpeaker;

/**-----------------------------------------------------------------------------
 * Set to YES to allow background audio (from iTunes etc) to continue
 * playing while this app is foregrounded.
 *----------------------------------------------------------------------------*/
@property (assign) BOOL mixWithOtherAudio;

/**-----------------------------------------------------------------------------
 * Set the microphone orientation and polar response
 * @param orientation   An AVAudioSessionOrientation NSString
 * @param pattern       An AVAudioSessionPolarPattern NSString
 *----------------------------------------------------------------------------*/
- (BOOL) selectInputOrientation:(NSString *)orientation polarPattern:(NSString *) pattern;


/**-----------------------------------------------------------------------------
 * Debugging macros.
 *----------------------------------------------------------------------------*/
#ifndef DLog
    #ifdef DEBUG
        #define DLog(...) NSLog(__VA_ARGS__)
    #else
        #define DLog(...)
    #endif
#endif

@end
