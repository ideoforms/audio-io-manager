# AudioIOManager

A minimal audio driver for iOS.

## Usage

```
static int pos = 0;

void audio_callback(float **samples, int num_channels, int num_frames)
{
  for (int c = 0; c < num_channels; c++)
  {
    for (int i = 0; i < num_frames; i++)
    {
       samples[c][i] = sin(M_PI * 2.0 * 440.0 * pos++ / 44100.0);
    }
  }
}

AudioIOManager *manager = [[AudioIOManager alloc] initWithCallback:audio_callback];
[manager start];
```
