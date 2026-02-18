# setup-VM

Automated setup script for Azure VMs. Installs Docker, runs nginx in a container, installs neofetch, and configures the login shell to display system info and public IP.

## Quick Start

**With network name argument:**
```bash
curl -fsSL https://raw.githubusercontent.com/AhmedAredah/setup-VM/main/setup-vm.sh | sudo bash -s tpet-dev
```

**Interactive mode** (prompts for network name):
```bash
curl -fsSL https://raw.githubusercontent.com/AhmedAredah/setup-VM/main/setup-vm.sh | sudo bash
```

## What It Does

1. **Detects your Linux distribution** and installs Docker CE with the official Docker repo
2. **Creates a Docker network** (you choose the name)
3. **Sets up nginx** in a container:
   - Minimal default config serving on port 80
   - Logs and config stored in `~/nginx/` on the host
   - Restarts automatically on reboot
4. **Installs neofetch** to display system info on login
5. **Configures your shell** to show the machine's public IP on every login

## Supported Distributions

- **Debian/Ubuntu** (including derivatives like Linux Mint, Pop!_OS)
- **RHEL / CentOS / AlmaLinux / Rocky Linux**
- **Fedora**
- **Alpine Linux**

## Usage Examples

### With a specific network name
```bash
curl -fsSL https://raw.githubusercontent.com/AhmedAredah/setup-VM/main/setup-vm.sh | sudo bash -s prod-network
```

### Interactive mode (will prompt for network name)
```bash
curl -fsSL https://raw.githubusercontent.com/AhmedAredah/setup-VM/main/setup-vm.sh | sudo bash
```

## Post-Setup

After the script completes, you must activate your docker group membership:

```bash
newgrp docker
```

Or log out and log back in. Then start nginx:

```bash
cd ~/nginx
docker compose up -d
```

Verify it's running:

```bash
curl http://localhost
```

You should see the default nginx welcome page. Access and error logs are available in `~/nginx/logs/`.

## Directory Structure

After setup, your home directory will contain:

```
~/nginx/
├── config/
│   └── nginx.conf              # Minimal nginx configuration
├── logs/                       # nginx access and error logs
└── docker-compose.yml          # Docker Compose configuration
```

## Features

- **Distribution detection**: Automatically detects your Linux distro and uses the correct package manager
- **Idempotent**: Can be run multiple times safely; won't duplicate entries in `.bashrc` or recreate existing Docker networks
- **User-friendly**: Colored output, clear error messages, skip non-root privilege escalation when possible
- **Non-interactive option**: Pass the network name as an argument for CI/CD or automated deployments
- **Alpine support**: Works on lightweight Alpine Linux distributions

## Script Behavior

### Docker Group Membership
The script adds your user to the `docker` group. You need to run `newgrp docker` or log out/in before you can use `docker` commands without `sudo`.

### .bashrc Modifications
The script appends two commands to your `~/.bashrc`:
1. `neofetch` — displays system information
2. `curl -s ifconfig.me` — fetches and displays your public IP address

These run automatically whenever you open a new bash shell.

### Logs and Configuration
All nginx state (logs, config) is stored in `~/nginx/` on the host machine. This makes it easy to:
- Edit the config: `~/nginx/config/nginx.conf`
- View logs: `~/nginx/logs/access.log` and `error.log`
- Backup everything: `tar czf nginx-backup.tar.gz ~/nginx`

## Troubleshooting

### "Permission denied" when running docker
```bash
newgrp docker
```

### "Docker network already exists"
This is not an error. The script safely skips network creation if it already exists.

### neofetch not found after login
On RHEL-based systems, `neofetch` requires the EPEL repository. If the install failed silently, enable EPEL and install manually:
```bash
sudo dnf install -y epel-release
sudo dnf install -y neofetch
```

### Public IP not showing on login
Ensure `curl` is installed. It should be installed as a Docker dependency, but if missing:
```bash
sudo apt-get install -y curl    # Debian/Ubuntu
sudo dnf install -y curl        # RHEL/Fedora
sudo apk add curl               # Alpine
```

## License

MIT