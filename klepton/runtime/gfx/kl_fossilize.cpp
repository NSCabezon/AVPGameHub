// kl_fossilize.cpp — the guest's Vulkan pipelines, recorded and replayed with Valve's Fossilize.
//
// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox) klepton/runtime/linux/kl_fossilize.cpp
// Fossilize: github.com/ValveSoftware/Fossilize (MIT), fetched by `make fossilize` into
// vendor-fossilize/ at a pinned revision; not part of this repository.
//
// Source 2 creates its pipelines lazily, one at a time as new views appear, and through MoltenVK
// a pipeline the Metal compiler has not seen costs 330-580 ms (a walk into a new area froze the
// frame for up to 9 s). The OS Metal cache keeps compiled pipelines across launches, so the fix
// is to have compiled everything BEFORE the guest asks:
//
//   KL_FOZ_RECORD=<file.foz>   record every sampler, set/pipeline layout, shader module, render
//       pass and pipeline the guest creates (its own create infos), appending to a Fossilize
//       stream archive. Flushed per record (KL_FOZ_RECORD_SYNC=0: a background writer).
//   KL_FOZ_REPLAY=<file.foz|dir>[:...]   at vkCreateDevice, replay those databases on
//       KL_FOZ_THREADS threads (default 4) through the layer's own entry points, so each
//       pipeline goes through the same fix-ups and MoltenVK state as the guest's and produces
//       the same MSL, which is what the Metal cache is keyed on. Each replayed pipeline is
//       destroyed at once; only the warm cache is kept. In the background by default;
//       KL_FOZ_REPLAY_BLOCK=1 holds vkCreateDevice until it is done.
//   KL_FOZ_PREWARM=<file.foz|dir>[:...]   (kl_foz_prewarm_env, called just before the guest
//       boots) the same replay, blocking, on a device of our own made as the game makes its own
//       (device-info.json, KL_VK_DEVICE_INFO), retired before the guest starts.
//
// Foveation (KL_FOVEATE=1 with the MoltenVK FDM fork): the game then creates each scene-pass
// pipeline with VK_PIPELINE_CREATE_RENDERING_FRAGMENT_DENSITY_MAP_ATTACHMENT_BIT_EXT, and the
// fork compiles those with a gl_FragCoord remap: different MSL, a Metal cache miss, a stall per
// pipeline even after a warm replay (device, 2026-10-11: 259 stalls, ~101 s, with the prewarm
// warm). A recording made with foveation shows those pipelines are the .foz's own with only
// that flag added, so the replay compiles each multisampled multiview dynamic-rendering
// pipeline twice, with and without it (fdm_twin). Without foveation the flag would compile to
// the same MSL as the plain pipeline, so no twin is made. KL_FOZ_FDM=0 turns the twins off.
//
//   KL_FOZ_AUTORECORD=<dir>   (the hub, with "Precompilar gráficos") each session records into
//       <dir>/session.N.foz ONLY what no known database has (a Fossilize concurrent database
//       over the KL_FOZ_PREWARM list and <dir>'s earlier files), and the prewarm replays
//       KL_FOZ_PREWARM + every <dir>/*.foz, so each session makes the next one smoother. Over
//       KL_FOZ_RECORD_KEEP files (default 8) the sessions are merged into <dir>/merged.foz;
//       over KL_FOZ_RECORD_MAX_MB (default 256) in <dir> nothing more is recorded. An explicit
//       KL_FOZ_RECORD wins; KL_FOZ_AUTORECORD=0 is off.
//
// Neither set: kl_fossilize_install installs nothing and the layer's hooks stay NULL.
#include "fossilize.hpp"
#include "fossilize_db.hpp"
#include "rapidjson/document.h"
#include <vulkan/vulkan.h>
#include "kl_vk_pipe_hooks.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <dirent.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

using namespace Fossilize;

namespace {

double now_s() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

bool knob_on(const char *v) { return v && *v && strcmp(v, "0"); }

// ---- recording ---------------------------------------------------------------------------
StateRecorder *g_rec;
DatabaseInterface *g_rec_db;
std::atomic<unsigned> g_rec_pipes{0}, g_rec_fail{0};

// Replay progress for a loading screen (kl_foz_progress): pipelines listed so far, pipelines
// compiled (or failed) so far, and the state: 0 no replay, 1 replaying, 2 done.
std::atomic<unsigned> g_prog_total{0}, g_prog_done{0};
std::atomic<int> g_prog_state{0};
std::atomic<double> g_prog_t0{0};
// Pipelines compiled and those over 100 ms, over every database of one prewarm.
std::atomic<unsigned> g_sum_compiled{0}, g_sum_slow{0};

// Records into `db` (a stream archive, or KL_FOZ_AUTORECORD's concurrent database); takes it.
void rec_start(DatabaseInterface *db, const char *path) {
    g_rec_db = db;
    if (!g_rec_db || !g_rec_db->prepare()) {
        fprintf(stderr, "  [foz] cannot open %s for recording; recording off\n", path);
        delete g_rec_db;
        g_rec_db = nullptr;
        return;
    }
    g_rec = new StateRecorder;
    g_rec->set_database_enable_compression(true);
    g_rec->set_database_enable_checksum(true);
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, nullptr, "hlvr", 1, "Source2", 1, VK_API_VERSION_1_1 };
    if (!g_rec->record_application_info(app)) fprintf(stderr, "  [foz] application info not recorded\n");
    // Synchronized by default: each record is written and flushed before the create returns, so
    // a crash loses nothing (Glovebox lost queued records to server crashes with the thread).
    bool sync = !(getenv("KL_FOZ_RECORD_SYNC") && !strcmp(getenv("KL_FOZ_RECORD_SYNC"), "0"));
    if (sync) g_rec->init_recording_synchronized(g_rec_db);
    else g_rec->init_recording_thread(g_rec_db);
    fprintf(stderr, "  [foz] recording the guest's pipelines to %s (%s)\n", path,
            sync ? "synchronized: flushed per record" : "recording thread");
}

void rec_init(const char *path) { rec_start(create_stream_archive_database(path, DatabaseMode::Append), path); }

bool fdm_twin(const VkGraphicsPipelineCreateInfo *ci);

void note_pipe(bool ok) {
    unsigned n = ok ? ++g_rec_pipes : g_rec_pipes.load();
    if (!ok) ++g_rec_fail;
    if (ok && (n & (n - 1)) == 0 && n >= 64)
        fprintf(stderr, "  [foz] %u pipelines recorded (%u refused)\n", n, g_rec_fail.load());
}

void h_sampler(VkSampler h, const VkSamplerCreateInfo *ci) { if (g_rec) (void)g_rec->record_sampler(h, *ci); }
void h_set_layout(VkDescriptorSetLayout h, const VkDescriptorSetLayoutCreateInfo *ci) { if (g_rec) (void)g_rec->record_descriptor_set_layout(h, *ci); }
void h_pipeline_layout(VkPipelineLayout h, const VkPipelineLayoutCreateInfo *ci) { if (g_rec) (void)g_rec->record_pipeline_layout(h, *ci); }
void h_shader_module(VkShaderModule h, const VkShaderModuleCreateInfo *ci) { if (g_rec) (void)g_rec->record_shader_module(h, *ci); }
void h_render_pass(VkRenderPass h, const VkRenderPassCreateInfo *ci) { if (g_rec) (void)g_rec->record_render_pass(h, *ci); }
void h_render_pass2(VkRenderPass h, const VkRenderPassCreateInfo2 *ci) { if (g_rec) (void)g_rec->record_render_pass2(h, *ci); }
void h_graphics_pipeline(VkPipeline h, const VkGraphicsPipelineCreateInfo *ci) {
    if (!g_rec) return;
    // A foveated pipeline is recorded as its plain self: the replay remakes the twin when
    // foveation is on (fdm_twin), and the plain one is what the .foz already holds (so it is
    // not recorded again) and what a run without foveation asks for.
    VkGraphicsPipelineCreateInfo plain;
    if (ci->flags & VK_PIPELINE_CREATE_RENDERING_FRAGMENT_DENSITY_MAP_ATTACHMENT_BIT_EXT) {
        plain = *ci;
        plain.flags &= ~(VkPipelineCreateFlags)VK_PIPELINE_CREATE_RENDERING_FRAGMENT_DENSITY_MAP_ATTACHMENT_BIT_EXT;
        if (fdm_twin(&plain)) ci = &plain;
    }
    note_pipe(g_rec->record_graphics_pipeline(h, *ci, nullptr, 0));
}
void h_compute_pipeline(VkPipeline h, const VkComputePipelineCreateInfo *ci) {
    if (g_rec) note_pipe(g_rec->record_compute_pipeline(h, *ci, nullptr, 0));
}
// The guest's device features, in the recording's application info.
void h_device_info(const VkDeviceCreateInfo *ci) {
    if (!g_rec) return;
    bool ok = ci->pEnabledFeatures ? g_rec->record_physical_device_features(*ci->pEnabledFeatures)
                                   : g_rec->record_physical_device_features(ci->pNext);
    if (!ok) fprintf(stderr, "  [foz] device features not recorded\n");
}

// ---- replay ------------------------------------------------------------------------------
struct Fns {
    PFN_vkCreateSampler CreateSampler;
    PFN_vkDestroySampler DestroySampler;
    PFN_vkCreateDescriptorSetLayout CreateDescriptorSetLayout;
    PFN_vkDestroyDescriptorSetLayout DestroyDescriptorSetLayout;
    PFN_vkCreatePipelineLayout CreatePipelineLayout;
    PFN_vkDestroyPipelineLayout DestroyPipelineLayout;
    PFN_vkCreateShaderModule CreateShaderModule;
    PFN_vkDestroyShaderModule DestroyShaderModule;
    PFN_vkCreateRenderPass CreateRenderPass;
    PFN_vkCreateRenderPass2 CreateRenderPass2;
    PFN_vkDestroyRenderPass DestroyRenderPass;
    PFN_vkCreateGraphicsPipelines CreateGraphicsPipelines;
    PFN_vkCreateComputePipelines CreateComputePipelines;
    PFN_vkDestroyPipeline DestroyPipeline;
};

struct Job { bool graphics; const void *ci; bool fdm = false; };

// The foveated twin of a replayed pipeline: what the game creates for its density-map pass when
// it sees VK_EXT_fragment_density_map (the scene pass: dynamic rendering, multiview, MSAA). On a
// recording made with foveation every such pipeline carried the flag and no other pipeline did.
bool fdm_twin(const VkGraphicsPipelineCreateInfo *ci) {
    if (ci->renderPass != VK_NULL_HANDLE) return false;
    if (ci->flags & VK_PIPELINE_CREATE_RENDERING_FRAGMENT_DENSITY_MAP_ATTACHMENT_BIT_EXT) return false;
    if (!ci->pMultisampleState || ci->pMultisampleState->rasterizationSamples <= VK_SAMPLE_COUNT_1_BIT) return false;
    uint32_t view_mask = 0;
    for (auto *b = (const VkBaseInStructure *)ci->pNext; b; b = b->pNext) {
        // flags there override ci->flags; Alyx does not send it
        if (b->sType == VK_STRUCTURE_TYPE_PIPELINE_CREATE_FLAGS_2_CREATE_INFO) return false;
        if (b->sType == VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO)
            view_mask = ((const VkPipelineRenderingCreateInfo *)b)->viewMask;
    }
    return view_mask != 0;
}

// Creates the dependency objects inline (the parse thread) and queues the pipelines for the
// compile threads. Fossilize keeps every parsed create info alive while the StateReplayer lives.
struct Creator : StateCreatorInterface {
    VkDevice dev;
    const Fns &f;
    std::vector<VkSampler> samplers;
    std::vector<VkDescriptorSetLayout> set_layouts;
    std::vector<VkPipelineLayout> layouts;
    std::vector<VkShaderModule> modules;
    std::vector<VkRenderPass> passes;
    std::mutex mu;
    std::condition_variable cv;
    std::deque<Job> queue;
    bool closed = false;
    bool fdm_variants = false;   // also queue each pipeline's foveated twin (fdm_twin)
    unsigned queued = 0, compiled = 0, failed = 0, slow = 0, twins = 0;
    double compile_s = 0;
    unsigned dep_fails = 0;

    Creator(VkDevice d, const Fns &fns) : dev(d), f(fns) {}
    void dep_fail(const char *what, VkResult r) {
        if (dep_fails++ < 4) fprintf(stderr, "  [foz] replay: creating a %s failed (VkResult %d)\n", what, (int)r);
    }

    bool enqueue_create_sampler(Hash, const VkSamplerCreateInfo *ci, VkSampler *out) override {
        *out = VK_NULL_HANDLE;
        if (VkResult r = f.CreateSampler(dev, ci, nullptr, out)) { dep_fail("sampler", r); return false; }
        samplers.push_back(*out);
        return true;
    }
    bool enqueue_create_descriptor_set_layout(Hash, const VkDescriptorSetLayoutCreateInfo *ci, VkDescriptorSetLayout *out) override {
        *out = VK_NULL_HANDLE;
        if (VkResult r = f.CreateDescriptorSetLayout(dev, ci, nullptr, out)) { dep_fail("set_layout", r); return false; }
        set_layouts.push_back(*out);
        return true;
    }
    bool enqueue_create_pipeline_layout(Hash, const VkPipelineLayoutCreateInfo *ci, VkPipelineLayout *out) override {
        *out = VK_NULL_HANDLE;
        if (VkResult r = f.CreatePipelineLayout(dev, ci, nullptr, out)) { dep_fail("layout", r); return false; }
        layouts.push_back(*out);
        return true;
    }
    bool enqueue_create_shader_module(Hash, const VkShaderModuleCreateInfo *ci, VkShaderModule *out) override {
        *out = VK_NULL_HANDLE;
        if (VkResult r = f.CreateShaderModule(dev, ci, nullptr, out)) { dep_fail("module", r); return false; }
        modules.push_back(*out);
        return true;
    }
    bool enqueue_create_render_pass(Hash, const VkRenderPassCreateInfo *ci, VkRenderPass *out) override {
        *out = VK_NULL_HANDLE;
        if (VkResult r = f.CreateRenderPass(dev, ci, nullptr, out)) { dep_fail("pass", r); return false; }
        passes.push_back(*out);
        return true;
    }
    bool enqueue_create_render_pass2(Hash, const VkRenderPassCreateInfo2 *ci, VkRenderPass *out) override {
        *out = VK_NULL_HANDLE;
        if (!f.CreateRenderPass2 || f.CreateRenderPass2(dev, ci, nullptr, out) != VK_SUCCESS) return false;
        passes.push_back(*out);
        return true;
    }
    void push(bool graphics, const void *ci, bool fdm = false) {
        std::lock_guard<std::mutex> l(mu);
        queue.push_back({ graphics, ci, fdm });
        queued++;
        if (fdm) twins++;
        cv.notify_one();
    }
    bool enqueue_create_graphics_pipeline(Hash, const VkGraphicsPipelineCreateInfo *ci, VkPipeline *out) override {
        *out = VK_NULL_HANDLE;
        push(true, ci);
        if (fdm_variants && fdm_twin(ci)) {
            g_prog_total.fetch_add(1, std::memory_order_relaxed);
            push(true, ci, true);
        }
        return true;
    }
    bool enqueue_create_compute_pipeline(Hash, const VkComputePipelineCreateInfo *ci, VkPipeline *out) override {
        *out = VK_NULL_HANDLE;
        push(false, ci);
        return true;
    }
    bool enqueue_create_raytracing_pipeline(Hash, const VkRayTracingPipelineCreateInfoKHR *, VkPipeline *out) override {
        *out = VK_NULL_HANDLE;
        return true;
    }

    void worker() {
        klvk_set_replay_thread(1);
        for (;;) {
            Job j;
            {
                std::unique_lock<std::mutex> l(mu);
                cv.wait(l, [&] { return closed || !queue.empty(); });
                if (queue.empty()) return;
                j = queue.front();
                queue.pop_front();
            }
            double t0 = now_s();
            VkPipeline p = VK_NULL_HANDLE;
            VkGraphicsPipelineCreateInfo twin;
            if (j.fdm) {
                twin = *(const VkGraphicsPipelineCreateInfo *)j.ci;
                twin.flags |= VK_PIPELINE_CREATE_RENDERING_FRAGMENT_DENSITY_MAP_ATTACHMENT_BIT_EXT;
            }
            VkResult r = j.graphics
                ? f.CreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1,
                      j.fdm ? &twin : (const VkGraphicsPipelineCreateInfo *)j.ci, nullptr, &p)
                : f.CreateComputePipelines(dev, VK_NULL_HANDLE, 1, (const VkComputePipelineCreateInfo *)j.ci, nullptr, &p);
            double dt = now_s() - t0;
            if (p) f.DestroyPipeline(dev, p, nullptr);
            std::lock_guard<std::mutex> l(mu);
            compiled++;
            g_prog_done.fetch_add(1, std::memory_order_relaxed);
            compile_s += dt;
            if (dt > 0.1) slow++;
            if (r != VK_SUCCESS) failed++;
        }
    }
    void destroy_objects() {
        for (auto h : modules) f.DestroyShaderModule(dev, h, nullptr);
        for (auto h : layouts) f.DestroyPipelineLayout(dev, h, nullptr);
        for (auto h : set_layouts) f.DestroyDescriptorSetLayout(dev, h, nullptr);
        for (auto h : passes) f.DestroyRenderPass(dev, h, nullptr);
        for (auto h : samplers) f.DestroySampler(dev, h, nullptr);
    }
};

std::vector<std::string> replay_files(const char *e = getenv("KL_FOZ_REPLAY")) {
    std::vector<std::string> out;
    if (!knob_on(e)) return out;
    std::string list = e;
    size_t pos = 0;
    while (pos <= list.size()) {
        size_t c = list.find(':', pos);
        std::string item = list.substr(pos, c == std::string::npos ? std::string::npos : c - pos);
        pos = c == std::string::npos ? list.size() + 1 : c + 1;
        if (item.empty()) continue;
        struct stat st;
        if (stat(item.c_str(), &st) != 0) {
            fprintf(stderr, "  [foz] replay: %s does not exist; skipped\n", item.c_str());
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            if (DIR *d = opendir(item.c_str())) {
                while (struct dirent *de = readdir(d)) {
                    size_t n = strlen(de->d_name);
                    if (n > 4 && !strcmp(de->d_name + n - 4, ".foz")) out.push_back(item + "/" + de->d_name);
                }
                closedir(d);
            }
        } else {
            out.push_back(item);
        }
    }
    return out;
}

// One replay over every database at once: a session recording (KL_FOZ_AUTORECORD) holds only
// what the others lacked, so its pipelines name layouts and modules that live in them.
void replay_db(VkDevice dev, const Fns &f, const std::vector<std::string> &paths, unsigned nthreads, bool background) {
    DatabaseInterface *db;
    std::string path = paths[0];
    if (paths.size() == 1) {
        db = create_stream_archive_database(path.c_str(), DatabaseMode::ReadOnly);
    } else {
        std::vector<const char *> p;
        for (const auto &s : paths) p.push_back(s.c_str());
        db = create_concurrent_database(nullptr, DatabaseMode::ReadOnly, p.data(), p.size());
        path += " + " + std::to_string(paths.size() - 1) + " more";
    }
    if (!db || !db->prepare()) {
        fprintf(stderr, "  [foz] replay: cannot open %s\n", path.c_str());
        delete db;
        return;
    }
    double t0 = now_s();
    StateReplayer replayer;
    Creator creator(dev, f);
    creator.fdm_variants = klvk_fdm_pipeline_variants() && !(getenv("KL_FOZ_FDM") && !strcmp(getenv("KL_FOZ_FDM"), "0"));
    std::vector<std::thread> workers;
    for (unsigned i = 0; i < nthreads; i++) workers.emplace_back([&] {
        pthread_setname_np("klfz replay");
        // racing the guest: behind its own loading. Blocking (the prewarm, or
        // KL_FOZ_REPLAY_BLOCK): nothing to yield to, so the caller's class.
        if (background) pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        creator.worker();
    });
    unsigned parse_fail = 0;
    std::vector<uint8_t> buf;
    // Dependencies first: the replayer resolves pipeline layouts and render passes only from
    // objects already replayed (shader modules and samplers it can also pull from the database).
    for (ResourceTag tag : { RESOURCE_SAMPLER, RESOURCE_DESCRIPTOR_SET_LAYOUT, RESOURCE_PIPELINE_LAYOUT,
                             RESOURCE_RENDER_PASS, RESOURCE_SHADER_MODULE,
                             RESOURCE_GRAPHICS_PIPELINE, RESOURCE_COMPUTE_PIPELINE }) {
        size_t n = 0;
        if (!db->get_hash_list_for_resource_tag(tag, &n, nullptr)) continue;
        std::vector<Hash> hashes(n);
        if (!db->get_hash_list_for_resource_tag(tag, &n, hashes.data())) continue;
        if (tag == RESOURCE_GRAPHICS_PIPELINE || tag == RESOURCE_COMPUTE_PIPELINE)
            g_prog_total.fetch_add((unsigned)n, std::memory_order_relaxed);
        for (Hash h : hashes) {
            size_t sz = 0;
            if (!db->read_entry(tag, h, &sz, nullptr, PAYLOAD_READ_NO_FLAGS)) { parse_fail++; continue; }
            buf.resize(sz);
            if (!db->read_entry(tag, h, &sz, buf.data(), PAYLOAD_READ_NO_FLAGS)) { parse_fail++; continue; }
            if (!replayer.parse(creator, db, buf.data(), sz)) parse_fail++;
        }
    }
    {
        std::lock_guard<std::mutex> l(creator.mu);
        creator.closed = true;
        creator.cv.notify_all();
    }
    for (auto &t : workers) t.join();
    creator.destroy_objects();
    delete db;
    fprintf(stderr, "  [foz] replay %s: %u pipelines (%u failed, %u unparsed%s) in %.1f s on %u threads; "
                    "%.1f s of compiles, %u over 100 ms\n",
            path.c_str(), creator.compiled, creator.failed, parse_fail,
            creator.fdm_variants ? (", " + std::to_string(creator.twins) + " of them foveated twins").c_str() : "",
            now_s() - t0, nthreads, creator.compile_s, creator.slow);
    g_sum_compiled.fetch_add(creator.compiled);
    g_sum_slow.fetch_add(creator.slow);
}

// Set while kl_foz_prewarm makes its own device: that device's replay is the prewarm's to run,
// not the hook's.
std::atomic<bool> g_prewarming{false};

void start_replay(VkDevice dev, PFN_vkGetDeviceProcAddr gdpa, const std::vector<std::string> &files, bool block) {
    if (files.empty()) return;
    static Fns f;
#define L(n) f.n = (PFN_vk##n)gdpa(dev, "vk" #n)
    L(CreateSampler); L(DestroySampler); L(CreateDescriptorSetLayout); L(DestroyDescriptorSetLayout);
    L(CreatePipelineLayout); L(DestroyPipelineLayout); L(CreateShaderModule); L(DestroyShaderModule);
    L(CreateRenderPass); L(CreateRenderPass2); L(DestroyRenderPass);
    L(CreateGraphicsPipelines); L(CreateComputePipelines); L(DestroyPipeline);
#undef L
    unsigned nthreads = 4;
    if (const char *t = getenv("KL_FOZ_THREADS")) nthreads = (unsigned)atoi(t);
    if (nthreads < 1) nthreads = 1;
    fprintf(stderr, "  [foz] replaying %zu database(s) on %u threads to warm the Metal cache%s\n",
            files.size(), nthreads, block ? " (blocking until done)" : " in the background");
    auto run = [dev, files, nthreads, block] {
        pthread_setname_np("klfz replay main");
        klvk_set_replay_thread(1);
        // Behind the guest's own loading: the utility class, not the render path's.
        if (!block) pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        double t0 = now_s();
        g_prog_done.store(0); g_prog_total.store(0);
        g_prog_t0.store(t0); g_prog_state.store(1);
        replay_db(dev, f, files, nthreads, !block);
        g_prog_state.store(2);
        fprintf(stderr, "  [foz] replay done in %.1f s\n", now_s() - t0);
        klvk_set_replay_thread(0);
    };
    if (block) run();
    else std::thread(run).detach();
}

void h_device_created(VkDevice dev, PFN_vkGetDeviceProcAddr gdpa) {
    if (g_prewarming.load()) return;
    static bool once;
    if (once) return;   // the guest's first device only
    std::vector<std::string> files = replay_files();
    if (files.empty()) return;
    once = true;
    start_replay(dev, gdpa, files, knob_on(getenv("KL_FOZ_REPLAY_BLOCK")));
}

// kl_fossilize_install and KL_FOZ_AUTORECORD: the hooks are installed once.
std::mutex g_install_mu;
bool g_installed;

const klvk_pipe_hooks g_hooks = {
    h_device_created, h_sampler, h_set_layout, h_pipeline_layout, h_shader_module,
    h_render_pass, h_render_pass2, h_graphics_pipeline, h_compute_pipeline, h_device_info,
};

} // namespace

// Replay progress for a loading screen: 0 (no replay this run), 1 (replaying) or 2 (done);
// `done`/`total` are pipelines compiled and listed so far, `elapsed` seconds since it began.
extern "C" int kl_foz_progress(unsigned *done, unsigned *total, double *elapsed) {
    int st = g_prog_state.load();
    if (done) *done = g_prog_done.load();
    if (total) *total = g_prog_total.load();
    if (elapsed) *elapsed = st ? now_s() - g_prog_t0.load() : 0;
    return st;
}

extern "C" void kl_fossilize_install(void) {
    std::lock_guard<std::mutex> l(g_install_mu);
    if (g_installed) return;
    const char *r = getenv("KL_FOZ_RECORD");
    bool rec = knob_on(r), rep = knob_on(getenv("KL_FOZ_REPLAY"));
    if (!rec && !rep) return;   // not latched: kl_foz_prewarm_env may set KL_FOZ_REPLAY later
    g_installed = true;
    if (rec && !g_rec) rec_init(r);
    klvk_set_pipe_hooks(&g_hooks);
}

// ---- prewarm: the replay before the guest exists ---------------------------------------------
// KL_FOZ_PREWARM=<file.foz|dir>[:...]: before the guest boots, make an instance and a device
// exactly as the game makes its own (device-info.json, which the layer writes at the game's
// vkCreateDevice: KL_VK_DEVICE_INFO), through the layer's own entry points, replay the
// databases on it on KL_FOZ_THREADS threads, blocking, and retire it. Pipelines made on that
// device go through the same fix-ups and MoltenVK state as the game's, so the Metal compiler's
// cache in THIS process is warm when the game asks. A replay from an earlier process did not
// warm a later one on the Mac, which is why this runs in the game's own process, right before
// boot. Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
// klepton/runtime/linux/kl_fossilize.cpp (kl_foz_prewarm).

extern "C" void *kl_vulkan_sym(const char *name);

namespace {

bool read_file(const char *path, std::string &out) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    char buf[65536];
    size_t n;
    out.clear();
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
    fclose(f);
    return true;
}

bool hex_bytes(const char *h, std::vector<uint8_t> &out) {
    size_t len = strlen(h);
    if (len & 1) return false;
    out.resize(len / 2);
    for (size_t i = 0; i < out.size(); i++) {
        unsigned v;
        if (sscanf(h + 2 * i, "%2x", &v) != 1) return false;
        out[i] = (uint8_t)v;
    }
    return true;
}

bool is_str(const rapidjson::Value &o, const char *k) { return o.HasMember(k) && o[k].IsString(); }
bool is_uint(const rapidjson::Value &o, const char *k) { return o.HasMember(k) && o[k].IsUint(); }
bool is_arr(const rapidjson::Value &o, const char *k) { return o.HasMember(k) && o[k].IsArray(); }

// Returns 0 when it replayed; -2 when the device info is missing or not usable; -1 when it
// could not otherwise (no databases, Vulkan unavailable, a create that failed).
int prewarm(const std::vector<std::string> &files, const char *info_path) {
    if (files.empty()) return -1;
    std::string text;
    if (!info_path || !read_file(info_path, text)) {
        fprintf(stderr, "  [foz] prewarm: no device info at %s\n", info_path ? info_path : "(null)");
        return -2;
    }
    rapidjson::Document d;
    d.Parse(text.c_str());
    if (d.HasParseError() || !d.IsObject() || !d.HasMember("instance") || !d.HasMember("device") ||
        !d["instance"].IsObject() || !d["device"].IsObject()) {
        fprintf(stderr, "  [foz] prewarm: %s is not device info\n", info_path);
        return -2;
    }
    const auto &ji = d["instance"], &jd = d["device"];
    if (!is_str(ji, "app") || !is_uint(ji, "app_version") || !is_str(ji, "engine") ||
        !is_uint(ji, "engine_version") || !is_uint(ji, "api") || !is_arr(ji, "extensions") ||
        !is_arr(jd, "extensions") || !is_arr(jd, "queues") || !is_arr(jd, "pnext") ||
        !jd.HasMember("enabled_features")) {
        fprintf(stderr, "  [foz] prewarm: %s is missing fields\n", info_path);
        return -2;
    }

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = ji["app"].GetString(); app.applicationVersion = ji["app_version"].GetUint();
    app.pEngineName = ji["engine"].GetString(); app.engineVersion = ji["engine_version"].GetUint();
    app.apiVersion = ji["api"].GetUint();
    std::vector<const char *> iext;
    for (const auto &e : ji["extensions"].GetArray()) if (e.IsString()) iext.push_back(e.GetString());
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = (uint32_t)iext.size(); ici.ppEnabledExtensionNames = iext.data();

    std::vector<const char *> dext;
    for (const auto &e : jd["extensions"].GetArray()) if (e.IsString()) dext.push_back(e.GetString());
    std::vector<VkDeviceQueueCreateInfo> qs;
    static const float prio[16] = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    for (const auto &q : jd["queues"].GetArray()) {
        if (!q.IsObject() || !is_uint(q, "family") || !is_uint(q, "count") || !is_uint(q, "flags")) return -2;
        VkDeviceQueueCreateInfo qi = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
        qi.queueFamilyIndex = q["family"].GetUint();
        qi.queueCount = std::min(q["count"].GetUint(), 16u);
        qi.flags = q["flags"].GetUint();
        qi.pQueuePriorities = prio;
        qs.push_back(qi);
    }
    VkPhysicalDeviceFeatures feats = {};
    bool have_feats = jd["enabled_features"].IsString();
    if (have_feats) {
        std::vector<uint8_t> b;
        if (!hex_bytes(jd["enabled_features"].GetString(), b) || b.size() != sizeof feats) {
            fprintf(stderr, "  [foz] prewarm: enabled_features is not a VkPhysicalDeviceFeatures\n");
            return -2;
        }
        memcpy(&feats, b.data(), sizeof feats);
    }
    std::vector<std::vector<uint8_t>> chain;
    for (const auto &st : jd["pnext"].GetArray()) {
        if (!st.IsObject() || !is_uint(st, "sType") || !is_uint(st, "size") || !is_str(st, "data")) return -2;
        size_t size = st["size"].GetUint();
        if (size <= sizeof(VkBaseOutStructure)) {
            fprintf(stderr, "  [foz] prewarm: device info has a feature struct (sType %u) this build cannot rebuild\n",
                    st["sType"].GetUint());
            return -2;
        }
        std::vector<uint8_t> b(size, 0), data;
        if (!hex_bytes(st["data"].GetString(), data) || data.size() != size - sizeof(VkBaseOutStructure)) return -2;
        ((VkBaseOutStructure *)b.data())->sType = (VkStructureType)st["sType"].GetUint();
        memcpy(b.data() + sizeof(VkBaseOutStructure), data.data(), data.size());
        chain.push_back(std::move(b));
    }
    for (size_t i = 0; i + 1 < chain.size(); i++)
        ((VkBaseOutStructure *)chain[i].data())->pNext = (VkBaseOutStructure *)chain[i + 1].data();
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.pNext = chain.empty() ? nullptr : chain[0].data();
    dci.queueCreateInfoCount = (uint32_t)qs.size(); dci.pQueueCreateInfos = qs.data();
    dci.enabledExtensionCount = (uint32_t)dext.size(); dci.ppEnabledExtensionNames = dext.data();
    dci.pEnabledFeatures = have_feats ? &feats : nullptr;

    auto gipa = (PFN_vkGetInstanceProcAddr)kl_vulkan_sym("vkGetInstanceProcAddr");
    if (!gipa) { fprintf(stderr, "  [foz] prewarm: no Vulkan (MoltenVK not loaded)\n"); return -1; }

    // the layer would write this device's settings over the game's
    std::string keep_info = getenv("KL_VK_DEVICE_INFO") ? getenv("KL_VK_DEVICE_INFO") : "";
    unsetenv("KL_VK_DEVICE_INFO");
    double t0 = now_s();
    VkInstance inst = VK_NULL_HANDLE;
    VkDevice dev = VK_NULL_HANDLE;
    VkResult r = ((PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance"))(&ici, nullptr, &inst);
    if (r == VK_SUCCESS) {
        uint32_t n = 1;
        VkPhysicalDevice phys = VK_NULL_HANDLE;
        ((PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices"))(inst, &n, &phys);
        g_prewarming.store(true);
        r = phys ? ((PFN_vkCreateDevice)gipa(inst, "vkCreateDevice"))(phys, &dci, nullptr, &dev)
                 : VK_ERROR_INITIALIZATION_FAILED;
        g_prewarming.store(false);
    }
    if (!keep_info.empty()) setenv("KL_VK_DEVICE_INFO", keep_info.c_str(), 1);
    if (r != VK_SUCCESS) {
        fprintf(stderr, "  [foz] prewarm: could not make the device (%d)\n", (int)r);
        if (inst) ((PFN_vkDestroyInstance)gipa(inst, "vkDestroyInstance"))(inst, nullptr);
        return -1;
    }
    fprintf(stderr, "  [foz] prewarm: device made as the game makes it (%zu + %zu extensions, %zu feature "
                    "structs); replaying\n", iext.size(), dext.size(), chain.size());
    g_sum_compiled.store(0); g_sum_slow.store(0);
    start_replay(dev, (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr"), files, true);
    klvk_retire_device(inst, dev);
    fprintf(stderr, "  [foz] prewarm done in %.1f s: %u pipelines, %u over 100 ms\n",
            now_s() - t0, g_sum_compiled.load(), g_sum_slow.load());
    return 0;
}

} // namespace

namespace {

// ---- KL_FOZ_AUTORECORD: each session records what the known databases lack ------------------
unsigned env_uint(const char *k, unsigned dflt) {
    const char *v = getenv(k);
    return v && *v ? (unsigned)strtoul(v, nullptr, 10) : dflt;
}

// Over KL_FOZ_RECORD_KEEP session files, fold them into <dir>/merged.foz (Fossilize dedups by
// hash) and delete them, so the folder holds a few files whatever the number of sessions.
void autorecord_compact(const std::string &dir) {
    std::string merged = dir + "/merged.foz";
    std::vector<std::string> src;
    for (const auto &f : replay_files(dir.c_str())) if (f != merged) src.push_back(f);
    if (src.size() <= env_uint("KL_FOZ_RECORD_KEEP", 8)) return;
    std::vector<const char *> p;
    for (const auto &f : src) p.push_back(f.c_str());
    if (!merge_concurrent_databases(merged.c_str(), p.data(), p.size(), true)) {
        fprintf(stderr, "  [foz] autorecord: merging %zu sessions into %s failed; kept as they are\n",
                src.size(), merged.c_str());
        return;
    }
    for (const auto &f : src) unlink(f.c_str());
    fprintf(stderr, "  [foz] autorecord: %zu sessions merged into %s\n", src.size(), merged.c_str());
}

// Records the guest's new pipelines into <dir>/session.N.foz: a concurrent database that knows
// every hash in `known` writes only the rest, and makes no file at all when there is none.
void autorecord_start(const std::string &dir, const std::vector<std::string> &known) {
    if (knob_on(getenv("KL_FOZ_RECORD"))) {
        fprintf(stderr, "  [foz] autorecord: off, KL_FOZ_RECORD names the recording\n");
        return;
    }
    unsigned long long bytes = 0;
    for (const auto &f : replay_files(dir.c_str())) {
        struct stat st;
        if (stat(f.c_str(), &st) == 0) bytes += (unsigned long long)st.st_size;
    }
    unsigned cap = env_uint("KL_FOZ_RECORD_MAX_MB", 256);
    if (bytes > (unsigned long long)cap << 20) {
        fprintf(stderr, "  [foz] autorecord: off, %s holds %.0f MB (cap %u MB, KL_FOZ_RECORD_MAX_MB)\n",
                dir.c_str(), bytes / 1048576.0, cap);
        return;
    }
    std::vector<const char *> p;
    for (const auto &f : known) p.push_back(f.c_str());
    std::string base = dir + "/session";
    std::lock_guard<std::mutex> l(g_install_mu);
    if (g_rec) return;
    rec_start(create_concurrent_database(base.c_str(), DatabaseMode::Append, p.data(), p.size()), base.c_str());
    if (!g_rec) return;
    g_installed = true;
    klvk_set_pipe_hooks(&g_hooks);
    fprintf(stderr, "  [foz] autorecord: pipelines not in the %zu known database(s) go to %s.N.foz\n",
            known.size(), base.c_str());
}

} // namespace

extern "C" int kl_foz_prewarm_env(void) {
    const char *p = getenv("KL_FOZ_PREWARM");
    const char *ar = getenv("KL_FOZ_AUTORECORD");
    bool autorec = knob_on(ar);
    if (!knob_on(p) && !autorec) return 1;
    static bool once;
    if (once) return 1;
    once = true;
    std::vector<std::string> files = replay_files(p);
    std::string first = files.empty() ? "" : files[0];
    if (autorec) {
        autorecord_compact(ar);
        for (const auto &f : replay_files(ar)) files.push_back(f);
    }
    int rc = 1;
    if (files.empty()) {
        if (knob_on(p)) { fprintf(stderr, "  [foz] prewarm: nothing to replay in %s\n", p); rc = -1; }
    } else {
        // KL_FOZ_DEVICE_INFO, else device-info.json beside the first KL_FOZ_PREWARM database,
        // else where the layer writes it (KL_VK_DEVICE_INFO)
        std::string info;
        if (const char *e = getenv("KL_FOZ_DEVICE_INFO")) info = e;
        else if (!first.empty()) {
            size_t slash = first.rfind('/');
            info = (slash == std::string::npos ? std::string(".") : first.substr(0, slash)) + "/device-info.json";
        } else if (const char *e = getenv("KL_VK_DEVICE_INFO")) info = e;
        rc = prewarm(files, info.empty() ? nullptr : info.c_str());
        if (rc == -2 && !knob_on(getenv("KL_FOZ_REPLAY"))) {
            // No way to make the game's device ahead of it: replay on the game's own device instead,
            // holding its vkCreateDevice (the in-process replay measured on the Mac). The layer
            // writes device-info.json there when KL_VK_DEVICE_INFO names it, for the next launch.
            fprintf(stderr, "  [foz] prewarm: falling back to a blocking replay at the game's vkCreateDevice\n");
            std::string list;
            for (const auto &f : files) list += (list.empty() ? "" : ":") + f;
            setenv("KL_FOZ_REPLAY", list.c_str(), 1);
            setenv("KL_FOZ_REPLAY_BLOCK", "1", 0);
            kl_fossilize_install();
        }
    }
    if (autorec) autorecord_start(ar, files);
    return rc;
}
