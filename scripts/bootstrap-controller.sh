#!/usr/bin/env bash
set -euo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-$HOME/cyberlab-infra}"
PRIVATE_DIR="${PRIVATE_DIR:-$REPO_DIR/private}"
SECRETS_DIR="${SECRETS_DIR:-$PRIVATE_DIR/secrets}"

need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd" >&2
    exit 1
  }
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    git \
    curl \
    sudo \
    python3 \
    python3-pip \
    python3-venv \
    python3-yaml \
    openssh-client \
    ca-certificates \
    gnupg \
    lsb-release \
    ansible
}

install_opentofu() {
  if command -v tofu >/dev/null 2>&1; then
    tofu_version="$(tofu version | sed -n '1p')"
    echo "OpenTofu already installed: $(tofu_version)"
    return
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey \
    | gpg --dearmor -o /etc/apt/keyrings/opentofu.gpg

  . /etc/os-release
  echo "deb [signed-by=/etc/apt/keyrings/opentofu.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" \
    > /etc/apt/sources.list.d/opentofu.list

  apt-get update
  apt-get install -y tofu
}

clone_or_update_repo() {
  if [[ -z "${REPO_URL}" ]]; then
    echo "REPO_URL is required." >&2
    echo "Example: REPO_URL=git@github.com:jalexlong/cyberlab-infra.git sudo bash scripts/bootstrap-controller.sh" >&2
    exit 1
  fi

  if [[ -d "${REPO_DIR}/.git" ]]; then
    echo "Updating existing repo at ${REPO_DIR}"
    git -C "${REPO_DIR}" fetch --all --prune
    git -C "${REPO_DIR}" checkout "${REPO_BRANCH}"
    git -C "${REPO_DIR}" pull --ff-only origin "${REPO_BRANCH}"
  else
    echo "Cloning repo into ${REPO_DIR}"
    git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
  fi
}

create_private_dirs() {
  install -d -m 0700 "${PRIVATE_DIR}"
  install -d -m 0700 "${SECRETS_DIR}"
  install -d -m 0700 "${PRIVATE_DIR}/generated"
}

write_env_helper() {
  install -d -m 0755 "${HOME}/.config/environment.d"
  cat > "${HOME}/.config/environment.d/10-cyberlab.conf" <<'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF
}

print_summary() {
  echo
  echo "Controller bootstrap complete."
  echo "Repo:        ${REPO_DIR}"
  echo "Private dir: ${PRIVATE_DIR}"
  echo "Secrets dir: ${SECRETS_DIR}"
  echo
  ansible_version="$(ansible --version | sed -n '1p')"
  echo "$ansible_version"
  tofu_version="$(tofu version | sed -n '1p')"
  echo "$tofu_version"
  python3 --version
  echo
  echo "Next:"
  echo "  1. Add environment files under data/environments/"
  echo "  2. Add inventory files under ansible/inventories/"
  echo "  3. Store token secrets securely under private/ or Ansible Vault"
  echo "  4. Use: cyberlab-env school-lab"
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root inside the controller LXC." >&2
    exit 1
  fi

  need_cmd apt-get

  install_packages
  need_cmd curl
  need_cmd gpg

  install_opentofu
  clone_or_update_repo
  create_private_dirs

  local target_home
  target_home="/root"
  HOME="${target_home}" write_env_helper

  print_summary
}

main "$@"
