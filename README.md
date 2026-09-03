# Ubuntu Server Hardening + Outline VPN

Harden a fresh **Ubuntu 26.04 LTS** server and deploy an **[Outline](https://getoutline.org/)** VPN (Shadowsocks) with sensible defaults: SSH key-only auth, UFW, fail2ban, automatic security updates, and kernel network tuning.

## What you get

| Component | Purpose |
|-----------|---------|
| `scripts/harden-server.sh` | Baseline security hardening |
| `scripts/lock-root.sh` | Lock root account only (standalone) |
| `scripts/install-outline.sh` | Docker + official Outline Server installer |
| `scripts/outline-ufw-allow.sh` | Open a single Outline access-key port in UFW |
| `config/` | SSH, sysctl, fail2ban, and unattended-upgrade snippets |

## Prerequisites

- A VPS or dedicated server running **Ubuntu 26.04 LTS** (24.04+ also works)
- Root or sudo access
- A static public IP (or stable DNS name)
- **SSH public key** already added to the server (`~/.ssh/authorized_keys`)
- Outline Manager desktop app ([download](https://getoutline.org/get-started/))

> **Warning:** The hardening script disables SSH password login. Confirm key-based SSH works before running it.

## Quick start

### 1. Initial server access

From your local machine, connect as the default user (often `ubuntu`):

```bash
ssh ubuntu@YOUR_SERVER_IP
```

If you have not added your SSH key yet:

```bash
ssh-copy-id ubuntu@YOUR_SERVER_IP
```

### 2. Clone this repository on the server

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/YOUR_USER/ubuntu-server-hardening.git
cd ubuntu-server-hardening
```

Or copy the project files with `scp -r`:

```bash
scp -r ./ubuntu-server-hardening ubuntu@YOUR_SERVER_IP:~/
```

### 3. Configure

```bash
cp .env.example .env
nano .env
```

Common settings:

```bash
SSH_PORT=22
ADMIN_USER="ubuntu"                  # admin user with sudo (must exist)
LOCK_ROOT=1                          # lock root password and shell
SSH_ALLOWED_USERS="ubuntu"           # restrict SSH to admin user only
OUTLINE_API_PORT=""
EXTRA_TCP_PORTS=""
NONINTERACTIVE=0
```

### Lock root only (without full hardening)

If you only want to disable root and keep using the `ubuntu` user:

```bash
sudo ./scripts/lock-root.sh
```

This checks that `ubuntu` has sudo + SSH keys, then:
- Locks the root password (`passwd -l root`)
- Sets root shell to `/usr/sbin/nologin`

Verify:

```bash
passwd -S root    # should show "L" (locked)
```

### 4. Harden the server

```bash
chmod +x scripts/*.sh
sudo ./scripts/harden-server.sh
```

**Before closing your current SSH session**, open a **new** terminal and verify access:

```bash
ssh -p 22 ubuntu@YOUR_SERVER_IP
```

### 5. Install Outline VPN

```bash
sudo ./scripts/install-outline.sh
```

The installer prints JSON with `apiUrl` and `certSha256`. Credentials are also saved to:

```
/root/outline-api-credentials.json
```

Copy these values into **Outline Manager** → **Add server** → paste the installation output.

### 6. Open firewall ports for access keys

Outline assigns a **unique TCP port per access key**. After creating a key in Outline Manager:

```bash
sudo ./scripts/outline-ufw-allow.sh 41234   # replace with your key's port
```

Or manually:

```bash
sudo ufw allow 41234/tcp comment 'Outline access key'
sudo ufw status
```

The Outline **management API port** is opened automatically during install when credentials are parsed successfully.

## Hardening details

The hardening script applies:

### SSH
- Disables root login and password authentication
- Locks the root account (password + login shell)
- Restricts SSH to `ubuntu` by default (`AllowUsers`)
- Limits auth attempts and idle sessions
- Uses modern ciphers and key exchange algorithms
- Optional `AllowUsers` restriction via `.env`

### Firewall (UFW)
- Default deny incoming, allow outgoing
- Allows configured SSH port
- Optional Outline API and extra ports from `.env`

### Intrusion prevention
- **fail2ban** for SSH (3 failures → 24h ban)

### Updates
- **unattended-upgrades** for automatic security patches

### Kernel
- Reverse-path filtering, SYN cookies, ICMP redirect blocking
- Source routing disabled

### Other
- **auditd** enabled
- Password quality rules for local accounts
- Unused services disabled (avahi, cups, etc.)
- `/run/shm` mounted with `noexec,nosuid,nodev`

## Project layout

```
ubuntu-server-hardening/
├── README.md
├── .env.example
├── config/
│   ├── sysctl/99-hardening.conf
│   ├── ssh/sshd_config.d/99-hardening.conf
│   ├── fail2ban/jail.local
│   └── unattended-upgrades/20auto-upgrades
└── scripts/
    ├── harden-server.sh
    ├── lock-root.sh
    ├── install-outline.sh
    ├── outline-ufw-allow.sh
    └── lib/common.sh
```

## Outline Manager setup

1. Install [Outline Manager](https://getoutline.org/get-started/) on your computer
2. Click **Add server** → **Set up Outline anywhere**
3. Paste the `apiUrl` and `certSha256` from the install output
4. Create access keys and share them with clients ([Outline Client](https://getoutline.org/get-started/))
5. Open each access-key port in UFW (see step 6 above)

## Maintenance

### Check services

```bash
sudo systemctl status ssh fail2ban ufw docker
sudo docker ps
```

### View logs

```bash
sudo tail -f /var/log/ubuntu-server-hardening/hardening.log
sudo fail2ban-client status sshd
```

### Update Outline

Outline runs in Docker. To update, re-run the official installer or follow [Outline server docs](https://github.com/Jigsaw-Code/outline-server):

```bash
sudo ./scripts/install-outline.sh
```

### Rotate SSH keys

Add the new key to `~/.ssh/authorized_keys`, verify login, then remove the old key.

## Troubleshooting

### Locked out of SSH

Use your cloud provider's **web console / serial console** to:
1. Restore `/etc/ssh/sshd_config` from a `.bak.*` backup
2. Or temporarily set `PasswordAuthentication yes` in `/etc/ssh/sshd_config.d/99-hardening.conf`
3. Run `sudo systemctl reload ssh`

### Outline Manager cannot connect

- Confirm the management API port is allowed: `sudo ufw status`
- Check Docker: `sudo docker ps`
- Verify credentials in `/root/outline-api-credentials.json`

### Client cannot connect through VPN

- Confirm the **access-key port** is open in UFW
- Test from outside: `nc -zv YOUR_SERVER_IP ACCESS_KEY_PORT`
- Ensure your VPS provider's **cloud firewall** also allows the port (AWS Security Groups, DigitalOcean Firewalls, etc.)

### fail2ban banned your IP

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip YOUR_IP
```

## Security notes

- Outline is a **proxy VPN** (Shadowsocks), not a full tunnel — traffic is encrypted to the server but DNS/app behavior depends on client settings
- Keep `apiUrl` and `certSha256` secret; they grant full server management
- Prefer unique access keys per user/device and revoke unused keys in Outline Manager
- Review UFW rules regularly: `sudo ufw status numbered`
- For high-risk deployments, consider moving SSH to a non-default port and restricting source IPs at the cloud firewall

## License

MIT — use and modify freely. No warranty; test on a staging server before production.
