//
//  ViewController.m
//  AudioIOTester
//
//  Created by Daniel Jones on 07/04/2016.
//  Copyright © 2016 Daniel Jones. All rights reserved.
//

#include <stdio.h>
#include <math.h>

static int pos = 0;

void audio_callback(float **samples, int num_channels, int num_frames, int samplerate)
{
    for (int c = 0; c < num_channels; c++)
    {
        for (int i = 0; i < num_frames; i++)
        {
            samples[c][i] = sin(M_PI * 2.0 * 880.0 * pos++ / samplerate);
            
        }
    }
    // fprintf(stderr, "audio_callback, %d frames\n", num_frames);
}

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.audioIO = [[AudioIOManager alloc] initWithCallback:audio_callback];
    self.audioIO.routeToSpeaker = YES;
    [self.audioIO start];
    
    UITapGestureRecognizer *tapGestureRecognizer =
    [[UITapGestureRecognizer alloc] initWithTarget:self
                                            action:@selector(togglePlayback)];
    [self.view addGestureRecognizer:tapGestureRecognizer];
}

- (void)togglePlayback
{
    if (self.audioIO.isStarted)
        [self.audioIO stop];
    else
        [self.audioIO start];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

@end
