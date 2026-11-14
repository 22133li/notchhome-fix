#import "NHFixDiag.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

NSUInteger nhfix_diagWillBegin = 0;
NSUInteger nhfix_diagDidEnd = 0;
NSUInteger nhfix_diagFrameCalls = 0;
NSUInteger nhfix_diagFrameActive = 0;
NSUInteger nhfix_diagIconOK = 0;
NSUInteger nhfix_diagScaleCalls = 0;
NSUInteger nhfix_diagCornerCalls = 0;
NSUInteger nhfix_diagMatchCalls = 0;
NSUInteger nhfix_diagAnimCalls = 0;
NSUInteger nhfix_diagAnimSkip = 0;
NSUInteger nhfix_diagAnimResp = 0;
NSUInteger nhfix_diagLayoutResp = 0;
NSInteger nhfix_diagLastStartedAtHome = -99;
NSInteger nhfix_diagLastBoundsOK = -99;

static NSString *nhfix_diagPath(void) {
    NSString *dir = @"/var/mobile/Library/Logs/NotchHomeFix";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"diag.txt"];
}

void nhfix_diagLogF(const char *format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NSString *path = nhfix_diagPath();
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                       dateStyle:NSDateFormatterNoStyle
                                                       timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"%@ %s\n", stamp, buffer];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}
