// See kl_json.h.
#include "kl_json.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *p; int depth; } kp;

static void ws(kp *k) { while (*k->p == ' ' || *k->p == '\t' || *k->p == '\n' || *k->p == '\r') k->p++; }

static int hex4(const char *p, unsigned *out) {
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char c = p[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
        else return 0;
    }
    *out = v;
    return 1;
}

static void put_utf8(char **o, unsigned cp) {
    char *d = *o;
    if (cp < 0x80) *d++ = (char)cp;
    else if (cp < 0x800) { *d++ = (char)(0xc0 | (cp >> 6)); *d++ = (char)(0x80 | (cp & 0x3f)); }
    else if (cp < 0x10000) {
        *d++ = (char)(0xe0 | (cp >> 12)); *d++ = (char)(0x80 | ((cp >> 6) & 0x3f));
        *d++ = (char)(0x80 | (cp & 0x3f));
    } else {
        *d++ = (char)(0xf0 | (cp >> 18)); *d++ = (char)(0x80 | ((cp >> 12) & 0x3f));
        *d++ = (char)(0x80 | ((cp >> 6) & 0x3f)); *d++ = (char)(0x80 | (cp & 0x3f));
    }
    *o = d;
}

// k->p at the opening quote. A decoded string is never longer than its source.
static char *pstr(kp *k) {
    const char *s = ++k->p;
    size_t n = 0;
    while (s[n] && s[n] != '"') { if (s[n] == '\\' && s[n + 1]) n++; n++; }
    if (s[n] != '"') return NULL;
    char *out = malloc(n + 1), *o = out;
    if (!out) return NULL;
    const char *p = s, *end = s + n;
    while (p < end) {
        if (*p != '\\') { *o++ = *p++; continue; }
        p++;
        switch (*p) {
        case 'n': *o++ = '\n'; p++; break;
        case 't': *o++ = '\t'; p++; break;
        case 'r': *o++ = '\r'; p++; break;
        case 'b': *o++ = '\b'; p++; break;
        case 'f': *o++ = '\f'; p++; break;
        case 'u': {
            unsigned cp;
            if (end - p < 5 || !hex4(p + 1, &cp)) { free(out); return NULL; }
            p += 5;
            if (cp >= 0xd800 && cp < 0xdc00 && end - p >= 6 && p[0] == '\\' && p[1] == 'u') {
                unsigned lo;
                if (hex4(p + 2, &lo) && lo >= 0xdc00 && lo < 0xe000) {
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                    p += 6;
                }
            }
            put_utf8(&o, cp);
            break;
        }
        default: *o++ = *p++; break;           // \" \\ \/
        }
    }
    *o = 0;
    k->p = end + 1;
    return out;
}

static kj *pval(kp *k);

static kj *node(kj_type t) { kj *v = calloc(1, sizeof *v); if (v) v->t = t; return v; }

static kj *pcontainer(kp *k, int obj) {
    if (++k->depth > 64) return NULL;
    kj *v = node(obj ? KJ_OBJ : KJ_ARR), **tail;
    if (!v) return NULL;
    tail = &v->child;
    k->p++;
    ws(k);
    if (*k->p == (obj ? '}' : ']')) { k->p++; k->depth--; return v; }
    for (;;) {
        char *key = NULL;
        ws(k);
        if (obj) {
            if (*k->p != '"' || !(key = pstr(k))) goto bad;
            ws(k);
            if (*k->p++ != ':') { free(key); goto bad; }
        }
        kj *c = pval(k);
        if (!c) { free(key); goto bad; }
        c->key = key;
        *tail = c;
        tail = &c->next;
        ws(k);
        if (*k->p == ',') { k->p++; continue; }
        if (*k->p == (obj ? '}' : ']')) { k->p++; break; }
        goto bad;
    }
    k->depth--;
    return v;
bad:
    kj_free(v);
    return NULL;
}

static kj *pval(kp *k) {
    ws(k);
    char c = *k->p;
    if (c == '{' || c == '[') return pcontainer(k, c == '{');
    if (c == '"') {
        char *s = pstr(k);
        if (!s) return NULL;
        kj *v = node(KJ_STR);
        if (!v) { free(s); return NULL; }
        v->s = s;
        return v;
    }
    if (!strncmp(k->p, "true", 4))  { k->p += 4; kj *v = node(KJ_BOOL); if (v) v->b = 1; return v; }
    if (!strncmp(k->p, "false", 5)) { k->p += 5; return node(KJ_BOOL); }
    if (!strncmp(k->p, "null", 4))  { k->p += 4; return node(KJ_NULL); }
    if (c == '-' || (c >= '0' && c <= '9')) {
        char *end;
        double d = strtod(k->p, &end);
        if (end == k->p) return NULL;
        kj *v = node(KJ_NUM);
        if (!v) return NULL;
        v->n = d;
        v->s = strndup(k->p, (size_t)(end - k->p));
        k->p = end;
        return v;
    }
    return NULL;
}

kj *kj_parse(const char *text) {
    if (!text) return NULL;
    kp k = { text, 0 };
    kj *v = pval(&k);
    if (!v) return NULL;
    ws(&k);
    if (*k.p) { kj_free(v); return NULL; }
    return v;
}

void kj_free(kj *v) {
    while (v) {
        kj *n = v->next;
        kj_free(v->child);
        free(v->key);
        free(v->s);
        free(v);
        v = n;
    }
}

kj *kj_get(const kj *o, const char *key) {
    if (!o || o->t != KJ_OBJ) return NULL;
    for (kj *c = o->child; c; c = c->next) if (c->key && !strcmp(c->key, key)) return c;
    return NULL;
}
int kj_is_true(const kj *v) { return v && v->t == KJ_BOOL && v->b; }
const char *kj_str(const kj *v, const char *d) { return v && v->t == KJ_STR ? v->s : d; }
double kj_num(const kj *v, double d) {
    if (!v) return d;
    if (v->t == KJ_NUM) return v->n;
    if (v->t == KJ_BOOL) return v->b;
    return d;
}
uint64_t kj_u64(const kj *v, uint64_t d) {
    if (!v || (v->t != KJ_NUM && v->t != KJ_STR) || !v->s) return d;
    char *end;
    unsigned long long x = strtoull(v->s, &end, 10);
    return end == v->s ? d : (uint64_t)x;
}

// ---- writer ----
static void grow(kjb *b, size_t more) {
    if (b->oom || b->n + more + 1 <= b->cap) return;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->n + more + 1) cap *= 2;
    char *p = realloc(b->p, cap);
    if (!p) { b->oom = 1; return; }
    b->p = p;
    b->cap = cap;
}
void kjb_add(kjb *b, const char *s) {
    size_t n = strlen(s);
    grow(b, n);
    if (b->oom) return;
    memcpy(b->p + b->n, s, n + 1);
    b->n += n;
}
void kjb_fmt(kjb *b, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char tmp[256];
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n < sizeof tmp) { kjb_add(b, tmp); return; }
    grow(b, (size_t)n);
    if (b->oom) return;
    va_start(ap, fmt);
    vsnprintf(b->p + b->n, (size_t)n + 1, fmt, ap);
    va_end(ap);
    b->n += (size_t)n;
}
void kjb_str(kjb *b, const char *s) {
    kjb_add(b, "\"");
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
        char e[8];
        if (*p == '"' || *p == '\\') { e[0] = '\\'; e[1] = (char)*p; e[2] = 0; }
        else if (*p == '\n') strcpy(e, "\\n");
        else if (*p == '\t') strcpy(e, "\\t");
        else if (*p == '\r') strcpy(e, "\\r");
        else if (*p < 0x20) snprintf(e, sizeof e, "\\u%04x", *p);
        else { e[0] = (char)*p; e[1] = 0; }
        kjb_add(b, e);
    }
    kjb_add(b, "\"");
}
void kjb_free(kjb *b) { free(b->p); b->p = NULL; b->n = b->cap = 0; }
