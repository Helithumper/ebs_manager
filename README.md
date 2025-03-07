# EBS Volume Manager

A Python utility for managing AWS EBS volumes. This tool allows you to list all EBS volumes in your AWS account and download them to your local machine.

## Prerequisites

- Python 3.7+
- AWS credentials configured (via AWS CLI, environment variables, or IAM role)
- UV package manager
- Appropriate IAM permissions for EBS direct APIs

## Installation

1. Clone this repository or download the script files
2. Install dependencies using UV:
   ```
   uv pip install -e .
   ```
   
   For development dependencies:
   ```
   uv pip install -e ".[dev]"
   ```
3. Make the script executable (Unix/Linux/macOS):
   ```
   chmod +x ebs_manager.py
   ```

## Usage

### Listing EBS Volumes

To list all EBS volumes in your AWS account:

```
python ebs_manager.py --list
```

To list volumes in a specific AWS region:

```
python ebs_manager.py --list --region us-east-1
```

This will display a table with the following information:
- Volume ID
- Volume Name (from tags)
- Size (GB)
- State
- Type
- Instance ID (if attached)
- Instance Name (from tags, if attached)

### Downloading an EBS Volume

To download an EBS volume to a local file:

```
python ebs_manager.py --download vol-1234567890abcdef0 -o /path/to/output/file
```

To download from a specific AWS region:

```
python ebs_manager.py --download vol-1234567890abcdef0 -o /path/to/output/file --region us-west-2
```

To download an in-use volume without confirmation prompt:

```
python ebs_manager.py --download vol-1234567890abcdef0 -o /path/to/output/file --force
```

For verbose logging:

```
python ebs_manager.py --download vol-1234567890abcdef0 -o /path/to/output/file -v
```

Replace `vol-1234567890abcdef0` with your actual volume ID and `/path/to/output/file` with your desired output location.

The download process:
1. Creates a snapshot of the specified volume
2. Uses EBS direct APIs to download all blocks from the snapshot
3. Writes the data to the specified output file
4. Creates a metadata JSON file with volume information
5. Cleans up the snapshot after download

The download process shows progress information with progress bars and uses parallel downloading for better performance.

#### Note on In-Use Volumes

When downloading volumes that are in the "in-use" state (attached to an EC2 instance):
- By default, you'll receive a warning and a confirmation prompt
- The snapshot may be inconsistent if there are active writes to the volume
- Use the `--force` flag to bypass the confirmation prompt

## Command Line Arguments

- `--list`: List all EBS volumes
- `--download VOLUME_ID`: Download the specified EBS volume
- `-o, --output FILE`: Output file path for downloaded volume (required with --download)
- `-r, --region`: AWS region to use (e.g., us-east-1, eu-west-1)
- `--force`: Bypass warning and confirmation prompt for in-use volumes
- `-v, --verbose`: Enable verbose logging for debugging

## Required IAM Permissions

To use this tool, your AWS credentials must have the following permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVolumes",
                "ec2:DescribeInstances",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot",
                "ec2:DescribeSnapshots",
                "ebs:ListSnapshotBlocks",
                "ebs:GetSnapshotBlock"
            ],
            "Resource": "*"
        }
    ]
}
```

## Development

This project uses:
- UV for dependency management
- Ruff for code formatting and linting
- pytest for testing
- tqdm for progress bars

To format code:
```
ruff format .
```

To lint code:
```
ruff check .
```

## AWS Credentials

This script uses boto3, which looks for AWS credentials in the following order:

1. Environment variables (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`)
2. Shared credential file (`~/.aws/credentials`)
3. IAM role for Amazon EC2 (if running on EC2)

Make sure you have the necessary permissions to describe, create, and delete EBS volumes and snapshots.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
