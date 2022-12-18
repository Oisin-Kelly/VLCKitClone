/*****************************************************************************
 * VLCMediaPlayer.m: VLCKit.framework VLCMediaPlayer implementation
 *****************************************************************************
 * Copyright (C) 2007-2009 Pierre d'Herbemont
 * Copyright (C) 2007-2022 VLC authors and VideoLAN
 * Partial Copyright (C) 2009-2020 Felix Paul Kühne
 * $Id$
 *
 * Authors: Pierre d'Herbemont <pdherbemont # videolan.org>
 *          Faustion Osuna <enrique.osuna # gmail.com>
 *          Felix Paul Kühne <fkuehne # videolan.org>
 *          Soomin Lee <TheHungryBu # gmail.com>
 *          Maxime Chapelet <umxprime # videolabs.io>
 *
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import <VLCLibrary.h>
#import <VLCLibVLCBridging.h>
#import <VLCMediaPlayer.h>
#import <VLCTime.h>
#import <VLCMediaPlayer+Internal.h>
#import <VLCAdjustFilter.h>
#if !TARGET_OS_IPHONE
# import <VLCVideoView.h>
#endif // !TARGET_OS_IPHONE
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#if !TARGET_OS_IPHONE
/* prevent system sleep */
# import <CoreServices/CoreServices.h>
/* FIXME: Ugly hack! */
# ifdef __x86_64__
#  import <CoreServices/../Frameworks/OSServices.framework/Headers/Power.h>
# endif
#endif // !TARGET_OS_IPHONE

#include <vlc/vlc.h>

/* Notification Messages */
NSNotificationName const VLCMediaPlayerTimeChangedNotification = @"VLCMediaPlayerTimeChangedNotification";
NSNotificationName const VLCMediaPlayerStateChangedNotification = @"VLCMediaPlayerStateChangedNotification";
NSNotificationName const VLCMediaPlayerTitleSelectionChangedNotification = @"VLCMediaPlayerTitleSelectionChangedNotification";
NSNotificationName const VLCMediaPlayerTitleListChangedNotification = @"VLCMediaPlayerTitleListChangedNotification";
NSNotificationName const VLCMediaPlayerChapterChangedNotification = @"VLCMediaPlayerChapterChangedNotification";
NSNotificationName const VLCMediaPlayerSnapshotTakenNotification = @"VLCMediaPlayerSnapshotTakenNotification";

/* title keys */
NSString *const VLCTitleDescriptionName         = @"VLCTitleDescriptionName";
NSString *const VLCTitleDescriptionDuration     = @"VLCTitleDescriptionDuration";
NSString *const VLCTitleDescriptionIsMenu       = @"VLCTitleDescriptionIsMenu";

/* chapter keys */
NSString *const VLCChapterDescriptionName       = @"VLCChapterDescriptionName";
NSString *const VLCChapterDescriptionTimeOffset = @"VLCChapterDescriptionTimeOffset";
NSString *const VLCChapterDescriptionDuration   = @"VLCChapterDescriptionDuration";

NSString * VLCMediaPlayerStateToString(VLCMediaPlayerState state)
{
    static NSString * stateToStrings[] = {
        [VLCMediaPlayerStateStopped]      = @"VLCMediaPlayerStateStopped",
        [VLCMediaPlayerStateStopping]     = @"VLCMediaPlayerStateStopping",
        [VLCMediaPlayerStateOpening]      = @"VLCMediaPlayerStateOpening",
        [VLCMediaPlayerStateBuffering]    = @"VLCMediaPlayerStateBuffering",
        [VLCMediaPlayerStateError]        = @"VLCMediaPlayerStateError",
        [VLCMediaPlayerStatePlaying]      = @"VLCMediaPlayerStatePlaying",
        [VLCMediaPlayerStatePaused]       = @"VLCMediaPlayerStatePaused",
        [VLCMediaPlayerStateESAdded]      = @"VLCMediaPlayerStateESAdded"
    };
    return stateToStrings[state];
}

// TODO: Documentation
@interface VLCMediaPlayer (Private)

- (instancetype)initWithDrawable:(id)aDrawable options:(NSArray *)options;

- (void)registerObservers;
- (void)unregisterObservers;
- (dispatch_queue_t)libVLCBackgroundQueue;
- (void)mediaPlayerLastTimePointUpdated:(const libvlc_media_player_time_point_t)newTimePoint;
- (void)mediaPlayerHandleTimeDiscontinuity:(int64_t)systemDate;
- (void)mediaPlayerStateChanged:(const VLCMediaPlayerState)newState;
- (void)mediaPlayerMediaChanged:(VLCMedia *)media;
- (void)mediaPlayerTitleSelectionChanged:(const int)newTitle;
- (void)mediaPlayerChapterChanged:(NSNumber *)newChapter;
- (void)mediaPlayerTitleListChanged:(NSString *)newTitleList;

- (void)mediaPlayerSnapshot:(NSString *)fileName;
- (void)mediaPlayerRecordChanged:(NSArray *)arguments;
@end

static void HandleWatchTimeUpdate(const libvlc_media_player_time_point_t *value, void *data)
{
    if (value == NULL || value->ts_us == -1) {
        return;
    }
    libvlc_media_player_time_point_t const newValue = *value;
    @autoreleasepool {
        VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)data;
        dispatch_async(dispatch_get_main_queue(), ^{
            [mediaPlayer mediaPlayerLastTimePointUpdated:newValue];
        });
    }
}

static void HandleWatchTimeDiscontinuity(libvlc_time_t system_date, void *data)
{
    @autoreleasepool {
        VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)data;
        dispatch_async(dispatch_get_main_queue(), ^{
            [mediaPlayer mediaPlayerHandleTimeDiscontinuity:system_date];
        });
    }
}

static void HandleMediaInstanceStateChanged(const libvlc_event_t * event, void * self)
{
    VLCMediaPlayerState newState;

    switch (event->type) {
        case libvlc_MediaPlayerPlaying:
            newState = VLCMediaPlayerStatePlaying;
            break;
        case libvlc_MediaPlayerPaused:
            newState = VLCMediaPlayerStatePaused;
            break;
        case libvlc_MediaPlayerStopping:
            newState = VLCMediaPlayerStateStopping;
            break;
        case libvlc_MediaPlayerStopped:
            newState = VLCMediaPlayerStateStopped;
            break;
        case libvlc_MediaPlayerEncounteredError:
            newState = VLCMediaPlayerStateError;
            break;
        case libvlc_MediaPlayerBuffering:
            newState = VLCMediaPlayerStateBuffering;
            break;
        case libvlc_MediaPlayerOpening:
            newState = VLCMediaPlayerStateOpening;
            break;
        case libvlc_MediaPlayerESAdded:
            newState = VLCMediaPlayerStateESAdded;
            break;
        case libvlc_MediaPlayerESDeleted:
            newState = VLCMediaPlayerStateESDeleted;
            break;
        case libvlc_MediaPlayerLengthChanged:
            newState = VLCMediaPlayerStateLengthChanged;
            break;

        default:
            VKLog(@"%s: Unknown event", __FUNCTION__);
            return;
    }

    @autoreleasepool {
        VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [mediaPlayer mediaPlayerStateChanged: newState];
            NSNotification *notification = [NSNotification notificationWithName: VLCMediaPlayerStateChangedNotification object: mediaPlayer];
            [[NSNotificationCenter defaultCenter] postNotification: notification];
            if([mediaPlayer.delegate respondsToSelector:@selector(mediaPlayerStateChanged:)])
                [mediaPlayer.delegate mediaPlayerStateChanged: notification];
        });
    }
}

static void HandleMediaPlayerMediaChanged(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)self;
        VLCMedia *newMedia = [VLCMedia mediaWithLibVLCMediaDescriptor: event->u.media_player_media_changed.new_media];
        dispatch_async(dispatch_get_main_queue(), ^{
            [mediaPlayer mediaPlayerMediaChanged: newMedia];
        });
    }
}

static void HandleMediaTitleSelectionChanged(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)self;
        const int index = event->u.media_player_title_selection_changed.index;
        dispatch_async(dispatch_get_main_queue(), ^{
            [mediaPlayer mediaPlayerTitleSelectionChanged: index];
            NSNotification *notification = [NSNotification notificationWithName: VLCMediaPlayerTitleSelectionChangedNotification object: mediaPlayer];
            [[NSNotificationCenter defaultCenter] postNotification: notification];
            if([mediaPlayer.delegate respondsToSelector:@selector(mediaPlayerTitleSelectionChanged:)])
                [mediaPlayer.delegate mediaPlayerTitleSelectionChanged: notification];
        });
    }
}

static void HandleMediaTitleListChanged(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            // TODO: - What does it mean to send a notification name?
            [mediaPlayer mediaPlayerTitleListChanged: VLCMediaPlayerTitleListChangedNotification];
            NSNotification *notification = [NSNotification notificationWithName: VLCMediaPlayerTitleListChangedNotification object: mediaPlayer];
            [[NSNotificationCenter defaultCenter] postNotification: notification];
            if([mediaPlayer.delegate respondsToSelector:@selector(mediaPlayerTitleListChanged:)])
                [mediaPlayer.delegate mediaPlayerTitleListChanged: notification];
        });
    }
}

static void HandleMediaChapterChanged(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotification *notification = [NSNotification notificationWithName: VLCMediaPlayerChapterChangedNotification object: mediaPlayer];
            [[NSNotificationCenter defaultCenter] postNotification: notification];
            if([mediaPlayer.delegate respondsToSelector:@selector(mediaPlayerChapterChanged:)])
                [mediaPlayer.delegate mediaPlayerChapterChanged: notification];
        });
    }
}

static void HandleMediaPlayerSnapshot(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        const char *psz_filename = event->u.media_player_snapshot_taken.psz_filename;
        if (psz_filename) {
            NSString *fileName = @(psz_filename);
            VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [mediaPlayer mediaPlayerSnapshot: fileName];
                NSNotification *notification = [NSNotification notificationWithName: VLCMediaPlayerSnapshotTakenNotification object: mediaPlayer];
                [[NSNotificationCenter defaultCenter] postNotification: notification];
                if([mediaPlayer.delegate respondsToSelector:@selector(mediaPlayerSnapshot:)])
                    [mediaPlayer.delegate mediaPlayerSnapshot: notification];
            });
        }
    }
}

static void HandleMediaPlayerRecord(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMediaPlayer *mediaPlayer = (__bridge VLCMediaPlayer *)self;
        NSArray *arg = @[
            @{
                @"filePath": [NSString stringWithFormat:@"%s", event->u.media_player_record_changed.recorded_file_path],
                @"isRecording": @(event->u.media_player_record_changed.recording)
            }
        ];
        dispatch_async(dispatch_get_main_queue(), ^{
            [mediaPlayer mediaPlayerRecordChanged: arg];
        });
    }
}

@interface VLCMediaPlayer ()
{
    VLCLibrary *_privateLibrary;                ///< Internal
    libvlc_media_player_t * _playerInstance;    ///< Internal
    VLCMedia * _media;                          ///< Current media being played
    libvlc_media_player_time_point_t _lastTimePoint; ///< Cached time point of the media being played
    double _lastInterpolatedPosition;           ///< Cached position of the media being played
    int64_t _lastInterpolatedTime;              ///< Cached time of the media being played
    int64_t _systemDateOfDiscontinuity;
    BOOL _timeDiscontinuityState;
    VLCMediaPlayerState _cachedState;           ///< Cached state of the media being played
    id _drawable;                               ///< The drawable associated to this media player
    NSMutableArray *_snapshots;                 ///< Array with snapshot file names
    VLCAudio *_audio;                           ///< The audio controller
    libvlc_equalizer_t *_equalizerInstance;     ///< The equalizer controller
    BOOL _equalizerEnabled;                     ///< Equalizer state
    libvlc_video_viewpoint_t *_viewpoint;       ///< Current viewpoint of the media
    dispatch_queue_t _libVLCBackgroundQueue;    ///< Background dispatch queue to call libvlc
    int64_t _minimalWatchTimePeriod;            ///< Minimal period for the watch timer
    __block NSTimer *_timeChangeUpdateTimer;    ///< Timer used to update time watch point interpolation on regular intervals
}
@end

@implementation VLCMediaPlayer
@synthesize libraryInstance = _privateLibrary;

/* Bindings */
+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key
{
    static NSDictionary * dict = nil;
    NSSet * superKeyPaths;
    if (!dict) {
        dict = @{@"playing": [NSSet setWithObject:@"state"],
                @"seekable": [NSSet setWithObjects:@"state", @"media", nil],
                @"canPause": [NSSet setWithObjects:@"state", @"media", nil],
                @"description": [NSSet setWithObjects:@"state", @"media", nil]};
    }
    if ((superKeyPaths = [super keyPathsForValuesAffectingValueForKey: key])) {
        NSMutableSet * ret = [NSMutableSet setWithSet:dict[key]];
        [ret unionSet:superKeyPaths];
        return ret;
    }
    return dict[key];
}

/* Constructor */
- (instancetype)init
{
    return [self initWithDrawable:nil options:nil];
}

- (instancetype)initCommon
{
    if (self = [super init]) {
        _adjustFilter = [VLCAdjustFilter createWithVLCMediaPlayer:self];
    }
    return self;
}

- (instancetype)initWithLibrary:(VLCLibrary *)library
{
    if (self = [self initCommon]) {
        _lastTimePoint.ts_us = -1;
        _timeChangeUpdateInterval = 0.0;
        _cachedState = VLCMediaPlayerStateStopped;
        _libVLCBackgroundQueue = [self libVLCBackgroundQueue];
        _minimalWatchTimePeriod = 500000;
        _privateLibrary = library;
        _playerInstance = libvlc_media_player_new([_privateLibrary instance]);
        if (_playerInstance == NULL) {
            NSAssert(0, @"%s: player initialization failed", __PRETTY_FUNCTION__);
            libvlc_release([_privateLibrary instance]);
            return nil;
        }

        [self registerObservers];
    }
    return self;

}

- (instancetype)initWithLibVLCInstance:(void *)playerInstance andLibrary:(VLCLibrary *)library
{
    if (self = [self initCommon]) {
        _lastTimePoint.ts_us = -1;
        _timeChangeUpdateInterval = 0.0;
        _cachedState = VLCMediaPlayerStateStopped;
        _libVLCBackgroundQueue = [self libVLCBackgroundQueue];

        _privateLibrary = library;
        libvlc_retain([_privateLibrary instance]);

        _playerInstance = playerInstance;

        [self registerObservers];
    }
    return self;
}

#if !TARGET_OS_IPHONE
- (instancetype)initWithVideoView:(VLCVideoView *)aVideoView
{
    return [self initWithDrawable: aVideoView options:nil];
}

- (instancetype)initWithVideoLayer:(VLCVideoLayer *)aVideoLayer
{
    return [self initWithDrawable: aVideoLayer options:nil];
}

- (instancetype)initWithVideoView:(VLCVideoView *)aVideoView options:(NSArray *)options
{
    return [self initWithDrawable: aVideoView options:options];
}

- (instancetype)initWithVideoLayer:(VLCVideoLayer *)aVideoLayer options:(NSArray *)options
{
    return [self initWithDrawable: aVideoLayer options:options];
}
#endif

- (instancetype)initWithOptions:(NSArray *)options
{
    return [self initWithDrawable:nil options:options];
}

- (void)dealloc
{
    [self unregisterObservers];

    // Always get rid of the delegate first so we can stop sending messages to it
    // TODO: Should we tell the delegate that we're shutting down?
    _delegate = nil;

    // Clear our drawable as we are going to release it, we don't
    // want the core to use it from this point.
    libvlc_media_player_set_nsobject(_playerInstance, nil);
    _drawable = nil;

    if (_equalizerInstance) {
        libvlc_media_player_set_equalizer(_playerInstance, NULL);
        libvlc_audio_equalizer_release(_equalizerInstance);
        _equalizerInstance = nil;
    }

    if (_viewpoint)
        libvlc_free(_viewpoint);

    libvlc_media_player_release(_playerInstance);

    if (_privateLibrary != [VLCLibrary sharedLibrary])
        libvlc_release(_privateLibrary.instance);
}

#if !TARGET_OS_IPHONE
- (void)setVideoView:(VLCVideoView *)aVideoView
{
    [self setDrawable: aVideoView];
}

- (void)setVideoLayer:(VLCVideoLayer *)aVideoLayer
{
    [self setDrawable: aVideoLayer];
}
#endif

- (void)setDrawable:(id)aDrawable
{
    // Make sure that this instance has been associated with the drawing canvas.
    _drawable = aDrawable;

    /* Note that ee need the caller to wait until the setter succeeded.
     * Otherwise, s/he might want to deploy the drawable while it isn’t ready yet. */
    dispatch_sync(_libVLCBackgroundQueue, ^{
        libvlc_media_player_set_nsobject(_playerInstance, (__bridge void *)(aDrawable));
    });
}

- (id)drawable
{
    return (__bridge id)(libvlc_media_player_get_nsobject(_playerInstance));
}

- (VLCAudio *)audio
{
    if (!_audio)
        _audio = [[VLCAudio alloc] initWithMediaPlayer:self];
    return _audio;
}



#pragma mark -
#pragma mark Subtitles

- (int)addPlaybackSlave:(NSURL *)slaveURL type:(VLCMediaPlaybackSlaveType)slaveType enforce:(BOOL)enforceSelection
{
    if (!slaveURL)
        return -1;

    return libvlc_media_player_add_slave(_playerInstance,
                                         (libvlc_media_slave_type_t)slaveType,
                                         [[slaveURL absoluteString] UTF8String],
                                         enforceSelection);
}

- (void)setCurrentVideoSubTitleDelay:(NSInteger)index
{
    libvlc_video_set_spu_delay(_playerInstance, index);
}

- (NSInteger)currentVideoSubTitleDelay
{
    return libvlc_video_get_spu_delay(_playerInstance);
}

- (void)setCurrentSubTitleFontScale:(float)scale
{
    libvlc_video_set_spu_text_scale(_playerInstance, scale);
}

- (float)currentSubTitleFontScale
{
    return libvlc_video_get_spu_text_scale(_playerInstance);
}

#if TARGET_OS_IPHONE
#warning text renderer API needs to be reimplemented in libvlc (#294)
- (void)setTextRendererFontSize:(NSNumber *)fontSize
{
//    libvlc_video_set_textrenderer_int(_playerInstance, libvlc_textrender_fontsize, [fontSize intValue]);
}

- (void)setTextRendererFont:(NSString *)fontname
{
//    libvlc_video_set_textrenderer_string(_playerInstance, libvlc_textrender_font, [fontname UTF8String]);
}

- (void)setTextRendererFontColor:(NSNumber *)fontColor
{
//    libvlc_video_set_textrenderer_int(_playerInstance, libvlc_textrender_fontcolor, [fontColor intValue]);
}

- (void)setTextRendererFontForceBold:(NSNumber *)fontForceBold
{
//    libvlc_video_set_textrenderer_bool(_playerInstance, libvlc_textrender_fontforcebold, [fontForceBold boolValue]);
}
#endif

#pragma mark -
#pragma mark Video Crop geometry

- (void)setCropRatioWithNumerator:(unsigned int)numerator denominator:(unsigned int)denominator
{
    libvlc_video_set_crop_ratio(_playerInstance, numerator, denominator);
}

- (void)setVideoAspectRatio:(char *)value
{
    libvlc_video_set_aspect_ratio(_playerInstance, value);
}

- (char *)videoAspectRatio
{
    char * result = libvlc_video_get_aspect_ratio(_playerInstance);
    return result;
}

- (void)setScaleFactor:(float)value
{
    libvlc_video_set_scale(_playerInstance, value);
}

- (float)scaleFactor
{
    return libvlc_video_get_scale(_playerInstance);
}

- (void)saveVideoSnapshotAt:(NSString *)path withWidth:(int)width andHeight:(int)height
{
    int failure = libvlc_video_take_snapshot(_playerInstance, 0, [path UTF8String], width, height);
    if (failure)
        [[NSException exceptionWithName:@"Can't take a video snapshot" reason:@"No video output" userInfo:nil] raise];
}

- (void)setDeinterlaceFilter:(nullable NSString *)name
{
    if (!name || name.length < 1)
        libvlc_video_set_deinterlace(_playerInstance, VLCDeinterlaceOff, NULL);
    else
        libvlc_video_set_deinterlace(_playerInstance, VLCDeinterlaceOn, [name UTF8String]);
}

- (void)setDeinterlace:(VLCDeinterlace)deinterlace withFilter:(NSString *)name
{
    libvlc_video_set_deinterlace(_playerInstance, (int)deinterlace, [name UTF8String]);
}

#pragma mark - Adjust Video Filter

- (BOOL)isAdjustFilterEnabled
{
    return _adjustFilter.isEnabled;
}
- (void)setAdjustFilterEnabled:(BOOL)b_value
{
    _adjustFilter.enabled = b_value;
}

- (float)contrast
{
    return [_adjustFilter.contrast.value floatValue];
}
- (void)setContrast:(float)f_value
{
    _adjustFilter.contrast.value = @(f_value);
}

- (float)brightness
{
    return [_adjustFilter.brightness.value floatValue];
}
- (void)setBrightness:(float)f_value
{
    _adjustFilter.brightness.value = @(f_value);
}

- (float)hue
{
    return [_adjustFilter.hue.value floatValue];
}
- (void)setHue:(float)f_value
{
    _adjustFilter.hue.value = @(f_value);
}

- (float)saturation
{
    return [_adjustFilter.saturation.value floatValue];
}
- (void)setSaturation:(float)f_value
{
    _adjustFilter.saturation.value = @(f_value);
}

- (float)gamma
{
    return [_adjustFilter.gamma.value floatValue];
}
- (void)setGamma:(float)f_value
{
    _adjustFilter.gamma.value = @(f_value);
}

#pragma mark -

- (void)setRate:(float)value
{
    libvlc_media_player_set_rate(_playerInstance, value);
}

- (float)rate
{
    return libvlc_media_player_get_rate(_playerInstance);
}

- (CGSize)videoSize
{
    unsigned height = 0, width = 0;
    int failure = libvlc_video_get_size(_playerInstance, 0, &width, &height);
    if (failure)
        return CGSizeZero;
    return CGSizeMake(width, height);
}

- (BOOL)hasVideoOut
{
    return libvlc_media_player_has_vout(_playerInstance);
}

- (void)setTime:(VLCTime *)value
{
    // Time is managed in seconds, while duration is managed in microseconds
    // TODO: Redo VLCTime to provide value numberAsMilliseconds, numberAsMicroseconds, numberAsSeconds, numberAsMinutes, numberAsHours
    libvlc_media_player_set_time(_playerInstance, value ? [[value value] longLongValue] : 0, NO);
    [self timeChangeUpdate];
}

- (VLCTime *)time
{
    NSAssert([NSThread isMainThread], @"Must be called from the main thread.");

    if (_lastTimePoint.ts_us == -1) {
        return [VLCTime nullTime];
    }

    return [VLCTime timeWithNumber:@(_lastInterpolatedTime / 1000)];
}

- (VLCTime *)remainingTime
{
    NSAssert([NSThread isMainThread], @"Must be called from the main thread.");

    if (_lastTimePoint.position == 0. || _lastTimePoint.ts_us == -1) {
        return [VLCTime nullTime];
    }
    
    double remaining = ((_lastInterpolatedTime / _lastInterpolatedPosition) - _lastInterpolatedTime) / 1000;
    return [VLCTime timeWithNumber:@(-remaining)];
}

- (void)setMinimalTimePeriod:(int64_t)minimalTimePeriod
{
    _minimalWatchTimePeriod = minimalTimePeriod;
    libvlc_media_player_unwatch_time(_playerInstance);
    libvlc_media_player_watch_time(_playerInstance,
                                   _minimalWatchTimePeriod,
                                   &HandleWatchTimeUpdate,
                                   &HandleWatchTimeDiscontinuity,
                                   (__bridge void *)(self));
}

- (int64_t)minimalTimePeriod
{
    return _minimalWatchTimePeriod;
}

#pragma mark -
#pragma mark Chapters
- (void)setCurrentChapterIndex:(int)value;
{
    libvlc_media_player_set_chapter(_playerInstance, value);
}

- (int)currentChapterIndex
{
    int count = libvlc_media_player_get_chapter_count(_playerInstance);
    if (count <= 0)
        return -1;
    int result = libvlc_media_player_get_chapter(_playerInstance);
    return result;
}

- (void)nextChapter
{
    libvlc_media_player_next_chapter(_playerInstance);
}

- (void)previousChapter
{
    libvlc_media_player_previous_chapter(_playerInstance);
}

#pragma mark -
#pragma mark Titles

- (void)setCurrentTitleIndex:(int)value
{
    libvlc_media_player_set_title(_playerInstance, value);
}

- (int)currentTitleIndex
{
    NSInteger count = libvlc_media_player_get_title_count(_playerInstance);
    if (count <= 0)
        return -1;

    return libvlc_media_player_get_title(_playerInstance);
}

- (int)numberOfTitles
{
    return libvlc_media_player_get_title_count(_playerInstance);
}

- (NSArray *)titleDescriptions
{
    libvlc_title_description_t **titleInfo;
    int numberOfTitleDescriptions = libvlc_media_player_get_full_title_descriptions(_playerInstance, &titleInfo);

    if (numberOfTitleDescriptions < 0)
        return [NSArray array];

    if (numberOfTitleDescriptions == 0) {
        libvlc_title_descriptions_release(titleInfo, numberOfTitleDescriptions);
        return [NSArray array];
    }

    NSMutableArray *array = [[NSMutableArray alloc] initWithCapacity:numberOfTitleDescriptions];

    for (int i = 0; i < numberOfTitleDescriptions; i++) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                           [NSNumber numberWithLongLong:titleInfo[i]->i_duration],
                                           VLCTitleDescriptionDuration,
                                           @(titleInfo[i]->i_flags & libvlc_title_menu),
                                           VLCTitleDescriptionIsMenu,
                                           nil];
        if (titleInfo[i]->psz_name != NULL)
            dictionary[VLCTitleDescriptionName] = [NSString stringWithUTF8String:titleInfo[i]->psz_name];
        [array addObject:[NSDictionary dictionaryWithDictionary:dictionary]];
    }
    libvlc_title_descriptions_release(titleInfo, numberOfTitleDescriptions);

    return [NSArray arrayWithArray:array];
}

- (int)indexOfLongestTitle
{
    NSArray *titles = [self titleDescriptions];
    NSUInteger titleCount = titles.count;

    int currentlyFoundTitle = 0;
    int64_t currentlySelectedDuration = 0;
    int64_t randomTitleDuration = 0;

    for (int x = 0; x < titleCount; x++) {
        randomTitleDuration = [[titles[x] valueForKey:VLCTitleDescriptionDuration] longLongValue];
        if (randomTitleDuration > currentlySelectedDuration) {
            currentlySelectedDuration = randomTitleDuration;
            currentlyFoundTitle = x;
        }
    }

    return currentlyFoundTitle;
}

- (int)numberOfChaptersForTitle:(int)titleIndex
{
    if (titleIndex >= 0) {
        return libvlc_media_player_get_chapter_count_for_title(_playerInstance, titleIndex);
    }
    return 0;
}

- (NSArray *)chapterDescriptionsOfTitle:(int)titleIndex
{
    libvlc_chapter_description_t **chapterDescriptions;
    int numberOfChapterDescriptions = libvlc_media_player_get_full_chapter_descriptions(_playerInstance,
                                                                                        titleIndex,
                                                                                        &chapterDescriptions);

    if (numberOfChapterDescriptions < 0)
        return [NSArray array];

    if (numberOfChapterDescriptions == 0) {
        libvlc_chapter_descriptions_release(chapterDescriptions, numberOfChapterDescriptions);
        return [NSArray array];
    }

    NSMutableArray *array = [[NSMutableArray alloc] initWithCapacity:numberOfChapterDescriptions];

    for (int i = 0; i < numberOfChapterDescriptions; i++) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                           [NSNumber numberWithLongLong:chapterDescriptions[i]->i_duration],
                                           VLCChapterDescriptionDuration,
                                           [NSNumber numberWithLongLong:chapterDescriptions[i]->i_time_offset],
                                           VLCChapterDescriptionTimeOffset,
                                           nil];
        if (chapterDescriptions[i]->psz_name != NULL)
            dictionary[VLCChapterDescriptionName] = [NSString stringWithUTF8String:chapterDescriptions[i]->psz_name];
        [array addObject:[NSDictionary dictionaryWithDictionary:dictionary]];
    }

    libvlc_chapter_descriptions_release(chapterDescriptions, numberOfChapterDescriptions);

    return [NSArray arrayWithArray:array];
}

#pragma mark -
#pragma mark Audio tracks

- (void)setAudioChannel:(int)value
{
    libvlc_audio_set_channel(_playerInstance, value);
}

- (int)audioChannel
{
    return libvlc_audio_get_channel(_playerInstance);
}

- (void)setCurrentAudioPlaybackDelay:(NSInteger)index
{
    libvlc_audio_set_delay(_playerInstance, index);
}

- (NSInteger)currentAudioPlaybackDelay
{
    return libvlc_audio_get_delay(_playerInstance);
}

#pragma mark -
#pragma mark equalizer

- (void)setEqualizerEnabled:(BOOL)equalizerEnabled
{
    if (!_equalizerInstance && equalizerEnabled) {
        if (!(_equalizerInstance = libvlc_audio_equalizer_new())) {
            NSAssert(_equalizerInstance, @"equalizer failed to initialize");
            return;
        }
    }

    _equalizerEnabled = equalizerEnabled;
    libvlc_media_player_set_equalizer(_playerInstance,
                                      equalizerEnabled ? _equalizerInstance : NULL);
}

- (BOOL)equalizerEnabled
{
    return _equalizerEnabled;
}

- (NSArray *)equalizerProfiles
{
    unsigned count = libvlc_audio_equalizer_get_preset_count();
    NSMutableArray *array = [[NSMutableArray alloc] initWithCapacity:count];
    for (unsigned x = 0; x < count; x++)
        [array addObject:@(libvlc_audio_equalizer_get_preset_name(x))];

    return [NSArray arrayWithArray:array];
}

- (void)resetEqualizerFromProfile:(unsigned)profile
{
    BOOL wasactive = NO;
    if (_equalizerInstance) {
        libvlc_media_player_set_equalizer(_playerInstance, NULL);
        libvlc_audio_equalizer_release(_equalizerInstance);
        _equalizerInstance = nil;
        wasactive = YES;
    }

    _equalizerInstance = libvlc_audio_equalizer_new_from_preset(profile);
    if (wasactive)
        libvlc_media_player_set_equalizer(_playerInstance, _equalizerInstance);
}

- (CGFloat)preAmplification
{
    if (!_equalizerInstance)
        return 0.;

    return libvlc_audio_equalizer_get_preamp(_equalizerInstance);
}

- (void)setPreAmplification:(CGFloat)preAmplification
{
    if (!_equalizerInstance)
        _equalizerInstance = libvlc_audio_equalizer_new();

    libvlc_audio_equalizer_set_preamp(_equalizerInstance, preAmplification);
    libvlc_media_player_set_equalizer(_playerInstance, _equalizerInstance);
}

- (unsigned)numberOfBands
{
    return libvlc_audio_equalizer_get_band_count();
}

- (CGFloat)frequencyOfBandAtIndex:(unsigned int)index
{
    return libvlc_audio_equalizer_get_band_frequency(index);
}

- (void)setAmplification:(CGFloat)amplification forBand:(unsigned int)index
{
    if (!_equalizerInstance)
        _equalizerInstance = libvlc_audio_equalizer_new();

    libvlc_audio_equalizer_set_amp_at_index(_equalizerInstance, amplification, index);
}

- (CGFloat)amplificationOfBand:(unsigned int)index
{
    if (!_equalizerInstance)
        return 0.;

    return libvlc_audio_equalizer_get_amp_at_index(_equalizerInstance, index);
}

#pragma mark -
#pragma mark set/get media

- (void)setMedia:(nullable VLCMedia *)value
{
    if (_media != value) {
        if (_media && [_media compare:value] == NSOrderedSame)
            return;

        _media = value;

        libvlc_media_player_set_media(_playerInstance, [_media libVLCMediaDescriptor]);
    }
}

- (nullable VLCMedia *)media
{
    return _media;
}

#pragma mark -
#pragma mark playback

#if !TARGET_OS_IPHONE
- (void)delaySleep
{
    UpdateSystemActivity(UsrActivity);
}
#endif

- (void)timeChangeUpdate {
    if ( _lastTimePoint.ts_us == -1 ||
        _timeDiscontinuityState ) {
        return;
    }

    int64_t system_now_us = _systemDateOfDiscontinuity > 0 ? _systemDateOfDiscontinuity : libvlc_clock();

    libvlc_media_player_time_point_interpolate(&_lastTimePoint,
                                               system_now_us,
                                               &_lastInterpolatedTime,
                                               &_lastInterpolatedPosition);

    [self willChangeValueForKey:@"time"];
    [self willChangeValueForKey:@"remainingTime"];
    [self didChangeValueForKey:@"remainingTime"];
    [self didChangeValueForKey:@"time"];

    NSNotification *notification = [NSNotification notificationWithName: VLCMediaPlayerTimeChangedNotification object: self];
    [[NSNotificationCenter defaultCenter] postNotification: notification];
    if ([self.delegate respondsToSelector:@selector(mediaPlayerTimeChanged:)])
        [self.delegate mediaPlayerTimeChanged: notification];

#if !TARGET_OS_IPHONE
    // This seems to be the most relevant place to delay sleeping and screen saver.
    [self delaySleep];
#endif

    [self willChangeValueForKey:@"position"];
    [self didChangeValueForKey:@"position"];
}

- (void)play
{
    dispatch_async(_libVLCBackgroundQueue, ^{
        libvlc_media_player_play(_playerInstance);
    });
    __weak VLCMediaPlayer *weak_player = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [_timeChangeUpdateTimer invalidate];
        [weak_player timeChangeUpdate];
        _timeChangeUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:_timeChangeUpdateInterval
                                                                 repeats:YES
                                                                   block:^(NSTimer * _Nonnull timer) {
            VLCMediaPlayer *player = weak_player;
            if (player == nil) {
                [timer invalidate];
                return;
            }
            [player timeChangeUpdate];
        }];
    });
}

- (void)pause
{
    __weak VLCMediaPlayer *weak_player = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        VLCMediaPlayer *player = weak_player;
        [_timeChangeUpdateTimer invalidate];
    });
    // Pause the stream
    dispatch_async(_libVLCBackgroundQueue, ^{
        libvlc_media_player_set_pause(_playerInstance, 1);
    });
}

- (void)stop
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [_timeChangeUpdateTimer invalidate];
    });
    libvlc_media_player_stop_async(_playerInstance);
}

- (libvlc_video_viewpoint_t *)viewPoint
{
    if (_viewpoint == NULL) {
        _viewpoint = libvlc_video_new_viewpoint();
    }
    return _viewpoint;
}

- (BOOL)updateViewpoint:(float)yaw pitch:(float)pitch roll:(float)roll fov:(float)fov absolute:(BOOL)absolute
{
    if ([self viewPoint]) {
        [self viewPoint]->f_yaw = yaw;
        [self viewPoint]->f_pitch = pitch;
        [self viewPoint]->f_roll = roll;
        [self viewPoint]->f_field_of_view = fov;

        return libvlc_video_update_viewpoint(_playerInstance, _viewpoint, absolute) == 0;
    }
    return NO;
}

- (float)yaw
{
    if ([self viewPoint]) {
        return [self viewPoint]->f_yaw;
    }
    return 0;
}

- (float)pitch
{
    if ([self viewPoint]) {
        return [self viewPoint]->f_pitch;
    }
    return 0;
}

- (float)roll
{
    if ([self viewPoint]) {
        return [self viewPoint]->f_roll;
    }
    return 0;
}

- (float)fov
{
    if ([self viewPoint]) {
        return [self viewPoint]->f_field_of_view;
    }
    return 0;
}

- (void)gotoNextFrame
{
    libvlc_media_player_next_frame(_playerInstance);
}

- (void)fastForward
{
    [self fastForwardAtRate: 2.0];
}

- (void)fastForwardAtRate:(float)rate
{
    [self setRate:rate];
}

- (void)rewind
{
    [self rewindAtRate: 2.0];
}

- (void)rewindAtRate:(float)rate
{
    [self setRate: -rate];
}

- (void)jumpWithOffset:(int)interval {
    if ([self isSeekable]) {
        int currentTime = [[self time] intValue];
        int targetTime = (currentTime + interval);
        VLCTime *newTime = [VLCTime timeWithInt: targetTime];
        [self setTime: newTime];
    }
}

- (void)jumpBackward:(double)interval
{
    [self jumpWithOffset:-( (int)(interval * 1e3) )];
}

- (void)jumpForward:(double)interval
{
    [self jumpWithOffset:( (int)(interval * 1e3) )];
}

- (void)extraShortJumpBackward
{
    [self jumpBackward:3];
}

- (void)extraShortJumpForward
{
    [self jumpForward:3];
}

- (void)shortJumpBackward
{
    [self jumpBackward:10];
}

- (void)shortJumpForward
{
    [self jumpForward:10];
}

- (void)mediumJumpBackward
{
    [self jumpBackward:60];
}

- (void)mediumJumpForward
{
    [self jumpForward:60];
}

- (void)longJumpBackward
{
    [self jumpBackward:300];
}

- (void)longJumpForward
{
    [self jumpForward:300];
}

- (void)performNavigationAction:(VLCMediaPlaybackNavigationAction)action
{
    libvlc_media_player_navigate(_playerInstance, action);
}

+ (NSSet *)keyPathsForValuesAffectingIsPlaying
{
    return [NSSet setWithObjects:@"state", nil];
}

- (BOOL)isPlaying
{
    return libvlc_media_player_is_playing(_playerInstance);
}

- (VLCMediaPlayerState)state
{
    return _cachedState;
}

- (double)position
{
    NSAssert([NSThread isMainThread], @"Must be called from the main thread.");

    
    
    return _lastInterpolatedPosition;
}

- (void)setPosition:(double)newPosition
{
    libvlc_media_player_set_position(_playerInstance, newPosition, NO);
}

- (BOOL)isSeekable
{
    return libvlc_media_player_is_seekable(_playerInstance);
}

- (BOOL)canPause
{
    return libvlc_media_player_can_pause(_playerInstance);
}

- (nullable NSArray *)snapshots
{
    if (!_snapshots)
        return nil;
    
    return [_snapshots copy];
}

#if TARGET_OS_IPHONE
- (nullable UIImage *)lastSnapshot {
    if (_snapshots == nil) {
        return nil;
    }

    @synchronized(_snapshots) {
        if (_snapshots.count == 0)
            return nil;

        return [UIImage imageWithContentsOfFile:[_snapshots lastObject]];
    }
}
#else
- (nullable NSImage *)lastSnapshot {
    if (_snapshots == nil) {
        return nil;
    }

    @synchronized(_snapshots) {
        if (_snapshots.count == 0)
            return nil;

        return [[NSImage alloc] initWithContentsOfFile:[_snapshots lastObject]];
    }
}
#endif

- (void *)libVLCMediaPlayer
{
    return _playerInstance;
}

- (void)startRecordingAtPath:(NSString *)path
{
    libvlc_media_player_record(_playerInstance, YES, [path UTF8String]);
}

- (void)stopRecording
{
    libvlc_media_player_record(_playerInstance, NO, nil);
}


#pragma mark -
#pragma mark - Renderer
#if !TARGET_OS_TV
- (BOOL)setRendererItem:(VLCRendererItem *)item
{
    return libvlc_media_player_set_renderer(_playerInstance, item.libVLCRendererItem) == 0;
}
#endif // !TARGET_OS_TV
@end

@implementation VLCMediaPlayer (Private)
- (instancetype)initWithDrawable:(id)aDrawable options:(NSArray *)options
{
    if (self = [self initCommon]) {
        _lastTimePoint.ts_us = -1;
        _timeChangeUpdateInterval = 0.0;
        _cachedState = VLCMediaPlayerStateStopped;
        _libVLCBackgroundQueue = [self libVLCBackgroundQueue];

        // Create a media instance, it doesn't matter what library we start off with
        // it will change depending on the media descriptor provided to the media
        // instance
        if (options && options.count > 0) {
            VKLog(@"creating player instance with private library as options were given");
            _privateLibrary = [[VLCLibrary alloc] initWithOptions:options];
        } else {
            VKLog(@"creating player instance using shared library");
            _privateLibrary = [VLCLibrary sharedLibrary];
        }
        libvlc_retain([_privateLibrary instance]);
        _playerInstance = libvlc_media_player_new([_privateLibrary instance]);
        if (_playerInstance == NULL) {
            NSAssert(0, @"%s: player initialization failed", __PRETTY_FUNCTION__);
            libvlc_release([_privateLibrary instance]);
            return nil;
        }

        [self registerObservers];

        [self setDrawable:aDrawable];
    }
    return self;
}

static const struct event_handler_entry
{
    libvlc_event_type_t type;
    libvlc_callback_t callback;
} event_entries[] =
{
    { libvlc_MediaPlayerPlaying,          HandleMediaInstanceStateChanged },
    { libvlc_MediaPlayerPaused,           HandleMediaInstanceStateChanged },
    { libvlc_MediaPlayerEncounteredError, HandleMediaInstanceStateChanged },
    { libvlc_MediaPlayerStopping,         HandleMediaInstanceStateChanged },
    { libvlc_MediaPlayerStopped,          HandleMediaInstanceStateChanged },
    { libvlc_MediaPlayerOpening,          HandleMediaInstanceStateChanged },
    { libvlc_MediaPlayerBuffering,        HandleMediaInstanceStateChanged },
    { libvlc_MediaPlayerESAdded,          HandleMediaInstanceStateChanged },

    { libvlc_MediaPlayerMediaChanged,     HandleMediaPlayerMediaChanged  },

    { libvlc_MediaPlayerTitleSelectionChanged, HandleMediaTitleSelectionChanged },
    { libvlc_MediaPlayerChapterChanged,   HandleMediaChapterChanged },
    { libvlc_MediaPlayerTitleListChanged, HandleMediaTitleListChanged },

    { libvlc_MediaPlayerSnapshotTaken,    HandleMediaPlayerSnapshot },
    { libvlc_MediaPlayerRecordChanged,    HandleMediaPlayerRecord },
};

- (void)registerObservers
{
    // Attach event observers into the media instance
    __block libvlc_event_manager_t * p_em = libvlc_media_player_event_manager(_playerInstance);
    if (!p_em)
        return;

    /* We need the caller to wait until this block is done.
     * The initialized object shall not be returned until the event attachments are done. */
    dispatch_sync(_libVLCBackgroundQueue,^{
        size_t entry_count = sizeof(event_entries)/sizeof(event_entries[0]);
        for (size_t i=0; i<entry_count; ++i)
        {
            const struct event_handler_entry *entry = &event_entries[i];
            libvlc_event_attach(p_em, entry->type, entry->callback, (__bridge void *)(self));
        }

        libvlc_media_player_watch_time(_playerInstance,
                                       _minimalWatchTimePeriod,
                                       &HandleWatchTimeUpdate,
                                       &HandleWatchTimeDiscontinuity,
                                       (__bridge void *)(self));
    });
}

- (void)unregisterObservers
{
    libvlc_event_manager_t * p_em = libvlc_media_player_event_manager(_playerInstance);
    if (!p_em)
        return;

    size_t entry_count = sizeof(event_entries)/sizeof(event_entries[0]);
    for (size_t i=0; i<entry_count; ++i)
    {
        const struct event_handler_entry *entry = &event_entries[i];
        libvlc_event_detach(p_em, entry->type, entry->callback, (__bridge void *)(self));
    }

    libvlc_media_player_unwatch_time(_playerInstance);
}

- (dispatch_queue_t)libVLCBackgroundQueue
{
    if (!_libVLCBackgroundQueue) {
        _libVLCBackgroundQueue = dispatch_queue_create("libvlcQueue", DISPATCH_QUEUE_SERIAL);
    }
    return  _libVLCBackgroundQueue;
}

- (void)mediaPlayerLastTimePointUpdated:(const libvlc_media_player_time_point_t)newTimePoint
{
    _timeDiscontinuityState = NO;
    _systemDateOfDiscontinuity = 0;
    _lastTimePoint = newTimePoint;
}

- (void)mediaPlayerHandleTimeDiscontinuity:(int64_t)systemDate
{
    _systemDateOfDiscontinuity = systemDate;
    [self timeChangeUpdate];
    _timeDiscontinuityState = YES;
}

- (void)mediaPlayerStateChanged:(const VLCMediaPlayerState)newState
{
    [self willChangeValueForKey:@"state"];
    _cachedState = newState;
    if ( ! [self isPlaying] ) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_timeChangeUpdateTimer invalidate];
        });
    }
#if TARGET_OS_IPHONE
    // Disable idle timer if player is playing media
    // Exclusion can be made for audio only media
    [UIApplication sharedApplication].idleTimerDisabled = [self isPlaying];
#endif
    [self didChangeValueForKey:@"state"];
}

- (void)mediaPlayerMediaChanged:(VLCMedia *)newMedia
{
    [self willChangeValueForKey:@"media"];
    if (_media != newMedia) {
        _media = newMedia;

        [self willChangeValueForKey:@"time"];
        [self willChangeValueForKey:@"remainingTime"];
        [self willChangeValueForKey:@"position"];
        [self didChangeValueForKey:@"position"];
        [self didChangeValueForKey:@"remainingTime"];
        [self didChangeValueForKey:@"time"];
    }

    [self didChangeValueForKey:@"media"];
}

- (void)mediaPlayerTitleSelectionChanged:(const int)newTitle
{
    [self willChangeValueForKey:@"currentTitleIndex"];
    [self didChangeValueForKey:@"currentTitleIndex"];
}

- (void)mediaPlayerTitleListChanged:(NSString *)string
{
    [self willChangeValueForKey:@"titleDescriptions"];
    [self didChangeValueForKey:@"titleDescriptions"];
}

- (void)mediaPlayerChapterChanged:(NSNumber *)newChapter
{
    [self willChangeValueForKey:@"currentChapterIndex"];
    [self didChangeValueForKey:@"currentChapterIndex"];
}

- (void)mediaPlayerSnapshot:(NSString *)fileName
{
    @synchronized(_snapshots) {
        if (!_snapshots) {
            _snapshots = [NSMutableArray array];
        }

        [_snapshots addObject:fileName];
    }
}

- (void)mediaPlayerRecordChanged:(NSArray *)arguments
{
    NSString *filePath = arguments.firstObject[@"filePath"];
    BOOL isRecording = [arguments.firstObject[@"isRecording"] boolValue];

    if (isRecording) {
        if ([_delegate respondsToSelector:@selector(mediaPlayerStartedRecording:)]) {
            [_delegate mediaPlayerStartedRecording:self];
        }
    } else {
        if ([_delegate respondsToSelector:@selector(mediaPlayer:recordingStoppedAtPath:)]) {
            [_delegate mediaPlayer:self recordingStoppedAtPath:filePath];
        }
    }
}

@end

#pragma mark - VLCMediaPlayer+Tracks

/**
 * VLCMediaPlayer+Tracks
 */
@implementation VLCMediaPlayer (Tracks)

#pragma mark - Audio Tracks

- (NSArray<VLCMediaPlayerTrack *> *)audioTracks
{
    return [self _tracksForType: libvlc_track_audio];
}

#pragma mark - Video Tracks

- (NSArray<VLCMediaPlayerTrack *> *)videoTracks
{
    return [self _tracksForType: libvlc_track_video];
}

#pragma mark - Text Tracks

- (NSArray<VLCMediaPlayerTrack *> *)textTracks
{
    return [self _tracksForType: libvlc_track_text];
}

#pragma mark - Track Selection

- (void)deselectAllAudioTracks
{
    libvlc_media_player_unselect_track_type(_playerInstance, libvlc_track_audio);
}

- (void)deselectAllVideoTracks
{
    libvlc_media_player_unselect_track_type(_playerInstance, libvlc_track_video);
}

- (void)deselectAllTextTracks
{
    libvlc_media_player_unselect_track_type(_playerInstance, libvlc_track_text);
}

#pragma mark - Private

- (NSArray<VLCMediaPlayerTrack *> *)_tracksForType:(const libvlc_track_type_t)type
{
    libvlc_media_tracklist_t *tracklist = libvlc_media_player_get_tracklist(_playerInstance, type, false);
    if (!tracklist)
        return @[];
    
    const size_t tracklistCount = libvlc_media_tracklist_count(tracklist);
    NSMutableArray<VLCMediaPlayerTrack *> *tracks = [NSMutableArray arrayWithCapacity: (NSUInteger)tracklistCount];
    for (size_t i = 0; i < tracklistCount; i++) {
        libvlc_media_track_t *track_t = libvlc_media_tracklist_at(tracklist, i);
        VLCMediaPlayerTrack *track = [[VLCMediaPlayerTrack alloc] initWithMediaTrack: track_t mediaPlayer: self];
        [tracks addObject: track];
    }
    libvlc_media_tracklist_delete(tracklist);
    return tracks;
}

- (libvlc_media_player_t *)playerInstance {
    return _playerInstance;
}

@end

#pragma mark - VLCMediaPlayer+Deprecated

@implementation VLCMediaPlayer (Deprecated)

#pragma mark - Video Tracks

- (void)setCurrentVideoTrackIndex:(int)value
{
    libvlc_video_set_track(_playerInstance, value);
}

- (int)currentVideoTrackIndex
{
    return libvlc_video_get_track(_playerInstance);
}

- (NSArray *)videoTrackNames
{
    NSInteger count = libvlc_video_get_track_count(_playerInstance);
    if (count <= 0)
        return @[];

    libvlc_track_description_t *firstTrack = libvlc_video_get_track_description(_playerInstance);
    libvlc_track_description_t *currentTrack = firstTrack;

    NSMutableArray *tempArray = [NSMutableArray array];
    while (currentTrack) {
        [tempArray addObject:@(currentTrack->psz_name)];
        currentTrack = currentTrack->p_next;
    }
    libvlc_track_description_list_release(firstTrack);
    return [NSArray arrayWithArray: tempArray];
}

- (NSArray *)videoTrackIndexes
{
    NSInteger count = libvlc_video_get_track_count(_playerInstance);
    if (count <= 0)
        return @[];

    libvlc_track_description_t *firstTrack = libvlc_video_get_track_description(_playerInstance);
    libvlc_track_description_t *currentTrack = firstTrack;

    NSMutableArray *tempArray = [NSMutableArray array];
    while (currentTrack) {
        [tempArray addObject:@(currentTrack->i_id)];
        currentTrack = currentTrack->p_next;
    }
    libvlc_track_description_list_release(firstTrack);
    return [NSArray arrayWithArray: tempArray];
}

- (int)numberOfVideoTracks
{
    return libvlc_video_get_track_count(_playerInstance);
}

#pragma mark - Subtitles

- (void)setCurrentVideoSubTitleIndex:(int)index
{
    libvlc_video_set_spu(_playerInstance, index);
}

- (int)currentVideoSubTitleIndex
{
    return libvlc_video_get_spu(_playerInstance);
}

- (NSArray *)videoSubTitlesNames
{
    NSInteger count = libvlc_video_get_spu_count(_playerInstance);
    if (count <= 0)
        return @[];

    libvlc_track_description_t *firstTrack = libvlc_video_get_spu_description(_playerInstance);
    libvlc_track_description_t *currentTrack = firstTrack;

    NSMutableArray *tempArray = [NSMutableArray array];
    while (currentTrack) {
        NSString *track = @(currentTrack->psz_name);
        [tempArray addObject:track != nil ? track : @""];
        currentTrack = currentTrack->p_next;
    }
    libvlc_track_description_list_release(firstTrack);
    return [NSArray arrayWithArray: tempArray];
}

- (NSArray *)videoSubTitlesIndexes
{
    NSInteger count = libvlc_video_get_spu_count(_playerInstance);
    if (count <= 0)
        return @[];

    libvlc_track_description_t *firstTrack = libvlc_video_get_spu_description(_playerInstance);
    libvlc_track_description_t *currentTrack = firstTrack;

    NSMutableArray *tempArray = [NSMutableArray array];
    while (currentTrack) {
        [tempArray addObject:@(currentTrack->i_id)];
        currentTrack = currentTrack->p_next;
    }
    libvlc_track_description_list_release(firstTrack);
    return [NSArray arrayWithArray: tempArray];
}

- (int)numberOfSubtitlesTracks
{
    return libvlc_video_get_spu_count(_playerInstance);
}

#pragma mark - Audio tracks

- (void)setCurrentAudioTrackIndex:(int)value
{
    libvlc_audio_set_track(_playerInstance, value);
}

- (int)currentAudioTrackIndex
{
    return libvlc_audio_get_track(_playerInstance);
}

- (NSArray *)audioTrackNames
{
    NSInteger count = libvlc_audio_get_track_count(_playerInstance);
    if (count <= 0)
        return @[];

    libvlc_track_description_t *firstTrack = libvlc_audio_get_track_description(_playerInstance);
    libvlc_track_description_t *currentTrack = firstTrack;

    NSMutableArray *tempArray = [NSMutableArray array];
    while (currentTrack) {
        NSString *track = @(currentTrack->psz_name);
        [tempArray addObject:track != nil ? track : @""];
        currentTrack = currentTrack->p_next;
    }
    libvlc_track_description_list_release(firstTrack);
    return [NSArray arrayWithArray: tempArray];
}

- (NSArray *)audioTrackIndexes
{
    NSInteger count = libvlc_audio_get_track_count(_playerInstance);
    if (count <= 0)
        return @[];

    libvlc_track_description_t *firstTrack = libvlc_audio_get_track_description(_playerInstance);
    libvlc_track_description_t *currentTrack = firstTrack;

    NSMutableArray *tempArray = [NSMutableArray array];
    while (currentTrack) {
        [tempArray addObject:@(currentTrack->i_id)];
        currentTrack = currentTrack->p_next;
    }
    libvlc_track_description_list_release(firstTrack);
    return [NSArray arrayWithArray: tempArray];
}

- (int)numberOfAudioTracks
{
    return libvlc_audio_get_track_count(_playerInstance);
}

@end
