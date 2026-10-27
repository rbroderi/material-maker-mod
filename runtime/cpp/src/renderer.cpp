// Vulkan pass runner for runtime packages. The binding layout is Material
// Maker's: set 0 output image, set 1 parameters, set 2 input samplers,
// set 3 first row of the rendered chunk.

#include "mmr/mmr.h"

#include <volk.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <set>

namespace mmr {

namespace {

constexpr uint64_t MAX_PIXELS_PER_DISPATCH = 2048ull * 2048ull;

struct FormatInfo {
	VkFormat format;
	int channels;
	int bytes_per_channel;
	bool is_float;
};

bool get_format(const std::string &name, FormatInfo &info) {
	static const std::map<std::string, FormatInfo> formats = {
		{ "r16f", { VK_FORMAT_R16_SFLOAT, 1, 2, true } },
		{ "rgba16f", { VK_FORMAT_R16G16B16A16_SFLOAT, 4, 2, true } },
		{ "r32f", { VK_FORMAT_R32_SFLOAT, 1, 4, true } },
		{ "rgba32f", { VK_FORMAT_R32G32B32A32_SFLOAT, 4, 4, true } },
		{ "r8", { VK_FORMAT_R8_UNORM, 1, 1, false } },
		{ "rgba8", { VK_FORMAT_R8G8B8A8_UNORM, 4, 1, false } },
	};
	auto it = formats.find(name);
	if (it == formats.end()) {
		return false;
	}
	info = it->second;
	return true;
}

float half_to_float(uint16_t h) {
	uint32_t sign = (uint32_t)(h & 0x8000) << 16;
	uint32_t exponent = (h >> 10) & 0x1F;
	uint32_t mantissa = h & 0x3FF;
	uint32_t bits;
	if (exponent == 0) {
		if (mantissa == 0) {
			bits = sign;
		} else {
			// Subnormal
			exponent = 127 - 15 + 1;
			while ((mantissa & 0x400) == 0) {
				mantissa <<= 1;
				exponent--;
			}
			mantissa &= 0x3FF;
			bits = sign | (exponent << 23) | (mantissa << 13);
		}
	} else if (exponent == 31) {
		bits = sign | 0x7F800000 | (mantissa << 13);
	} else {
		bits = sign | ((exponent - 15 + 127) << 23) | (mantissa << 13);
	}
	float f;
	memcpy(&f, &bits, 4);
	return f;
}

std::string vk_error(const char *what, VkResult result) {
	return std::string(what) + " failed (VkResult " + std::to_string((int)result) + ")";
}

} // namespace

struct Renderer::Impl {
	struct GpuImage {
		VkImage image = VK_NULL_HANDLE;
		VkDeviceMemory memory = VK_NULL_HANDLE;
		VkImageView view = VK_NULL_HANDLE;
		VkImageLayout layout = VK_IMAGE_LAYOUT_UNDEFINED;
		uint32_t width = 0;
		uint32_t height = 0;
	};
	struct GpuBuffer {
		VkBuffer buffer = VK_NULL_HANDLE;
		VkDeviceMemory memory = VK_NULL_HANDLE;
		void *mapped = nullptr;
		VkDeviceSize size = 0;
	};
	struct PassState {
		const Pass *pass = nullptr;
		FormatInfo format{};
		GpuImage output;
		GpuBuffer parameters;
		std::vector<GpuBuffer> chunks;
		std::vector<uint32_t> chunk_rows;
		VkShaderModule module = VK_NULL_HANDLE;
		VkDescriptorSetLayout set_layouts[4] = {};
		VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
		VkPipeline pipeline = VK_NULL_HANDLE;
		VkDescriptorPool pool = VK_NULL_HANDLE;
		VkDescriptorSet sets[3] = {};
		std::vector<VkDescriptorSet> chunk_sets;
		bool dirty = true;
	};

	VkInstance instance = VK_NULL_HANDLE;
	VkPhysicalDevice physical_device = VK_NULL_HANDLE;
	VkPhysicalDeviceMemoryProperties memory_properties{};
	VkDevice device = VK_NULL_HANDLE;
	uint32_t queue_family = 0;
	VkQueue queue = VK_NULL_HANDLE;
	VkCommandPool command_pool = VK_NULL_HANDLE;
	VkSampler sampler = VK_NULL_HANDLE;
	VkFence fence = VK_NULL_HANDLE;
	std::string device_name;

	Package package;
	std::vector<PassState> passes;
	std::map<std::string, size_t> pass_index;
	std::map<std::string, GpuImage> textures;
	size_t rendered = 0;

	~Impl() { release(); }

	void release() {
		if (device == VK_NULL_HANDLE) {
			if (instance != VK_NULL_HANDLE) {
				vkDestroyInstance(instance, nullptr);
				instance = VK_NULL_HANDLE;
			}
			return;
		}
		vkDeviceWaitIdle(device);
		release_package();
		vkDestroyFence(device, fence, nullptr);
		vkDestroySampler(device, sampler, nullptr);
		vkDestroyCommandPool(device, command_pool, nullptr);
		vkDestroyDevice(device, nullptr);
		vkDestroyInstance(instance, nullptr);
		device = VK_NULL_HANDLE;
		instance = VK_NULL_HANDLE;
	}

	void release_image(GpuImage &image) {
		vkDestroyImageView(device, image.view, nullptr);
		vkDestroyImage(device, image.image, nullptr);
		vkFreeMemory(device, image.memory, nullptr);
		image = GpuImage();
	}

	void release_buffer(GpuBuffer &buffer) {
		if (buffer.mapped) {
			vkUnmapMemory(device, buffer.memory);
		}
		vkDestroyBuffer(device, buffer.buffer, nullptr);
		vkFreeMemory(device, buffer.memory, nullptr);
		buffer = GpuBuffer();
	}

	void release_package() {
		for (PassState &p : passes) {
			vkDestroyPipeline(device, p.pipeline, nullptr);
			vkDestroyPipelineLayout(device, p.pipeline_layout, nullptr);
			for (VkDescriptorSetLayout l : p.set_layouts) {
				vkDestroyDescriptorSetLayout(device, l, nullptr);
			}
			vkDestroyDescriptorPool(device, p.pool, nullptr);
			vkDestroyShaderModule(device, p.module, nullptr);
			release_image(p.output);
			release_buffer(p.parameters);
			for (GpuBuffer &b : p.chunks) {
				release_buffer(b);
			}
		}
		passes.clear();
		pass_index.clear();
		for (auto &[name, image] : textures) {
			release_image(image);
		}
		textures.clear();
	}

	bool find_memory_type(uint32_t bits, VkMemoryPropertyFlags flags, uint32_t &index) {
		for (uint32_t i = 0; i < memory_properties.memoryTypeCount; i++) {
			if ((bits & (1u << i)) && (memory_properties.memoryTypes[i].propertyFlags & flags) == flags) {
				index = i;
				return true;
			}
		}
		return false;
	}

	bool create_buffer(VkDeviceSize size, VkBufferUsageFlags usage, GpuBuffer &buffer, std::string &error) {
		VkBufferCreateInfo info{ VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
		info.size = std::max<VkDeviceSize>(size, 16);
		info.usage = usage;
		info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
		VkResult result = vkCreateBuffer(device, &info, nullptr, &buffer.buffer);
		if (result != VK_SUCCESS) {
			error = vk_error("vkCreateBuffer", result);
			return false;
		}
		VkMemoryRequirements requirements;
		vkGetBufferMemoryRequirements(device, buffer.buffer, &requirements);
		VkMemoryAllocateInfo allocate{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
		allocate.allocationSize = requirements.size;
		if (!find_memory_type(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, allocate.memoryTypeIndex)) {
			error = "no host visible memory";
			return false;
		}
		result = vkAllocateMemory(device, &allocate, nullptr, &buffer.memory);
		if (result != VK_SUCCESS) {
			error = vk_error("vkAllocateMemory", result);
			return false;
		}
		vkBindBufferMemory(device, buffer.buffer, buffer.memory, 0);
		vkMapMemory(device, buffer.memory, 0, VK_WHOLE_SIZE, 0, &buffer.mapped);
		buffer.size = info.size;
		memset(buffer.mapped, 0, (size_t)buffer.size);
		return true;
	}

	bool create_image(uint32_t width, uint32_t height, VkFormat format, VkImageUsageFlags usage, GpuImage &image, std::string &error) {
		VkImageCreateInfo info{ VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
		info.imageType = VK_IMAGE_TYPE_2D;
		info.format = format;
		info.extent = { width, height, 1 };
		info.mipLevels = 1;
		info.arrayLayers = 1;
		info.samples = VK_SAMPLE_COUNT_1_BIT;
		info.tiling = VK_IMAGE_TILING_OPTIMAL;
		info.usage = usage;
		info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
		info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		VkResult result = vkCreateImage(device, &info, nullptr, &image.image);
		if (result != VK_SUCCESS) {
			error = vk_error("vkCreateImage", result);
			return false;
		}
		VkMemoryRequirements requirements;
		vkGetImageMemoryRequirements(device, image.image, &requirements);
		VkMemoryAllocateInfo allocate{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
		allocate.allocationSize = requirements.size;
		if (!find_memory_type(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, allocate.memoryTypeIndex)) {
			error = "no device local memory";
			return false;
		}
		result = vkAllocateMemory(device, &allocate, nullptr, &image.memory);
		if (result != VK_SUCCESS) {
			error = vk_error("vkAllocateMemory", result);
			return false;
		}
		vkBindImageMemory(device, image.image, image.memory, 0);
		VkImageViewCreateInfo view{ VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
		view.image = image.image;
		view.viewType = VK_IMAGE_VIEW_TYPE_2D;
		view.format = format;
		view.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
		result = vkCreateImageView(device, &view, nullptr, &image.view);
		if (result != VK_SUCCESS) {
			error = vk_error("vkCreateImageView", result);
			return false;
		}
		image.width = width;
		image.height = height;
		return true;
	}

	void image_barrier(VkCommandBuffer cmd, GpuImage &image, VkImageLayout layout, VkAccessFlags src_access, VkAccessFlags dst_access, VkPipelineStageFlags src_stage, VkPipelineStageFlags dst_stage) {
		VkImageMemoryBarrier barrier{ VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
		barrier.oldLayout = image.layout;
		barrier.newLayout = layout;
		barrier.srcAccessMask = src_access;
		barrier.dstAccessMask = dst_access;
		barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		barrier.image = image.image;
		barrier.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
		vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, nullptr, 0, nullptr, 1, &barrier);
		image.layout = layout;
	}

	/// Records commands in a one time command buffer and waits for them
	template <typename F>
	bool submit(F record, std::string &error) {
		VkCommandBufferAllocateInfo allocate{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
		allocate.commandPool = command_pool;
		allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
		allocate.commandBufferCount = 1;
		VkCommandBuffer cmd;
		vkAllocateCommandBuffers(device, &allocate, &cmd);
		VkCommandBufferBeginInfo begin{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
		vkBeginCommandBuffer(cmd, &begin);
		record(cmd);
		vkEndCommandBuffer(cmd);
		VkSubmitInfo submit_info{ VK_STRUCTURE_TYPE_SUBMIT_INFO };
		submit_info.commandBufferCount = 1;
		submit_info.pCommandBuffers = &cmd;
		vkResetFences(device, 1, &fence);
		VkResult result = vkQueueSubmit(queue, 1, &submit_info, fence);
		if (result == VK_SUCCESS) {
			result = vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX);
		}
		vkFreeCommandBuffers(device, command_pool, 1, &cmd);
		if (result != VK_SUCCESS) {
			error = vk_error("vkQueueSubmit", result);
			return false;
		}
		return true;
	}

	bool init(std::string &error, int device_index) {
		VkResult result = volkInitialize();
		if (result != VK_SUCCESS) {
			error = "Vulkan is not available (no Vulkan driver)";
			return false;
		}
		VkApplicationInfo app{ VK_STRUCTURE_TYPE_APPLICATION_INFO };
		app.pApplicationName = "Material Maker runtime";
		app.apiVersion = VK_API_VERSION_1_1;
		VkInstanceCreateInfo instance_info{ VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
		instance_info.pApplicationInfo = &app;
		result = vkCreateInstance(&instance_info, nullptr, &instance);
		if (result != VK_SUCCESS) {
			error = vk_error("vkCreateInstance", result);
			return false;
		}
		volkLoadInstance(instance);
		uint32_t count = 0;
		vkEnumeratePhysicalDevices(instance, &count, nullptr);
		std::vector<VkPhysicalDevice> devices(count);
		vkEnumeratePhysicalDevices(instance, &count, devices.data());
		// Devices with a compute queue, discrete GPUs first
		std::vector<std::pair<VkPhysicalDevice, uint32_t>> candidates;
		for (int pass = 0; pass < 2; pass++) {
			for (VkPhysicalDevice d : devices) {
				VkPhysicalDeviceProperties properties;
				vkGetPhysicalDeviceProperties(d, &properties);
				if ((properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) != (pass == 0)) {
					continue;
				}
				uint32_t family_count = 0;
				vkGetPhysicalDeviceQueueFamilyProperties(d, &family_count, nullptr);
				std::vector<VkQueueFamilyProperties> families(family_count);
				vkGetPhysicalDeviceQueueFamilyProperties(d, &family_count, families.data());
				for (uint32_t f = 0; f < family_count; f++) {
					if (families[f].queueFlags & VK_QUEUE_COMPUTE_BIT) {
						candidates.push_back({ d, f });
						break;
					}
				}
			}
		}
		if (candidates.empty() || device_index >= (int)candidates.size()) {
			error = "no Vulkan device with compute shaders";
			return false;
		}
		auto [chosen, family] = candidates[device_index < 0 ? 0 : device_index];
		physical_device = chosen;
		queue_family = family;
		VkPhysicalDeviceProperties properties;
		vkGetPhysicalDeviceProperties(physical_device, &properties);
		device_name = properties.deviceName;
		vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
		VkPhysicalDeviceFeatures supported;
		vkGetPhysicalDeviceFeatures(physical_device, &supported);
		VkPhysicalDeviceFeatures features{};
		// Material Maker's shaders declare storage image formats such as r16f
		features.shaderStorageImageExtendedFormats = supported.shaderStorageImageExtendedFormats;
		float priority = 1.0f;
		VkDeviceQueueCreateInfo queue_info{ VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
		queue_info.queueFamilyIndex = queue_family;
		queue_info.queueCount = 1;
		queue_info.pQueuePriorities = &priority;
		VkDeviceCreateInfo device_info{ VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
		device_info.queueCreateInfoCount = 1;
		device_info.pQueueCreateInfos = &queue_info;
		device_info.pEnabledFeatures = &features;
		result = vkCreateDevice(physical_device, &device_info, nullptr, &device);
		if (result != VK_SUCCESS) {
			error = vk_error("vkCreateDevice", result);
			return false;
		}
		volkLoadDevice(device);
		vkGetDeviceQueue(device, queue_family, 0, &queue);
		VkCommandPoolCreateInfo pool_info{ VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
		pool_info.queueFamilyIndex = queue_family;
		pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
		vkCreateCommandPool(device, &pool_info, nullptr, &command_pool);
		VkSamplerCreateInfo sampler_info{ VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
		sampler_info.magFilter = VK_FILTER_LINEAR;
		sampler_info.minFilter = VK_FILTER_LINEAR;
		sampler_info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
		sampler_info.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
		sampler_info.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
		sampler_info.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
		sampler_info.maxLod = 0.0f;
		vkCreateSampler(device, &sampler_info, nullptr, &sampler);
		VkFenceCreateInfo fence_info{ VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
		vkCreateFence(device, &fence_info, nullptr, &fence);
		return true;
	}

	bool upload_texture(const std::string &name, const Image &image, std::string &error) {
		GpuImage gpu;
		if (!create_image(image.width, image.height, VK_FORMAT_R32G32B32A32_SFLOAT, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, gpu, error)) {
			return false;
		}
		GpuBuffer staging;
		VkDeviceSize size = (VkDeviceSize)image.width * image.height * 16;
		if (!create_buffer(size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, staging, error)) {
			return false;
		}
		memcpy(staging.mapped, image.pixels.data(), (size_t)size);
		bool ok = submit([&](VkCommandBuffer cmd) {
			image_barrier(cmd, gpu, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
			VkBufferImageCopy region{};
			region.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
			region.imageExtent = { (uint32_t)image.width, (uint32_t)image.height, 1 };
			vkCmdCopyBufferToImage(cmd, staging.buffer, gpu.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
			image_barrier(cmd, gpu, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
		}, error);
		release_buffer(staging);
		textures[name] = gpu;
		return ok;
	}

	bool create_pass(PassState &state, std::string &error) {
		const Pass &pass = *state.pass;
		if (!get_format(pass.format, state.format)) {
			error = "pass " + pass.name + ": unknown format " + pass.format;
			return false;
		}
		if (!create_image(pass.width, pass.height, state.format.format, VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, state.output, error)) {
			return false;
		}
		if (!create_buffer(pass.parameter_data.size(), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, state.parameters, error)) {
			return false;
		}
		memcpy(state.parameters.mapped, pass.parameter_data.data(), pass.parameter_data.size());
		// Rows are rendered in chunks, the first row of each chunk is in set 3
		uint32_t chunk_height = (uint32_t)std::clamp<uint64_t>(MAX_PIXELS_PER_DISPATCH / pass.width, 1, pass.height);
		for (uint32_t y = 0; y < pass.height; y += chunk_height) {
			GpuBuffer chunk;
			if (!create_buffer(4, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, chunk, error)) {
				return false;
			}
			int32_t first_row = (int32_t)y;
			memcpy(chunk.mapped, &first_row, 4);
			state.chunks.push_back(chunk);
			state.chunk_rows.push_back(std::min(chunk_height, pass.height - y));
		}
		VkShaderModuleCreateInfo module_info{ VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
		module_info.codeSize = pass.spirv.size() * 4;
		module_info.pCode = pass.spirv.data();
		VkResult result = vkCreateShaderModule(device, &module_info, nullptr, &state.module);
		if (result != VK_SUCCESS) {
			error = "pass " + pass.name + ": " + vk_error("vkCreateShaderModule", result);
			return false;
		}
		std::vector<VkDescriptorSetLayoutBinding> bindings[4];
		bindings[0].push_back({ 0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr });
		bindings[1].push_back({ 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr });
		for (uint32_t i = 0; i < pass.inputs.size(); i++) {
			bindings[2].push_back({ i, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr });
		}
		bindings[3].push_back({ 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr });
		for (int s = 0; s < 4; s++) {
			VkDescriptorSetLayoutCreateInfo layout_info{ VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
			layout_info.bindingCount = (uint32_t)bindings[s].size();
			layout_info.pBindings = bindings[s].data();
			vkCreateDescriptorSetLayout(device, &layout_info, nullptr, &state.set_layouts[s]);
		}
		VkPipelineLayoutCreateInfo pipeline_layout_info{ VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
		pipeline_layout_info.setLayoutCount = 4;
		pipeline_layout_info.pSetLayouts = state.set_layouts;
		vkCreatePipelineLayout(device, &pipeline_layout_info, nullptr, &state.pipeline_layout);
		VkComputePipelineCreateInfo pipeline_info{ VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
		pipeline_info.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO };
		pipeline_info.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
		pipeline_info.stage.module = state.module;
		pipeline_info.stage.pName = "main";
		pipeline_info.layout = state.pipeline_layout;
		result = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, nullptr, &state.pipeline);
		if (result != VK_SUCCESS) {
			error = "pass " + pass.name + ": " + vk_error("vkCreateComputePipelines", result);
			return false;
		}
		// Descriptor sets
		uint32_t chunk_count = (uint32_t)state.chunks.size();
		std::vector<VkDescriptorPoolSize> sizes = {
			{ VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1 },
			{ VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 + chunk_count },
		};
		if (!pass.inputs.empty()) {
			sizes.push_back({ VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, (uint32_t)pass.inputs.size() });
		}
		VkDescriptorPoolCreateInfo pool_info{ VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
		pool_info.maxSets = 3 + chunk_count;
		pool_info.poolSizeCount = (uint32_t)sizes.size();
		pool_info.pPoolSizes = sizes.data();
		vkCreateDescriptorPool(device, &pool_info, nullptr, &state.pool);
		std::vector<VkDescriptorSetLayout> layouts = { state.set_layouts[0], state.set_layouts[1], state.set_layouts[2] };
		for (uint32_t c = 0; c < chunk_count; c++) {
			layouts.push_back(state.set_layouts[3]);
		}
		std::vector<VkDescriptorSet> sets(layouts.size());
		VkDescriptorSetAllocateInfo set_info{ VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
		set_info.descriptorPool = state.pool;
		set_info.descriptorSetCount = (uint32_t)layouts.size();
		set_info.pSetLayouts = layouts.data();
		result = vkAllocateDescriptorSets(device, &set_info, sets.data());
		if (result != VK_SUCCESS) {
			error = vk_error("vkAllocateDescriptorSets", result);
			return false;
		}
		for (int s = 0; s < 3; s++) {
			state.sets[s] = sets[s];
		}
		state.chunk_sets.assign(sets.begin() + 3, sets.end());
		// The output stays in the general layout (storage writes and sampling)
		VkDescriptorImageInfo output_info{ VK_NULL_HANDLE, state.output.view, VK_IMAGE_LAYOUT_GENERAL };
		VkDescriptorBufferInfo parameters_info{ state.parameters.buffer, 0, VK_WHOLE_SIZE };
		std::vector<VkDescriptorImageInfo> input_infos;
		for (const PassInput &input : pass.inputs) {
			if (!input.pass.empty()) {
				auto it = pass_index.find(input.pass);
				if (it == pass_index.end()) {
					error = "pass " + pass.name + " uses " + input.pass + " before it is defined";
					return false;
				}
				input_infos.push_back({ sampler, passes[it->second].output.view, VK_IMAGE_LAYOUT_GENERAL });
			} else {
				auto it = textures.find(input.texture);
				if (it == textures.end()) {
					error = "missing texture " + input.texture;
					return false;
				}
				input_infos.push_back({ sampler, it->second.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL });
			}
		}
		std::vector<VkWriteDescriptorSet> writes;
		VkWriteDescriptorSet w{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
		w.descriptorCount = 1;
		w.dstSet = state.sets[0];
		w.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
		w.pImageInfo = &output_info;
		writes.push_back(w);
		w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
		w.descriptorCount = 1;
		w.dstSet = state.sets[1];
		w.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
		w.pBufferInfo = &parameters_info;
		writes.push_back(w);
		for (uint32_t i = 0; i < input_infos.size(); i++) {
			w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
			w.descriptorCount = 1;
			w.dstSet = state.sets[2];
			w.dstBinding = i;
			w.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
			w.pImageInfo = &input_infos[i];
			writes.push_back(w);
		}
		std::vector<VkDescriptorBufferInfo> chunk_infos(chunk_count);
		for (uint32_t c = 0; c < chunk_count; c++) {
			chunk_infos[c] = { state.chunks[c].buffer, 0, VK_WHOLE_SIZE };
			w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
			w.descriptorCount = 1;
			w.dstSet = state.chunk_sets[c];
			w.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
			w.pBufferInfo = &chunk_infos[c];
			writes.push_back(w);
		}
		vkUpdateDescriptorSets(device, (uint32_t)writes.size(), writes.data(), 0, nullptr);
		return true;
	}

	bool load(const Package &p, std::string &error) {
		if (device == VK_NULL_HANDLE) {
			error = "the renderer is not initialized";
			return false;
		}
		release_package();
		package = p;
		for (const auto &[name, image] : package.textures) {
			if (!upload_texture(name, image, error)) {
				return false;
			}
		}
		passes.resize(package.passes.size());
		for (size_t i = 0; i < package.passes.size(); i++) {
			passes[i].pass = &package.passes[i];
			if (!create_pass(passes[i], error)) {
				return false;
			}
			pass_index[package.passes[i].name] = i;
		}
		// Output images go to the general layout once
		return submit([&](VkCommandBuffer cmd) {
			for (PassState &state : passes) {
				image_barrier(cmd, state.output, VK_IMAGE_LAYOUT_GENERAL, 0, VK_ACCESS_SHADER_WRITE_BIT, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
			}
		}, error);
	}

	void mark_dirty(size_t index) {
		if (passes[index].dirty) {
			return;
		}
		passes[index].dirty = true;
		const std::string &name = passes[index].pass->name;
		for (size_t i = index + 1; i < passes.size(); i++) {
			for (const PassInput &input : passes[i].pass->inputs) {
				if (input.pass == name) {
					mark_dirty(i);
					break;
				}
			}
		}
	}

	bool set_parameter(const std::string &name, const std::vector<float> &value, std::string &error) {
		const Parameter *parameter = package.find_parameter(name);
		if (parameter == nullptr) {
			error = "unknown parameter " + name;
			return false;
		}
		for (const ParameterTarget &target : parameter->targets) {
			auto it = pass_index.find(target.pass);
			if (it == pass_index.end()) {
				continue;
			}
			PassState &state = passes[it->second];
			auto layout = state.pass->parameters.find(target.parameter);
			if (layout == state.pass->parameters.end()) {
				continue;
			}
			size_t count = layout->second.type == "float" ? 1 : layout->second.type == "vec2" ? 2 : layout->second.type == "vec3" ? 3 : 4;
			uint8_t *destination = (uint8_t *)state.parameters.mapped + layout->second.offset;
			if (parameter->type == "seed") {
				// As Material Maker's --seed: unlocked seeds are offset by the
				// golden ratio times the seed, modulo 1
				double seed = value.empty() ? 0.0 : value[0];
				double sum = 0.0;
				for (const SeedTerm &term : target.seed_terms) {
					sum += term.locked ? term.value : std::fmod(term.value + 0.6180339887 * seed, 1.0);
				}
				float uniform = float(sum);
				memcpy(destination, &uniform, 4);
				mark_dirty(it->second);
				continue;
			}
			for (size_t i = 0; i < count && i < value.size(); i++) {
				memcpy(destination + 4 * i, &value[i], 4);
			}
			mark_dirty(it->second);
		}
		return true;
	}

	bool render(std::string &error) {
		rendered = 0;
		for (const PassState &state : passes) {
			rendered += state.dirty ? 1 : 0;
		}
		if (rendered == 0) {
			return true;
		}
		bool ok = submit([&](VkCommandBuffer cmd) {
			for (PassState &state : passes) {
				if (!state.dirty) {
					continue;
				}
				vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, state.pipeline);
				vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, state.pipeline_layout, 0, 3, state.sets, 0, nullptr);
				uint32_t groups_x = (state.pass->width + state.pass->local_size - 1) / state.pass->local_size;
				for (size_t c = 0; c < state.chunks.size(); c++) {
					vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, state.pipeline_layout, 3, 1, &state.chunk_sets[c], 0, nullptr);
					vkCmdDispatch(cmd, groups_x, state.chunk_rows[c], 1);
				}
				// Following passes read this one
				image_barrier(cmd, state.output, VK_IMAGE_LAYOUT_GENERAL, VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
				state.dirty = false;
			}
		}, error);
		return ok;
	}

	bool read_image(const std::string &output, Image &image, std::string &error) {
		auto o = package.outputs.find(output);
		auto it = pass_index.find(o != package.outputs.end() ? o->second : output);
		if (it == pass_index.end()) {
			error = "unknown output " + output;
			return false;
		}
		PassState &state = passes[it->second];
		VkDeviceSize size = (VkDeviceSize)state.output.width * state.output.height * state.format.channels * state.format.bytes_per_channel;
		GpuBuffer staging;
		if (!create_buffer(size, VK_BUFFER_USAGE_TRANSFER_DST_BIT, staging, error)) {
			return false;
		}
		bool ok = submit([&](VkCommandBuffer cmd) {
			image_barrier(cmd, state.output, VK_IMAGE_LAYOUT_GENERAL, VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
			VkBufferImageCopy region{};
			region.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
			region.imageExtent = { state.output.width, state.output.height, 1 };
			vkCmdCopyImageToBuffer(cmd, state.output.image, VK_IMAGE_LAYOUT_GENERAL, staging.buffer, 1, &region);
		}, error);
		if (ok) {
			image.width = (int)state.output.width;
			image.height = (int)state.output.height;
			image.channels = state.format.channels;
			size_t count = (size_t)image.width * image.height * image.channels;
			image.pixels.resize(count);
			for (size_t i = 0; i < count; i++) {
				switch (state.format.bytes_per_channel) {
					case 1: image.pixels[i] = ((const uint8_t *)staging.mapped)[i] / 255.0f; break;
					case 2: image.pixels[i] = half_to_float(((const uint16_t *)staging.mapped)[i]); break;
					default: image.pixels[i] = ((const float *)staging.mapped)[i]; break;
				}
			}
		}
		release_buffer(staging);
		return ok;
	}
};

Renderer::Renderer() : impl(new Impl()) {}
Renderer::~Renderer() = default;

bool Renderer::init(std::string &error, int device_index) { return impl->init(error, device_index); }
bool Renderer::load(const Package &package, std::string &error) { return impl->load(package, error); }
bool Renderer::set_parameter(const std::string &name, const std::vector<float> &value, std::string &error) { return impl->set_parameter(name, value, error); }
bool Renderer::render(std::string &error) { return impl->render(error); }
bool Renderer::read_image(const std::string &output, Image &image, std::string &error) { return impl->read_image(output, image, error); }
std::string Renderer::device_name() const { return impl->device_name; }
size_t Renderer::rendered_pass_count() const { return impl->rendered; }

} // namespace mmr
