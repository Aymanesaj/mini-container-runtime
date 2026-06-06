# Mini Container Runtime

A lightweight container runtime written in C. The goal is not to replace Docker — it is to understand **how containers actually work at the kernel level** by building the same primitives yourself: namespaces, cgroups, chroot/pivot_root, capabilities, and process lifecycle management.

If you have already built **minishell** (fork/exec, pipes, signals) and **webserv** (I/O multiplexing, sockets, processes), you have most of the user-space skills this project needs. What you will add is kernel-facing isolation: telling Linux to give a process its own view of the filesystem, PID table, network stack, and resource limits.

---

## What is a container, really?

A container is **not** a lightweight VM. It is an ordinary Linux process (or tree of processes) that the kernel treats as isolated through a combination of:

| Mechanism | What it isolates |
|-----------|------------------|
| **Namespaces** | What the process *sees* (PIDs, hostnames, mount points, network interfaces, IPC, users) |
| **cgroups** | What the process *can consume* (CPU, memory, pids, I/O) |
| **chroot / pivot_root** | Where `/` points on disk |
| **Capabilities** | Which privileged operations remain (most are dropped) |
| **seccomp** (optional) | Which syscalls are allowed |

Docker, containerd, Podman, and runc all boil down to orchestrating these same pieces. Your runtime will implement a **minimal subset** of what `runc` does — enough to run an arbitrary command inside an isolated environment and manage its lifecycle.

---

## How this fits in the container ecosystem

```
  docker run nginx
       │
       ▼
  dockerd (daemon: images, networks, volumes)
       │
       ▼
  containerd (container lifecycle, snapshots)
       │
       ▼
  runc (OCI runtime: namespaces + cgroups + rootfs)
       │
       ▼
  your process inside isolated namespaces
```

**This project = you writing the `runc` layer** (and a thin CLI on top). No image registry, no overlay filesystems required for v1 — though you can add them later.

The [OCI Runtime Specification](https://github.com/opencontainers/runtime-spec) defines a `config.json` + `rootfs/` bundle format. Your runtime can start by ignoring the spec and hardcoding paths, then evolve toward OCI compliance as a stretch goal.

---

## Architecture (target)

```
┌─────────────────────────────────────────────────────────┐
│  minictl (CLI)                                          │
│  minictl run <rootfs> <command...>                      │
│  minictl ps / stop / rm                                 │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  runtime core                                           │
│  • create container struct (id, rootfs, config)         │
│  • clone() with namespace flags                         │
│  • setup mounts (pivot_root, /proc, /sys)               │
│  • join/write cgroups                                   │
│  • drop capabilities, set hostname                      │
│  • execve target command                                │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Linux kernel                                           │
│  namespaces · cgroups · vfs · networking                │
└─────────────────────────────────────────────────────────┘
```

### Key design decisions

1. **Two-process model (like runc)**  
   A *parent* (your runtime) stays in the host namespaces and monitors the container. A *child* enters new namespaces, sets up the rootfs, and execs the user command. Communication happens via pipes or a socket passed across `clone()`.

2. **`clone()` not `fork()` for namespace creation**  
   Namespace flags (`CLONE_NEWPID`, `CLONE_NEWNS`, etc.) must be set at process creation time. You cannot add them after the fact.

3. **cgroup v2**  
   Modern distros use unified cgroup v2 (`/sys/fs/cgroup`). Prefer v2 unless your test environment forces v1.

4. **Rootfs = directory tree**  
   For development, use a minimal rootfs built with `debootstrap`, `pacstrap`, or a pre-made [BusyBox rootfs](https://github.com/mirror/busybox). No image layers needed initially.

5. **Privileges**  
   Creating namespaces and mounting generally requires `CAP_SYS_ADMIN` or running as root. User namespaces (`CLONE_NEWUSER`) can map root inside the container to an unprivileged UID outside — add this once basic isolation works.

---

## Namespaces you will use

| Flag | Namespace | Effect |
|------|-----------|--------|
| `CLONE_NEWPID` | PID | PID 1 inside container; host PIDs hidden |
| `CLONE_NEWNS` | Mount | Independent mount table |
| `CLONE_NEWUTS` | UTS | Own hostname / domainname |
| `CLONE_NEWNET` | Network | Own network stack (loopback only until you add veth) |
| `CLONE_NEWIPC` | IPC | Own SysV IPC / POSIX message queues |
| `CLONE_NEWUSER` | User | UID/GID mapping (unprivileged containers) |

Start with **PID + Mount + UTS**. Add network once the basics run `/bin/sh` inside a chrooted rootfs.

---

## cgroups — what you will limit

With cgroup v2, you write limits to files under `/sys/fs/cgroup/<your-group>/`:

- `memory.max` — hard memory cap
- `cpu.max` — CPU bandwidth (`max 100000` = one full core)
- `pids.max` — max number of processes

Your runtime creates a cgroup per container, moves the container init PID into it, and removes the cgroup on teardown.

---

## Rootfs setup (pivot_root)

`chroot(2)` is not enough for production-quality isolation — mount propagation and `..` paths can leak the host. **`pivot_root(2)`** is the correct approach:

1. Bind-mount the container rootfs to itself (makes it a mount point).
2. `pivot_root(new_root, put_old)` — swap root and park the old root at `put_old`.
3. Unmount and remove `put_old`.
4. Mount `proc`, `sysfs`, and optionally `dev` inside the new root.

Inside the container, `/` is the rootfs directory. On the host, that same directory is just a path like `/var/lib/minic/containers/abc123/rootfs`.

---

## Project layout (suggested)

```
mini_container_runtime/
├── Makefile
├── README.md
├── STEPS.md
├── include/
│   ├── container.h
│   ├── namespace.h
│   ├── cgroup.h
│   ├── mount.h
│   └── config.h
├── src/
│   ├── main.c              # CLI entry (minictl)
│   ├── container.c         # lifecycle: create, start, stop, delete
│   ├── namespace.c         # clone flags, child setup
│   ├── cgroup.c            # cgroup v2 create/join/destroy
│   ├── mount.c             # pivot_root, bind mounts, /proc, /sys
│   └── config.c            # parse paths, hostname, resource limits
├── rootfs/                 # gitignored — your test rootfs lives here
└── scripts/
    └── build_rootfs.sh     # debootstrap or busybox helper
```

---

## Requirements

- Linux (namespaces and cgroups are Linux-specific; this will not work on macOS natively)
- GCC or Clang, Make
- Root or sufficient capabilities for namespace/mount operations during development
- Packages for building a test rootfs: `debootstrap` or `busybox-static`

Verify kernel support:

```bash
# cgroup v2 mounted?
mount | grep cgroup2

# namespace support (should exist on any recent kernel)
ls /proc/self/ns/
```

---

## Quick mental model (minishell parallels)

| minishell | this project |
|-----------|--------------|
| `fork()` + `execve()` | same, but child calls `unshare()` or is created with `clone()` flags |
| wait for child exit status | parent monitors container init; reap zombies in PID namespace |
| redir / pipes | setup `/dev/null`, `/dev/pts`, pass stdio through |
| signals to foreground job | forward signals to container PID 1 |
| `$PATH`, env | set minimal env inside container or pass through selectively |

---

## What “done” looks like

Minimum viable runtime:

```bash
sudo ./minictl run ./rootfs /bin/sh
# inside container: hostname is isolated, ps shows only container processes,
# memory limit enforced, exit returns to host

sudo ./minictl ps
sudo ./minictl stop <id>
```

Stretch goals: veth networking, OCI bundle support, user namespaces (rootless), seccomp profile, overlayfs rootfs.

See **[STEPS.md](./STEPS.md)** for the full build order.

---

## References

- [Linux namespaces man page](https://man7.org/linux/man-pages/man7.namespaces.7.html)
- [cgroups v2 documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [runc source](https://github.com/opencontainers/runc) — the real-world reference implementation
- [OCI Runtime Spec](https://github.com/opencontainers/runtime-spec/blob/main/spec.md)
- [LWN: Containers overview](https://lwn.net/Articles/531114/)
- [Fosdem: Building a container from scratch (Julien Danjou)](https://www.youtube.com/results?search_query=build+container+from+scratch+c+namespaces)

---

## License

Educational project — add a license if you publish it.
