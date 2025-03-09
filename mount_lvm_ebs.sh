#!/bin/bash

# Script to mount an EBS volume image with LVM using Docker
# Usage: ./mount_lvm_ebs.sh -i <ebs_image_file> [-l]

set -e

# Function to display usage
usage() {
    echo "Usage: $0 -i <ebs_image_file> [-l]"
    echo "Options:"
    echo "  -i <ebs_image_file>   EBS image file to mount (required)"
    echo "  -l                    List LVM volumes only, don't mount"
    echo ""
    echo "Example: $0 -i vol-04407893e41e1f1c2"
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
LIST_ONLY=false

while getopts "i:l" opt; do
    case $opt in
        i) EBS_IMAGE="$OPTARG" ;;
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

# If list-only mode, just show LVM volumes and exit
if [ "$LIST_ONLY" = true ]; then
    echo "Listing LVM volumes in EBS image: $EBS_IMAGE"
    
    docker run --rm --privileged \
        -v "$(realpath "$EBS_IMAGE"):/ebs.img" \
        ubuntu:22.04 bash -c "
        apt-get update && apt-get install -y fdisk lvm2 util-linux
        echo 'EBS image details:'
        fdisk -l /ebs.img
        
        # Set up loop device
        LOOP_DEVICE=\$(losetup -f)
        losetup \$LOOP_DEVICE /ebs.img
        
        # Scan for partitions on the loop device
        partprobe \$LOOP_DEVICE
        
        # List partitions
        echo 'Partitions found:'
        ls -la \${LOOP_DEVICE}*
        
        # Scan for volume groups
        echo 'Scanning for LVM volume groups...'
        vgscan
        
        # Activate all volume groups
        echo 'Activating volume groups...'
        vgchange -ay
        
        # List logical volumes
        echo 'Available logical volumes:'
        lvs
        
        # Clean up
        losetup -d \$LOOP_DEVICE
        "
    exit 0
fi

echo "Starting Docker container to mount LVM EBS image..."
echo "EBS Image: $EBS_IMAGE"
echo "Mount Directory: $MOUNT_DIR"

# Create a unique container name to avoid conflicts
CONTAINER_NAME="ebs_lvm_mount_$(date +%s)"

# First, run a container to check if we can mount the volume
MOUNT_SUCCESS=$(docker run --rm --privileged \
    -v "$(realpath "$EBS_IMAGE"):/ebs.img" \
    -v "${MOUNT_DIR}:/mnt" \
    ubuntu:22.04 bash -c "
    apt-get update && apt-get install -y fdisk lvm2 util-linux
    echo 'EBS image details:'
    fdisk -l /ebs.img
    
    # Set up loop device
    LOOP_DEVICE=\$(losetup -f)
    losetup \$LOOP_DEVICE /ebs.img
    
    # Scan for partitions on the loop device
    partprobe \$LOOP_DEVICE
    
    # List partitions
    echo 'Partitions found:'
    ls -la \${LOOP_DEVICE}*
    
    # Scan for volume groups
    echo 'Scanning for LVM volume groups...'
    vgscan
    
    # Activate all volume groups
    echo 'Activating volume groups...'
    vgchange -ay
    
    # List logical volumes
    echo 'Available logical volumes:'
    lvs
    
    # If no logical volumes found, try to mount partitions directly
    if [ \$(lvs | wc -l) -le 1 ]; then
        echo 'No logical volumes found. Trying to mount partitions directly...'
        MOUNTED=false
        for part in \${LOOP_DEVICE}p*; do
            if [ -e \$part ]; then
                echo \"Trying to mount \$part...\"
                mkdir -p /mnt/ebs
                if mount \$part /mnt/ebs 2>/dev/null; then
                    echo \"Successfully mounted \$part to /mnt/ebs\"
                    MOUNTED=true
                    break
                else
                    echo \"Failed to mount \$part\"
                fi
            fi
        done
        
        if [ \"\$MOUNTED\" = true ]; then
            echo \"success\"
        else
            echo \"Failed to mount any partition.\"
            losetup -d \$LOOP_DEVICE
            exit 1
        fi
    else
        # Get the first logical volume path
        LV_PATH=\$(lvs --noheadings -o lv_path | tr -d ' ' | head -n1)
        
        if [ -n \"\$LV_PATH\" ]; then
            echo \"Mounting logical volume \$LV_PATH...\"
            mkdir -p /mnt/ebs
            if mount \$LV_PATH /mnt/ebs; then
                echo \"LVM volume mounted successfully at /mnt/ebs inside the container.\"
                echo \"success\"
            else
                echo \"Failed to mount logical volume.\"
                losetup -d \$LOOP_DEVICE
                exit 1
            fi
        else
            echo \"Error: No logical volumes found to mount.\"
            losetup -d \$LOOP_DEVICE
            exit 1
        fi
    fi
    
    # Clean up
    umount /mnt/ebs
    losetup -d \$LOOP_DEVICE
    " 2>&1)

# Check if the mount was successful
if ! echo "$MOUNT_SUCCESS" | grep -q "success"; then
    echo "Failed to mount the EBS volume."
    echo "$MOUNT_SUCCESS"
    exit 1
fi

echo ""
echo "EBS volume can be mounted. Starting interactive shell..."
echo "You will be dropped into the container with the mounted volume."
echo "The mounted volume will be available at /mnt/ebs"
echo "To exit and unmount, type 'exit' or press Ctrl+D"
echo ""

# Now start an interactive container with the same mounts
docker run -it --rm --privileged \
    -v "$(realpath "$EBS_IMAGE"):/ebs.img" \
    -v "${MOUNT_DIR}:/mnt" \
    --name "$CONTAINER_NAME" \
    ubuntu:22.04 bash -c "
    # Install necessary tools
    apt-get update && apt-get install -y fdisk lvm2 util-linux
    
    # Set up loop device
    LOOP_DEVICE=\$(losetup -f)
    losetup \$LOOP_DEVICE /ebs.img
    
    # Scan for partitions
    partprobe \$LOOP_DEVICE
    
    # Scan and activate LVM
    vgscan
    vgchange -ay
    
    # Try to mount LVM volume
    LV_PATH=\$(lvs --noheadings -o lv_path | tr -d ' ' | head -n1)
    MOUNTED=false
    
    if [ -n \"\$LV_PATH\" ]; then
        echo \"Mounting logical volume \$LV_PATH...\"
        mkdir -p /mnt/ebs
        if mount \$LV_PATH /mnt/ebs; then
            echo \"LVM volume mounted successfully at /mnt/ebs\"
            MOUNTED=true
        fi
    fi
    
    # If LVM mount failed, try partitions
    if [ \"\$MOUNTED\" = false ]; then
        for part in \${LOOP_DEVICE}p*; do
            if [ -e \$part ]; then
                echo \"Trying to mount \$part...\"
                mkdir -p /mnt/ebs
                if mount \$part /mnt/ebs 2>/dev/null; then
                    echo \"Successfully mounted \$part to /mnt/ebs\"
                    MOUNTED=true
                    break
                fi
            fi
        done
    fi
    
    if [ \"\$MOUNTED\" = false ]; then
        echo \"Failed to mount the volume.\"
        losetup -d \$LOOP_DEVICE
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
    vgchange -an
    losetup -d \$LOOP_DEVICE
    "

echo "EBS volume unmounted." 