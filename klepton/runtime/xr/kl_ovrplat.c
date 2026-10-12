// libovrplatformloader.so — see kl_ovrplat.h for why this is a replacement and
// where the DRM line is drawn.
//
// Adapted from avp-play (MIT, github.com/myMartek/avp-play) runtime/xr/kl_ovrplat.c:
// Walkabout's on-disk courses, batman / AC Nexus language packs, store-delivered
// add-on files, error completions (checkout, leaderboards, CancelAppDownload),
// the User model fields and GetLoggedInUser for their titles. One deliberate
// difference: a Walkabout purchase is reported only for a course whose real
// bundle is on disk AND that the store confirmed — never a confirmed SKU alone
// (see klplat_scan_courses).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <pthread.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>              // the cloud-save directory is created
#include "klepton.h"
#include "kl_jni.h"
#include "guest/kl_driver.h"   // target name, for the per-target KL_PLAT_USER default
#include "kl_env.h"
#include "kl_ovrplat.h"

#define KL_OVRPLAT_MAX 512
static struct { const char *name; unsigned calls; int drm; } g_plat[KL_OVRPLAT_MAX];
static unsigned g_nplat;
static unsigned g_drm_calls;

static int plat_slot(const char *name) {
    for (unsigned i = 0; i < g_nplat; i++)
        if (strcmp(g_plat[i].name, name) == 0) return (int)i;
    if (g_nplat >= KL_OVRPLAT_MAX) return -1;
    g_plat[g_nplat].name  = strdup(name);
    g_plat[g_nplat].calls = 0;
    g_plat[g_nplat].drm   = 0;
    return (int)g_nplat++;
}

static void plat_hit(const char *name) {
    int s = plat_slot(name);
    if (s >= 0) g_plat[s].calls++;
}

// ---------------------------------------------------------------------------
// The DRM classifier
//
// Matched on substrings of the entry point name rather than an enumerated list,
// deliberately: the export surface is 1335 wide and a list would be the thing
// that goes stale. A new ovr_Entitlement_* or ovr_IAP_* added by a future SDK
// lands on the refusal by default, which is the direction an error should fall.
//
// What is covered and why:
//   Entitle*  — "is this user allowed to run this", the licence check. Note the
//               g_plat_absent carve-out below: the APP's own entitlement is
//               answered, everything else in the family still refuses.
//   IAP       — purchases and their ownership records.
//   AssetFile — download and unlock of purchasable DLC; the delivery half of the
//               same question. ovr_AssetFile_* is how paid content arrives.
//               Note the g_plat_absent carve-out above: the pure *enumeration*
//               call is answered with "nothing here", which grants no access.
//   Purchase  — belt and braces for the SDK's other spelling of IAP.
static const char *const g_drm_markers[] = {
    "Entitle", "Entitlement", "IAP", "Purchase", "AssetFile", "AssetDetails",
};

// The carve-outs: names in the ownership families that we ANSWER rather than
// refuse. There are exactly two, they earn it for two DIFFERENT reasons, and
// neither reason generalises to the rest of the family — which is why these are
// exact names, not substrings, and are checked BEFORE the markers below, so the
// marker list keeps its fail-closed default and anything new still lands on the
// refusal.
//
//   ovr_AssetFile_GetList — enumerates the DLC asset files present on this
//     device. For every title but Walkabout that list is empty. For Walkabout
//     it names a course only when that course's real track bundle is already
//     on disk (klplat_scan_courses): files the user copied off their own Quest,
//     never a stub, never a course that is not there. Download and Delete stay
//     refused — this list does not fetch anything.
//
//   ovr_Entitlement_GetIsViewerEntitled — the APPLICATION's own licence check,
//     and the one question in this family we can actually answer. Klepton runs
//     an APK the user unpacked from a device they own, i.e. from a copy of the
//     app they already bought; answering yes describes that, it does not
//     manufacture it. This is a deliberate move of the line and it is confined
//     to the app: DLC ownership stays refused because it is genuinely
//     unanswerable here — paid content is out-of-band asset data plus a licence
//     held by a platform that is absent from this host, so neither half is
//     present to check, and claiming it IS the circumvention. It is answered
//     for real (klplat_Entitlement_GetIsViewerEntitled) rather than through the
//     request path below, because it returns its answer directly.
//
// The remaining entries are answered through klplat_init_fails, i.e. request id
// 0: the platform request APIs are asynchronous and ovr_PopMessage never
// produces a message, so a plausible id would leave the caller polling forever
// for a completion that cannot come. 0 puts it on the error path it already has.
static const char *const g_plat_absent[] = {
    "ovr_AssetFile_GetList",
    "ovr_Entitlement_GetIsViewerEntitled",
    // The GetList completion's readers. They match the "AssetDetails"/"AssetFile"
    // DRM markers by substring, but they only READ the empty list GetList
    // returned - no id, no size, no delivery - so they carve out for the same
    // reason GetList does: strictly more restrictive than the truth. The
    // DELIVERY calls (ovr_AssetFile_Download*, DownloadById) are not here and
    // stay refused.
    "ovr_Message_GetAssetFileDeliveryList",
    "ovr_AssetFileDeliveryList_GetSize",
    "ovr_Message_GetAssetDetailsArray",
    "ovr_AssetDetailsArray_GetSize",
};

static int plat_is_absent_ok(const char *name) {
    for (size_t i = 0; i < sizeof g_plat_absent / sizeof g_plat_absent[0]; i++)
        if (strcmp(name, g_plat_absent[i]) == 0) return 1;
    return 0;
}

// The IAP CATALOG calls — enumeration of what is for sale, not what is owned.
// ovr_IAP_GetProductsBySKU returns a ProductArray of {sku, name, description,
// formatted price}: the store's shop window, read to DECIDE whether to offer a
// purchase. It reports no ownership and delivers no content, and on a host with
// no store the truthful answer is "the request could not be made" (request 0),
// the same answer ovr_User_GetLoggedInUser gives. This is the IAP twin of the
// ovr_AssetFile_GetList carve-out: a pure enumeration is strictly MORE
// restrictive than the truth. Ownership is a different call
// (ovr_IAP_GetViewerPurchases): request 0 for every title but Walkabout, and
// for Walkabout only the store ids of courses whose track files are on disk.
// ovr_IAP_ConsumePurchase, checkout and every delivery call keep matching the
// "IAP"/"Purchase" markers below, because this list is exact names checked
// first, not a substring. GetNextProductArrayPage walks the same catalog
// array, so it carves out for the same reason.
static int plat_is_iap_catalog(const char *name) {
    return strcmp(name, "ovr_IAP_GetProductsBySKU") == 0 ||
           strcmp(name, "ovr_IAP_GetNextProductArrayPage") == 0;
}

// The read side of the OWNED half: "which IAPs has this viewer already bought?"
// For every title but Walkabout the answer is still "the request could not be
// made" (request id 0): no purchase message, so the guest learns of nothing it
// did not already have. Walkabout is the exception, and only there:
// klplat_IAP_GetViewerPurchases returns the purchases the store confirmed for
// this viewer, read from klepton-entitlements.txt (klplat_load_entitlements).
// A bundle on disk is not a purchase, and with no such file the list is empty.
// The WRITE side — ovr_IAP_ConsumePurchase and the AssetFile delivery calls —
// stays in plat_is_drm and keeps aborting. Checkout is an error (plat_is_checkout).
static int plat_is_iap_owned_query(const char *name) {
    return strcmp(name, "ovr_IAP_GetViewerPurchases") == 0 ||
           strcmp(name, "ovr_IAP_GetViewerPurchasesDurableCache") == 0 ||
           strcmp(name, "ovr_IAP_GetViewerPurchasesDeltaAsync") == 0;
}

// Readers of a course record we actually produced: asset-file status and the
// AssetDetails / Purchase fields of an on-disk Walkabout course. Exact names,
// checked before the substring markers, so Download, Delete and ConsumePurchase
// still match "AssetFile" / "IAP" / "Purchase" and still abort. Answering one
// of these with no course files present yields an empty list or "not installed",
// which grants nothing.
static int plat_is_course_record(const char *name) {
    static const char *const n[] = {
        "ovr_AssetFile_StatusById",
        "ovr_AssetFile_StatusByName",
        "ovr_AssetFile_StatusByName_Native",
        "ovr_AssetDetails_GetAssetId",
        "ovr_AssetDetails_GetAssetType",
        "ovr_AssetDetails_GetAssetType_Native",
        "ovr_AssetDetails_GetDownloadStatus",
        "ovr_AssetDetails_GetDownloadStatus_Native",
        "ovr_AssetDetails_GetFilepath",
        "ovr_AssetDetails_GetFilepath_Native",
        "ovr_AssetDetails_GetIapStatus",
        "ovr_AssetDetails_GetIapStatus_Native",
        "ovr_AssetDetails_GetLanguage",
        "ovr_AssetDetails_GetMetadata",
        "ovr_AssetDetailsArray_GetElement",
        "ovr_Message_GetAssetDetails",
        "ovr_Message_GetPurchaseArray",
        "ovr_PurchaseArray_GetSize",
        "ovr_PurchaseArray_GetElement",
        "ovr_PurchaseArray_GetNextUrl",
        "ovr_Purchase_GetDeveloperPayload",
        "ovr_Purchase_GetExpirationTime",
        "ovr_Purchase_GetGrantTime",
        "ovr_Purchase_GetPurchaseID",
        "ovr_Purchase_GetPurchaseStrID",
        "ovr_Purchase_GetPurchaseStrID_Native",
        "ovr_Purchase_GetReportingId",
        "ovr_Purchase_GetReportingId_Native",
        "ovr_Purchase_GetSKU",
        "ovr_Purchase_GetSKU_Native",
    };
    for (size_t i = 0; i < sizeof n / sizeof n[0]; i++)
        if (strcmp(name, n[i]) == 0) return 1;
    return 0;
}

// ...and the one WRITE-side call that is answered, with a failure.
// ovr_IAP_LaunchCheckoutFlow is the guest opening the store for a SKU. There is
// no store here, and the truthful completion of that request is an ERROR
// message — "the purchase did not happen" — which grants nothing and delivers
// nothing. Aborting instead cost the whole session for pressing a button in the
// song list. Only this entry point: ConsumePurchase, the Purchase accessors and
// every AssetFile delivery call still match the markers and still refuse, and a
// failed checkout never reaches them (the SDK reads a Purchase only from a
// message that is not an error).
static int plat_is_checkout(const char *name) {
    return strcmp(name, "ovr_IAP_LaunchCheckoutFlow") == 0;
}

// A base game's own LANGUAGE PACKS, for the one target measured to need them.
//
// batman (Batman: Arkham Shadow) ships its voice-over as one OBB per locale and
// a manifest beside them (localized-asset-manifest.txt: "<locale>:<file>:<size>").
// Every owner gets every locale; none is sold. At startup it asks
// ovr_AssetFile_StatusByName whether the pack for the current language is on the
// device, and the refusal below killed it right after its content had loaded.
//
// What is answered is a FACT ABOUT THE DISK and nothing else: a name that is in
// the game's own manifest, present with the size the manifest gives, is
// "installed" at its real path; a manifest name that is not there is
// "available"; any other name still refuses. No download, delete, purchase or
// list call moves — a pack that is not on disk cannot be fetched from here, and
// nothing this answers was ever for sale. Target-scoped on purpose: the same
// call on another title can be asking about paid content.
//
// The game offers to download a pack it was told is "available", and its yes
// is ovr_AssetFile_DownloadById — which, refused, aborted the whole session on
// the headset (2026-10-12, Spanish system: es-ES). The hub now fetches the
// headset language's pack (and en-US) from Meta with the player's own account,
// so the question normally never comes up. When it does, the answer is again
// the disk: a manifest pack that is there completes at once (the download
// result, then the one progress notification a finished download ends with,
// bytes = its real size); a manifest pack that is not there gets an ERROR
// completion — nothing was fetched, and the game's own failure path says so —
// and an id or name outside the manifest still refuses.
//
// AC Nexus VR (x5812519008825194) is the second, and asks differently: its
// voice-over is one `<tag>.lang` Wwise package per language beside the rest of
// its data in the OBB directory, part of the base game like batman's, and it
// learns which of them are there from ovr_AssetFile_GetList. With the empty
// list every title gets, its audio-language menu greyed out every language
// but the one it had already loaded by path. For it the list names the .lang
// files that are really in that directory (klplat_scan_obb_langpacks) — again
// a fact about the disk; delivery, delete and purchase calls are untouched.
// KL_PLAT_LANGPACK_LIST=0 restores the empty list.
static int plat_is_obb_langpack_target(void) {
    static int v = -1;
    if (v < 0) {
        const char *t = kl_driver_target_name();
        v = kl_env_on("KL_PLAT_LANGPACK_LIST", t && strcmp(t, "x5812519008825194") == 0);
    }
    return v;
}
static int plat_is_langpack_target(void) {
    const char *t = kl_driver_target_name();
    return (t && strcmp(t, "batman") == 0) || plat_is_obb_langpack_target();
}
static int plat_is_langpack_status(const char *name) {
    static const char *const ok[] = {
        "ovr_AssetFile_StatusByName",
        "ovr_Message_GetAssetDetails",
        "ovr_AssetDetails_GetAssetId",       "ovr_AssetDetails_GetAssetType",
        "ovr_AssetDetails_GetDownloadStatus", "ovr_AssetDetails_GetFilepath",
        "ovr_AssetDetails_GetIapStatus",     "ovr_AssetDetails_GetLanguage",
        "ovr_AssetDetails_GetMetadata",
        // A download of a pack, answered from the disk (klplat_langpack_Download):
        // a pack already there completes, any other manifest pack gets an error
        // completion, and a name/id outside the manifest still refuses.
        "ovr_AssetFile_DownloadById",   "ovr_AssetFile_DownloadByName",
        "ovr_AssetFile_DownloadByName_Native",
        "ovr_Message_GetAssetFileDownloadResult",
        "ovr_AssetFileDownloadResult_GetAssetId", "ovr_AssetFileDownloadResult_GetFilepath",
        "ovr_AssetFileDownloadResult_GetFilepath_Native",
        "ovr_Message_GetAssetFileDownloadUpdate",
        "ovr_AssetFileDownloadUpdate_GetAssetFileId", "ovr_AssetFileDownloadUpdate_GetAssetId",
        "ovr_AssetFileDownloadUpdate_GetBytesTotal", "ovr_AssetFileDownloadUpdate_GetBytesTotalLong",
        "ovr_AssetFileDownloadUpdate_GetBytesTransferred",
        "ovr_AssetFileDownloadUpdate_GetBytesTransferredLong",
        "ovr_AssetFileDownloadUpdate_GetCompleted",
    };
    if (!plat_is_langpack_target()) return 0;
    for (size_t i = 0; i < sizeof ok / sizeof ok[0]; i++)
        if (strcmp(name, ok[i]) == 0) return 1;
    return 0;
}

static int plat_is_drm(const char *name) {
    if (plat_is_absent_ok(name)) return 0;
    if (plat_is_iap_catalog(name)) return 0;
    if (plat_is_iap_owned_query(name)) return 0;
    if (plat_is_checkout(name)) return 0;
    if (plat_is_course_record(name)) return 0;
    if (plat_is_langpack_status(name)) return 0;
    for (size_t i = 0; i < sizeof g_drm_markers / sizeof g_drm_markers[0]; i++)
        if (strstr(name, g_drm_markers[i])) return 1;
    return 0;
}

// Ownership and licence queries — everything the carve-out above does NOT name,
// which after it is the CONTENT half: IAP, purchase records, asset details, and
// the delivery calls. This aborts unconditionally — KL_PERMISSIVE is a scouting
// knob for things we intend to implement, and this is not one of them. Answering
// 0 would be worse than useless here: for a call shaped like ovr_IAP_GetProducts
// or ovr_AssetFile_DownloadById a fabricated answer is the circumvention itself,
// and a permissive run would produce it silently.
static uint64_t klplat_drm(const char *name) {
    int s = plat_slot(name);
    if (s >= 0) { g_plat[s].calls++; g_plat[s].drm = 1; }
    g_drm_calls++;
    fprintf(stderr,
            "\n[klepton] REFUSED: the guest called '%s'.\n"
            "  This is an entitlement / purchase-ownership query. Klepton does not\n"
            "  implement these and does not answer them permissively — inventing a\n"
            "  result is DRM circumvention, which is out of scope.\n"
            "  The Oculus platform is genuinely absent on this host; that is the\n"
            "  true state of affairs, and it is the app's decision what to do with\n"
            "  it. If this call is unavoidable, the target is wrong: pick an APK\n"
            "  without entitlement checks (Steam Link).\n", name);
    kl_ovrplat_report(stderr);
    kl_fatal_prepare();
    abort();
}

// Everything else: named, so the guest says which of the 1335 it wants.
static uint64_t klplat_called(const char *name) {
    plat_hit(name);
    if (kl_permissive()) {
        int s = plat_slot(name);
        if (s >= 0 && g_plat[s].calls == 1)
            fprintf(stderr, "  [plat] call (permissive, returning 0): %s\n", name);
        return 0;
    }
    fprintf(stderr, "\n[klepton] fatal: guest called unimplemented Oculus Platform "
                    "entry point '%s'\n", name);
    kl_ovrplat_report(stderr);
    kl_fatal_prepare();
    abort();
}

// ---------------------------------------------------------------------------
// The completion queue — an asynchronous request has to ARRIVE somewhere
//
// An async request gets a real id and a message that arrives via
// ovr_Message_Get*. Answering `ovrRequest` 0 has the SAME "poll forever" tail
// as a fabricated id — the SDK builds its `Request` object either way and
// awaits it — so 0 buys silence, not an error path.
//
// Beat Saber 1.40 gates a screen on that silence: HealthWarningFlowCoordinator
// hands the epilepsy screen's Continue to WaitForUserAgeCategory, a coroutine
// waiting on a category OculusInit.CheckUserAgeCategoryAsync never sets because
// InitializeOculusAsync is still awaiting platform init. The button does
// nothing, silently, with the frame loop running normally.
//
// What is asserted, and by whose decision. Answering the age category at all
// claims an initialized platform, which is a real change from "genuinely
// absent" — an absent platform cannot answer a demographic question. The user
// asked for it and declared themselves over 18 (2026-08-12), which is the only
// place that answer can legitimately come from here: a self-declaration by the
// person running their own copy, not a discovered fact. THE DRM LINE DOES NOT
// MOVE WITH IT — IAP, purchase records, asset details and every delivery call
// still abort unconditionally, and check_drm_guard still asserts both
// directions. What changes is that the application's own entitlement, already
// answered yes, is answered through the channel the guest actually reads.
//
// The three completions are all this queues, each issued only in response to
// the guest's own request:
//
//   ovr_UnityInitWrapperAsynchronous  -> Platform_InitializeAndroidAsynchronous,
//                                        result Success
//   ovr_Entitlement_GetIsViewerEntitled -> Entitlement_GetIsViewerEntitled, no
//                                        payload; success IS the answer
//   ovr_UserAgeCategory_Get           -> UserAgeCategory_Get, category Ad(ult)
//
// The type numbers are the guest's own, read out of the running IL2CPP runtime
// with KL_PROBE_ENUM (kl_mprobe.c) rather than from an SDK header. Necessary
// rather than tidy: Message.ParseMessageHandle switches on the type and its
// default arm logs "Unrecognized message type" and produces NO message, so a
// guessed number is indistinguishable from the silence above.
#define KLPLAT_MSG_PLATFORM_INIT   450037684u   // Message.MessageType
#define KLPLAT_MSG_ENTITLEMENT     409688241u   //   .Platform_InitializeAndroidAsynchronous
#define KLPLAT_MSG_AGE_CATEGORY    567009472u   //   .Entitlement_GetIsViewerEntitled
#define KLPLAT_MSG_APP_VERSION    1751583246u   //   .UserAgeCategory_Get
                                                //   .Application_GetVersion
#define KLPLAT_MSG_CLOUD_DIR      1990471406u   //   .CloudStorage2_GetUserDirectoryPath
#define KLPLAT_MSG_ASSET_LIST     1258057588u   //   .AssetFile_GetList (KL_PROBE_ENUM, this APK)
#define KLPLAT_MSG_ACCESS_TOKEN     0x06A85ABEu  // .User_GetAccessToken (Message<string>)
#define KLPLAT_MSG_ACHIEVEMENT_DEFS 0x03D3458Du  // .Achievements_GetAllDefinitions (empty array)
#define KLPLAT_MSG_LOGGED_IN_USER  0x436F345Du  // .User_GetLoggedInUser (Message<User>)
#define KLPLAT_MSG_IAP_CHECKOUT    0x3F9B0D0Du  // .IAP_LaunchCheckoutFlow (KL_PROBE_ENUM, 1.28)
#define KLPLAT_MSG_APP_CANCEL_DL   0x7C2060DEu  // .Application_CancelAppDownload (Cave Crave's
                                                //   global-metadata, beside GetVersion's)
// Walkabout's own Message.MessageType values, read from its global-metadata
// default-value blob (the same encoding that reproduces the constants above).
// Queued only for that title — another game's enum is not these numbers.
#define KLPLAT_MSG_ASSET_STATUS_ID    1570069816u  // AssetFile_StatusById
#define KLPLAT_MSG_ASSET_STATUS_NAME  1104140880u  // AssetFile_StatusByName
// batman's own, from its global-metadata default-value blob (the same read finds
// the two above beside them): a pack download, and the notification it ends with.
#define KLPLAT_MSG_ASSET_DOWNLOAD_ID     0x2D008992u  // AssetFile_DownloadById
#define KLPLAT_MSG_ASSET_DOWNLOAD_NAME   0x6336CEFAu  // AssetFile_DownloadByName
#define KLPLAT_MSG_ASSET_DOWNLOAD_UPDATE 0x2FDD0CCDu  // Notification_AssetFile_DownloadUpdate
#define KLPLAT_MSG_IAP_PURCHASES       974095385u  // IAP_GetViewerPurchases
#define KLPLAT_MSG_IAP_PURCHASES_CACHE 1666817579u // IAP_GetViewerPurchasesDurableCache
#define KLPLAT_MSG_IAP_PRODUCTS       2124073717u  // IAP_GetProductsBySKU
// Read from Keep Talking and Nobody Explodes' global-metadata default-value blob
// the same way (the same read reproduces 0x186B58B1 and 0x436F345D above), and
// found again in Eye of the Temple's.
#define KLPLAT_MSG_LEADERBOARD_GET_ENTRIES 0x5DB3474Cu // Leaderboard_GetEntries
#define KLPLAT_MSG_LEADERBOARD_WRITE_ENTRY 0x117FC8FEu // Leaderboard_WriteEntry
#define KLPLAT_INIT_SUCCESS        0            // PlatformInitializeResult.Success
#define KLPLAT_AGE_ADULT           3            // AccountAgeCategory.Ad

// A ring, because the guest holds a message only until it has read it and calls
// ovr_FreeMessage; three per run is the whole traffic, so 16 slots cannot wrap
// under a live message. The mutex is not defensive — the requests are issued
// from managed code on the main thread and the pump runs there too, but nothing
// in the API promises that.
#define KLPLAT_MSGQ 16
// `str` is the STRING payload, for the messages whose managed wrapper is a
// `Message<string>` — it is read through ovr_Message_GetString rather than
// through the int payload above, and a message carries one or the other.
// `err` marks the one completion that is a FAILURE (a refused checkout): the
// SDK's Message constructor then reads ovr_Message_GetError and the three
// ovr_Error_* accessors, and does not touch the payload at all.
// `kind` says which array the payload count refers to. A message that is not a
// course list leaves it 0, and the array getters then answer empty — an
// achievement list must not grow a purchase.
enum {
    KLPLAT_KIND_NONE = 0,
    KLPLAT_KIND_ASSETS,
    KLPLAT_KIND_ASSET,
    KLPLAT_KIND_PURCHASES,
    KLPLAT_KIND_PRODUCTS,
};
typedef struct {
    uint32_t type; uint64_t request; int32_t payload; const char *str; int err;
    int kind;
    const void *obj;   // an AssetDetails, for the one message that has one
} klplat_msg;
static klplat_msg      g_msgq[KLPLAT_MSGQ];
static unsigned        g_msg_head, g_msg_tail;
static uint64_t        g_next_request = 1;
static int             g_platform_up;
static pthread_mutex_t g_msg_mu = PTHREAD_MUTEX_INITIALIZER;

// Issue a request and queue its completion. Returns the ovrRequest the guest
// will wait on — non-zero, and matched by the message, which together are the
// whole point.
static uint64_t klplat_request_str(const char *what, uint32_t type,
                                   int32_t payload, const char *str) {
    pthread_mutex_lock(&g_msg_mu);
    uint64_t id = g_next_request++;
    if (g_msg_tail - g_msg_head < KLPLAT_MSGQ) {
        klplat_msg *m = &g_msgq[g_msg_tail++ % KLPLAT_MSGQ];
        m->type = type; m->request = id; m->payload = payload; m->str = str;
        m->err = 0; m->kind = KLPLAT_KIND_NONE; m->obj = NULL;
    }
    pthread_mutex_unlock(&g_msg_mu);
    fprintf(stderr, "  [plat] %s -> request %llu, completion queued "
                    "(type 0x%08x, payload %d%s%s)\n",
            what, (unsigned long long)id, type, payload,
            str ? ", string " : "", str ? str : "");
    return id;
}

// ...and the failing spelling: the same request/completion pair, with the
// completion an error.
// `msg` (optional) is the error's text; NULL is the store-absent sentence.
static uint64_t klplat_request_err_msg(const char *what, uint32_t type, const char *msg) {
    pthread_mutex_lock(&g_msg_mu);
    uint64_t id = g_next_request++;
    if (g_msg_tail - g_msg_head < KLPLAT_MSGQ) {
        klplat_msg *m = &g_msgq[g_msg_tail++ % KLPLAT_MSGQ];
        m->type = type; m->request = id; m->payload = 0; m->str = msg;
        m->err = 1; m->kind = KLPLAT_KIND_NONE; m->obj = NULL;
    }
    pthread_mutex_unlock(&g_msg_mu);
    fprintf(stderr, "  [plat] %s -> request %llu, ERROR completion queued "
                    "(type 0x%08x)\n", what, (unsigned long long)id, type);
    return id;
}
static uint64_t klplat_request_err(const char *what, uint32_t type) {
    return klplat_request_err_msg(what, type, NULL);
}

// A NOTIFICATION: request id 0, which is how the SDK tells one from a
// completion. Queued only right behind the request it reports on.
static void klplat_notify(const char *what, uint32_t type, const void *obj) {
    pthread_mutex_lock(&g_msg_mu);
    if (g_msg_tail - g_msg_head < KLPLAT_MSGQ) {
        klplat_msg *m = &g_msgq[g_msg_tail++ % KLPLAT_MSGQ];
        m->type = type; m->request = 0; m->payload = 0; m->str = NULL;
        m->err = 0; m->kind = KLPLAT_KIND_NONE; m->obj = obj;
    }
    pthread_mutex_unlock(&g_msg_mu);
    fprintf(stderr, "  [plat] %s -> notification queued (type 0x%08x)\n", what, type);
}

// ...and the int-payload spelling, which is all but one caller.
static uint64_t klplat_request(const char *what, uint32_t type, int32_t payload) {
    return klplat_request_str(what, type, payload, NULL);
}

// Same queue, with the array kind the course getters switch on. `payload` is
// the element count captured at request time.
static uint64_t klplat_request_kind(const char *what, uint32_t type,
                                    int32_t payload, int kind) {
    pthread_mutex_lock(&g_msg_mu);
    uint64_t id = g_next_request++;
    if (g_msg_tail - g_msg_head < KLPLAT_MSGQ) {
        klplat_msg *m = &g_msgq[g_msg_tail++ % KLPLAT_MSGQ];
        m->type = type; m->request = id; m->payload = payload; m->str = NULL;
        m->err = 0; m->kind = kind; m->obj = NULL;
    }
    pthread_mutex_unlock(&g_msg_mu);
    fprintf(stderr, "  [plat] %s -> request %llu, completion queued "
                    "(type 0x%08x, %d item%s)\n",
            what, (unsigned long long)id, type, payload, payload == 1 ? "" : "s");
    return id;
}

// The message pump. NULL still means "no messages queued", which is the
// documented way to say it and is the steady state for all but three calls a
// run — what changed is that it is no longer the ONLY thing this can say.
static void *klplat_PopMessage(void) {
    plat_hit("ovr_PopMessage");
    void *out = NULL;
    pthread_mutex_lock(&g_msg_mu);
    if (g_msg_head != g_msg_tail) out = &g_msgq[g_msg_head++ % KLPLAT_MSGQ];
    pthread_mutex_unlock(&g_msg_mu);
    return out;
}

// The accessors the SDK's Message base class and the two payload wrappers call
// on that handle. Real functions rather than named trampolines, because these
// take the handle in x0 and a trampoline would put the entry point's NAME there.
//
// Every other Message accessor is deliberately absent — a message shape we do
// not produce should stop the run by name rather than answer.
static uint64_t klplat_Message_GetType(const klplat_msg *m) {
    plat_hit("ovr_Message_GetType");
    return m ? m->type : 0;
}
static uint64_t klplat_Message_IsError(const klplat_msg *m) {
    plat_hit("ovr_Message_IsError");
    return m ? (uint64_t)m->err : 0;
}
// The error handle IS the message, as the payload handle is. Its text is what
// happened, in words a person reading the game's own dialog can act on: the
// message's own `str` when it carries one (a language pack that is not on the
// device), else the store-absent sentence (a refused checkout).
#define KLPLAT_ERR_NO_STORE \
    "The Oculus store is not available on this device, so nothing was purchased."
static uint64_t klplat_Message_GetError(const klplat_msg *m) {
    plat_hit("ovr_Message_GetError");
    return (uint64_t)(uintptr_t)m;
}
static uint64_t klplat_Error_GetCode(const klplat_msg *m) {
    plat_hit("ovr_Error_GetCode");
    (void)m;
    return 1;                     // non-zero, and no code the SDK assigns meaning to
}
static uint64_t klplat_Error_GetHttpCode(const klplat_msg *m) {
    plat_hit("ovr_Error_GetHttpCode");
    (void)m;
    return 0;                     // no request left this machine
}
static const char *klplat_Error_GetMessage(const klplat_msg *m) {
    plat_hit("ovr_Error_GetMessage");
    return m && m->str ? m->str : KLPLAT_ERR_NO_STORE;
}
static const char *klplat_Error_GetDisplayableMessage(const klplat_msg *m) {
    plat_hit("ovr_Error_GetDisplayableMessage");
    return m && m->str ? m->str : KLPLAT_ERR_NO_STORE;
}
// The checkout itself. A real function for the same reason the accessors are:
// the SKU arrives in x0.
static uint64_t klplat_IAP_LaunchCheckoutFlow(const char *sku) {
    // KL_PLAT_CHECKOUT_ERROR=0|1: the error completion below, default on for
    // avp-play's titles only. Off (this fork's existing targets) keeps the
    // older refusal, which aborts like every other purchase-side call.
    static int err = -1;
    if (err < 0) {
        extern int kl_ovrp_avpplay_title(void);
        err = kl_env_on("KL_PLAT_CHECKOUT_ERROR", kl_ovrp_avpplay_title());
    }
    if (!err) return klplat_drm("ovr_IAP_LaunchCheckoutFlow");
    plat_hit("ovr_IAP_LaunchCheckoutFlow");
    fprintf(stderr, "  [plat] checkout asked for SKU '%s' — no store on this host, "
                    "answering with an error\n", sku ? sku : "");
    return klplat_request_err("ovr_IAP_LaunchCheckoutFlow", KLPLAT_MSG_IAP_CHECKOUT);
}

// ---- language-pack status (see plat_is_langpack_status) ---------------------
typedef struct {
    uint64_t id; char path[1024]; char tag[32];
    const char *status;          // "installed" or "available"
    unsigned long long size;     // the manifest's size (batman) / the file's (AC Nexus)
} klplat_asset;
// A handful per run (the game asks for the current language, perhaps a
// fallback), handed out round-robin: a details handle is read once, right after
// its message, and the guest never keeps it.
static klplat_asset g_assets[8];
static unsigned     g_asset_next;

// The game's own manifest, in the OBB directory it reads its packs from.
// Returns 1 and fills size/tag if `name` is one of its lines.
static int langpack_in_manifest(const char *dir, const char *name,
                                unsigned long long *size, char *tag, size_t tagcap) {
    char mf[1200];
    snprintf(mf, sizeof mf, "%s/localized-asset-manifest.txt", dir);
    FILE *f = fopen(mf, "r");
    if (!f) return 0;
    char line[512];
    int hit = 0;
    while (!hit && fgets(line, sizeof line, f)) {
        char *c1 = strchr(line, ':');
        char *c2 = c1 ? strchr(c1 + 1, ':') : NULL;
        if (!c2) continue;
        *c1 = 0; *c2 = 0;
        if (strcmp(c1 + 1, name) != 0) continue;
        *size = strtoull(c2 + 1, NULL, 10);
        snprintf(tag, tagcap, "%s", line);
        hit = 1;
    }
    fclose(f);
    return hit;
}

// The `<tag>.lang` files in AC Nexus's OBB directory (plat_is_obb_langpack_target).
// Rescanned on every question, so the answer is what is on disk now.
#define KLPLAT_OBB_LANG_PKG "com.Ubisoft.ACNexusVR"
static klplat_asset g_lang[8];
static int          g_nlang;
static int klplat_scan_obb_langpacks(void) {
    g_nlang = 0;
    const char *root = kl_jni_files_dir();
    char dir[PATH_MAX];
    if (!root || !root[0] ||
        snprintf(dir, sizeof dir, "%s/Android/obb/" KLPLAT_OBB_LANG_PKG, root) >= (int)sizeof dir)
        return 0;
    DIR *d = opendir(dir);
    if (!d) return 0;
    struct dirent *de;
    while ((de = readdir(d)) != NULL && g_nlang < (int)(sizeof g_lang / sizeof g_lang[0])) {
        size_t nl = strlen(de->d_name);
        if (nl <= 5 || strcmp(de->d_name + nl - 5, ".lang") != 0) continue;
        klplat_asset *a = &g_lang[g_nlang];
        memset(a, 0, sizeof *a);
        if (nl - 5 >= sizeof a->tag ||
            snprintf(a->path, sizeof a->path, "%s/%s", dir, de->d_name) >= (int)sizeof a->path)
            continue;
        struct stat st;
        if (stat(a->path, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) continue;
        memcpy(a->tag, de->d_name, nl - 5);
        for (const char *p = de->d_name; *p; p++) a->id = a->id * 131 + (unsigned char)*p;
        if (!a->id) a->id = 1;
        a->status = "installed";
        a->size = (unsigned long long)st.st_size;
        g_nlang++;
    }
    closedir(d);
    static int said = -1;
    if (said != g_nlang) {
        said = g_nlang;
        char tags[160] = ""; size_t o = 0;
        for (int i = 0; i < g_nlang && o + 34 < sizeof tags; i++)
            o += (size_t)snprintf(tags + o, sizeof tags - o, "%s%s", i ? " " : "", g_lang[i].tag);
        fprintf(stderr, "  [plat] language packs on disk: %d (%s)\n", g_nlang, tags);
    }
    return g_nlang;
}
// A status request about one of them: the details ride on the message, as for
// batman. A name or id that is not one of these files is not a language pack,
// and the refusal stands.
static uint64_t klplat_obb_langpack_status(const char *what, uint32_t type,
                                           const char *name, uint64_t id) {
    klplat_scan_obb_langpacks();
    klplat_asset *a = NULL;
    for (int i = 0; i < g_nlang && !a; i++) {
        const char *base = strrchr(g_lang[i].path, '/');
        if (name ? (base && strcmp(base + 1, name) == 0) : g_lang[i].id == id) a = &g_lang[i];
    }
    if (!a) return klplat_drm(what);
    uint64_t req = klplat_request(what, type, 0);
    pthread_mutex_lock(&g_msg_mu);
    for (unsigned i = g_msg_head; i != g_msg_tail; i++)
        if (g_msgq[i % KLPLAT_MSGQ].request == req) g_msgq[i % KLPLAT_MSGQ].obj = a;
    pthread_mutex_unlock(&g_msg_mu);
    return req;
}

static uint64_t klplat_langpack_StatusByName(const char *name) {
    plat_hit("ovr_AssetFile_StatusByName");
    if (plat_is_obb_langpack_target())
        return klplat_obb_langpack_status("ovr_AssetFile_StatusByName",
                                          KLPLAT_MSG_ASSET_STATUS_NAME, name ? name : "", 0);
    const char *files = kl_jni_files_dir();
    char dir[1100];
    snprintf(dir, sizeof dir, "%s/obb", files ? files : ".");
    unsigned long long want = 0;
    char tag[32] = "";
    // A name outside the manifest is not a language pack, and what it is cannot
    // be known from here: that is the refusal's case, unchanged.
    if (!name || strchr(name, '/') || !langpack_in_manifest(dir, name, &want, tag, sizeof tag))
        return klplat_drm("ovr_AssetFile_StatusByName");

    klplat_asset *a = &g_assets[g_asset_next++ % (sizeof g_assets / sizeof g_assets[0])];
    memset(a, 0, sizeof *a);
    snprintf(a->path, sizeof a->path, "%s/%s", dir, name);
    snprintf(a->tag, sizeof a->tag, "%s", tag);
    for (const char *p = name; *p; p++) a->id = a->id * 131 + (unsigned char)*p;
    if (!a->id) a->id = 1;
    struct stat st;
    int there = stat(a->path, &st) == 0 && (unsigned long long)st.st_size == want;
    a->status = there ? "installed" : "available";
    a->size = want;
    fprintf(stderr, "  [plat] language pack '%s' (%s): %s\n", name, tag,
            there ? "on disk at the manifest's size -> installed"
                  : "not on disk -> available (it cannot be fetched from here)");

    uint64_t id = klplat_request("ovr_AssetFile_StatusByName", KLPLAT_MSG_ASSET_STATUS_NAME, 0);
    // Attach the details to the message just queued — the newest one in the ring.
    pthread_mutex_lock(&g_msg_mu);
    for (unsigned i = g_msg_head; i != g_msg_tail; i++)
        if (g_msgq[i % KLPLAT_MSGQ].request == id) g_msgq[i % KLPLAT_MSGQ].obj = a;
    pthread_mutex_unlock(&g_msg_mu);
    return id;
}
// ---- a pack download (see the note above plat_is_langpack_status) ----------
#define KLPLAT_ERR_LANGPACK \
    "This language pack is not on this device and cannot be downloaded from inside the game. " \
    "Install it from the AVP Game Hub (it downloads the packs for your language)."

// batman: the manifest line whose file is `name`, or whose id (the hash
// StatusByName hands out) is `id`, as a details slot with its disk status.
static klplat_asset *klplat_langpack_lookup(const char *name, uint64_t id) {
    if (plat_is_obb_langpack_target()) {
        klplat_scan_obb_langpacks();
        for (int i = 0; i < g_nlang; i++) {
            const char *base = strrchr(g_lang[i].path, '/');
            if (name ? (base && strcmp(base + 1, name) == 0) : g_lang[i].id == id) return &g_lang[i];
        }
        return NULL;
    }
    if (name && strchr(name, '/')) return NULL;
    const char *files = kl_jni_files_dir();
    char dir[1100];
    snprintf(dir, sizeof dir, "%s/obb", files ? files : ".");
    char mf[1200];
    snprintf(mf, sizeof mf, "%s/localized-asset-manifest.txt", dir);
    FILE *f = fopen(mf, "r");
    if (!f) return NULL;
    char line[512];
    klplat_asset *a = NULL;
    while (!a && fgets(line, sizeof line, f)) {
        char *c1 = strchr(line, ':');
        char *c2 = c1 ? strchr(c1 + 1, ':') : NULL;
        if (!c2) continue;
        *c1 = 0; *c2 = 0;
        const char *file = c1 + 1;
        if (!*file || strchr(file, '/')) continue;
        uint64_t h = 0;
        for (const char *p = file; *p; p++) h = h * 131 + (unsigned char)*p;
        if (!h) h = 1;
        if (name ? strcmp(file, name) != 0 : h != id) continue;
        a = &g_assets[g_asset_next++ % (sizeof g_assets / sizeof g_assets[0])];
        memset(a, 0, sizeof *a);
        a->id = h;
        a->size = strtoull(c2 + 1, NULL, 10);
        snprintf(a->path, sizeof a->path, "%s/%s", dir, file);
        snprintf(a->tag, sizeof a->tag, "%s", line);
        struct stat st;
        a->status = stat(a->path, &st) == 0 && (unsigned long long)st.st_size == a->size
                        ? "installed" : "available";
    }
    fclose(f);
    return a;
}

// The pack the game asked for and did not get, for the hub's next open: one
// small file in the game's own files dir (<container>/android-files on the
// headset), its language tag then its file name, one per line. The hub shows
// "the game asked for voice pack X — download it here" on the game's card and
// deletes the file once that pack is installed. Best effort: a write that
// fails costs the banner only.
#define KLPLAT_LANGPACK_REQUEST_FILE "klepton-voicepack-request.txt"
static void klplat_langpack_note_request(const char *tag, const char *file) {
    const char *files = kl_jni_files_dir();
    if (!files || !*files) return;
    char path[1200];
    snprintf(path, sizeof path, "%s/" KLPLAT_LANGPACK_REQUEST_FILE, files);
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%s\n%s\n", tag ? tag : "", file ? file : "");
    fclose(f);
    fprintf(stderr, "  [plat] noted for the hub: %s (%s)\n", path, tag ? tag : "?");
}

static uint64_t klplat_langpack_Download(const char *what, uint32_t type,
                                         const char *name, uint64_t id) {
    plat_hit(what);
    klplat_asset *a = klplat_langpack_lookup(name, id);
    // Not a language pack of this game: what it is cannot be known from here,
    // and that is the refusal's case, unchanged.
    if (!a) return klplat_drm(what);
    const char *base = strrchr(a->path, '/');
    base = base ? base + 1 : a->path;
    if (strcmp(a->status, "installed") == 0) {
        fprintf(stderr, "  [plat] %s: language pack '%s' (%s) is already on disk "
                        "(%llu bytes) -> completed, nothing fetched\n",
                what, base, a->tag, a->size);
        uint64_t req = klplat_request(what, type, 0);
        pthread_mutex_lock(&g_msg_mu);
        for (unsigned i = g_msg_head; i != g_msg_tail; i++)
            if (g_msgq[i % KLPLAT_MSGQ].request == req) g_msgq[i % KLPLAT_MSGQ].obj = a;
        pthread_mutex_unlock(&g_msg_mu);
        klplat_notify("Notification_AssetFile_DownloadUpdate (completed)",
                      KLPLAT_MSG_ASSET_DOWNLOAD_UPDATE, a);
        return req;
    }
    fprintf(stderr, "  [plat] %s: language pack '%s' (%s) is NOT on disk -> error "
                    "completion (it cannot be fetched from here; the hub downloads it)\n",
            what, base, a->tag);
    klplat_langpack_note_request(a->tag, base);
    return klplat_request_err_msg(what, type, KLPLAT_ERR_LANGPACK);
}
static uint64_t klplat_AssetFile_DownloadById(uint64_t id) {
    if (!plat_is_langpack_target()) return klplat_drm("ovr_AssetFile_DownloadById");
    return klplat_langpack_Download("ovr_AssetFile_DownloadById",
                                    KLPLAT_MSG_ASSET_DOWNLOAD_ID, NULL, id);
}
static uint64_t klplat_AssetFile_DownloadByName(const char *name) {
    if (!plat_is_langpack_target()) return klplat_drm("ovr_AssetFile_DownloadByName");
    return klplat_langpack_Download("ovr_AssetFile_DownloadByName",
                                    KLPLAT_MSG_ASSET_DOWNLOAD_NAME, name ? name : "", 0);
}
// The download result and the update ride on the message as the details do.
static uint64_t klplat_langpack_Message_GetObj(const klplat_msg *m) {
    plat_hit("ovr_Message_GetAssetFileDownload*");
    return (uint64_t)(uintptr_t)(m ? m->obj : NULL);
}
static uint64_t klplat_langpack_dl_id(const klplat_asset *a) {
    plat_hit("ovr_AssetFileDownload*_GetAssetId");
    return a ? a->id : 0;
}
static const char *klplat_langpack_dl_path(const klplat_asset *a) {
    plat_hit("ovr_AssetFileDownloadResult_GetFilepath");
    return a ? a->path : "";
}
static uint64_t klplat_langpack_dl_bytes(const klplat_asset *a) {
    plat_hit("ovr_AssetFileDownloadUpdate_GetBytes*");
    return a ? (uint64_t)a->size : 0;
}
static uint64_t klplat_langpack_dl_completed(const klplat_asset *a) {
    plat_hit("ovr_AssetFileDownloadUpdate_GetCompleted");
    return a ? 1 : 0;
}
static uint64_t klplat_langpack_Message_GetAssetDetails(const klplat_msg *m) {
    plat_hit("ovr_Message_GetAssetDetails");
    return (uint64_t)(uintptr_t)(m ? m->obj : NULL);
}
static uint64_t klplat_langpack_GetAssetId(const klplat_asset *a) {
    plat_hit("ovr_AssetDetails_GetAssetId");
    return a ? a->id : 0;
}
static const char *klplat_langpack_GetAssetType(const klplat_asset *a) {
    plat_hit("ovr_AssetDetails_GetAssetType");
    (void)a;
    return "language_pack";
}
static const char *klplat_langpack_GetDownloadStatus(const klplat_asset *a) {
    plat_hit("ovr_AssetDetails_GetDownloadStatus");
    return a ? a->status : "available";
}
static const char *klplat_langpack_GetFilepath(const klplat_asset *a) {
    plat_hit("ovr_AssetDetails_GetFilepath");
    return a ? a->path : "";
}
// Not for sale, so there is no purchase to have or lack.
static const char *klplat_langpack_GetIapStatus(const klplat_asset *a) {
    plat_hit("ovr_AssetDetails_GetIapStatus");
    (void)a;
    return "free";
}
// The language handle is the details: tag and both names are the locale.
static uint64_t klplat_AssetDetails_GetLanguage(const klplat_asset *a) {
    plat_hit("ovr_AssetDetails_GetLanguage");
    return (uint64_t)(uintptr_t)a;
}
static const char *klplat_langpack_GetMetadata(const klplat_asset *a) {
    plat_hit("ovr_AssetDetails_GetMetadata");
    (void)a;
    return "";
}
static const char *klplat_LanguagePackInfo_tag(const klplat_asset *a) {
    plat_hit("ovr_LanguagePackInfo_Get*");
    return a ? a->tag : "";
}
static uint64_t klplat_Message_GetRequestID(const klplat_msg *m) {
    plat_hit("ovr_Message_GetRequestID");
    return m ? m->request : 0;
}
// The payload handle IS the message: there is one payload per message here, so
// a separate allocation would only be a second thing to keep alive.
static uint64_t klplat_Message_GetPayload(const klplat_msg *m) {
    plat_hit("ovr_Message_GetPayload");
    return (uint64_t)(uintptr_t)m;
}
static uint64_t klplat_payload_int(const klplat_msg *m) {
    plat_hit("ovr_Payload_GetInt");
    return m ? (uint64_t)(uint32_t)m->payload : 0;
}
// ...and the string one. `Message<string>` reads its data with this rather than
// through the payload handle, so a message whose managed wrapper is a string
// carries `str` and answers here. NULL for every other message, which is what
// the SDK expects for one that has no string.
static const char *klplat_Message_GetString(const klplat_msg *m) {
    plat_hit("ovr_Message_GetString");
    return m ? m->str : NULL;
}
static uint64_t klplat_FreeMessage(klplat_msg *m) {
    plat_hit("ovr_FreeMessage");
    (void)m;                      // the ring owns it; see the KLPLAT_MSGQ note
    return 0;
}

// ---------------------------------------------------------------------------
// What we do implement: the platform reporting its own absence, honestly.
//
// ovr_IsPlatformInitialized answers false, because it is not initialised and
// never will be. That is the same answer a real headset would give before init,
// so the guest's own "platform unavailable" path is a path it already has — its
// metadata carries "Oculus Platform failed to initialize." and
// "Initialize Error: Oculus platform failed to initialize due to exception."
// ...and it answers TRUE once an init request has been completed, because the
// SDK gates every other request on it — `Entitlements.IsUserEntitledToApplication`
// and `Users.GetUserAgeCategory` both begin `if (Core.IsInitialized())`, and
// Core.IsInitialized() IS this call. Answering false there is not a cautious
// answer, it is a guarantee that no request is ever made and so no completion
// is ever awaited-and-delivered; the two halves have to agree.
static uint64_t klplat_IsPlatformInitialized(void) {
    plat_hit("ovr_IsPlatformInitialized");
    return (uint64_t)g_platform_up;
}

// ...and the SYNCHRONOUS Android wrapper, which is the same decision reached
// through a different door — and a different RETURN TYPE, which is what made it
// worth measuring rather than grouping.
//
// `Oculus.Platform.Core.Initialize(appId)` calls this one and THROWS when it is
// false: `UnityException("Oculus Platform failed to initialize.")`. It is not an
// ovrRequest and not a PlatformInitializeResult — the real export builds a byte
// (`and w8, w8, #1; strb w8, [sp, ...]`), i.e. a plain bool, checked in both
// this tree's loaders (superhot +0x51934, beatsaber +0x8aae4). Grouped with the
// request-returning init family it would answer 0, and 0 in a bool is false.
//
// Why it answers TRUE, given the file's standing objection to inventing success:
// that objection is about a request id nothing completes, and it no longer
// applies. This branch has a message queue, the async init already answers
// success and sets g_platform_up, and the app's own entitlement completes
// through it. Answering false HERE while answering success THERE is the two
// halves disagreeing — and the cost of the disagreement is not an error path,
// it is the whole title: a guest running the stock
// `Oculus.Platform.Samples.EntitlementCheck` behaviour catches the throw, runs
// its failure handler, and calls `UnityEngine.Application.Quit()`. Unity's quit
// gate then makes `nativeRender` a no-op for the rest of the process's life, so
// what a person sees is not an error message but a frozen frame, reprojected
// forever, with every counter healthy. SUPERHOT VR is such a guest.
//
// **The DRM line does not move with this.** Asking to connect to the platform is
// not an ownership question (that is why this family was never among the
// refusals); IAP, purchase records, asset details and every delivery call still
// abort unconditionally and check_drm_guard still asserts both directions.
// What init being answered buys is that the app's own licence check — the one
// carve-out this project deliberately made — becomes REACHABLE. A guest that
// quits before it can ask is not a guest being refused; it is one that never got
// to the question.
//
// Deliberately narrow: only this name. The Asynchronous / Standalone spellings
// have their own answers above, and the `ovr_PlatformInitialize*` family returns
// an `ovrPlatformInitializeResult` (a THIRD convention, whose Success is 0).
static uint64_t klplat_UnityInitWrapper(const char *app_id) {
    plat_hit("ovr_UnityInitWrapper");
    g_platform_up = 1;
    static int said;
    if (!said) {
        said = 1;
        fprintf(stderr, "  [plat] ovr_UnityInitWrapper(\"%s\") -> true (the "
                        "synthetic platform reports it came up, so the app's own "
                        "entitlement check can be asked and answered; every "
                        "ownership query still refuses)\n", app_id ? app_id : "");
    }
    return 1;
}

// The app's own licence check — see the g_plat_absent carve-out above for why
// this one is answered and the rest of the family is not: the user unpacked
// their own APK, so a licence to the application itself is something we can
// assert, while DLC needs out-of-band asset data and a licence we genuinely
// cannot verify. Non-zero is load-bearing rather than incidental — 0 here is
// the guest's licence-FAILURE path, not a neutral answer — so m_boot's
// check_drm_guard asserts the value, in both directions along with the
// refusals it sits beside.
// It is a REQUEST, not a predicate — `Entitlements.IsUserEntitledToApplication()`
// wraps its return in a `Request` and awaits the completion, so the old bare 1
// was request id 1 with nothing ever arriving for it. The answer is unchanged
// and so is the reasoning above; it is now delivered where the guest reads it,
// as a non-error completion, which is how this API spells "entitled".
// ---------------------------------------------------------------------------
// Walkabout courses that are actually on disk
//
// The menu loads from Addressables. Starting a course is a second question:
// does this viewer own it? The game asks the Oculus platform (GetViewerPurchases
// and the asset-file list) and will not start a course the answer leaves out.
//
// The tracks themselves are already here when the user copied them off a Quest
// they own. They sit beside the packaged OBB, one
// `<prefix>common_assets_.bundle` per course. A real bundle is megabytes. The
// placeholder tools/walkabout_stub_bundles.py writes is a few kilobytes, and
// that is not a course — glooplair stays locked while it is a stub.
//
// So the platform reports a course installed when that bundle is present and
// large. Purchased is a separate fact and does not follow from the file: its
// store ids are reported only for a course the store itself confirmed (see
// klplat_load_entitlements). Download, Delete and ConsumePurchase still abort:
// nothing is fetched, and a course with no file is absent from the asset list. Every other title keeps the old answers (an empty
// asset list, and request id 0 for purchases).
//
// The store ids are the ones serialized in the game's own CourseIAP assets
// (the product id, the course key, and the numeric Oculus SKUs). Whichever of
// those DoesUserOwnProduct compares against, it is one of that course's ids
// and no other course's.

// 48 held Walkabout's courses; a title with one add-on file per song has hundreds.
enum { KLPLAT_COURSE_MAX = 384, KLPLAT_PURCHASE_MAX = 512, KLPLAT_PRODUCT_MAX = 256 };
enum { KLPLAT_COURSE_MIN_BYTES = 1 << 20 };

typedef struct {
    char prefix[48];
    char path[768];
    uint64_t id;
    int iap_row;                 // index into k_course_iap, or -1 for a base course
    int delivered;               // 1: an add-on file the store itself delivered (see klplat_scan_delivered)
} klplat_course;

typedef struct {
    const char *sku;
    uint64_t id;
} klplat_purchase;

typedef struct {
    const char *sku;
} klplat_product;

static klplat_course   g_courses[KLPLAT_COURSE_MAX];
static int             g_ncourses;
static klplat_course   g_missing = { .iap_row = -1 };
static klplat_purchase g_purchases[KLPLAT_PURCHASE_MAX];
static int             g_npurchases;
/* "Tiki" is also asked as "Tiki-Easy" / "Tiki-Hard": the game's own IAP-suffix
   check rejects '_' and requires '-'. Built at scan time, only for a course
   whose bundle is present. */
static char            g_suffix_sku[160][96];
static int             g_nsuffix;
static klplat_product  g_products[KLPLAT_PRODUCT_MAX];
static int             g_nproducts;

static const char *const k_sku_alice[] = {
    "Alice", "alice",
    "0508570229647579", "0418993343719872", "0458073381106966", "0923353526946195", NULL };
static const char *const k_sku_amusementpark[] = {
    "Fairyland", "ForgottenFairyland", "AmusementPark", "fairyland", "amusementpark",
    "0231896114137487", "0118522714705222", "0979900971745119", "0929255417249534", NULL };
static const char *const k_sku_aroundtheworld[] = {
    "AroundTheWorld", "around_the_world", "aroundtheworld",
    "0809673849171947", "0381387977600117", "0464846572721676", "0089224930412381", NULL };
static const char *const k_sku_atlantis[] = {
    "Atlantis", "atlantis",
    "0193615521010795", "0126263252455057", "0785996778995100", "0070235305715118", NULL };
static const char *const k_sku_babylon[] = {
    "GardensOfBabylon", "Babylon", "gardens_of_babylon", "babylon",
    "0883465875498324", "0468433596909097", "0357028625964721", "0440901715502036", NULL };
static const char *const k_sku_blokhaven[] = {
    "Blokhaven", "blokhaven",
    "0792874719224960", "0448237864330080", "0186685347544838", "0833133854582451", NULL };
static const char *const k_sku_christmas[] = {
    "HolidayHideaway", "Christmas", "holiday_hideaway", "christmas",
    "0539445275378225", "0738663383377858", "0353303721845295", "0465685194506867", NULL };
static const char *const k_sku_crystallair[] = {
    "CrystalLair", "crystal_lair", "crystallair",
    "0595272659142648", "0692494830833590", "0389051848841963", "0791551254406180", NULL };
static const char *const k_sku_dinotrek[] = {
    "RaptorCliffs", "DinoTrek", "raptor_cliffs", "dinotrek",
    "0280952767786223", "0657765835048147", "0757357488987015", "0295622698767353", NULL };
static const char *const k_sku_eldorado[] = {
    "ElDorado", "el_dorado", "eldorado",
    "0782009790857091", "0608881966116657", "0736786255141041", "0353137664124339", NULL };
static const char *const k_sku_glooplair[] = {
    "GloopLair", "glooplair",
    "0039385890638181", "0393122296438243", "0432479671626154", "0208424449522073", NULL };
static const char *const k_sku_hollywood[] = {
    "Hollywood", "hollywood",
    "0851582513712615", "0268100986231193", "0499491591065399", "0333623169506999", NULL };
static const char *const k_sku_journey[] = {
    "Journey", "journey",
    "0201630851737472", "0924377305170762", "0368521921284294", "0554013985097819", NULL };
static const char *const k_sku_labyrinth[] = {
    "Labyrinth", "labyrinth",
    "0386676296379164", "0519765801230615", "0794463215268664", "0975451948660469", NULL };
static const char *const k_sku_mars[] = {
    "MarsGardens", "Mars", "mars_gardens", "mars",
    "0447460470797810", "0584906650980393", "0842789959214737", "0488127592926092", NULL };
static const char *const k_sku_meowwolf[] = {
    "MeowWolf", "meow_wolf", "meowwolf",
    "0176441726772604", "0558530222121807", "0625332469605345", "0815433443254192", NULL };
static const char *const k_sku_myst[] = {
    "Myst", "myst",
    "0652801418511180", "0370509882972218", "0053133987085667", "0282333553843204", NULL };
static const char *const k_sku_olympus[] = {
    "Olympus", "olympus",
    "0981989358512753", "0527839967097480", "0491689512026715", "0325529197532150", NULL };
static const char *const k_sku_tiki[] = {
    "Tiki", "tiki",
    "0747504920995321", "0843678180221081", "0822281563296852", "0237479462796302", NULL };
static const char *const k_sku_tokyo[] = {
    "Tokyo", "tokyo",
    "0284462869323706", "0944106475990195", "0427314937628732", "0357998668137809", NULL };
static const char *const k_sku_vegas[] = {
    "Vegas", "vegas", "VivaLasElvis", "viva_las_elvis",
    "0342954105855049", "0680995419979357", "0192938135998486", "0919699210002063", NULL };
static const char *const k_sku_venice[] = {
    "Venice", "venice",
    "0818815108952217", "0711539433621922", "0449413071930315", "0814372382135912", NULL };
static const char *const k_sku_villains8bit[] = {
    "8BitLair", "8Bit", "Villains8Bit", "8bit_lair", "villains8bit",
    "0457632226017672", "0955888416106811", "0820833223912158", "0708386203900748", NULL };
static const char *const k_sku_villainsarctic[] = {
    "IceLair", "VillainsArctic", "ice_lair", "villainsarctic",
    "0927683480793557", "0242239932998891", "0336458101349780", "0189649934441094", NULL };
static const char *const k_sku_wallace[] = {
    "WallaceAndGromit", "wallace_and_gromit", "wallaceandgromit",
    "0569395155549669", "0436490607169566", "0706704701080124", "0413363645758406", NULL };
static const char *const k_sku_widows[] = {
    "Widows", "Haunted", "widowswalkabout", "widows_walkabout",
    "0953970477189139", "0056559795905160", "0151583285449966", "0493989045534602", NULL };
/* Laser Lair's course bundle is real, but this build's CourseIAP catalogue has
   no numeric store id for it. The names are the course's own (courseinfos). */
static const char *const k_sku_laserlair[] = {
    "LaserLair", "VillainsTropical", "laserlair", NULL };
static const char *const k_sku_zerzura[] = {
    "Zerzura", "zerzura",
    "0246728596865682", "0590424361368553", "0094566846310398", "0125621824615283", NULL };

// Four courses the table above did not know were sold. Their SKUs are the ones
// the store's own purchase list (viewer_purchases) names; the prefixes are the
// bundle names in the build's asset list. Without a row a course reported "free"
// to every owner of the base game.
static const char *const k_sku_20k[]       = { "20000leagues", NULL };
static const char *const k_sku_alfheim[]   = { "alfheim", NULL };
static const char *const k_sku_shangrila[] = { "ShangriLa", NULL };
static const char *const k_sku_sweetopia[] = { "sweetopia", NULL };

static const struct { const char *prefix; const char *const *skus; } k_course_iap[] = {
    { "20k",              k_sku_20k },
    { "alfheim",          k_sku_alfheim },
    { "shangri-la",       k_sku_shangrila },
    { "sweetopia",        k_sku_sweetopia },
    { "alice",            k_sku_alice },
    { "amusementpark",    k_sku_amusementpark },
    { "aroundtheworld",   k_sku_aroundtheworld },
    { "atlantis",         k_sku_atlantis },
    { "babylon",          k_sku_babylon },
    { "blokhaven",        k_sku_blokhaven },
    { "christmas",        k_sku_christmas },
    { "crystallair",      k_sku_crystallair },
    { "dinotrek",         k_sku_dinotrek },
    { "eldorado",         k_sku_eldorado },
    { "glooplair",        k_sku_glooplair },
    { "hollywood",        k_sku_hollywood },
    { "journey",          k_sku_journey },
    { "labyrinth",        k_sku_labyrinth },
    { "laserlair",        k_sku_laserlair },
    { "mars",             k_sku_mars },
    { "meowwolf",         k_sku_meowwolf },
    { "myst",             k_sku_myst },
    { "olympus",          k_sku_olympus },
    { "tiki",             k_sku_tiki },
    { "tokyo",            k_sku_tokyo },
    { "vegas",            k_sku_vegas },
    { "venice",           k_sku_venice },
    { "villains8bit",     k_sku_villains8bit },
    { "villainsarctic",   k_sku_villainsarctic },
    { "wallaceandgromit", k_sku_wallace },
    { "widowswalkabout",  k_sku_widows },
    { "zerzura",          k_sku_zerzura },
};

static int klplat_is_walkabout(void) {
    const char *t = kl_driver_target_name();
    return t && strcmp(t, "walkabout") == 0;
}

static uint64_t klplat_fnv(const char *s) {
    uint64_t h = 14695981039346656037ull;
    if (!s) return 1;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        h ^= *p;
        h *= 1099511628211ull;
    }
    return h ? h : 1;
}

static int klplat_course_cmp(const void *a, const void *b) {
    return strcmp(((const klplat_course *)a)->prefix,
                  ((const klplat_course *)b)->prefix);
}

/* A product id ("Tiki", "8BitLair") rather than a numeric store SKU or a
   snake_case key. Those are the ids the difficulty suffix attaches to. */
static int klplat_is_product_id(const char *s) {
    if (!s || !s[0]) return 0;
    int upper = 0, digit_only = 1;
    for (const char *p = s; *p; p++) {
        int ok = (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
                 (*p >= '0' && *p <= '9');
        if (!ok) return 0;
        if (*p >= 'A' && *p <= 'Z') upper = 1;
        if (*p < '0' || *p > '9') digit_only = 0;
    }
    return upper && !digit_only;
}

static void klplat_add_purchase(const char *sku) {
    if (!sku || !sku[0] || g_npurchases >= KLPLAT_PURCHASE_MAX) return;
    for (int i = 0; i < g_npurchases; i++)
        if (strcmp(g_purchases[i].sku, sku) == 0) return;
    g_purchases[g_npurchases].sku = sku;
    g_purchases[g_npurchases].id = klplat_fnv(sku);
    g_npurchases++;
}

// ---- purchases the store has confirmed --------------------------------------
//
// Which courses this viewer bought is not something the disk can say: the
// build's own expansion-files-config.json marks every course bundle `required`,
// so every owner of the base game has every paid course's files. Reporting a
// course as purchased because its bundle is present therefore unlocked all of
// them for everyone.
//
// The answer comes from the store instead. The Mac side asks it
// (GET graph.oculus.com/<app>/viewer_purchases, with the user's own token) and
// writes the SKUs it returned to <files>/klepton-entitlements.txt, one
// `sku <name>` per line. This side only reads that file: no token is ever on
// the device, and with no file there are no purchases. A failed refresh leaves
// the last confirmed file in place — that is decided where the file is written,
// not here.
enum { KLPLAT_OWNED_MAX = 512 };
static char g_owned[KLPLAT_OWNED_MAX][96];
static int  g_nowned;

static void klplat_load_entitlements(void) {
    static long long seen_mtime = -1, seen_size = -1;
    const char *root = kl_jni_files_dir();
    char path[PATH_MAX];
    struct stat st;
    if (!root || !root[0] ||
        snprintf(path, sizeof path, "%s/klepton-entitlements.txt", root) >= (int)sizeof path ||
        stat(path, &st) != 0 || !S_ISREG(st.st_mode)) {
        if (seen_mtime != 0 || seen_size != 0)
            fprintf(stderr, "  [plat] no klepton-entitlements.txt in %s — no purchases reported\n",
                    root ? root : "(no files dir)");
        seen_mtime = 0; seen_size = 0;
        g_nowned = 0;
        return;
    }
    // Unchanged file, unchanged list: a guest may still hold a SKU string from
    // an earlier answer, so the buffers are only rewritten when the file was.
    if ((long long)st.st_mtime == seen_mtime && (long long)st.st_size == seen_size) return;
    FILE *f = fopen(path, "r");
    if (!f) return;
    g_nowned = 0;
    char line[256], verified[64] = "";
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r' || line[n - 1] == ' ')) line[--n] = 0;
        if (strncmp(line, "verified ", 9) == 0) snprintf(verified, sizeof verified, "%s", line + 9);
        if (strncmp(line, "sku ", 4) != 0 || !line[4]) continue;
        if (g_nowned >= KLPLAT_OWNED_MAX || n - 4 >= sizeof g_owned[0]) continue;
        memcpy(g_owned[g_nowned++], line + 4, n - 4 + 1);
    }
    fclose(f);
    seen_mtime = (long long)st.st_mtime; seen_size = (long long)st.st_size;
    fprintf(stderr, "  [plat] store-confirmed purchases: %d SKU%s (verified %s)\n",
            g_nowned, g_nowned == 1 ? "" : "s", verified[0] ? verified : "at an unknown time");
}

// The store's SKUs are compared without case: it says "Blokhaven" where a
// game's own asset may spell the key "blokhaven".
static int klplat_owns_sku(const char *sku) {
    if (!sku) return 0;
    for (int i = 0; i < g_nowned; i++)
        if (strcasecmp(g_owned[i], sku) == 0) return 1;
    return 0;
}

// A course is bought when the store confirmed any one of its ids.
static int klplat_course_owned(int row) {
    if (row < 0) return 0;
    for (const char *const *s = k_course_iap[row].skus; *s; s++)
        if (klplat_owns_sku(*s)) return 1;
    return 0;
}

// ---- add-on files the store delivered ----------------------------------------
//
// A title whose add-ons are separate asset files (Beat Saber's songs) asks
// ovr_AssetFile_GetList which of them are on the device and reads each one's
// id, path and purchase status. For such a title the store refuses to deliver a
// file the account does not own ("Not entitled to download"), so a file that
// was delivered IS an owned one, and what is reported here is exactly that set:
//
//   <files>/klepton-assets/index.txt     one `asset <store asset id> <name>` per line
//   <files>/klepton-assets/<name>        the file as the store delivered it
//
// Both are written on the Mac from the store's own listing and download. A
// line whose file is missing or empty is not reported, and with no index the
// list is empty — the answer every title had before. Nothing is fetched,
// deleted or purchased from here.
static int klplat_scan_delivered(void) {
    const char *root = kl_jni_files_dir();
    char dir[PATH_MAX], path[PATH_MAX];
    if (!root || !root[0] ||
        snprintf(dir, sizeof dir, "%s/klepton-assets", root) >= (int)sizeof dir ||
        snprintf(path, sizeof path, "%s/index.txt", dir) >= (int)sizeof path)
        return 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[512];
    int listed = 0;
    while (fgets(line, sizeof line, f) && g_ncourses < KLPLAT_COURSE_MAX) {
        unsigned long long id = 0;
        char name[128];
        if (sscanf(line, "asset %llu %127s", &id, name) != 2 || !id) continue;
        if (strchr(name, '/') || strstr(name, "..")) continue;
        listed++;
        klplat_course *c = &g_courses[g_ncourses];
        if (strlen(name) >= sizeof c->prefix) continue;
        int pw = snprintf(c->path, sizeof c->path, "%s/%s", dir, name);
        if (pw < 0 || (size_t)pw >= sizeof c->path) continue;
        struct stat st;
        if (stat(c->path, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) continue;
        snprintf(c->prefix, sizeof c->prefix, "%s", name);
        c->id = (uint64_t)id;
        c->iap_row = -1;
        c->delivered = 1;
        g_ncourses++;
    }
    fclose(f);
    static int said = -1;
    if (said != g_ncourses) {
        said = g_ncourses;
        fprintf(stderr, "  [plat] add-on files delivered by the store: %d on disk of %d indexed\n",
                g_ncourses, listed);
    }
    return g_ncourses;
}

static void klplat_scan_courses(void) {
    g_ncourses = 0;
    g_npurchases = 0;
    g_nsuffix = 0;
    if (!klplat_is_walkabout()) { klplat_scan_delivered(); return; }
    // What the store confirmed is read here, but reported only for a course
    // whose real bundle is on disk (the loop below): this fork never claims a
    // purchase for content that is not on the device. (avp-play also reported
    // every confirmed SKU as it stood; that half is not carried over.)
    klplat_load_entitlements();
    const char *root = kl_jni_files_dir();
    if (!root || !root[0]) return;
    char dir[PATH_MAX];
    int nw = snprintf(dir, sizeof dir,
                      "%s/Android/obb/com.MightyCoconut.WalkaboutMiniGolf", root);
    if (nw < 0 || (size_t)nw >= sizeof dir) return;
    DIR *d = opendir(dir);
    if (!d) return;

    static const char suf[] = "common_assets_.bundle";
    const size_t sl = sizeof suf - 1;
    int stubs = 0;
    struct dirent *de;
    while ((de = readdir(d)) != NULL && g_ncourses < KLPLAT_COURSE_MAX) {
        const char *name = de->d_name;
        size_t nl = strlen(name);
        if (nl <= sl || strcmp(name + (nl - sl), suf) != 0) continue;
        size_t plen = nl - sl;
        if (plen == 0 || plen >= sizeof g_courses[0].prefix) continue;
        char path[PATH_MAX];
        int pw = snprintf(path, sizeof path, "%s/%s", dir, name);
        if (pw < 0 || (size_t)pw >= sizeof path) continue;
        if ((size_t)pw >= sizeof g_courses[0].path) continue;
        struct stat st;
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        if (st.st_size < KLPLAT_COURSE_MIN_BYTES) { stubs++; continue; }

        klplat_course *c = &g_courses[g_ncourses];
        memcpy(c->prefix, name, plen);
        c->prefix[plen] = '\0';
        memcpy(c->path, path, (size_t)pw + 1);
        c->id = klplat_fnv(c->prefix);
        c->iap_row = -1;
        c->delivered = 0;
        for (int i = 0; i < (int)(sizeof k_course_iap / sizeof k_course_iap[0]); i++) {
            if (strcmp(k_course_iap[i].prefix, c->prefix) == 0) {
                c->iap_row = i;
                break;
            }
        }
        g_ncourses++;
    }
    closedir(d);

    if (g_ncourses > 1)
        qsort(g_courses, (size_t)g_ncourses, sizeof g_courses[0], klplat_course_cmp);

    for (int i = 0; i < g_ncourses; i++) {
        int row = g_courses[i].iap_row;
        if (row < 0) continue;
        // The other spellings of a course's id (its key, the numeric store
        // SKUs, the -Easy/-Hard forms) follow only a course the store confirmed.
        if (!klplat_course_owned(row)) continue;
        for (const char *const *s = k_course_iap[row].skus; *s; s++) {
            klplat_add_purchase(*s);
            if (!klplat_is_product_id(*s) || g_nsuffix + 2 > (int)(sizeof g_suffix_sku / sizeof g_suffix_sku[0]))
                continue;
            snprintf(g_suffix_sku[g_nsuffix], sizeof g_suffix_sku[0], "%s-Easy", *s);
            klplat_add_purchase(g_suffix_sku[g_nsuffix++]);
            snprintf(g_suffix_sku[g_nsuffix], sizeof g_suffix_sku[0], "%s-Hard", *s);
            klplat_add_purchase(g_suffix_sku[g_nsuffix++]);
        }
    }

    char listed[2048];
    size_t u = 0;
    listed[0] = '\0';
    for (int i = 0; i < g_ncourses && u + 1 < sizeof listed; i++) {
        int w = snprintf(listed + u, sizeof listed - u, "%s%s",
                         u ? " " : "", g_courses[i].prefix);
        if (w < 0) break;
        if ((size_t)w >= sizeof listed - u) { listed[sizeof listed - 1] = '\0'; break; }
        u += (size_t)w;
    }
    static char sig[2048];
    static int sig_stubs = -1;
    if (strcmp(listed, sig) != 0 || stubs != sig_stubs) {
        snprintf(sig, sizeof sig, "%s", listed);
        sig_stubs = stubs;
        int sold = 0, bought = 0;
        for (int i = 0; i < g_ncourses; i++) {
            if (g_courses[i].iap_row < 0) continue;
            sold++;
            bought += klplat_course_owned(g_courses[i].iap_row);
        }
        fprintf(stderr, "  [plat] walkabout courses on disk: %s "
                        "(%d sold separately, %d of those store-confirmed; "
                        "%d purchase ids, %d stub%s ignored)\n",
                g_ncourses ? listed : "(none)", sold, bought,
                g_npurchases, stubs, stubs == 1 ? "" : "s");
    }
}

static int klplat_course_named(const klplat_course *c, const char *name) {
    if (!c || !name || !name[0]) return 0;
    if (strcmp(name, c->prefix) == 0 || strcmp(name, c->path) == 0) return 1;
    const char *base = strrchr(c->path, '/');
    base = base ? base + 1 : c->path;
    if (strcmp(name, base) == 0) return 1;
    if (c->iap_row >= 0) {
        for (const char *const *s = k_course_iap[c->iap_row].skus; *s; s++) {
            if (strcmp(name, *s) == 0) return 1;
            if (!klplat_is_product_id(*s)) continue;
            size_t n = strlen(*s);
            if (strncmp(name, *s, n) == 0 &&
                (strcmp(name + n, "-Easy") == 0 || strcmp(name + n, "-Hard") == 0))
                return 1;
        }
    }
    return 0;
}

static int klplat_find_course_name(const char *name) {
    for (int i = 0; i < g_ncourses; i++)
        if (klplat_course_named(&g_courses[i], name)) return i;
    return -1;
}

static int klplat_find_course_id(uint64_t id) {
    if (!id) return -1;
    for (int i = 0; i < g_ncourses; i++)
        if (g_courses[i].id == id) return i;
    return -1;
}

static const klplat_course *klplat_as_course(const void *h) {
    if (!h || h == &g_missing) return &g_missing;
    const klplat_course *c = h;
    if (c >= g_courses && c < g_courses + g_ncourses) return c;
    return &g_missing;
}

static const klplat_purchase *klplat_as_purchase(const void *h) {
    if (!h) return NULL;
    const klplat_purchase *p = h;
    if (p >= g_purchases && p < g_purchases + g_npurchases) return p;
    return NULL;
}

static const klplat_product *klplat_as_product(const void *h) {
    if (!h) return NULL;
    const klplat_product *p = h;
    if (p >= g_products && p < g_products + g_nproducts) return p;
    return NULL;
}

static uint64_t klplat_AssetFile_GetList(void) {
    plat_hit("ovr_AssetFile_GetList");
    if (plat_is_obb_langpack_target())
        return klplat_request_kind("ovr_AssetFile_GetList", KLPLAT_MSG_ASSET_LIST,
                                   klplat_scan_obb_langpacks(), KLPLAT_KIND_ASSETS);
    klplat_scan_courses();
    return klplat_request_kind("ovr_AssetFile_GetList", KLPLAT_MSG_ASSET_LIST,
                               g_ncourses, KLPLAT_KIND_ASSETS);
}

static uint64_t klplat_AssetFile_StatusByName(const char *name) {
    // batman asks this about its language packs, Walkabout about its courses.
    if (plat_is_langpack_target()) return klplat_langpack_StatusByName(name);
    plat_hit("ovr_AssetFile_StatusByName");
    klplat_scan_courses();
    if (!klplat_is_walkabout() && g_ncourses == 0) klplat_drm("ovr_AssetFile_StatusByName");
    int i = klplat_find_course_name(name);
    fprintf(stderr, "  [plat] AssetFile_StatusByName('%s') -> %s\n",
            name ? name : "", i >= 0 ? "installed" : "not present");
    return klplat_request_kind("ovr_AssetFile_StatusByName",
                               KLPLAT_MSG_ASSET_STATUS_NAME, i, KLPLAT_KIND_ASSET);
}

static uint64_t klplat_AssetFile_StatusById(uint64_t id) {
    plat_hit("ovr_AssetFile_StatusById");
    if (plat_is_obb_langpack_target())
        return klplat_obb_langpack_status("ovr_AssetFile_StatusById",
                                          KLPLAT_MSG_ASSET_STATUS_ID, NULL, id);
    klplat_scan_courses();
    // Outside Walkabout this is answered only where the store delivered add-on
    // files (klplat_scan_delivered); with none, the refusal is unchanged.
    if (!klplat_is_walkabout() && g_ncourses == 0) klplat_drm("ovr_AssetFile_StatusById");
    int i = klplat_find_course_id(id);
    return klplat_request_kind("ovr_AssetFile_StatusById",
                               KLPLAT_MSG_ASSET_STATUS_ID, i, KLPLAT_KIND_ASSET);
}

static uint64_t klplat_AssetDetailsArray_GetSize(const klplat_msg *m) {
    plat_hit("ovr_AssetDetailsArray_GetSize");
    if (!m || m->kind != KLPLAT_KIND_ASSETS || m->payload < 0) return 0;
    return (uint64_t)m->payload;
}

static void *klplat_AssetDetailsArray_GetElement(const klplat_msg *m, int index) {
    plat_hit("ovr_AssetDetailsArray_GetElement");
    if (!m || m->kind != KLPLAT_KIND_ASSETS) return NULL;
    if (plat_is_obb_langpack_target())
        return index >= 0 && index < m->payload && index < g_nlang ? &g_lang[index] : NULL;
    if (index < 0 || index >= m->payload || index >= g_ncourses) return NULL;
    return &g_courses[index];
}

static uint64_t klplat_Message_GetAssetDetails(const klplat_msg *m) {
    if (plat_is_langpack_target()) return klplat_langpack_Message_GetAssetDetails(m);
    plat_hit("ovr_Message_GetAssetDetails");
    if (!m || m->kind != KLPLAT_KIND_ASSET) return 0;
    if (m->payload < 0 || m->payload >= g_ncourses)
        return (uint64_t)(uintptr_t)&g_missing;
    return (uint64_t)(uintptr_t)&g_courses[m->payload];
}

// Delivery is still refused, so the delivery list stays empty even when the
// details list above names courses that are already on disk.
static uint64_t klplat_AssetFileDeliveryList_GetSize(const void *h) {
    plat_hit("ovr_AssetFileDeliveryList_GetSize");
    (void)h;
    return 0;
}

static uint64_t klplat_AssetDetails_GetAssetId(const void *h) {
    if (plat_is_langpack_target()) return klplat_langpack_GetAssetId(h);
    plat_hit("ovr_AssetDetails_GetAssetId");
    return klplat_as_course(h)->id;
}
static const char *klplat_AssetDetails_GetAssetType(const void *h) {
    if (plat_is_langpack_target()) return klplat_langpack_GetAssetType(h);
    plat_hit("ovr_AssetDetails_GetAssetType");
    (void)h;
    return "default";
}
static const char *klplat_AssetDetails_GetDownloadStatus(const void *h) {
    if (plat_is_langpack_target()) return klplat_langpack_GetDownloadStatus(h);
    plat_hit("ovr_AssetDetails_GetDownloadStatus");
    return klplat_as_course(h)->path[0] ? "installed" : "unknown";
}
static const char *klplat_AssetDetails_GetFilepath(const void *h) {
    if (plat_is_langpack_target()) return klplat_langpack_GetFilepath(h);
    plat_hit("ovr_AssetDetails_GetFilepath");
    return klplat_as_course(h)->path;
}
static const char *klplat_AssetDetails_GetIapStatus(const void *h) {
    if (plat_is_langpack_target()) return klplat_langpack_GetIapStatus(h);
    plat_hit("ovr_AssetDetails_GetIapStatus");
    const klplat_course *c = klplat_as_course(h);
    if (!c->path[0]) return "not-entitled";
    if (c->delivered) return "entitled";      // the store delivered it to this account
    if (c->iap_row < 0) return "free";
    return klplat_course_owned(c->iap_row) ? "entitled" : "not-entitled";
}
static const char *klplat_AssetDetails_GetMetadata(const void *h) {
    if (plat_is_langpack_target()) return klplat_langpack_GetMetadata(h);
    plat_hit("ovr_AssetDetails_GetMetadata");
    (void)h;
    return "";
}

// The language of an asset file. Only a language pack has one (batman, above);
// for a course or a delivered add-on the SDK's own spelling of "none" is NULL,
// and it reads the three LanguagePackInfo names off that NULL without checking.
static uint64_t klplat_AssetDetails_GetLanguage_any(const void *h) {
    if (plat_is_langpack_target()) return klplat_AssetDetails_GetLanguage(h);
    plat_hit("ovr_AssetDetails_GetLanguage");
    (void)h;
    return 0;
}

static uint64_t klplat_iap_purchases(const char *what, uint32_t type) {
    if (!klplat_is_walkabout()) return 0;
    klplat_scan_courses();
    return klplat_request_kind(what, type, g_npurchases, KLPLAT_KIND_PURCHASES);
}

static uint64_t klplat_IAP_GetViewerPurchases(void) {
    plat_hit("ovr_IAP_GetViewerPurchases");
    return klplat_iap_purchases("ovr_IAP_GetViewerPurchases", KLPLAT_MSG_IAP_PURCHASES);
}

static uint64_t klplat_IAP_GetViewerPurchasesDurableCache(void) {
    plat_hit("ovr_IAP_GetViewerPurchasesDurableCache");
    return klplat_iap_purchases("ovr_IAP_GetViewerPurchasesDurableCache",
                                KLPLAT_MSG_IAP_PURCHASES_CACHE);
}

static uint64_t klplat_IAP_GetProductsBySKU(const char **skus, int count) {
    plat_hit("ovr_IAP_GetProductsBySKU");
    if (!klplat_is_walkabout()) return 0;
    klplat_scan_courses();
    g_nproducts = 0;
    if (skus && count > 0) {
        if (count > 512) count = 512;
        for (int i = 0; i < count && g_nproducts < KLPLAT_PRODUCT_MAX; i++) {
            const char *s = skus[i];
            if (!s) continue;
            const char *owned = NULL;
            for (int j = 0; j < g_npurchases; j++) {
                if (strcmp(g_purchases[j].sku, s) == 0) { owned = g_purchases[j].sku; break; }
            }
            if (!owned) continue;
            int dup = 0;
            for (int k = 0; k < g_nproducts; k++)
                if (g_products[k].sku == owned) { dup = 1; break; }
            if (!dup) g_products[g_nproducts++].sku = owned;
        }
    }
    return klplat_request_kind("ovr_IAP_GetProductsBySKU", KLPLAT_MSG_IAP_PRODUCTS,
                               g_nproducts, KLPLAT_KIND_PRODUCTS);
}

static uint64_t klplat_Message_GetPurchaseArray(const klplat_msg *m) {
    plat_hit("ovr_Message_GetPurchaseArray");
    return (uint64_t)(uintptr_t)m;
}
static uint64_t klplat_PurchaseArray_GetSize(const klplat_msg *m) {
    plat_hit("ovr_PurchaseArray_GetSize");
    if (!m || m->kind != KLPLAT_KIND_PURCHASES || m->payload < 0) return 0;
    return (uint64_t)m->payload;
}
static void *klplat_PurchaseArray_GetElement(const klplat_msg *m, int index) {
    plat_hit("ovr_PurchaseArray_GetElement");
    if (!m || m->kind != KLPLAT_KIND_PURCHASES) return NULL;
    if (index < 0 || index >= m->payload || index >= g_npurchases) return NULL;
    return &g_purchases[index];
}
static const char *klplat_Purchase_GetSKU(const void *h) {
    plat_hit("ovr_Purchase_GetSKU");
    const klplat_purchase *p = klplat_as_purchase(h);
    return p ? p->sku : "";
}
static const char *klplat_Purchase_GetPurchaseStrID(const void *h) {
    plat_hit("ovr_Purchase_GetPurchaseStrID");
    const klplat_purchase *p = klplat_as_purchase(h);
    return p ? p->sku : "";
}
static uint64_t klplat_Purchase_GetPurchaseID(const void *h) {
    plat_hit("ovr_Purchase_GetPurchaseID");
    const klplat_purchase *p = klplat_as_purchase(h);
    return p ? p->id : 0;
}
static uint64_t klplat_Purchase_GetGrantTime(const void *h) {
    plat_hit("ovr_Purchase_GetGrantTime");
    (void)h;
    return 1704067200ull;            // 2024-01-01, unix seconds
}
static uint64_t klplat_Purchase_GetExpirationTime(const void *h) {
    plat_hit("ovr_Purchase_GetExpirationTime");
    (void)h;
    return 4102444800ull;            // 2100-01-01, so the grant has not lapsed
}
static const char *klplat_Purchase_GetDeveloperPayload(const void *h) {
    plat_hit("ovr_Purchase_GetDeveloperPayload");
    (void)h;
    return "";
}
static const char *klplat_Purchase_GetReportingId(const void *h) {
    plat_hit("ovr_Purchase_GetReportingId");
    (void)h;
    return "";
}

static uint64_t klplat_Message_GetProductArray(const klplat_msg *m) {
    plat_hit("ovr_Message_GetProductArray");
    return (uint64_t)(uintptr_t)m;
}
static uint64_t klplat_ProductArray_GetSize(const klplat_msg *m) {
    plat_hit("ovr_ProductArray_GetSize");
    if (!m || m->kind != KLPLAT_KIND_PRODUCTS || m->payload < 0) return 0;
    return (uint64_t)m->payload;
}
static void *klplat_ProductArray_GetElement(const klplat_msg *m, int index) {
    plat_hit("ovr_ProductArray_GetElement");
    if (!m || m->kind != KLPLAT_KIND_PRODUCTS) return NULL;
    if (index < 0 || index >= m->payload || index >= g_nproducts) return NULL;
    return &g_products[index];
}
static const char *klplat_Product_GetSKU(const void *h) {
    plat_hit("ovr_Product_GetSKU");
    const klplat_product *p = klplat_as_product(h);
    return p ? p->sku : "";
}
static const char *klplat_Product_GetName(const void *h) {
    plat_hit("ovr_Product_GetName");
    const klplat_product *p = klplat_as_product(h);
    return p ? p->sku : "";
}
static const char *klplat_Product_GetDescription(const void *h) {
    plat_hit("ovr_Product_GetDescription");
    (void)h;
    return "";
}
static const char *klplat_Product_GetPrice(const void *h) {
    plat_hit("ovr_Product_GetPrice");
    (void)h;
    return "";
}
static const char *klplat_Product_GetFormattedPrice(const void *h) {
    plat_hit("ovr_Product_GetFormattedPrice");
    (void)h;
    return "";
}

// The Oculus user *access token* — an opaque credential the app hands to its own
// backend (Ubisoft Connect) to open a session. It is NOT an ownership answer: the
// entitlement check is a separate request (klplat_Entitlement_GetIsViewerEntitled
// above) and this token grants nothing on its own. Returning 0 — "the request
// could not be made" — is what we did before, and AC Nexus does not treat it as a
// soft failure: its platform-init chain logs "Request failed" and the loading->menu
// transition aborts back to the loading loop. So we COMPLETE the request instead,
// with an opaque offline token. With KL_NET_OFFLINE the token is never exchanged
// against a server; the only point is that the request the game gates its own menu
// on RESOLVES. Read back through ovr_Message_GetString, like CloudStorage2's path.
static uint64_t klplat_User_GetAccessToken(void) {
    plat_hit("ovr_User_GetAccessToken");
    static const char tok[] = "OCACkleptonOfflineAccessToken000000000000";
    return klplat_request_str("ovr_User_GetAccessToken",
                              KLPLAT_MSG_ACCESS_TOKEN, 0, tok);
}

// Achievement *definitions* — the catalogue the game's achievement manager reads
// at startup. No Oculus service here defines any, so the honest answer is an EMPTY
// set, the same shape ovr_AssetFile_GetList's empty list takes. Delivered as a
// completed request (IsError false, an AchievementDefinitionArray of size 0) rather
// than as 0/"request could not be made", because AC Nexus gates its menu on the
// request resolving and a bare 0 lands it on the same "Request failed" path that
// aborts the transition. Achievements record what a player has DONE, not what they
// own, so an empty definition set invents no entitlement. The size-0 array is read
// through GetAchievementDefinitionArray (-> the message payload) and the existing
// Array_GetSize answer (plat_is_empty_array -> 0).
static uint64_t klplat_Achievements_GetAllDefinitions(void) {
    plat_hit("ovr_Achievements_GetAllDefinitions");
    return klplat_request("ovr_Achievements_GetAllDefinitions",
                          KLPLAT_MSG_ACHIEVEMENT_DEFS, 0);
}

// Who is signed in — the ASYNC request form (the synchronous ovr_GetLoggedInUserID
// is separate, below). Its completion is Message<User>. By DEFAULT we still answer
// 0, "the request could not be made", which is the offline path Beat Saber wants
// (see g_plat_request). But a title can run its online-init as a chain that ABORTS
// on a failed request: AC Nexus's log shows the Oculus entitlement check PASS and
// then this call fail with "Request failed", stranding it on the loading screen.
// KL_PLAT_USER opts such a title into a synthetic OFFLINE user so the chain
// completes. Not an ownership answer — entitlement is a separate request
// (klplat_Entitlement_GetIsViewerEntitled) that already passed — only "who is
// playing", which a real headset answers even with no network.
// Default ON for titles that HARD-QUIT on a failed login rather than falling
// back to offline. ZIX prints "Oculus Auth Failed! Quitting" and exits when
// GetLoggedInUser returns 0, so for it the synthetic offline user is not
// optional; the knob still overrides in either direction. Beat Saber and the
// rest keep the default-0 offline path (they tolerate no user).
static int klplat_user_default(void) {
    // Titles that ABORT when ovr_GetLoggedInUserID / GetLoggedInUser returns 0 —
    // they put up "Unable to get a valid UserID ... check you have an Entitlement"
    // and then FMessageDialog->abort on the game thread. A synthetic offline user
    // is strictly better for these: there is no Oculus service to sign in to, and
    // the alternative is a hard exit before the menu. Unity titles that read 0 as
    // "offline, carry on" are NOT in this list and keep the 0.
    // Walkabout is the Unity exception: it does not quit, it WAITS. XRRig logs
    // "WaitForPlatform(): Platform is not connected and or is not ready" and
    // re-asks GetLoggedInUser every few frames on a black screen, forever.
    // Moss does neither: with no user it carries on into its first room and
    // then dereferences the subtitle overlay AMossGameMode::CreateSubtitleOverlay
    // could not make without a primary player controller — a NULL read in
    // UGameSubtitleManager::NotifyRoomEnterBegin, about 630 frames in.
    // AC Nexus as a store install (x5812519008825194) is the chain described
    // above klplat_User_GetLoggedInUser: the entitlement check passes, this
    // request then fails with "An unknown error occurred. Request failed." and
    // the game never leaves its loading screen.
    // Maestro (x6963344583787383, UE4): UMaestroGameInstance binds its QuitGame
    // to the OnlineSubsystem's login-complete delegate; with no user the login
    // fails and the game calls FGenericPlatformMisc::RequestExit(true) — abort —
    // right after its first controller poll, before a frame is drawn.
    static const char *on[] = { "zix", "intotheradius", "redmatter2", "vampire", "twd2",
                                "walkabout", "moss", "x5812519008825194", "x6963344583787383" };
    const char *t = kl_driver_target_name();
    if (t) for (unsigned i = 0; i < sizeof on / sizeof on[0]; i++)
        if (strcmp(t, on[i]) == 0) return 1;
    return 0;
}
static uint64_t klplat_User_GetLoggedInUser(void) {
    plat_hit("ovr_User_GetLoggedInUser");
    if (!kl_env_on("KL_PLAT_USER", klplat_user_default())) {
        static int said;
        if (!said) { said = 1;
            fprintf(stderr, "  [plat] ovr_User_GetLoggedInUser -> 0 (no platform "
                    "user; set KL_PLAT_USER=1 for a synthetic offline user)\n"); }
        return 0;
    }
    return klplat_request("ovr_User_GetLoggedInUser", KLPLAT_MSG_LOGGED_IN_USER, 0);
}

// The User that completion carries. The message handle IS the user handle (one
// payload per message), and these read its fields. An offline user: a fixed
// non-zero ovrID — 0 would read as "no user" and defeat the point — and a plain
// name. Every other User field the SDK's model reads is optional, and NULL/0 is
// how it spells "absent" (see the launch-details note), so only these three are
// set; the rest answer 0 permissively and are never even reached unless
// KL_PLAT_USER handed out the user above.
static uint64_t klplat_User_GetID(const void *h) {
    plat_hit("ovr_User_GetID"); (void)h;
    return 1000000000000042ull;          // fixed, non-zero synthetic ovrID
}
static const char *klplat_User_GetOculusID(const void *h) {
    plat_hit("ovr_User_GetOculusID"); (void)h;
    return "kleptonplayer";
}
static const char *klplat_User_GetDisplayName(const void *h) {
    plat_hit("ovr_User_GetDisplayName"); (void)h;
    return "Klepton Player";
}
// The user's avatar picture. An empty URL is the SDK's "no image": Beat Saber
// 1.40 reads it as soon as KL_PLAT_USER hands out a user (just after the
// language screen) and draws its default avatar. Ours (not avp-play's NULL from
// plat_is_user_field): Beat Saber is measured with "", so it wins for these two.
static const char *klplat_User_GetImageUrl(const void *h) {
    plat_hit("ovr_User_GetImageUrl"); (void)h;
    return "";
}
static const char *klplat_User_GetSmallImageUrl(const void *h) {
    plat_hit("ovr_User_GetSmallImageUrl"); (void)h;
    return "";
}
// The rest of the User model, which the SDK's C# constructor reads in one go
// (Walkabout builds the whole object from the GetLoggedInUser completion): the
// profile pictures, the presence block, and the Quest-for-Business ManagedInfo.
// An offline user has none of them, and 0 is the SDK's own spelling of that — a
// NULL string, presence status Unknown, and a NULL ManagedInfo whose ten getters
// are then called on that NULL anyway and must answer the same.
static int plat_is_user_field(const char *name) {
    static const char *const f[] = {
        "ovr_User_GetImageUrl", "ovr_User_GetSmallImageUrl",
        "ovr_User_GetPresence", "ovr_User_GetPresenceStatus",
        "ovr_User_GetPresenceDeeplinkMessage", "ovr_User_GetPresenceDestinationApiName",
        "ovr_User_GetPresenceLobbySessionId", "ovr_User_GetPresenceMatchSessionId",
        "ovr_User_GetManagedInfo",
    };
    for (size_t i = 0; i < sizeof f / sizeof f[0]; i++)
        if (strcmp(name, f[i]) == 0) return 1;
    return strncmp(name, "ovr_ManagedInfo_Get", 19) == 0;
}
static uint64_t klplat_Entitlement_GetIsViewerEntitled(void) {
    plat_hit("ovr_Entitlement_GetIsViewerEntitled");
    return klplat_request("ovr_Entitlement_GetIsViewerEntitled",
                          KLPLAT_MSG_ENTITLEMENT, 0);
}

// Where the user's saves live — and the one member of the CloudStorage family
// that is answered rather than refused.
//
// The rest of that family stays refused, and the split is the same one the DRM
// line is drawn along: `ovr_CloudStorage_Load` / `_Save` move DATA to and from a
// service that is not here, so 0 ("the request could not be made") is the truth
// about them. This one moves no data at all. It asks where on the local
// filesystem the save directory IS — the directory the platform would later
// synchronise — and that is a question this host can answer completely.
//
// Refusing it is what a black launch screen looks like. SUPERHOT's
// `VRSaveManager::LoadAsync` chains its whole load off this request, so a 0
// leaves the SDK waiting on a completion it will never post: no save data, no
// scene, and the launch precache's own `ClearRenderTarget` command buffer parked
// on the camera in the meantime — which renders as black, forever, with every
// frame counter healthy. "A game that cannot reach the cloud writes locally" is
// only true if something tells it where local is.
//
// It is a REQUEST returning `Request<string>` (the SDK's `MessageWithString`),
// so the path arrives as a message payload read through ovr_Message_GetString —
// not as a return value. The type number is the guest's own, read out of the
// running IL2CPP runtime with KL_PROBE_ENUM like the three above it.
//
// The directory is created, and that is not a convenience: the guest calls its
// own IsDirectoryWritable on the answer before it uses it, and a path that does
// not exist fails that test — which is the same stall wearing a different hat.
// It sits beside the guest's files directory, so it is per-target and follows
// KL_FILES_DIR like everything else the guest writes.
static const char *klplat_cloud_dir(void) {
    static char dir[1024];
    if (!*dir) {
        const char *env = kl_env_str("KL_PLAT_CLOUD_DIR", NULL);
        if (env && *env) snprintf(dir, sizeof dir, "%s", env);
        else snprintf(dir, sizeof dir, "%s/cloudstorage", kl_jni_files_dir());
        mkdir(dir, 0755);
    }
    return dir;
}

static uint64_t klplat_CloudStorage2_GetUserDirectoryPath(void) {
    plat_hit("ovr_CloudStorage2_GetUserDirectoryPath");
    return klplat_request_str("ovr_CloudStorage2_GetUserDirectoryPath",
                              KLPLAT_MSG_CLOUD_DIR, 0, klplat_cloud_dir());
}

// The age category, and the ONE answer in this file that is a declaration
// rather than a measurement. See the completion-queue comment above: the user
// declared themselves over 18 and this reports it; nothing here discovered it.
// `Ad` is Oculus.Platform.AccountAgeCategory's own spelling, read out of the
// guest, and Beat Saber maps it to its `UserAgeCategory.Adult`.
static uint64_t klplat_UserAgeCategory_Get(void) {
    plat_hit("ovr_UserAgeCategory_Get");
    return klplat_request("ovr_UserAgeCategory_Get",
                          KLPLAT_MSG_AGE_CATEGORY, KLPLAT_AGE_ADULT);
}

// The application's own version, which is the one question in this family we can
// answer from something we actually have: the unpacked tree's apktool.yml, i.e.
// exactly what PackageManager already tells the guest. `OculusInit`'s
// GetAppVersionQuestAsync asks it during startup, behind the init completion.
//
// LATEST is answered as CURRENT, and that is a statement rather than a dodge:
// there is no store here to ask what the newest build is, and "the installed
// one is the newest one" is the only self-consistent thing to say — it means
// "no update available", which is true of this host in the only sense available
// to it. Reporting a HIGHER latest would advertise an update that cannot be
// fetched, which is what drives Application_StartAppDownload.
static uint64_t klplat_Application_GetVersion(void) {
    plat_hit("ovr_Application_GetVersion");
    return klplat_request("ovr_Application_GetVersion", KLPLAT_MSG_APP_VERSION, 0);
}

// Cancel an in-progress update download. Cave Crave asks it right after the
// version check above. GetVersion reports no update, so no download was ever
// started, and with no store there is nothing that could be cancelled: the
// request completes as an error, as cancelling a download that does not exist
// does — rather than a success claiming something was stopped.
static uint64_t klplat_Application_CancelAppDownload(void) {
    plat_hit("ovr_Application_CancelAppDownload");
    return klplat_request_err("ovr_Application_CancelAppDownload", KLPLAT_MSG_APP_CANCEL_DL);
}

// Leaderboards. Keep Talking and Nobody Explodes reads one when a bomb is picked
// from the binder, Eye of the Temple reads one while it starts, and both aborted
// here on the unimplemented trampoline. There is no leaderboard service on this
// host, so the read and the write complete as an error — what a Quest without a
// network says — rather than as an empty or accepted board that would claim a
// service answered. Nothing about ownership rides on a score.
//
// For every title: the two message types are the Platform SDK's own constants
// (ovrMessage_Leaderboard_GetEntries / _WriteEntry in OVR_MessageType.h), and
// they were read back identically from the global-metadata of both games, built
// years apart (Unity 2022.3 and 2019.4) — the same check that reproduces the
// Entitlement and User values above.
static uint64_t klplat_Leaderboard_GetEntries(const char *name, int limit,
                                              int filter, int start_at) {
    (void)name; (void)limit; (void)filter; (void)start_at;
    plat_hit("ovr_Leaderboard_GetEntries");
    return klplat_request_err("ovr_Leaderboard_GetEntries",
                              KLPLAT_MSG_LEADERBOARD_GET_ENTRIES);
}
static uint64_t klplat_Leaderboard_WriteEntry(const char *name, long long score,
                                              const void *extra, unsigned extra_size,
                                              int force) {
    (void)name; (void)score; (void)extra; (void)extra_size; (void)force;
    plat_hit("ovr_Leaderboard_WriteEntry");
    return klplat_request_err("ovr_Leaderboard_WriteEntry",
                              KLPLAT_MSG_LEADERBOARD_WRITE_ENTRY);
}

static uint64_t klplat_AppVersion_code(const void *h) {
    plat_hit("ovr_ApplicationVersion_GetCode");
    (void)h;
    long code = 0; kl_jni_guest_version(&code, NULL);
    return (uint64_t)(int64_t)code;
}
// The two fields of the same model we cannot answer from anything here. A
// release date and a download size are properties of a STORE listing, and there
// is no store; 0 is the SDK's own "not published" rather than a stand-in, and
// the model reads every field at construction whether or not it uses them.
static uint64_t klplat_AppVersion_unknown(const void *h) {
    plat_hit("ovr_ApplicationVersion_unknown_field");
    (void)h;
    return 0;
}

static const char *klplat_AppVersion_name(const void *h) {
    plat_hit("ovr_ApplicationVersion_GetName");
    (void)h;
    const char *name = NULL; kl_jni_guest_version(NULL, &name);
    return name ? name : "";
}

// The ASYNCHRONOUS init. Its completion is what everything else waits behind,
// so this is also where the platform becomes "up" for ovr_IsPlatformInitialized.
// Only the async spellings come here: the synchronous ones return a
// PlatformInitializeResult directly and keep their old answer.
static uint64_t klplat_init_async(const char *name) {
    plat_hit(name);
    g_platform_up = 1;
    return klplat_request(name, KLPLAT_MSG_PLATFORM_INIT, KLPLAT_INIT_SUCCESS);
}

static const char *const g_plat_init_async[] = {
    "ovr_UnityInitWrapperAsynchronous",
    "ovr_PlatformInitializeAndroidAsynchronous",
    "ovr_PlatformInitializeAndroidAsynchronousWithOptions",
    "ovr_PlatformInitializeWindowsAsynchronous",
};

static int plat_is_init_async(const char *name) {
    for (size_t i = 0; i < sizeof g_plat_init_async / sizeof g_plat_init_async[0]; i++)
        if (strcmp(g_plat_init_async[i], name) == 0) return 1;
    return 0;
}


// Unity's native plugin interface. Every entry point in it returns void, and the
// real platform loader uses them only to keep hold of the IUnityInterfaces
// registry and the render event queue — there is nothing here to bind either to.
// Taken as a group because it is one fixed interface Unity calls on every plugin,
// and the same group is already answered this way in kl_ovrp.c.
static uint64_t klplat_void(const char *name) {
    plat_hit(name);
    return 0;
}

static const char *const g_plat_unity[] = {
    "UnityPluginLoad", "UnityPluginUnload", "UnitySetEventQueue",
    "UnitySetGraphicsDevice", "UnityShaderCompilerExtEvent", "UnityRenderEvent",
    // The rendering-extension pair. UnityRenderingExtEvent is void; the Query
    // returns int, and 0 is the truthful answer — this plugin wants no
    // render-thread extension events, so Unity will never issue them.
    "UnityRenderingExtEvent", "UnityRenderingExtQuery",
    // Audio-plugin enumeration, dlsym'd speculatively by libunity's
    // AudioPluginManager on every plugin handle. A COUNT of effect definitions,
    // so 0 is "none here" — which is what the real loader says by not exporting
    // it. Same answer, same reasoning, as kl_ovrp.c's copy.
    "UnityGetAudioEffectDefinitions",
    // ovr_FreeMessage used to sit here, under "ovr_PopMessage never hands out a
    // message, so there is never anything to free". It does now, so it has a
    // real implementation above.
};

static int plat_is_unity_hook(const char *name) {
    for (size_t i = 0; i < sizeof g_plat_unity / sizeof g_plat_unity[0]; i++)
        if (strcmp(g_plat_unity[i], name) == 0) return 1;
    return 0;
}

// Platform initialisation. Note this is *not* one of the refused calls: asking to
// connect to the platform is not an ownership question, and it has a truthful
// answer here — it fails, because there is no com.oculus.horizon to connect to.
//
// An ovrRequest of 0 is the SDK's "the request could not be made". That is the
// honest report, and it lands the guest on an error path it already has: its own
// metadata carries "Oculus Platform failed to initialize." and "Initialize Error:
// Oculus platform failed to initialize due to exception."
//
// Returning a plausible request id instead would be a lie with a tail: the caller
// would then poll ovr_PopMessage forever for a completion that cannot come.
static uint64_t klplat_init_fails(const char *name) {
    plat_hit(name);
    static int said;
    if (!said) {
        said = 1;
        fprintf(stderr, "  [plat] %s -> 0 (no Oculus platform service on this host; "
                        "reporting failure rather than inventing success)\n", name);
    }
    return 0;
}

// ovr_UnityInitWrapper is NOT here — it is a bool, not an ovrRequest, and it has
// its own implementation above. It is the only one of these whose contract can
// report success without owing anybody a completion message.
static const char *const g_plat_init[] = {
    "ovr_UnityInitWrapperAsynchronous",
    "ovr_UnityInitWrapperStandalone", "ovr_UnityInitGlobals",
    "ovr_PlatformInitializeAndroid", "ovr_PlatformInitializeAndroidAsynchronous",
    "ovr_PlatformInitializeAndroidAsynchronousWithOptions",
    "ovr_PlatformInitializeWithAccessToken", "ovr_PlatformInitializeStandaloneOculus",
};

static int plat_is_init(const char *name) {
    for (size_t i = 0; i < sizeof g_plat_init / sizeof g_plat_init[0]; i++)
        if (strcmp(g_plat_init[i], name) == 0) return 1;
    return 0;
}

// Request-returning calls with the same truthful answer as init: 0, "the
// request could not be made", because there is no platform service to make it
// of. Answering with a fabricated request id would have the caller polling
// ovr_PopMessage for a completion that cannot come.
static const char *const g_plat_request[] = {
    // Walkabout's GetProductsBySKU / GetViewerPurchases are real functions in
    // g_plat_impl (file-backed). What remains here is the page walker and the
    // delta query: still "could not be made", still no extra grant.
    "ovr_IAP_GetNextProductArrayPage",
    "ovr_IAP_GetViewerPurchasesDeltaAsync",
    "ovr_RichPresence_Clear", "ovr_RichPresence_Set",
    "ovr_RichPresence_SetDestination", "ovr_RichPresence_SetIsJoinable",
    // Asking who is logged in is not an ownership question; with no platform
    // service the request cannot be made, which is what 0 says. Beat Saber
    // 1.28 takes its offline path from there (~swap 34k of the boot).
    "ovr_User_GetLoggedInUser",
    // The signed-in user's SOCIAL graph — friends, and the room/party a friend
    // is in. Pure social decoration, no ownership: with no platform service the
    // request cannot be made (0). Asgard's Wrath 2 walks this whole family right
    // after KL_PLAT_USER hands it a user; each is honestly "could not be made".
    "ovr_User_GetLoggedInUserFriends",
    "ovr_User_GetLoggedInUserFriendsAndRooms",
    "ovr_User_GetLoggedInUserFriendsV2",
    "ovr_User_GetNextUserArrayPage",
    "ovr_User_GetOrgScopedID",
    "ovr_User_LaunchFriendRequestFlow",
    "ovr_User_GetLoggedInUserManagedInfo",
};

// Whole families where EVERY entry point is request-returning, so the same
// answer is right for all of them and an exact list would only stop the run
// once per name for nothing.
//
//   ovr_Achievements_* — progress and definitions for achievements. All nine
//     calls (AddCount, AddFields, Unlock, GetAllDefinitions, GetAllProgress,
//     GetDefinitionsByName, GetProgressByName and the two ArrayPage walkers)
//     return an ovrRequest. This is not an ownership question: achievements
//     record what the player has done, not what they have bought, and 0 says
//     the request could not be made rather than reporting any progress. The
//     entitlement families are unaffected — plat_is_drm runs first.
//   ovr_GroupPresence_* — "who are you playing with", the multiplayer presence
//     the invite/roster panels read. Ownership does not enter into it, and the
//     trailing underscore keeps this clear of ovr_GroupPresenceOptions_* below,
//     which is a different shape entirely.
static const char *const g_plat_request_prefix[] = {
    "ovr_Achievements_", "ovr_GroupPresence_",
};

// ---------------------------------------------------------------------------
// Options objects: ovr_<Thing>Options_Create / _Set<Field> / _Destroy.
//
// Not requests and not queries — a local builder the caller fills in and then
// hands to a request call. Create returns an opaque handle, so 0 is the one
// answer that is NOT safe here: the guest would carry a NULL through to the
// setters, and on a real platform that is a null deref inside the library.
//
// We hand back a non-NULL cookie instead. Nothing reads it: the setters are
// no-ops because the request the options would feed cannot be made anyway
// (ovr_GroupPresence_Set and friends answer 0 above), so there is no state
// worth keeping and one shared cookie serves every live options object. That
// is invented behaviour in the narrow sense, but it invents no ANSWER — the
// guest learns nothing from it that it did not itself put in.
//
// Entitlement spellings never reach here: plat_is_drm runs first, so
// ovr_IAPOptions_* and the rest still refuse.
// Outbound-only calls: the guest hands us something and asks nothing back.
// Accepted and dropped, which is not a stub standing in for an answer — there
// is no answer involved. Same treatment as the haptics commands in kl_ovrp.c.
//
//   ovr_Log_NewEvent(name, ovrKeyValuePair *, count) — analytics. Telemetry
//     with no service behind it goes nowhere, and a headset that is not
//     attached to an Oculus account has nowhere to send it anyway.
//   ovr_Voip_SetMicrophoneMuted(ovrVoipMuteState) — the local mic gate for
//     in-game voice chat. RE4's OculusPlatform module pushes it during startup.
//     Nothing here captures audio at all — kl_aaudio refuses capture streams by
//     design and no microphone is presented — so there is no stream to mute and
//     nothing the guest can learn from the call. It is deliberately NOT filed
//     with the enumeration-answers-none group: those state an absence, and this
//     one is a command with no reply.
static const char *const g_plat_drop[] = {
    "ovr_Log_NewEvent",
    "ovr_Voip_SetMicrophoneMuted",
};

static int plat_is_drop(const char *name) {
    for (size_t i = 0; i < sizeof g_plat_drop / sizeof g_plat_drop[0]; i++)
        if (strcmp(g_plat_drop[i], name) == 0) return 1;
    return 0;
}

static const char g_options_cookie[] = "klepton-ovr-options";

static uint64_t klplat_options_create(const char *name) {
    plat_hit(name);
    static int said;
    if (!said) {
        said = 1;
        fprintf(stderr, "  [plat] %s -> opaque cookie (options objects are local "
                        "state; the request they feed cannot be made)\n", name);
    }
    return (uint64_t)(uintptr_t)g_options_cookie;
}

static int plat_is_options_create(const char *name) {
    return strstr(name, "Options_Create") != NULL;
}

// ---------------------------------------------------------------------------
// Launch details: HOW the app was started.
//
// Not a request — a plain accessor returning an opaque handle that the managed
// SDK immediately picks apart, reading a dozen ovr_LaunchDetails_* fields off it
// in `Models.LaunchDetails`'s constructor. SUPERHOT asks while building its main
// scene.
//
// The truthful answer is "normally, by the user, with nothing attached": no
// deeplink message, no destination, no room, no invited users, LaunchType 0
// (Unknown). That is precisely what every accessor answers below, because 0 is
// simultaneously the zero enum, the zero integer and the NULL pointer — and the
// SDK null-checks each optional list before wrapping it, so NULL is how it
// spells "there was none", not a hole.
//
// The handle itself must be NON-NULL for the same reason the options cookie is:
// it is carried straight into those accessors, and on a real platform a NULL
// there is a null dereference inside the library rather than an empty answer.
static const char g_launch_cookie[] = "klepton-launch-details";

static uint64_t klplat_launch_details(const char *name) {
    plat_hit(name);
    static int said;
    if (!said) {
        said = 1;
        fprintf(stderr, "  [plat] %s -> opaque handle: launched normally, by the "
                        "user, with nothing attached (no deeplink, no destination, "
                        "no invited users)\n", name);
    }
    return (uint64_t)(uintptr_t)g_launch_cookie;
}

static uint64_t klplat_launch_field(const char *name) {
    plat_hit(name);
    return 0;                 // the zero enum, the zero int and NULL, all at once
}

static int plat_is_launch_details(const char *name) {
    return strcmp(name, "ovr_ApplicationLifecycle_GetLaunchDetails") == 0;
}

static int plat_is_launch_field(const char *name) {
    return strncmp(name, "ovr_LaunchDetails_", 18) == 0;
}

// ...and the empty ARRAY that a NULL list handle turns into one call later.
//
// The managed `DeserializableList<T>` reads three things off a list handle —
// GetSize, GetElement and GetNextUrl — and this SDK version wraps the pointer
// WITHOUT null-checking it first, so answering ovr_LaunchDetails_GetUsers with
// NULL (correctly: nobody was invited) still ends in ovr_UserArray_GetSize(NULL)
// one call later. Size 0 is the same answer the NULL was: there is nobody in it.
//
// GetElement is deliberately NOT here. It can only be reached on an array with
// elements, which is an array we did not produce, so it keeps the fail-closed
// default and would stop the run by name rather than hand back a User the guest
// would then read fields off.
static int plat_is_empty_array(const char *name) {
    const char *p = strstr(name, "Array_Get");
    if (!p) return 0;
    return strcmp(p, "Array_GetSize") == 0 || strcmp(p, "Array_GetNextUrl") == 0;
}

static uint64_t klplat_empty_array(const char *name) {
    plat_hit(name);
    return 0;                 // no elements, and no next page to fetch them from
}

// The setters and the destructor. Both are genuinely nothing to do, not stubs
// standing in for something: there is no options state to keep.
static int plat_is_options_sink(const char *name) {
    return strstr(name, "Options_Destroy") != NULL ||
           strstr(name, "Options_Set") != NULL;
}

static int plat_is_request(const char *name) {
    for (size_t i = 0; i < sizeof g_plat_request / sizeof g_plat_request[0]; i++)
        if (strcmp(g_plat_request[i], name) == 0) return 1;
    for (size_t i = 0; i < sizeof g_plat_request_prefix / sizeof g_plat_request_prefix[0]; i++)
        if (strncmp(name, g_plat_request_prefix[i],
                    strlen(g_plat_request_prefix[i])) == 0) return 1;
    return 0;
}

// Who is signed in — the C SDK's synchronous accessor, not a request. It
// returns an `ovrID`, and 0 is that type's own "no such user": the managed side
// spells the same thing `User == null`, and every caller of it null-checks,
// because a user really can be absent on a real headset (offline, or before the
// platform has initialized).
//
// Not an ownership question and not a request, so neither classifier is right
// for it: `ovr_User_GetLoggedInUser` beside them is the ASYNC form and correctly
// answers "the request could not be made", while this one is asked and answered
// on the spot. RE4 asks during engine init.
static uint64_t klplat_GetLoggedInUserID(void) {
    plat_hit("ovr_GetLoggedInUserID");
    // KL_PLAT_USER opts a title into a synthetic OFFLINE user, the same switch
    // klplat_User_GetLoggedInUser reads for the async form. Some titles gate boot
    // on "is anyone signed in?" and ForceQuit when this returns 0 — Asgard's
    // Wrath 2 does exactly that (ovr_PlatformInitializeAndroid succeeds,
    // ovr_GetLoggedInUserID == 0, then AndroidThunkJava_ForceQuit). The ID is
    // the SAME synthetic ovrID ovr_User_GetID hands back, so the sync and async
    // views of "who is playing" agree. This is a session identity, NOT an
    // ownership answer: entitlement stays a separate request
    // (ovr_Entitlement_GetIsViewerEntitled) that still returns "could not be
    // made" and grants nothing. The default is the per-target one — the SAME
    // klplat_user_default() the async form reads — so a title that fatals on a
    // 0 here (Into the Radius, Red Matter 2: "Unable to get a valid UserID")
    // gets the synthetic id without a flag, while titles fine with 0 (RE4) keep
    // it. Previously this hardcoded 0 and only the async form honoured the
    // per-target default, so the sync callers still fatalled.
    if (kl_env_on("KL_PLAT_USER", klplat_user_default())) {
        static int saidu;
        if (!saidu) { saidu = 1;
            fprintf(stderr, "  [plat] ovr_GetLoggedInUserID -> synthetic offline "
                    "user (KL_PLAT_USER=1); NOT an entitlement grant\n"); }
        return 1000000000000042ull;   // == klplat_User_GetID's synthetic ovrID
    }
    static int said;
    if (!said) {
        said = 1;
        fprintf(stderr, "  [plat] ovr_GetLoggedInUserID -> 0 (no platform user; "
                        "there is no service here to be signed in to; set "
                        "KL_PLAT_USER=1 for a synthetic offline user)\n");
    }
    return 0;
}

// ovr_GetLoggedInUserLocale — a SYNCHRONOUS getter (returns const char*, not an
// ovrRequest), the locale the store would report for the signed-in user. There
// is no platform user here, but the guest reads the string to pick a language,
// and a NULL would crash the read — so answer the host's, defaulting to en_US.
static uint64_t klplat_GetLoggedInUserLocale(void) {
    plat_hit("ovr_GetLoggedInUserLocale");
    static char loc[16];
    if (!loc[0]) {
        const char *lang = getenv("LANG");            // e.g. "en_US.UTF-8"
        int i = 0;
        if (lang) for (; lang[i] && lang[i] != '.' && i < (int)sizeof loc - 1; i++) loc[i] = lang[i];
        if (i == 0) { loc[0]='e'; loc[1]='n'; loc[2]='_'; loc[3]='U'; loc[4]='S'; i=5; }
        loc[i] = '\0';
    }
    return (uint64_t)(uintptr_t)loc;
}

// The real libovrplatformloader exports JNI_OnLoad and caches the JavaVM out of
// it. Ours has no JNI surface to set up, so the whole body is the version
// number Android checks for.
//
// Reached only because System.load() now honours the Android contract and calls
// JNI_OnLoad on what it loaded (kl_jni.c). Before that, this library was
// dlopen'd and never initialized, and nothing noticed — which is exactly the
// bug that change fixes, so this is the cost of fixing it rather than a
// workaround. Answering the version is not a stub: a library that returns an
// unrecognised version is one that REFUSED to initialize, and Android unloads it.
//
// Below plat_is_drm in kl_ovrplat_sym, like everything in this table, so the
// entitlement classifier still runs first and this cannot be a way around it.
static uint64_t klplat_JNI_OnLoad(void *vm, void *reserved) {
    (void)vm; (void)reserved;
    plat_hit("JNI_OnLoad");
    return 0x00010006;                 // JNI_VERSION_1_6
}

static const struct { const char *name; void *fn; } g_plat_impl[] = {
    {"JNI_OnLoad",                (void *)klplat_JNI_OnLoad},
    {"ovr_IsPlatformInitialized", (void *)klplat_IsPlatformInitialized},
    {"ovr_GetLoggedInUserID",     (void *)klplat_GetLoggedInUserID},
    {"ovr_GetLoggedInUserLocale", (void *)klplat_GetLoggedInUserLocale},
    {"ovr_UnityInitWrapper",      (void *)klplat_UnityInitWrapper},
    {"ovr_PopMessage",            (void *)klplat_PopMessage},
    {"ovr_FreeMessage",           (void *)klplat_FreeMessage},
    {"ovr_Entitlement_GetIsViewerEntitled", (void *)klplat_Entitlement_GetIsViewerEntitled},
    {"ovr_UserAgeCategory_Get",   (void *)klplat_UserAgeCategory_Get},
    {"ovr_Application_GetVersion",(void *)klplat_Application_GetVersion},
    {"ovr_Application_CancelAppDownload", (void *)klplat_Application_CancelAppDownload},
    {"ovr_Message_GetApplicationVersion",      (void *)klplat_Message_GetPayload},
    {"ovr_AssetFile_GetList",                  (void *)klplat_AssetFile_GetList},
    {"ovr_AssetFile_StatusByName",             (void *)klplat_AssetFile_StatusByName},
    {"ovr_AssetFile_StatusByName_Native",      (void *)klplat_AssetFile_StatusByName},
    {"ovr_AssetFile_StatusById",               (void *)klplat_AssetFile_StatusById},
    {"ovr_Message_GetAssetFileDeliveryList",   (void *)klplat_Message_GetPayload},
    {"ovr_AssetFileDeliveryList_GetSize",      (void *)klplat_AssetFileDeliveryList_GetSize},
    // GetList's readers. The array is empty for every title but Walkabout; there
    // it is the courses whose real bundles are on disk. Download stays refused.
    {"ovr_Message_GetAssetDetailsArray",       (void *)klplat_Message_GetPayload},
    {"ovr_Message_GetAssetDetails",            (void *)klplat_Message_GetAssetDetails},
    {"ovr_AssetDetailsArray_GetSize",          (void *)klplat_AssetDetailsArray_GetSize},
    {"ovr_AssetDetailsArray_GetElement",       (void *)klplat_AssetDetailsArray_GetElement},
    {"ovr_AssetDetails_GetAssetId",            (void *)klplat_AssetDetails_GetAssetId},
    {"ovr_AssetDetails_GetAssetType",          (void *)klplat_AssetDetails_GetAssetType},
    {"ovr_AssetDetails_GetAssetType_Native",   (void *)klplat_AssetDetails_GetAssetType},
    {"ovr_AssetDetails_GetDownloadStatus",     (void *)klplat_AssetDetails_GetDownloadStatus},
    {"ovr_AssetDetails_GetDownloadStatus_Native", (void *)klplat_AssetDetails_GetDownloadStatus},
    {"ovr_AssetDetails_GetFilepath",           (void *)klplat_AssetDetails_GetFilepath},
    {"ovr_AssetDetails_GetFilepath_Native",    (void *)klplat_AssetDetails_GetFilepath},
    {"ovr_AssetDetails_GetIapStatus",          (void *)klplat_AssetDetails_GetIapStatus},
    {"ovr_AssetDetails_GetIapStatus_Native",   (void *)klplat_AssetDetails_GetIapStatus},
    {"ovr_AssetDetails_GetMetadata",           (void *)klplat_AssetDetails_GetMetadata},
    // Walkabout purchases, one per store id of a course with a real bundle.
    // Any other title hits the function and gets request id 0.
    {"ovr_IAP_GetViewerPurchases",             (void *)klplat_IAP_GetViewerPurchases},
    {"ovr_IAP_GetViewerPurchasesDurableCache", (void *)klplat_IAP_GetViewerPurchasesDurableCache},
    {"ovr_IAP_GetProductsBySKU",               (void *)klplat_IAP_GetProductsBySKU},
    {"ovr_Message_GetPurchaseArray",           (void *)klplat_Message_GetPurchaseArray},
    {"ovr_PurchaseArray_GetSize",              (void *)klplat_PurchaseArray_GetSize},
    {"ovr_PurchaseArray_GetElement",           (void *)klplat_PurchaseArray_GetElement},
    {"ovr_Purchase_GetSKU",                    (void *)klplat_Purchase_GetSKU},
    {"ovr_Purchase_GetSKU_Native",             (void *)klplat_Purchase_GetSKU},
    {"ovr_Purchase_GetPurchaseID",             (void *)klplat_Purchase_GetPurchaseID},
    {"ovr_Purchase_GetPurchaseStrID",          (void *)klplat_Purchase_GetPurchaseStrID},
    {"ovr_Purchase_GetPurchaseStrID_Native",   (void *)klplat_Purchase_GetPurchaseStrID},
    {"ovr_Purchase_GetGrantTime",              (void *)klplat_Purchase_GetGrantTime},
    {"ovr_Purchase_GetExpirationTime",         (void *)klplat_Purchase_GetExpirationTime},
    {"ovr_Purchase_GetDeveloperPayload",       (void *)klplat_Purchase_GetDeveloperPayload},
    {"ovr_Purchase_GetReportingId",            (void *)klplat_Purchase_GetReportingId},
    {"ovr_Purchase_GetReportingId_Native",     (void *)klplat_Purchase_GetReportingId},
    {"ovr_Message_GetProductArray",            (void *)klplat_Message_GetProductArray},
    {"ovr_ProductArray_GetSize",               (void *)klplat_ProductArray_GetSize},
    {"ovr_ProductArray_GetElement",            (void *)klplat_ProductArray_GetElement},
    {"ovr_Product_GetSKU",                     (void *)klplat_Product_GetSKU},
    {"ovr_Product_GetSKU_Native",              (void *)klplat_Product_GetSKU},
    {"ovr_Product_GetName",                    (void *)klplat_Product_GetName},
    {"ovr_Product_GetDescription",             (void *)klplat_Product_GetDescription},
    {"ovr_Product_GetPrice",                   (void *)klplat_Product_GetPrice},
    {"ovr_Product_GetFormattedPrice",          (void *)klplat_Product_GetFormattedPrice},
    // The user access token and the achievement catalogue — two request-style
    // calls the game issues during platform init and gates its menu on. Both
    // complete with benign, empty/offline data (see the handlers above) rather
    // than the bare 0 that lands the guest on its "Request failed" path. The
    // exact-match binding here overrides the ovr_Achievements_ prefix rule.
    {"ovr_User_GetAccessToken",                (void *)klplat_User_GetAccessToken},
    {"ovr_Achievements_GetAllDefinitions",     (void *)klplat_Achievements_GetAllDefinitions},
    // Leaderboards: error completions (see the handlers).
    {"ovr_Leaderboard_GetEntries",             (void *)klplat_Leaderboard_GetEntries},
    {"ovr_Leaderboard_WriteEntry",             (void *)klplat_Leaderboard_WriteEntry},
    {"ovr_Message_GetAchievementDefinitionArray", (void *)klplat_Message_GetPayload},
    // The logged-in user (async) and the User accessors its completion feeds.
    // Gated by KL_PLAT_USER inside the handler; the accessors are inert unless a
    // user was handed out. The exact-match binding overrides ovr_User_GetLoggedInUser's
    // entry in g_plat_request.
    {"ovr_User_GetLoggedInUser",               (void *)klplat_User_GetLoggedInUser},
    {"ovr_Message_GetUser",                    (void *)klplat_Message_GetPayload},
    {"ovr_User_GetID",                         (void *)klplat_User_GetID},
    {"ovr_User_GetOculusID",                   (void *)klplat_User_GetOculusID},
    {"ovr_User_GetDisplayName",                (void *)klplat_User_GetDisplayName},
    {"ovr_User_GetImageUrl",                   (void *)klplat_User_GetImageUrl},
    {"ovr_User_GetSmallImageUrl",              (void *)klplat_User_GetSmallImageUrl},
    {"ovr_ApplicationVersion_GetCurrentCode",  (void *)klplat_AppVersion_code},
    {"ovr_ApplicationVersion_GetLatestCode",   (void *)klplat_AppVersion_code},
    {"ovr_ApplicationVersion_GetCurrentName",  (void *)klplat_AppVersion_name},
    {"ovr_ApplicationVersion_GetLatestName",   (void *)klplat_AppVersion_name},
    {"ovr_ApplicationVersion_GetReleaseDate",  (void *)klplat_AppVersion_unknown},
    {"ovr_ApplicationVersion_GetSize",         (void *)klplat_AppVersion_unknown},
    // The message accessors. Each takes the handle in x0, so they cannot go
    // through a named trampoline — see the note above klplat_Message_GetType.
    {"ovr_Message_GetType",       (void *)klplat_Message_GetType},
    // "The native message" is this message — the SDK keeps the handle around to
    // hand back to callers that want the raw pointer, and there is nothing
    // behind ours that it is not already holding.
    {"ovr_Message_GetNativeMessage", (void *)klplat_Message_GetPayload},
    {"ovr_Message_IsError",       (void *)klplat_Message_IsError},
    {"ovr_Message_GetError",      (void *)klplat_Message_GetError},
    {"ovr_Error_GetCode",         (void *)klplat_Error_GetCode},
    {"ovr_Error_GetHttpCode",     (void *)klplat_Error_GetHttpCode},
    {"ovr_Error_GetMessage",      (void *)klplat_Error_GetMessage},
    {"ovr_Error_GetDisplayableMessage", (void *)klplat_Error_GetDisplayableMessage},
    {"ovr_IAP_LaunchCheckoutFlow", (void *)klplat_IAP_LaunchCheckoutFlow},
    // Language-pack status (batman). The AssetFile/AssetDetails names share the
    // course entries above and branch on plat_is_langpack_target(); these four
    // exist only for language packs.
    {"ovr_AssetDetails_GetLanguage",       (void *)klplat_AssetDetails_GetLanguage_any},
    // A pack download (langpack targets only; any other title still refuses
    // inside the handler, and these readers are reached only from its messages).
    {"ovr_AssetFile_DownloadById",          (void *)klplat_AssetFile_DownloadById},
    {"ovr_AssetFile_DownloadByName",        (void *)klplat_AssetFile_DownloadByName},
    {"ovr_AssetFile_DownloadByName_Native", (void *)klplat_AssetFile_DownloadByName},
    {"ovr_Message_GetAssetFileDownloadResult", (void *)klplat_langpack_Message_GetObj},
    {"ovr_Message_GetAssetFileDownloadUpdate", (void *)klplat_langpack_Message_GetObj},
    {"ovr_AssetFileDownloadResult_GetAssetId",  (void *)klplat_langpack_dl_id},
    {"ovr_AssetFileDownloadResult_GetFilepath", (void *)klplat_langpack_dl_path},
    {"ovr_AssetFileDownloadResult_GetFilepath_Native", (void *)klplat_langpack_dl_path},
    {"ovr_AssetFileDownloadUpdate_GetAssetFileId", (void *)klplat_langpack_dl_id},
    {"ovr_AssetFileDownloadUpdate_GetAssetId",  (void *)klplat_langpack_dl_id},
    {"ovr_AssetFileDownloadUpdate_GetBytesTotal",          (void *)klplat_langpack_dl_bytes},
    {"ovr_AssetFileDownloadUpdate_GetBytesTotalLong",      (void *)klplat_langpack_dl_bytes},
    {"ovr_AssetFileDownloadUpdate_GetBytesTransferred",    (void *)klplat_langpack_dl_bytes},
    {"ovr_AssetFileDownloadUpdate_GetBytesTransferredLong",(void *)klplat_langpack_dl_bytes},
    {"ovr_AssetFileDownloadUpdate_GetCompleted",           (void *)klplat_langpack_dl_completed},
    {"ovr_LanguagePackInfo_GetEnglishName", (void *)klplat_LanguagePackInfo_tag},
    {"ovr_LanguagePackInfo_GetNativeName",  (void *)klplat_LanguagePackInfo_tag},
    {"ovr_LanguagePackInfo_GetTag",         (void *)klplat_LanguagePackInfo_tag},
    {"ovr_Message_GetRequestID",  (void *)klplat_Message_GetRequestID},
    {"ovr_Message_GetPlatformInitialize",      (void *)klplat_Message_GetPayload},
    {"ovr_PlatformInitialize_GetResult",       (void *)klplat_payload_int},
    {"ovr_Message_GetUserAccountAgeCategory",  (void *)klplat_Message_GetPayload},
    {"ovr_UserAccountAgeCategory_GetAgeCategory", (void *)klplat_payload_int},
    // The string payload, and the one request that carries one.
    {"ovr_Message_GetString",     (void *)klplat_Message_GetString},
    {"ovr_CloudStorage2_GetUserDirectoryPath",
                                  (void *)klplat_CloudStorage2_GetUserDirectoryPath},
};

static const char g_plat_handle[] = "klepton-ovrplatformloader";

int kl_ovrplat_claims(const char *soname) {
    if (!soname) return 0;
    const char *b = strrchr(soname, '/');
    b = b ? b + 1 : soname;
    return strcmp(b, "libovrplatformloader.so") == 0 ||
           strcmp(b, "ovrplatformloader") == 0;
}

void *kl_ovrplat_dlopen(const char *soname) {
    if (!kl_ovrplat_claims(soname)) return NULL;
    const char *b = strrchr(soname, '/');
    b = b ? b + 1 : soname;
    fprintf(stderr, "  [plat] guest dlopen(\"%s\") -> synthetic Oculus Platform "
                    "(the real one forwards to com.oculus.horizon, which is not "
                    "here; see kl_ovrplat.h)\n", b);
    return (void *)g_plat_handle;
}

int kl_ovrplat_is_handle(const void *h) { return h == (const void *)g_plat_handle; }

void *kl_ovrplat_sym(const char *name) {
    if (!name) return NULL;
    int s = plat_slot(name);                    // resolved, whatever happens next

    // Classified at *resolve* time as well as call time, so kl_ovrplat_report can
    // show what the guest went looking for even on a run where nothing aborted.
    // Resolving is still only a measurement — the refusal is at the call.
    if (plat_is_drm(name)) {
        if (s >= 0) g_plat[s].drm = 1;
        return kl_named_stub(name, (void *)klplat_drm);
    }
    for (size_t i = 0; i < sizeof g_plat_impl / sizeof g_plat_impl[0]; i++)
        if (strcmp(g_plat_impl[i].name, name) == 0) return g_plat_impl[i].fn;
    if (plat_is_unity_hook(name))
        return kl_named_stub(name, (void *)klplat_void);
    if (plat_is_drop(name))
        return kl_named_stub(name, (void *)klplat_void);
    if (plat_is_options_create(name))
        return kl_named_stub(name, (void *)klplat_options_create);
    if (plat_is_launch_details(name))
        return kl_named_stub(name, (void *)klplat_launch_details);
    if (plat_is_launch_field(name))
        return kl_named_stub(name, (void *)klplat_launch_field);
    if (plat_is_empty_array(name))
        return kl_named_stub(name, (void *)klplat_empty_array);
    if (plat_is_options_sink(name))
        return kl_named_stub(name, (void *)klplat_void);
    if (plat_is_init_async(name))
        return kl_named_stub(name, (void *)klplat_init_async);
    if (plat_is_absent_ok(name) || plat_is_init(name) || plat_is_request(name) ||
        plat_is_user_field(name))
        return kl_named_stub(name, (void *)klplat_init_fails);
    return kl_named_stub(name, (void *)klplat_called);
}

void kl_ovrplat_report(FILE *f) {
    static int done;
    if (done || !g_nplat) return;
    done = 1;
    unsigned called = 0, drm = 0;
    for (unsigned i = 0; i < g_nplat; i++) {
        if (g_plat[i].calls) called++;
        if (g_plat[i].drm)   drm++;
    }
    fprintf(f, "\n=== Oculus Platform surface ===\n");
    fprintf(f, "  resolved: %u, of which called: %u\n", g_nplat, called);
    if (drm) {
        fprintf(f, "  --- entitlement / ownership (REFUSED by policy) ---\n");
        for (unsigned i = 0; i < g_nplat; i++)
            if (g_plat[i].drm)
                fprintf(f, "    %-52s %s\n", g_plat[i].name,
                        g_plat[i].calls ? "CALLED" : "resolved only");
        fprintf(f, "  (%u DRM call%s refused)\n", g_drm_calls, g_drm_calls == 1 ? "" : "s");
    }
    fprintf(f, "  --- called ---\n");
    for (unsigned i = 0; i < g_nplat; i++)
        if (g_plat[i].calls && !g_plat[i].drm)
            fprintf(f, "    %-52s x%u\n", g_plat[i].name, g_plat[i].calls);
    fprintf(f, "  --- resolved but never called ---\n");
    for (unsigned i = 0; i < g_nplat; i++)
        if (!g_plat[i].calls && !g_plat[i].drm) fprintf(f, "    %s\n", g_plat[i].name);
}
