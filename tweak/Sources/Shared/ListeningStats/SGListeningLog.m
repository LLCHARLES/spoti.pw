// ListeningStats.h says what is kept and why.
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"
#import "ListeningStats.h"

// A play is a listen of 30 seconds or more; anything under 5 is not kept at all.
static const double kPlaySeconds = 30, kKeepSeconds = 5;
// How often the listen going on is written down, so a Spotify killed mid-song loses at most this much.
static const NSTimeInterval kFlushInterval = 30;

@implementation SGListeningEntry
@end

@implementation SGListeningSummary
@end

@interface SGListeningLog : NSObject <SGPlayerStateObserver>
@property (nonatomic) BOOL recording;
@end

@implementation SGListeningLog {
    NSMutableArray<NSMutableArray *> *_events;   // [unix seconds, uri, seconds listened]
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_tracks;   // uri: [title, artist, artist uri]
    BOOL _loaded, _dirty;
    NSString *_uri;                 // the track being listened to
    CFAbsoluteTime _playingSince;   // 0 while not playing
    double _listened;               // seconds of this listen before _playingSince
    NSTimeInterval _startedAt;      // unix seconds the listen began
    NSInteger _eventIndex;          // where the listen is in _events once kept, -1 before
    NSTimer *_timer;
}

+ (instancetype)shared {
    static SGListeningLog *log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = [SGListeningLog new]; });
    return log;
}

+ (NSURL *)fileURL {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [base URLByAppendingPathComponent:@"spoti.pw/Stats/listening.json"];
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _events = [NSMutableArray array];
    _tracks = [NSMutableDictionary dictionary];
    _eventIndex = -1;
    return self;
}

- (void)load {
    if (_loaded) return;
    _loaded = YES;
    NSData *data = [NSData dataWithContentsOfURL:SGListeningLog.fileURL];
    NSDictionary *saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![saved isKindOfClass:NSDictionary.class]) return;
    for (id event in saved[@"events"]) {
        if ([event isKindOfClass:NSArray.class] && [event count] == 3 && [event[1] isKindOfClass:NSString.class]
            && [event[0] isKindOfClass:NSNumber.class] && [event[2] isKindOfClass:NSNumber.class]) {
            [_events addObject:[event mutableCopy]];
        }
    }
    NSDictionary *tracks = saved[@"tracks"];
    if ([tracks isKindOfClass:NSDictionary.class]) {
        [tracks enumerateKeysAndObjectsUsingBlock:^(NSString *uri, NSArray *info, BOOL *stop) {
            if ([uri isKindOfClass:NSString.class] && [info isKindOfClass:NSArray.class] && info.count == 3) self->_tracks[uri] = info;
        }];
    }
    SGLog(@"listening stats: %lu listens of %lu tracks", (unsigned long)_events.count, (unsigned long)_tracks.count);
}

- (void)save {
    if (!_dirty) return;
    _dirty = NO;
    NSDictionary *saved = @{@"v": @1, @"events": [_events copy], @"tracks": [_tracks copy]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:saved options:0 error:NULL];
    NSURL *url = SGListeningLog.fileURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        if (![data writeToURL:url options:NSDataWritingAtomic error:NULL]) SGLog(@"listening stats: could not write the log");
    });
}

// The listen so far into the log: added once it is worth keeping, then updated in place.
- (void)note {
    if (!_uri) return;
    double listened = _listened + (_playingSince > 0 ? CFAbsoluteTimeGetCurrent() - _playingSince : 0);
    if (listened < kKeepSeconds) return;
    NSNumber *seconds = @(round(listened));
    if (_eventIndex < 0) {
        [_events addObject:[@[@((long long)_startedAt), _uri, seconds] mutableCopy]];
        _eventIndex = (NSInteger)_events.count - 1;
    } else if (_eventIndex < (NSInteger)_events.count) {
        _events[(NSUInteger)_eventIndex][2] = seconds;
    }
    _dirty = YES;
}

- (void)flush {
    [self note];
    [self save];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (!_recording) return;
    [self load];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_playingSince > 0) {
        _listened += now - _playingSince;
        _playingSince = 0;
    }
    SPTPlayerTrack *track = [state respondsToSelector:@selector(track)] ? state.track : nil;
    NSString *uri = SGURIString(track.URI);
    if (![uri isEqualToString:_uri]) {
        [self note];
        if (_dirty) [self save];
        _uri = uri.length ? [uri copy] : nil;
        _listened = 0;
        _startedAt = NSDate.date.timeIntervalSince1970;
        _eventIndex = -1;
        if (_uri) {
            NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : nil;
            NSString *artist = [track respondsToSelector:@selector(artistName)] ? track.artistName : nil;
            NSString *artistURI = [track respondsToSelector:@selector(artistURI)] ? SGURIString(track.artistURI) : nil;
            if (title.length) _tracks[_uri] = @[title, artist ?: @"", artistURI ?: @""];
        }
    }
    BOOL loading = [state respondsToSelector:@selector(isLoading)] && state.isLoading;
    if (_uri && state.isPlaying && !state.isPaused && !loading) _playingSince = now;
}

- (void)setRecording:(BOOL)recording {
    if (recording == _recording) return;
    _recording = recording;
    if (recording) {
        [self load];
        SGAddPlayerStateObserver(self);
        _timer = [NSTimer scheduledTimerWithTimeInterval:kFlushInterval repeats:YES block:^(NSTimer *timer) {
            [SGListeningLog.shared flush];
        }];
        _timer.tolerance = 5;
        SPTPlayerState *state = SGPlayerState();
        if (state) [self playerStateDidChange:state];
    } else {
        // The listen going on ends here, written down while the recorder still takes it.
        _recording = YES;
        [self playerStateDidChange:nil];
        _recording = NO;
        [_timer invalidate];
        _timer = nil;
        [self flush];
    }
}

- (void)clear {
    [self load];
    [_events removeAllObjects];
    [_tracks removeAllObjects];
    _eventIndex = -1;
    _listened = 0;
    _playingSince = _playingSince > 0 ? CFAbsoluteTimeGetCurrent() : 0;
    _startedAt = NSDate.date.timeIntervalSince1970;
    if (_uri && _recording) {
        // The track playing keeps its name for when its listen is written down.
        SPTPlayerTrack *track = SGPlayerState().track;
        NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : nil;
        if (title.length) _tracks[_uri] = @[title, track.artistName ?: @"", SGURIString(track.artistURI) ?: @""];
    }
    _dirty = YES;
    [self save];
}

static NSArray<SGListeningEntry *> *top(NSDictionary<NSString *, SGListeningEntry *> *entries, NSUInteger count) {
    NSArray *sorted = [entries.allValues sortedArrayUsingComparator:^NSComparisonResult(SGListeningEntry *a, SGListeningEntry *b) {
        if (a.plays != b.plays) return a.plays > b.plays ? NSOrderedAscending : NSOrderedDescending;
        if (a.seconds != b.seconds) return a.seconds > b.seconds ? NSOrderedAscending : NSOrderedDescending;
        return [a.title localizedCaseInsensitiveCompare:b.title];
    }];
    return [sorted subarrayWithRange:NSMakeRange(0, MIN(count, sorted.count))];
}

- (SGListeningSummary *)summarize:(SGListeningPeriod)period count:(NSUInteger)count {
    [self load];
    [self note];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval from = period == SGListeningPeriodMonth ? now - 28 * 86400 : period == SGListeningPeriodHalfYear ? now - 182 * 86400 : 0;
    NSMutableDictionary<NSString *, SGListeningEntry *> *tracks = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, SGListeningEntry *> *artists = [NSMutableDictionary dictionary];
    SGListeningSummary *summary = [SGListeningSummary new];
    NSTimeInterval first = now;
    for (NSArray *event in _events) {
        NSTimeInterval at = [event[0] doubleValue];
        if (at < from) continue;
        first = MIN(first, at);
        NSString *uri = event[1];
        double seconds = [event[2] doubleValue];
        BOOL play = seconds >= kPlaySeconds;
        summary.seconds += seconds;
        if (play) summary.plays++;
        NSArray<NSString *> *info = _tracks[uri];
        SGListeningEntry *track = tracks[uri];
        if (!track) {
            track = [SGListeningEntry new];
            track.uri = uri;
            track.title = info.count ? info[0] : uri;
            track.subtitle = info.count > 1 && info[1].length ? info[1] : nil;
            tracks[uri] = track;
        }
        track.seconds += seconds;
        if (play) track.plays++;
        NSString *artistName = info.count > 1 ? info[1] : nil;
        if (artistName.length) {
            NSString *artistURI = info.count > 2 && info[2].length ? info[2] : nil;
            NSString *key = artistURI ?: artistName;
            SGListeningEntry *artist = artists[key];
            if (!artist) {
                artist = [SGListeningEntry new];
                artist.uri = artistURI;
                artist.title = artistName;
                artists[key] = artist;
            }
            artist.seconds += seconds;
            if (play) artist.plays++;
        }
    }
    summary.tracks = (NSInteger)tracks.count;
    summary.artists = (NSInteger)artists.count;
    summary.days = summary.seconds > 0 ? MAX(1, (NSInteger)ceil((now - first) / 86400)) : 0;
    summary.topTracks = top(tracks, count);
    summary.topArtists = top(artists, count);
    return summary;
}

@end

void SGListeningStatsApply(void) {
    SGListeningLog.shared.recording = SGEnabled(SGKeyListeningStats);
}

SGListeningSummary *SGListeningSummarize(SGListeningPeriod period, NSUInteger count) {
    return [SGListeningLog.shared summarize:period count:count];
}

void SGListeningClear(void) {
    [SGListeningLog.shared clear];
}

void SGListeningStatsFlush(void) {
    [SGListeningLog.shared flush];
}
