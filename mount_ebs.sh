#!/bin/bash

# Script to mount an EBS volume image using Docker
# Usage: ./mount_ebs.sh -i <ebs_image_file> [-p <partition_number> | -l]

set -e

# Function to display usage
usage() {
    echo "Usage: $0 -i <ebs_image_file> [-p <partition_number> | -l]"
    echo "Options:"
    echo "  -i <ebs_image_file>   EBS image file to mount (required)"
    echo "  -p <partition_number> Partition number to mount (default: 1)"
    echo "  -l                    List partitions only, don't mount"
    echo ""
    echo "Example: $0 -i vol-04407893e41e1f1c2 -p 1"
    echo "Example: $0 -i vol-04407893e41e1f1c2 -l"
    exit 1
}

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo "Error: Docker daemon is not running. Please start Docker first."
    exit 1
fi

# Parse command line arguments
EBS_IMAGE=""
PARTITION="1"  # Default to partition 1
LIST_ONLY=false

while getopts "i:p:l" opt; do
    case $opt in
        i) EBS_IMAGE="$OPTARG" ;;
        p) PARTITION="$OPTARG" ;;
        l) LIST_ONLY=true ;;
        *) usage ;;
    esac
done

# Check if EBS image is provided
if [ -z "$EBS_IMAGE" ]; then
    echo "Error: EBS image file is required."
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_DIR="${SCRIPT_DIR}/mnt"

# Check if the EBS image file exists
if [ ! -f "$EBS_IMAGE" ]; then
    echo "Error: EBS image file '$EBS_IMAGE' not found."
    exit 1
fi

# Create mount directory if it doesn't exist
mkdir -p "${MOUNT_DIR}"

# If list-only mode, just show partitions and exit
if [ "$LIST_ONLY" = true ]; then
    echo "Listing partitions in EBS image: $EBS_IMAGE"
    
    docker run --rm \
        -v "$(realpath "$EBS_IMAGE"):/ebs.img" \
        ubuntu:22.04 bash -c "
        apt-get update && apt-get install -y fdisk util-linux
        echo 'EBS image details:'
        fdisk -l /ebs.img
        "
    exit 0
fi

echo "Starting Docker container to mount EBS image..."
echo "EBS Image: $EBS_IMAGE"
echo "Partition: $PARTITION"
echo "Mount Directory: $MOUNT_DIR"

# Create a unique container name to avoid conflicts
CONTAINER_NAME="ebs_mount_$(date +%s)"

# First, run a container to mount the volume and prepare it
MOUNT_SUCCESS=$(docker run --rm \
    --privileged \
    -v "$(realpath "$EBS_IMAGE"):/ebs.img" \
    -v "${MOUNT_DIR}:/mnt" \
    ubuntu:22.04 bash -c "
    apt-get update && apt-get install -y fdisk util-linux
    echo 'EBS image details:'
    fdisk -l /ebs.img
    
    # Get partition information
    PART_INFO=\$(fdisk -l /ebs.img | grep -E \"/ebs.img${PARTITION}\\s\")
    
    if [ -z \"\$PART_INFO\" ]; then
        echo \"Error: Partition ${PARTITION} not found in the EBS image.\"
        echo \"Available partitions:\"
        fdisk -l /ebs.img | grep -E \"/ebs.img[0-9]+\\s\"
        exit 1
    fi
    
    # Extract start sector and sector size
    START_SECTOR=\$(echo \"\$PART_INFO\" | awk '{print \$2}')
    SECTOR_SIZE=\$(fdisk -l /ebs.img | grep 'Sector size' | awk '{print \$4}')
    
    if [ -z \"\$START_SECTOR\" ] || [ -z \"\$SECTOR_SIZE\" ]; then
        echo \"Error: Could not determine partition offset.\"
        exit 1
    fi
    
    # Calculate offset in bytes
    OFFSET=\$((\$START_SECTOR * \$SECTOR_SIZE))
    echo \"Mounting partition ${PARTITION} at offset \$OFFSET bytes (sector \$START_SECTOR)...\"
    
    mkdir -p /mnt/ebs
    
    # Try to mount with common filesystems
    MOUNTED=false
    for fs in ext4 ext3 ext2 xfs btrfs; do
        echo \"Trying \$fs filesystem...\"
        if mount -t \$fs -o loop,offset=\$OFFSET /ebs.img /mnt/ebs 2>/dev/null; then
            echo \"Successfully mounted as \$fs filesystem.\"
            MOUNTED=true
            break
        fi
    done
    
    # If all specific filesystems failed, try auto detection
    if [ \"\$MOUNTED\" = false ]; then
        echo \"Trying auto filesystem detection...\"
        if mount -o loop,offset=\$OFFSET /ebs.img /mnt/ebs 2>/dev/null; then
            echo \"Successfully mounted with auto filesystem detection.\"
            MOUNTED=true
        fi
    fi
    
    # Check if mount was successful
    if [ \"\$MOUNTED\" = true ]; then
        echo \"EBS volume mounted successfully at /mnt/ebs inside the container.\"
        echo \"Files in the mounted volume:\"
        ls -la /mnt/ebs
        echo \"success\"
    else
        echo \"Failed to mount the partition. It might have an unsupported filesystem.\"
        echo \"Available filesystems in the kernel:\"
        cat /proc/filesystems
        exit 1
    fi
    " 2>&1)

# Check if the mount was successful
if ! echo "$MOUNT_SUCCESS" | grep -q "success"; then
    echo "Failed to mount the EBS volume."
    echo "$MOUNT_SUCCESS"
    exit 1
fi

echo ""
echo "EBS volume mounted successfully. Starting interactive shell..."
echo "You will be dropped into the container with the mounted volume."
echo "The mounted volume is available at /mnt/ebs"
echo "To exit and unmount, type 'exit' or press Ctrl+D"
echo ""

# Store the partition information for the interactive container
PART_INFO=$(echo "$MOUNT_SUCCESS" | grep "Mounting partition ${PARTITION} at offset" || echo "")
OFFSET=$(echo "$PART_INFO" | grep -o "offset [0-9]* bytes" | awk '{print $2}' || echo "")
FS_TYPE=$(echo "$MOUNT_SUCCESS" | grep "Successfully mounted as" | awk '{print $4}' || echo "")

if [ -z "$OFFSET" ]; then
    echo "Error: Could not determine partition offset from previous mount."
    exit 1
fi

# Now start an interactive container with the same mounts
docker run -it --rm \
    --privileged \
    -v "$(realpath "$EBS_IMAGE"):/ebs.img" \
    -v "${MOUNT_DIR}:/mnt" \
    --name "$CONTAINER_NAME" \
    --workdir /mnt/ebs \
    ubuntu:22.04 bash -c "
    # Install necessary tools
    apt-get update && apt-get install -y fdisk util-linux
    
    # Create mount point
    mkdir -p /mnt/ebs
    
    # Mount the partition using the offset we already determined
    if [ -n \"$FS_TYPE\" ]; then
        # If we know the filesystem type, use it
        mount -t $FS_TYPE -o loop,offset=$OFFSET /ebs.img /mnt/ebs
    else
        # Otherwise try auto detection
        mount -o loop,offset=$OFFSET /ebs.img /mnt/ebs
    fi
    
    if ! mountpoint -q /mnt/ebs; then
        echo \"Failed to mount the volume in the interactive container.\"
        exit 1
    fi
    
    echo \"\"
    echo \"EBS volume mounted at /mnt/ebs\"
    echo \"You are now in the mounted directory.\"
    echo \"Type 'exit' or press Ctrl+D to unmount and exit.\"
    echo \"\"
    
    # Start an interactive shell in the mounted directory
    cd /mnt/ebs
    bash
    
    # Clean up when the user exits
    echo \"Unmounting volume...\"
    cd /
    umount /mnt/ebs
    "

echo "EBS volume unmounted." 