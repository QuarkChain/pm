# AI Sandbox with Docker + VS Code Dev Containers

Goal: AI reads and runs code inside an isolated Linux container. No host folders, SSH keys, or credentials are exposed to it.

---

## 1. Install prerequisites (host)

1. Install **Docker Desktop**.
2. Verify:
   ```bash
   docker run --rm hello-world
   ```
3. Install **VS Code** and the **Dev Containers** extension (publisher: Microsoft).
4. Do **not** install the AI extension on the host. If already installed, disable or uninstall it.
5. Optional: in **Docker Desktop → Settings → Resources → File sharing**, remove `/Users` to block any accidental host mounts.

---

## 2. Harden host VS Code settings

`Cmd/Ctrl + Shift + P` → **Preferences: Open User Settings (JSON)**, add:

```jsonc
{
  "dev.containers.copyGitConfig": false,
  "dev.containers.gitCredentialHelperConfigLocation": "none",
  "dev.containers.dockerCredentialHelper": false,
  "dev.containers.mountWaylandSocket": false,
  "security.workspace.trust.enabled": true,
  "remote.autoForwardPorts": false
}
```

---

## 3. Create the sandbox config

```bash
mkdir -p ~/sandbox/.devcontainer
cd ~/sandbox/.devcontainer
```

### 3.1 `Dockerfile`

```dockerfile
FROM ubuntu:24.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive

# Minimal tools; install anything else later with sudo apt install
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git sudo less vim procps \
    && rm -rf /var/lib/apt/lists/*

# Non-root user "dev" with password-protected sudo (password set in step 5)
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash -G sudo ${USERNAME} \
    && passwd -l ${USERNAME} \
    && echo 'Defaults timestamp_timeout=0' > /etc/sudoers.d/90-sandbox \
    && chmod 0440 /etc/sudoers.d/90-sandbox \
    && mkdir -p /workspaces && chown ${USERNAME}:${USERNAME} /workspaces

USER ${USERNAME}
WORKDIR /home/${USERNAME}

```

### 3.2 `devcontainer.json`

```jsonc
{
  "name": "claude-sandbox",
  "build": { "dockerfile": "Dockerfile" },

  "containerUser": "dev",
  "remoteUser": "dev",

  // Code lives in a Docker volume, not a host folder
  "workspaceMount": "source=claude-sandbox-ws,target=/workspaces,type=volume",
  "workspaceFolder": "/workspaces",

  // Home dir (Claude login, git config) persists across rebuilds
  "mounts": [
    "source=claude-sandbox-home,target=/home/dev,type=volume"
  ],

  "runArgs": [
    "--name=claude-sandbox",
    "--hostname=sandbox",
    "--cap-drop=ALL",
    "--cap-add=CHOWN",
    "--cap-add=DAC_OVERRIDE",
    "--cap-add=FOWNER",
    "--cap-add=FSETID",
    "--cap-add=SETUID",
    "--cap-add=SETGID",
    "--cap-add=KILL",
    "--cap-add=AUDIT_WRITE",
    "--memory=8g",
    "--cpus=4",
    "--pids-limit=2048"
  ],

  // Block host SSH agent forwarding
  "remoteEnv": {
    "SSH_AUTH_SOCK": ""
  },

  "customizations": {
    "vscode": {
      "extensions": ["anthropic.claude-code"],
      "settings": {
        "github.gitAuthentication": false,
        "git.terminalAuthentication": false,
        "terminal.integrated.defaultProfile.linux": "bash"
      }
    }
  }
}
```

Never add: host path mounts, `/var/run/docker.sock`, `"privileged": true`, `--network=host`.

---

## 4. Start the sandbox

1. In VS Code: **File → Open Folder** → `~/sandbox`.
2. `Cmd/Ctrl + Shift + P` → **Dev Containers: Reopen in Container**.
3. Wait for the first build. The bottom-left corner shows `Dev Container: claude-sandbox`.
4. Open a terminal. The prompt should be `dev@sandbox`.

---

## 5. Set the sudo password

On the **host** terminal (container must be running):

```bash
docker exec -it -u root claude-sandbox passwd dev
```

Use a unique password. Repeat this after every **Rebuild Container**.

Check inside the container:

```bash
sudo -n true          # expect: "sudo: a password is required"
sudo apt-get update   # enter password; should work
```

---

## 6. Sign in to AI

1. Open the AI panel in VS Code (inside the container).
2. Click sign in and finish authorization in your browser.
---

## 7. Configure Git (sandbox-only credentials)

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

For private repos, use **one** of these. Never copy host SSH keys into the container.

- **Fine-grained GitHub PAT** (selected repos only, short expiry):
  ```bash
  git config --global credential.helper store
  ```
  Use the PAT as the password on first clone/push.
- **Deploy key** for a single repo:
  ```bash
  ssh-keygen -t ed25519
  ```
  Add `~/.ssh/id_ed25519.pub` as a Deploy Key on that repo. (Requires `sudo apt install openssh-client`.)

Clone and open a project:

```bash
cd /workspaces
git clone <repo-url>
```

Then **File → Open Folder** → `/workspaces/<repo>`.

---

## 8. Verify isolation

Run inside the container:

| Command | Expected |
|---|---|
| `whoami` | `dev` |
| `sudo -n true 2>&1` | `sudo: a password is required` |
| `grep CapBnd /proc/self/status` | `00000000200000fb` |
| `ls ~/.ssh 2>&1` | No such file (unless you created a deploy key) |
| `mount \| grep -Ei 'users\|c:'` | No output |
| `ls /var/run/docker.sock 2>&1` | No such file |
| `echo "[$SSH_AUTH_SOCK]"` | `[]` |
| `ssh-add -l 2>&1` | Cannot connect to agent (if openssh-client installed) |
| `git config --global --list` | Only what you set in step 7 |
| `env \| grep -Ei 'token\|secret\|key\|password'` | No host secrets |

If `ssh-add -l` lists your keys, run `ssh-add -D` on the host while using the sandbox.

---

## 9. Daily use

| Task | How |
|---|---|
| Enter sandbox | Open `~/sandbox` → **Reopen in Container** |
| Install software | `sudo apt install <pkg>` (lost on rebuild; add frequent ones to the Dockerfile) |
| npm global packages | `npm config set prefix ~/.npm-global` and add `~/.npm-global/bin` to `PATH` in `~/.bashrc`. Never `sudo npm install -g`. |
| Apply config changes | **Dev Containers: Rebuild Container**, then redo step 5 |
| Check volumes | `docker volume ls` |

---

## 10. Full reset

Push your code first. Then on the host:

```bash
docker rm -f claude-sandbox
docker volume rm claude-sandbox-ws claude-sandbox-home
```

Reopen in Container to get a fresh environment, then redo steps 5–7.