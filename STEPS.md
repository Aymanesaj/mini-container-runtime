# STEPS — Build Order for Mini Container Runtime

Assumes comfortable C, Make, debugging with `gdb`/`strace`, and prior work on fork/exec-heavy projects (minishell, webserv, etc.). Each phase ends with something **runnable and verifiable** before moving on.

Run most tests as root during early phases (`sudo`). User namespaces come later.

---

## Phase 0 — Project skeleton

**Goal:** Clean repo, builds, basic CLI stub.

- [ ] Create directory layout (`include/`, `src/`, `scripts/`)
- [ ] Write `Makefile` with `-Wall -Wextra -Werror`, debug (`-g`) and release targets
- [ ] Add `main.c` with argument parsing (manual or simple getopt — no need for libft here unless you want it)
- [ ] Stub subcommands: `run`, `ps`, `stop`, `rm`, `help`
- [ ] Define core structs in `container.h`:
  ```c
  typedef struct s_container {
      char    *id;
      char    *rootfs;
      char    **argv;
      pid_t   init_pid;      /* on host */
      int     status;        /* created / running / stopped */
  } t_container;
  ```
- [ ] **Verify:** `make && ./minictl help` prints usage.

---

## Phase 1 — Minimal rootfs (no namespaces yet)

**Goal:** Confirm your rootfs works and you can `chroot` + `execve` into it.

- [ ] Write `scripts/build_rootfs.sh` using one of:
  - `debootstrap --variant=minbase stable ./rootfs` (Debian/Ubuntu)
  - static BusyBox + minimal `/etc`, `/dev` nodes
- [ ] Add `rootfs/` to `.gitignore`
- [ ] Implement `run` as a **single process**: `chroot(rootfs) + execve("/bin/sh", ...)`
- [ ] Mount nothing yet — just prove `/bin/sh` runs inside the tree
- [ ] **Verify:**
  ```bash
  sudo ./minictl run ./rootfs /bin/sh -c 'id; ls /'
  ```
  You should see the rootfs contents at `/`.

**Debug tip:** If exec fails, check `strace -f ./minictl run ...` for ENOENT on dynamic linker (`/lib/ld-linux.so.*`) — rootfs must match your binary architecture.

---

## Phase 2 — Two-process model + `clone()` with namespaces

**Goal:** Parent on host, child in new PID/Mount/UTS namespaces running the command.

- [ ] Replace bare `fork()` with `clone()` (or `unshare()` after fork — pick one approach and stick to it; `clone()` with flags is the runc way)
- [ ] Initial namespace set:
  ```c
  CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUTS | SIGCHLD
  ```
- [ ] Parent writes child PID, waits on `waitpid` (later: track in container list)
- [ ] Child path (in order):
  1. `sethostname("minic", 5)`
  2. rootfs setup (Phase 3 — for now stub with `chroot`)
  3. `execve` target command
- [ ] **Verify:**
  ```bash
  # host
  hostname
  # container
  sudo ./minictl run ./rootfs /bin/sh -c 'hostname; echo $$'
  ```
  Hostname inside should be `minic`. PID of shell should be **1** (or low number in new PID ns).

- [ ] From another host terminal, confirm isolation:
  ```bash
  ps aux | grep <child-pid-on-host>   # visible on host by real PID
  # inside container: ps (once /proc mounted) shows only container processes
  ```

---

## Phase 3 — Proper rootfs with `pivot_root`

**Goal:** Replace `chroot` with correct mount namespace setup.

Implement in `mount.c`:

- [ ] `mount(rootfs, rootfs, NULL, MS_BIND | MS_REC, NULL)` — bind mount rootfs to itself
- [ ] Create `rootfs/.pivot` directory (put_old)
- [ ] `pivot_root(rootfs, rootfs/.pivot)`
- [ ] `chdir("/")`
- [ ] `umount2(".pivot", MNT_DETACH)` and remove `.pivot`
- [ ] Mount essential filesystems inside container:
  - [ ] `proc` → `/proc`
  - [ ] `sysfs` → `/sys` (optional early; needed for some tools)
  - [ ] `devtmpfs` or bind-mount `/dev` (needed for shell job control / PTY later)
- [ ] **Verify:**
  ```bash
  sudo ./minictl run ./rootfs /bin/sh -c 'mount | head; cat /proc/1/status | grep ^Name'
  ```
  `/proc` should show container processes only. Host paths must not appear in `mount` output.

**Common failures:** forgetting bind mount before pivot; pivot_old not under new root; missing `/proc` so `ps` falls back to unmountable behavior.

---

## Phase 4 — cgroups v2 resource limits

**Goal:** Per-container memory and CPU limits enforced by the kernel.

Implement in `cgroup.c`:

- [ ] Detect cgroup v2: stat `/sys/fs/cgroup/cgroup.controllers`
- [ ] Create group: `/sys/fs/cgroup/minic-<id>/`
  ```c
  mkdir("/sys/fs/cgroup/minic-abc123", 0755);
  ```
- [ ] Enable controllers (if using subtree):
  ```bash
  echo "+memory +cpu +pids" > /sys/fs/cgroup/cgroup.subtree_control
  ```
- [ ] Write limits before moving process:
  - `memory.max` — e.g. `67108864` (64 MiB)
  - `cpu.max` — e.g. `max 50000` (50% of one CPU)
  - `pids.max` — e.g. `64`
- [ ] Move container init: `echo <pid> > .../cgroup.procs`
- [ ] On stop/delete: kill process, `rmdir` cgroup (may need to drain procs first)
- [ ] Plumb limits through CLI:
  ```bash
  sudo ./minictl run --memory 64M --cpu 0.5 ./rootfs /bin/sh
  ```
- [ ] **Verify:**
  ```bash
  # inside container — should OOM or fail
  stress-ng --vm 1 --vm-bytes 128M --timeout 5s
  ```
  Or run a fork bomb and hit `pids.max`.

---

## Phase 5 — Capabilities and basic hardening

**Goal:** Drop unnecessary privileges inside the container init before exec.

- [ ] Include `<sys/capability.h>` or parse `/proc/self/status` CapEff
- [ ] In child, before exec: keep only what you need (often none for arbitrary user commands)
- [ ] Use `capset(2)` or libcap if available; minimal approach: write Linux capabilities drop via `prctl` + ambient set clearing
- [ ] Set `PR_SET_NO_NEW_PRIVS` before exec to prevent setuid binaries gaining caps
- [ ] Optional: static seccomp-bpf allowlist (blocking `mount`, `pivot_root`, `clone` with flags inside container)
- [ ] **Verify:** run a setuid binary inside container — it should not escalate on host.

---

## Phase 6 — Container state and lifecycle

**Goal:** Multiple containers, list/stop/remove — not just one-shot `run`.

- [ ] Persist state under `/var/run/minic/` or `./run/` (JSON or plain text — your choice):
  ```json
  { "id": "abc123", "init_pid": 12345, "rootfs": "/path", "status": "running" }
  ```
- [ ] `minictl run` → create id (random 6 chars), fork, save state, detach or stay attached (TTY decision)
- [ ] `minictl ps` → read state dir, show id, pid, status, command
- [ ] `minictl stop <id>` → `kill(init_pid, SIGTERM)`, wait, fallback `SIGKILL`, update status
- [ ] `minictl rm <id>` → require stopped; remove state + cgroup + optionally rootfs copy
- [ ] Handle SIGCHLD in parent daemon or rely on synchronous wait in foreground mode
- [ ] **Verify:** start two containers, list both, stop one, confirm cgroup removed from `/sys/fs/cgroup/`.

---

## Phase 7 — Stdio, TTY, and signal forwarding

**Goal:** Interactive shell feels correct; Ctrl+C goes to container.

- [ ] Foreground mode: attach stdin/stdout/stderr to container (already mostly works if you don't redirect)
- [ ] Allocate PTY for interactive `run -t`:
  - `openpty` in parent, pass slave fd to child as stdin/out/err
  - child: `ioctl(TIOCSCTTY)`
- [ ] Forward `SIGWINCH` on terminal resize
- [ ] Forward `SIGINT`/`SIGTERM` from parent to container init when attached
- [ ] **Verify:** `sudo ./minictl run -t ./rootfs /bin/sh` — job control, `reset`, `vi` or `cat` with terminal editing work.

---

## Phase 8 — Network namespace (optional but recommended)

**Goal:** Container has its own loopback and optional outbound connectivity.

- [ ] Add `CLONE_NEWNET` to clone flags
- [ ] In child (before exec, while still privileged):
  - `socket(AF_INET, SOCK_STREAM, 0)` + `ioctl(SIOCSIFFLAGS)` bring up `lo`
  - assign `127.0.0.1`
- [ ] Host-side veth pair (requires root on host):
  - create `veth0` / `veth1`
  - move one end into container net ns (`setns` or write veth pid to net ns)
  - attach host end to bridge `minic0`
  - configure IP / NAT (iptables MASQUERADE or nftables)
- [ ] CLI: `--network bridge` or `--network none`
- [ ] **Verify:**
  ```bash
  # inside
  ping -c1 127.0.0.1
  ping -c1 8.8.8.8   # if NAT configured
  ip addr
  ```

Reference: webserv gave you sockets; this is the same skill applied to `rtnetlink` and `setns`.

---

## Phase 9 — User namespaces (rootless containers)

**Goal:** Run without sudo where possible.

- [ ] Add `CLONE_NEWUSER`
- [ ] Write uid/gid maps before exec:
  ```bash
  echo "0 1000 1" > /proc/<pid>/uid_map
  echo "0 1000 1" > /proc/<pid>/gid_map
  ```
  Map container root (0) to your host UID (1000).
- [ ] Handle `/proc/self/setgroups` (write `deny` for unprivileged single mapping)
- [ ] Some operations still need caps in the **user** namespace — file ownership in rootfs may need adjustment
- [ ] **Verify:** `./minictl run ./rootfs /bin/id` works without sudo; host user unchanged.

---

## Phase 10 — OCI bundle support (stretch)

**Goal:** Run a standard OCI bundle layout.

- [ ] Accept path to bundle: `config.json` + `rootfs/`
- [ ] Parse minimal JSON fields (use `jq`-generated fixtures or a tiny parser):
  - `process.args`, `process.env`, `process.cwd`
  - `linux.namespaces`, `linux.resources`
  - `root.path`, `root.readonly`
- [ ] Map OCI namespace types to `clone` flags
- [ ] **Verify:** run [oci-runtime-spec bundle example](https://github.com/opencontainers/runtime-spec/tree/main/bundle)

---

## Phase 11 — Polish and validation

- [ ] Memory leak check: run under `valgrind` for short-lived containers (parent process only — child exec replaces address space)
- [ ] Error paths: every syscall failure prints useful context (`perror` + container id)
- [ ] Clean teardown on all exit paths (cgroups, mounts, state files)
- [ ] Integration test script in `scripts/test.sh`:
  1. build rootfs if missing
  2. run container, assert hostname
  3. assert memory limit
  4. stop + rm
- [ ] Document flags and env in README

---

## Suggested timeline

| Phase | Focus | Rough effort |
|-------|--------|--------------|
| 0–1 | skeleton + chroot | 1 day |
| 2–3 | namespaces + pivot_root | 2–3 days |
| 4 | cgroups | 1–2 days |
| 5–6 | hardening + lifecycle | 2–3 days |
| 7 | TTY / signals | 1 day |
| 8 | networking | 2–3 days |
| 9 | user ns / rootless | 1–2 days |
| 10–11 | OCI + polish | optional |

---

## Debugging checklist

When something breaks, check in this order:

1. **`strace -f`** on parent and child — see which syscall fails
2. **Missing `/proc`** — `ps`, `top`, and PID 1 semantics break
3. **cgroup not delegated** — writing to `cgroup.procs` fails with EPERM
4. **Mount namespace** — host mounts visible? pivot_root done correctly?
5. **Capabilities** — operation needs `CAP_SYS_ADMIN` outside user ns
6. **Rootfs architecture** — 32 vs 64 bit mismatch

Useful commands:

```bash
ls -la /proc/<pid>/ns/
cat /proc/<pid>/cgroup
nsenter -t <pid> -m -u -i -n -p -- /bin/sh   # manual inspection
```

---

## Definition of done (MVP)

You are finished with the core project when all of these pass:

- [ ] `minictl run ./rootfs /bin/sh -c 'hostname'` shows isolated hostname
- [ ] `/proc` inside lists only container processes
- [ ] Memory limit kills or contains greedy allocator
- [ ] `minictl ps` / `stop` / `rm` manage multiple containers
- [ ] Interactive shell works with `-t`
- [ ] Code is split into logical modules with no single 800-line file

Everything after Phase 8 is enrichment for your portfolio and deeper kernel understanding.

---

## What to read when stuck

| Problem | Read |
|---------|------|
| pivot_root confusion | `man 2 pivot_root`, runc `libcontainer/rootfs_linux.go` |
| cgroup v2 EPERM | kernel cgroup v2 "delegation" docs, `/sys/fs/cgroup/cgroup.controllers` |
| Network veth | `man 8 ip-link`, container networking articles on LWN |
| clone vs unshare | `man 2 clone`, `man 2 unshare` |
| OCI mapping | runtime-spec `config-linux.md` |

Good luck — this is one of the most instructive systems projects you can do on Linux.
