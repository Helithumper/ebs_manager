#!/usr/bin/env python3
"""
EBS Volume Manager - A utility for managing AWS EBS volumes.

This script allows you to list all EBS volumes in your AWS account and
download them to your local machine using EBS direct APIs.
"""

import argparse
import concurrent.futures
import json
import logging
import os
import sys
from typing import Dict, List, Optional, Tuple, Union

import boto3
import tqdm
from botocore.exceptions import ClientError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler()],
)
logger = logging.getLogger("ebs-manager")


def setup_logger(verbose: bool = False) -> None:
    """Configure the logger based on verbosity level.

    Args:
        verbose: If True, set log level to DEBUG, otherwise INFO
    """
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    # Set boto3 and botocore to only log warnings and errors
    logging.getLogger("boto3").setLevel(logging.WARNING)
    logging.getLogger("botocore").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)


def list_ebs_volumes(region: Optional[str] = None) -> None:
    """List all EBS volumes in the current AWS account.

    Args:
        region: AWS region to use. If None, uses the default region.
    """
    ec2 = boto3.client("ec2", region_name=region)

    try:
        logger.info(f"Fetching EBS volumes{' in region ' + region if region else ''}...")
        response = ec2.describe_volumes()
        volumes = response.get("Volumes", [])

        if not volumes:
            logger.info(
                f"No EBS volumes found in the current AWS account{' in region ' + region if region else ''}."
            )
            return

        # Get all instance IDs that have volumes attached
        instance_ids = []
        for volume in volumes:
            for attachment in volume.get("Attachments", []):
                instance_id = attachment.get("InstanceId")
                if instance_id and instance_id not in instance_ids:
                    instance_ids.append(instance_id)

        # Get instance details if there are any instances
        instances = {}
        if instance_ids:
            logger.debug(f"Fetching details for {len(instance_ids)} instances...")
            instance_response = ec2.describe_instances(InstanceIds=instance_ids)
            for reservation in instance_response.get("Reservations", []):
                for instance in reservation.get("Instances", []):
                    instance_id = instance.get("InstanceId")
                    # Get instance name from tags
                    instance_name = "N/A"
                    for tag in instance.get("Tags", []):
                        if tag.get("Key") == "Name":
                            instance_name = tag.get("Value")
                            break
                    instances[instance_id] = instance_name

        print(f"Found {len(volumes)} EBS volumes{' in region ' + region if region else ''}:")
        print("-" * 120)
        print(
            f"{'Volume ID':<25} {'Name':<20} {'Size (GB)':<10} {'State':<10} {'Type':<10} {'Instance ID':<20} {'Instance Name':<20}"
        )
        print("-" * 120)

        for volume in volumes:
            volume_id = volume.get("VolumeId", "N/A")
            size = volume.get("Size", "N/A")
            state = volume.get("State", "N/A")
            volume_type = volume.get("VolumeType", "N/A")

            # Get volume name from tags
            volume_name = "N/A"
            for tag in volume.get("Tags", []):
                if tag.get("Key") == "Name":
                    volume_name = tag.get("Value")
                    break

            # Get attached instance information
            instance_id = "N/A"
            instance_name = "N/A"
            for attachment in volume.get("Attachments", []):
                instance_id = attachment.get("InstanceId", "N/A")
                instance_name = instances.get(instance_id, "N/A")
                break

            print(
                f"{volume_id:<25} {volume_name[:18] + '...' if len(volume_name) > 18 else volume_name:<20} {size:<10} {state:<10} {volume_type:<10} {instance_id:<20} {instance_name[:18] + '...' if len(instance_name) > 18 else instance_name:<20}"
            )

        print("-" * 120)

    except ClientError as e:
        logger.error(f"Error listing EBS volumes: {e}")
        sys.exit(1)


def download_snapshot_block(
    ebs_client,
    snapshot_id: str,
    block_index: int,
    block_token: str,
    output_file: str,
    start_offset: int,
) -> Optional[int]:
    """Download a single block from a snapshot and write it to the output file at the specified offset.

    Args:
        ebs_client: Boto3 EBS client
        snapshot_id: ID of the snapshot to download from
        block_index: Index of the block to download
        block_token: Token for the block to download
        output_file: Path to the output file
        start_offset: Offset in the output file to write the block data

    Returns:
        The block index if successful, None otherwise
    """
    try:
        response = ebs_client.get_snapshot_block(
            SnapshotId=snapshot_id, BlockIndex=block_index, BlockToken=block_token
        )

        # Get the block data from the response
        block_data = response["BlockData"].read()

        # Write the block data to the output file at the correct offset
        with open(output_file, "r+b") as f:
            f.seek(start_offset)
            f.write(block_data)

        # Return the block index for progress tracking
        return block_index
    except Exception as e:
        logger.debug(f"Error downloading block {block_index}: {e}")
        return None


def download_ebs_volume(
    volume_id: str, output_file: str, region: Optional[str] = None, force: bool = False
) -> bool:
    """Download an EBS volume to a local file.

    Args:
        volume_id: ID of the EBS volume to download
        output_file: Path to save the downloaded volume
        region: AWS region to use. If None, uses the default region.
        force: If True, bypass warning for in-use volumes

    Returns:
        True if download was successful, False otherwise
    """
    ec2 = boto3.client("ec2", region_name=region)

    try:
        # Check if the volume exists
        try:
            logger.info(f"Checking volume {volume_id}...")
            response = ec2.describe_volumes(VolumeIds=[volume_id])
            volumes = response.get("Volumes", [])
            if not volumes:
                logger.error(
                    f"Volume {volume_id} not found{' in region ' + region if region else ''}."
                )
                return False

            volume = volumes[0]
            volume_size_gb = volume.get("Size", 0)
            volume_size_bytes = volume_size_gb * 1024 * 1024 * 1024  # Convert GB to bytes

            # Get volume name from tags
            volume_name = None
            for tag in volume.get("Tags", []):
                if tag.get("Key") == "Name":
                    volume_name = tag.get("Value")
                    break

            volume_info = f"{volume_id}"
            if volume_name:
                volume_info += f" ({volume_name})"

            volume_state = volume.get("State")
            logger.info(f"Found volume {volume_info} ({volume_size_gb} GB, {volume_state}).")

            # Check if volume is in 'in-use' state and warn the user
            if volume_state == "in-use":
                if not force:
                    logger.warning(
                        f"Volume {volume_id} is currently in use. Creating a snapshot of an in-use volume"
                    )
                    logger.warning(
                        "may result in an inconsistent state if there are active writes to the volume."
                    )
                    logger.warning("Use --force to bypass this warning.")

                    confirm = input("Do you want to continue anyway? (y/n): ")
                    if confirm.lower() != "y":
                        logger.info("Download cancelled.")
                        return False
                else:
                    logger.info(
                        f"Volume {volume_id} is in 'in-use' state. Proceeding with snapshot creation as --force was specified."
                    )

        except ClientError as e:
            if "InvalidVolume.NotFound" in str(e):
                logger.error(
                    f"Volume {volume_id} not found{' in region ' + region if region else ''}."
                )
                return False
            raise

        # Create a snapshot of the volume
        logger.info(f"Creating snapshot of volume {volume_id}...")
        snapshot_response = ec2.create_snapshot(
            VolumeId=volume_id, Description=f"Snapshot for download of {volume_id}"
        )

        snapshot_id = snapshot_response["SnapshotId"]
        logger.info(f"Snapshot {snapshot_id} created. Waiting for completion...")

        # Wait for the snapshot to complete
        waiter = ec2.get_waiter("snapshot_completed")
        waiter.wait(SnapshotIds=[snapshot_id])

        logger.info(f"Snapshot {snapshot_id} completed.")

        # Create an EBS client for direct APIs
        ebs_client = boto3.client("ebs", region_name=region)

        # Default block size is 512 KiB (512 * 1024 bytes)
        block_size = 512 * 1024

        # Create an empty file of the required size
        logger.info(f"Creating output file of size {volume_size_gb} GB...")
        with open(output_file, "wb") as f:
            # Allocate the file to the full size
            f.seek(volume_size_bytes - 1)
            f.write(b"\0")

        # List all blocks in the snapshot
        logger.info("Listing all blocks in the snapshot...")
        blocks = []
        next_token = None

        # Use tqdm for progress bar during block listing
        with tqdm.tqdm(desc="Listing blocks", unit="blocks", dynamic_ncols=True) as pbar:
            while True:
                if next_token:
                    response = ebs_client.list_snapshot_blocks(
                        SnapshotId=snapshot_id, MaxResults=1000, NextToken=next_token
                    )
                else:
                    response = ebs_client.list_snapshot_blocks(
                        SnapshotId=snapshot_id, MaxResults=1000
                    )

                new_blocks = response.get("Blocks", [])
                blocks.extend(new_blocks)
                pbar.update(len(new_blocks))

                next_token = response.get("NextToken")
                if not next_token:
                    break

        total_blocks = len(blocks)
        logger.info(f"Found {total_blocks} blocks to download.")

        # Download blocks in parallel
        logger.info("Downloading blocks...")
        downloaded_blocks = 0

        # Use ThreadPoolExecutor for parallel downloads with tqdm for progress tracking
        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
            futures = []

            # Submit download tasks for each block
            for block in blocks:
                block_index = block["BlockIndex"]
                block_token = block["BlockToken"]
                start_offset = block_index * block_size

                future = executor.submit(
                    download_snapshot_block,
                    ebs_client,
                    snapshot_id,
                    block_index,
                    block_token,
                    output_file,
                    start_offset,
                )
                futures.append(future)

            # Process the results as they complete with a progress bar
            with tqdm.tqdm(
                total=total_blocks, desc="Downloading", unit="blocks", dynamic_ncols=True
            ) as pbar:
                for future in concurrent.futures.as_completed(futures):
                    result = future.result()
                    if result is not None:
                        downloaded_blocks += 1
                        pbar.update(1)

        logger.info(f"Downloaded {downloaded_blocks}/{total_blocks} blocks successfully.")

        # Clean up the snapshot
        logger.info(f"Cleaning up snapshot {snapshot_id}...")
        ec2.delete_snapshot(SnapshotId=snapshot_id)
        logger.info(f"Snapshot {snapshot_id} deleted.")

        # Add metadata to a separate file
        metadata = {
            "volume_id": volume_id,
            "volume_name": volume_name,
            "volume_size_gb": volume_size_gb,
            "region": region,
            "download_date": str(boto3.utils.datetime.datetime.now()),
            "block_count": total_blocks,
            "block_size": block_size,
        }

        # Create a metadata file alongside the volume file
        metadata_file = f"{output_file}.metadata.json"
        with open(metadata_file, "w") as f:
            json.dump(metadata, f, indent=2)

        logger.info(f"Volume data downloaded successfully to {output_file}")
        logger.info(f"Metadata saved to {metadata_file}")

        return True

    except ClientError as e:
        logger.error(f"Error downloading EBS volume: {e}")
        return False
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        logger.debug("Exception details:", exc_info=True)
        return False


def main() -> None:
    """Main entry point for the EBS Volume Manager."""
    parser = argparse.ArgumentParser(description="AWS EBS Volume Manager")

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true", help="List all EBS volumes")
    group.add_argument("--download", metavar="VOLUME_ID", help="Download an EBS volume")

    parser.add_argument("-o", "--output", metavar="FILE", help="Output file for downloaded volume")
    parser.add_argument("-r", "--region", help="AWS region (e.g., us-east-1, eu-west-1)")
    parser.add_argument("--force", action="store_true", help="Bypass warning for in-use volumes")
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable verbose logging")

    args = parser.parse_args()

    # Configure logging based on verbosity
    setup_logger(args.verbose)

    if args.list:
        list_ebs_volumes(args.region)
    elif args.download:
        if not args.output:
            parser.error("--download requires -o/--output argument")

        # Check if output file already exists
        if os.path.exists(args.output):
            overwrite = input(f"File {args.output} already exists. Overwrite? (y/n): ")
            if overwrite.lower() != "y":
                logger.info("Download cancelled.")
                return

        logger.info(f"Downloading volume {args.download} to {args.output}...")
        success = download_ebs_volume(args.download, args.output, args.region, args.force)

        if success:
            logger.info(f"Volume {args.download} downloaded successfully to {args.output}")
        else:
            logger.error(f"Failed to download volume {args.download}")


if __name__ == "__main__":
    main()
