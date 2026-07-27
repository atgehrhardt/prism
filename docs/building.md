# Building
Prism binaries are built using [CMake](https://cmake.org) and requires `cmake` > 3.25.

## Building Locally

### Compiler
It is recommended to use one of the following compilers:

| Compiler    | Version |
|:------------|:--------|
| GCC         | 14+     |
| Clang       | 17+     |

### Dependencies

#### Linux
Dependencies vary depending on the distribution. You can reference our
[linux_build.sh](https://github.com/LizardByte/Prism/blob/master/scripts/linux_build.sh) script for a list of
dependencies we use in Debian-based, Fedora-based and Arch-based distributions. Please submit a PR if you would like to extend the
script to support other distributions.

##### KMS Capture
If you are using KMS, patching the Prism binary with `setcap` is required. Some post-install scripts handle this. If building
from source and using the binary directly, this will also work:

```bash
sudo cp build/prism /tmp
sudo setcap cap_sys_admin,cap_sys_nice+p /tmp/prism
sudo getcap /tmp/prism
sudo mv /tmp/prism build/prism
```

##### CUDA Toolkit
Prism requires CUDA Toolkit for NVFBC capture. There are two caveats to CUDA:

1. The version installed depends on the version of GCC.
2. The version of CUDA you use will determine compatibility with various GPU generations.
   At the time of writing, the recommended version to use is CUDA ~13.1.
   See [CUDA compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/index.html) for more info.

> [!NOTE]
> To install older versions, select the appropriate run file based on your desired CUDA version and architecture
> according to [CUDA Toolkit Archive](https://developer.nvidia.com/cuda-toolkit-archive)

### Clone
Ensure [git](https://git-scm.com) is installed on your system, then clone the repository using the following command:

```bash
git clone https://github.com/atgehrhardt/prism.git --recurse-submodules
cd prism
mkdir build
```

### Build

```bash
cmake -B build -G Ninja -S .
ninja -C build
```

> [!TIP]
> Available build options can be found in
> [options.cmake](https://github.com/LizardByte/Prism/blob/master/cmake/prep/options.cmake).

### Package

```bash
cpack -G DEB --config ./build/CPackConfig.cmake
```

or

```bash
cpack -G RPM --config ./build/CPackConfig.cmake
```

### Remote Build
It may be beneficial to build remotely in some cases. This will enable easier building on different operating systems.

1. Fork the project
2. Activate workflows
3. Trigger the *CI* workflow manually
4. Download the artifacts/binaries from the workflow run summary

<div class="section_buttons">

| Previous                              |                            Next |
|:--------------------------------------|--------------------------------:|
| [Troubleshooting](troubleshooting.md) | [Contributing](contributing.md) |

</div>

<details style="display: none;">
  <summary></summary>
  [TOC]
</details>
