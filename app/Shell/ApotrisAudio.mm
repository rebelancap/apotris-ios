// ApotrisAudio.mm — AVAudioSession policy + the game's master mix gain.
//
// Two knobs, both surfaced in the native Settings sheet's "Audio" section:
//
//   audioMode   what happens when another app is already playing (Music, a
//               podcast, ...). Three of the five modes are pure session
//               category/option choices that iOS enforces for us; the other
//               two ("lower/mute game audio") have no session equivalent —
//               iOS will duck OTHER apps for you, never you — so we attenuate
//               our own mix instead.
//   gameVolume  a plain master volume, multiplied into the same gain.
//
// Who owns the session: we do, entirely. Apotris drives SoLoud's CoreAudio
// (AudioQueue) backend, which never touches AVAudioSession — unlike the SDL
// ports, nothing re-sets the category behind our back. The 4 Hz poll below is
// therefore about "did another app start playing", not about healing SDL.
//
// The gain is NOT the engine's own music/SFX volume settings. Those are
// archived into Apotris.sav and drive the in-game Options sliders; ducking
// through them would write the ducked value back and ratchet the player's real
// volume down over days. SoLoud's global volume sits on top of the whole mix
// (music queue + every SFX voice) and the game never writes it, so it is ours.
// Caveat that makes the once-per-tick write necessary rather than
// once-per-change: Soloud::postinit_internal() resets mGlobalVolume to 1 when
// the backend initialises, which happens on the game thread well after boot.
//
// Playback (not Ambient) in all five modes: a game should keep playing with
// the ring/silent switch off, and only Playback can interrupt other audio.
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <math.h>

#include "soloud.h"

#include "AppBridge.h"

extern SoLoud::Soloud gSoloud;

// How far "Lower Game Audio" pulls the game down: -13 dB. Still audible under
// a podcast, quiet enough to follow the podcast.
static const float kDuckGain = 0.22f;
// Gain ramp time constant. A hard cut when music starts is audible as a click
// on a sustained track; ~0.2 s of exponential glide is not.
static const float kGainTau = 0.20f;

static ApotrisAudioMode gMode = ApotrisAudioDuckOthers;
static float gMasterVolume = 1.0f;
static BOOL gOtherPlaying = NO;
static float gGainTarget = 1.0f;
static float gGainCur = -1.0f; // -1 = never set, so the first tick snaps
static double gPollLast = 0;
static BOOL gBooted = NO;

// The category options this mode wants. Category is Playback throughout; only
// the mixability bits differ.
static NSUInteger optionsForMode(ApotrisAudioMode m) {
    switch (m) {
    case ApotrisAudioStopOthers:
        // Non-mixable: activating the session interrupts the other app.
        return 0;
    case ApotrisAudioDuckOthers:
        return AVAudioSessionCategoryOptionMixWithOthers |
               AVAudioSessionCategoryOptionDuckOthers;
    default:
        // We do our own attenuating in the mix, if any.
        return AVAudioSessionCategoryOptionMixWithOthers;
    }
}

// isOtherAudioPlaying is the broad "someone else has sound out";
// secondaryAudioShouldBeSilencedHint is the narrower "another app is playing
// PRIMARY audio". Either means the player is listening to something else.
static BOOL queryOtherPlaying(AVAudioSession* s) {
    return s.isOtherAudioPlaying || s.secondaryAudioShouldBeSilencedHint;
}

static void loadDefaults(void) {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    // Same keys the SwiftUI @AppStorage settings write, read directly so boot
    // does not depend on the Swift side having wired itself up yet.
    id mode = [d objectForKey:@"audioMode"];
    if (mode) {
        int v = [mode intValue];
        if (v >= 0 && v < ApotrisAudioModeCount)
            gMode = (ApotrisAudioMode)v;
    }
    id vol = [d objectForKey:@"gameVolume"];
    if (vol)
        gMasterVolume = fmaxf(0.0f, fminf(1.0f, [vol floatValue]));
}

static void recomputeTarget(void) {
    float duck = 1.0f;
    if (gOtherPlaying) {
        if (gMode == ApotrisAudioDuckGame)
            duck = kDuckGain;
        else if (gMode == ApotrisAudioMuteGame)
            duck = 0.0f;
    }
    float t = gMasterVolume * duck;
    if (fabsf(t - gGainTarget) > 0.0005f)
        NSLog(@"[apotris] audio: mix gain -> %.2f (volume %.2f, duck %.2f, "
              @"other %s)",
              t, gMasterVolume, duck, gOtherPlaying ? "yes" : "no");
    gGainTarget = t;
}

static void applySession(void) {
    AVAudioSession* s = [AVAudioSession sharedInstance];
    NSUInteger want = optionsForMode(gMode);
    NSError* err = nil;

    if (![s.category isEqualToString:AVAudioSessionCategoryPlayback] ||
        s.categoryOptions != want) {
        if (![s setCategory:AVAudioSessionCategoryPlayback
                       mode:AVAudioSessionModeDefault
                    options:want
                      error:&err])
            NSLog(@"[apotris] audio: setCategory(mode %d, opts %lu) failed: %@",
                  (int)gMode, (unsigned long)want, err);
        else
            NSLog(@"[apotris] audio: session -> Playback opts %lu (mode %d)",
                  (unsigned long)want, (int)gMode);
    }

    // Interrupting the other app happens at setActive:YES with a non-mixable
    // category, and setActive:YES on an already-active session is a no-op. So
    // when the player switches INTO this mode mid-session, bounce the session
    // once to make it take. Losing that race is survivable — the mode is read
    // back at boot, before the session is ever activated, so the next launch
    // is right regardless.
    if (gMode == ApotrisAudioStopOthers) {
        [s setActive:YES error:nil];
        if (queryOtherPlaying(s)) {
            [s setActive:NO
                    withOptions:
                        AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                          error:nil];
            if (![s setActive:YES error:&err])
                NSLog(@"[apotris] audio: reactivate to interrupt other audio "
                      @"failed: %@",
                      err);
        }
    }

    gOtherPlaying = queryOtherPlaying(s);
    recomputeTarget();
}

extern "C" {

void apotris_audio_boot(void) {
    if (gBooted)
        return;
    gBooted = YES;

    loadDefaults();
    applySession();
    // The FIRST activation is the one that interrupts other audio, and it has
    // to happen before SoLoud opens its AudioQueue on the game thread.
    [[AVAudioSession sharedInstance] setActive:YES error:nil];

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    // Each of these is a moment the session may have been reconfigured under us
    // or the "is anyone else playing" answer may have changed.
    for (NSNotificationName n in @[
             AVAudioSessionRouteChangeNotification,
             AVAudioSessionSilenceSecondaryAudioHintNotification,
             UIApplicationDidBecomeActiveNotification
         ])
        [nc addObserverForName:n
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) { applySession(); }];

    // An interruption (phone call, Siri, an alarm) deactivates the session and
    // stops SoLoud's AudioQueue. Nothing restarts it — and the app is not
    // necessarily backgrounded, so the foreground path may never run. Revive it
    // here, but only if we are actually frontmost: on visionOS a closed window
    // leaves the process running with audio deliberately suspended.
    [nc addObserverForName:AVAudioSessionInterruptionNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
                  NSNumber* type =
                      note.userInfo[AVAudioSessionInterruptionTypeKey];
                  BOOL ended = type.unsignedIntegerValue ==
                               AVAudioSessionInterruptionTypeEnded;
                  if (ended && UIApplication.sharedApplication.applicationState ==
                                   UIApplicationStateActive) {
                      [[AVAudioSession sharedInstance] setActive:YES error:nil];
                      if (gSoloud.mBackendResumeFunc)
                          gSoloud.mBackendResumeFunc(&gSoloud);
                      NSLog(@"[apotris] audio: interruption ended — session "
                            @"reactivated");
                  }
                  applySession();
                }];

    AVAudioSession* s = [AVAudioSession sharedInstance];
    NSLog(@"[apotris] audio: boot mode %d, volume %.2f — session %@ opts %lu, "
          @"other playing %s",
          (int)gMode, gMasterVolume, s.category,
          (unsigned long)s.categoryOptions, gOtherPlaying ? "yes" : "no");
}

void apotris_audio_set_mode(int mode) {
    if (mode < 0 || mode >= ApotrisAudioModeCount)
        return;
    if ((ApotrisAudioMode)mode == gMode)
        return;
    gMode = (ApotrisAudioMode)mode;
    if (gBooted)
        applySession();
}

void apotris_audio_set_volume(float volume) {
    gMasterVolume = fmaxf(0.0f, fminf(1.0f, volume));
    recomputeTarget();
}

// Called from the game thread when the app comes back to the foreground (the
// session is deactivated while backgrounded, and on visionOS a closed window
// stops the AudioQueue outright). The immediate activation is what lets the
// caller restart the queue; the category re-assert goes to the main thread,
// where every other mutation of this module's state happens.
void apotris_audio_reactivate(void) {
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gBooted)
            applySession();
    });
}

void apotris_audio_tick(void) {
    double now = CACurrentMediaTime();
    static double lastFrame = 0;
    double dt = lastFrame ? now - lastFrame : 0;
    lastFrame = now;

    // Poll at 4 Hz: nothing posts a notification when the player simply hits
    // play in another app while Apotris is frontmost.
    if (now - gPollLast >= 0.25) {
        gPollLast = now;
        AVAudioSession* s = [AVAudioSession sharedInstance];
        BOOL other = queryOtherPlaying(s);
        if (other != gOtherPlaying) {
            gOtherPlaying = other;
            NSLog(@"[apotris] audio: other app audio %s",
                  other ? "started" : "stopped");
        }
        if (gBooted &&
            (![s.category isEqualToString:AVAudioSessionCategoryPlayback] ||
             s.categoryOptions != optionsForMode(gMode)))
            applySession(); // something changed it under us — put it back
        recomputeTarget();
    }

    // Glide toward the target so duck/unduck and slider drags are not a step.
    if (gGainCur < 0.0f)
        gGainCur = gGainTarget; // first tick: no ramp up from silence
    else if (dt > 0 && dt < 0.5) {
        float a = 1.0f - expf(-(float)dt / kGainTau);
        gGainCur += (gGainTarget - gGainCur) * a;
        if (fabsf(gGainTarget - gGainCur) < 0.001f)
            gGainCur = gGainTarget;
    } else
        gGainCur = gGainTarget;

    // Unconditionally, not just on change: SoLoud resets its global volume to
    // 1 inside postinit_internal(), which lands on the game thread whenever the
    // backend (re)initialises. Two stores per frame is cheaper than tracking
    // that race.
    gSoloud.setGlobalVolume(gGainCur);
}

} // extern "C"
