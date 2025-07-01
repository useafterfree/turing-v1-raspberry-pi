#!/bin/bash

LINUX_REPO_DIR="/opt/linux"
CORES=$(( $(nproc) - 1 ))
HOST_ARCH=$(uname -m)
HOST_BITS=$(getconf LONG_BIT)
if [[ "${HOST_ARCH}" == "x86_64" ]]; then
    HOST_ARCH="amd64"
elif [[ "${HOST_ARCH}" == "armv7l" ]]; then
    HOST_ARCH="arm"
fi

## We need gum to be installed
if ! command -v gum &> /dev/null; then
    echo "gum could not be found, please install it first."
    ## if we are on ubuntu or debian, we can install gum with apt
    if [[ -f /etc/debian_version ]]; then
        echo "Installing gum using apt..."
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
        sudo apt update && sudo apt install gum
    else
        echo "Please install gum manually from https://github.com/charmbracelet/gum"
        exit 1
    fi
fi


## Determine which BCM chip to build for based on raspberry pi model name
## create gum options for each raspberry pi model name

BOARD_CHOICE=$(cat */* | gum choose --limit 1 --header "Which Raspberry Pi do you want to build for?")

## find which folder and file this choise is in

FOUND_ARCHS=$(grep -r "^${BOARD_CHOICE}$")

## if we have multiple board results, we need to choose the architecture manually
if [[ $(echo "$FOUND_ARCHS" | wc -l) -gt 1 ]]; then
    echo "Found multiple results for ${BOARD_CHOICE}. Please select the architecture:"
    ## loop through FOUND and get the folder and file name
    TARGET_BITS=$(echo "$FOUND_ARCHS" | cut -d: -f1 | xargs dirname | sed 's/\.\///g' | sort -u | gum choose --limit 1 --header "Select the Architecture for $BOARD_CHOICE")
else
    TARGET_BITS=$(echo "$FOUND_ARCHS" | cut -d: -f1 | xargs dirname | sed 's/\.\///g')
fi

if [[ -z "${TARGET_BITS}" ]]; then
    echo "No architecture found for ${BOARD_CHOICE}. Exiting..."
    exit 1
fi

if [[ "${TARGET_BITS}" == "32" ]]; then
    TARGET_ARCH="arm"
elif [[ "${TARGET_BITS}" == "64" ]]; then
    TARGET_ARCH="aarch64"
fi

if [[ "${TARGET_ARCH}" != "arm" && "${TARGET_ARCH}" != "aarch64" ]]; then
    echo "Invalid architecture selected: ${TARGET_ARCH}. Please select either 'arm' or 'aarch64'."
    exit 1
fi

echo "Building for ${BOARD_CHOICE} for on ${HOST_ARCH} ${TARGET_ARCH}bit architecture."

CONFIG="$(grep -r "^${BOARD_CHOICE}$" ./${TARGET_BITS} | cut -d: -f1 | xargs basename)"

## Make an associative array to hold the kernel names
declare -A kernel_names

kernel_names["bcm2709"]="kernel7"
kernel_names["bcm2710"]="kernel7l"
kernel_names["bcm2711"]="kernel8"
kernel_names["bcm2712"]="kernel_2712"

export KERNEL_NAME="${kernel_names[$CONFIG]}"

echo "Using kernel name: ${KERNEL_NAME}"

## clone repo
if [[ ! -d "${LINUX_REPO_DIR}" ]]; then
    sudo mkdir -p ${LINUX_REPO_DIR}
    sudo git clone --depth=1 https://github.com/raspberrypi/linux ${LINUX_REPO_DIR}
fi

cd ${LINUX_REPO_DIR}

## Do we need to cross compile?

echo "${HOST_ARCH} architecture detected. We are targeting ${TARGET_ARCH} architecture for our build."

if [[ "${HOST_ARCH}" != "${TARGET_ARCH}" ]]; then
    echo "Cross compiling on ${HOST_ARCH} for ${TARGET_ARCH} architecture..."
    if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
        echo "Setting up cross compilation for 64-bit architecture..."
        export ARCH=arm64
        export CROSS_COMPILE=aarch64-linux-gnu-
        sudo apt install crossbuild-essential-arm64 -y
    else
        echo "Setting up cross compilation for 32-bit architecture..."
        sudo apt install crossbuild-essential-armhf -y
        export ARCH=arm
        export CROSS_COMPILE=arm-linux-gnueabihf-
    fi
else
    echo "Compiling for native architecture..."
    unset ARCH
    unset CROSS_COMPILE
fi

if [[ ! -z "${ARCH}" && ! -z "${CROSS_COMPILE}" ]]; then
    echo "Cross compilation is set up with ARCH=${ARCH} and CROSS_COMPILE=${CROSS_COMPILE}"
else
    echo "No cross compilation is needed, compiling natively."
fi

OPTIONS=" "

if [[ ! -z "${ARCH}" ]]; then
    OPTIONS="${OPTIONS}ARCH=${ARCH} "
fi

if [[ ! -z "${CROSS_COMPILE}" ]]; then
    OPTIONS="${OPTIONS}CROSS_COMPILE=${CROSS_COMPILE} "
fi

sudo make -j${CORES} clean
echo "Executing: sudo make -j${CORES}${OPTIONS}${CONFIG}_defconfig"
sudo make -j${CORES}${OPTIONS}${CONFIG}_defconfig

## Check if the config file has the correct settings for turing-v1
CONFIG_USB_DWCOTG=$(grep -E "^CONFIG_USB_DWCOTG=y" .config)
if [[ -z "${CONFIG_USB_DWCOTG}" ]]; then
    if gum choose "yes" "no" --header "Do you want to enable CONFIG_USB_DWCOTG? This is required for networking to work correctly with ${BOARD_CHOICE} on Turing pi" | grep -q "yes"; then
        echo "Enabling CONFIG_USB_DWCOTG in .config"
        sudo sed -i 's/^# CONFIG_USB_DWCOTG is not set/CONFIG_USB_DWCOTG=y/' .config
    fi
fi

if [[ ${TARGET_BITS} == "64" ]]; then
    CONFIG_ARM64_VA_BITS_48=$(grep -E "^CONFIG_ARM64_VA_BITS_48=y" .config)
    if [[ -z "${CONFIG_ARM64_VA_BITS_48}" ]]; then
        if gum choose "yes" "no" --header "Do you want to enable CONFIG_ARM64_VA_BITS_48? This is required for Istio/Envoy to work correctly with ${BOARD_CHOICE}" | grep -q "yes"; then
            echo "Enabling CONFIG_ARM64_VA_BITS_48 in .config"
            sudo sed -i 's/^# CONFIG_ARM64_VA_BITS_48 is not set/CONFIG_ARM64_VA_BITS_48=y/' .config
        fi
    fi
fi

echo "Building kernel with ${CONFIG} configuration..."

if [[ ${TARGET_BITS} == "64" ]]; then
    echo "Building 64-bit kernel..."
    echo sudo make -j${CORES}${OPTIONS}Image dtbs modules
    sudo make -j${CORES}${OPTIONS}Image dtbs modules
else
    echo "Building 32-bit kernel..."
    echo sudo make -j${CORES}${OPTIONS}zImage dtbs modules
    sudo make -j${CORES}${OPTIONS}zImage dtbs modules
fi
