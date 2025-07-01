#!/bin/bash

LINUX_REPO_DIR="/opt/linux"

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
    fi
fi

HOST_ARCH=$(uname -m)

## Determine which BCM chip to build for
## create gum options for each BCM chip

CHOICE=$(cat */* | gum choose --limit 1 --header "Which Raspberry Pi do you want to build for?")

## find which folder and file this choise is in

FOUND=$(grep -r "^${CHOICE}$")
## loop through FOUND and get the folder and file name
ARCH=$(echo "$FOUND" | cut -d: -f1 | xargs dirname | sed 's/\.\///g' | sort -u | gum choose --limit 1 --header "Select the Architecture for $CHOICE")

echo "Building for ${CHOICE} on ${ARCH}bit architecture."

CONFIG="$(grep -r "^${CHOICE}$" ./${ARCH} | cut -d: -f1 | xargs basename)"

## Make an associative array to hold the kernel names
declare kernel_names

kernel_names["bcm2709"]="kernel7"
kernel_names["bcm2710"]="kernel7l"
kernel_names["bcm2711"]="kernel8"
kernel_names["bcm2712"]="kernel_2712"

KERNEL_NAME="${kernel_names[$CONFIG]}"

## clone repo
if [[ ! -d "${LINUX_REPO_DIR}" ]]; then
    sudo mkdir -p ${LINUX_REPO_DIR}
    sudo git clone --depth=1 https://github.com/raspberrypi/linux ${LINUX_REPO_DIR}
fi

cd ${LINUX_REPO_DIR}
