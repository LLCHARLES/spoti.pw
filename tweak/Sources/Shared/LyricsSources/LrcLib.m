// LRCLIB, the floor of the order. It is an open library with no key and no catalogue to license, so
// it holds what the rest cannot: the tracks Apple's word by word programme never reached, and the
// ones Musixmatch may show nobody. Its own records time lines and not words, but the charlesl.qzz.io
// mirror proxies QQ Music and ships a yrcLyrics field when it has one, which is word timed, so a
// record from the mirror can sweep word by word.
//
// The exact lookup goes through the charlesl.qzz.io mirror of LRCLIB, which carries a translatedLyrics
// field (an LRC sheet in Chinese) alongside the usual lyrics. /api/get wants the length to agree
// almost exactly and answers 404 otherwise, so a miss falls back to lrclib.net's /api/search, which
// answers with whole recordings to pick the closest of — but has no translations. LRCLIB asks that
// clients say who they are, and the mod does.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kGet = @"https://charlesl.qzz.io/api/get";
static NSString *const kSearch = @"https://lrclib.net/api/search";
// Line timing is only worth taking from a recording of about the same length as the one playing.
static const NSInteger kLengthSlack = 4;

static NSDictionary<NSString *, NSString *> *headers(void) {
    return @{@"User-Agent": @"spoti.pw " @SG_VERSION @" (https://github.com/skopevoj/spoti.pw)"};
}

// [00:34.30] Look — the timestamp in minutes, seconds and hundredths, or thousandths where a line
// carries three digits. A line may be stamped more than once when it is sung more than once, and
// the tags LRC opens with ([ar:…], [length:…]) are not timestamps, so they fall out on their own.
// The mirror marks an absent translation with "//"; those are skipped so a blank never shows.
static NSArray<SGKaraokeLine *> *linesFromLRC(NSString *lrc) {
    static NSRegularExpression *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]" options:0 error:nil];
    });
    NSMutableArray<NSDictionary *> *stamped = [NSMutableArray array];
    for (NSString *row in [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSTextCheckingResult *> *found = [stamp matchesInString:row options:0 range:NSMakeRange(0, row.length)];
        // Only the stamps a line opens with are its own; one further in is part of the words.
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
        if ([text isEqualToString:@"//"]) continue;
        for (NSNumber *ms in at) [stamped addObject:@{@"ms": ms, @"text": text}];
    }
    if (!stamped.count) return nil;
    [stamped sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"ms"] compare:b[@"ms"]];
    }];
    // The empty rows stay in: they are the breaks, and each one is the end of the line before it.
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *row in stamped) {
        [starts addObject:row[@"ms"]];
        [texts addObject:row[@"text"]];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

// The charlesl.qzz.io mirror proxies QQ Music, so when it has a yrcLyrics field it is QQ Music's
// yrc: [start,dur]word(start,dur)..., with each word's text before its stamp. Parse it for word
// timing when the mirror serves it; otherwise fall back to the line-timed syncedLyrics.
static NSArray<SGKaraokeLine *> *linesFromYrc(NSString *yrc) {
    static NSRegularExpression *header, *piece;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        header = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+),(\\d+)\\]" options:0 error:nil];
        piece = [NSRegularExpression regularExpressionWithPattern:@"\\((\\d+),(\\d+)\\)" options:0 error:nil];
    });
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSString *row in [yrc componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *head = [header firstMatchInString:row options:0 range:NSMakeRange(0, row.length)];
        if (!head) continue;
        NSUInteger contentStart = NSMaxRange(head.range);
        NSArray<NSTextCheckingResult *> *pieces = [piece matchesInString:row options:0 range:NSMakeRange(contentStart, row.length - contentStart)];
        if (!pieces.count) continue;
        NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
        SGKaraokeWord *open = nil;
        BOOL spaced = YES;
        NSUInteger prevEnd = contentStart;
        for (NSUInteger i = 0; i < pieces.count; i++) {
            NSTextCheckingResult *p = pieces[i];
            NSString *raw = [row substringWithRange:NSMakeRange(prevEnd, p.range.location - prevEnd)];
            NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSInteger start = [row substringWithRange:[p rangeAtIndex:1]].integerValue;
            NSInteger end = start + [row substringWithRange:[p rangeAtIndex:2]].integerValue;
            prevEnd = NSMaxRange(p.range);
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

// The charlesl.qzz.io mirror of LRCLIB carries a translatedLyrics field: an LRC sheet with its own
// timestamps, in Chinese. Each translated line is lined up with the closest original by start time
// and set on the line, so the redesign shows it beneath the words.
static void applyLrcTranslation(SGLyricsResult *lyrics, NSString *translatedLRC) {
    if (!lyrics || !lyrics.karaokeLines.count) return;
    NSArray<SGKaraokeLine *> *translated = linesFromLRC(translatedLRC);
    if (!translated.count) return;
    for (SGKaraokeLine *line in lyrics.karaokeLines) {
        NSUInteger best = 0;
        NSInteger minDiff = NSIntegerMax;
        for (NSUInteger i = 0; i < translated.count; i++) {
            NSInteger diff = labs(line.start - translated[i].start);
            if (diff < minDiff) { minDiff = diff; best = i; }
        }
        NSString *text = SGKaraokeLineText(translated[best]);
        if (text.length && ![text isEqualToString:SGKaraokeLineText(line)]) line.translation = text;
    }
}

static SGLyricsResult *resultFrom(NSDictionary *record) {
    if (![record isKindOfClass:NSDictionary.class]) return nil;
    SGLyricsResult *result = [SGLyricsResult new];
    result.instrumental = [record[@"instrumental"] boolValue];
    if (result.instrumental) return result;
    id yrc = record[@"yrcLyrics"], synced = record[@"syncedLyrics"], plain = record[@"plainLyrics"];
    // The mirror serves QQ Music's yrc when it has it — word timing, better than line timing.
    NSArray<SGKaraokeLine *> *lines = [yrc isKindOfClass:NSString.class] && [yrc length] ? linesFromYrc(yrc) : nil;
    if (lines) {
        result.synced = result.wordTimed = YES;
        result.karaokeLines = lines;
    } else {
        lines = [synced isKindOfClass:NSString.class] ? linesFromLRC(synced) : nil;
        if (lines) {
            result.synced = YES;
            result.karaokeLines = lines;
            NSArray<NSNumber *> *starts;
            NSArray<NSString *> *texts;
            SGLyricsPageLines(lines, &starts, &texts);
            result.starts = starts;
            result.texts = texts;
        } else if ([plain isKindOfClass:NSString.class] && [plain length]) {
            // Nothing timed, but the words still beat an empty page when no other source has any.
            NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
            NSMutableArray<NSString *> *texts = [NSMutableArray array];
            for (NSString *row in [plain componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                [starts addObject:@0];
                [texts addObject:row.length ? row : @"♪"];
            }
            result.starts = starts;
            result.texts = texts;
            result.karaokeLines = SGKaraokeStaticLines(texts);
        } else return nil;
    }
    // The mirror's translatedLyrics is Chinese; show it when asked for Chinese or Any.
    id translated = record[@"translatedLyrics"];
    if ([translated isKindOfClass:NSString.class] && [translated length]) {
        NSString *lang = SGLyricsTranslationLanguage();
        if (!lang.length || [lang hasPrefix:@"zh"]) applyLrcTranslation(result, translated);
    }
    return result;
}

// How good a recording is for the track: timed beats untimed, then the closest length. With no
// length to go on, the fullest sheet wins — the search will happily rank a seventeen second stub of
// a song above the song, and a stub is the one thing a length would have caught.
static BOOL betterRecord(NSDictionary *record, NSDictionary *best, NSInteger seconds) {
    if (!best) return YES;
    BOOL synced = ([record[@"syncedLyrics"] isKindOfClass:NSString.class] && [record[@"syncedLyrics"] length])
               || ([record[@"yrcLyrics"] isKindOfClass:NSString.class] && [record[@"yrcLyrics"] length]);
    BOOL wasSynced = ([best[@"syncedLyrics"] isKindOfClass:NSString.class] && [best[@"syncedLyrics"] length])
                  || ([best[@"yrcLyrics"] isKindOfClass:NSString.class] && [best[@"yrcLyrics"] length]);
    if (synced != wasSynced) return synced;
    if (seconds > 0) {
        NSInteger off = labs((NSInteger)[record[@"duration"] doubleValue] - seconds);
        NSInteger wasOff = labs((NSInteger)[best[@"duration"] doubleValue] - seconds);
        return off < wasOff;
    }
    NSString *text = record[@"syncedLyrics"] ?: record[@"yrcLyrics"] ?: record[@"plainLyrics"] ?: @"";
    NSString *wasText = best[@"syncedLyrics"] ?: best[@"yrcLyrics"] ?: best[@"plainLyrics"] ?: @"";
    return [text isKindOfClass:NSString.class] && [text length] > [wasText length];
}

static NSDictionary *bestOf(id found, NSInteger seconds) {
    NSDictionary *best = nil;
    for (NSDictionary *record in [found isKindOfClass:NSArray.class] ? found : @[]) {
        if (![record isKindOfClass:NSDictionary.class]) continue;
        NSInteger length = (NSInteger)[record[@"duration"] doubleValue];
        if (seconds > 0 && length > 0 && labs(length - seconds) > kLengthSlack) continue;
        if (betterRecord(record, best, seconds)) best = record;
    }
    return best;
}

SGLyricsAsk SGLrcLibAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        SGLog(@"lrclib: nothing to search with for %@", query.trackID);
        done(nil);
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *search = [NSMutableDictionary dictionaryWithDictionary:@{
        @"track_name": query.title,
        @"artist_name": query.artist,
    }];
    if (query.album.length) search[@"album_name"] = query.album;

    void (^bySearch)(void) = ^{
        SGLyricsGetJSON(SGLyricsURL(kSearch, search), headers(), ^(id found) {
            NSDictionary *record = bestOf(found, query.seconds);
            SGLyricsResult *result = resultFrom(record);
            SGLog(@"lrclib: search for %@ by %@ gave %@", query.title, query.artist,
                  !result ? @"nothing" : result.instrumental ? @"an instrumental"
                  : result.synced ? [NSString stringWithFormat:@"%lu timed lines", (unsigned long)result.karaokeLines.count]
                  : [NSString stringWithFormat:@"%lu untimed lines", (unsigned long)result.texts.count]);
            done(result);
        });
    };

    // With no length to match on, the exact lookup would be a guess; the search ranks by itself.
    if (query.seconds <= 0) {
        bySearch();
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *exact = [search mutableCopy];
    exact[@"duration"] = @(query.seconds).stringValue;
    SGLyricsGetJSON(SGLyricsURL(kGet, exact), headers(), ^(id record) {
        SGLyricsResult *result = resultFrom(record);
        if (!result) {
            bySearch();
            return;
        }
        SGLog(@"lrclib: %@ by %@ matched exactly, %@", query.title, query.artist,
              result.instrumental ? @"instrumental" : result.synced ? @"timed" : @"untimed");
        done(result);
    });
};
