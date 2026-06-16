#!/usr/bin/env bash
set -euo pipefail

ROOTFS_DIR="${1:-./rootfs}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${EUID}" -eq 0 ]]; then
	SUDO=()
else
	SUDO=(sudo)
fi

cd "${PROJECT_DIR}"

if [[ -d "${ROOTFS_DIR}/bin" && -x "${ROOTFS_DIR}/bin/sh" ]]; then
	echo "rootfs already exists at ${ROOTFS_DIR} (skipping build)"
	exit 0
fi

build_with_debootstrap() {
	local suite="${1:-stable}"
	echo "Building rootfs with debootstrap (${suite})..."
	"${SUDO[@]}" debootstrap --variant=minbase "${suite}" "${ROOTFS_DIR}"
}

build_with_busybox() {
	local busybox_bin
	local applet

	busybox_bin="$(command -v busybox-static 2>/dev/null || command -v busybox)"
	echo "Building minimal rootfs with BusyBox (${busybox_bin})..."

	rm -rf "${ROOTFS_DIR}"
	mkdir -p "${ROOTFS_DIR}"/{bin,etc,dev,proc,sys,lib,lib64,usr/bin}

	cp "${busybox_bin}" "${ROOTFS_DIR}/bin/busybox"
	for applet in sh ls id cat echo mkdir mount umount sleep; do
		ln -sf busybox "${ROOTFS_DIR}/bin/${applet}"
	done

	cat >"${ROOTFS_DIR}/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
EOF

	cat >"${ROOTFS_DIR}/etc/group" <<'EOF'
root:x:0:
nobody:x:65534:
EOF

	if [[ "${EUID}" -eq 0 ]]; then
		"${SUDO[@]}" chroot "${ROOTFS_DIR}" /bin/busybox --install -s /bin
		"${SUDO[@]}" mknod -m 666 "${ROOTFS_DIR}/dev/null" c 1 3
		"${SUDO[@]}" mknod -m 666 "${ROOTFS_DIR}/dev/zero" c 1 5
		"${SUDO[@]}" mknod -m 666 "${ROOTFS_DIR}/dev/tty" c 5 0
		"${SUDO[@]}" mknod -m 600 "${ROOTFS_DIR}/dev/console" c 5 1
	fi
}

if [[ "${USE_DEBOOTSTRAP:-0}" -eq 1 ]] \
	&& [[ "${EUID}" -eq 0 ]] \
	&& command -v debootstrap >/dev/null 2>&1; then
	build_with_debootstrap stable
elif command -v busybox >/dev/null 2>&1 \
	|| command -v busybox-static >/dev/null 2>&1; then
	build_with_busybox
elif [[ "${EUID}" -eq 0 ]] && command -v debootstrap >/dev/null 2>&1; then
	build_with_debootstrap stable
elif command -v debootstrap >/dev/null 2>&1; then
	echo "error: debootstrap requires root; re-run with sudo or set USE_DEBOOTSTRAP=1" >&2
	exit 1
else
	echo "error: need debootstrap or busybox to build a rootfs" >&2
	exit 1
fi

echo "rootfs ready at ${ROOTFS_DIR}"
