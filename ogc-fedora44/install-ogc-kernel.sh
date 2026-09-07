#!/usr/bin/bash
# Installs the latest Open Gaming Collective (OGC) kernel on a normal (mutable)
# Fedora 44 system. The stock Fedora kernel is kept as a fallback and is never
# removed. No kmods are installed.
#
# Usage:
#   ./install-ogc-kernel.sh             install (or re-verify) the latest OGC kernel
#   ./install-ogc-kernel.sh --update    force re-fetch + install; removes the PREVIOUS ogc kver only
#   ./install-ogc-kernel.sh verify      post-reboot checks (run after rebooting)
#
# OGC_TAG can be overridden to pin a version tag, e.g.:
#   OGC_TAG=7.0.9-ogc3.2-fc44 ./install-ogc-kernel.sh
#
# Optional signature/provenance verification (requires cosign, not in fedora repos):
#   cosign verify --certificate-identity-regexp=".*" \
#     --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
#     "ghcr.io/opengamingcollective/kernel-packages-fedora:latest-fc44"

set -euo pipefail

OCI_REGISTRY="ghcr.io"
OCI_REPOSITORY="opengamingcollective/kernel-packages-fedora"
OGC_TAG="${OGC_TAG:-latest-fc44}"
TARGET_ARCH="x86_64"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPMS_DIR="${SCRIPT_DIR}/rpms"
STATE_FILE="${SCRIPT_DIR}/last-kver"
TMP_DIR="$(mktemp -d)"
TOK=""
trap 'rm -rf "$TMP_DIR"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(uname -m)" == "${TARGET_ARCH}" ]] || die "only ${TARGET_ARCH} supported (running on $(uname -m))"
[[ "$(rpm -E %fedora 2>/dev/null || echo 0)" -ge 44 ]] || die "this script targets Fedora 44+"

for tool in curl jq rpm dnf5 sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found"
done

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
    SUDO="sudo"
fi

fetch_token() {
    curl -fsSL "https://${OCI_REGISTRY}/token?scope=repository:${OCI_REPOSITORY}:pull" \
        | jq -r '.token'
}

fetch_manifest() {
    local out="$1"
    local want_arch
    case "${TARGET_ARCH}" in
        x86_64) want_arch="amd64" ;;
        aarch64) want_arch="arm64" ;;
        *) want_arch="${TARGET_ARCH}" ;;
    esac

    curl -fsSL -H "Authorization: Bearer ${TOK}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://${OCI_REGISTRY}/v2/${OCI_REPOSITORY}/manifests/${OGC_TAG}" -o "$out"

    # If the tag resolved to an index, pull the per-arch member manifest.
    if jq -e '.manifests' "$out" >/dev/null 2>&1; then
        local child
        child="$(jq -r --arg a "${want_arch}" '.manifests[] | select(.platform.architecture == $a) | .digest' "$out" | head -1)"
        [[ -n "${child}" ]] || die "no ${want_arch} manifest in index for tag ${OGC_TAG}"
        curl -fsSL -H "Authorization: Bearer ${TOK}" \
            -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
            "https://${OCI_REGISTRY}/v2/${OCI_REPOSITORY}/manifests/${child}" -o "$out"
    fi

    jq -e '.layers' "$out" >/dev/null || die "manifest for tag ${OGC_TAG} has no layers"
}

download_layer() {
    local digest="$1"
    local blob="${TMP_DIR}/blob"
    local sum name

    curl -fsSL -H "Authorization: Bearer ${TOK}" \
        "https://${OCI_REGISTRY}/v2/${OCI_REPOSITORY}/blobs/${digest}" -o "$blob"

    sum="$(sha256sum "$blob" | awk '{print $1}')"
    [[ "${sum}" == "${digest#sha256:}" ]] || die "digest mismatch for ${digest}"

    name="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}-%{ARCH}.rpm' "$blob" 2>/dev/null || true)"
    [[ -n "${name}" ]] || die "could not read RPM header from blob ${digest}"

    mv -f "$blob" "${RPMS_DIR}/${name}"
    echo "  fetched ${name}"
}

installed_ogc_kver() {
    rpm -qa 2>/dev/null \
        | grep -F -- "kernel-core-" \
        | grep -E -- 'ogc' \
        | sed -E "s/^kernel-core-(.+)\\.${TARGET_ARCH}\$//" \
        | sort -Vr \
        | head -1 || true
}

apply_locks() {
    local p
    for p in kernel kernel-core kernel-modules kernel-modules-core kernel-devel kernel-devel-matched kernel-headers; do
        ${SUDO} dnf5 -y versionlock add "${p}" 2>/dev/null || true
    done
    ${SUDO} dnf5 versionlock list 2>/dev/null || true

    # Keep dnf from ever pulling stock kernel packages back in from the main repos.
    local pat
    for pat in '*fedora*' '*updates*' 'crb'; do
        ${SUDO} dnf5 config-manager setopt "${pat}".exclude='kernel-core-* kernel-modules-* kernel-uki*' 2>/dev/null \
            || echo "note: no repos match pattern '${pat}'; nothing to exclude there"
    done
}

remove_ogc_kver() {
    local kver="$1"
    local nevra
    local nevras

    nevras="$(rpm -qa 2>/dev/null | grep -F -- "-${kver}.${TARGET_ARCH}" || true)"
    if [[ -z "${nevras}" ]]; then
        echo "no installed packages for kver ${kver}; nothing to remove"
        return 0
    fi

    while IFS= read -r nevra; do
        [[ -n "${nevra}" ]] && ${SUDO} dnf5 -y versionlock unlock "${nevra}" 2>/dev/null || true
    done <<< "${nevras}"

    # shellcheck disable=SC2086
    ${SUDO} dnf5 -y remove ${nevras}
    echo "removed old OGC kver ${kver}"
}

install_latest() {
    local force="${1:-0}"
    local kver old core_rpm

    if [[ "${force}" -eq 0 && -f "${STATE_FILE}" && "$(uname -r)" == "$(sed -n 1p "${STATE_FILE}")" ]]; then
        echo "already running $(sed -n 1p "${STATE_FILE}"); nothing to do (use --update to force a re-fetch)"
        return 0
    fi

    echo "== fetching OGC kernel packages (tag: ${OGC_TAG}) =="
    TOK="$(fetch_token)"
    fetch_manifest "${TMP_DIR}/manifest.json"

    mkdir -p "${RPMS_DIR}"
    jq -r '.layers[] | .digest' "${TMP_DIR}/manifest.json" | while IFS= read -r digest; do
        [[ -n "${digest}" ]] && download_layer "${digest}"
    done

    core_rpm="$(ls -1 "${RPMS_DIR}" 2>/dev/null | grep -E "^kernel-core-[^/]+\.rpm$" | head -1 || true)"
    [[ -n "${core_rpm}" ]] || die "downloaded packages contain no kernel-core RPM; aborting"
    kver="$(basename "${core_rpm}" .rpm | sed -E 's/^kernel-core-//; s/\.'"${TARGET_ARCH}"'\.$//')"
    [[ -n "${kver}" ]] || die "could not determine kernel version from ${core_rpm}"

    echo "== installing OGC kernel ${kver} (stock kernel remains as fallback) =="
    # shellcheck disable=SC2046
    ${SUDO} dnf5 -y --nogpgcheck install $(compgen -G "${RPMS_DIR}/*.rpm")

    if [[ "${force}" -eq 1 && -f "${STATE_FILE}" ]]; then
        old="$(sed -n 1p "${STATE_FILE}")"
        if [[ -n "${old}" && "${old}" != "${kver}" ]]; then
            remove_ogc_kver "${old}"
        fi
    fi

    printf '%s\n' "${kver}" > "${STATE_FILE}"
    apply_locks

    echo
    echo "== installed OGC kernel ${kver}; stock kernel kept as fallback =="
    echo "1. reboot:   sudo reboot"
    echo "2. confirm:  $0 verify"
}

verify() {
    [[ -f "${STATE_FILE}" ]] || die "no install state found (${STATE_FILE}); run the installer first"
    local want running
    want="$(sed -n 1p "${STATE_FILE}")"

    echo "== OGC kernel verification (expected kver: ${want}) =="
    running="$(uname -r)"
    echo "running kernel:  ${running}"
    if [[ "${running}" != "${want}" ]]; then
        echo "WARNING: expected ${want} but system is running ${running}, e.g. forgot to reboot" >&2
    else
        echo "OK: running the installed OGC kernel"
    fi

    echo
    echo "installed kernel-core packages:"
    rpm -q kernel-core 2>/dev/null || true

    local new_ogc
    new_ogc="$(installed_ogc_kver)"
    if [[ -n "${new_ogc}" && "${new_ogc}" != "${want}" ]]; then
        echo "note: a different/newer OGC kver is installed: ${new_ogc}" >&2
    fi

    echo
    local images
    images="$(find /boot /boot/efi -maxdepth 4 -name "*${want}.img" 2>/dev/null || true)"
    if [[ -n "${images}" ]]; then
        echo "initramfs images for ${want}:"
        echo "${images}"
    else
        echo "WARNING: no initramfs image found for ${want} (dracut post-install may not have run)" >&2
    fi

    echo
    echo "grub env:"
    grub2-editenv list 2>/dev/null || true

    echo
    echo "== done. Test your OGC feature set (e.g. HDMI FRL / display features) on the running kernel =="
}

case "${1:-}" in
    "")
        install_latest 0
        ;;
    --update)
        install_latest 1
        ;;
    verify)
        verify
        ;;
    -h|--help|help)
        sed -n '2,14p' "$0"
        ;;
    *)
        die "unknown command: $1 (expected no args, --update, or verify)"
        ;;
esac
