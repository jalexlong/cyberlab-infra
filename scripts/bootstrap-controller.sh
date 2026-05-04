#!/usr/bin/env bash
set -euo pipefail

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
    software-properties-common \
    ansible
}

install_opentofu() {
  if command -v tofu >/dev/null 2>&1; then
    echo "OpenTofu already installed: $(tofu version | head -n 1)"
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
  local helper="${HOME}/.local/bin/cyberlab-env"
  install -d -m 0755 "${HOME}/.local/bin"

  cat > "${helper}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="${REPO_DIR:-$HOME/cyberlab-infra}"

if [[ $# -lt 1 ]]; then
  echo "usage: cyberlab-env <school-lab|demo-lab>" >&2
  exit 1
fi

ENV_NAME="$1"
case "${ENV_NAME}" in
  school-lab|demo-lab) ;;
  *)
    echo "Unsupported environment: ${ENV_NAME}" >&2
    exit 1
    ;;
esac

export CYBERLAB_ENV="${ENV_NAME}"
export CYBERLAB_REPO_ROOT="${REPO_DIR}"
export CYBERLAB_ENV_FILE="${REPO_DIR}/data/environments/${ENV_NAME}.yml"
export TF_VAR_environment_file="${CYBERLAB_ENV_FILE}"
export ANSIBLE_INVENTORY="${REPO_DIR}/ansible/inventories/${ENV_NAME}.yml"

echo "CYBERLAB_ENV=${CYBERLAB_ENV}"
echo "CYBERLAB_ENV_FILE=${CYBERLAB_ENV_FILE}"
echo "ANSIBLE_INVENTORY=${ANSIBLE_INVENTORY}"
EOF

  chmod 0755 "${helper}"
}

print_summary() {
  echo
  echo "Controller bootstrap complete."
  echo "Repo:        ${REPO_DIR}"
  echo "Private dir: ${PRIVATE_DIR}"
  echo "Secrets dir: ${SECRETS_DIR}"
  echo
  ansible --version | head -n 1
  tofu version | head -n 1
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
  need_cmd curl
  need_cmd gpg

  install_packages
  install_opentofu
  clone_or_update_repo
  create_private_dirs

  local target_home
  target_home="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
  if [[ -n "${target_home}" && -d "${target_home}" ]]; then
    HOME="${target_home}" write_env_helper
    chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "${REPO_DIR}" "${PRIVATE_DIR}" "${target_home}/.local"
  else
    write_env_helper
  fi

  print_summary
}

main "$@"
