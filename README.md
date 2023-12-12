# GitLab Runner Management Script

This Bash script is designed to manage GitLab runners efficiently. 
It provides various functionalities to list runners, jobs, remove stale runners, and more.

## Prerequisites

Ensure the following dependencies are met before using this script:

- Bash environment
- `jq`: A lightweight and flexible command-line JSON processor
- `column`: A utility to format the output into columns

## Configuration

### Environment Variables

Make sure the following environment variables are set:
- `GITLAB_TOKEN`: Your personal GitLab token.

### Configuration File

Ensure that a `config.json` file is available. It should contain the necessary configuration details for the script to function correctly. 
Check the `config.json.example` file for an example.

## Usage

### Running the Script

```bash
./script.sh [OPTIONS]
```

### Options

- `--runners-by-group <group_slug|group_id>`: List runners grouped by `group_id`. Filter by `group_slug` or `group_id` if provided.
- `--runners-by-instance <ec2_instance|ip_address>`: List runners grouped by `ec2_instance`. Filter by `ec2_instance` or `ip_address` if provided.
- `--remove-stale-runners`: Search for and remove all stale/offline runners from the provided groups.
- `--jobs`: List jobs grouped by `runner_id`.
- `--running-jobs`: List running jobs grouped by `runner_id`.
- `--jobs-by-runner-id <runner_id>`: List jobs filtered by `runner_id`.
- `--help`: Show script usage instructions.

## Example

### List all runners grouped by group_id

```bash
./script.sh --runners-by-group
```

### Remove stale/offline runners

```bash
./script.sh --remove-stale-runners
```

For more information and usage instructions, run:

```bash
./script.sh --help
```
