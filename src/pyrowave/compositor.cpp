/**
 * @file src/pyrowave/compositor.cpp
 * @brief Synchronized Vulkan cursor composition for direct PyroWave capture.
 */
#include "compositor.h"
#if defined(PRISM_ENABLE_PYROWAVE) && defined(PRISM_BUILD_VULKAN)
  #include "composite_shader.h"
  #include "src/platform/linux/graphics.h"

  #include <array>
  #include <stdexcept>

namespace prism_pyrowave {
  namespace {
    /**
     * @brief Reject a failed compositor operation.
     * @param result Vulkan status.
     */
    void check(VkResult result) {
      if (result != VK_SUCCESS) {
        throw std::runtime_error("PyroWave compositor Vulkan failure: " + std::to_string(result));
      }
    }

    /**
     * @brief Select compatible memory for a Vulkan allocation.
     * @param gpu Physical device.
     * @param bits Acceptable memory types.
     * @param flags Required memory properties.
     * @return Matching memory type index.
     */
    uint32_t memory_type(VkPhysicalDevice gpu, uint32_t bits, VkMemoryPropertyFlags flags) {
      VkPhysicalDeviceMemoryProperties properties {};
      vkGetPhysicalDeviceMemoryProperties(gpu, &properties);
      for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        if ((bits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & flags) == flags) {
          return i;
        }
      }
      throw std::runtime_error("PyroWave compositor memory unavailable");
    }
  }  // namespace

  /**
   * @brief Native resources with dependency-ordered destruction.
   */
  struct compositor::state {
    VkDevice device = VK_NULL_HANDLE;  ///< Borrowed codec device.
    VkQueue queue = VK_NULL_HANDLE;  ///< Borrowed graphics/compute queue.
    uint32_t family = 0;  ///< Queue family index.
    VkImage output = VK_NULL_HANDLE;  ///< Aspect-fit RGB frame.
    VkDeviceMemory output_memory = VK_NULL_HANDLE;  ///< Output allocation.
    VkImageView output_view = VK_NULL_HANDLE;  ///< Shader storage view.
    VkBuffer cursor = VK_NULL_HANDLE;  ///< Host-visible cursor pixels.
    VkDeviceMemory cursor_memory = VK_NULL_HANDLE;  ///< Cursor allocation.
    void *mapped = nullptr;  ///< Persistent cursor mapping.
    VkSampler sampler = VK_NULL_HANDLE;  ///< Capture sampler.
    VkDescriptorSetLayout layout = VK_NULL_HANDLE;  ///< Compute bindings.
    VkDescriptorPool descriptors = VK_NULL_HANDLE;  ///< Descriptor allocator.
    VkDescriptorSet set = VK_NULL_HANDLE;  ///< Active descriptors.
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;  ///< Push constants and descriptors.
    VkPipeline pipeline = VK_NULL_HANDLE;  ///< Composition compute pipeline.
    VkCommandPool pool = VK_NULL_HANDLE;  ///< Command allocator.
    VkCommandBuffer command = VK_NULL_HANDLE;  ///< Serialized command buffer.
    VkFence fence = VK_NULL_HANDLE;  ///< Completion fence.
    pyrowave_image_view result {};  ///< Codec-visible output view.
    bool initialized = false;  ///< Output image layout initialization state.
    static constexpr size_t cursor_capacity = 512 * 512 * 4;  ///< Bounded cursor allocation.

    /**
     * @brief Shader push constants; all fields use 32-bit scalar alignment.
     */
    struct parameters {
      int source_offset[2];  ///< Capture crop origin.
      int source_size[2];  ///< Capture display size.
      int output_size[2];  ///< Encoded frame size.
      int cursor_position[2];  ///< Cursor location in the captured framebuffer.
      int cursor_size[2];  ///< Displayed cursor dimensions.
      int cursor_source_size[2];  ///< Cursor bitmap dimensions.
      int hdr;  ///< Whether the capture uses PQ/BT.2020.
    };

    /**
     * @brief Release GPU resources after outstanding work completes.
     */
    ~state() {
      if (!device) {
        return;
      }
      vkDeviceWaitIdle(device);
      if (mapped) {
        vkUnmapMemory(device, cursor_memory);
      }
      if (fence) {
        vkDestroyFence(device, fence, nullptr);
      }
      if (pool) {
        vkDestroyCommandPool(device, pool, nullptr);
      }
      if (pipeline) {
        vkDestroyPipeline(device, pipeline, nullptr);
      }
      if (pipeline_layout) {
        vkDestroyPipelineLayout(device, pipeline_layout, nullptr);
      }
      if (descriptors) {
        vkDestroyDescriptorPool(device, descriptors, nullptr);
      }
      if (layout) {
        vkDestroyDescriptorSetLayout(device, layout, nullptr);
      }
      if (sampler) {
        vkDestroySampler(device, sampler, nullptr);
      }
      if (output_view) {
        vkDestroyImageView(device, output_view, nullptr);
      }
      if (output) {
        vkDestroyImage(device, output, nullptr);
      }
      if (output_memory) {
        vkFreeMemory(device, output_memory, nullptr);
      }
      if (cursor) {
        vkDestroyBuffer(device, cursor, nullptr);
      }
      if (cursor_memory) {
        vkFreeMemory(device, cursor_memory, nullptr);
      }
    }
  };

  compositor::compositor(pyrowave_device device, int width, int height):
      impl(std::make_unique<state>()) {
    auto &s = *impl;
    VkPhysicalDevice gpu = VK_NULL_HANDLE;
    pyrowave_device_get_vk_device_handles(device, nullptr, &gpu, &s.device);
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, nullptr);
    std::vector<VkQueueFamilyProperties> queues(count);
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, queues.data());
    bool found = false;
    for (uint32_t i = 0; i < count; ++i) {
      if ((queues[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) == (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) {
        s.family = i;
        found = true;
        break;
      }
    }
    if (!found) {
      throw std::runtime_error("PyroWave compositor requires a graphics/compute queue");
    }
    vkGetDeviceQueue(s.device, s.family, 0, &s.queue);
    VkImageCreateInfo image {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    image.imageType = VK_IMAGE_TYPE_2D;
    image.format = VK_FORMAT_R16G16B16A16_UNORM;
    image.extent = {uint32_t(width), uint32_t(height), 1};
    image.arrayLayers = image.mipLevels = 1;
    image.samples = VK_SAMPLE_COUNT_1_BIT;
    image.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT;
    check(vkCreateImage(s.device, &image, nullptr, &s.output));
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(s.device, s.output, &requirements);
    VkMemoryAllocateInfo allocate {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocate.allocationSize = requirements.size;
    allocate.memoryTypeIndex = memory_type(gpu, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    check(vkAllocateMemory(s.device, &allocate, nullptr, &s.output_memory));
    check(vkBindImageMemory(s.device, s.output, s.output_memory, 0));
    VkImageViewCreateInfo view {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    view.image = s.output;
    view.format = image.format;
    view.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    check(vkCreateImageView(s.device, &view, nullptr, &s.output_view));
    s.result.image = s.output;
    s.result.width = width;
    s.result.height = height;
    s.result.image_format = s.result.view_format = image.format;
    s.result.aspect = VK_IMAGE_ASPECT_COLOR_BIT;
    s.result.layout = VK_IMAGE_LAYOUT_GENERAL;
    VkBufferCreateInfo buffer {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    buffer.size = state::cursor_capacity;
    buffer.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    check(vkCreateBuffer(s.device, &buffer, nullptr, &s.cursor));
    vkGetBufferMemoryRequirements(s.device, s.cursor, &requirements);
    allocate.allocationSize = requirements.size;
    allocate.memoryTypeIndex = memory_type(gpu, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    check(vkAllocateMemory(s.device, &allocate, nullptr, &s.cursor_memory));
    check(vkBindBufferMemory(s.device, s.cursor, s.cursor_memory, 0));
    check(vkMapMemory(s.device, s.cursor_memory, 0, state::cursor_capacity, 0, &s.mapped));
    VkSamplerCreateInfo sampler {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    sampler.magFilter = sampler.minFilter = VK_FILTER_LINEAR;
    sampler.addressModeU = sampler.addressModeV = sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    check(vkCreateSampler(s.device, &sampler, nullptr, &s.sampler));
    std::array<VkDescriptorSetLayoutBinding, 3> bindings {{{0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr}, {1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr}, {2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr}}};
    VkDescriptorSetLayoutCreateInfo layout {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    layout.bindingCount = bindings.size();
    layout.pBindings = bindings.data();
    check(vkCreateDescriptorSetLayout(s.device, &layout, nullptr, &s.layout));
    std::array<VkDescriptorPoolSize, 3> sizes {{{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1}, {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1}, {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1}}};
    VkDescriptorPoolCreateInfo descriptor_pool {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    descriptor_pool.maxSets = 1;
    descriptor_pool.poolSizeCount = sizes.size();
    descriptor_pool.pPoolSizes = sizes.data();
    check(vkCreateDescriptorPool(s.device, &descriptor_pool, nullptr, &s.descriptors));
    VkDescriptorSetAllocateInfo descriptor {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    descriptor.descriptorPool = s.descriptors;
    descriptor.descriptorSetCount = 1;
    descriptor.pSetLayouts = &s.layout;
    check(vkAllocateDescriptorSets(s.device, &descriptor, &s.set));
    VkPushConstantRange constants {VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(state::parameters)};
    VkPipelineLayoutCreateInfo pipeline_layout {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pipeline_layout.setLayoutCount = 1;
    pipeline_layout.pSetLayouts = &s.layout;
    pipeline_layout.pushConstantRangeCount = 1;
    pipeline_layout.pPushConstantRanges = &constants;
    check(vkCreatePipelineLayout(s.device, &pipeline_layout, nullptr, &s.pipeline_layout));
    VkShaderModuleCreateInfo shader {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    shader.codeSize = sizeof(composite_spv);
    shader.pCode = composite_spv;
    VkShaderModule module;
    check(vkCreateShaderModule(s.device, &shader, nullptr, &module));
    auto release_shader = util::fail_guard([&]() {
      vkDestroyShaderModule(s.device, module, nullptr);
    });
    VkComputePipelineCreateInfo pipeline {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    pipeline.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
    pipeline.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    pipeline.stage.module = module;
    pipeline.stage.pName = "main";
    pipeline.layout = s.pipeline_layout;
    check(vkCreateComputePipelines(s.device, VK_NULL_HANDLE, 1, &pipeline, nullptr, &s.pipeline));
    VkCommandPoolCreateInfo pool {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pool.queueFamilyIndex = s.family;
    pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    check(vkCreateCommandPool(s.device, &pool, nullptr, &s.pool));
    VkCommandBufferAllocateInfo command {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    command.commandPool = s.pool;
    command.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    command.commandBufferCount = 1;
    check(vkAllocateCommandBuffers(s.device, &command, &s.command));
    VkFenceCreateInfo fence {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    check(vkCreateFence(s.device, &fence, nullptr, &s.fence));
  }

  compositor::~compositor() = default;

  pyrowave_image_view compositor::compose(const pyrowave_image_view &source, VkSemaphore ready, const egl::img_descriptor_t &descriptor, platf::display_t &display) {
    auto &s = *impl;
    auto [x, y] = display.pyrowave_capture_offset();
    state::parameters parameters {{x, y}, {display.width, display.height}, {int(s.result.width), int(s.result.height)}, {descriptor.x, descriptor.y}, {0, 0}, {0, 0}, 0};
    // HDR is encoded by the negotiated source format; the caller sets the color state below.
    parameters.hdr = display.is_hdr();
    if (descriptor.data) {
      if (descriptor.src_w <= 0 || descriptor.src_h <= 0 || descriptor.src_w > 512 || descriptor.src_h > 512 ||
          size_t(descriptor.src_w) * descriptor.src_h * 4 > descriptor.buffer.size()) {
        throw std::runtime_error("Invalid KMS cursor bitmap");
      }
      std::memcpy(s.mapped, descriptor.data, size_t(descriptor.src_w) * descriptor.src_h * 4);
      parameters.cursor_size[0] = descriptor.width;
      parameters.cursor_size[1] = descriptor.height;
      parameters.cursor_source_size[0] = descriptor.src_w;
      parameters.cursor_source_size[1] = descriptor.src_h;
    }
    VkImageViewCreateInfo view {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    view.image = source.image;
    view.format = source.view_format;
    view.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageView input;
    check(vkCreateImageView(s.device, &view, nullptr, &input));
    auto cleanup = util::fail_guard([&]() {
      vkDestroyImageView(s.device, input, nullptr);
    });
    std::array<VkDescriptorImageInfo, 2> images {{{s.sampler, input, VK_IMAGE_LAYOUT_GENERAL}, {VK_NULL_HANDLE, s.output_view, VK_IMAGE_LAYOUT_GENERAL}}};
    VkDescriptorBufferInfo buffer {s.cursor, 0, state::cursor_capacity};
    std::array<VkWriteDescriptorSet, 3> writes {};
    for (unsigned i = 0; i < writes.size(); ++i) {
      writes[i] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
      writes[i].dstSet = s.set;
      writes[i].dstBinding = i;
      writes[i].descriptorCount = 1;
      writes[i].descriptorType = i == 0 ? VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER : i == 1 ? VK_DESCRIPTOR_TYPE_STORAGE_IMAGE :
                                                                                               VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
      if (i < 2) {
        writes[i].pImageInfo = &images[i];
      } else {
        writes[i].pBufferInfo = &buffer;
      }
    }
    vkUpdateDescriptorSets(s.device, writes.size(), writes.data(), 0, nullptr);
    check(vkResetCommandBuffer(s.command, 0));
    VkCommandBufferBeginInfo begin {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    check(vkBeginCommandBuffer(s.command, &begin));
    std::array<VkImageMemoryBarrier, 2> barriers {};
    for (auto &barrier : barriers) {
      barrier = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
      barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
      barrier.oldLayout = barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    }
    barriers[0].image = source.image;
    barriers[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT;
    barriers[0].dstQueueFamilyIndex = s.family;
    barriers[0].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barriers[1].image = s.output;
    barriers[1].srcQueueFamilyIndex = barriers[1].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barriers[1].oldLayout = s.initialized ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_UNDEFINED;
    barriers[1].dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    vkCmdPipelineBarrier(s.command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, nullptr, 0, nullptr, barriers.size(), barriers.data());
    vkCmdBindPipeline(s.command, VK_PIPELINE_BIND_POINT_COMPUTE, s.pipeline);
    vkCmdBindDescriptorSets(s.command, VK_PIPELINE_BIND_POINT_COMPUTE, s.pipeline_layout, 0, 1, &s.set, 0, nullptr);
    vkCmdPushConstants(s.command, s.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(parameters), &parameters);
    vkCmdDispatch(s.command, (s.result.width + 7) / 8, (s.result.height + 7) / 8, 1);
    barriers[0].srcQueueFamilyIndex = s.family;
    barriers[0].dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT;
    barriers[0].srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barriers[0].dstAccessMask = 0;
    barriers[1].oldLayout = VK_IMAGE_LAYOUT_GENERAL;
    barriers[1].srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    barriers[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(s.command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 0, nullptr, barriers.size(), barriers.data());
    check(vkEndCommandBuffer(s.command));
    VkPipelineStageFlags wait = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
    VkSubmitInfo submit {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &ready;
    submit.pWaitDstStageMask = &wait;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &s.command;
    check(vkResetFences(s.device, 1, &s.fence));
    check(vkQueueSubmit(s.queue, 1, &submit, s.fence));
    auto result = vkWaitForFences(s.device, 1, &s.fence, VK_TRUE, 1000000000);
    if (result != VK_SUCCESS) {
      vkDeviceWaitIdle(s.device);
    }
    check(result);
    s.initialized = true;
    return s.result;
  }
}  // namespace prism_pyrowave
#endif
