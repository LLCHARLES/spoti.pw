// KuGou: word-timed KRC and line-timed LRC from KuGou's public search and lyric endpoints.
// The KRC payload is XOR-scrambled with a fixed 16-byte key and zlib-compressed; decodeKRC
// reverses both. Parsing, cleaning and matching ride on SpotifyGlass's shared karaoke helpers
// so the lines match every other source. Registered under the "kugou" key.
#import "Core/SGCore.h"
#import "LyricsSources.h"
#import <string.h>
#import <zlib.h>

#pragma mark - KRC decoder

// KuGou KRC: base64 -> strip the 4-byte "krc1" magic -> XOR the body with a fixed key -> inflate.
static NSString *decodeKRC(NSString *encoded) {
    if (![encoded isKindOfClass:NSString.class] || encoded.length > 2 * 1024 * 1024) return nil;
    NSData *bytes = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (bytes.length <= 4 || bytes.length > 1024 * 1024 || memcmp(bytes.bytes, "krc1", 4)) return nil;
    static const uint8_t key[] = {64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105};
    NSMutableData *compressed = [[bytes subdataWithRange:NSMakeRange(4, bytes.length - 4)] mutableCopy];
    uint8_t *body = compressed.mutableBytes;
    for (NSUInteger i = 0; i < compressed.length; i++) body[i] ^= key[i % sizeof(key)];
    NSMutableData *inflated = [NSMutableData dataWithLength:1024 * 1024];
    uLongf length = (uLongf)inflated.length;
    if (uncompress(inflated.mutableBytes, &length, compressed.bytes, (uLong)compressed.length) != Z_OK) return nil;
    return [[NSString alloc] initWithBytes:inflated.bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}

// KRC embeds an optional base64 JSON language block. Type 0 carries romanised syllables, one array
// of word strings per line. A row count that does not line up is ignored rather than shifted.
static NSArray *krcPronunciationRows(NSString *krc) {
    for (NSString *row in [krc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![row hasPrefix:@"[language:"] || ![row hasSuffix:@"]"] || row.length > 2 * 1024 * 1024) continue;
        NSString *encoded = [row substringWithRange:NSMakeRange(10, row.length - 11)];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *content = [root isKindOfClass:NSDictionary.class] && [root[@"content"] isKindOfClass:NSArray.class] ? root[@"content"] : @[];
        for (id language in content) {
            if (![language isKindOfClass:NSDictionary.class] || ![language[@"type"] isKindOfClass:NSNumber.class] || [language[@"type"] integerValue] != 0) continue;
            if ([language[@"lyricContent"] isKindOfClass:NSArray.class]) return language[@"lyricContent"];
        }
    }
    return nil;
}

#pragma mark - shared cleaning helpers (identical to QQ Music's)

// Whether a line carries a colon (Chinese or English), used to catch credit lines.
static BOOL containsColon(NSString *text) {
    return [text containsString:@":"] || [text containsString:@"："];
}

// Whether a line carries a bracket pair ([] or 【】), a leftover tag.
static BOOL containsBracketTag(NSString *text) {
    return ([text containsString:@"["] && [text containsString:@"]"])
        || ([text containsString:@"【"] && [text containsString:@"】"]);
}

// Whether a line carries a paren pair (() or （）), a credit annotation.
static BOOL containsParenPair(NSString *text) {
    return ([text containsString:@"("] && [text containsString:@")"])
        || ([text containsString:@"（"] && [text containsString:@"）"]);
}

// Whether a line is a copyright / license warning KuGou sometimes carries.
static BOOL isLicenseWarning(NSString *text) {
    if (!text.length) return NO;
    static NSArray<NSString *> *special;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ special = @[@"文曲大模型", @"享有本翻译作品的著作权"]; });
    for (NSString *kw in special) if ([text containsString:kw]) return YES;
    static NSArray<NSString *> *tokens;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{ tokens = @[@"未经", @"许可", @"授权", @"不得", @"请勿", @"使用", @"版权", @"翻唱"]; });
    NSInteger count = 0;
    for (NSString *t in tokens) if ([text containsString:t]) count++;
    return count >= 3;
}

// The eight-step filter the lrclib proxy's get.js runs, ported to SGKaraokeLine arrays. Strips credit
// lines, metadata tags, copyright warnings, empty rows and "//" markers so only sung lines remain.
static NSArray<SGKaraokeLine *> *filterKaraokeLines(NSArray<SGKaraokeLine *> *lines) {
    if (!lines.count) return lines;
    NSMutableArray<SGKaraokeLine *> *f = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) {
        NSString *text = SGKaraokeLineText(line);
        if (!text.length) continue;
        if ([text isEqualToString:@"//"]) continue;
        if (containsBracketTag(text)) continue;
        if (isLicenseWarning(text)) continue;
        [f addObject:line];
    }
    // 1) First three: drop lines with '-' (song-title rows).
    NSUInteger limit = MIN(3, f.count);
    for (NSUInteger i = 0; i < limit && i < f.count; ) {
        if ([SGKaraokeLineText(f[i]) containsString:@"-"]) { [f removeObjectAtIndex:i]; limit = MIN(3, f.count); }
        else i++;
    }
    // 2) First three: drop lines with a colon (词：/曲： rows).
    BOOL removedColon = NO;
    limit = MIN(3, f.count);
    for (NSUInteger i = 0; i < limit && i < f.count; ) {
        if (containsColon(SGKaraokeLineText(f[i]))) { [f removeObjectAtIndex:i]; removedColon = YES; limit = MIN(3, f.count); }
        else i++;
    }
    // 3) Drop the leading run of colon lines: all of it if step 2 removed one, else only ≥2.
    NSUInteger leading = 0;
    while (leading < f.count && containsColon(SGKaraokeLineText(f[leading]))) leading++;
    if ((removedColon && leading >= 1) || (!removedColon && leading >= 2)) {
        [f removeObjectsInRange:NSMakeRange(0, leading)];
    }
    // 4) Drop any run of ≥2 consecutive colon lines further in.
    NSMutableArray<SGKaraokeLine *> *g = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < f.count) {
        if (containsColon(SGKaraokeLineText(f[i]))) {
            NSUInteger j = i;
            while (j < f.count && containsColon(SGKaraokeLineText(f[j]))) j++;
            if (j - i >= 2) i = j;
            else { [g addObject:f[i]]; i++; }
        } else { [g addObject:f[i]]; i++; }
    }
    f = g;
    // 5) First two: drop lines with a paren pair (credit annotations).
    limit = MIN(2, f.count);
    for (NSUInteger i = 0; i < limit && i < f.count; ) {
        if (containsParenPair(SGKaraokeLineText(f[i]))) { [f removeObjectAtIndex:i]; limit = MIN(2, f.count); }
        else i++;
    }
    return f.count ? f : nil;
}

// [00:34.30] Look — the same LRC shape LRCLIB serves, parsed the same way. A line may be stamped
// more than once when it is sung more than once. KuGou marks an absent translation with "//".
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
    return filterKaraokeLines(SGKaraokeEstimatedLines(starts, texts));
}

#pragma mark - KRC line parsing

// [lineStart,lineLength]<wordStart,wordLength,singer?>... — the KRC shape. Each word's text sits
// before its <start,length> stamp; a space before a token belongs to the preceding word.
static NSArray<SGKaraokeLine *> *linesFromKRC(NSString *krc) {
    static NSRegularExpression *header, *part;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        header = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+),(\\d+)\\]" options:0 error:nil];
        part = [NSRegularExpression regularExpressionWithPattern:@"<(\\d+),(\\d+),-?\\d+>" options:0 error:nil];
    });
    NSArray *romanRows = krcPronunciationRows(krc);
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    NSUInteger romanIndex = 0;
    for (NSString *rawRow in [krc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *row = [rawRow stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSTextCheckingResult *head = [header firstMatchInString:row options:0 range:NSMakeRange(0, row.length)];
        if (!head) continue;
        NSInteger lineStart = [row substringWithRange:[head rangeAtIndex:1]].integerValue;
        NSInteger lineEnd = lineStart + [row substringWithRange:[head rangeAtIndex:2]].integerValue;
        if (lineStart < 0 || lineStart > 36000000 || lineEnd < 0 || lineEnd > 36000000) continue;
        NSArray<NSTextCheckingResult *> *parts = [part matchesInString:row options:0
            range:NSMakeRange(NSMaxRange(head.range), row.length - NSMaxRange(head.range))];
        NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
        SGKaraokeWord *open = nil;
        BOOL spaced = YES;
        NSUInteger from = NSMaxRange(head.range);
        for (NSUInteger i = 0; i < parts.count; i++) {
            NSTextCheckingResult *match = parts[i];
            NSUInteger to = i + 1 < parts.count ? parts[i + 1].range.location : row.length;
            NSString *raw = [row substringWithRange:NSMakeRange(from, to - from)];
            NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSInteger start = lineStart + [row substringWithRange:[match rangeAtIndex:1]].integerValue;
            NSInteger length = [row substringWithRange:[match rangeAtIndex:2]].integerValue;
            from = NSMaxRange(match.range);
            if (start < 0 || start > 36000000 || length < 0 || length > 600000) continue;
            NSInteger end = start + MAX((NSInteger)1, length);
            BOOL unspaced = SGKaraokeUnspacedScript(text);
            if (text.length && open && !spaced && !unspaced) {
                open.text = [open.text stringByAppendingString:text];
                open.end = MAX(open.end, end);
            } else if (text.length) {
                SGKaraokeWord *word = [SGKaraokeWord new];
                word.text = text;
                word.start = start;
                word.end = end;
                word.joined = !spaced;
                [words addObject:word];
                open = unspaced ? nil : word;
            }
            spaced = raw.length > text.length || !text.length;
            if (spaced) open = nil;
        }
        if (!words.count) continue;
        SGKaraokeLine *line = [SGKaraokeLine new];
        line.words = words;
        line.start = lineStart;
        line.end = MAX(lineEnd, words.lastObject.end);
        // Romanisation: only when the KRC carries a per-word block that lines up with this row.
        if (romanRows && romanIndex < romanRows.count) {
            id roman = romanRows[romanIndex];
            if ([roman isKindOfClass:NSArray.class] && [roman count] == parts.count) {
                NSMutableArray<SGKaraokeWord *> *spokenWords = [NSMutableArray array];
                BOOL valid = YES;
                for (NSUInteger i = 0; i < parts.count; i++) {
                    if (![roman[i] isKindOfClass:NSString.class]) { valid = NO; break; }
                    NSString *spokenText = [roman[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if (!spokenText.length) { valid = NO; break; }
                    SGKaraokeWord *word = [SGKaraokeWord new];
                    word.text = spokenText;
                    word.start = lineStart + [row substringWithRange:[parts[i] rangeAtIndex:1]].integerValue;
                    word.end = MAX(word.start + 1, word.start + [row substringWithRange:[parts[i] rangeAtIndex:2]].integerValue);
                    word.joined = NO;
                    [spokenWords addObject:word];
                }
                if (valid && spokenWords.count) {
                    SGKaraokeLine *spoken = [SGKaraokeLine new];
                    spoken.start = line.start;
                    spoken.end = line.end;
                    spoken.align = line.align;
                    spoken.words = spokenWords;
                    line.pronunciation = spoken;
                }
            }
            romanIndex++;
        }
        [lines addObject:line];
    }
    return filterKaraokeLines(lines);
}

#pragma mark - result assembly

static SGLyricsResult *resultForLines(NSArray<SGKaraokeLine *> *lines) {
    if (!lines.count) return nil;
    SGLyricsResult *result = [SGLyricsResult new];
    result.synced = YES;
    result.wordTimed = lines.firstObject.words.count > 0;
    result.karaokeLines = lines;
    NSArray<NSNumber *> *starts;
    NSArray<NSString *> *texts;
    SGLyricsPageLines(lines, &starts, &texts);
    result.starts = starts;
    result.texts = texts;
    return result;
}

#pragma mark - the requests

static void tryDownload(NSDictionary *song, SGLyricsQuery *query, void (^done)(SGLyricsResult *)) {
    NSString *songID = [song[@"id"] description];
    NSString *accesskey = [song[@"accesskey"] isKindOfClass:NSString.class] ? song[@"accesskey"] : @"";
    NSURL *krcURL = SGLyricsURL(@"https://lyrics.kugou.com/download", @{
        @"ver": @"1", @"client": @"pc", @"id": songID, @"accesskey": accesskey,
        @"fmt": @"krc", @"charset": @"utf8"});
    SGLyricsGetJSON(krcURL, @{@"User-Agent": @"Mozilla/5.0"}, ^(id krcRoot) {
        NSDictionary *krcReply = [krcRoot isKindOfClass:NSDictionary.class] ? krcRoot : nil;
        NSString *encoded = [krcReply[@"content"] isKindOfClass:NSString.class] ? krcReply[@"content"] : nil;
        NSArray<SGKaraokeLine *> *lines = nil;
        if ([krcReply[@"status"] integerValue] == 200 && encoded.length) {
            NSString *krc = decodeKRC(encoded);
            if (krc.length) lines = linesFromKRC(krc);
        }
        if (lines.count) {
            SGLog(@"kugou: KRC decoded %lu word timed lines for %@", (unsigned long)lines.count, songID);
            SGLyricsResult *result = resultForLines(lines);
            if (result) { result.title = query.title; result.artist = query.artist; }
            done(result);
            return;
        }
        SGLog(@"kugou: KRC unavailable for %@; trying LRC", songID);
        NSURL *lrcURL = SGLyricsURL(@"https://lyrics.kugou.com/download", @{
            @"ver": @"1", @"client": @"pc", @"id": songID, @"accesskey": accesskey,
            @"fmt": @"lrc", @"charset": @"utf8"});
        SGLyricsGetJSON(lrcURL, @{@"User-Agent": @"Mozilla/5.0"}, ^(id lrcRoot) {
            NSDictionary *lrcReply = [lrcRoot isKindOfClass:NSDictionary.class] ? lrcRoot : nil;
            NSString *lrcEncoded = [lrcReply[@"content"] isKindOfClass:NSString.class] ? lrcReply[@"content"] : nil;
            NSData *lrcBytes = lrcEncoded.length ? [[NSData alloc] initWithBase64EncodedString:lrcEncoded options:0] : nil;
            NSString *lrc = lrcBytes ? [[NSString alloc] initWithData:lrcBytes encoding:NSUTF8StringEncoding] : nil;
            NSArray<SGKaraokeLine *> *lrcLines = ([lrcReply[@"status"] integerValue] == 200 && lrc.length) ? linesFromLRC(lrc) : nil;
            SGLyricsResult *result = lrcLines.count ? resultForLines(lrcLines) : nil;
            if (result) { result.title = query.title; result.artist = query.artist; }
            done(result);
        });
    });
}

static void kugouAsk(SGLyricsQuery *query, void (^done)(SGLyricsResult *)) {
    if (!query.title.length || !query.artist.length) { done(nil); return; }
    NSString *lead = [query.artist componentsSeparatedByString:@" feat"].firstObject;
    NSString *keyword = [NSString stringWithFormat:@"%@ - %@", query.title, lead];
    NSURL *url = SGLyricsURL(@"https://krcs.kugou.com/search", @{
        @"ver": @"1", @"man": @"yes", @"client": @"mobi", @"hash": @"", @"album_audio_id": @"",
        @"keyword": keyword,
        @"duration": [NSString stringWithFormat:@"%ld", (long)MAX(query.seconds, 0) * 1000]});
    SGLyricsGetJSON(url, @{@"User-Agent": @"Mozilla/5.0"}, ^(id root) {
        NSDictionary *reply = [root isKindOfClass:NSDictionary.class] ? root : nil;
        NSArray *candidates = [reply[@"candidates"] isKindOfClass:NSArray.class] && [reply[@"status"] integerValue] == 200
            ? reply[@"candidates"] : @[];
        NSString *leadLower = [lead lowercaseString];
        NSMutableArray<NSDictionary *> *fitting = [NSMutableArray array];
        for (id song in candidates) {
            if (![song isKindOfClass:NSDictionary.class]) continue;
            NSString *singer = [song[@"singer"] isKindOfClass:NSString.class] ? song[@"singer"] : @"";
            NSString *singers = singer.lowercaseString;
            BOOL artistOK = singers.length && ([singers containsString:leadLower] || [leadLower containsString:singers]);
            NSInteger duration = [song[@"duration"] respondsToSelector:@selector(integerValue)]
                ? [song[@"duration"] integerValue] : 0;
            BOOL timeOK = query.seconds <= 0 || duration <= 0 || labs(duration / 1000 - query.seconds) <= 8;
            if (artistOK && timeOK) [fitting addObject:song];
        }
        [fitting sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSString *as = [[a[@"singer"] isKindOfClass:NSString.class] ? a[@"singer"] : @"" lowercaseString];
            NSString *bs = [[b[@"singer"] isKindOfClass:NSString.class] ? b[@"singer"] : @"" lowercaseString];
            BOOL aMatch = as.length && ([as containsString:leadLower] || [leadLower containsString:as]);
            BOOL bMatch = bs.length && ([bs containsString:leadLower] || [leadLower containsString:bs]);
            if (aMatch != bMatch) return aMatch ? NSOrderedAscending : NSOrderedDescending;
            NSInteger ai = [a[@"duration"] respondsToSelector:@selector(integerValue)] ? [a[@"duration"] integerValue] / 1000 : 0;
            NSInteger bi = [b[@"duration"] respondsToSelector:@selector(integerValue)] ? [b[@"duration"] integerValue] / 1000 : 0;
            NSInteger ag = query.seconds > 0 && ai > 0 ? labs(ai - query.seconds) : NSIntegerMax;
            NSInteger bg = query.seconds > 0 && bi > 0 ? labs(bi - query.seconds) : NSIntegerMax;
            if (ag != bg) return ag < bg ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
        SGLog(@"kugou: search '%@' returned %lu candidates, %lu matching", keyword,
              (unsigned long)candidates.count, (unsigned long)fitting.count);
        if (!fitting.count) { SGLog(@"kugou: no recording of %@", query.title); done(nil); return; }
        // Try up to three recordings until one has lyrics. Recurses into itself, so a weak reference
        // breaks the ARC retain cycle a __block capture would make.
        __block NSUInteger index = 0;
        __block void (^tryNext)(void) = nil;
        __weak void (^weakTryNext)(void) = nil;
        void (^finish)(SGLyricsResult *) = ^(SGLyricsResult *r) { done(r); };
        tryNext = ^{
            if (index >= MIN(fitting.count, 3)) { finish(nil); return; }
            NSDictionary *song = fitting[index];
            index++;
            tryDownload(song, query, ^(SGLyricsResult *result) {
                if (result) finish(result);
                else {
                    void (^strong)(void) = weakTryNext;
                    if (strong) strong();
                }
            });
        };
        weakTryNext = tryNext;
        tryNext();
    });
}

SGLyricsAsk SGKuGouAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    kugouAsk(query, done);
};
