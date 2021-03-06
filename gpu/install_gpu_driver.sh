#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS-IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This script installs NVIDIA GPU drivers and collects GPU utilization metrics.

set -euxo pipefail

function get_metadata_attribute() {
  local -r attribute_name=$1
  local -r default_value=$2
  /usr/share/google/get_metadata_value "attributes/${attribute_name}" || echo -n "${default_value}"
}

OS_NAME=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
readonly OS_NAME
OS_DIST=$(lsb_release -cs)
readonly OS_DIST

# Prameters for NVIDIA-provided Debian GPU driver
readonly DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_URL='http://us.download.nvidia.com/tesla/418.87/NVIDIA-Linux-x86_64-418.87.00.run'
readonly NVIDIA_DEBIAN_GPU_DRIVER_URL=$(get_metadata_attribute 'gpu-driver-url' "${DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_URL}")
readonly DEFAULT_NVIDIA_DEBIAN_CUDA_URL='https://developer.nvidia.com/compute/cuda/10.0/Prod/local_installers/cuda_10.0.130_410.48_linux'
readonly NVIDIA_DEBIAN_CUDA_URL=$(get_metadata_attribute 'cuda-url' "${DEFAULT_NVIDIA_DEBIAN_CUDA_URL}")

# Prameters for NVIDIA-provided Ubuntu GPU driver
readonly CUDA_VERSION=$(get_metadata_attribute 'cuda-version' '10.0')
readonly NVIDIA_UBUNTU_REPOSITORY_URL='https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64'
readonly NVIDIA_UBUNTU_REPOSITORY_KEY="${NVIDIA_UBUNTU_REPOSITORY_URL}/7fa2af80.pub"
readonly NVIDIA_UBUNTU_REPOSITORY_CUDA_PIN="${NVIDIA_UBUNTU_REPOSITORY_URL}/cuda-ubuntu1804.pin"

# Prameters for Ubuntu-provided NVIDIA GPU driver
readonly NVIDIA_DRIVER_VERSION_UBUNTU='435'

# Whether to install NVIDIA-provided or OS-provided GPU driver
GPU_DRIVER_PROVIDER=$(get_metadata_attribute 'gpu-driver-provider' 'OS')
readonly GPU_DRIVER_PROVIDER

# Stackdriver GPU agent parameters
readonly GPU_AGENT_REPO_URL='https://raw.githubusercontent.com/GoogleCloudPlatform/ml-on-gcp/master/dlvm/gcp-gpu-utilization-metrics'
# Whether to install GPU monitoring agent that sends GPU metrics to Stackdriver
INSTALL_GPU_AGENT=$(get_metadata_attribute 'install-gpu-agent' 'false')
readonly INSTALL_GPU_AGENT

function execute_with_retries() {
  local -r cmd=$1
  for ((i = 0; i < 10; i++)); do
    if eval "$cmd"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# Install NVIDIA GPU driver provided by NVIDIA
function install_nvidia_gpu_driver() {
  if [[ ${OS_NAME} == debian ]]; then
    wget -nv --timeout=30 --tries=5 --retry-connrefused \
      "${NVIDIA_DEBIAN_GPU_DRIVER_URL}" -O driver.run
    bash "./driver.run" --silent

    wget -nv --timeout=30 --tries=5 --retry-connrefused "${NVIDIA_DEBIAN_CUDA_URL}" -O cuda.run
    bash "./cuda.run" --silent --toolkit --no-opengl-libs
  elif [[ ${OS_NAME} == ubuntu ]]; then
    wget -nv --timeout=30 --tries=5 --retry-connrefused \
      "${NVIDIA_UBUNTU_REPOSITORY_CUDA_PIN}" -O /etc/apt/preferences.d/cuda-repository-pin-600

    curl --retry 5 "${NVIDIA_UBUNTU_REPOSITORY_KEY}" | apt-key add -
    add-apt-repository "deb ${NVIDIA_UBUNTU_REPOSITORY_URL} /"
    execute_with_retries "apt-get update"

    if [[ -n "${CUDA_VERSION}" ]]; then
      local -r cuda_package=cuda-${CUDA_VERSION//./-}
    else
      local -r cuda_package=cuda
    fi
    # Without --no-install-recommends this takes a very long time.
    execute_with_retries "apt-get install -y -q --no-install-recommends ${cuda_package}"
  else
    echo "Unsupported OS: '${OS_NAME}'"
    exit 1
  fi

  echo "NVIDIA GPU driver provided by NVIDIA was installed successfully"
}

# Install NVIDIA GPU driver provided by OS distribution
function install_os_gpu_driver() {
  local packages=(nvidia-cuda-toolkit)
  local modules=(nvidia-drm nvidia-uvm drm)

  # Add non-free Debian packages.
  # See https://www.debian.org/distrib/packages#note
  if [[ ${OS_NAME} == debian ]]; then
    for type in deb deb-src; do
      for distro in ${OS_DIST} ${OS_DIST}-backports; do
        echo "${type} http://deb.debian.org/debian ${distro} contrib non-free" \
          >>/etc/apt/sources.list.d/non-free.list
      done
    done
    execute_with_retries "apt-get update"

    packages+=(nvidia-driver nvidia-kernel-common nvidia-smi)
    modules+=(nvidia-current)
    local -r nvblas_cpu_blas_lib=/usr/lib/libblas.so
  elif [[ ${OS_NAME} == ubuntu ]]; then
    # Ubuntu-specific NVIDIA driver packages and modules
    packages+=("nvidia-driver-${NVIDIA_DRIVER_VERSION_UBUNTU}"
      "nvidia-kernel-common-${NVIDIA_DRIVER_VERSION_UBUNTU}")
    modules+=(nvidia)
    local -r nvblas_cpu_blas_lib=/usr/lib/x86_64-linux-gnu/libblas.so
  else
    echo "Unsupported OS: '${OS_NAME}'"
    exit 1
  fi

  # Install proprietary NVIDIA drivers and CUDA
  # See https://wiki.debian.org/NvidiaGraphicsDrivers
  # Without --no-install-recommends this takes a very long time.
  execute_with_retries \
    "apt-get install -y -q -t ${OS_DIST}-backports --no-install-recommends ${packages[*]}"

  # Create a system wide NVBLAS config
  # See http://docs.nvidia.com/cuda/nvblas/
  local -r nvblas_config_file=/etc/nvidia/nvblas.conf
  # Create config file if it does not exist - this file doesn't exist by default in Ubuntu
  mkdir -p "$(dirname ${nvblas_config_file})"
  cat <<EOF >>${nvblas_config_file}
# Insert here the CPU BLAS fallback library of your choice.
# The standard libblas.so.3 defaults to OpenBLAS, which does not have the
# requisite CBLAS API.
NVBLAS_CPU_BLAS_LIB ${nvblas_cpu_blas_lib}
# Use all GPUs
NVBLAS_GPU_LIST ALL
# Add more configuration here.
EOF
  echo "NVBLAS_CONFIG_FILE=${nvblas_config_file}" >>/etc/environment

  # Rebooting during an initialization action is not recommended, so just
  # dynamically load kernel modules. If you want to run an X server, it is
  # recommended that you schedule a reboot to occur after the initialization
  # action finishes.
  modprobe -r nouveau
  modprobe "${modules[@]}"

  # Restart any NodeManagers, so they pick up the NVBLAS config.
  if systemctl status hadoop-yarn-nodemanager; then
    # Kill Node Manager to prevent unregister/register cycle
    systemctl kill -s KILL hadoop-yarn-nodemanager
  fi

  echo "NVIDIA GPU driver provided by ${OS_NAME} was installed successfully"
}

# Collects 'gpu_utilization' and 'gpu_memory_utilization' metrics
function install_gpu_agent() {
  if ! command -v pip; then
    execute_with_retries "apt-get install -y -q python-pip"
  fi
  local install_dir=/opt/gpu-utilization-agent
  mkdir "${install_dir}"
  wget -nv --timeout=30 --tries=5 --retry-connrefused \
    "${GPU_AGENT_REPO_URL}/requirements.txt" -P "${install_dir}"
  wget -nv --timeout=30 --tries=5 --retry-connrefused \
    "${GPU_AGENT_REPO_URL}/report_gpu_metrics.py" -P "${install_dir}"
  pip install -r "${install_dir}/requirements.txt"

  # Generate GPU service.
  cat <<EOF >/lib/systemd/system/gpu-utilization-agent.service
[Unit]
Description=GPU Utilization Metric Agent

[Service]
Type=simple
PIDFile=/run/gpu_agent.pid
ExecStart=/bin/bash --login -c 'python "${install_dir}/report_gpu_metrics.py"'
User=root
Group=root
WorkingDirectory=/
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  # Reload systemd manager configuration
  systemctl daemon-reload
  # Enable gpu-utilization-agent service
  systemctl --now enable gpu-utilization-agent.service
}

function main() {
  if [[ ${OS_NAME} != debian ]] && [[ ${OS_NAME} != ubuntu ]]; then
    echo "Unsupported OS: '${OS_NAME}'"
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive

  execute_with_retries "apt-get update"
  execute_with_retries "apt-get install -y -q pciutils"

  # Detect NVIDIA GPU
  if ! (lspci | grep -q NVIDIA); then
    echo 'No NVIDIA card detected. Skipping installation.' >&2
    exit 0
  fi

  execute_with_retries "apt-get install -y -q 'linux-headers-$(uname -r)'"
  if [[ ${GPU_DRIVER_PROVIDER} == 'NVIDIA' ]]; then
    install_nvidia_gpu_driver
  elif [[ ${GPU_DRIVER_PROVIDER} == 'OS' ]]; then
    install_os_gpu_driver
  else
    echo "Unsupported GPU driver provider: '${GPU_DRIVER_PROVIDER}'"
    exit 1
  fi

  # Install GPU metrics collection in Stackdriver if needed
  if [[ ${INSTALL_GPU_AGENT} == true ]]; then
    install_gpu_agent
    echo 'GPU agent successfully deployed.'
  else
    echo 'GPU metrics will not be installed.'
  fi
}

main
