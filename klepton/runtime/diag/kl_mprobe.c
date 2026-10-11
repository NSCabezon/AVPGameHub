#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "klepton.h"
#include "kl_mprobe.h"

// ---- the slice of IL2CPP's embedding API this needs ----
// All exported by libil2cpp.so (checked with nm), so they resolve through the
// image registry like any other guest symbol.
typedef struct Il2CppDomain   Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage    Il2CppImage;
typedef struct Il2CppClass    Il2CppClass;
typedef struct MethodInfo     MethodInfo;
typedef struct Il2CppObject   Il2CppObject;

static struct {
    Il2CppDomain     *(*domain_get)(void);
    const Il2CppAssembly **(*domain_get_assemblies)(const Il2CppDomain *, size_t *);
    const Il2CppImage *(*assembly_get_image)(const Il2CppAssembly *);
    Il2CppClass      *(*class_from_name)(const Il2CppImage *, const char *, const char *);
    const MethodInfo *(*class_get_method_from_name)(Il2CppClass *, const char *, int);
    Il2CppObject     *(*runtime_invoke)(const MethodInfo *, void *, void **, Il2CppObject **);
    void             *(*object_unbox)(Il2CppObject *);
    Il2CppObject     *(*string_new)(const char *);
    uint32_t          (*array_length)(Il2CppObject *);
    Il2CppClass      *(*object_get_class)(Il2CppObject *);
    const char       *(*class_get_name)(Il2CppClass *);
    void             *(*class_get_type)(Il2CppClass *);
    Il2CppObject     *(*type_get_object)(void *);
} il;

// Managed object layouts (v24 / Unity 2019.4, LP64). Only the fields read here.
//   Il2CppObject { Il2CppClass *klass; void *monitor; }              16 B
//   Il2CppString { Il2CppObject; int32_t length; uint16_t chars[]; } chars at 20
//   Il2CppArray  { Il2CppObject; void *bounds; uintptr_t max_length; } data at 32
#define OBJ_HDR   16
#define STR_LEN   16
#define STR_CHARS 20
#define ARR_DATA  32

static int g_state;          // 0 = untried, 1 = up, -1 = unavailable

static int mprobe_init(void) {
    if (g_state) return g_state > 0;
    g_state = -1;
    kl_image *img = kl_find_image("libil2cpp.so");
    if (!img) return 0;
#define BIND(field, sym) \
    do { *(void **)&il.field = kl_sym(img, sym); \
         if (!il.field) { fprintf(stderr, "  [mprobe] libil2cpp exports no %s\n", sym); \
                          return 0; } } while (0)
    BIND(domain_get,                "il2cpp_domain_get");
    BIND(domain_get_assemblies,     "il2cpp_domain_get_assemblies");
    BIND(assembly_get_image,        "il2cpp_assembly_get_image");
    BIND(class_from_name,           "il2cpp_class_from_name");
    BIND(class_get_method_from_name,"il2cpp_class_get_method_from_name");
    BIND(runtime_invoke,            "il2cpp_runtime_invoke");
    BIND(object_unbox,              "il2cpp_object_unbox");
    BIND(string_new,                "il2cpp_string_new");
    BIND(array_length,              "il2cpp_array_length");
    BIND(object_get_class,          "il2cpp_object_get_class");
    BIND(class_get_name,            "il2cpp_class_get_name");
    BIND(class_get_type,            "il2cpp_class_get_type");
    BIND(type_get_object,           "il2cpp_type_get_object");
#undef BIND
    g_state = 1;
    return 1;
}

// Search every loaded assembly rather than naming one: which module a type
// lives in is a Unity-version detail (Input moved to UnityEngine.CoreModule,
// InputTracking to UnityEngine.XRModule), and 87 images is a cheap scan done
// once per method.
static Il2CppClass *find_class(const char *ns, const char *name) {
    Il2CppDomain *dom = il.domain_get();
    if (!dom) return NULL;
    size_t n = 0;
    const Il2CppAssembly **as = il.domain_get_assemblies(dom, &n);
    for (size_t i = 0; i < n; i++) {
        const Il2CppImage *im = il.assembly_get_image(as[i]);
        if (!im) continue;
        Il2CppClass *k = il.class_from_name(im, ns, name);
        if (k) return k;
    }
    return NULL;
}

static const MethodInfo *find_method(const char *ns, const char *cls,
                                     const char *meth, int argc) {
    Il2CppClass *k = find_class(ns, cls);
    if (!k) { fprintf(stderr, "  [mprobe] no class %s.%s\n", ns, cls); return NULL; }
    const MethodInfo *m = il.class_get_method_from_name(k, meth, argc);
    if (!m) fprintf(stderr, "  [mprobe] %s.%s has no %s/%d\n", ns, cls, meth, argc);
    return m;
}

// Invoke, reporting a managed throw by class name instead of letting it
// escape. A probe that aborts the run it is measuring is worse than no probe.
static Il2CppObject *invoke_on(Il2CppObject *self, const MethodInfo *m,
                               void **args, const char *what) {
    if (!m) return NULL;
    Il2CppObject *exc = NULL;
    Il2CppObject *r = il.runtime_invoke(m, self, args, &exc);
    if (exc) {
        Il2CppClass *k = il.object_get_class(exc);
        fprintf(stderr, "  [mprobe] %s threw %s\n", what,
                k ? il.class_get_name(k) : "?");
        return NULL;
    }
    return r;
}

static Il2CppObject *invoke(const MethodInfo *m, void **args, const char *what) {
    return invoke_on(NULL, m, args, what);   // static methods
}

static float invoke_float(const MethodInfo *m, void **args, const char *what) {
    Il2CppObject *r = invoke(m, args, what);
    if (!r) return 0.0f;
    return *(float *)il.object_unbox(r);
}

// Managed string -> ASCII, for the joystick names.
static void str_ascii(Il2CppObject *s, char *out, size_t cap) {
    if (!s) { snprintf(out, cap, "(null)"); return; }
    int32_t len = *(int32_t *)((uint8_t *)s + STR_LEN);
    const uint16_t *ch = (const uint16_t *)((uint8_t *)s + STR_CHARS);
    size_t o = 0;
    for (int32_t i = 0; i < len && o + 1 < cap; i++)
        out[o++] = (ch[i] >= 0x20 && ch[i] < 0x7f) ? (char)ch[i] : '?';
    out[o] = 0;
}

// ---- KL_PROBE_ENUM: read an enum's VALUES out of the running guest --------
//
// The values of a C# enum are the one thing about the guest's ABI that is
// neither in its exported symbols nor in its strings: global-metadata.dat holds
// the names, and the numbers live in a constant table whose layout is a
// metadata-version detail. But the runtime knows them, and it will answer
// through ordinary reflection — `Enum.GetNames(t)` and `Enum.GetValues(t)`.
//
// This exists because kl_ovrplat has to hand the guest a MESSAGE, and a message
// carries `Message.MessageType`, which the guest's own `ParseMessageHandle`
// switches on: a number we guessed lands in its `default` arm, which logs
// "Unrecognized message type" and produces no message at all. Same argument as
// OVRP_HEADSET_OCULUS_QUEST_2 in kl_ovrp.c — read the value out of the guest
// rather than out of a header we do not have — with reflection instead of a
// metadata scan, because that also works for a nested type.
//
//   KL_PROBE_ENUM="Oculus.Platform.Message/MessageType,Oculus.Platform.User..."
//
// Comma-separated, `Namespace.Type` (nested types with `/`), printed once at
// the first probe tick. Diagnostic only; nothing in the shipping path reads it.
static void probe_dump_enum(const char *spec) {
    char ns[128] = "", name[128] = "";
    const char *dot = strrchr(spec, '.');
    if (dot) {
        size_t nl = (size_t)(dot - spec);
        if (nl >= sizeof ns) nl = sizeof ns - 1;
        memcpy(ns, spec, nl); ns[nl] = 0;
        snprintf(name, sizeof name, "%s", dot + 1);
    } else {
        snprintf(name, sizeof name, "%s", spec);   // the global namespace
    }
    Il2CppClass *k = find_class(ns, name);
    if (!k) { fprintf(stderr, "  [mprobe] enum: no class %s.%s\n", ns, name); return; }
    void         *ty  = il.class_get_type(k);
    Il2CppObject *tyo = ty ? il.type_get_object(ty) : NULL;
    if (!tyo) { fprintf(stderr, "  [mprobe] enum: no System.Type for %s\n", spec); return; }

    const MethodInfo *m_names  = find_method("System", "Enum", "GetNames", 1);
    const MethodInfo *m_values = find_method("System", "Enum", "GetValues", 1);
    void *args[1] = { tyo };
    Il2CppObject *names  = invoke(m_names,  args, "Enum.GetNames");
    Il2CppObject *values = invoke(m_values, args, "Enum.GetValues");
    if (!names || !values) return;
    uint32_t n = il.array_length(names);
    // GetValues returns an array OF THE ENUM TYPE, so its elements are the
    // underlying integer, not boxed objects. Four bytes unless the enum has an
    // explicit wider base, which none of the ones this exists for do — the
    // stride is checked against the array length rather than assumed, so a
    // long-backed enum prints as such instead of silently reading halves.
    const uint8_t *vdata = (const uint8_t *)values + ARR_DATA;
    const void   **ndata = (const void **)((const uint8_t *)names + ARR_DATA);
    fprintf(stderr, "  [mprobe] enum %s: %u value(s)\n", spec, n);
    for (uint32_t i = 0; i < n; i++) {
        char nm[128];
        str_ascii((Il2CppObject *)ndata[i], nm, sizeof nm);
        int32_t v; memcpy(&v, vdata + (size_t)i * 4, sizeof v);
        fprintf(stderr, "  [mprobe]   %-56s = %d (0x%08x)\n", nm, v, (unsigned)v);
    }
}

// Adapted from avp-play (MIT, github.com/myMartek/avp-play) runtime/diag/kl_mprobe.c:
// KL_PROBE_METHODS / KL_PROBE_FIELDS / KL_PROBE_XFORM (diagnostics, env-gated) and
// kl_mprobe_nexus_frame_budget (AC Nexus only, KL_NEXUS_FRAME_BUDGET).
//
// ---- KL_PROBE_METHODS: which methods of a class SURVIVED stripping ---------
//
// IL2CPP's managed stripping removes methods nothing in the build calls, and
// the metadata's string table cannot say which: a name there may belong to a
// field, a property or another class. The runtime can — il2cpp_class_get_methods
// walks exactly what this build compiled. Asked for the custom-level classes,
// whose shells are in the Quest build while their disk-reading half is not.
//
//   KL_PROBE_METHODS="CustomLevelLoader,BeatmapLevelsModel"
//
// Same spelling and same tick as KL_PROBE_ENUM. `ptr` is the methodPointer (a
// MethodInfo's first field), NULL for an abstract or generic-definition method.
static void probe_dump_methods_of(const char *spec) {
    char ns[128] = "", name[128] = "";
    const char *dot = strrchr(spec, '.');
    if (dot) {
        size_t nl = (size_t)(dot - spec);
        if (nl >= sizeof ns) nl = sizeof ns - 1;
        memcpy(ns, spec, nl); ns[nl] = 0;
        snprintf(name, sizeof name, "%s", dot + 1);
    } else {
        snprintf(name, sizeof name, "%s", spec);
    }
    kl_image *img = kl_find_image("libil2cpp.so");
    Il2CppClass *k = find_class(ns, name);
    if (!img || !k) { fprintf(stderr, "  [mprobe] methods %s: no such class\n", spec); return; }
    typedef const MethodInfo *(*get_methods_fn)(Il2CppClass *, void **);
    typedef const char *(*m_name_fn)(const MethodInfo *);
    typedef uint32_t (*m_argc_fn)(const MethodInfo *);
    typedef const void *(*m_param_fn)(const MethodInfo *, uint32_t);
    typedef char *(*t_name_fn)(const void *);
    typedef void *(*get_fields_fn)(Il2CppClass *, void **);
    typedef const char *(*f_name_fn)(void *);
    typedef const void *(*f_type_fn)(void *);
    typedef size_t (*f_off_fn)(void *);
    get_methods_fn get_methods = (get_methods_fn)kl_sym(img, "il2cpp_class_get_methods");
    m_name_fn      m_name      = (m_name_fn)kl_sym(img, "il2cpp_method_get_name");
    m_argc_fn      m_argc      = (m_argc_fn)kl_sym(img, "il2cpp_method_get_param_count");
    m_param_fn     m_param     = (m_param_fn)kl_sym(img, "il2cpp_method_get_param");
    t_name_fn      t_name      = (t_name_fn)kl_sym(img, "il2cpp_type_get_name");
    get_fields_fn  get_fields  = (get_fields_fn)kl_sym(img, "il2cpp_class_get_fields");
    f_name_fn      f_name      = (f_name_fn)kl_sym(img, "il2cpp_field_get_name");
    f_type_fn      f_type      = (f_type_fn)kl_sym(img, "il2cpp_field_get_type");
    f_off_fn       f_off       = (f_off_fn)kl_sym(img, "il2cpp_field_get_offset");
    if (!get_methods || !m_name) return;
    fprintf(stderr, "  [mprobe] methods of %s:\n", spec);
    void *it = NULL; unsigned n = 0;
    for (const MethodInfo *m; (m = get_methods(k, &it)) != NULL; n++) {
        void *ptr; memcpy(&ptr, m, sizeof ptr);
        unsigned argc = m_argc ? (unsigned)m_argc(m) : 0u;
        fprintf(stderr, "  [mprobe]   %-58s /%u ptr=%p\n", m_name(m), argc, ptr);
        // The parameter TYPES, which is what a caller building the argument
        // array by hand needs and what the name alone cannot give.
        if (m_param && t_name)
            for (unsigned i = 0; i < argc; i++) {
                const void *t = m_param(m, i);
                fprintf(stderr, "  [mprobe]       arg%-2u %s\n", i, t ? t_name(t) : "?");
            }
    }
    fprintf(stderr, "  [mprobe]   (%u method(s))\n", n);
    // ...and the fields, with offsets: the half of a class that reflection by
    // method name cannot reach when the accessor was stripped.
    if (get_fields && f_name && f_type && f_off && t_name) {
        fprintf(stderr, "  [mprobe] fields of %s:\n", spec);
        void *fit = NULL;
        for (void *f; (f = get_fields(k, &fit)) != NULL; ) {
            const void *t = f_type(f);
            fprintf(stderr, "  [mprobe]   +0x%03zx %-44s %s\n", f_off(f), f_name(f),
                    t ? t_name(t) : "?");
        }
    }
}

static void probe_dump_methods(void) {
    const char *spec = kl_env_str("KL_PROBE_METHODS", NULL);
    if (!spec || !*spec) return;
    char buf[512];
    snprintf(buf, sizeof buf, "%s", spec);
    for (char *p = buf, *tok; (tok = strsep(&p, ",")) != NULL; )
        if (*tok) probe_dump_methods_of(tok);
}

// ---- KL_PROBE_FIELDS: the instance fields of a live component --------------
//
// KL_PROBE_XFORM says WHICH transform went NaN; the component that writes it
// keeps the inputs of that arithmetic in private fields no accessor exposes
// (a calibrated height, a weight, a cached pose). Take the component off the
// scene object that carries it and print its value-typed fields raw, by offset.
// Object.FindObjectOfType would spare the path, but stripping took it.
//
//   KL_PROBE_FIELDS="PlayerController(Clone)/TrackingOffset=Camouflaj.XRFramework.Tracking.OffsetTracker"
//
// Same cadence as KL_PROBE_XFORM, at most KL_PROBE_FIELDS_MAX (8) times.
static void probe_fields_of(unsigned frame, const char *item) {
    char path[256];
    snprintf(path, sizeof path, "%s", item);
    char *eq = strchr(path, '=');
    if (!eq) { fprintf(stderr, "  [mprobe] fields %s: want <scene path>=<Namespace.Class>\n", item); return; }
    *eq = 0;
    const char *spec = eq + 1;
    char ns[128] = "", name[128] = "";
    const char *dot = strrchr(spec, '.');
    if (dot) {
        size_t nl = (size_t)(dot - spec);
        if (nl >= sizeof ns) nl = sizeof ns - 1;
        memcpy(ns, spec, nl); ns[nl] = 0;
        snprintf(name, sizeof name, "%s", dot + 1);
    } else {
        snprintf(name, sizeof name, "%s", spec);
    }
    kl_image *img = kl_find_image("libil2cpp.so");
    Il2CppClass *k = find_class(ns, name);
    if (!img || !k) { fprintf(stderr, "  [mprobe] fields %s: no such class\n", spec); return; }
    typedef char *(*t_name_fn)(const void *);
    typedef void *(*get_fields_fn)(Il2CppClass *, void **);
    typedef const char *(*f_name_fn)(void *);
    typedef const void *(*f_type_fn)(void *);
    typedef size_t (*f_off_fn)(void *);
    typedef int (*f_flags_fn)(void *);
    t_name_fn      t_name     = (t_name_fn)kl_sym(img, "il2cpp_type_get_name");
    get_fields_fn  get_fields = (get_fields_fn)kl_sym(img, "il2cpp_class_get_fields");
    f_name_fn      f_name     = (f_name_fn)kl_sym(img, "il2cpp_field_get_name");
    f_type_fn      f_type     = (f_type_fn)kl_sym(img, "il2cpp_field_get_type");
    f_off_fn       f_off      = (f_off_fn)kl_sym(img, "il2cpp_field_get_offset");
    f_flags_fn     f_flags    = (f_flags_fn)kl_sym(img, "il2cpp_field_get_flags");
    if (!t_name || !get_fields || !f_name || !f_type || !f_off || !f_flags) return;
    // GetComponent has a (Type) and a (String) overload with the same arity;
    // the by-name lookup returns whichever comes first. Pick by parameter type.
    typedef const MethodInfo *(*get_methods_fn)(Il2CppClass *, void **);
    typedef const char *(*m_name_fn)(const MethodInfo *);
    typedef uint32_t (*m_argc_fn)(const MethodInfo *);
    typedef const void *(*m_param_fn)(const MethodInfo *, uint32_t);
    static const MethodInfo *m_find, *m_getc;
    static int resolved;
    if (!resolved) {
        resolved = 1;
        m_find = find_method("UnityEngine", "GameObject", "Find", 1);
        get_methods_fn get_methods = (get_methods_fn)kl_sym(img, "il2cpp_class_get_methods");
        m_name_fn      m_name      = (m_name_fn)kl_sym(img, "il2cpp_method_get_name");
        m_argc_fn      m_argc      = (m_argc_fn)kl_sym(img, "il2cpp_method_get_param_count");
        m_param_fn     m_param     = (m_param_fn)kl_sym(img, "il2cpp_method_get_param");
        Il2CppClass *gok = find_class("UnityEngine", "GameObject");
        void *it = NULL;
        if (gok && get_methods && m_name && m_argc && m_param)
            for (const MethodInfo *m; (m = get_methods(gok, &it)) != NULL; ) {
                if (strcmp(m_name(m), "GetComponent") || m_argc(m) != 1) continue;
                const void *t = m_param(m, 0);
                if (t && !strcmp(t_name(t), "System.Type")) { m_getc = m; break; }
            }
        if (!m_getc) fprintf(stderr, "  [mprobe] GameObject has no GetComponent(Type)\n");
    }
    if (!m_find || !m_getc) return;
    void *a0[1] = { il.string_new(path) };
    Il2CppObject *go = invoke(m_find, a0, "GameObject.Find");
    if (!go) return;                                  // not spawned yet: stay quiet
    void *a1[1] = { il.type_get_object(il.class_get_type(k)) };
    Il2CppObject *obj = invoke_on(go, m_getc, a1, "GameObject.GetComponent");
    if (!obj) { fprintf(stderr, "  [mprobe f%u] fields %s: %s carries none\n", frame, spec, path); return; }
    fprintf(stderr, "  [mprobe f%u] fields of the live %s @%p:\n", frame, spec, (void *)obj);
    const uint8_t *base = (const uint8_t *)obj;
    void *fit = NULL;
    for (void *f; (f = get_fields(k, &fit)) != NULL; ) {
        if (f_flags(f) & 0x10) continue;                  // static: not in the instance
        const void *t = f_type(f);
        const char *tn = t ? t_name(t) : "?";
        size_t off = f_off(f);
        const uint8_t *p = base + off;
        float v[4]; int32_t i32; memcpy(v, p, sizeof v); memcpy(&i32, p, sizeof i32);
        if (!strcmp(tn, "System.Single"))
            fprintf(stderr, "  [mprobe]   +0x%03zx %-34s %g\n", off, f_name(f), v[0]);
        else if (!strcmp(tn, "System.Boolean"))
            fprintf(stderr, "  [mprobe]   +0x%03zx %-34s %s\n", off, f_name(f), p[0] ? "true" : "false");
        else if (!strcmp(tn, "UnityEngine.Vector3"))
            fprintf(stderr, "  [mprobe]   +0x%03zx %-34s (%g %g %g)\n", off, f_name(f), v[0], v[1], v[2]);
        else if (!strcmp(tn, "UnityEngine.Quaternion"))
            fprintf(stderr, "  [mprobe]   +0x%03zx %-34s (%g %g %g %g)\n", off, f_name(f), v[0], v[1], v[2], v[3]);
        else if (!strcmp(tn, "System.Int32") || strstr(tn, "Flags") || strstr(tn, "Type") || strstr(tn, "Mode"))
            fprintf(stderr, "  [mprobe]   +0x%03zx %-34s %d   (%s)\n", off, f_name(f), i32, tn);
        else if (!strncmp(tn, "System.Nullable<", 16))
            // Mono lays Nullable<T> out as { T value; bool has_value }.
            fprintf(stderr, "  [mprobe]   +0x%03zx %-34s raw(%g %g %g %g)   (%s)\n", off, f_name(f),
                    v[0], v[1], v[2], v[3], tn);
        else {
            void *ref; memcpy(&ref, p, sizeof ref);
            fprintf(stderr, "  [mprobe]   +0x%03zx %-34s %s   (%s)\n", off, f_name(f),
                    ref ? "set" : "null", tn);
        }
    }
}

static void probe_fields(unsigned frame) {
    const char *spec = kl_env_str("KL_PROBE_FIELDS", NULL);
    static unsigned printed, cap;
    if (!cap) cap = kl_env_uint("KL_PROBE_FIELDS_MAX", 8u);
    if (!spec || !*spec || printed >= cap) return;
    char buf[512];
    snprintf(buf, sizeof buf, "%s", spec);
    for (char *p = buf, *tok; (tok = strsep(&p, ",")) != NULL; )
        if (*tok) probe_fields_of(frame, tok);
    printed++;
}

// ---- KL_PROBE_XFORM: the local TRS along a scene path ----------------------
//
// Unity says "Infinity or NaN ... transform matrix" and names the LEAF of a
// hierarchy path. Which ancestor went bad first, and whether it is its
// position, rotation or scale, is what decides where to look — a NaN rotation
// is a pose source, a zero or NaN scale is something else entirely — and the
// message carries none of it. So walk the path from the root object down and
// print each level's own local values.
//
//   KL_PROBE_XFORM="PlayerController(Clone)/TrackingOffset/TrackedHeadset/Camera"
//
// Printed on the probe's cadence (KL_PROBE_FROM / KL_PROBE_EVERY), at most
// eight times, and only once the root object exists.
static void probe_xform_path(unsigned frame) {
    const char *spec = kl_env_str("KL_PROBE_XFORM", NULL);
    static unsigned printed;
    if (!spec || !*spec || printed >= 8) return;
    static const MethodInfo *m_find, *m_tr, *m_child, *m_lp, *m_lr, *m_ls, *m_wp;
    static int resolved;
    if (!resolved) {
        resolved = 1;
        m_find  = find_method("UnityEngine", "GameObject", "Find", 1);
        m_tr    = find_method("UnityEngine", "GameObject", "get_transform", 0);
        m_child = find_method("UnityEngine", "Transform", "Find", 1);
        m_lp    = find_method("UnityEngine", "Transform", "get_localPosition", 0);
        m_lr    = find_method("UnityEngine", "Transform", "get_localRotation", 0);
        m_ls    = find_method("UnityEngine", "Transform", "get_localScale", 0);
        m_wp    = find_method("UnityEngine", "Transform", "get_position", 0);
    }
    if (!m_find || !m_tr || !m_child) return;
    char buf[512];
    snprintf(buf, sizeof buf, "%s", spec);
    char *rest = buf, *seg = strsep(&rest, "/");
    void *a1[1] = { il.string_new(seg) };
    Il2CppObject *go = invoke(m_find, a1, "GameObject.Find");
    if (!go) return;                                  // not spawned yet: stay quiet
    Il2CppObject *t = invoke_on(go, m_tr, NULL, "GameObject.transform");
    fprintf(stderr, "  [mprobe f%u] xform path %s\n", frame, spec);
    for (int depth = 0; t; depth++) {
        float lp[3] = {0}, lr[4] = {0}, ls[3] = {0}, wp[3] = {0};
        Il2CppObject *o;
        if (m_lp && (o = invoke_on(t, m_lp, NULL, "localPosition"))) memcpy(lp, il.object_unbox(o), sizeof lp);
        if (m_lr && (o = invoke_on(t, m_lr, NULL, "localRotation"))) memcpy(lr, il.object_unbox(o), sizeof lr);
        if (m_ls && (o = invoke_on(t, m_ls, NULL, "localScale")))    memcpy(ls, il.object_unbox(o), sizeof ls);
        if (m_wp && (o = invoke_on(t, m_wp, NULL, "position")))      memcpy(wp, il.object_unbox(o), sizeof wp);
        fprintf(stderr, "  [mprobe]   %*s%-18s lpos(%g %g %g) lrot(%g %g %g %g) lscale(%g %g %g) wpos(%g %g %g)\n",
                depth * 2, "", seg, lp[0], lp[1], lp[2], lr[0], lr[1], lr[2], lr[3],
                ls[0], ls[1], ls[2], wp[0], wp[1], wp[2]);
        seg = rest ? strsep(&rest, "/") : NULL;
        if (!seg) break;
        void *a2[1] = { il.string_new(seg) };
        t = invoke_on(t, m_child, a2, "Transform.Find");
        if (!t) fprintf(stderr, "  [mprobe]   %*s%s: no such child\n", depth * 2 + 2, "", seg);
    }
    printed++;
}

static void probe_dump_enums(void) {
    const char *spec = kl_env_str("KL_PROBE_ENUM", NULL);
    if (!spec || !*spec) return;
    char buf[512];
    snprintf(buf, sizeof buf, "%s", spec);
    for (char *p = buf, *tok; (tok = strsep(&p, ",")) != NULL; )
        if (*tok) probe_dump_enum(tok);
}

// The axes this title binds (parsed out of globalgamemanagers).
static const char *const AXES[] = {
    "TriggerLeftHand", "TriggerRightHand",
    "HorizontalLeftHand", "VerticalLeftHand",
    "HorizontalRightHand", "VerticalRightHand",
    "MenuButtonLeftHand", "MenuButtonRightHand",
};
#define N_AXES (sizeof AXES / sizeof AXES[0])

// ---- KL_PROBE_STACKTRACE: make Unity's own exception log say WHERE ---------
//
// A managed exception that prints its message and nothing else is a name
// without an address. BONELAB throws `ArgumentOutOfRangeException` once a
// frame out of Unity's SRP `XRSystem` and the log carries three blank lines
// where the stack should be — which has two very different causes, and they
// are not distinguishable from the native side: either the build strips
// managed stack traces, or the game called `Application.SetStackTraceLogType`
// to turn them off. `Application.GetStackTraceLogType` answers that, so this
// PRINTS the setting it found before changing it: a probe that reports
// "already ScriptOnly" is telling you the traces are genuinely unavailable and
// that this instrument is a dead end, which is worth as much as a trace.
//
// StackTraceLogType { None = 0, ScriptOnly = 1, Full = 2 } and
// LogType { Error = 0, Assert = 1, Warning = 2, Log = 3, Exception = 4 } — both
// are UnityEngine enums stable since 5.x. Enums marshal as their underlying
// int, so il2cpp_runtime_invoke takes the ADDRESS of each value.
//
// Diagnostic only, and it changes the guest's logging configuration, so it is
// off unless asked for.
static void probe_stack_traces(void) {
    static const char *const LOGTYPE[] = { "Error", "Assert", "Warning", "Log",
                                           "Exception" };
    static const char *const STLT[] = { "None", "ScriptOnly", "Full" };

    const MethodInfo *m_get = find_method("UnityEngine", "Application",
                                          "GetStackTraceLogType", 1);
    const MethodInfo *m_set = find_method("UnityEngine", "Application",
                                          "SetStackTraceLogType", 2);
    if (!m_get || !m_set) return;

    // What the guest asked for, before we touch it.
    int want = (int)kl_env_uint("KL_PROBE_STACKTRACE", 1);
    if (want < 0 || want > 2) want = 1;
    for (int lt = 0; lt < 5; lt++) {
        int arg = lt;
        void *ga[1] = { &arg };
        Il2CppObject *r = invoke(m_get, ga, "Application.GetStackTraceLogType");
        int had = r ? *(int32_t *)il.object_unbox(r) : -1;
        int set = want;
        void *sa[2] = { &arg, &set };
        invoke(m_set, sa, "Application.SetStackTraceLogType");
        fprintf(stderr, "  [mprobe] stack traces for %-9s: %s -> %s\n",
                LOGTYPE[lt],
                (had >= 0 && had <= 2) ? STLT[had] : "?",
                STLT[want]);
    }
}

// ---- KL_PROBE_XR: what Unity thinks the XR display IS ---------------------
//
// Every number on this path is one WE answered — the eye texture size through
// ovrp_CalculateEyeLayerDesc, the layout through ovrp_GetSystemMultiViewSupported,
// the viewport through ovrp_CalculateEyeViewportRect — and they travel through
// libunity and the Oculus XR provider before Unity's own render loop reads them
// back. That round trip is where they can stop agreeing, and nothing on the
// native side can see the far end of it: our log says what we said, not what
// Unity concluded. `XRSettings` is Unity's conclusion, in Unity's words.
//
// The reason this exists: BONELAB throws `ArgumentOutOfRangeException` once per
// frame out of the SRP render loop with an EMPTY stack trace (the build carries
// none — `KL_PROBE_STACKTRACE` measured that and is a dead end), so the throw
// site cannot be named from either side. What can be named is a disagreement,
// and the first candidate is the stereo mode: a title authored for Single Pass
// Instanced whose display hands back two separate 2D textures is a shape its
// renderer may never have run.
static void probe_xr_display(unsigned frame) {
    // UnityEngine.XR.StereoRenderingMode { MultiPass = 0, SinglePass = 1,
    // SinglePassInstanced = 2, SinglePassMultiview = 3 }.
    static const char *const SRM[] = { "MultiPass", "SinglePass",
                                       "SinglePassInstanced",
                                       "SinglePassMultiview" };
    static const MethodInfo *m_mode, *m_w, *m_h, *m_vps, *m_en, *m_dev, *m_occ;
    static int resolved;
    if (!resolved) {
        resolved = 1;
        m_mode = find_method("UnityEngine.XR", "XRSettings",
                             "get_stereoRenderingMode", 0);
        m_w    = find_method("UnityEngine.XR", "XRSettings", "get_eyeTextureWidth", 0);
        m_h    = find_method("UnityEngine.XR", "XRSettings", "get_eyeTextureHeight", 0);
        m_vps  = find_method("UnityEngine.XR", "XRSettings",
                             "get_renderViewportScale", 0);
        m_en   = find_method("UnityEngine.XR", "XRSettings", "get_enabled", 0);
        m_dev  = find_method("UnityEngine.XR", "XRSettings", "get_loadedDeviceName", 0);
        m_occ  = find_method("UnityEngine.XR", "XRSettings",
                             "get_useOcclusionMesh", 0);
    }
    Il2CppObject *mo = invoke(m_mode, NULL, "XRSettings.stereoRenderingMode");
    Il2CppObject *wo = invoke(m_w,    NULL, "XRSettings.eyeTextureWidth");
    Il2CppObject *ho = invoke(m_h,    NULL, "XRSettings.eyeTextureHeight");
    Il2CppObject *so = invoke(m_vps,  NULL, "XRSettings.renderViewportScale");
    Il2CppObject *eo = invoke(m_en,   NULL, "XRSettings.enabled");
    Il2CppObject *oo = invoke(m_occ,  NULL, "XRSettings.useOcclusionMesh");
    Il2CppObject *dv = invoke(m_dev,  NULL, "XRSettings.loadedDeviceName");
    int mode = mo ? *(int32_t *)il.object_unbox(mo) : -1;
    char dn[128] = "?";
    if (dv) str_ascii(dv, dn, sizeof dn);
    fprintf(stderr, "  [mprobe f%u] XRSettings: device=\"%s\" enabled=%s "
                    "stereo=%d (%s) eyeTexture=%dx%d viewportScale=%.3f "
                    "occlusionMesh=%s\n",
            frame, dn,
            eo ? (*(uint8_t *)il.object_unbox(eo) ? "1" : "0") : "?",
            mode, (mode >= 0 && mode <= 3) ? SRM[mode] : "?",
            wo ? *(int32_t *)il.object_unbox(wo) : -1,
            ho ? *(int32_t *)il.object_unbox(ho) : -1,
            so ? (double)*(float *)il.object_unbox(so) : -1.0,
            oo ? (*(uint8_t *)il.object_unbox(oo) ? "1" : "0") : "?");
}

// ---------------------------------------------------------------------------
// KL_PROBE_RESOLVE=0xoff[,0xoff...]: name the managed method CONTAINING each
// given libil2cpp offset. The sampler reports parked pcs as libil2cpp+0x...;
// on metadata v29 its own resolver cannot name them, but the RUNTIME can:
// enumerate every image -> class -> method through the embedding API, read
// each MethodInfo's methodPointer (its first field - stable across il2cpp
// versions), and keep the nearest method at or below each target. One pass,
// a few seconds, printed once.
static void mprobe_resolve_offsets(void) {
    const char *spec = kl_env_str("KL_PROBE_RESOLVE", NULL);
    if (!spec || !*spec) return;
    kl_image *img = kl_find_image("libil2cpp.so");
    if (!img) return;
    typedef const MethodInfo *(*get_methods_fn)(Il2CppClass *, void **);
    typedef size_t (*class_count_fn)(const Il2CppImage *);
    typedef Il2CppClass *(*get_class_fn)(const Il2CppImage *, size_t);
    typedef const char *(*m_name_fn)(const MethodInfo *);
    typedef const char *(*i_name_fn)(const Il2CppImage *);
    get_methods_fn get_methods = (get_methods_fn)kl_sym(img, "il2cpp_class_get_methods");
    class_count_fn class_count = (class_count_fn)kl_sym(img, "il2cpp_image_get_class_count");
    get_class_fn   get_class   = (get_class_fn)kl_sym(img, "il2cpp_image_get_class");
    m_name_fn      m_name      = (m_name_fn)kl_sym(img, "il2cpp_method_get_name");
    i_name_fn      i_name      = (i_name_fn)kl_sym(img, "il2cpp_image_get_name");
    if (!get_methods || !class_count || !get_class || !m_name) {
        fprintf(stderr, "  [mprobe] resolve: enumeration exports missing\n");
        return;
    }
    uintptr_t base = (uintptr_t)kl_base(img);
    enum { MAXT = 8 };
    uintptr_t tgt[MAXT]; int nt = 0;
    for (const char *p = spec; *p && nt < MAXT; ) {
        tgt[nt++] = base + (uintptr_t)strtoull(p, NULL, 16);
        while (*p && *p != ',') p++;
        if (*p == ',') p++;
    }
    struct { uintptr_t best; const MethodInfo *m; Il2CppClass *k; const Il2CppImage *im; } hit[MAXT];
    memset(hit, 0, sizeof hit);
    size_t na = 0;
    const Il2CppAssembly **as = il.domain_get_assemblies(il.domain_get(), &na);
    unsigned long long nmeth = 0;
    for (size_t a = 0; a < na; a++) {
        const Il2CppImage *im = il.assembly_get_image(as[a]);
        if (!im) continue;
        size_t nc = class_count(im);
        for (size_t c = 0; c < nc; c++) {
            Il2CppClass *k = get_class(im, c);
            if (!k) continue;
            void *iter = NULL;
            const MethodInfo *m;
            while ((m = get_methods(k, &iter)) != NULL) {
                nmeth++;
                uintptr_t p = *(uintptr_t *)m;   // MethodInfo.methodPointer
                if (!p) continue;
                for (int t = 0; t < nt; t++)
                    if (p <= tgt[t] && p > hit[t].best) {
                        hit[t].best = p; hit[t].m = m; hit[t].k = k; hit[t].im = im;
                    }
            }
        }
    }
    fprintf(stderr, "  [mprobe] resolve: scanned %llu methods in %zu assemblies\n",
            nmeth, na);
    for (int t = 0; t < nt; t++) {
        if (!hit[t].m) { fprintf(stderr, "  [mprobe] resolve %#llx: no method at or below\n",
                                 (unsigned long long)(tgt[t] - base)); continue; }
        fprintf(stderr, "  [mprobe] resolve libil2cpp+%#llx -> %s::%s (+%#llx, image %s)\n",
                (unsigned long long)(tgt[t] - base),
                il.class_get_name(hit[t].k), m_name(hit[t].m),
                (unsigned long long)(tgt[t] - hit[t].best),
                i_name && hit[t].im ? i_name(hit[t].im) : "?");
    }
}

// ---- AC Nexus VR: the frame length the guest spins itself out to -------------
//
// Not a probe: the one place the runtime writes a managed value, kept here
// because the il2cpp bindings are. AC Nexus runs with Application SpaceWarp and
// paces ITSELF for it: NexusUtils.PhaseSyncHack.SpinWaitAtEndOfNexusFrame spins
// every frame out to _nexusFrameTicksSpaceWarp, which its Awake sets from a
// per-headset constant — 85% of two display periods, 21.25 ms for a Quest 2 at
// 80 Hz (Q2_TARGET) and 18.89 ms for a Quest 3 at 90 Hz (Q3_TARGET). On a Quest
// the compositor then holds the app to half the display rate and synthesises
// the frames between. Nothing synthesises frames here, so that spin is half the
// frame rate given away for nothing, and at the Quest 2 length it is not even a
// whole number of display frames: 46.7 fps against a 100 Hz display, six frames
// shown for two periods and the seventh for three.
//
// So the spin is taken out (0 ticks, the value the game itself uses outside
// SpaceWarp — _nexusFrameTicksNormal is 0) and the game runs as fast as it
// can: 100 fps in its menus and 70-98 in a level on device, where the spin had
// held both at 46.7. Only the value its Awake wrote for a Quest 2 is replaced.
// KL_NEXUS_FRAME_BUDGET=0 leaves it alone; KL_NEXUS_FRAME_BUDGET_MS=<ms> spins
// to that length instead (17.0 is the game's own rule at 100 Hz, and with
// KL_GUEST_FRESH_POSE gives exactly half the display rate).
void kl_mprobe_nexus_frame_budget(unsigned frame) {
    static int on = -1;
    static double ms;
    if (on < 0) {
        extern const char *kl_driver_target_name(void);
        const char *t = kl_driver_target_name();
        on = kl_env_on("KL_NEXUS_FRAME_BUDGET", t && strcmp(t, "x5812519008825194") == 0);
        const char *e = kl_env_str("KL_NEXUS_FRAME_BUDGET_MS", NULL);
        ms = e ? strtod(e, NULL) : 0.0;
        if (!(ms >= 0.0 && ms < 21.25)) ms = 0.0;
    }
    if (!on || frame < 300 || frame % 300) return;
    if (!mprobe_init()) return;
    static const MethodInfo *m_fo; static Il2CppObject *type; static size_t off; static int r;
    if (!r) {
        r = 1;
        kl_image *img = kl_find_image("libil2cpp.so");
        Il2CppClass *k = find_class("NexusUtils", "PhaseSyncHack");
        typedef void *(*gfn_fn)(Il2CppClass *, const char *);
        typedef size_t (*f_off_fn)(void *);
        gfn_fn gfn = img ? (gfn_fn)kl_sym(img, "il2cpp_class_get_field_from_name") : NULL;
        f_off_fn fo = img ? (f_off_fn)kl_sym(img, "il2cpp_field_get_offset") : NULL;
        void *f = k && gfn ? gfn(k, "_nexusFrameTicksSpaceWarp") : NULL;
        if (f && fo) off = fo(f);
        if (k) type = il.type_get_object(il.class_get_type(k));
        m_fo = find_method("UnityEngine", "Object", "FindObjectsOfType", 1);
        if (!off || !type || !m_fo) {
            fprintf(stderr, "  [nexus] frame length: PhaseSyncHack not found as expected — left alone\n");
            on = 0;
            return;
        }
    }
    int64_t want = (int64_t)(ms * 1e4);                       // 100 ns ticks
    void *ta[1] = { type };
    Il2CppObject *arr = invoke(m_fo, ta, "FindObjectsOfType(PhaseSyncHack)");
    unsigned n = arr ? il.array_length(arr) : 0;
    for (unsigned i = 0; i < n; i++) {
        Il2CppObject *o = ((Il2CppObject **)((uint8_t *)arr + ARR_DATA))[i];
        if (!o) continue;
        int64_t *p = (int64_t *)((uint8_t *)o + off);
        if (*p == 212500) {                                   // Q2_TARGET, as Awake wrote it
            fprintf(stderr, "  [nexus] frame length: the game's SpaceWarp spin of %.2f ms "
                            "(Quest 2 at 80 Hz) -> %.2f ms\n", (double)*p / 1e4, ms);
            *p = want;
        }
    }
}

void kl_mprobe_tick(unsigned frame) {
    // Independent of KL_PROBE_INPUT and of KL_PROBE_FROM: this one has to land
    // BEFORE the throw it exists to describe, and the throw here is on the
    // first frame. It runs once, on the first tick that finds IL2CPP up.
    static int st_done;
    if (!st_done && kl_env_str("KL_PROBE_STACKTRACE", NULL) && mprobe_init()) {
        st_done = 1;
        probe_stack_traces();
    }
    // pc->method naming, once, late enough that the game's assemblies are all
    // loaded (frame 600 ~= ten seconds in).
    static int rs_done;
    if (!rs_done && frame >= 600 && kl_env_str("KL_PROBE_RESOLVE", NULL) && mprobe_init()) {
        rs_done = 1;
        mprobe_resolve_offsets();
    }
    // Also independent, and for the same reason: the disagreement it looks for
    // is settled long before KL_PROBE_FROM's default, and reading XRSettings
    // runs no cctor the guest has not already run.
    static unsigned xr_from, xr_every;
    if (kl_env_str("KL_PROBE_XR", NULL)) {
        if (!xr_every) {
            xr_from  = kl_env_uint("KL_PROBE_XR_FROM", 60u);
            xr_every = kl_env_uint("KL_PROBE_XR_EVERY", 300u);
            if (!xr_every) xr_every = 300;
        }
        if (frame >= xr_from && frame % xr_every == 0 && mprobe_init())
            probe_xr_display(frame);
    }

    static int on = -1;
    if (on < 0) on = kl_env_on("KL_PROBE_INPUT", 0);
    static unsigned every, from;
    if (!every) {
        every = kl_env_uint("KL_PROBE_EVERY", 120);
        if (!every) every = 120;
        // Probing is not free of side effects: the first call into a managed
        // class runs its cctor, and doing that to OVRInput/OVRPlugin before the
        // guest has loaded the plugin drags the runtime down paths it would not
        // take on its own (one such run aborted on an ovrp entry point the game
        // reaches only from there). Wait for the game to be up.
        from = kl_env_uint("KL_PROBE_FROM", 1200u);
    }
    if (frame < from || frame % every) return;
    if (!mprobe_init()) { on = 0; return; }

    static int dumped_enums;
    if (!dumped_enums) { dumped_enums = 1; probe_dump_enums(); probe_dump_methods(); }
    probe_xform_path(frame);
    probe_fields(frame);

    // Input.GetJoystickNames and InputTracking.GetLocalPosition/Rotation are
    // NOT here: IL2CPP's managed stripping removed them, which is itself the
    // measurement — this title reaches poses through OVRInput, below.
    static const MethodInfo *m_axis;
    static const MethodInfo *m_cpos, *m_crot, *m_conn, *m_pvalid, *m_ptracked;
    static Il2CppObject *axis_str[N_AXES];
    static int resolved;
    if (!resolved) {
        resolved = 1;
        m_axis  = find_method("UnityEngine", "Input", "GetAxis", 1);
        // The game's own pose seam. VRController::Update asks
        // IVRPlatformHelper::GetNodePose, which lands in OVRInput, which asks
        // OVRNodeStateProperties -> InputTracking::GetNodeStates -> libunity's
        // node table -> our ovrp node poses. Static, so callable from here.
        m_cpos     = find_method("", "OVRInput", "GetLocalControllerPosition", 1);
        m_crot     = find_method("", "OVRInput", "GetLocalControllerRotation", 1);
        m_conn     = find_method("", "OVRInput", "GetConnectedControllers", 0);
        m_pvalid   = find_method("", "OVRInput", "GetControllerPositionValid", 1);
        m_ptracked = find_method("", "OVRInput", "GetControllerPositionTracked", 1);
        for (unsigned i = 0; i < N_AXES; i++) axis_str[i] = il.string_new(AXES[i]);
    }

    // Which VR device does Unity think is loaded? This title ships four
    // IVRPlatformHelper implementations (Oculus, OpenVR, PSVR and
    // Deviceless), and DevicelessVRHelper::GetNodePose reports no pose BY
    // DESIGN — a game running on that helper has a working menu, working
    // Input.GetAxis and no controllers at all, which is exactly the symptom.
    // The choice keys on this surface, and OculusVRHelper also picks its
    // controller-transform offset from the device model.
    static const MethodInfo *m_devname, *m_xrenabled, *m_present, *m_model;
    static int resolved_xr;
    if (!resolved_xr) {
        resolved_xr = 1;
        m_devname   = find_method("UnityEngine.XR", "XRSettings", "get_loadedDeviceName", 0);
        m_xrenabled = find_method("UnityEngine.XR", "XRSettings", "get_enabled", 0);
        m_present   = find_method("UnityEngine.XR", "XRDevice", "get_isPresent", 0);
        m_model     = find_method("UnityEngine.XR", "XRDevice", "get_model", 0);
    }
    // Focus, as MANAGED OVRPlugin computes it. The game acts on these: it has
    // inputFocusWasCaptured/Released events and hides its menu controllers
    // while focus is away. Every one of these getters is a candidate for the
    // ovrpResult-vs-ovrpBool trap that made node validity read false.
    static const MethodInfo *m_infocus, *m_vrfocus, *m_userp;
    static int resolved_focus;
    if (!resolved_focus) {
        resolved_focus = 1;
        m_infocus = find_method("", "OVRPlugin", "get_hasInputFocus", 0);
        m_vrfocus = find_method("", "OVRPlugin", "get_hasVrFocus", 0);
        m_userp   = find_method("", "OVRPlugin", "get_userPresent", 0);
    }
    {
        Il2CppObject *a = invoke(m_infocus, NULL, "OVRPlugin.hasInputFocus");
        Il2CppObject *b = invoke(m_vrfocus, NULL, "OVRPlugin.hasVrFocus");
        Il2CppObject *c2 = invoke(m_userp, NULL, "OVRPlugin.userPresent");
        fprintf(stderr, "  [mprobe f%u] focus: input=%s vr=%s userPresent=%s\n", frame,
                a ? (*(uint8_t *)il.object_unbox(a) ? "1" : "0") : "?",
                b ? (*(uint8_t *)il.object_unbox(b) ? "1" : "0") : "?",
                c2 ? (*(uint8_t *)il.object_unbox(c2) ? "1" : "0") : "?");
    }
    {
        char dn[128] = "?", md[128] = "?";
        Il2CppObject *d = invoke(m_devname, NULL, "XRSettings.loadedDeviceName");
        Il2CppObject *m = invoke(m_model, NULL, "XRDevice.model");
        if (d) str_ascii(d, dn, sizeof dn);
        if (m) str_ascii(m, md, sizeof md);
        Il2CppObject *en = invoke(m_xrenabled, NULL, "XRSettings.enabled");
        Il2CppObject *pr = invoke(m_present, NULL, "XRDevice.isPresent");
        fprintf(stderr, "  [mprobe f%u] xr: device=\"%s\" model=\"%s\" enabled=%s present=%s\n",
                frame, dn, md,
                en ? (*(uint8_t *)il.object_unbox(en) ? "1" : "0") : "?",
                pr ? (*(uint8_t *)il.object_unbox(pr) ? "1" : "0") : "?");
    }

    // The game's own controller objects, read straight out of the live scene.
    // FindObjectsOfType returns only components on ACTIVE objects while
    // Resources.FindObjectsOfTypeAll includes inactive ones, so the pair
    // separates "the controllers were never built" from "they exist and
    // something disabled them" — which is what "no saber hilts render" is
    // asking. VRController::get_active is the game's own verdict on whether
    // its node has a pose.
    // KL_PROBE_TYPES: comma-separated managed types to census, each as
    // Namespace.Type (bare name for the global namespace). The default set is
    // the menu pointer chain.
    static const MethodInfo *m_find, *m_findall, *m_vactive, *m_vnode, *m_vpos;
    static Il2CppObject *vrc_type;
    static Il2CppObject *types[12];
    static char          tnames[12][64];
    static unsigned      n_types;
    static int resolved_scene;
    if (!resolved_scene) {
        resolved_scene = 1;
        m_find    = find_method("UnityEngine", "Object", "FindObjectsOfType", 1);
        m_findall = find_method("UnityEngine", "Resources", "FindObjectsOfTypeAll", 1);
        m_vactive = find_method("", "VRController", "get_active", 0);
        m_vnode   = find_method("", "VRController", "get_node", 0);
        m_vpos    = find_method("", "VRController", "get_position", 0);
        Il2CppClass *k = find_class("", "VRController");
        if (k) vrc_type = il.type_get_object(il.class_get_type(k));

        const char *spec = kl_env_str("KL_PROBE_TYPES", "VRUIControls.VRPointer,VRUIControls.VRInputModule,"
                                                        "VRUIControls.VRLaserPointer,VRUIControls.VRGraphicRaycaster");
        char buf[512];
        snprintf(buf, sizeof buf, "%s", spec);
        for (char *tok = strtok(buf, ","); tok && n_types < 12;
             tok = strtok(NULL, ",")) {
            char ns[64] = "", nm[64];
            const char *dot = strrchr(tok, '.');
            if (dot) {
                size_t l = (size_t)(dot - tok);
                if (l >= sizeof ns) l = sizeof ns - 1;
                memcpy(ns, tok, l); ns[l] = 0;
                snprintf(nm, sizeof nm, "%s", dot + 1);
            } else {
                snprintf(nm, sizeof nm, "%s", tok);
            }
            Il2CppClass *kk = find_class(ns, nm);
            if (!kk) continue;
            snprintf(tnames[n_types], sizeof tnames[0], "%s", nm);
            types[n_types++] = il.type_get_object(il.class_get_type(kk));
        }
    }
    if (n_types) {
        fprintf(stderr, "  [mprobe f%u] scene:", frame);
        for (unsigned i = 0; i < n_types; i++) {
            void *ta[1] = { types[i] };
            Il2CppObject *a = invoke(m_find, ta, "FindObjectsOfType");
            Il2CppObject *b = invoke(m_findall, ta, "FindObjectsOfTypeAll");
            fprintf(stderr, " %s=%d/%d", tnames[i],
                    a ? (int)il.array_length(a) : -1,
                    b ? (int)il.array_length(b) : -1);
        }
        fprintf(stderr, "  (active/all)\n");
    }
    // Walk each VRController up its parent chain, naming every object and
    // whether it is switched off in its own right (activeSelf). An object can
    // be inactive because a PARENT is inactive, and only the ancestor that is
    // actually off is the thing to explain — the rest are consequences.
    static const MethodInfo *m_go, *m_tf, *m_parent, *m_aself, *m_ahier, *m_ptr_ctrl;
    static const MethodInfo *m_objname;
    static int resolved_walk;
    if (!resolved_walk) {
        resolved_walk = 1;
        m_objname = find_method("UnityEngine", "Object", "get_name", 0);
        m_go     = find_method("UnityEngine", "Component", "get_gameObject", 0);
        m_tf     = find_method("UnityEngine", "Component", "get_transform", 0);
        m_parent = find_method("UnityEngine", "Transform", "get_parent", 0);
        m_aself  = find_method("UnityEngine", "GameObject", "get_activeSelf", 0);
        m_ahier  = find_method("UnityEngine", "GameObject", "get_activeInHierarchy", 0);
        m_ptr_ctrl = find_method("VRUIControls", "VRPointer", "get_vrController", 0);
    }
    // Which controller does the live pointer actually want? A null here means
    // the pointer was never wired to one, which is a different bug from a
    // controller that exists and is switched off.
    if (vrc_type && m_ptr_ctrl && n_types) {
        void *ta[1] = { types[0] };            // VRPointer is first by default
        Il2CppObject *ps = invoke(m_find, ta, "FindObjectsOfType(VRPointer)");
        if (ps && il.array_length(ps)) {
            Il2CppObject *p0 = ((Il2CppObject **)((uint8_t *)ps + ARR_DATA))[0];
            Il2CppObject *vc = invoke_on(p0, m_ptr_ctrl, NULL, "VRPointer.vrController");
            fprintf(stderr, "  [mprobe f%u] VRPointer.vrController=%s\n", frame,
                    vc ? "set" : "<null>");
        }
    }
    if (vrc_type) {
        void *targs[1] = { vrc_type };
        Il2CppObject *act = invoke(m_find, targs, "Object.FindObjectsOfType");
        Il2CppObject *all = invoke(m_findall, targs, "Resources.FindObjectsOfTypeAll");
        fprintf(stderr, "  [mprobe f%u] VRController: active=%d all=%d", frame,
                act ? (int)il.array_length(act) : -1,
                all ? (int)il.array_length(all) : -1);
        // Report each one the game built, however it was found.
        Il2CppObject *list = all ? all : act;
        uint32_t n = list ? il.array_length(list) : 0;
        for (uint32_t i = 0; i < n && i < 4; i++) {
            Il2CppObject *vc = ((Il2CppObject **)((uint8_t *)list + ARR_DATA))[i];
            if (!vc) continue;
            Il2CppObject *a = invoke_on(vc, m_vactive, NULL, "VRController.active");
            Il2CppObject *nd = invoke_on(vc, m_vnode, NULL, "VRController.node");
            Il2CppObject *p = invoke_on(vc, m_vpos, NULL, "VRController.position");
            fprintf(stderr, " | node=%s active=%s",
                    nd ? (*(int32_t *)il.object_unbox(nd) == 4 ? "L" :
                          *(int32_t *)il.object_unbox(nd) == 5 ? "R" : "?") : "?",
                    a ? (*(uint8_t *)il.object_unbox(a) ? "YES" : "no") : "?");
            if (p) {
                const float *v = (const float *)il.object_unbox(p);
                fprintf(stderr, " pos=(%.2f,%.2f,%.2f)", v[0], v[1], v[2]);
            }
            fprintf(stderr, "\n      chain:");
            // Up the parents, naming each and flagging the ones switched off.
            Il2CppObject *tf = invoke_on(vc, m_tf, NULL, "Component.transform");
            for (unsigned d = 0; tf && d < 12; d++) {
                Il2CppObject *go = invoke_on(tf, m_go, NULL, "Component.gameObject");
                if (!go) break;
                Il2CppObject *nm2 = invoke_on(go, m_objname, NULL, "Object.get_name");
                Il2CppObject *as = invoke_on(go, m_aself, NULL, "activeSelf");
                Il2CppObject *ah = invoke_on(go, m_ahier, NULL, "activeInHierarchy");
                char nb[96];
                str_ascii(nm2, nb, sizeof nb);
                int self = as ? *(uint8_t *)il.object_unbox(as) : -1;
                int hier = ah ? *(uint8_t *)il.object_unbox(ah) : -1;
                fprintf(stderr, " %s%s[self=%d,hier=%d]", d ? "< " : "", nb, self, hier);
                tf = invoke_on(tf, m_parent, NULL, "Transform.parent");
            }
            fprintf(stderr, "\n");
        }
        fprintf(stderr, "\n");
    }

    // The other end of the chain: does the pointer ray actually land on UI?
    // Everything above measures what we hand the game; this reads back what
    // the game's own event system concluded, which is the difference between
    // "the controllers are wrong" and "the controllers are fine and the ray is
    // aimed somewhere else".
    static const MethodInfo *m_es_cur, *m_over, *m_sel, *m_name;
    static int resolved_es;
    if (!resolved_es) {
        resolved_es = 1;
        m_es_cur = find_method("UnityEngine.EventSystems", "EventSystem", "get_current", 0);
        m_over   = find_method("UnityEngine.EventSystems", "EventSystem",
                               "IsPointerOverGameObject", 0);
        m_sel    = find_method("UnityEngine.EventSystems", "EventSystem",
                               "get_currentSelectedGameObject", 0);
        m_name   = find_method("UnityEngine", "Object", "get_name", 0);
    }

    // 1. Does any of the fill survive into Input.GetAxis? This was the one
    //    unproven link in the chain from our ovrp state to the game's click.
    //    Gated behind its OWN knob (default off) even under KL_PROBE_INPUT: on a
    //    title whose Input Manager has no axis of the queried name, il2cpp's
    //    Input.GetAxis walks off a buffer inside libunity and SIGSEGVs — an
    //    intermittent native fault the managed try/catch cannot stop, and it
    //    killed some Unity guests mid-run. The answer here is always
    //    "InvalidOperationException" anyway, so it is off unless asked for.
    if (kl_env_on("KL_PROBE_GETAXIS", 0)) {
        fprintf(stderr, "  [mprobe f%u] axes:", frame);
        for (unsigned i = 0; i < N_AXES; i++) {
            void *args[1] = { axis_str[i] };
            fprintf(stderr, " %s=%.3f", AXES[i], invoke_float(m_axis, args, "Input.GetAxis"));
        }
        fprintf(stderr, "\n");
    }

    // 2. And do the hand poses? The pointer ray is built from these, so a ray
    //    that never hits is either aimed wrong or cast from nowhere. Asked
    //    exactly the way VRController::Update asks it.
    Il2CppObject *c = invoke(m_conn, NULL, "OVRInput.GetConnectedControllers");
    fprintf(stderr, "  [mprobe f%u] OVRInput: connected=", frame);
    if (c) fprintf(stderr, "0x%x", *(uint32_t *)il.object_unbox(c));
    else   fprintf(stderr, "?");

    // OVRInput.Controller: LTouch = 0x01, RTouch = 0x02.
    static const struct { const char *name; int ctrl; } HANDS[] = {
        { "L", 0x01 }, { "R", 0x02 },
    };
    for (unsigned i = 0; i < 2; i++) {
        int ctrl = HANDS[i].ctrl;
        void *args[1] = { &ctrl };
        Il2CppObject *p  = invoke(m_cpos, args, "OVRInput.GetLocalControllerPosition");
        Il2CppObject *q  = invoke(m_crot, args, "OVRInput.GetLocalControllerRotation");
        Il2CppObject *pv = invoke(m_pvalid, args, "OVRInput.GetControllerPositionValid");
        Il2CppObject *pt = invoke(m_ptracked, args, "OVRInput.GetControllerPositionTracked");
        fprintf(stderr, " %s:", HANDS[i].name);
        if (pv) fprintf(stderr, "valid=%d", *(uint8_t *)il.object_unbox(pv));
        if (pt) fprintf(stderr, ",tracked=%d", *(uint8_t *)il.object_unbox(pt));
        if (p) {
            const float *v = (const float *)il.object_unbox(p);
            fprintf(stderr, ",pos=(%.2f,%.2f,%.2f)", v[0], v[1], v[2]);
        }
        if (q) {
            const float *r = (const float *)il.object_unbox(q);
            fprintf(stderr, ",rot=(%.2f,%.2f,%.2f,%.2f)", r[0], r[1], r[2], r[3]);
        }
    }
    fprintf(stderr, "\n");

    // 3. The verdict: is the pointer over UI, and what does the game consider
    //    selected? A hit here is the whole point of the controller work.
    Il2CppObject *es = invoke(m_es_cur, NULL, "EventSystem.get_current");
    fprintf(stderr, "  [mprobe f%u] eventsystem:", frame);
    if (!es) {
        fprintf(stderr, " none\n");
    } else {
        Il2CppObject *over = invoke_on(es, m_over, NULL, "IsPointerOverGameObject");
        fprintf(stderr, " overUI=%s",
                over ? (*(uint8_t *)il.object_unbox(over) ? "YES" : "no") : "?");
        Il2CppObject *sel = invoke_on(es, m_sel, NULL, "get_currentSelectedGameObject");
        if (!sel) {
            fprintf(stderr, " selected=<none>");
        } else {
            Il2CppObject *nm = invoke_on(sel, m_name, NULL, "Object.get_name");
            char buf[128];
            str_ascii(nm, buf, sizeof buf);
            fprintf(stderr, " selected=\"%s\"", buf);
        }
        fprintf(stderr, "\n");
    }
    fflush(stderr);
}
