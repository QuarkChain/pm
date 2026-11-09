# AI Sandbox with Docker + VS Code Remote-SSH

Goal: the AI reads and runs code inside an isolated Linux container. It cannot reach host folders, SSH keys, or credentials.

Treat everything inside the container as hostile: the AI, the code it writes, and the packages it installs. Only **host-side** settings count as protection. The AI can change anything inside the container, including VS Code's remote settings.

> **Why not Dev Containers?** The Dev Containers extension opens two channels to the host. Settings do not close them (verified 2026-11):
> - `/tmp/vscode-ssh-auth-*.sock` relays to the host SSH agent, even when `SSH_AUTH_SOCK` is cleared.
> - `$REMOTE_CONTAINERS_IPC` runs `git credential fill` on the host and returns the host's GitHub token (e.g. the GitHub CLI's `gho_…` token), even with `dev.containers.gitCredentialHelperConfigLocation: "none"`.
>
> Remote-SSH has neither channel. **Never** use *Dev Containers: Attach to Running Container* on this sandbox, because it brings both channels back.

---

## 1. Install prerequisites (host)

1. Install **Docker Desktop**, then verify:
   ```bash
   docker run --rm hello-world
   ```
2. Install **VS Code** and the **Remote - SSH** extension (`ms-vscode-remote.remote-ssh`, publisher: Microsoft).
3. Do **not** install the AI extension on the host. If it is already installed, disable or uninstall it. Step 6 installs it inside the container.
4. Optional: in **Docker Desktop → Settings → Resources → File sharing**, remove `/Users` to block accidental host mounts.

---

## 2. Harden host VS Code settings

`Cmd/Ctrl + Shift + P` → **Preferences: Open User Settings (JSON)**, add:

```jsonc
{
  "remote.SSH.enableAgentForwarding": false,
  "remote.SSH.enableX11Forwarding": false,
  "remote.SSH.remotePlatform": { "ai-sandbox": "linux" },
  "remote.autoForwardPorts": false,
  "github.gitAuthentication": false,
  "git.terminalAuthentication": false,
  "security.workspace.trust.enabled": true
}
```

These must be **User** settings on the host. Copies inside the container do not protect anything.

Recommended: do not sign in to GitHub in VS Code's **Accounts** menu on this machine (see [Known limitations](#11-known-limitations)).

---

## 3. Create a dedicated SSH key and host entry (host)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ai_sandbox_ed25519 -N '' -C ai-sandbox
```

This key only opens the sandbox on `127.0.0.1`, so it has no passphrase. Never reuse your personal key, and never copy any private key into the container.

Add this block to the **top** of `~/.ssh/config`. ssh uses the first value it finds, so a `Host *` block above it with `ForwardAgent yes` would win.

```
Host ai-sandbox
  HostName 127.0.0.1
  Port 2222
  User dev
  IdentityFile ~/.ssh/ai_sandbox_ed25519
  IdentitiesOnly yes
  IdentityAgent none
  ForwardAgent no
  ForwardX11 no
  UserKnownHostsFile ~/.ssh/known_hosts_ai_sandbox
```

---

## 4. Create the sandbox config

```bash
mkdir -p ~/ai-sandbox && cd ~/ai-sandbox
cp ~/.ssh/ai_sandbox_ed25519.pub authorized_keys
```

Create the three files below in `~/ai-sandbox`.

### 4.1 `sshd_config`

```
# Installed as /etc/ssh/sshd_config.d/10-sandbox.conf. The first value wins, so these override the defaults.
Port 2222
PermitRootLogin no
AllowUsers dev
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no

# Root-owned key file: the AI cannot add its own keys
AuthorizedKeysFile /etc/ssh/authorized_keys/%u

# Nothing flows from the container back to the host.
# Remote-SSH needs local forwarding (host -> container) to reach the VS Code server;
# remote forwarding (container -> host) stays off.
AllowAgentForwarding no
AllowStreamLocalForwarding no
AllowTcpForwarding local
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
```

### 4.2 `Dockerfile`

```dockerfile
FROM ubuntu:24.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive

# Minimal tools. Add more later from the host (see step 9).
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server ca-certificates curl git less vim procps \
    && rm -rf /var/lib/apt/lists/*

# Non-root user "dev": no sudo, no password (SSH key login only)
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && usermod -p '*' ${USERNAME} \
    && mkdir -p /workspaces && chown ${USERNAME}:${USERNAME} /workspaces

# sshd: key-only login for dev, nothing forwarded back to the host
COPY sshd_config /etc/ssh/sshd_config.d/10-sandbox.conf
COPY authorized_keys /etc/ssh/authorized_keys/${USERNAME}
RUN chmod 755 /etc/ssh/authorized_keys \
    && chmod 644 /etc/ssh/sshd_config.d/10-sandbox.conf /etc/ssh/authorized_keys/${USERNAME} \
    && sed -i 's/^session\s\+required\s\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd \
    && ssh-keygen -A \
    && mkdir -p /run/sshd

EXPOSE 2222
CMD ["/usr/sbin/sshd", "-D", "-e"]
```

sshd runs as root inside the container because it has to switch to `dev`. The `dev` user has no capabilities and cannot become root: there is no sudo, and `no-new-privileges` blocks setuid binaries.

### 4.3 `compose.yaml`

```yaml
name: ai-sandbox

services:
  sandbox:
    build: .
    image: ai-sandbox
    container_name: ai-sandbox
    hostname: sandbox
    init: true
    # Reachable only from this machine, never from the LAN
    ports:
      - "127.0.0.1:2222:2222"
    cap_drop: [ALL]
    # Capabilities sshd (running as root) needs to log in "dev"
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, SETUID, SETGID, SYS_CHROOT, AUDIT_WRITE]
    security_opt:
      - no-new-privileges:true
    mem_limit: 8g
    cpus: 4
    pids_limit: 2048
    volumes:
      - home:/home/dev        # login, git config, VS Code server
      - workspaces:/workspaces # code lives in a Docker volume, not a host folder

volumes:
  home:
  workspaces:
```

Never add: host path mounts, `/var/run/docker.sock`, `privileged: true`, `network_mode: host`, or a port mapping without `127.0.0.1:`.

---

## 5. Start and connect

```bash
cd ~/ai-sandbox
docker compose up -d --build
docker port ai-sandbox     # expect only: 2222/tcp -> 127.0.0.1:2222
ssh ai-sandbox whoami      # first time: answer "yes" to the host key; expect: dev
```

Then in VS Code:

1. `Cmd/Ctrl + Shift + P` → **Remote-SSH: Connect to Host…** → `ai-sandbox`.
2. Wait for the VS Code server to install. The bottom-left corner shows `SSH: ai-sandbox`.
3. **File → Open Folder** → `/workspaces`.
4. Open a terminal. The prompt should be `dev@sandbox`.

If the connection fails, check `docker logs ai-sandbox`.

---

## 6. Install the AI extension and sign in

1. In the Extensions view, find **Claude Code** (`anthropic.claude-code`) and click **Install in SSH: ai-sandbox**.
2. Open its panel, click sign in, and finish authorization in your browser.

---

## 7. Configure Git (sandbox-only credentials)

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

For private repos, use **one** of these. Never copy host SSH keys or tokens into the container. Anything stored here is readable by the AI, so keep the scope small and the expiry short.

- **Fine-grained GitHub PAT** (selected repos only, short expiry):
  ```bash
  git config --global credential.helper store
  ```
  Use the PAT as the password on the first clone or push. It is saved in plain text in `~/.git-credentials`.
- **Deploy key** for a single repo:
  ```bash
  ssh-keygen -t ed25519
  ```
  Add `~/.ssh/id_ed25519.pub` as a Deploy Key on that repo.

Clone a project:

```bash
cd /workspaces
git clone <repo-url>
```

Then **File → Open Folder** → `/workspaces/<repo>`.

---

## 8. Verify isolation

### 8.1 On the host

| Command | Expected |
|---|---|
| `docker port ai-sandbox` | Only `2222/tcp -> 127.0.0.1:2222` |
| `ssh -G ai-sandbox \| grep -E '^(forwardagent\|forwardx11\|identityagent) '` | `forwardagent no`, `forwardx11 no`, `identityagent none` |
| `docker inspect ai-sandbox --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{"\n"}}{{end}}'` | Only `volume /home/dev` and `volume /workspaces`. No `bind`. |

### 8.2 Inside the container

Run these in a VS Code terminal connected to `ai-sandbox`. Run the GitHub check **before** step 7, so that no sandbox PAT exists yet.

| Command | Expected |
|---|---|
| `id` | `uid=1000(dev) gid=1000(dev) groups=1000(dev)` |
| `command -v sudo` | No output |
| `grep -E '^(CapEff\|CapBnd\|NoNewPrivs)' /proc/self/status` | `CapEff: 0000000000000000`, `CapBnd: 00000000200400fb`, `NoNewPrivs: 1` |
| `echo "[$SSH_AUTH_SOCK]"; ls -d /tmp/ssh-* 2>&1` | `[]` and `No such file` |
| `ls /tmp \| grep -E 'vscode-(ssh-auth\|remote-containers)'` | No output. If you see output, you are connected through Dev Containers, not Remote-SSH. |
| `env \| grep -iE 'askpass\|token\|secret\|password'` | No output |
| `GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/<org>/<private-repo> 2>&1 \| tail -1` | Fails (`could not read Username`) |
| `mount \| grep -Ei 'host_mnt\|/Users\|/run/desktop\|virtiofs\|grpcfuse\|fakeowner\|9p'` | No output |
| `ls /var/run/docker.sock 2>&1` | `No such file` |
| `git config --global --list` | Only what you set in step 7 |

### 8.3 VS Code's Git sign-in channel

This check runs Git through VS Code's own askpass directly, the way a malicious process could:

```bash
b=$(ls -d ~/.vscode-server/bin/* | head -1)
VSCODE_GIT_IPC_HANDLE=$(ls /tmp/vscode-git-*.sock | head -1) \
VSCODE_GIT_ASKPASS_NODE=$b/node \
VSCODE_GIT_ASKPASS_MAIN=$b/extensions/git/dist/askpass-main.js \
GIT_ASKPASS=$b/extensions/git/dist/askpass.sh \
git ls-remote https://github.com/<org>/<private-repo> 2>&1 | tail -1
```

Expected: VS Code on the host shows a username prompt. Press **Esc**, and the command fails. If it succeeds **without any prompt**, the host is handing out a GitHub session. Recheck step 2 and the Accounts menu.

---

## 9. Daily use

| Task | How |
|---|---|
| Start | `cd ~/ai-sandbox && docker compose up -d` |
| Connect | VS Code → **Remote-SSH: Connect to Host…** → `ai-sandbox` (or **File → Open Recent**) |
| Stop (also stops everything the AI started) | `docker compose stop` |
| Install software (one-off, lost on rebuild) | On the host: `docker exec -u root ai-sandbox sh -c 'apt-get update && apt-get install -y <pkg>'` |
| Install software (permanent) | Add it to the `apt-get install` line in the `Dockerfile`, then rebuild |
| npm global packages (after installing Node) | `npm config set prefix ~/.npm-global` and add `~/.npm-global/bin` to `PATH` in `~/.bashrc` |
| Apply config changes | `docker compose up -d --build`. Volumes (home and code) are kept. If ssh warns that the host key changed: `rm ~/.ssh/known_hosts_ai_sandbox` |
| Terminal only, without VS Code | `docker exec -it -u dev ai-sandbox bash` |

---

## 10. Full reset

Push your code first. Then on the host:

```bash
cd ~/ai-sandbox
docker compose down -v          # removes the container AND both volumes
rm -f ~/.ssh/known_hosts_ai_sandbox
docker compose up -d --build
```

Then redo steps 5–7.

---

## 11. Known limitations

1. **VS Code's remote channel.** The AI and the VS Code server run as the same user in the container. Through VS Code's remote protocol, the container side can read and write the host clipboard, open URLs in the host browser, show input boxes, and run VS Code commands. While the sandbox is connected, distrust unexpected VS Code prompts, and never type a host password into one. For the strictest isolation, skip VS Code: use `docker exec -it -u dev ai-sandbox bash` and run the `claude` CLI there.
2. **Container-side settings are not a boundary.** The AI can edit `~/.vscode-server/data/Machine/settings.json`, which may override host settings for this window. For example, it could turn `github.gitAuthentication` back on. If host VS Code is signed in to GitHub, VS Code may then ask to allow GitHub access. Deny it. Not signing in to GitHub in host VS Code removes this path.
3. **Network is not restricted.** The container can reach the internet, your LAN, and host services through `host.docker.internal`, including services bound to localhost. While the sandbox runs, do not run unauthenticated services on the host (databases, dev servers, Docker's TCP API). Egress filtering is out of scope for this guide.
4. **Anything you put in the sandbox is visible to the AI**: PATs, deploy keys, the Claude login, `.env` files.
5. **Shared kernel.** A kernel or Docker Desktop bug could allow a container escape. Keep Docker Desktop updated.

