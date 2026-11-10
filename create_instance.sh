#!/usr/bin/env bash
#
# sige-seaweedfs - Proxmox VE recipe for a SeaweedFS LXC container.
#
# Run this script as root on a Proxmox VE host:
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/loganrf/sige-seaweedfs/refs/heads/main/create_instance.sh)"
#
# The wizard asks for each setting and then shows a review screen. On the
# review screen, you can change each setting before the recipe makes the
# container. To make a container with no questions, use an answers file:
#
#   ./create_instance.sh --unattended --config my.answers
#
# Use --help to see all the options. Refer to README.md for more data.
#
set -Eeuo pipefail

readonly RECIPE_VERSION="1.0.0"
readonly RECIPE_URL="https://github.com/loganrf/sige-seaweedfs"
readonly BACKTITLE="sige-seaweedfs ${RECIPE_VERSION}  |  SeaweedFS LXC for Proxmox VE"
readonly PAYLOAD_PATH="/root/.sige-seaweedfs-install.sh"

# =============================================================================
# Answers
# =============================================================================
# Each answer is one setting. The wizard shows these values as defaults. An
# answers file (--config FILE) and --set KEY=VALUE can change them.

ANSWER_KEYS=(
  SWFS_ROLE
  CT_ID CT_HOSTNAME CT_TAGS CT_OS CT_TEMPLATE_STORAGE
  CT_ROOTFS_STORAGE CT_ROOTFS_SIZE CT_CORES CT_MEMORY CT_SWAP
  CT_UNPRIVILEGED CT_ONBOOT CT_PASSWORD CT_SSH_KEY_FILE
  DATA_MODE DATA_STORAGE DATA_SIZE DATA_HOST_PATH DATA_MOUNT DATA_BACKUP
  NET_BRIDGE NET_IP NET_GW NET_VLAN NET_IP6 NET_DNS NET_SEARCHDOMAIN
  SWFS_VERSION SWFS_VARIANT SWFS_RELEASE_URL
  SWFS_MASTER SWFS_PEERS SWFS_ADVERTISE SWFS_REPLICATION SWFS_DATACENTER SWFS_RACK
  SWFS_VOLUME_SIZE_MB SWFS_VOLUME_MAX SWFS_INDEX SWFS_DISK_TYPE
  SWFS_FILER SWFS_S3 SWFS_WEBDAV SWFS_ADMIN SWFS_METRICS SWFS_ICEBERG SWFS_TELEMETRY
  SWFS_S3_ACCESS_KEY SWFS_S3_SECRET_KEY SWFS_BUCKETS
  SWFS_ADMIN_USER SWFS_ADMIN_PASSWORD SWFS_EXTRA_ARGS
  PORT_MASTER PORT_VOLUME PORT_FILER PORT_S3 PORT_WEBDAV PORT_ADMIN
  PORT_METRICS PORT_ICEBERG PORT_LANCE
  FW_ENABLE FW_SOURCE FW_SSH
)

# The recipe does not write these answers to a saved answers file.
SECRET_KEYS=(CT_PASSWORD SWFS_S3_ACCESS_KEY SWFS_S3_SECRET_KEY SWFS_ADMIN_PASSWORD)

set_defaults() {
  SWFS_ROLE="all-in-one"         # all-in-one | master | volume | filer

  CT_ID=""                       # blank: the next free ID
  CT_HOSTNAME="seaweedfs"
  CT_TAGS="seaweedfs"
  CT_OS="debian-13"              # debian-13 | debian-12
  CT_TEMPLATE_STORAGE=""         # blank: select automatically
  CT_ROOTFS_STORAGE=""           # blank: select automatically
  CT_ROOTFS_SIZE="8"             # GiB
  CT_CORES="2"
  CT_MEMORY="2048"               # MiB
  CT_SWAP="512"                  # MiB
  CT_UNPRIVILEGED="1"
  CT_ONBOOT="1"
  CT_PASSWORD=""                 # blank: make a random password
  CT_SSH_KEY_FILE=""

  DATA_MODE="volume"             # volume | bind | rootfs
  DATA_STORAGE=""                # blank: the root disk storage
  DATA_SIZE="64"                 # GiB
  DATA_HOST_PATH=""              # host directory for DATA_MODE=bind
  DATA_MOUNT="/data"
  DATA_BACKUP="1"

  NET_BRIDGE="vmbr0"
  NET_IP="dhcp"                  # dhcp | IPv4 address in CIDR format
  NET_GW=""
  NET_VLAN=""
  NET_IP6="none"                 # none | auto | dhcp
  NET_DNS=""
  NET_SEARCHDOMAIN=""

  SWFS_VERSION="latest"
  SWFS_VARIANT="standard"        # standard | large_disk | full | full_large_disk
  SWFS_RELEASE_URL="https://github.com/seaweedfs/seaweedfs/releases"
  SWFS_MASTER=""                 # host:port list, for the volume and filer roles
  SWFS_PEERS=""
  SWFS_ADVERTISE=""
  SWFS_REPLICATION="000"
  SWFS_DATACENTER=""
  SWFS_RACK=""
  SWFS_VOLUME_SIZE_MB=""         # blank: calculate from the data disk size
  SWFS_VOLUME_MAX="0"            # 0: calculate from the free disk space
  SWFS_INDEX="memory"
  SWFS_DISK_TYPE=""

  SWFS_FILER="1"
  SWFS_S3="1"
  SWFS_WEBDAV="0"
  SWFS_ADMIN="1"
  SWFS_METRICS="0"
  SWFS_ICEBERG="0"
  SWFS_TELEMETRY="0"

  SWFS_S3_ACCESS_KEY=""          # blank: make a random key
  SWFS_S3_SECRET_KEY=""          # blank: make a random key
  SWFS_BUCKETS=""
  SWFS_ADMIN_USER="admin"
  SWFS_ADMIN_PASSWORD=""         # blank: make a random password
  SWFS_EXTRA_ARGS=""

  PORT_MASTER="9333"
  PORT_VOLUME="8080"
  PORT_FILER="8888"
  PORT_S3="8333"
  PORT_WEBDAV="7333"
  PORT_ADMIN="12535"
  PORT_METRICS="9327"
  PORT_ICEBERG="8181"
  PORT_LANCE="9101"

  FW_ENABLE="0"
  FW_SOURCE=""                   # blank: accept all source addresses
  FW_SSH="1"
}

# Run-time state. These are not answers.
OPT_CONFIG=""
OPT_UNATTENDED=0
OPT_DRY_RUN=0
OPT_SAVE=""
OPT_SETS=()
WIZARD_MODE="quick"
NET_IP_MODE="dhcp"
FW_SOURCE_SUGGESTED=0
CT_CREATED=0
FAILED_CMD=""
PAYLOAD_FILE=""
NEXT_ID="100"
HOST_GW=""
HOST_ARCH="amd64"
TEMPLATE_VOLID=""
CT_IP=""
ROOTDIR_STORAGES=()
VZTMPL_STORAGES=()
BRIDGES=()
declare -A STORAGE_DESC=()
declare -A EXPLICIT=() # The answers that came from an answers file or --set.

# =============================================================================
# Output
# =============================================================================
if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_OFF=$'\e[0m'
else
  C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_OFF=""
fi

msg() { printf '%s==>%s %s\n' "${C_GREEN}${C_BOLD}" "$C_OFF" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "${C_YELLOW}${C_BOLD}" "$C_OFF" "$*" >&2; }
die() {
  printf '%sERROR:%s %s\n' "${C_RED}${C_BOLD}" "$C_OFF" "$*" >&2
  exit 1
}

# Run a command that changes the host. With --dry-run, show the command only.
run() {
  if ((OPT_DRY_RUN)); then
    printf '%s[dry-run]%s' "$C_YELLOW" "$C_OFF"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  FAILED_CMD="$*"
  "$@"
  FAILED_CMD=""
}

on_error() {
  local rc=$? line=$1
  trap - ERR
  printf '%sERROR:%s "%s" stopped with exit code %s (script line %s).\n' \
    "${C_RED}${C_BOLD}" "$C_OFF" "${FAILED_CMD:-$BASH_COMMAND}" "$rc" "$line" >&2
  if ((CT_CREATED)); then
    printf 'The container %s exists, but the setup is not complete.\n' "$CT_ID" >&2
    printf '  To examine the container, enter:  pct enter %s\n' "$CT_ID" >&2
    printf '  To remove the container, enter:   pct destroy %s --purge\n' "$CT_ID" >&2
  fi
  exit "$rc"
}

on_exit() {
  if [[ -n $PAYLOAD_FILE && -e $PAYLOAD_FILE ]] && ((!OPT_DRY_RUN)); then
    rm -f "$PAYLOAD_FILE"
  fi
}

trap 'on_error $LINENO' ERR
trap on_exit EXIT

usage() {
  cat <<EOF
sige-seaweedfs ${RECIPE_VERSION} - make a SeaweedFS LXC container on Proxmox VE.

Usage: create_instance.sh [OPTION]...

With no option, the script starts a wizard. The wizard asks for the settings
and shows a review screen before it makes the container.

Options:
  -c, --config FILE    Read answers from FILE (KEY="value" lines).
  -s, --set KEY=VALUE  Set one answer. You can use this option more than once.
  -u, --unattended     Do not start the wizard. Use the defaults and the answers.
  -n, --dry-run        Show the commands. Do not change the host.
      --save FILE      Write the answers to FILE, then stop. Secrets are not saved.
  -h, --help           Show this help, then stop.
  -V, --version        Show the recipe version, then stop.

Examples:
  create_instance.sh
  create_instance.sh --unattended --set SWFS_ROLE=all-in-one --set SWFS_BUCKETS=backups
  create_instance.sh --unattended --config volume-node.answers

Refer to ${RECIPE_URL} for the list of answers.
EOF
}

# =============================================================================
# Small helpers
# =============================================================================
trim() {
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    if [[ $item == "$needle" ]]; then return 0; fi
  done
  return 1
}

is_secret() { in_list "$1" "${SECRET_KEYS[@]}"; }

# bool CMD...: print 1 if the command succeeds, else 0.
bool() {
  if "$@"; then echo 1; else echo 0; fi
}

# gen_secret LENGTH [CHARACTER-SET]
gen_secret() {
  local len=$1 set=${2:-A-Za-z0-9} out=""
  while ((${#out} < len)); do
    out+=$(LC_ALL=C tr -dc "$set" < <(head -c 512 /dev/urandom))
  done
  printf '%s' "${out:0:len}"
}

# cidr_network 192.168.1.10/24 -> 192.168.1.0/24
cidr_network() {
  local ip=${1%/*} prefix=${1#*/} a b c d n mask
  IFS=. read -r a b c d <<<"$ip"
  n=$(((a << 24) | (b << 16) | (c << 8) | d))
  if ((prefix == 0)); then mask=0; else mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF)); fi
  n=$((n & mask))
  printf '%d.%d.%d.%d/%d\n' $((n >> 24 & 255)) $((n >> 16 & 255)) $((n >> 8 & 255)) $((n & 255)) "$prefix"
}

role_in() {
  local r
  for r in "$@"; do
    if [[ $SWFS_ROLE == "$r" ]]; then return 0; fi
  done
  return 1
}

# These functions tell which SeaweedFS parts run in the container.
has_master() { role_in all-in-one master; }
has_volume() { role_in all-in-one volume; }
has_filer() {
  role_in filer && return 0
  role_in all-in-one && [[ $SWFS_FILER == 1 || $SWFS_S3 == 1 || $SWFS_WEBDAV == 1 ]]
}
has_s3() { role_in all-in-one filer && [[ $SWFS_S3 == 1 ]]; }
has_webdav() { role_in all-in-one filer && [[ $SWFS_WEBDAV == 1 ]]; }
has_admin() { role_in all-in-one master filer && [[ $SWFS_ADMIN == 1 ]]; }
has_metrics() { [[ $SWFS_METRICS == 1 ]]; }
has_iceberg() { has_s3 && [[ $SWFS_ICEBERG == 1 ]]; }
has_telemetry_option() { has_master; }

ctid_in_use() {
  local f
  for f in /etc/pve/nodes/*/lxc/"$1".conf /etc/pve/nodes/*/qemu-server/"$1".conf; do
    if [[ -e $f ]]; then return 0; fi
  done
  return 1
}

# The volume size that "weed mini" also uses: 1% of the disk, rounded up to a
# power of 2, from 64 MB to 1024 MB.
auto_volume_size_mb() {
  local gb="" mb size=64 p
  if ! has_volume; then
    echo 1024
    return 0
  fi
  case $DATA_MODE in
    volume) gb=$DATA_SIZE ;;
    rootfs) gb=$CT_ROOTFS_SIZE ;;
    bind)
      p=${DATA_HOST_PATH:-/}
      while [[ ! -e $p ]]; do p=$(dirname "$p"); done
      gb=$(df -BG --output=size "$p" 2>/dev/null | tail -n 1 | tr -dc '0-9' || true)
      ;;
  esac
  [[ $gb =~ ^[0-9]+$ ]] || gb=100
  mb=$((gb * 1024 / 100))
  while ((size < mb && size < 1024)); do size=$((size * 2)); done
  echo "$size"
}

effective_volume_size() {
  if [[ -n $SWFS_VOLUME_SIZE_MB ]]; then echo "$SWFS_VOLUME_SIZE_MB"; else auto_volume_size_mb; fi
}

# Print "PORT NAME" for each port that the container uses.
used_ports() {
  if has_master; then
    echo "$PORT_MASTER master"
    echo "$((PORT_MASTER + 10000)) master-grpc"
  fi
  if has_volume; then
    echo "$PORT_VOLUME volume"
    echo "$((PORT_VOLUME + 10000)) volume-grpc"
  fi
  if has_filer; then
    echo "$PORT_FILER filer"
    echo "$((PORT_FILER + 10000)) filer-grpc"
  fi
  if has_s3; then
    echo "$PORT_S3 s3"
    echo "$((PORT_S3 + 10000)) s3-grpc"
  fi
  if has_webdav; then echo "$PORT_WEBDAV webdav"; fi
  if has_admin; then
    echo "$PORT_ADMIN admin"
    echo "$((PORT_ADMIN + 10000)) admin-grpc"
  fi
  if has_metrics; then echo "$PORT_METRICS metrics"; fi
  if has_iceberg; then
    echo "$PORT_ICEBERG iceberg"
    echo "$PORT_LANCE lance"
  fi
  return 0
}

# =============================================================================
# Validation
# =============================================================================
# Each validator gets the value as its last argument. If the value is not
# correct, the validator prints a message and returns 1.

readonly RE_IPV4='((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
readonly RE_LABEL='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
readonly RE_HOSTPORT='[A-Za-z0-9.-]+:[0-9]{1,5}'

v_int() {
  local min=$1 max=$2 v=$3
  if [[ $v =~ ^[0-9]{1,10}$ ]] && ((10#$v >= min && 10#$v <= max)); then return 0; fi
  echo "Enter a whole number from $min to $max."
  return 1
}

v_choice() {
  if [[ "|$1|" == *"|$2|"* ]]; then return 0; fi
  echo "Use one of these values: ${1//|/, }."
  return 1
}

v_bool() { v_choice "0|1" "$1"; }

v_ctid() {
  v_int 100 999999999 "$1" || return 1
  if ctid_in_use "$1"; then
    echo "A guest with ID $1 exists. Enter a different ID."
    return 1
  fi
  return 0
}

v_hostname() {
  if [[ ${#1} -le 253 && $1 =~ ^${RE_LABEL}(\.${RE_LABEL})*$ ]]; then return 0; fi
  echo "Use letters, digits, hyphens and dots. A label cannot start or end with a hyphen."
  return 1
}

v_tags() {
  if [[ -z $1 || $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.+-]*(\;[A-Za-z0-9_][A-Za-z0-9_.+-]*)*$ ]]; then return 0; fi
  echo "Separate the tags with semicolons. Use letters, digits and the characters _ . + -"
  return 1
}

v_rootdir_storage() {
  if in_list "$1" "${ROOTDIR_STORAGES[@]}"; then return 0; fi
  echo "Use an active storage that holds container disks: ${ROOTDIR_STORAGES[*]:-none found}."
  return 1
}

v_data_storage() {
  if [[ -z $1 ]]; then return 0; fi
  v_rootdir_storage "$1"
}

v_tmpl_storage() {
  if in_list "$1" "${VZTMPL_STORAGES[@]}"; then return 0; fi
  echo "Use an active storage that holds container templates: ${VZTMPL_STORAGES[*]:-none found}."
  return 1
}

v_abs_path() {
  if [[ $1 == /* && $1 != / && $1 != *[[:space:],\;]* ]]; then return 0; fi
  echo "Enter an absolute path, for example /data. Do not use spaces, commas or semicolons."
  return 1
}

v_host_path() {
  v_abs_path "$1" || return 1
  if [[ -e $1 && ! -d $1 ]]; then
    echo "$1 is not a directory."
    return 1
  fi
  case $1 in
    /etc/pve | /etc/pve/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/*)
      echo "You cannot use $1 for data."
      return 1
      ;;
  esac
  return 0
}

v_bridge() {
  if ((${#BRIDGES[@]} == 0)) || in_list "$1" "${BRIDGES[@]}"; then return 0; fi
  echo "Use a bridge of this host: ${BRIDGES[*]}."
  return 1
}

v_ipv4_cidr() {
  if [[ $1 =~ ^${RE_IPV4}/([1-9]|[12][0-9]|3[0-2])$ ]]; then return 0; fi
  echo "Enter an IPv4 address in CIDR format, for example 192.168.1.50/24."
  return 1
}

v_opt_ipv4() {
  if [[ -z $1 || $1 =~ ^${RE_IPV4}$ ]]; then return 0; fi
  echo "Enter an IPv4 address, for example 192.168.1.1, or leave the field blank."
  return 1
}

v_vlan() {
  if [[ -z $1 ]]; then return 0; fi
  v_int 1 4094 "$1"
}

v_dns() {
  local ip
  for ip in $1; do
    if [[ ! $ip =~ ^${RE_IPV4}$ && ! $ip =~ ^[0-9A-Fa-f:]+$ ]]; then
      echo "\"$ip\" is not an IP address. Separate the addresses with spaces."
      return 1
    fi
  done
  return 0
}

v_domain() {
  if [[ -z $1 ]]; then return 0; fi
  v_hostname "$1"
}

v_root_password() {
  if [[ -z $1 ]]; then return 0; fi
  if ((${#1} >= 8)) && [[ $1 != *[[:space:]]* ]]; then return 0; fi
  echo "Use 8 or more characters, with no spaces. Leave the field blank to make a random password."
  return 1
}

v_admin_password() {
  if [[ -z $1 ]]; then return 0; fi
  if ((${#1} >= 8)) && [[ $1 =~ ^[A-Za-z0-9._~!@%^*+=:,/-]+$ ]]; then return 0; fi
  echo "Use 8 or more characters: letters, digits and . _ ~ ! @ % ^ * + = : , / -"
  return 1
}

v_ssh_key_file() {
  if [[ -z $1 ]]; then return 0; fi
  if [[ -f $1 && -r $1 ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$1"; then return 0; fi
  echo "Enter the path of a readable SSH public key file, or leave the field blank."
  return 1
}

v_version() {
  if [[ $1 == latest || $1 =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then return 0; fi
  echo "Enter latest, or a release number such as 4.53."
  return 1
}

v_url() {
  if [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/%-]*)?$ ]]; then return 0; fi
  echo "Enter an http or https URL."
  return 1
}

v_master_list() {
  if [[ $1 =~ ^${RE_HOSTPORT}(,${RE_HOSTPORT})*$ ]]; then return 0; fi
  echo "Enter one or more host:port values, separated by commas. Example: 192.168.1.50:9333"
  return 1
}

v_opt_master_list() {
  if [[ -z $1 ]]; then return 0; fi
  v_master_list "$1"
}

v_advertise() {
  if [[ -z $1 ]]; then return 0; fi
  v_hostname "$1"
}

v_replication() {
  if [[ $1 =~ ^[0-9]{3}$ ]]; then return 0; fi
  echo "Enter three digits, for example 000 or 001."
  return 1
}

v_name_tag() {
  if [[ -z $1 || $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then return 0; fi
  echo "Use letters, digits and the characters . _ -"
  return 1
}

v_volume_size() {
  if [[ -z $1 ]]; then return 0; fi
  if [[ $SWFS_VARIANT == *large_disk ]]; then
    v_int 64 8000000 "$1"
    return
  fi
  if [[ $1 =~ ^[0-9]{1,10}$ ]] && ((10#$1 > 30000)); then
    echo "A volume larger than 30000 MB needs a large_disk build. Select the build first, or use a smaller value."
    return 1
  fi
  v_int 64 30000 "$1"
}

v_port() { v_int 1024 65535 "$1"; }
v_port_grpc() { v_int 1024 55535 "$1"; }

v_access_key() {
  if [[ -z $1 || $1 =~ ^[A-Za-z0-9]{16,128}$ ]]; then return 0; fi
  echo "Use 16 to 128 letters and digits, or leave the field blank to make a random key."
  return 1
}

v_secret_key() {
  if [[ -z $1 || $1 =~ ^[A-Za-z0-9/+=._-]{16,128}$ ]]; then return 0; fi
  echo "Use 16 to 128 characters: letters, digits and / + = . _ -"
  return 1
}

v_buckets() {
  local b
  local -a list=()
  if [[ -z $1 ]]; then return 0; fi
  IFS=, read -ra list <<<"$1"
  for b in "${list[@]}"; do
    if [[ ! $b =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
      echo "\"$b\" is not a correct bucket name. Use 3 to 63 lowercase letters, digits, dots and hyphens. Separate the names with commas."
      return 1
    fi
  done
  return 0
}

v_extra_args() {
  local w
  if [[ $1 == *[\'\"\\\`\$]* ]]; then
    echo "Do not use quotes, backslashes, back quotes or dollar signs."
    return 1
  fi
  for w in $1; do
    if [[ $w != -* ]]; then
      echo "Each argument must start with \"-\", for example -volume.minFreeSpace=10GiB."
      return 1
    fi
  done
  return 0
}

v_sources() {
  local s
  local -a list=()
  if [[ -z $1 ]]; then return 0; fi
  IFS=, read -ra list <<<"$1"
  for s in "${list[@]}"; do
    if [[ ! $s =~ ^${RE_IPV4}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
      echo "\"$s\" is not an IPv4 address or CIDR. Separate the values with commas."
      return 1
    fi
  done
  return 0
}

declare -A RULE=(
  [SWFS_ROLE]="v_choice all-in-one|master|volume|filer"
  [CT_ID]="v_ctid"
  [CT_HOSTNAME]="v_hostname"
  [CT_TAGS]="v_tags"
  [CT_OS]="v_choice debian-13|debian-12"
  [CT_TEMPLATE_STORAGE]="v_tmpl_storage"
  [CT_ROOTFS_STORAGE]="v_rootdir_storage"
  [CT_ROOTFS_SIZE]="v_int 2 65536"
  [CT_CORES]="v_int 1 512"
  [CT_MEMORY]="v_int 256 4194304"
  [CT_SWAP]="v_int 0 4194304"
  [CT_UNPRIVILEGED]="v_bool"
  [CT_ONBOOT]="v_bool"
  [CT_PASSWORD]="v_root_password"
  [CT_SSH_KEY_FILE]="v_ssh_key_file"
  [DATA_MODE]="v_choice volume|bind|rootfs"
  [DATA_STORAGE]="v_data_storage"
  [DATA_SIZE]="v_int 1 1048576"
  [DATA_HOST_PATH]="v_host_path"
  [DATA_MOUNT]="v_abs_path"
  [DATA_BACKUP]="v_bool"
  [NET_BRIDGE]="v_bridge"
  [NET_IP]="v_ipv4_cidr"
  [NET_GW]="v_opt_ipv4"
  [NET_VLAN]="v_vlan"
  [NET_IP6]="v_choice none|auto|dhcp"
  [NET_DNS]="v_dns"
  [NET_SEARCHDOMAIN]="v_domain"
  [SWFS_VERSION]="v_version"
  [SWFS_VARIANT]="v_choice standard|large_disk|full|full_large_disk"
  [SWFS_RELEASE_URL]="v_url"
  [SWFS_MASTER]="v_master_list"
  [SWFS_PEERS]="v_opt_master_list"
  [SWFS_ADVERTISE]="v_advertise"
  [SWFS_REPLICATION]="v_replication"
  [SWFS_DATACENTER]="v_name_tag"
  [SWFS_RACK]="v_name_tag"
  [SWFS_VOLUME_SIZE_MB]="v_volume_size"
  [SWFS_VOLUME_MAX]="v_int 0 100000"
  [SWFS_INDEX]="v_choice memory|leveldb|leveldbMedium|leveldbLarge"
  [SWFS_DISK_TYPE]="v_name_tag"
  [SWFS_FILER]="v_bool"
  [SWFS_S3]="v_bool"
  [SWFS_WEBDAV]="v_bool"
  [SWFS_ADMIN]="v_bool"
  [SWFS_METRICS]="v_bool"
  [SWFS_ICEBERG]="v_bool"
  [SWFS_TELEMETRY]="v_bool"
  [SWFS_S3_ACCESS_KEY]="v_access_key"
  [SWFS_S3_SECRET_KEY]="v_secret_key"
  [SWFS_BUCKETS]="v_buckets"
  [SWFS_ADMIN_USER]="v_name_tag"
  [SWFS_ADMIN_PASSWORD]="v_admin_password"
  [SWFS_EXTRA_ARGS]="v_extra_args"
  [PORT_MASTER]="v_port_grpc"
  [PORT_VOLUME]="v_port_grpc"
  [PORT_FILER]="v_port_grpc"
  [PORT_S3]="v_port_grpc"
  [PORT_WEBDAV]="v_port"
  [PORT_ADMIN]="v_port_grpc"
  [PORT_METRICS]="v_port"
  [PORT_ICEBERG]="v_port"
  [PORT_LANCE]="v_port"
  [FW_ENABLE]="v_bool"
  [FW_SOURCE]="v_sources"
  [FW_SSH]="v_bool"
)

# check_var VAR VALUE: print a message and return 1 if VALUE is not correct.
check_var() {
  local rule=${RULE[$1]:-}
  local -a r=()
  if [[ -z $rule ]]; then return 0; fi
  read -ra r <<<"$rule"
  "${r[@]}" "$2"
}

# Checks that compare more than one answer.
cross_check() {
  local out="" dup
  dup=$(used_ports | awk '{c[$1]++; n[$1] = n[$1] (n[$1] ? ", " : "") $2}
    END {for (p in c) if (c[p] > 1) printf "%s%s (%s)", (k++ ? "; " : ""), p, n[p]}')
  if [[ -n $dup ]]; then
    out+="Ports: more than one service uses the same port: ${dup}. A gRPC port is the HTTP port + 10000."$'\n'
  fi
  if [[ -z $out ]]; then return 0; fi
  printf '%s' "$out"
  return 1
}

# =============================================================================
# Wizard steps
# =============================================================================
# The wizard shows the steps in this order. A "#" entry is a group heading on
# the review screen. Expert steps are only on the review screen.

STEP_ORDER=(
  "#SeaweedFS role" role
  "#Container" ctid hostname os tmpl_storage tags
  "#Resources" rootfs_storage rootfs_size cores memory swap
  "#Data storage" data_mode data_storage data_size data_path data_backup data_mount
  "#Network" bridge ipv4 ipv4_addr ipv4_gw vlan ipv6 dns searchdomain
  "#Access" password ssh_key ct_options
  "#SeaweedFS" version variant master peers advertise replication datacenter rack
  "#Storage tuning" volume_size volume_max index disk_type
  "#Services" features s3_access s3_secret buckets admin_user admin_password extra_args
  "#Ports" port_master port_volume port_filer port_s3 port_webdav port_admin port_metrics port_iceberg port_lance
  "#Firewall" firewall fw_source fw_ssh
)

declare -A STEP_EXPERT=(
  [tags]=1 [data_mount]=1 [ipv6]=1 [dns]=1 [searchdomain]=1
  [peers]=1 [advertise]=1 [datacenter]=1 [rack]=1
  [volume_max]=1 [index]=1 [disk_type]=1
  [s3_access]=1 [s3_secret]=1 [admin_user]=1 [extra_args]=1
  [port_master]=1 [port_volume]=1 [port_filer]=1 [port_s3]=1 [port_webdav]=1
  [port_admin]=1 [port_metrics]=1 [port_iceberg]=1 [port_lance]=1
  [fw_ssh]=1
)

declare -A STEP_LABEL=(
  [role]="Role" [ctid]="Container ID" [hostname]="Host name" [os]="Operating system"
  [tmpl_storage]="Template storage" [tags]="Tags"
  [rootfs_storage]="Root disk storage" [rootfs_size]="Root disk size" [cores]="CPU cores"
  [memory]="Memory" [swap]="Swap"
  [data_mode]="Data location" [data_storage]="Data disk storage" [data_size]="Data disk size"
  [data_path]="Host directory" [data_backup]="Back up data disk" [data_mount]="Data path in container"
  [bridge]="Bridge" [ipv4]="IPv4 mode" [ipv4_addr]="IPv4 address" [ipv4_gw]="IPv4 gateway"
  [vlan]="VLAN tag" [ipv6]="IPv6" [dns]="DNS servers" [searchdomain]="DNS search domain"
  [password]="Root password" [ssh_key]="SSH public key" [ct_options]="Container options"
  [version]="SeaweedFS version" [variant]="Build" [master]="Master address"
  [peers]="Master peers" [advertise]="Advertised address" [replication]="Replication"
  [datacenter]="Data center" [rack]="Rack"
  [volume_size]="Volume size limit" [volume_max]="Maximum volumes" [index]="Volume index"
  [disk_type]="Disk type tag"
  [features]="Services" [s3_access]="S3 access key" [s3_secret]="S3 secret key"
  [buckets]="S3 buckets" [admin_user]="Admin user" [admin_password]="Admin password"
  [extra_args]="Extra weed arguments"
  [port_master]="Master port" [port_volume]="Volume port" [port_filer]="Filer port"
  [port_s3]="S3 port" [port_webdav]="WebDAV port" [port_admin]="Admin UI port"
  [port_metrics]="Metrics port" [port_iceberg]="Iceberg port" [port_lance]="Lance port"
  [firewall]="Proxmox firewall" [fw_source]="Allowed sources" [fw_ssh]="Allow SSH"
)

# The answers that each step sets. The recipe validates these answers.
declare -A STEP_VARS=(
  [role]="SWFS_ROLE" [ctid]="CT_ID" [hostname]="CT_HOSTNAME" [os]="CT_OS"
  [tmpl_storage]="CT_TEMPLATE_STORAGE" [tags]="CT_TAGS"
  [rootfs_storage]="CT_ROOTFS_STORAGE" [rootfs_size]="CT_ROOTFS_SIZE" [cores]="CT_CORES"
  [memory]="CT_MEMORY" [swap]="CT_SWAP"
  [data_mode]="DATA_MODE" [data_storage]="DATA_STORAGE" [data_size]="DATA_SIZE"
  [data_path]="DATA_HOST_PATH" [data_backup]="DATA_BACKUP" [data_mount]="DATA_MOUNT"
  [bridge]="NET_BRIDGE" [ipv4]="" [ipv4_addr]="NET_IP" [ipv4_gw]="NET_GW" [vlan]="NET_VLAN"
  [ipv6]="NET_IP6" [dns]="NET_DNS" [searchdomain]="NET_SEARCHDOMAIN"
  [password]="CT_PASSWORD" [ssh_key]="CT_SSH_KEY_FILE" [ct_options]="CT_UNPRIVILEGED CT_ONBOOT"
  [version]="SWFS_VERSION SWFS_RELEASE_URL" [variant]="SWFS_VARIANT" [master]="SWFS_MASTER"
  [peers]="SWFS_PEERS" [advertise]="SWFS_ADVERTISE" [replication]="SWFS_REPLICATION"
  [datacenter]="SWFS_DATACENTER" [rack]="SWFS_RACK"
  [volume_size]="SWFS_VOLUME_SIZE_MB" [volume_max]="SWFS_VOLUME_MAX" [index]="SWFS_INDEX"
  [disk_type]="SWFS_DISK_TYPE"
  [features]="SWFS_FILER SWFS_S3 SWFS_WEBDAV SWFS_ADMIN SWFS_METRICS SWFS_ICEBERG SWFS_TELEMETRY"
  [s3_access]="SWFS_S3_ACCESS_KEY" [s3_secret]="SWFS_S3_SECRET_KEY" [buckets]="SWFS_BUCKETS"
  [admin_user]="SWFS_ADMIN_USER" [admin_password]="SWFS_ADMIN_PASSWORD" [extra_args]="SWFS_EXTRA_ARGS"
  [port_master]="PORT_MASTER" [port_volume]="PORT_VOLUME" [port_filer]="PORT_FILER"
  [port_s3]="PORT_S3" [port_webdav]="PORT_WEBDAV" [port_admin]="PORT_ADMIN"
  [port_metrics]="PORT_METRICS" [port_iceberg]="PORT_ICEBERG" [port_lance]="PORT_LANCE"
  [firewall]="FW_ENABLE" [fw_source]="FW_SOURCE" [fw_ssh]="FW_SSH"
)

# On the review screen, a change to one of these steps also opens the steps
# that depend on it.
declare -A STEP_FOLLOW=(
  [role]="master"
  [data_mode]="data_storage data_size data_path data_backup"
  [ipv4]="ipv4_addr ipv4_gw"
  [features]="buckets admin_password"
  [firewall]="fw_source"
)

# step_applies ID [wizard|review|validate]: return 0 if the step is necessary.
step_applies() {
  local id=$1 ctx=${2:-wizard}
  if [[ $ctx == wizard && -n ${STEP_EXPERT[$id]:-} ]]; then return 1; fi
  case $id in
    tmpl_storage) [[ $ctx != wizard ]] || ((${#VZTMPL_STORAGES[@]} > 1)) ;;
    data_storage | data_size | data_backup) [[ $DATA_MODE == volume ]] ;;
    data_path) [[ $DATA_MODE == bind ]] ;;
    ipv4_addr | ipv4_gw) [[ $NET_IP_MODE == static ]] ;;
    master) role_in volume filer ;;
    peers | replication | volume_size) has_master ;;
    datacenter | rack) role_in all-in-one volume filer ;;
    volume_max | index | disk_type) has_volume ;;
    port_master) has_master ;;
    port_volume) has_volume ;;
    port_filer) has_filer ;;
    port_s3 | s3_access | s3_secret | buckets) has_s3 ;;
    port_webdav) has_webdav ;;
    port_admin | admin_user | admin_password) has_admin ;;
    port_metrics) has_metrics ;;
    port_iceberg | port_lance) has_iceberg ;;
    fw_source | fw_ssh) [[ $FW_ENABLE == 1 ]] ;;
    *) return 0 ;;
  esac
}

# The text that the review screen shows for a step.
step_value() {
  local id=$1 v
  case $id in
    role) echo "$SWFS_ROLE" ;;
    rootfs_size | data_size) v=${STEP_VARS[$id]} && echo "${!v} GiB" ;;
    memory | swap) v=${STEP_VARS[$id]} && echo "${!v} MiB" ;;
    tmpl_storage | rootfs_storage) v=${STEP_VARS[$id]} && echo "${!v:-(automatic)}" ;;
    data_storage) echo "${DATA_STORAGE:-${CT_ROOTFS_STORAGE} (same as root disk)}" ;;
    data_mode)
      case $DATA_MODE in
        volume) echo "new disk on a Proxmox storage" ;;
        bind) echo "host directory (bind mount)" ;;
        rootfs) echo "directory on the root disk" ;;
      esac
      ;;
    data_backup | fw_ssh)
      v=${STEP_VARS[$id]}
      if [[ ${!v} == 1 ]]; then echo yes; else echo no; fi
      ;;
    ipv4) echo "$NET_IP_MODE" ;;
    ipv4_addr | ipv4_gw | vlan | dns | searchdomain | ssh_key | tags | peers | datacenter | rack | disk_type | extra_args | buckets)
      v=${STEP_VARS[$id]} && echo "${!v:-(none)}"
      ;;
    password) if [[ -n $CT_PASSWORD ]]; then echo "(set)"; else echo "(random)"; fi ;;
    s3_access | s3_secret | admin_password)
      v=${STEP_VARS[$id]}
      if [[ -n ${!v} ]]; then echo "(set)"; else echo "(random)"; fi
      ;;
    ct_options)
      v=""
      if [[ $CT_UNPRIVILEGED == 1 ]]; then v="unprivileged"; else v="privileged"; fi
      if [[ $CT_ONBOOT == 1 ]]; then v+=", start at boot"; fi
      echo "$v"
      ;;
    version) echo "$SWFS_VERSION" ;;
    master) echo "${SWFS_MASTER:-(not set)}" ;;
    advertise)
      if [[ -n $SWFS_ADVERTISE ]]; then echo "$SWFS_ADVERTISE"
      elif [[ $NET_IP_MODE == static && -n $NET_IP ]]; then echo "${NET_IP%/*} (static IP)"
      else echo "(detect at start)"; fi
      ;;
    volume_size)
      if [[ -n $SWFS_VOLUME_SIZE_MB ]]; then echo "$SWFS_VOLUME_SIZE_MB MB"
      else echo "auto ($(auto_volume_size_mb) MB)"; fi
      ;;
    volume_max) if [[ $SWFS_VOLUME_MAX == 0 ]]; then echo "auto"; else echo "$SWFS_VOLUME_MAX"; fi ;;
    features) features_text ;;
    firewall) if [[ $FW_ENABLE == 1 ]]; then echo "on"; else echo "off"; fi ;;
    fw_source) echo "${FW_SOURCE:-(all addresses)}" ;;
    *) v=${STEP_VARS[$id]} && echo "${!v}" ;;
  esac
}

features_text() {
  local -a on=()
  if has_master; then on+=(master); fi
  if has_volume; then on+=(volume); fi
  if has_filer; then on+=(filer); fi
  if has_s3; then on+=(s3); fi
  if has_webdav; then on+=(webdav); fi
  if has_admin; then on+=(admin-ui); fi
  if has_metrics; then on+=(metrics); fi
  if has_iceberg; then on+=(iceberg); fi
  if has_telemetry_option && [[ $SWFS_TELEMETRY == 1 ]]; then on+=(telemetry); fi
  local IFS=,
  echo "${on[*]}"
}

validate_all() {
  local id var err out=""
  for id in "${STEP_ORDER[@]}"; do
    if [[ $id == \#* ]] || ! step_applies "$id" validate; then continue; fi
    for var in ${STEP_VARS[$id]}; do
      if ! err=$(check_var "$var" "${!var}"); then
        out+="${STEP_LABEL[$id]} (${var}): ${err}"$'\n'
      fi
    done
  done
  if [[ -z $out ]] && ! err=$(cross_check); then out+=$err; fi
  if [[ -z $out ]]; then return 0; fi
  printf '%s' "$out"
  return 1
}

# -----------------------------------------------------------------------------
# whiptail helpers. Each ask_* function returns 0 for Next, 1 for Back and
# 255 for Esc.
# -----------------------------------------------------------------------------
WT_W=76

wt() { whiptail --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

wt_size() {
  local cols rows
  cols=$(tput cols 2>/dev/null || echo 80)
  rows=$(tput lines 2>/dev/null || echo 24)
  WT_W=$((cols - 4 < 76 ? cols - 4 : 76))
  WT_ROWS=$rows
}

# text_rows TEXT: the number of lines that TEXT uses in a dialog box.
text_rows() {
  local line rows=0 width=$((WT_W - 4))
  while IFS= read -r line; do
    if ((${#line} == 0)); then rows=$((rows + 1)); else rows=$((rows + (${#line} + width - 1) / width)); fi
  done <<<"$1"
  echo "$rows"
}

msgbox() {
  wt --title "$1" --msgbox "$2" $(($(text_rows "$2") + 7)) "$WT_W" || true
}

# ask_input VAR TITLE TEXT [VALIDATOR...]
ask_input() {
  local var=$1 title=$2 text=$3 value err
  shift 3
  while :; do
    value=$(wt --title "$title" --ok-button Next --cancel-button Back \
      --inputbox -- "$text" $(($(text_rows "$text") + 8)) "$WT_W" "${!var}") || return $?
    value=$(trim "$value")
    if (($#)); then
      err=$("$@" "$value") || {
        msgbox "Check the value" "$err"
        continue
      }
    elif ! err=$(check_var "$var" "$value"); then
      msgbox "Check the value" "$err"
      continue
    fi
    printf -v "$var" '%s' "$value"
    return 0
  done
}

# ask_menu VAR TITLE TEXT TAG DESCRIPTION [TAG DESCRIPTION]...
ask_menu() {
  local var=$1 title=$2 text=$3 value n lh
  shift 3
  n=$(($# / 2))
  lh=$((n < 10 ? n : 10))
  value=$(wt --title "$title" --ok-button Next --cancel-button Back --default-item "${!var}" \
    --menu -- "$text" $(($(text_rows "$text") + lh + 7)) "$WT_W" "$lh" "$@") || return $?
  printf -v "$var" '%s' "$value"
  return 0
}

# ask_bool VAR TITLE TEXT YES-TEXT NO-TEXT
ask_bool() {
  local var=$1 title=$2 text=$3 value
  value=$(wt --title "$title" --ok-button Next --cancel-button Back --notags --default-item "${!var}" \
    --menu -- "$text" $(($(text_rows "$text") + 9)) "$WT_W" 2 1 "$4" 0 "$5") || return $?
  printf -v "$var" '%s' "$value"
  return 0
}

# ask_password VAR TITLE TEXT
ask_password() {
  local var=$1 title=$2 text=$3 p1 p2 err
  while :; do
    p1=$(wt --title "$title" --ok-button Next --cancel-button Back \
      --passwordbox -- "$text" $(($(text_rows "$text") + 8)) "$WT_W") || return $?
    if [[ -z $p1 ]]; then
      printf -v "$var" '%s' ""
      return 0
    fi
    if ! err=$(check_var "$var" "$p1"); then
      msgbox "Check the password" "$err"
      continue
    fi
    p2=$(wt --title "$title" --ok-button Next --cancel-button Back \
      --passwordbox "Enter the password again." 9 "$WT_W") || continue
    if [[ $p1 != "$p2" ]]; then
      msgbox "Check the password" "The two passwords are not the same. Try again."
      continue
    fi
    printf -v "$var" '%s' "$p1"
    return 0
  done
}

storage_menu_items() { # storage_menu_items LIST-NAME
  local -n _menu_list=$1
  local s
  for s in "${_menu_list[@]}"; do
    printf '%s\n%s\n' "$s" "${STORAGE_DESC[$s]:-storage}"
  done
}

# -----------------------------------------------------------------------------
# The steps
# -----------------------------------------------------------------------------
step_mode() {
  local text="This wizard makes a Proxmox VE LXC container that runs SeaweedFS.

Select how to set up the container. Both modes end on a review screen. On the review screen, you can change each setting before the recipe makes the container."
  local value
  value=$(wt --title "SeaweedFS LXC" --ok-button Next --cancel-button Quit --notags --default-item "$WIZARD_MODE" \
    --menu -- "$text" $(($(text_rows "$text") + 9)) "$WT_W" 2 \
    quick "Quick: use the recommended settings" \
    advanced "Advanced: go through the settings step by step") || return $?
  WIZARD_MODE=$value
}

step_role() {
  local old=$SWFS_ROLE
  ask_menu SWFS_ROLE "SeaweedFS role" "Select the job of this container.

Use all-in-one for a single container that holds all of SeaweedFS. To make a cluster, make one master container first. Then make volume and filer containers that connect to the master." \
    all-in-one "Master, volume server, filer and gateways" \
    master "Cluster master only (keeps the cluster map)" \
    volume "Volume server only (keeps file data)" \
    filer "Filer with S3 and WebDAV gateways" || return $?
  apply_role_defaults "$old"
}

# Change the defaults that depend on the role. Do not change an answer that
# came from an answers file or --set.
apply_role_defaults() {
  local old=$1
  if [[ $old == "$SWFS_ROLE" ]]; then return 0; fi
  if [[ -z ${EXPLICIT[CT_HOSTNAME]:-} && $CT_HOSTNAME =~ ^seaweedfs(-master|-volume|-filer)?$ ]]; then
    case $SWFS_ROLE in
      all-in-one) CT_HOSTNAME="seaweedfs" ;;
      *) CT_HOSTNAME="seaweedfs-$SWFS_ROLE" ;;
    esac
  fi
  if [[ -z ${EXPLICIT[DATA_SIZE]:-} ]]; then
    if role_in master filer && [[ $DATA_SIZE == 64 ]]; then DATA_SIZE=8; fi
    if role_in all-in-one volume && [[ $DATA_SIZE == 8 ]]; then DATA_SIZE=64; fi
  fi
  return 0
}

step_ctid() {
  ask_input CT_ID "Container ID" "Enter the ID of the new container.

The next free ID is ${NEXT_ID}."
}

step_hostname() {
  ask_input CT_HOSTNAME "Host name" "Enter the host name of the container."
}

step_os() {
  ask_menu CT_OS "Operating system" "Select the Debian release for the container. The recipe downloads the newest standard template for this release." \
    debian-13 "Debian 13 (trixie), recommended" \
    debian-12 "Debian 12 (bookworm)"
}

step_tmpl_storage() {
  local -a items=()
  mapfile -t items < <(storage_menu_items VZTMPL_STORAGES)
  ask_menu CT_TEMPLATE_STORAGE "Template storage" "Select the storage for the container template." "${items[@]}"
}

step_tags() {
  ask_input CT_TAGS "Tags" "Enter the Proxmox tags for the container. Separate the tags with semicolons."
}

step_rootfs_storage() {
  local -a items=()
  mapfile -t items < <(storage_menu_items ROOTDIR_STORAGES)
  ask_menu CT_ROOTFS_STORAGE "Root disk storage" "Select the storage for the root disk of the container." "${items[@]}"
}

step_rootfs_size() {
  ask_input CT_ROOTFS_SIZE "Root disk size" "Enter the size of the root disk in GiB.

Debian and SeaweedFS use approximately 2 GiB. If the data is on the root disk, add the space for the data."
}

step_cores() {
  ask_input CT_CORES "CPU cores" "Enter the number of CPU cores for the container."
}

step_memory() {
  ask_input CT_MEMORY "Memory" "Enter the memory (RAM) for the container in MiB.

In the memory index mode, the volume server keeps an index entry for each file in RAM. For millions of files, add memory or set the volume index to leveldb."
}

step_swap() {
  ask_input CT_SWAP "Swap" "Enter the swap size in MiB. Enter 0 for no swap."
}

step_data_mode() {
  ask_menu DATA_MODE "Data location" "Select where SeaweedFS keeps its data.

A new disk keeps the data separate from the operating system. A host directory lets you use an existing disk or ZFS dataset of the host." \
    volume "New disk on a Proxmox storage (recommended)" \
    bind "Directory on the Proxmox host (bind mount)" \
    rootfs "Directory on the root disk"
}

step_data_storage() {
  local -a items=()
  if [[ -z $DATA_STORAGE ]]; then DATA_STORAGE=$CT_ROOTFS_STORAGE; fi
  mapfile -t items < <(storage_menu_items ROOTDIR_STORAGES)
  ask_menu DATA_STORAGE "Data disk storage" "Select the storage for the SeaweedFS data disk." "${items[@]}"
}

step_data_size() {
  ask_input DATA_SIZE "Data disk size" "Enter the size of the SeaweedFS data disk in GiB."
}

step_data_path() {
  ask_input DATA_HOST_PATH "Host directory" "Enter the directory on the Proxmox host for the SeaweedFS data. Example: /tank/seaweedfs

If the directory does not exist, the recipe makes it. The recipe changes the owner of the directory to the seaweedfs user of the container.

Proxmox backups do not include a bind mount."
}

step_data_backup() {
  ask_bool DATA_BACKUP "Back up data disk" "Include the data disk in Proxmox backups (vzdump)?" \
    "Yes, include the data disk in backups" \
    "No, back up the root disk only"
}

step_data_mount() {
  ask_input DATA_MOUNT "Data path in container" "Enter the directory in the container for the SeaweedFS data."
}

step_bridge() {
  local -a items=()
  local b
  for b in "${BRIDGES[@]}"; do items+=("$b" "Linux bridge"); done
  if ((${#items[@]} == 0)); then
    ask_input NET_BRIDGE "Bridge" "Enter the name of the network bridge, for example vmbr0."
  else
    ask_menu NET_BRIDGE "Bridge" "Select the network bridge for the container." "${items[@]}"
  fi
}

step_ipv4() {
  ask_menu NET_IP_MODE "IPv4 mode" "Select how the container gets its IPv4 address.

A master needs an address that does not change. For a master, use a static address or a DHCP reservation." \
    dhcp "Get an address from a DHCP server" \
    static "Use a static address" || return $?
  if [[ $NET_IP_MODE == dhcp ]]; then
    NET_IP="dhcp"
  elif [[ $NET_IP == dhcp ]]; then
    NET_IP=""
  fi
  return 0
}

step_ipv4_addr() {
  ask_input NET_IP "IPv4 address" "Enter the IPv4 address of the container in CIDR format.

Example: 192.168.1.50/24"
}

step_ipv4_gw() {
  if [[ -z $NET_GW ]]; then NET_GW=$HOST_GW; fi
  ask_input NET_GW "IPv4 gateway" "Enter the IPv4 gateway. Leave the field blank for no gateway.

The gateway of this host is ${HOST_GW:-not known}."
}

step_vlan() {
  ask_input NET_VLAN "VLAN tag" "Enter the VLAN tag for the network interface. Leave the field blank for no VLAN."
}

step_ipv6() {
  ask_menu NET_IP6 "IPv6" "Select how the container gets its IPv6 address." \
    none "No IPv6 setting" \
    auto "SLAAC (router advertisement)" \
    dhcp "DHCPv6"
}

step_dns() {
  ask_input NET_DNS "DNS servers" "Enter the DNS server addresses. Separate the addresses with spaces. Leave the field blank to use the settings of the host."
}

step_searchdomain() {
  ask_input NET_SEARCHDOMAIN "DNS search domain" "Enter the DNS search domain. Leave the field blank to use the settings of the host."
}

step_password() {
  ask_password CT_PASSWORD "Root password" "Enter the root password of the container. Leave the field blank to make a random password.

The recipe shows the password at the end."
}

step_ssh_key() {
  local hint=""
  if [[ -r /root/.ssh/authorized_keys ]]; then hint="

To copy the keys of the host root user, enter /root/.ssh/authorized_keys"; fi
  ask_input CT_SSH_KEY_FILE "SSH public key" "Enter the path of an SSH public key file on this host. The recipe adds the keys to the root user of the container. Leave the field blank for no key.${hint}"
}

step_ct_options() {
  local value text="Press SPACE to select or clear an item. Press ENTER to continue.

An unprivileged container is safer. Use a privileged container only if you know that you need one."
  value=$(wt --title "Container options" --ok-button Next --cancel-button Back --separate-output \
    --checklist -- "$text" $(($(text_rows "$text") + 9)) "$WT_W" 2 \
    unprivileged "Unprivileged container (recommended)" "$([[ $CT_UNPRIVILEGED == 1 ]] && echo ON || echo OFF)" \
    onboot "Start the container when the host starts" "$([[ $CT_ONBOOT == 1 ]] && echo ON || echo OFF)") || return $?
  CT_UNPRIVILEGED=$(bool grep -qx unprivileged <<<"$value")
  CT_ONBOOT=$(bool grep -qx onboot <<<"$value")
}

step_version() {
  ask_input SWFS_VERSION "SeaweedFS version" "Enter the SeaweedFS release to install, for example 4.53. Enter latest to install the newest release.

To update later, enter seaweedfs-update in the container."
}

step_variant() {
  ask_menu SWFS_VARIANT "Build" "Select the SeaweedFS build.

The large_disk builds let a single volume grow to more than 30000 MB. The full builds include more filer metadata stores." \
    standard "Default build, volumes up to 30000 MB" \
    large_disk "Volumes up to 8000 GB" \
    full "More filer stores, volumes up to 30000 MB" \
    full_large_disk "More filer stores, volumes up to 8000 GB"
}

step_master() {
  ask_input SWFS_MASTER "Master address" "Enter the address of the SeaweedFS master as host:port. For more than one master, separate the addresses with commas.

Example: 192.168.1.50:9333"
}

step_peers() {
  ask_input SWFS_PEERS "Master peers" "For a highly available master, enter the addresses of all the masters as host:port, separated by commas. Use 3 masters. Leave the field blank for a single master."
}

step_advertise() {
  ask_input SWFS_ADVERTISE "Advertised address" "Enter the address that other servers and clients use to connect to this container (the weed -ip option).

Leave the field blank to use the static IPv4 address. With DHCP, SeaweedFS finds the address when it starts."
}

step_replication() {
  local -a items=(
    000 "One copy of the data"
    001 "Two copies on different servers in the same rack"
    010 "Two copies in different racks"
    100 "Two copies in different data centers"
    002 "Three copies on different servers in the same rack"
  )
  if ! in_list "$SWFS_REPLICATION" 000 001 010 100 002; then items+=("$SWFS_REPLICATION" "Value from the answers"); fi
  ask_menu SWFS_REPLICATION "Replication" "Select the default replication of the cluster.

Each copy must be on a different volume server. If there is only one volume server, use 000." "${items[@]}"
}

step_datacenter() {
  ask_input SWFS_DATACENTER "Data center" "Enter the data center name of this server. SeaweedFS uses the name for replication. Leave the field blank for no name."
}

step_rack() {
  ask_input SWFS_RACK "Rack" "Enter the rack name of this server. SeaweedFS uses the name for replication. Leave the field blank for no name."
}

step_volume_size() {
  ask_input SWFS_VOLUME_SIZE_MB "Volume size limit" "Enter the size limit of one SeaweedFS volume in MB. Leave the field blank to calculate the limit from the data disk size (now $(auto_volume_size_mb) MB).

SeaweedFS keeps files in volumes. Each S3 bucket uses its own volumes. On a small disk, use small volumes."
}

step_volume_max() {
  ask_input SWFS_VOLUME_MAX "Maximum volumes" "Enter the maximum number of volumes on this server. Enter 0 to calculate the number from the free disk space."
}

step_index() {
  ask_menu SWFS_INDEX "Volume index" "Select the index type of the volume server. The leveldb types use less RAM, but they are slower." \
    memory "Index in RAM (fastest)" \
    leveldb "Index in LevelDB (less RAM)" \
    leveldbMedium "LevelDB with a medium cache" \
    leveldbLarge "LevelDB with a large cache"
}

step_disk_type() {
  ask_input SWFS_DISK_TYPE "Disk type tag" "Enter the disk type of the data disk: hdd, ssd or a custom tag. SeaweedFS can put collections on a disk type. Leave the field blank for the default (hdd)."
}

step_features() {
  local value text
  local -a items=()
  on() { if [[ ${!1} == 1 ]]; then echo ON; else echo OFF; fi; }
  if role_in all-in-one; then items+=(filer "Filer: directories and the filer web UI" "$(on SWFS_FILER)"); fi
  if role_in all-in-one filer; then
    items+=(s3 "S3 gateway, with an access key" "$(on SWFS_S3)")
    items+=(webdav "WebDAV gateway (no password)" "$(on SWFS_WEBDAV)")
  fi
  if role_in all-in-one master filer; then items+=(admin "Admin web UI, with a password" "$(on SWFS_ADMIN)"); fi
  items+=(metrics "Prometheus metrics endpoint" "$(on SWFS_METRICS)")
  if role_in all-in-one filer; then items+=(iceberg "Iceberg and Lance catalogs on the S3 gateway" "$(on SWFS_ICEBERG)"); fi
  if role_in all-in-one master; then items+=(telemetry "Send anonymous statistics to SeaweedFS" "$(on SWFS_TELEMETRY)"); fi
  unset -f on
  text="Select the services to run in this container. Press SPACE to select or clear an item. Press ENTER to continue.

The S3 and WebDAV gateways need the filer. WebDAV has no password protection. Use WebDAV only on a trusted network."
  value=$(wt --title "Services" --ok-button Next --cancel-button Back --separate-output \
    --checklist -- "$text" $(($(text_rows "$text") + ${#items[@]} / 3 + 7)) "$WT_W" $((${#items[@]} / 3)) \
    "${items[@]}") || return $?
  local tag var
  for tag in filer s3 webdav admin metrics iceberg telemetry; do
    var="SWFS_${tag^^}"
    if in_list "$tag" "${items[@]}"; then printf -v "$var" '%s' "$(bool grep -qx "$tag" <<<"$value")"; fi
  done
  if role_in all-in-one && [[ $SWFS_S3 == 1 || $SWFS_WEBDAV == 1 ]]; then SWFS_FILER=1; fi
  return 0
}

step_s3_access() {
  ask_input SWFS_S3_ACCESS_KEY "S3 access key" "Enter the S3 access key. Leave the field blank to make a random key."
}

step_s3_secret() {
  ask_password SWFS_S3_SECRET_KEY "S3 secret key" "Enter the S3 secret key. Leave the field blank to make a random key."
}

step_buckets() {
  ask_input SWFS_BUCKETS "S3 buckets" "Enter the names of the S3 buckets to make. Separate the names with commas. Leave the field blank for no buckets.

Example: backups,media"
}

step_admin_user() {
  ask_input SWFS_ADMIN_USER "Admin user" "Enter the user name for the admin web UI."
}

step_admin_password() {
  ask_password SWFS_ADMIN_PASSWORD "Admin password" "Enter the password for the admin web UI. Leave the field blank to make a random password.

The recipe shows the password at the end."
}

step_extra_args() {
  ask_input SWFS_EXTRA_ARGS "Extra weed arguments" "Enter more arguments for the main weed command. Separate the arguments with spaces.

Example: -volume.minFreeSpace=10GiB"
}

step_port() { # step_port VAR NAME
  ask_input "$1" "$2 port" "Enter the TCP port of the $2. SeaweedFS also uses this port + 10000 for gRPC on the master, volume, filer, S3 and admin services."
}
step_port_master() { step_port PORT_MASTER "master"; }
step_port_volume() { step_port PORT_VOLUME "volume server"; }
step_port_filer() { step_port PORT_FILER "filer"; }
step_port_s3() { step_port PORT_S3 "S3 gateway"; }
step_port_webdav() { step_port PORT_WEBDAV "WebDAV gateway"; }
step_port_admin() { step_port PORT_ADMIN "admin web UI"; }
step_port_metrics() { step_port PORT_METRICS "metrics endpoint"; }
step_port_iceberg() { step_port PORT_ICEBERG "Iceberg catalog"; }
step_port_lance() { step_port PORT_LANCE "Lance namespace"; }

step_firewall() {
  ask_bool FW_ENABLE "Proxmox firewall" "Turn on the Proxmox firewall for this container?

The firewall lets in only the ports of the services that you selected. The master, filer and volume UIs have no password. Thus a firewall is a good protection.

The firewall of a container operates only if the firewall is on at the datacenter level." \
    "Yes, turn on the firewall for the container" \
    "No, do not change the firewall"
}

step_fw_source() {
  local net=""
  if ((!FW_SOURCE_SUGGESTED)) && [[ -z $FW_SOURCE ]]; then
    if [[ $NET_IP_MODE == static && -n $NET_IP ]]; then
      net=$(cidr_network "$NET_IP")
    else
      net=$(ip -o -4 addr show dev "$NET_BRIDGE" 2>/dev/null | awk '{print $4; exit}' || true)
      if [[ -n $net ]]; then net=$(cidr_network "$net"); fi
    fi
    FW_SOURCE=$net
    FW_SOURCE_SUGGESTED=1
  fi
  ask_input FW_SOURCE "Allowed sources" "Enter the addresses that can connect to SeaweedFS. Use IPv4 addresses or CIDR values, separated by commas. Leave the field blank to accept all addresses.

Example: 192.168.1.0/24"
}

step_fw_ssh() {
  ask_bool FW_SSH "Allow SSH" "Let in SSH (port 22) from the allowed sources?" \
    "Yes, let in SSH" \
    "No, block SSH"
}

# -----------------------------------------------------------------------------
# Wizard flow
# -----------------------------------------------------------------------------
confirm_quit() {
  if wt --title "Stop" --yes-button "Stop" --no-button "Continue" --defaultno \
    --yesno "Stop the wizard? The recipe does not make a container." 8 "$WT_W"; then
    clear >&2
    echo "Stopped. The recipe did not change the host."
    exit 0
  fi
  return 0
}

run_linear() {
  local -a ids=()
  local id i=0 dir=1 rc
  for id in "${STEP_ORDER[@]}"; do
    if [[ $id != \#* ]]; then ids+=("$id"); fi
  done
  while ((i < ${#ids[@]})); do
    if ((i < 0)); then
      return 1 # Back from the first step
    fi
    id=${ids[i]}
    if ! step_applies "$id" wizard; then
      i=$((i + dir))
      continue
    fi
    rc=0
    "step_$id" || rc=$?
    case $rc in
      0) dir=1 && i=$((i + 1)) ;;
      1) dir=-1 && i=$((i - 1)) ;;
      *) confirm_quit ;;
    esac
  done
  return 0
}

review_items() {
  local id label value width
  width=$((WT_W - 32))
  REVIEW_ITEMS=(
    "@create" ">> Make the container with these settings"
    "@save" ">> Save the answers to a file"
    "@quit" ">> Stop, and do not make a container"
  )
  for id in "${STEP_ORDER[@]}"; do
    if [[ $id == \#* ]]; then
      REVIEW_ITEMS+=("$id" "=== ${id#\#} ===")
      continue
    fi
    if ! step_applies "$id" review; then continue; fi
    label=${STEP_LABEL[$id]}
    value=$(step_value "$id")
    if ((${#value} > width)); then value="${value:0:width-3}..."; fi
    REVIEW_ITEMS+=("$id" "$(printf '   %-24s %s' "$label" "$value")")
  done
}

run_review() {
  local choice errs file follow f lh h
  while :; do
    review_items
    h=$((WT_ROWS - 2 < 40 ? WT_ROWS - 2 : 40))
    lh=$((h - 9))
    choice=$(wt --title "Review and change the settings" --ok-button Select --cancel-button Back --notags \
      --default-item "${choice:-@create}" \
      --menu -- "Select a setting to change it. Select the first item to make the container." \
      "$h" "$WT_W" "$lh" "${REVIEW_ITEMS[@]}") || return 1
    case $choice in
      @create)
        if ! errs=$(validate_all); then
          msgbox "Correct these settings" "$errs"
          continue
        fi
        if wt --title "Make the container" --yes-button "Make" --no-button "Back" \
          --yesno "Make container ${CT_ID} (${CT_HOSTNAME}) with the role ${SWFS_ROLE} now?" 8 "$WT_W"; then
          return 0
        fi
        ;;
      @save)
        file="/root/seaweedfs-${CT_HOSTNAME}.answers"
        if file=$(wt --title "Save the answers" --ok-button Save --cancel-button Back \
          --inputbox "Enter the path of the answers file. The recipe does not save the secrets." 9 "$WT_W" "$file"); then
          if write_answers "$file" template 2>/dev/null; then
            msgbox "Saved" "The recipe wrote the answers to ${file}.

To use the file, enter:
./create_instance.sh --config ${file}"
          else
            msgbox "Error" "The recipe cannot write ${file}."
          fi
        fi
        ;;
      @quit) confirm_quit ;;
      \#*) ;;
      *)
        "step_$choice" || continue
        follow=${STEP_FOLLOW[$choice]:-}
        for f in $follow; do
          if step_applies "$f" review; then "step_$f" || true; fi
        done
        ;;
    esac
  done
}

run_wizard() {
  local rc
  wt_size
  while :; do
    rc=0
    step_mode || rc=$?
    if ((rc != 0)); then
      confirm_quit
      continue
    fi
    if [[ $WIZARD_MODE == advanced ]]; then
      run_linear || continue
    fi
    run_review && break
  done
  clear >&2
}

# =============================================================================
# Answers files
# =============================================================================
set_answer() {
  if ! in_list "$1" "${ANSWER_KEYS[@]}"; then return 1; fi
  printf -v "$1" '%s' "$2"
  EXPLICIT[$1]=1
}

unquote() {
  local v
  v=$(trim "$1")
  if [[ $v == \"* ]]; then
    v=${v#\"}
    v=${v%%\"*}
  elif [[ $v == \'* ]]; then
    v=${v#\'}
    v=${v%%\'*}
  else
    v=${v%%[[:space:]]#*}
    v=$(trim "$v")
  fi
  printf '%s' "$v"
}

load_answers() {
  local file=$1 line n=0
  [[ -r $file ]] || die "Cannot read the answers file $file."
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(#|$) ]]; then continue; fi
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      set_answer "${BASH_REMATCH[2]}" "$(unquote "${BASH_REMATCH[3]}")" ||
        die "$file line $n: ${BASH_REMATCH[2]} is not a known answer."
    else
      die "$file line $n: use the format KEY=\"value\"."
    fi
  done <"$file"
}

apply_sets() {
  local s
  for s in "${OPT_SETS[@]}"; do
    [[ $s == *=* ]] || die "--set needs KEY=VALUE, not \"$s\"."
    set_answer "${s%%=*}" "${s#*=}" || die "--set: ${s%%=*} is not a known answer."
  done
}

# write_answers FILE template|record [NAME-IN-HINT]
write_answers() {
  local file=$1 mode=$2 key value base
  base=${3:-$(basename "$file")}
  {
    printf '# sige-seaweedfs %s answers file. Made on %s.\n' "$RECIPE_VERSION" "$(date '+%Y-%m-%d %H:%M')"
    if [[ $mode == record ]]; then
      printf '# These are the answers that made container %s.\n' "$CT_ID"
      printf '# To make a similar container, copy this file to the Proxmox host, set CT_ID=""\n'
      printf '# and change the host name and the static IP address (if any).\n'
    fi
    printf '# To use this file, enter: ./create_instance.sh --config %s\n' "$base"
    printf '# The recipe does not save secrets. A blank secret gets a random value.\n'
    printf '# Refer to answers.example in %s for a description of each answer.\n\n' "$RECIPE_URL"
    for key in "${ANSWER_KEYS[@]}"; do
      value=${!key}
      if is_secret "$key"; then value=""; fi
      if [[ $mode == template && $key == CT_ID ]]; then value=""; fi
      printf '%s="%s"\n' "$key" "$value"
    done
  } >"$file"
  chmod 0600 "$file" 2>/dev/null || true
}

answers_text() {
  local tmp
  tmp=$(mktemp)
  write_answers "$tmp" record recipe.answers
  cat "$tmp"
  rm -f "$tmp"
}

# =============================================================================
# Host checks
# =============================================================================
preflight() {
  local t
  if ((!OPT_DRY_RUN)) && ((EUID != 0)); then die "Run this script as root on the Proxmox VE host."; fi
  for t in pct pvesh pveam pvesm; do
    command -v "$t" >/dev/null 2>&1 || die "The command $t is missing. Run this script on a Proxmox VE host."
  done
  if ((!OPT_UNATTENDED)); then
    command -v whiptail >/dev/null 2>&1 || die "whiptail is missing. Install it (apt install whiptail) or use --unattended."
    [[ -t 0 && -t 2 ]] || die "The wizard needs a terminal. Use --unattended with --config FILE."
  fi
}

detect_host() {
  local name type status avail
  NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
  NEXT_ID=${NEXT_ID//[^0-9]/}
  HOST_ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  HOST_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)
  ROOTDIR_STORAGES=()
  while read -r name type status _ _ avail _; do
    if [[ $status != active ]]; then continue; fi
    [[ $avail =~ ^[0-9]+$ ]] || avail=0
    ROOTDIR_STORAGES+=("$name")
    STORAGE_DESC[$name]="$type, $((avail / 1048576)) GiB free"
  done < <(pvesm status -content rootdir 2>/dev/null | tail -n +2 || true)
  VZTMPL_STORAGES=()
  while read -r name type status _ _ avail _; do
    if [[ $status != active ]]; then continue; fi
    [[ $avail =~ ^[0-9]+$ ]] || avail=0
    VZTMPL_STORAGES+=("$name")
    STORAGE_DESC[$name]="$type, $((avail / 1048576)) GiB free"
  done < <(pvesm status -content vztmpl 2>/dev/null | tail -n +2 || true)
  mapfile -t BRIDGES < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | sort || true)
  ((${#ROOTDIR_STORAGES[@]} > 0)) || die "No active storage can hold container disks."
  ((${#VZTMPL_STORAGES[@]} > 0)) || die "No active storage can hold container templates."
}

pick_from() { # pick_from LIST-NAME PREFERRED...
  local -n _pick_list=$1
  local p
  shift
  for p in "$@"; do
    if in_list "$p" "${_pick_list[@]}"; then
      echo "$p"
      return 0
    fi
  done
  echo "${_pick_list[0]}"
}

fill_defaults() {
  apply_role_defaults all-in-one
  if [[ -z $CT_ID ]]; then CT_ID=$NEXT_ID; fi
  if [[ -z $CT_ROOTFS_STORAGE ]]; then CT_ROOTFS_STORAGE=$(pick_from ROOTDIR_STORAGES local-lvm local-zfs); fi
  if [[ -z $CT_TEMPLATE_STORAGE ]]; then CT_TEMPLATE_STORAGE=$(pick_from VZTMPL_STORAGES local); fi
  if ((${#BRIDGES[@]} > 0)) && ! in_list "$NET_BRIDGE" "${BRIDGES[@]}"; then
    NET_BRIDGE=$(pick_from BRIDGES vmbr0)
  fi
  if [[ $NET_IP == dhcp ]]; then NET_IP_MODE=dhcp; else NET_IP_MODE=static; fi
  if [[ $NET_IP_MODE == static && -z $NET_GW ]]; then NET_GW=$HOST_GW; fi
  return 0
}

# =============================================================================
# Make the container
# =============================================================================
derive() {
  EFF_MASTER=$(bool has_master)
  EFF_VOLUME=$(bool has_volume)
  EFF_FILER=$(bool has_filer)
  EFF_S3=$(bool has_s3)
  EFF_WEBDAV=$(bool has_webdav)
  EFF_ADMIN=$(bool has_admin)
  EFF_METRICS=$(bool has_metrics)
  EFF_ICEBERG=$(bool has_iceberg)

  if [[ -z $CT_PASSWORD ]]; then CT_PASSWORD=$(gen_secret 20); fi
  if ((EFF_S3)); then
    if [[ -z $SWFS_S3_ACCESS_KEY ]]; then SWFS_S3_ACCESS_KEY=$(gen_secret 20 'A-Z0-9'); fi
    if [[ -z $SWFS_S3_SECRET_KEY ]]; then SWFS_S3_SECRET_KEY=$(gen_secret 40); fi
  fi
  if ((EFF_ADMIN)) && [[ -z $SWFS_ADMIN_PASSWORD ]]; then SWFS_ADMIN_PASSWORD=$(gen_secret 20); fi
  if ((EFF_MASTER)) && [[ -z $SWFS_VOLUME_SIZE_MB ]]; then SWFS_VOLUME_SIZE_MB=$(auto_volume_size_mb); fi
  if [[ $DATA_MODE == volume && -z $DATA_STORAGE ]]; then DATA_STORAGE=$CT_ROOTFS_STORAGE; fi

  SWFS_IP=$SWFS_ADVERTISE
  if [[ -z $SWFS_IP && $NET_IP_MODE == static ]]; then SWFS_IP=${NET_IP%/*}; fi
  if ((EFF_MASTER)); then ADMIN_MASTER="127.0.0.1:${PORT_MASTER}"; else ADMIN_MASTER=$SWFS_MASTER; fi
  RECIPE_ANSWERS=$(answers_text)
  WAIT_SECONDS=90
}

find_template() {
  local ver=${CT_OS#debian-} re name="" available local_list
  re="^debian-${ver}-standard_[0-9.]+-[0-9]+_${HOST_ARCH}\.tar\.(zst|xz|gz)$"
  msg "Looking for the newest Debian ${ver} template"
  run pveam update >/dev/null || warn "Cannot update the template list. The recipe uses the cached list."
  available=$(pveam available --section system 2>/dev/null | awk '{print $2}' || true)
  name=$(grep -E "$re" <<<"$available" | sort -V | tail -n 1 || true)
  local_list=$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null | awk 'NR > 1 {print $1}' || true)
  if [[ -z $name ]]; then
    name=$(awk -F/ '{print $NF}' <<<"$local_list" | grep -E "$re" | sort -V | tail -n 1 || true)
  fi
  [[ -n $name ]] || die "No Debian ${ver} template is available for ${HOST_ARCH}."
  TEMPLATE_VOLID="${CT_TEMPLATE_STORAGE}:vztmpl/${name}"
  if grep -qxF "$TEMPLATE_VOLID" <<<"$local_list"; then
    msg "The template ${name} is on ${CT_TEMPLATE_STORAGE}"
  else
    msg "Downloading the template ${name}"
    run pveam download "$CT_TEMPLATE_STORAGE" "$name"
  fi
}

net0_value() {
  local v="name=eth0,bridge=${NET_BRIDGE},ip=${NET_IP}"
  if [[ $NET_IP_MODE == static && -n $NET_GW ]]; then v+=",gw=${NET_GW}"; fi
  if [[ $NET_IP6 != none ]]; then v+=",ip6=${NET_IP6}"; fi
  if [[ -n $NET_VLAN ]]; then v+=",tag=${NET_VLAN}"; fi
  if [[ $FW_ENABLE == 1 ]]; then v+=",firewall=1"; fi
  echo "$v"
}

pct_create_args() {
  PCT_ARGS=(
    "$TEMPLATE_VOLID"
    --hostname "$CT_HOSTNAME"
    --cores "$CT_CORES"
    --memory "$CT_MEMORY"
    --swap "$CT_SWAP"
    --rootfs "${CT_ROOTFS_STORAGE}:${CT_ROOTFS_SIZE}"
    --net0 "$(net0_value)"
    --unprivileged "$CT_UNPRIVILEGED"
    --onboot "$CT_ONBOOT"
    --timezone host
    --description "SeaweedFS (${SWFS_ROLE}). The sige-seaweedfs recipe is installing this container."
  )
  if [[ -n $CT_TAGS ]]; then PCT_ARGS+=(--tags "$CT_TAGS"); fi
  if [[ $CT_UNPRIVILEGED == 1 ]]; then PCT_ARGS+=(--features nesting=1); fi
  if [[ -n $NET_DNS ]]; then PCT_ARGS+=(--nameserver "$NET_DNS"); fi
  if [[ -n $NET_SEARCHDOMAIN ]]; then PCT_ARGS+=(--searchdomain "$NET_SEARCHDOMAIN"); fi
  if [[ -n $CT_SSH_KEY_FILE ]]; then PCT_ARGS+=(--ssh-public-keys "$CT_SSH_KEY_FILE"); fi
  case $DATA_MODE in
    volume) PCT_ARGS+=(--mp0 "${DATA_STORAGE}:${DATA_SIZE},mp=${DATA_MOUNT},backup=${DATA_BACKUP}") ;;
    bind) PCT_ARGS+=(--mp0 "${DATA_HOST_PATH},mp=${DATA_MOUNT}") ;;
  esac
  return 0
}

# fw_rule SOURCE-OPTION NAME PORT...
fw_rule() {
  local src=$1 name=$2
  shift 2
  local IFS=,
  printf 'IN ACCEPT%s -p tcp -dport %s -log nolog # SeaweedFS %s\n' "$src" "$*" "$name"
}

# The gRPC ports (HTTP port + 10000) of the master, volume server and filer
# are open, because the other servers of a cluster use them. The admin gRPC
# port is open for "weed worker" processes.
firewall_text() {
  local src=""
  if [[ -n $FW_SOURCE ]]; then src=" -source ${FW_SOURCE}"; fi
  printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n'
  if [[ $NET_IP_MODE == dhcp ]]; then printf 'dhcp: 1\n'; fi
  if [[ $NET_IP6 != none ]]; then printf 'ndp: 1\n'; fi
  printf '\n[RULES]\n'
  if [[ $FW_SSH == 1 ]]; then printf 'IN SSH(ACCEPT)%s -log nolog # SSH\n' "$src"; fi
  printf 'IN Ping(ACCEPT)%s -log nolog # Ping\n' "$src"
  if has_master; then fw_rule "$src" master "$PORT_MASTER" "$((PORT_MASTER + 10000))"; fi
  if has_volume; then fw_rule "$src" volume "$PORT_VOLUME" "$((PORT_VOLUME + 10000))"; fi
  if has_filer; then fw_rule "$src" filer "$PORT_FILER" "$((PORT_FILER + 10000))"; fi
  if has_s3; then fw_rule "$src" s3 "$PORT_S3"; fi
  if has_webdav; then fw_rule "$src" webdav "$PORT_WEBDAV"; fi
  if has_admin; then fw_rule "$src" admin "$PORT_ADMIN" "$((PORT_ADMIN + 10000))"; fi
  if has_metrics; then fw_rule "$src" metrics "$PORT_METRICS"; fi
  if has_iceberg; then fw_rule "$src" iceberg "$PORT_ICEBERG" "$PORT_LANCE"; fi
  return 0
}

write_firewall() {
  local file="/etc/pve/firewall/${CT_ID}.fw"
  msg "Writing the firewall rules to ${file}"
  if ((OPT_DRY_RUN)); then
    firewall_text | sed 's/^/    /'
  else
    firewall_text >"$file"
  fi
  if ! grep -Eqs '^[[:space:]]*enable:[[:space:]]*1' /etc/pve/firewall/cluster.fw; then
    warn "The datacenter firewall is off. The container rules operate only after you turn on the firewall at Datacenter > Firewall > Options."
  fi
}

wait_for_network() {
  local n=0 host
  if ((OPT_DRY_RUN)); then return 0; fi
  host=${SWFS_RELEASE_URL#*://}
  host=${host%%[/:]*}
  msg "Waiting for the container network"
  until pct exec "$CT_ID" -- getent hosts "$host" >/dev/null 2>&1; do
    n=$((n + 1))
    if ((n >= 45)); then
      die "The container cannot resolve ${host} after 90 seconds. Check the bridge, VLAN, IP and DNS settings."
    fi
    sleep 2
  done
}

# The in-container installer gets these values.
PAYLOAD_VARS=(
  RECIPE_VERSION RECIPE_URL CT_ID CT_HOSTNAME DATA_MOUNT
  SWFS_ROLE SWFS_VERSION SWFS_VARIANT SWFS_RELEASE_URL SWFS_IP SWFS_MASTER SWFS_PEERS
  SWFS_REPLICATION SWFS_DATACENTER SWFS_RACK SWFS_VOLUME_SIZE_MB SWFS_VOLUME_MAX
  SWFS_INDEX SWFS_DISK_TYPE SWFS_TELEMETRY SWFS_S3_ACCESS_KEY SWFS_S3_SECRET_KEY
  SWFS_BUCKETS SWFS_ADMIN_USER SWFS_ADMIN_PASSWORD SWFS_EXTRA_ARGS
  PORT_MASTER PORT_VOLUME PORT_FILER PORT_S3 PORT_WEBDAV PORT_ADMIN
  PORT_METRICS PORT_ICEBERG PORT_LANCE
  EFF_MASTER EFF_VOLUME EFF_FILER EFF_S3 EFF_WEBDAV EFF_ADMIN EFF_METRICS EFF_ICEBERG
  ADMIN_MASTER RECIPE_ANSWERS WAIT_SECONDS
)

build_payload() {
  local -a fns=()
  mapfile -t fns < <(compgen -A function ct_)
  {
    printf '#!/usr/bin/env bash\n'
    printf '# sige-seaweedfs %s in-container installer. The host script made this file.\n' "$RECIPE_VERSION"
    printf 'set -Eeuo pipefail\n'
    declare -p "${PAYLOAD_VARS[@]}"
    declare -f "${fns[@]}"
    printf 'ct_main "$@"\n'
  } >"$1"
}

notes_text() {
  local ip=${CT_IP:-<container-ip>}
  printf '## SeaweedFS (%s)\n\n' "$SWFS_ROLE"
  printf 'Made with [sige-seaweedfs](%s) %s.\n\n' "$RECIPE_URL" "$RECIPE_VERSION"
  endpoints_text "$ip" | sed 's/^/- /'
  # shellcheck disable=SC2016 # The back quotes are Markdown.
  printf '\nSettings: `/etc/seaweedfs/*.args`. Credentials: `/root/seaweedfs-credentials.txt`.\n'
}

endpoints_text() {
  local ip=$1
  if ((EFF_MASTER)); then echo "Master UI: http://${ip}:${PORT_MASTER}"; fi
  if ((EFF_VOLUME)); then echo "Volume server: http://${ip}:${PORT_VOLUME}/status"; fi
  if ((EFF_FILER)); then echo "Filer UI: http://${ip}:${PORT_FILER}"; fi
  if ((EFF_S3)); then echo "S3 endpoint: http://${ip}:${PORT_S3}"; fi
  if ((EFF_WEBDAV)); then echo "WebDAV: http://${ip}:${PORT_WEBDAV}"; fi
  if ((EFF_ADMIN)); then echo "Admin UI: http://${ip}:${PORT_ADMIN}"; fi
  if ((EFF_METRICS)); then echo "Metrics: http://${ip}:${PORT_METRICS}/metrics"; fi
  if ((EFF_ICEBERG)); then echo "Iceberg: http://${ip}:${PORT_ICEBERG}"; fi
  return 0
}

fix_bind_owner() {
  local uid=${1%:*} gid=${1#*:} base=0
  if [[ $CT_UNPRIVILEGED == 1 ]]; then base=100000; fi
  msg "Setting the owner of ${DATA_HOST_PATH} to the seaweedfs user of the container"
  run chown "$((base + uid)):$((base + gid))" "$DATA_HOST_PATH"
  run chmod 0750 "$DATA_HOST_PATH"
}

create_instance() {
  local uidgid
  find_template
  pct_create_args

  if [[ $DATA_MODE == bind ]]; then run mkdir -p "$DATA_HOST_PATH"; fi
  msg "Making container ${CT_ID} (${CT_HOSTNAME})"
  run pct create "$CT_ID" "${PCT_ARGS[@]}"
  CT_CREATED=1
  if [[ $FW_ENABLE == 1 ]]; then write_firewall; fi

  msg "Starting container ${CT_ID}"
  run pct start "$CT_ID"
  wait_for_network

  msg "Setting the root password"
  if ((OPT_DRY_RUN)); then
    printf '%s[dry-run]%s printf root:*** | pct exec %s -- chpasswd\n' "$C_YELLOW" "$C_OFF" "$CT_ID"
  else
    printf 'root:%s\n' "$CT_PASSWORD" | pct exec "$CT_ID" -- chpasswd
  fi

  PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/sige-seaweedfs-payload.XXXXXX")
  build_payload "$PAYLOAD_FILE"
  if ((OPT_DRY_RUN)); then msg "The installer is in ${PAYLOAD_FILE} (mode 0600, it contains the secrets)"; fi
  run pct push "$CT_ID" "$PAYLOAD_FILE" "$PAYLOAD_PATH" --perms 0700

  msg "Making the seaweedfs user"
  if ((OPT_DRY_RUN)); then
    uidgid="999:999"
  else
    uidgid=$(pct exec "$CT_ID" -- bash "$PAYLOAD_PATH" prepare)
  fi
  [[ $uidgid =~ ^[0-9]+:[0-9]+$ ]] || die "Cannot read the uid and gid of the seaweedfs user (got \"${uidgid}\")."
  if [[ $DATA_MODE == bind ]]; then fix_bind_owner "$uidgid"; fi

  msg "Installing SeaweedFS in the container"
  run pct exec "$CT_ID" -- bash "$PAYLOAD_PATH" install
  run pct exec "$CT_ID" -- rm -f "$PAYLOAD_PATH"

  if ((OPT_DRY_RUN)); then
    CT_IP=${SWFS_IP:-<container-ip>}
  else
    CT_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  run pct set "$CT_ID" --description "$(notes_text)"
}

print_report() {
  local ip=${CT_IP:-<container-ip>} line
  line="================================================================"
  printf '\n%s%s%s\n' "$C_GREEN" "$line" "$C_OFF"
  if ((OPT_DRY_RUN)); then
    printf ' %sDry run complete. The recipe did not make container %s.%s\n' "$C_BOLD" "$CT_ID" "$C_OFF"
    printf ' The values below are examples. A real run makes new secrets.\n'
  else
    printf ' %sSeaweedFS container %s is ready%s\n' "$C_BOLD" "$CT_ID" "$C_OFF"
  fi
  printf '%s\n' "$line"
  printf ' Host name:      %s\n' "$CT_HOSTNAME"
  printf ' Role:           %s (%s)\n' "$SWFS_ROLE" "$(features_text)"
  printf ' IP address:     %s\n' "$ip"
  printf ' Root password:  %s\n' "$CT_PASSWORD"
  printf '%s\n' "----------------------------------------------------------------"
  endpoints_text "$ip" | awk -F': ' '{printf " %-15s %s\n", $1 ":", $2}'
  if ((EFF_S3)); then
    printf ' S3 access key:  %s\n' "$SWFS_S3_ACCESS_KEY"
    printf ' S3 secret key:  %s\n' "$SWFS_S3_SECRET_KEY"
    if [[ -n $SWFS_BUCKETS ]]; then printf ' S3 buckets:     %s\n' "$SWFS_BUCKETS"; fi
  fi
  if ((EFF_ADMIN)); then
    printf ' Admin user:     %s\n' "$SWFS_ADMIN_USER"
    printf ' Admin password: %s\n' "$SWFS_ADMIN_PASSWORD"
  fi
  printf '%s\n' "----------------------------------------------------------------"
  printf ' The credentials are also in /root/seaweedfs-credentials.txt in the container.\n'
  printf ' To open a shell in the container:   pct enter %s\n' "$CT_ID"
  printf ' To change the SeaweedFS settings:   edit /etc/seaweedfs/seaweedfs.args,\n'
  printf '                                     then enter: systemctl restart seaweedfs\n'
  printf ' To update SeaweedFS:                pct exec %s -- seaweedfs-update\n' "$CT_ID"
  printf '%s%s%s\n' "$C_GREEN" "$line" "$C_OFF"
  if ((EFF_WEBDAV)); then warn "WebDAV has no password protection. Use it only on a trusted network."; fi
  if [[ $FW_ENABLE != 1 ]]; then
    warn "The master, volume and filer HTTP ports have no password. Keep them on a trusted network, or turn on the Proxmox firewall (FW_ENABLE=1)."
  fi
}

# =============================================================================
# In-container installer
# =============================================================================
# The host copies the ct_* functions and the PAYLOAD_VARS values into one file.
# The file runs in the container with "prepare" and then with "install".

ct_log() { printf '    [%s] %s\n' "${CT_HOSTNAME:-ct}" "$*" >&2; }

ct_die() {
  printf '    [%s] ERROR: %s\n' "${CT_HOSTNAME:-ct}" "$*" >&2
  exit 1
}

ct_main() {
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8
  trap 'printf "    [ct] ERROR: \"%s\" failed.\n" "$BASH_COMMAND" >&2' ERR
  case ${1:-} in
    prepare) ct_prepare ;;
    install) ct_install ;;
    *) ct_die "Usage: $0 prepare|install" ;;
  esac
}

# Make the seaweedfs user and print "uid:gid" (the host needs it for a bind mount).
ct_prepare() {
  if ! getent group seaweedfs >/dev/null; then groupadd --system seaweedfs; fi
  if ! id -u seaweedfs >/dev/null 2>&1; then
    useradd --system --gid seaweedfs --home-dir /var/lib/seaweedfs --create-home \
      --shell /usr/sbin/nologin --comment "SeaweedFS" seaweedfs
  fi
  printf '%s:%s\n' "$(id -u seaweedfs)" "$(id -g seaweedfs)"
}

ct_install() {
  local version
  ct_log "Installing the operating system updates"
  apt-get -q update >/dev/null
  apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade >/dev/null
  apt-get -y -q install --no-install-recommends ca-certificates curl tar gzip >/dev/null

  version=$(ct_resolve_version "$SWFS_VERSION")
  ct_log "Installing SeaweedFS ${version} (${SWFS_VARIANT} build)"
  ct_download_weed "$version"

  ct_make_dirs
  ct_write_config
  ct_write_units
  ct_write_tools

  systemctl daemon-reload
  systemctl enable --quiet --now seaweedfs.service
  if [[ $EFF_ADMIN == 1 ]]; then systemctl enable --quiet --now seaweedfs-admin.service; fi

  ct_wait_ready
  ct_make_buckets
  ct_write_credentials
  ct_log "Installation complete"
}

ct_resolve_version() {
  local want=$1 url
  if [[ $want == latest ]]; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${SWFS_RELEASE_URL}/latest") ||
      ct_die "Cannot get ${SWFS_RELEASE_URL}/latest. Set a version number, for example 4.53."
    want=${url##*/}
  fi
  [[ $want =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || ct_die "\"${want}\" is not a SeaweedFS release number."
  printf '%s\n' "$want"
}

ct_download_weed() {
  local version=$1 arch suffix="" asset url tmp expected actual bin
  arch=$(dpkg --print-architecture)
  case $arch in
    amd64 | arm64) ;;
    armhf) arch=arm ;;
    *) ct_die "SeaweedFS has no Linux build for ${arch}." ;;
  esac
  case $SWFS_VARIANT in
    large_disk) suffix="_large_disk" ;;
    full) suffix="_full" ;;
    full_large_disk) suffix="_full_large_disk" ;;
  esac
  asset="linux_${arch}${suffix}.tar.gz"
  url="${SWFS_RELEASE_URL}/download/${version}/${asset}"
  tmp=$(mktemp -d)
  curl -fsSL --retry 3 -o "${tmp}/${asset}" "$url" || ct_die "Cannot download ${url}."
  curl -fsSL --retry 3 -o "${tmp}/${asset}.md5" "${url}.md5" || ct_die "Cannot download ${url}.md5."
  expected=$(head -c 32 "${tmp}/${asset}.md5")
  actual=$(md5sum "${tmp}/${asset}" | cut -c 1-32)
  [[ $expected == "$actual" ]] || ct_die "The MD5 checksum of ${asset} is not correct."
  mkdir "${tmp}/x"
  tar -xzf "${tmp}/${asset}" -C "${tmp}/x"
  bin=$(find "${tmp}/x" -type f -name weed -print -quit)
  [[ -n $bin ]] || ct_die "${asset} does not contain the weed program."
  install -m 0755 "$bin" /usr/local/bin/weed.new
  mv -f /usr/local/bin/weed.new /usr/local/bin/weed
  rm -rf "$tmp"
  ct_log "Installed: $(/usr/local/bin/weed version 2>/dev/null | head -n 1)"
}

ct_make_dirs() {
  local d flag
  install -d -m 0755 -o root -g root /etc/seaweedfs
  install -d -m 0750 -o seaweedfs -g seaweedfs "$DATA_MOUNT"
  for d in master:EFF_MASTER volume:EFF_VOLUME filer:EFF_FILER admin:EFF_ADMIN; do
    flag=${d#*:}
    if [[ ${!flag} == 1 ]]; then
      install -d -m 0750 -o seaweedfs -g seaweedfs "${DATA_MOUNT}/${d%%:*}"
    fi
  done
}

# ct_opt NAME VALUE: print -NAME=VALUE if VALUE is not blank.
ct_opt() {
  [[ -z $2 ]] || printf -- '-%s=%s\n' "$1" "$2"
}

ct_gateway_args() {
  if [[ $EFF_S3 == 1 ]]; then
    printf '%s\n' -s3 "-s3.port=${PORT_S3}" -s3.config=/etc/seaweedfs/s3.json
    if [[ $EFF_ICEBERG == 1 ]]; then
      printf '%s\n' "-s3.port.iceberg=${PORT_ICEBERG}" "-s3.port.lance=${PORT_LANCE}"
    else
      printf '%s\n' -s3.port.iceberg=0 -s3.port.lance=0
    fi
  fi
  if [[ $EFF_WEBDAV == 1 ]]; then printf '%s\n' -webdav "-webdav.port=${PORT_WEBDAV}"; fi
  return 0
}

# Print the arguments of seaweedfs.service, one on each line.
ct_main_args() {
  local -a extra=()
  echo -logtostderr=true
  case $SWFS_ROLE in
    all-in-one)
      printf '%s\n' server -ip.bind=0.0.0.0
      ct_opt ip "$SWFS_IP"
      ct_opt dataCenter "$SWFS_DATACENTER"
      ct_opt rack "$SWFS_RACK"
      printf '%s\n' "-master.port=${PORT_MASTER}" "-master.dir=${DATA_MOUNT}/master" \
        "-master.volumeSizeLimitMB=${SWFS_VOLUME_SIZE_MB}" "-master.defaultReplication=${SWFS_REPLICATION}"
      ct_opt master.peers "$SWFS_PEERS"
      [[ $SWFS_TELEMETRY == 1 ]] || echo -master.telemetry=false
      printf '%s\n' "-volume.port=${PORT_VOLUME}" "-dir=${DATA_MOUNT}/volume" \
        "-volume.max=${SWFS_VOLUME_MAX}" "-volume.index=${SWFS_INDEX}"
      ct_opt volume.disk "$SWFS_DISK_TYPE"
      if [[ $EFF_FILER == 1 ]]; then printf '%s\n' -filer "-filer.port=${PORT_FILER}"; fi
      ct_gateway_args
      ;;
    master)
      printf '%s\n' master -ip.bind=0.0.0.0
      ct_opt ip "$SWFS_IP"
      printf '%s\n' "-port=${PORT_MASTER}" "-mdir=${DATA_MOUNT}/master" \
        "-volumeSizeLimitMB=${SWFS_VOLUME_SIZE_MB}" "-defaultReplication=${SWFS_REPLICATION}"
      ct_opt peers "$SWFS_PEERS"
      [[ $SWFS_TELEMETRY == 1 ]] || echo -telemetry=false
      ;;
    volume)
      printf '%s\n' volume -ip.bind=0.0.0.0
      ct_opt ip "$SWFS_IP"
      printf '%s\n' "-port=${PORT_VOLUME}" "-master=${SWFS_MASTER}" "-dir=${DATA_MOUNT}/volume" \
        "-max=${SWFS_VOLUME_MAX}" "-index=${SWFS_INDEX}"
      ct_opt disk "$SWFS_DISK_TYPE"
      ct_opt dataCenter "$SWFS_DATACENTER"
      ct_opt rack "$SWFS_RACK"
      ;;
    filer)
      printf '%s\n' filer -ip.bind=0.0.0.0
      ct_opt ip "$SWFS_IP"
      printf '%s\n' "-port=${PORT_FILER}" "-master=${SWFS_MASTER}" "-defaultStoreDir=${DATA_MOUNT}/filer"
      ct_opt dataCenter "$SWFS_DATACENTER"
      ct_opt rack "$SWFS_RACK"
      ct_gateway_args
      ;;
  esac
  if [[ $EFF_METRICS == 1 ]]; then echo "-metricsPort=${PORT_METRICS}"; fi
  if [[ -n $SWFS_EXTRA_ARGS ]]; then
    read -ra extra <<<"$SWFS_EXTRA_ARGS"
    echo "# Extra arguments from the recipe answers:"
    printf '%s\n' "${extra[@]}"
  fi
  return 0
}

ct_admin_args() {
  printf '%s\n' -logtostderr=true admin "-port=${PORT_ADMIN}" -port.legacy=0 \
    "-master=${ADMIN_MASTER}" "-dataDir=${DATA_MOUNT}/admin" "-adminUser=${SWFS_ADMIN_USER}"
  if [[ $EFF_ICEBERG == 1 ]]; then
    printf '%s\n' "-iceberg.port=${PORT_ICEBERG}" "-lance.port=${PORT_LANCE}"
  else
    printf '%s\n' -iceberg.port=0 -lance.port=0
  fi
  echo "# The admin password is in /etc/seaweedfs/admin.env (WEED_ADMIN_PASSWORD)."
}

# ct_write_args FILE UNIT < ARGUMENTS
ct_write_args() {
  {
    printf '# weed arguments for %s.service. sige-seaweedfs %s made this file.\n' "$2" "$RECIPE_VERSION"
    printf '# Write one argument on each line. A line that starts with "#" is a comment.\n'
    printf '# Write the global weed options first, then the command, then its options.\n'
    printf '# To see the options of a command, enter: weed help <command>\n'
    printf '# To apply a change, enter: systemctl restart %s\n' "$2"
    cat
  } >"$1"
  chmod 0644 "$1"
}

ct_write_config() {
  ct_main_args | ct_write_args /etc/seaweedfs/seaweedfs.args seaweedfs

  if [[ $EFF_FILER == 1 ]]; then
    cat >/etc/seaweedfs/filer.toml <<EOF
# Filer metadata store. sige-seaweedfs ${RECIPE_VERSION} made this file.
# To see the other stores, enter: weed scaffold -config=filer
[leveldb2]
enabled = true
dir = "${DATA_MOUNT}/filer/filerldb2"
EOF
    chmod 0644 /etc/seaweedfs/filer.toml
  fi

  if [[ $EFF_S3 == 1 ]]; then
    (
      umask 027
      cat >/etc/seaweedfs/s3.json <<EOF
{
  "identities": [
    {
      "name": "admin",
      "credentials": [
        {
          "accessKey": "${SWFS_S3_ACCESS_KEY}",
          "secretKey": "${SWFS_S3_SECRET_KEY}"
        }
      ],
      "actions": ["Admin", "Read", "List", "Tagging", "Write"]
    }
  ]
}
EOF
    )
    chown root:seaweedfs /etc/seaweedfs/s3.json
    chmod 0640 /etc/seaweedfs/s3.json
  fi

  if [[ $EFF_ADMIN == 1 ]]; then
    ct_admin_args | ct_write_args /etc/seaweedfs/admin.args seaweedfs-admin
    (
      umask 077
      printf '# Password of the SeaweedFS admin web UI.\nWEED_ADMIN_PASSWORD=%s\n' "$SWFS_ADMIN_PASSWORD" \
        >/etc/seaweedfs/admin.env
    )
    chmod 0600 /etc/seaweedfs/admin.env
  fi

  printf '%s\n' "$RECIPE_ANSWERS" >/etc/seaweedfs/recipe.answers
  chmod 0644 /etc/seaweedfs/recipe.answers
}

# ct_write_unit NAME DESCRIPTION ARGS-FILE [ENVIRONMENT-FILE]
ct_write_unit() {
  {
    printf '# sige-seaweedfs %s made this file.\n' "$RECIPE_VERSION"
    printf '[Unit]\nDescription=%s\nDocumentation=https://github.com/seaweedfs/seaweedfs/wiki\n' "$2"
    printf 'After=network-online.target\nWants=network-online.target\n'
    if [[ $1 == seaweedfs-admin ]]; then printf 'After=seaweedfs.service\n'; fi
    printf '\n[Service]\nType=simple\nUser=seaweedfs\nGroup=seaweedfs\n'
    printf 'WorkingDirectory=/var/lib/seaweedfs\n'
    if [[ -n ${4:-} ]]; then printf 'EnvironmentFile=%s\n' "$4"; fi
    printf 'ExecStart=/usr/local/sbin/seaweedfs-launch %s\n' "$3"
    printf 'Restart=on-failure\nRestartSec=5\nLimitNOFILE=65536\nTimeoutStopSec=60\n'
    printf '\n[Install]\nWantedBy=multi-user.target\n'
  } >"/etc/systemd/system/$1.service"
}

ct_write_units() {
  ct_write_unit seaweedfs "SeaweedFS ${SWFS_ROLE}" /etc/seaweedfs/seaweedfs.args
  if [[ $EFF_ADMIN == 1 ]]; then
    ct_write_unit seaweedfs-admin "SeaweedFS admin web UI" /etc/seaweedfs/admin.args /etc/seaweedfs/admin.env
  fi
}

ct_write_tools() {
  cat >/usr/local/sbin/seaweedfs-launch <<'EOF'
#!/bin/sh
# Start weed with the arguments in a file. sige-seaweedfs made this file.
# The file has one argument on each line. A line that starts with "#" is a
# comment. The launcher ignores blank lines.
set -eu
if [ "$#" -ne 1 ]; then
  echo "Usage: seaweedfs-launch ARGUMENTS-FILE" >&2
  exit 2
fi
set -f
IFS='
'
# shellcheck disable=SC2046
set -- $(grep -Ev '^[[:space:]]*(#|$)' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
exec /usr/local/bin/weed "$@"
EOF
  chmod 0755 /usr/local/sbin/seaweedfs-launch

  {
    printf '#!/usr/bin/env bash\n'
    printf '# Update the weed program. sige-seaweedfs %s made this file.\n' "$RECIPE_VERSION"
    printf '# Usage: seaweedfs-update [latest|VERSION]\n'
    printf 'set -Eeuo pipefail\n'
    declare -p CT_HOSTNAME SWFS_VARIANT SWFS_RELEASE_URL
    declare -f ct_log ct_die ct_resolve_version ct_download_weed
    cat <<'EOF'
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  echo "Usage: seaweedfs-update [latest|VERSION]"
  exit 0
fi
current=$(/usr/local/bin/weed version 2>/dev/null | awk '{print $3}')
target=$(ct_resolve_version "${1:-latest}")
if [[ $current == "$target" ]]; then
  ct_log "SeaweedFS ${current} is installed. No update is necessary."
  exit 0
fi
ct_log "Updating SeaweedFS from ${current:-unknown} to ${target}"
ct_download_weed "$target"
systemctl try-restart seaweedfs.service seaweedfs-admin.service
ct_log "Update complete. To see the status, enter: systemctl status seaweedfs"
EOF
  } >/usr/local/sbin/seaweedfs-update
  chmod 0755 /usr/local/sbin/seaweedfs-update
}

# ct_wait_http UNIT NAME URL: wait until URL gives an HTTP answer.
ct_wait_http() {
  local unit=$1 name=$2 url=$3 n=$WAIT_SECONDS code
  while ((n > 0)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" || true)
    if [[ $code != 000 ]]; then
      ct_log "${name} is ready (${url})"
      return 0
    fi
    if systemctl is-failed --quiet "$unit"; then break; fi
    sleep 2
    n=$((n - 2))
  done
  ct_log "WARNING: ${name} does not answer at ${url}."
  return 1
}

ct_wait_ready() {
  local ok=1 u=seaweedfs
  if [[ $EFF_MASTER == 1 ]]; then ct_wait_http "$u" "Master" "http://127.0.0.1:${PORT_MASTER}/cluster/status" || ok=0; fi
  if [[ $EFF_VOLUME == 1 ]]; then ct_wait_http "$u" "Volume server" "http://127.0.0.1:${PORT_VOLUME}/status" || ok=0; fi
  if [[ $EFF_FILER == 1 ]]; then ct_wait_http "$u" "Filer" "http://127.0.0.1:${PORT_FILER}/" || ok=0; fi
  if [[ $EFF_S3 == 1 ]]; then ct_wait_http "$u" "S3 gateway" "http://127.0.0.1:${PORT_S3}/" || ok=0; fi
  if [[ $EFF_WEBDAV == 1 ]]; then ct_wait_http "$u" "WebDAV gateway" "http://127.0.0.1:${PORT_WEBDAV}/" || ok=0; fi
  if [[ $EFF_ADMIN == 1 ]]; then
    ct_wait_http seaweedfs-admin "Admin UI" "http://127.0.0.1:${PORT_ADMIN}/" || ok=0
  fi
  if ((!ok)); then
    ct_log "WARNING: A service is not ready. The last log lines follow."
    journalctl -u seaweedfs -u seaweedfs-admin -n 30 --no-pager >&2 || true
    ct_log "Correct the settings in /etc/seaweedfs, then enter: systemctl restart seaweedfs"
  fi
  return 0
}

ct_make_buckets() {
  local master b out n
  local -a list=()
  if [[ $EFF_S3 != 1 || -z $SWFS_BUCKETS ]]; then return 0; fi
  if [[ $EFF_MASTER == 1 ]]; then master="127.0.0.1:${PORT_MASTER}"; else master=$SWFS_MASTER; fi
  IFS=, read -ra list <<<"$SWFS_BUCKETS"
  for b in "${list[@]}"; do
    for n in 1 2 3 4 5 6 7 8 9 10; do
      printf 's3.bucket.create -name %s\n' "$b" |
        timeout 60 /usr/local/bin/weed shell -master="$master" -filer="127.0.0.1:${PORT_FILER}" >/dev/null 2>&1 || true
      out=$(printf 's3.bucket.list\n' |
        timeout 60 /usr/local/bin/weed shell -master="$master" -filer="127.0.0.1:${PORT_FILER}" 2>/dev/null || true)
      if grep -qw -- "$b" <<<"$out"; then
        ct_log "Made the S3 bucket ${b}"
        continue 2
      fi
      sleep 3
    done
    ct_log "WARNING: Cannot make the S3 bucket ${b}. Make it later with: weed shell, then s3.bucket.create -name ${b}"
  done
  return 0
}

ct_write_credentials() {
  (
    umask 077
    {
      printf '# SeaweedFS credentials. sige-seaweedfs %s made this file on %s.\n' "$RECIPE_VERSION" "$(date '+%Y-%m-%d %H:%M')"
      if [[ $EFF_S3 == 1 ]]; then
        printf 'S3_PORT=%s\nS3_ACCESS_KEY=%s\nS3_SECRET_KEY=%s\n' "$PORT_S3" "$SWFS_S3_ACCESS_KEY" "$SWFS_S3_SECRET_KEY"
      fi
      if [[ $EFF_ADMIN == 1 ]]; then
        printf 'ADMIN_PORT=%s\nADMIN_USER=%s\nADMIN_PASSWORD=%s\n' "$PORT_ADMIN" "$SWFS_ADMIN_USER" "$SWFS_ADMIN_PASSWORD"
      fi
    } >/root/seaweedfs-credentials.txt
  )
}

# =============================================================================
# Main
# =============================================================================
need_arg() {
  [[ $# -ge 2 && -n $2 ]] || die "The option $1 needs a value."
}

parse_args() {
  while (($#)); do
    case $1 in
      -c | --config) need_arg "$@" && OPT_CONFIG=$2 && shift 2 ;;
      --config=*) OPT_CONFIG=${1#*=} && shift ;;
      -s | --set) need_arg "$@" && OPT_SETS+=("$2") && shift 2 ;;
      --set=*) OPT_SETS+=("${1#*=}") && shift ;;
      -u | --unattended) OPT_UNATTENDED=1 && shift ;;
      -n | --dry-run) OPT_DRY_RUN=1 && shift ;;
      --save) need_arg "$@" && OPT_SAVE=$2 && shift 2 ;;
      --save=*) OPT_SAVE=${1#*=} && shift ;;
      -h | --help) usage && exit 0 ;;
      -V | --version) echo "sige-seaweedfs ${RECIPE_VERSION}" && exit 0 ;;
      *) die "Unknown option: $1. Use --help to see the options." ;;
    esac
  done
}

main() {
  local errs
  parse_args "$@"
  set_defaults
  if [[ -n $OPT_CONFIG ]]; then load_answers "$OPT_CONFIG"; fi
  apply_sets
  preflight
  detect_host
  fill_defaults

  if ((OPT_UNATTENDED)); then
    if ! errs=$(validate_all); then
      printf '%s\n' "$errs" | sed 's/^/  - /' >&2
      die "Correct the answers above."
    fi
  else
    run_wizard
  fi

  if [[ -n $OPT_SAVE ]]; then
    write_answers "$OPT_SAVE" template
    msg "The recipe wrote the answers to ${OPT_SAVE}."
    exit 0
  fi

  derive
  if ((OPT_DRY_RUN)); then msg "Dry run: the recipe does not change the host."; fi
  create_instance
  print_report
}

main "$@"
