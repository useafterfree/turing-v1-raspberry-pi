#!/bin/bash

trap 'exit' INT TERM

REPO_DIR=$(pwd)
LINUX_REPO_DIR="/opt/linux"
LAST_CONFIG_FILE="${REPO_DIR}/.config-last"
CORES=$(( $(nproc) - 1 ))
HOST_ARCH=$(uname -m)
HOST_BITS=$(getconf LONG_BIT)

IMAGE_FILE=Image

if [[ "${HOST_ARCH}" == "x86_64" ]]; then
    HOST_ARCH="amd64"
elif [[ "${HOST_ARCH}" == "armv7l" ]]; then
    HOST_ARCH="arm"
fi

check_package() {
    if ! dpkg -s "$1" >/dev/null 2>&1; then
        echo "Package $1 is not installed. Installing..."
        sudo apt install -y "$1"
    fi
}


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

## check build environment
for pkg in bc bison flex libssl-dev make; do check_package "$pkg"; done

## Determine which BCM chip to build for based on raspberry pi model name
## create gum options for each raspberry pi model name
echo "Which Raspberry Pi do you want to build for?"
BOARD_CHOICE=$(gum table < boards.csv)

## We need to split the BOARD_CHOICE to get the Board, BCM chip, and bits
IFS=',' read -r BOARD CONFIG TARGET_BITS <<< "$BOARD_CHOICE"

if [[ ${TARGET_BITS} == "32" ]]; then
    IMAGE_FILE=zImage
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


## Make an associative array to hold the kernel names
declare -A kernel_names

kernel_names["bcm2709"]="kernel7"
kernel_names["bcm2710"]="kernel7l"
kernel_names["bcm2711"]="kernel8"
kernel_names["bcm2712"]="kernel_2712"

export KERNEL="${kernel_names[$CONFIG]}"

echo "Building for ${BOARD} for on ${HOST_ARCH} with ${TARGET_BITS}bit architecture."
echo "Using kernel name: ${KERNEL_NAME}"

## clone repo
if [[ ! -d "${LINUX_REPO_DIR}" ]]; then
    sudo mkdir -p ${LINUX_REPO_DIR}
    sudo git clone --depth=1 https://github.com/raspberrypi/linux ${LINUX_REPO_DIR}
fi


DIRTY=false
## we clean if the options have changed
if [[ -f ${LAST_CONFIG_FILE} ]]; then
    echo "Found previous config file. Checking if we need to clean..."
    if ! grep -q "${BOARD_CHOICE}" ${LAST_CONFIG_FILE}; then
        echo "The previous configuration file does not match the current board choice. Cleaning the build..."
        DIRTY=true
    fi
fi

## Save the current configuration to the last config file
echo "${BOARD_CHOICE}" > ${LAST_CONFIG_FILE}

cd ${LINUX_REPO_DIR}

if [[ "${DIRTY}" == "true" ]]; then
    echo "Cleaning the build ..."
    sudo make -j${CORES} clean
fi

## We just always remove the .config file to start fresh
if [[ -f .config ]]; then
    echo "Removing existing .config file..."
    sudo rm .config
fi

## Do we need to cross compile?

echo "${HOST_ARCH} architecture detected. We are targeting ${TARGET_ARCH} architecture for our build."

if [[ "${HOST_ARCH}" != "${TARGET_ARCH}" ]]; then
    echo "Cross compiling on ${HOST_ARCH} for ${TARGET_ARCH} architecture..."
    if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
        echo "Setting up cross compilation for 64-bit architecture..."
        export ARCH=arm64
        export CROSS_COMPILE=aarch64-linux-gnu-
        check_package crossbuild-essential-arm64
    else
        echo "Setting up cross compilation for 32-bit architecture..."
        check_package crossbuild-essential-armhf
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
fi

OPTIONS=" "

if [[ ! -z "${ARCH}" ]]; then
    OPTIONS="${OPTIONS}ARCH=${ARCH} "
fi

if [[ ! -z "${CROSS_COMPILE}" ]]; then
    OPTIONS="${OPTIONS}CROSS_COMPILE=${CROSS_COMPILE} "
fi

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

copy_kernel_to_disk() {

    DATETIME=$(date +%Y%m%d-%H%M%S)
    echo "🔍 Scanning for block devices..."
    DISK=$(lsblk -dpno NAME,SIZE,MODEL | grep -v "loop" | gum choose --header "Select target disk")
    DISK=$(echo "${DISK}" | awk '{print $1}')
    if [[ -z "${DISK}" ]]; then
        echo "No disk selected. Exiting..."
        exit 1
    fi

    gum confirm && echo "Selected disk: ${DISK}" || exit 1

    sudo mkdir -p mnt/boot
    sudo mkdir -p mnt/root
    sudo mount ${DISK}1 mnt/boot
    sudo mount ${DISK}2 mnt/root

    sudo env PATH=$PATH make -j${CORES}${OPTIONS}INSTALL_MOD_PATH=mnt/root modules_install

    sudo cp mnt/boot/$KERNEL.img mnt/boot/$KERNEL-backup-${DATETIME}.img
    sudo cp arch/${TARGET_ARCH}/boot/${IMAGE_FILE} mnt/boot/$KERNEL.img
    sudo cp arch/${TARGET_ARCH}/boot/dts/broadcom/*.dtb mnt/boot/
    sudo cp arch/${TARGET_ARCH}/boot/dts/overlays/*.dtb* mnt/boot/overlays/
    sudo cp arch/${TARGET_ARCH}/boot/dts/overlays/README mnt/boot/overlays/
    sudo umount mnt/boot
    sudo umount mnt/root

    IMAGE_ANOTHER=$(gum choose "yes" "no" --header "Do you want to copy the kernel image to another disk?")
    echo "Kernel image copied to ${DISK} successfully."
    if [[ "${IMAGE_ANOTHER}" == "yes" ]]; then
        copy_kernel_to_disk
    fi
}

echo "Building ${TARGET_BITS}-bit kernel with ${CONFIG} configuration..."
echo sudo make -j${CORES}${OPTIONS}${IMAGE_FILE} dtbs modules
if sudo make -j${CORES}${OPTIONS}${IMAGE_FILE} dtbs modules; then
    echo "Kernel build successful."
    copy_kernel_to_disk
else
    echo "Kernel build failed. Please check the output for errors."
    exit 1
fi
