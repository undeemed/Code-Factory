# Code Factory container worker.
#
# This image is a repeatable, isolated, NON-ROOT worker and a provisioning smoke
# surface. It is deliberately NOT a native host:
#   * no systemd, no user manager, no `loginctl enable-linger`
#   * no SSH server, no Tailscale daemon, no XFCE/TigerVNC/noVNC desktop
#   * no host Docker socket, no host PID/network namespace, no credential binds
# Those live only on a real host provisioned by ansible/** with
# factory.start_services=true. Inside this image the factory configuration sets
# start_services=false and disables the docker/tailscale/desktop profiles, so the
# playbook performs file/tool convergence only.
#
# Base image pinned by digest, verified 2026-09-15 against registry-1.docker.io:
#   ubuntu:24.04
#     index digest  sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254
#     annotations   org.opencontainers.image.version=24.04
#                   org.opencontainers.image.created=2026-09-05T00:00:00Z
#                   org.opencontainers.image.source=https://git.launchpad.net/cloud-images/+oci/ubuntu-base
#     linux/amd64   sha256:a61567bd31828687156d735ea8eb01ba4e37636e225dd6a48ba94136a70d9d61
#     linux/arm64   sha256:ec0b1c9058e44c837a21c3f9d8a3d5e9aaa94ed28edceb18e154af5efecf0950
#
# Build targets:
#   base    OS packages and the factory account only (no repository content)
#   worker  provisioned worker image; devcontainer and compose default
#   smoke   worker + tests/container-smoke.sh as CMD (behavior smoke)
#
# Distribution packages are intentionally not version-frozen: docs/security.md
# treats operating-system security updates as an OS responsibility rather than
# pinning a whole vulnerable package index. Reproducibility comes from the base
# image digest plus the checksum-pinned tool lock consumed by the installer.

ARG UBUNTU_IMAGE=ubuntu:24.04
ARG UBUNTU_DIGEST=sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254

FROM ${UBUNTU_IMAGE}@${UBUNTU_DIGEST} AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG FACTORY_USER=coder
ARG FACTORY_UID=1000
ARG FACTORY_GID=1000
ARG FACTORY_HOME=/home/coder
ARG FACTORY_WORKSPACE=/home/coder/Dev

# Prerequisites for: the uv bootstrap, ansible-core running against localhost
# (ansible.builtin.apt imports python3-apt from the system interpreter, so it is
# installed here instead of being auto-installed mid-playbook), the
# checksum-pinned tool installer (curl/ca-certificates/unzip/xz), the
# development profile (rustup toolchains need a C toolchain and pkg-config),
# and the behavior smoke script (procps/iproute2/jq).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        git \
        iproute2 \
        jq \
        less \
        libssl-dev \
        openssh-client \
        pkg-config \
        procps \
        python3 \
        python3-apt \
        python3-venv \
        sudo \
        tar \
        unzip \
        xz-utils \
        zstd; \
    rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 ships an "ubuntu" account on uid/gid 1000. Release the id before
# claiming it for the factory user so uid/gid stay configurable and stable.
RUN set -eux; \
    if getent passwd "${FACTORY_UID}" >/dev/null; then \
        existing_user="$(getent passwd "${FACTORY_UID}" | cut -d: -f1)"; \
        if [ "${existing_user}" != "${FACTORY_USER}" ]; then \
            userdel -r "${existing_user}" >/dev/null 2>&1 || userdel "${existing_user}"; \
        fi; \
    fi; \
    if getent group "${FACTORY_GID}" >/dev/null; then \
        existing_group="$(getent group "${FACTORY_GID}" | cut -d: -f1)"; \
        if [ "${existing_group}" != "${FACTORY_USER}" ]; then groupdel "${existing_group}"; fi; \
    fi; \
    if ! getent group "${FACTORY_USER}" >/dev/null; then \
        groupadd --gid "${FACTORY_GID}" "${FACTORY_USER}"; \
    fi; \
    if ! getent passwd "${FACTORY_USER}" >/dev/null; then \
        useradd --create-home --home-dir "${FACTORY_HOME}" \
                --uid "${FACTORY_UID}" --gid "${FACTORY_GID}" \
                --shell /bin/bash "${FACTORY_USER}"; \
    fi; \
    install -d -o "${FACTORY_USER}" -g "${FACTORY_USER}" -m 0755 \
        "${FACTORY_HOME}/.local" \
        "${FACTORY_HOME}/.local/bin" \
        "${FACTORY_HOME}/.local/share" \
        "${FACTORY_HOME}/.local/state" \
        "${FACTORY_HOME}/.config" \
        "${FACTORY_HOME}/.cache" \
        "${FACTORY_WORKSPACE}" \
        /opt/code-factory; \
    # Ansible become for the unprivileged factory user. The container publishes no
    # ports by default, mounts no host socket and holds no host credentials, so the
    # blast radius of this sudoers entry is the container itself. A real host keeps
    # its own sudo policy; this file is never applied by ansible/**.
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${FACTORY_USER}" > /etc/sudoers.d/90-code-factory; \
    chmod 0440 /etc/sudoers.d/90-code-factory; \
    visudo -cf /etc/sudoers.d/90-code-factory

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    FACTORY_USER=${FACTORY_USER} \
    FACTORY_HOME=${FACTORY_HOME} \
    HOME=${FACTORY_HOME} \
    FACTORY_WORKSPACE=${FACTORY_WORKSPACE} \
    CODE_FACTORY_ROOT=/opt/code-factory \
    PATH=${FACTORY_HOME}/.local/bin:${FACTORY_HOME}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------------------------------------------------------------------------
# worker: provisioned image built through the repository's own CLI interfaces.
# ---------------------------------------------------------------------------
FROM base AS worker

ARG FACTORY_USER=coder
ARG FACTORY_HOME=/home/coder
ARG FACTORY_WORKSPACE=/home/coder/Dev
ARG FACTORY_CONFIG=containers/factory.container.yml

COPY --chown=${FACTORY_USER}:${FACTORY_USER} . /opt/code-factory

RUN set -eux; \
    printf 'role=worker\nsource=/opt/code-factory\nuser=%s\nhome=%s\nworkspace=%s\nconfig=%s\nsystemd=absent\ntailscale=absent\ndesktop=absent\n' \
        "${FACTORY_USER}" "${FACTORY_HOME}" "${FACTORY_WORKSPACE}" "${FACTORY_CONFIG}" \
        > /etc/code-factory-image; \
    chmod 0444 /etc/code-factory-image

USER ${FACTORY_USER}
WORKDIR /opt/code-factory

# Executable bits are part of the interface: ./bootstrap.sh, ./factory and the
# smoke script are invoked directly, including from a context that lost them.
RUN set -eux; chmod +x bootstrap.sh factory tests/container-smoke.sh

# Pinned uv bootstrap + locked Python dependencies (no provisioning yet).
RUN set -eux; ./bootstrap.sh

# Schema validation through the repository's own validator.
RUN set -eux; ./factory validate --config "${FACTORY_CONFIG}"

# A valid document is not automatically the right document: this guard parses it
# and compares it with the live image account, then refuses any capability an
# ordinary container cannot host.
RUN set -eux; uv run --project . --locked python containers/assert-image-config.py "${FACTORY_CONFIG}"

# The real convergence run. `apply` installs the checksum-pinned agent and
# development toolchain through scripts/install_tools.py and renders the
# user-scope files; start_services=false keeps it off systemd and linger.
RUN set -eux; ./factory apply --config "${FACTORY_CONFIG}"

ENV CODE_FACTORY_IMAGE=worker \
    CODE_FACTORY_CONFIG=/opt/code-factory/${FACTORY_CONFIG}

LABEL org.opencontainers.image.title="code-factory-worker" \
      org.opencontainers.image.description="Isolated non-root Code Factory worker; no systemd, Tailscale or desktop." \
      org.opencontainers.image.source="https://github.com/undeemed/Code-Factory" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:24.04" \
      org.opencontainers.image.base.digest="sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254"

WORKDIR ${FACTORY_WORKSPACE}
CMD ["/bin/bash"]

# ---------------------------------------------------------------------------
# smoke: identical filesystem, runs the behavior smoke as its default command.
# ---------------------------------------------------------------------------
FROM worker AS smoke

ENV CODE_FACTORY_IMAGE=smoke

LABEL org.opencontainers.image.title="code-factory-smoke" \
      org.opencontainers.image.description="Code Factory worker image running tests/container-smoke.sh."

WORKDIR /opt/code-factory
CMD ["/opt/code-factory/tests/container-smoke.sh", "--in-container"]
