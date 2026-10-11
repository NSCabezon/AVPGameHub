// Pipeline-object hooks the Vulkan layer (kl_vulkan.c) calls after each successful create,
// with the guest's create info, for an add-on pipeline recorder/replayer (kl_fossilize.cpp,
// KL_FOZ_RECORD / KL_FOZ_REPLAY). Include after the Vulkan headers.
//
// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox) klepton/runtime/gfx/kl_vk_pipe_hooks.h
//
// device_created hands over the layer's own vkGetDeviceProcAddr, so a replayer creates its
// objects through exactly the path the guest does: the same fix-ups, the same MoltenVK state,
// and so the same MSL, which is what the OS Metal compiler cache is keyed on.
//
// With no hooks installed (neither knob set) every call site is one predictable branch on a
// NULL pointer.
#ifndef KL_VK_PIPE_HOOKS_H
#define KL_VK_PIPE_HOOKS_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct klvk_pipe_hooks {
    void (*device_created)(VkDevice dev, PFN_vkGetDeviceProcAddr layer_gdpa);
    void (*sampler)(VkSampler h, const VkSamplerCreateInfo *ci);
    void (*set_layout)(VkDescriptorSetLayout h, const VkDescriptorSetLayoutCreateInfo *ci);
    void (*pipeline_layout)(VkPipelineLayout h, const VkPipelineLayoutCreateInfo *ci);
    void (*shader_module)(VkShaderModule h, const VkShaderModuleCreateInfo *ci);
    void (*render_pass)(VkRenderPass h, const VkRenderPassCreateInfo *ci);
    void (*render_pass2)(VkRenderPass h, const VkRenderPassCreateInfo2 *ci);
    void (*graphics_pipeline)(VkPipeline h, const VkGraphicsPipelineCreateInfo *ci);
    void (*compute_pipeline)(VkPipeline h, const VkComputePipelineCreateInfo *ci);
    // the guest's device create info, as it asked, just before the device is made
    void (*device_info)(const VkDeviceCreateInfo *ci);
} klvk_pipe_hooks;

void klvk_set_pipe_hooks(const klvk_pipe_hooks *h);

// A replayer's own device (kl_foz_prewarm), when it is done with it: out of the layer's books
// and destroyed, with its instance, so the game's device is the layer's first.
void klvk_retire_device(VkInstance inst, VkDevice dev);

// On a replayer's own threads: their creates are neither handed to the hooks nor counted
// as guest compiles in the "pipeline warmup" / stall report.
void klvk_set_replay_thread(int on);

// 1 when the guest's density-map pass is foveated by the MoltenVK fork (KL_FOVEATE=1 and the
// fork's ABI): a replayer then also compiles each scene-pass pipeline with
// VK_PIPELINE_CREATE_RENDERING_FRAGMENT_DENSITY_MAP_ATTACHMENT_BIT_EXT, the variant the game
// asks for in that mode (different MSL). Call after MoltenVK is loaded (a device exists).
int klvk_fdm_pipeline_variants(void);

// Weak no-op in kl_vulkan.c; the strong one is kl_fossilize.cpp's, linked only where
// Fossilize is vendored (make fossilize). Reads the knobs and installs the hooks.
void kl_fossilize_install(void);

#ifdef __cplusplus
}
#endif
#endif
