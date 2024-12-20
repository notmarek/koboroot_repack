#!/bin/sh
set -e

# This script drives the update. It is extracted to /tmp by the OS and executed.
#
# Usage:
# driver.sh <update-path> stage1|stage2
#
#   <update-path>   Path to the update archive that shall be processed
#   stage1          The system is currently booted into the rootfs
#   stage2          The system is currently booted into the recoveryfs
#
# stage1 images:
#   recoveryfs, kernel, uboot, bl2, tee, hwcfg, ntxfw
#
# stage2 images:
#   vendor, rootfs

if [ $# -lt 2 -o $# -gt 3 ]; then
    echo "Invalid usage!"
    exit 1
fi


ARCHIVE="$1"
STAGE="$2"
PRODUCT="${3:-$PRODUCT}"

if [ -z "$PRODUCT" ]; then
    echo "No PRODUCT specified. Assuming monza for compat."
    PRODUCT="monzaTolino"
fi


# the versions without branding (spaBW, monza, ...) are for the qt5 legacy update
case $PRODUCT in
    monzaTolino|monzaKobo|monza)
        device_dir="monza"
        ;;
    spaTolinoBW|spaKoboBW|spaBW)
        device_dir="spa-bw"
        ;;
    spaTolinoColour|spaKoboColour|spaColour)
        device_dir="spa-colour"
        ;;
    *)
        echo "Device not supported: $PRODUCT"
        exit 1
esac


DECOMPRESSOR="/tmp/updater/decompressor"


set_boot_part() {
    case $1 in
        recovery)
            part="/dev/disk/by-partlabel/recovery"
            ;;
        root)
            part="/dev/disk/by-partlabel/system_a"
            ;;
        default)
            echo "Invalid argument" >&2
            exit 1
    esac

    part=$(readlink -f $part)
    partno=$(echo $part | egrep -o '[0-9]+$')
    echo "Setting boot partition number to $partno"
    ntx_hwconfig -S 1 -p /dev/disk/by-partlabel/hwcfg BootPartNo $partno
}


has_file() {
    local filename="$1"
    tar -tf "${ARCHIVE}" "${filename}" >/dev/null 2>&1
}


try_flash_image() {
    local imgname="$1"
    local partlabel="$2"

    if [ ! -e "/dev/disk/by-partlabel/${partlabel}" ]; then
        echo "Partlabel ${partlabel} does not exist!"
        exit 1
    fi

    if has_file "${imgname}"; then
        echo "Flashing ${imgname}..."
        tar -xOf "${ARCHIVE}" "${imgname}" | ${DECOMPRESSOR} | dd bs=4M of="/dev/disk/by-partlabel/${partlabel}"
    else
        echo "NOT flashing ${imgname}"
        return 1
    fi
}

flash_image() {
    try_flash_image "$1" "$2" || true
}


extract_file() {
    local filename="$1"
    local dest="$2"

    if has_file "${filename}"; then
        if ! tar -xOf "${ARCHIVE}" "${filename}" | ${DECOMPRESSOR} > "${dest}"; then
            echo "Extraction of ${filename} failed"
            return 1
        fi
        return 0
    fi

    return 1
}


check_checksums() {
    echo "Checking update checksums"

    local tempfile=$(mktemp)
    local csum fname

    if ! extract_file "sha2-256sums" "/tmp/updater/sha2-256sums"; then
        echo "Extracting checksum file failed. Missing or corrupted?"
        exit 1
    fi

    cat /tmp/updater/sha2-256sums | while read csum fname; do
        echo "${fname} ?= ${csum}"
        # we need TWO spaces in the echo string for some reason -.-
        # the tempfile is required because the shell on the qt5 rootfs does not support the <(...) syntax -.-
        echo "${csum}  -" > $tempfile
        if ! tar -xOf "${ARCHIVE}" "${fname}" | sha256sum -c $tempfile; then
            echo "Checksum failed: $fname"
            exit 1
        fi
    done

    rm $tempfile
    echo "Checksums OK"
}


#if extract_file "update_script" "/tmp/update_script"; then
#    HAS_SCRIPT=true
#    /tmp/update_script "${ARCHIVE}" "${STAGE}" "pre"
#else
#    HAS_SCRIPT=false
#fi


# prior to every stage we need to extract the decompressor
mkdir -p /tmp/updater
tar -C /tmp/updater -xf "${ARCHIVE}" "decompressor"

# make sure it executes
[ -x $DECOMPRESSOR ]


case $STAGE in
    stage1)
        extract_file "KoboRoot.tgz" "/tmp/updater/KoboRoot.tgz"
        tar -C /tmp/updater -xf "${ARCHIVE}" "KoboRoot.tgz"
	    gunzip -t /tmp/updater/KoboRoot.tgz && tar zxf /tmp/updater/KoboRoot.tgz -C / && ( cat /usr/local/Kobo/revinfo >> /usr/local/Kobo/install.log )
        # by exitting with an error we prevent a reboot into recoveryfs, we don't need to go there
        # We could also do our KoboRoot shenanigons inside the recovery to make sure non of the files being replaced are in use
        exit 1
        ;;

    stage2)
        # flash rootfs
        # the rootfs is either located in the update package or in the recoveryfs.
        #
        # If it's in the update, then recovery was not updated (normal case).
        # If it's in the recovery, then recovery was updated and it makes no sense to ship the image twice.
        # if ! try_flash_image "rootfs.img" "system_a"; then
        #     if has_file "stock-rootfs"; then
        #         # we flash our own rootfs from /recovery
        #         echo "Flashing stock rootfs"
        #         unzstd /recovery/rootfs.ext4.zst --stdout | dd bs=4M of="/dev/disk/by-partlabel/system_a"
        #     else
        #         echo "Not flashing any rootfs."
        #     fi
        # fi

        # flash_image "vendor.img" "vendor"

        # set rootfs as boot partition
        set_boot_part root
        ;;
    pack)
        if [ -f KoboRoot.tgz ]; then
            echo "Compressing KoboRoot.tgz with zstd..."
            zstd KoboRoot.tgz && mv KoboRoot.tgz.zst KoboRoot.zst
            echo "Packing files into update.tar"
            tar update.tar KoboRoot.tgz driver.sh decompressor.sh
            echo "KoboRoot.tgz repacked!"
        else
            echo "KoboRoot.tgz not present, aborting!"
        fi
        ;;
esac

sync

#if $HAS_SCRIPT; then
#    /tmp/update_script "${ARCHIVE}" "${STAGE}" "post"
#fi
