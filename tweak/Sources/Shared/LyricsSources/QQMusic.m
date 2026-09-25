// Line and word timing from QQ Music (Tencent). It is searched by title, artist and length, the way
// NetEase is, and answers with two shapes: the word-by-word yric when the track has it, and the
// line-timed LRC otherwise. The word shape is the same bracket-and-paren layout NetEase calls yrc,
// so its parser is the twin of NetEase.m's; QQ Music censors nothing, which is why it sits ahead of
// NetEase in the order rather than behind it.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static const NSTimeInterval kTimeout = 4;
// A QQ recording is only taken when its length is this close to the track's, so the words fall on
// the same beat as the recording Spotify is playing.
static const NSInteger kLengthSlack = 3;
static const NSUInteger kTriedSongs = 3;

static void get(NSString *path, NSDictionary<NSString *, NSString *> *query, void (^done)(NSDictionary *root)) {
    NSURLComponents *url = [NSURLComponents componentsWithString:[@"https://c.y.qq.com/" stringByAppendingString:path]];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:name value:value]];
    }];
    url.queryItems = items;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    // The lyrics endpoint answers empty without a referer from its own site.
    [request setValue:@"https://y.qq.com/" forHTTPHeaderField:@"Referer"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        SGLyricsNoteReply(response, error);
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (error || !root) SGLog(@"qqmusic: %@ failed: status %ld, error %@", path, (long)[(NSHTTPURLResponse *)response statusCode], error);
        dispatch_async(dispatch_get_main_queue(), ^{ done([root isKindOfClass:NSDictionary.class] ? root : nil); });
    }] resume];
}

// [1560,1560](1560,360,0)To (1920,360,0)seize (2280,420,0)everything …
// A line's start and length in ms, then each piece's start and length before its text. A piece not
// ending in a space runs on into the next one ("wanted" "…"), as in NetEase's yrc.
static NSArray<SGKaraokeLine *> *linesFromYric(NSString *yric) {
    static NSRegularExpression *header, *piece;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        header = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+),(\\d+)\\]" options:0 error:nil];
        piece = [NSRegularExpression regularExpressionWithPattern:@"\\((\\d+),(\\d+),-?\\d+\\)" options:0 error:nil];
    });
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSString *row in [yric componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *head = [header firstMatchInString:row options:0 range:NSMakeRange(0, row.length)];
        if (!head) continue;
        NSArray<NSTextCheckingResult *> *pieces = [piece matchesInString:row options:0 range:NSMakeRange(NSMaxRange(head.range), row.length - NSMaxRange(head.range))];
        NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
        SGKaraokeWord *open = nil;
        BOOL spaced = YES;   // a space has gone by, so the next word is not joined to the last
        for (NSUInteger i = 0; i < pieces.count; i++) {
            NSUInteger from = NSMaxRange(pieces[i].range), to = i + 1 < pieces.count ? pieces[i + 1].range.location : row.length;
            NSString *raw = [row substringWithRange:NSMakeRange(from, to - from)];
            NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSInteger start = [row substringWithRange:[pieces[i] rangeAtIndex:1]].integerValue;
            NSInteger end = start + [row substringWithRange:[pieces[i] rangeAtIndex:2]].integerValue;
            // QQ times a Chinese or Japanese syllable a piece at a time and never spaces them, so
            // each one is a word of its own; only a spaced script runs its pieces together.
            BOOL unspaced = SGKaraokeUnspacedScript(text);
            if (text.length && open && !unspaced) {
                open.text = [open.text stringByAppendingString:text];
                open.end = end;
            } else if (text.length) {
                SGKaraokeWord *word = [SGKaraokeWord new];
                word.text = text;
                word.start = start;
                word.end = end;
                word.joined = !spaced;
                [words addObject:word];
                open = unspaced ? nil : word;
                spaced = NO;
            }
            if (raw.length > text.length || !text.length) {
                open = nil;
                spaced = YES;
            }
        }
        if (!words.count) continue;
        SGKaraokeLine *line = [SGKaraokeLine new];
        line.words = words;
        line.start = [row substringWithRange:[head rangeAtIndex:1]].integerValue;
        line.end = line.start + [row substringWithRange:[head rangeAtIndex:2]].integerValue;
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

// [00:34.30] Look — the timestamp in minutes, seconds and hundredths, or thousandths where a line
// carries three digits. A line may be stamped more than once when it is sung more than once, and
// the tags LRC opens with ([ar:…], [length:…]) are not timestamps, so they fall out on their own.
static NSArray<SGKaraokeLine *> *linesFromLRC(NSString *lrc) {
    static NSRegularExpression *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]" options:0 error:nil];
    });
    NSMutableArray<NSDictionary *> *stamped = [NSMutableArray array];
    for (NSString *row in [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSTextCheckingResult *> *found = [stamp matchesInString:row options:0 range:NSMakeRange(0, row.length)];
        NSUInteger end = 0;
        NSMutableArray<NSNumber *> *at = [NSMutableArray array];
        for (NSTextCheckingResult *match in found) {
            if (match.range.location != end) break;
            end = NSMaxRange(match.range);
            NSInteger minutes = [row substringWithRange:[match rangeAtIndex:1]].integerValue;
            NSInteger seconds = [row substringWithRange:[match rangeAtIndex:2]].integerValue;
            NSInteger fraction = 0;
            NSRange part = [match rangeAtIndex:3];
            if (part.location != NSNotFound) {
                NSString *digits = [row substringWithRange:part];
                fraction = digits.integerValue * (digits.length == 1 ? 100 : digits.length == 2 ? 10 : 1);
            }
            [at addObject:@((minutes * 60 + seconds) * 1000 + fraction)];
        }
        if (!at.count) continue;
        NSString *text = [[row substringFromIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSNumber *ms in at) [stamped addObject:@{@"ms": ms, @"text": text}];
    }
    if (!stamped.count) return nil;
    [stamped sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"ms"] compare:b[@"ms"]];
    }];
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *row in stamped) {
        [starts addObject:row[@"ms"]];
        [texts addObject:row[@"text"]];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

static SGLyricsResult *resultFromLyrics(NSString *lyric, NSString *yric) {
    // Word timing first: it is the finer answer, and the lines it yields carry the page text too.
    NSArray<SGKaraokeLine *> *lines = [yric isKindOfClass:NSString.class] ? linesFromYric(yric) : nil;
    if (lines) {
        SGLyricsResult *result = [SGLyricsResult new];
        result.wordTimed = result.synced = YES;
        result.karaokeLines = lines;
        NSArray<NSNumber *> *starts;
        NSArray<NSString *> *texts;
        SGLyricsPageLines(lines, &starts, &texts);
        result.starts = starts;
        result.texts = texts;
        return result;
    }
    lines = [lyric isKindOfClass:NSString.class] ? linesFromLRC(lyric) : nil;
    if (lines) {
        SGLyricsResult *result = [SGLyricsResult new];
        result.synced = YES;
        result.karaokeLines = lines;
        NSArray<NSNumber *> *starts;
        NSArray<NSString *> *texts;
        SGLyricsPageLines(lines, &starts, &texts);
        result.starts = starts;
        result.texts = texts;
        return result;
    }
    return nil;
}

static void tryLyrics(NSArray<NSString *> *mids, NSUInteger index, void (^done)(SGLyricsResult *)) {
    if (index >= mids.count) {
        done(nil);
        return;
    }
    get(@"lyric/fcgi-bin/fcg_query_lyric_new.fcg", @{@"songmid": mids[index], @"format": @"json", @"nobase64": @"1", @"g_tk": @"5381"}, ^(NSDictionary *root) {
        SGLyricsResult *result = resultFromLyrics(root[@"lyric"], root[@"yric"]);
        if (result) {
            SGLog(@"qqmusic: song %@ has %@", mids[index], result.wordTimed ? @"word timed lines" : @"line timed lines");
            done(result);
        } else {
            tryLyrics(mids, index + 1, done);
        }
    });
}

SGLyricsAsk SGQQMusicAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    NSString *lead = [query.artist componentsSeparatedByString:@" feat"].firstObject.lowercaseString;
    NSString *title = query.title;
    NSInteger seconds = query.seconds;
    if (!title.length || !lead.length || seconds <= 0) {
        done(nil);
        return;
    }
    get(@"soso/fcgi-bin/client_search_cp", @{@"w": [NSString stringWithFormat:@"%@ %@", title, lead], @"format": @"json", @"n": @"10", @"p": @"1"}, ^(NSDictionary *root) {
        id songs = [root[@"data"] isKindOfClass:NSDictionary.class] ? root[@"data"][@"song"][@"list"] : nil;
        NSMutableArray<NSDictionary *> *fitting = [NSMutableArray array];
        for (NSDictionary *song in [songs isKindOfClass:NSArray.class] ? songs : @[]) {
            if (![song isKindOfClass:NSDictionary.class]) continue;
            NSInteger interval = [song[@"interval"] integerValue];
            if (interval <= 0 || labs(interval - seconds) > kLengthSlack) continue;
            id singers = song[@"singer"];
            for (NSDictionary *singer in [singers isKindOfClass:NSArray.class] ? singers : @[]) {
                NSString *name = [singer isKindOfClass:NSDictionary.class] && [singer[@"name"] isKindOfClass:NSString.class] ? [singer[@"name"] lowercaseString] : nil;
                if (name.length && ([name containsString:lead] || [lead containsString:name])) {
                    [fitting addObject:song];
                    break;
                }
            }
        }
        [fitting sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [@(labs([a[@"interval"] integerValue] - seconds)) compare:@(labs([b[@"interval"] integerValue] - seconds))];
        }];
        NSMutableArray<NSString *> *mids = [NSMutableArray array];
        for (NSDictionary *song in [fitting subarrayWithRange:NSMakeRange(0, MIN(fitting.count, kTriedSongs))]) {
            NSString *mid = [song[@"songmid"] isKindOfClass:NSString.class] ? song[@"songmid"] : nil;
            if (mid.length) [mids addObject:mid];
        }
        if (!mids.count) SGLog(@"qqmusic: no recording of %@ by %@ within %lds of %lds", title, lead, (long)kLengthSlack, (long)seconds);
        tryLyrics(mids, 0, done);
    });
};
