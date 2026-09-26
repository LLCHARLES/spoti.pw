// Word and line timing, plus a Chinese translation, from QQ Music. The catalogue has tracks the
// western sources never reach, and the translation it ships is the only one most of those tracks
// carry, so QQ Music earns its place at the floor of the order alongside LRCLIB.
//
// QQ Music keeps its songs behind their own ids, so a track is first searched for by its title
// (the API takes a single word, no artist filter), and the closest of the results by singer and
// length is taken. The lyric endpoint answers lrc (line timing), trans (a Chinese LRC sheet),
// yrc (word timing, the same shape NetEase uses, two numbers to a piece), and roma (romanisation);
// the translation is applied when Chinese (or Any) is asked for.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kSearch = @"https://api.vkeys.cn/v2/music/tencent/search/song";
static NSString *const kLyric = @"https://api.vkeys.cn/v2/music/tencent/lyric";
static const NSUInteger kTriedSongs = 3;

static void get(NSString *base, NSDictionary<NSString *, NSString *> *query, void (^done)(NSDictionary *root)) {
    SGLyricsGetJSON(SGLyricsURL(base, query), nil, ^(id root) {
        done([root isKindOfClass:NSDictionary.class] ? root : nil);
    });
}

// [00:34.30] Look — the same LRC shape LRCLIB serves, parsed the same way. A line may be stamped
// more than once when it is sung more than once, and the tags LRC opens with fall out on their own.
// QQ Music marks an absent translation with "//"; those are skipped so a blank never shows as a
// translation line.
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
        if ([text isEqualToString:@"//"]) continue;
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

// [0,3420]Des(0,879)pa(879,...)ci(...)...to(...) — QQ Music stamps each piece's (start,duration)
// after its text, the opposite of NetEase, so each word's text is the slice before its stamp.
// Pieces not ending in a space run on into the next one, as a richsync does.
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
            // The text sits before its (start,duration) stamp: from the end of the previous stamp
            // (or the header, for the first word) up to this stamp's opening parenthesis.
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
    if (!lines.count) return nil;
    // QQ Music leads every sheet with the song name, the lyricist and the composer stamped as lines,
    // all of which carry a "-" or "：". They are not sung, so drop the leading run of them.
    while (lines.count) {
        NSString *text = SGKaraokeLineText(lines.firstObject);
        if ([text containsString:@"-"] || [text containsString:@"："] || [text containsString:@":"]) {
            [lines removeObjectAtIndex:0];
        } else break;
    }
    return lines.count ? lines : nil;
}

// The translation is an LRC sheet with its own timestamps, in Chinese. Each translated line is
// lined up with the closest original by start time and set on the line.
static void applyTranslation(SGLyricsResult *lyrics, NSString *translatedLRC) {
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

// The romanisation is a yrc sheet spelt in the Latin alphabet, the sound of a CJK line — the same
// [start,dur]word(start,dur)... shape as the lyrics, so linesFromYrc parses it word for word. Each
// roma line is lined up with the closest original by start time, and its own words (already timed)
// become the line's pronunciation. The pronunciation shows only when the redesign's Pronunciation
// switch is on.
static void applyPronunciation(SGLyricsResult *lyrics, NSString *romaYrc) {
    if (!lyrics || !lyrics.karaokeLines.count) return;
    NSArray<SGKaraokeLine *> *roma = linesFromYrc(romaYrc);
    if (!roma.count) return;
    for (SGKaraokeLine *line in lyrics.karaokeLines) {
        NSUInteger best = 0;
        NSInteger minDiff = NSIntegerMax;
        for (NSUInteger i = 0; i < roma.count; i++) {
            NSInteger diff = labs(line.start - roma[i].start);
            if (diff < minDiff) { minDiff = diff; best = i; }
        }
        NSString *said = SGKaraokeLineText(roma[best]);
        if (!said.length || [said isEqualToString:SGKaraokeLineText(line)]) continue;
        // The roma sheet is already word-timed, so reuse its words directly instead of estimating
        // them across the line's time.
        SGKaraokeLine *spoken = [SGKaraokeLine new];
        spoken.words = roma[best].words;
        spoken.start = line.start;
        spoken.end = MAX(line.end, roma[best].end);
        spoken.align = line.align;
        line.pronunciation = spoken;
    }
}

static void lyricFor(NSString *songID, void (^done)(SGLyricsResult *result)) {
    get(kLyric, @{@"id": songID}, ^(NSDictionary *root) {
        id code = root[@"code"];
        if (![code respondsToSelector:@selector(integerValue)] || [code integerValue] != 200) { done(nil); return; }
        NSDictionary *data = [root[@"data"] isKindOfClass:NSDictionary.class] ? root[@"data"] : nil;
        if (!data) { done(nil); return; }
        NSString *yrc = [data[@"yrc"] isKindOfClass:NSString.class] ? data[@"yrc"] : nil;
        NSString *lrc = [data[@"lrc"] isKindOfClass:NSString.class] ? data[@"lrc"] : nil;
        NSString *trans = [data[@"trans"] isKindOfClass:NSString.class] ? data[@"trans"] : nil;
        NSString *roma = [data[@"roma"] isKindOfClass:NSString.class] ? data[@"roma"] : nil;
        NSArray<SGKaraokeLine *> *lines = yrc.length ? linesFromYrc(yrc) : nil;
        SGLyricsResult *result = [SGLyricsResult new];
        if (lines) {
            result.karaokeLines = lines;
            result.synced = result.wordTimed = YES;
        } else if (lrc.length) {
            lines = linesFromLRC(lrc);
            if (!lines) { done(nil); return; }
            result.karaokeLines = lines;
            result.synced = YES;
            NSArray<NSNumber *> *starts;
            NSArray<NSString *> *texts;
            SGLyricsPageLines(lines, &starts, &texts);
            result.starts = starts;
            result.texts = texts;
        } else { done(nil); return; }
        // The translation is Chinese; show it when asked for Chinese or Any.
        if (trans.length) {
            NSString *lang = SGLyricsTranslationLanguage();
            if (!lang.length || [lang hasPrefix:@"zh"]) applyTranslation(result, trans);
        }
        // The romanisation is the Latin-alphabet sound of a CJK line, set as the pronunciation.
        if (roma.length) applyPronunciation(result, roma);
        SGLog(@"qqmusic: song %@ has %@", songID,
              result.wordTimed ? [NSString stringWithFormat:@"%lu word timed lines", (unsigned long)result.karaokeLines.count]
              : [NSString stringWithFormat:@"%lu line timed lines", (unsigned long)result.karaokeLines.count]);
        done(result);
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
    get(kSearch, @{@"word": title}, ^(NSDictionary *root) {
        id code = root[@"code"];
        if (![code respondsToSelector:@selector(integerValue)] || [code integerValue] != 200) { done(nil); return; }
        NSArray *songs = [root[@"data"] isKindOfClass:NSArray.class] ? root[@"data"] : nil;
        NSMutableArray<NSDictionary *> *fitting = [NSMutableArray array];
        for (NSDictionary *song in songs) {
            if (![song isKindOfClass:NSDictionary.class]) continue;
            // QQ Music's data carries a "time" string ("2016-07-08"), not a duration; the length is
            // not in the search response, so the closest is picked by singer alone when no length is.
            NSString *singer = [song[@"singer"] isKindOfClass:NSString.class] ? [song[@"singer"] lowercaseString] : @"";
            if (singer.length && ([singer containsString:lead] || [lead containsString:singer])) {
                [fitting addObject:song];
            }
        }
        if (!fitting.count) {
            // No singer match — fall back to the first result, on the bet that QQ Music's search
            // ranks the title's best known recording first.
            if (songs.count) [fitting addObject:[songs firstObject]];
            else { SGLog(@"qqmusic: no recording of %@", title); done(nil); return; }
        }
        NSArray *ids = [[fitting valueForKey:@"id"] subarrayWithRange:NSMakeRange(0, MIN(fitting.count, kTriedSongs))];
        // try up to kTriedSongs until one has lyrics. The block recurses into itself, so a weak
        // reference is used inside it to break the ARC retain cycle a __block capture would make.
        __block NSUInteger index = 0;
        __block void (^tryNext)(void) = nil;
        __weak void (^weakTryNext)(void) = nil;
        tryNext = ^{
            if (index >= ids.count) { done(nil); return; }
            NSString *songID = [ids[index] stringValue];
            index++;
            lyricFor(songID, ^(SGLyricsResult *result) {
                if (result) done(result);
                else {
                    void (^strong)(void) = weakTryNext;
                    if (strong) strong();
                }
            });
        };
        weakTryNext = tryNext;
        tryNext();
    });
};
