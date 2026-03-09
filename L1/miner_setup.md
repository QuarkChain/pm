# Building ethminer on Ubuntu 24.04 (Clean Machine Guide)

This guide documents the exact steps to build ethminer from source on a **fresh Ubuntu 24.04** machine with an NVIDIA GPU. It was validated on a machine with an NVIDIA RTX 4000 Ada (sm_89) and CUDA driver 12.6.

---

## System Requirements

- Ubuntu 24.04 (x86_64)
- NVIDIA GPU
- Internet access (for downloading dependencies)

---

## Step 0: Install NVIDIA Driver

Skip this step if the driver is already installed (`nvidia-smi` returns output).

The driver requires kernel headers and a C compiler to build its kernel module:

```bash
sudo apt install -y gcc make linux-headers-$(uname -r)
```

Download and run the NVIDIA driver installer (560.35.03 = CUDA 12.6 driver):

```bash
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/560.35.03/NVIDIA-Linux-x86_64-560.35.03.run
sudo bash NVIDIA-Linux-x86_64-560.35.03.run
```

Verify the driver is loaded:

```bash
nvidia-smi
```

You should see your GPU listed with driver version 560.35.03 and CUDA Version 12.6.

> **Note:** If you are running a headless server, add `--no-x-check` to the installer command to skip the X server check.

---

## Step 1: Install System Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y \
    git \
    build-essential \
    gcc \
    g++ \
    cmake \
    perl \
    libssl-dev \
    p7zip-full \
    wget
```

> **Why:** ethminer needs GCC, CMake >= 3.5, Perl (for OpenSSL build), and libssl-dev.

---

## Step 2: Install CUDA 12.6 Toolkit

The system `nvidia-cuda-toolkit` package from Ubuntu's default repo is version 12.0, which is **incompatible** with Ubuntu 24.04's glibc (causes `_Float32 undefined` errors during compilation). Install CUDA 12.6 from NVIDIA's official repo instead.

```bash
# Add NVIDIA's official CUDA repo keyring
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb
sudo dpkg -i /tmp/cuda-keyring.deb

# Update and install CUDA 12.6 toolkit
sudo apt-get update
sudo apt-get install -y cuda-toolkit-12-6
```

Verify:
```bash
/usr/local/cuda-12.6/bin/nvcc --version
# Expected: Cuda compilation tools, release 12.6
```

> **Why:** CUDA 12.0 nvcc cannot parse `_Float32` types defined in Ubuntu 24.04's glibc 2.39. CUDA 12.2+ fixes this. Match the toolkit version to your installed driver.

---

## Step 3: Build and Install Boost 1.66.0 from Source

ethminer was written for Boost 1.66.0. Newer Boost versions (1.70+) removed the `get_io_service()` Asio API that ethminer uses, causing compile errors. **Do not use the system Boost.**

```bash
# Download Boost 1.66.0 from official archive
wget https://archives.boost.io/release/1.66.0/source/boost_1_66_0.tar.gz -O /tmp/boost_1_66_0.tar.gz

# Extract
tar -xzf /tmp/boost_1_66_0.tar.gz -C /tmp/

# Bootstrap and build only the required libraries
cd /tmp/boost_1_66_0
./bootstrap.sh --with-libraries=system,filesystem,thread,chrono,date_time,atomic \
               --prefix=/usr/local/boost166

./b2 install -j$(nproc)
```

> **Why:** Hunter (ethminer's built-in package manager) is configured to use Boost 1.66.0, but its download URL has a checksum mismatch. Building from the official source bypasses Hunter entirely.

---

## Step 4: Install CLI11 1.5.4

ethminer uses the CLI11 library for argument parsing. The system package (2.x) removed the 4-argument `add_option()` API that ethminer relies on. Install the compatible version:

```bash
wget https://github.com/CLIUtils/CLI11/archive/v1.5.4.tar.gz -O /tmp/CLI11-1.5.4.tar.gz
tar -xzf /tmp/CLI11-1.5.4.tar.gz -C /tmp/

mkdir -p /tmp/cli11_build
cd /tmp/cli11_build
cmake /tmp/CLI11-1.5.4 \
    -DCLI11_TESTING=OFF \
    -DCLI11_EXAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX=/usr/local
sudo make install

# Remove old system CLI11 cmake files (if present) to avoid version conflicts
sudo rm -rf /usr/local/share/cmake/CLI11/
```

---

## Step 5: Build and Install jsoncpp 1.9.5 (Static Library)

ethminer links against `jsoncpp_static`. The system jsoncpp only ships the shared library. Build from source to get the static version:

```bash
wget https://github.com/open-source-parsers/jsoncpp/archive/refs/tags/1.9.5.tar.gz -O /tmp/jsoncpp-1.9.5.tar.gz
tar -xzf /tmp/jsoncpp-1.9.5.tar.gz -C /tmp/

mkdir -p /tmp/jsoncpp_build
cd /tmp/jsoncpp_build
cmake /tmp/jsoncpp-1.9.5 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DCMAKE_INSTALL_PREFIX=/usr/local
make -j$(nproc)
sudo make install
```

---

## Step 6: Clone and Prepare the Source

```bash
git clone https://github.com/nicehash/ethminer.git
cd ethminer
git submodule update --init --recursive
```

> **Note:** The repository already contains two required source fixes:
> - `libdevcore/vector_ref.h` — added `#include <cstdint>` (needed for newer GCC)
> - `libethash-cuda/CMakeLists.txt` — removed deprecated `sm_35` target (dropped in CUDA 12+), added `sm_89` (Ada Lovelace architecture)
>
> If building from a fresh clone without these fixes, apply them manually (see [Source Fixes](#appendix-source-fixes) below).

---

## Step 7: Configure with CMake

```bash
mkdir build && cd build

cmake .. \
    -DHUNTER_ENABLED=OFF \
    -DBOOST_ROOT=/usr/local/boost166 \
    -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.6 \
    -DCUDA_NVCC_FLAGS="--allow-unsupported-compiler" \
    -DETHASHCUDA=ON \
    -Djsoncpp_DIR=/usr/local/lib/cmake/jsoncpp
```

**Flag explanations:**

| Flag | Reason |
|------|--------|
| `-DHUNTER_ENABLED=OFF` | Disables Hunter package manager; use our manually installed deps instead |
| `-DBOOST_ROOT=/usr/local/boost166` | Point to our Boost 1.66.0 installation |
| `-DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.6` | Use CUDA 12.6 toolkit, not the older system nvcc |
| `-DCUDA_NVCC_FLAGS="--allow-unsupported-compiler"` | GCC 13 is newer than CUDA's officially supported host compilers; this flag bypasses the version check |
| `-DETHASHCUDA=ON` | Enable NVIDIA CUDA mining support |
| `-Djsoncpp_DIR=...` | Force cmake to use our jsoncpp (with static lib) instead of the system one |

---

## Step 8: Build

```bash
cmake --build . -j$(nproc)
```

The final binary will be at:
```
build/ethminer/ethminer
```

Verify:
```bash
./ethminer/ethminer --version
# Expected: ethminer 0.19.0-18+commit.xxxxxxxx
```

---

## Appendix: Source Fixes

If building from a clean clone that does not include the patches already committed to this repo, apply these two fixes manually:

### Fix 1: `libdevcore/vector_ref.h` — missing `<cstdint>`

Add `#include <cstdint>` after the other includes:

```cpp
// Before:
#include <vector>

// After:
#include <vector>
#include <cstdint>
```

### Fix 2: `libethash-cuda/CMakeLists.txt` — CUDA architecture targets

Remove `sm_35` (dropped in CUDA 12+) and add your GPU's compute capability. For RTX 4000 Ada (sm_89):

```cmake
# Remove this line:
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_35,code=sm_35")

# Add this line (Ada Lovelace):
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_89,code=sm_89")
```

Common compute capabilities:
| GPU Generation | Compute Capability |
|---|---|
| Pascal (GTX 10xx) | sm_61 |
| Volta (V100) | sm_70 |
| Turing (RTX 20xx) | sm_75 |
| Ampere (RTX 30xx) | sm_86 |
| Ada Lovelace (RTX 40xx) | sm_89 |

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `'get_io_service' has no member` | System Boost too new (1.70+) | Use Boost 1.66.0 from Step 3 |
| `identifier "_Float32" is undefined` | CUDA 12.0 nvcc + Ubuntu 24.04 glibc mismatch | Install CUDA 12.6 toolkit (Step 2) |
| `no matching function for call to 'CLI::App::add_option'` | CLI11 version too new (2.x) | Install CLI11 1.5.4 (Step 4) |
| `cannot find -ljsoncpp_static` | System jsoncpp has no static library | Build jsoncpp from source (Step 5), pass `-Djsoncpp_DIR` to cmake |
| `error: identifier "_Float32" is undefined` (sm_35) | CUDA 12+ dropped sm_35 support | Remove sm_35 from `libethash-cuda/CMakeLists.txt` |

---

## Running ethminer with tmux

Create a `run.sh` script next to the ethminer executable so you can attach/detach it in a tmux session:

```bash
cat > build/ethminer/run.sh << 'EOF'
#!/bin/bash

while [[ 1 ]]; do ./ethminer -U -P stratum2+tcp://0x96b11d1c5db3e027a6e9dfcf940d67be1f66de78.qkc:x@<root_mining_pool_ip>:8000 --cuda-grid-size 4 --cuda-block-size 128; sleep 1; done
EOF
chmod +x build/ethminer/run.sh
```

Replace `<root_mining_pool_ip>` with your actual mining pool IP address before running.

Start a tmux session and launch:

```bash
tmux new -s miner
cd build/ethminer
./run.sh
```

Detach with `Ctrl+B D`. Reattach later with `tmux attach -t miner`.

> The `while` loop with `sleep 1` ensures ethminer automatically restarts if it crashes.

---

## Power Limit Management

To keep GPU power consumption low, create a `pl.sh` script that continuously re-applies the power limit (the limit can reset after driver events):

```bash
cat > pl.sh << 'EOF'
#!/bin/bash

while [[ 1 ]]; do nvidia-smi -pl 60; sleep 3600; done
EOF
chmod +x pl.sh
```

Run it in a separate tmux window:

```bash
tmux new-window -t miner
sudo ./pl.sh
```

> `nvidia-smi -pl 60` sets the GPU power limit to 60W. Adjust the value to suit your GPU's TDP and efficiency target. The loop re-applies it every hour in case it is reset by the system.
