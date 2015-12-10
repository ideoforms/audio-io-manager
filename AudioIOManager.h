/*----------------------------------------------------------------------------*
 *
 *  AudioIOManager
 *
 *  Singleton object that creates an iOS audio session and registers
 *  a C function callback for input and output of audio samples:
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
 *  Copyright (c) Daniel Jones 2015 <http://www.erase.net/>
 *  Provided under the MIT License. <https://opensource.org/licenses/MIT>
 *
 *----------------------------------------------------------------------------*/

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVAudioSession.h>


/**-----------------------------------------------------------------------------
 * Typedef for the audio data I/O callback.
 *
 * When this function is called, `data` contains input samples.
 * To write output samples, overwrite the contents of `data`.
 *----------------------------------------------------------------------------*/
typedef void (*audio_callback_t)(float **data, int num_channels, int num_frames);

@interface AudioIOManager : NSObject

/**-----------------------------------------------------------------------------
 * Returns YES if the IO manager has initialised successfully.
 * Initialisation happens automatically when the object is created.
 *----------------------------------------------------------------------------*/
@property (assign) BOOL isInitialised;

/**-----------------------------------------------------------------------------
 * Create a new audio I/O unit.
 *
 * @param callback A pure C function called when an audio buffer is available.
 *----------------------------------------------------------------------------*/
- (id)          initWithCallback:(audio_callback_t)callback;

/**-----------------------------------------------------------------------------
 * Start audio.
 *----------------------------------------------------------------------------*/
- (OSStatus)    start;

/**-----------------------------------------------------------------------------
 * Stop audio.
 *----------------------------------------------------------------------------*/
- (OSStatus)    stop;

/**-----------------------------------------------------------------------------
 * Returns the current session's sample rate.
 *----------------------------------------------------------------------------*/
- (double)      sessionSampleRate;

@end
