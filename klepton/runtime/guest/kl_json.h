// A small JSON reader and writer, for the Steam bridge (kl_steam_bridge.c).
//
// The tree keeps object members in source order (GetAchievementName(i) relies
// on that), numbers as both a double and their source text (a SteamID does not
// fit in a double), and every string decoded to UTF-8 with \u escapes,
// surrogate pairs included. Nothing here is fast or clever: the documents are a
// few KB, a handful of times per run.
#ifndef KL_JSON_H
#define KL_JSON_H
#include <stddef.h>
#include <stdint.h>

typedef enum { KJ_NULL, KJ_BOOL, KJ_NUM, KJ_STR, KJ_ARR, KJ_OBJ } kj_type;
typedef struct kj {
    kj_type t;
    char *key;              // member name inside an object, else NULL
    char *s;                // KJ_STR: the decoded string; KJ_NUM: the number's text
    double n;               // KJ_NUM
    int b;                  // KJ_BOOL
    struct kj *child, *next;
} kj;

kj  *kj_parse(const char *text);                 // NULL on a syntax error
void kj_free(kj *v);
kj  *kj_get(const kj *obj, const char *key);     // NULL if absent or obj is not an object
int  kj_is_true(const kj *v);                    // a KJ_BOOL that is true
const char *kj_str(const kj *v, const char *dflt);
double kj_num(const kj *v, double dflt);
uint64_t kj_u64(const kj *v, uint64_t dflt);     // a number or a string of digits

// A growing string. kjb_str appends a JSON string literal, quotes included.
typedef struct { char *p; size_t n, cap; int oom; } kjb;
void kjb_add(kjb *b, const char *s);
void kjb_fmt(kjb *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void kjb_str(kjb *b, const char *s);
void kjb_free(kjb *b);
#endif
