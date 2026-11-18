#ifndef C_SYSTEM_REGEX_H
#define C_SYSTEM_REGEX_H

#include <stdint.h>

// ICU ships in macOS as libicucore, with unversioned exported symbols.
// These declarations cover only the stable C API used by the tester.
typedef struct URegularExpression URegularExpression;
typedef int32_t UErrorCode;
typedef int8_t UBool;
typedef struct UParseError {
    int32_t line;
    int32_t offset;
    uint16_t preContext[16];
    uint16_t postContext[16];
} UParseError;

URegularExpression *uregex_open(const uint16_t *pattern, int32_t length, uint32_t flags,
                               UParseError *parse_error, UErrorCode *status);
void uregex_close(URegularExpression *expression);
void uregex_setTimeLimit(URegularExpression *expression, int32_t limit, UErrorCode *status);
void uregex_setStackLimit(URegularExpression *expression, int32_t limit, UErrorCode *status);
void uregex_setText(URegularExpression *expression, const uint16_t *text, int32_t length,
                    UErrorCode *status);
int32_t uregex_groupCount(URegularExpression *expression, UErrorCode *status);
int32_t uregex_groupNumberFromCName(URegularExpression *expression, const char *name,
                                  int32_t length, UErrorCode *status);
UBool uregex_findNext(URegularExpression *expression, UErrorCode *status);
int32_t uregex_start(URegularExpression *expression, int32_t group, UErrorCode *status);
int32_t uregex_end(URegularExpression *expression, int32_t group, UErrorCode *status);
const char *u_errorName(UErrorCode status);

enum {
    MUKRegexCaseInsensitive = 2,
    MUKRegexDotAll = 32,
    MUKRegexMultiline = 8
};

#endif
