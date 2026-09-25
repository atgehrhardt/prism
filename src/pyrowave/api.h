/**
 * @file api.h
 * @brief Include Vulkan types before the standalone PyroWave C API.
 */
#pragma once
#include <vulkan/vulkan.h>

// Upstream requires Vulkan declarations before its own header.
extern "C" {
#include <pyrowave.h>
}
