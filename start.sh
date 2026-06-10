#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
VAR_DIR="$PROJECT_ROOT/generated_vars"
VAR_FILE="$VAR_DIR/env.yml"
BACKUP_ROOT="$PROJECT_ROOT/backups"
BACKUP_ID=""
BACKUP_PATH=""
RESTORE_BACKUP_PATH=""
RESTORE_NETWORK="false"
RESTORE_PACKAGES="false"

# Korean TUI text needs a UTF-8 locale. Do not force LC_ALL=C.
if locale -a 2>/dev/null | grep -qi '^ko_KR\.utf8$'; then
  export LANG="${LANG:-ko_KR.UTF-8}"
elif locale -a 2>/dev/null | grep -qi '^C\.utf8$'; then
  export LANG="${LANG:-C.UTF-8}"
else
  export LANG="${LANG:-C.UTF-8}"
fi
export LC_CTYPE="${LC_CTYPE:-$LANG}"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fatal() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    fi
    fatal "root 또는 sudo 권한으로 실행해야 합니다. 예: sudo ./start.sh"
  fi
}

check_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] || fatal "대화형 TTY가 필요합니다. 터미널에서 직접 실행하세요."
}

check_os() {
  [[ -r /etc/os-release ]] || fatal "/etc/os-release 파일을 찾을 수 없습니다."
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${NAME:-}" != "CentOS Stream" || "${VERSION_ID:-}" != "9" ]]; then
    fatal "이 도구는 CentOS Stream 9만 지원합니다. 감지된 OS: ${PRETTY_NAME:-unknown}"
  fi
}

install_bootstrap_packages() {
  local missing=()

  command -v dnf >/dev/null 2>&1 || fatal "dnf 명령을 찾을 수 없습니다."

  command -v dialog >/dev/null 2>&1 || missing+=(dialog)
  command -v ansible-playbook >/dev/null 2>&1 || missing+=(ansible-core)
  command -v nmcli >/dev/null 2>&1 || missing+=(NetworkManager NetworkManager-tui)
  command -v ssh >/dev/null 2>&1 || missing+=(openssh-clients)

  if (( ${#missing[@]} > 0 )); then
    info "bootstrap 패키지를 설치합니다: ${missing[*]}"
    dnf install -y "${missing[@]}"
  fi
}

DIALOG=(dialog --ascii-lines --no-collapse)
DIALOG_TMP=""
FEATURE_FILE=""
RUN_ANSIBLE="true"
USE_DEFAULTS="true"

CURRENT_HOSTNAME=""
CURRENT_IFACE=""
CURRENT_CONNECTION=""
CURRENT_IP_CIDR=""
CURRENT_GATEWAY=""
CURRENT_DNS=""
CURRENT_DNS_SEARCH=""

cleanup_dialog() {
  [[ -n "${DIALOG_TMP:-}" && -f "$DIALOG_TMP" ]] && rm -f "$DIALOG_TMP"
  [[ -n "${FEATURE_FILE:-}" && -f "$FEATURE_FILE" ]] && rm -f "$FEATURE_FILE"
  clear || true
}
trap cleanup_dialog EXIT

dialog_init() {
  DIALOG_TMP="$(mktemp)"
  FEATURE_FILE="$(mktemp)"
}

show_msg() {
  local title="$1" message="$2" height="${3:-12}" width="${4:-86}"
  "${DIALOG[@]}" --title "$title" --msgbox "$message" "$height" "$width" < /dev/tty > /dev/tty 2>&1
}

ask_yesno() {
  local title="$1" message="$2" default_answer="${3:-yes}"
  local default_opt=()
  [[ "$default_answer" == "no" ]] && default_opt=(--defaultno)

  if "${DIALOG[@]}" "${default_opt[@]}" --title "$title" --yesno "$message" 10 86 < /dev/tty > /dev/tty 2>&1; then
    printf 'true'
  else
    printf 'false'
  fi
}

ask_input() {
  local title="$1" message="$2" default_value="${3:-}" output
  : > "$DIALOG_TMP"

  if "${DIALOG[@]}" --title "$title" --inputbox "$message" 10 92 "$default_value" 2> "$DIALOG_TMP" < /dev/tty > /dev/tty; then
    output="$(cat "$DIALOG_TMP")"
    printf '%s' "${output:-$default_value}"
  else
    printf '%s' "$default_value"
  fi
}

ask_password() {
  local title="$1" message="$2"
  : > "$DIALOG_TMP"

  if "${DIALOG[@]}" --insecure --title "$title" --passwordbox "$message" 10 92 2> "$DIALOG_TMP" < /dev/tty > /dev/tty; then
    cat "$DIALOG_TMP"
  fi
}

ask_menu() {
  local title="$1" message="$2" default_value="$3" output
  shift 3
  : > "$DIALOG_TMP"

  if "${DIALOG[@]}" --title "$title" --default-item "$default_value" --menu "$message" 16 86 7 "$@" 2> "$DIALOG_TMP" < /dev/tty > /dev/tty; then
    output="$(cat "$DIALOG_TMP")"
    printf '%s' "${output:-$default_value}"
  else
    printf '%s' "$default_value"
  fi
}

first_nonempty_line() {
  awk 'NF {print; exit}' 2>/dev/null || true
}

detect_active_iface() {
  nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected" && $1 != "lo" {print $1; exit}' || true
}

detect_connection_name() {
  local iface="$1" con
  con=$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null | head -n1 || true)
  if [[ -z "$con" || "$con" == "--" ]]; then
    echo "eth0"
  else
    echo "$con"
  fi
}

detect_device_value() {
  local iface="$1" field="$2"
  nmcli -g "$field" device show "$iface" 2>/dev/null | first_nonempty_line
}

detect_environment() {
  CURRENT_HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo localhost)"
  CURRENT_IFACE="$(detect_active_iface)"
  CURRENT_IFACE="${CURRENT_IFACE:-ens160}"
  CURRENT_CONNECTION="$(detect_connection_name "$CURRENT_IFACE")"
  CURRENT_IP_CIDR="$(detect_device_value "$CURRENT_IFACE" IP4.ADDRESS)"
  CURRENT_GATEWAY="$(detect_device_value "$CURRENT_IFACE" IP4.GATEWAY)"
  CURRENT_DNS="$(detect_device_value "$CURRENT_IFACE" IP4.DNS)"
  CURRENT_DNS_SEARCH="$(detect_device_value "$CURRENT_IFACE" IP4.DOMAIN)"

  CURRENT_IP_CIDR="${CURRENT_IP_CIDR:-192.168.10.10/24}"
  CURRENT_GATEWAY="${CURRENT_GATEWAY:-192.168.10.2}"
  CURRENT_DNS="${CURRENT_DNS:-8.8.8.8}"
  CURRENT_DNS_SEARCH="${CURRENT_DNS_SEARCH:-example.com}"
}

ask_checklist() {
  : > "$FEATURE_FILE"
  if ! "${DIALOG[@]}" --title "Setup Modules" --separate-output --checklist \
    "적용할 항목을 선택하세요. SPACE로 선택/해제하고 ENTER로 진행합니다.\n항목명은 영어로 표시하고, 설명은 한국어로 표시합니다." \
    24 108 14 \
    HOSTNAME  "호스트명 변경 - 현재값: ${CURRENT_HOSTNAME}" off \
    ROOTPWD   "root 암호 변경" off \
    NETWORK   "기본 NIC 설정 변경 - 현재: ${CURRENT_IFACE}, IP: ${CURRENT_IP_CIDR}" off \
    EXTRANIC  "이미 장착된 추가 NIC IP 설정 - NIC 추가 자체는 제외" off \
    FIREWALLD "firewalld 중지 및 비활성화" on \
    SELINUX   "SELinux를 permissive로 설정" on \
    SSHKEY    "추후 server1/server2 확장을 위한 로컬 SSH 키 생성" off \
    HOSTS     "/etc/hosts에 실습 호스트 항목 추가" on \
    PS1       "root 쉘 프롬프트 설정" on \
    GNOME     "GNOME 화면 잠금, 전원, 폰트, 확장 설정" on \
    KOREAN    "한글 Hangul 입력 소스 설정" on \
    VSCODE    "VSCode 설치, root alias, 확장 설치" off \
    REBOOT    "필요 시 자동 재부팅 허용" off \
    2> "$FEATURE_FILE" < /dev/tty > /dev/tty; then
    fatal "설정이 취소되었습니다."
  fi
}

feature_selected() {
  local feature="$1"
  grep -qx "$feature" "$FEATURE_FILE"
}

yaml_quote() {
  local value="${1-}"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

set_default_values() {
  detect_environment

  APPLY_HOSTNAME="false"
  HOSTNAME_VALUE="$CURRENT_HOSTNAME"

  CHANGE_ROOT_PASSWORD="false"
  ROOT_PASSWORD=""

  CONFIGURE_NETWORK="false"
  NETWORK_INTERFACE="$CURRENT_IFACE"
  NETWORK_CONNECTION="$CURRENT_CONNECTION"
  NETWORK_IP_CIDR="$CURRENT_IP_CIDR"
  NETWORK_GATEWAY="$CURRENT_GATEWAY"
  NETWORK_DNS="$CURRENT_DNS"
  NETWORK_DNS_SEARCH="$CURRENT_DNS_SEARCH"

  CONFIGURE_EXTRA_NIC="false"
  EXTRA_NIC_INTERFACE="ens192"
  EXTRA_NIC_CONNECTION="eth1"
  EXTRA_NIC_IP_CIDR="10.1.93.200/24"
  EXTRA_NIC_SET_GATEWAY="false"
  EXTRA_NIC_GATEWAY=""

  DISABLE_FIREWALLD="false"
  CONFIGURE_SELINUX="false"
  SELINUX_STATE="permissive"

  GENERATE_SSH_KEY="false"
  SSH_KEY_FORCE="false"
  SSH_KEY_PATH="/root/.ssh/id_rsa"

  MANAGE_HOSTS="false"

  CONFIGURE_PS1="false"
  PS1_FILE="/root/.bashrc"
  PS1_PROMPT='\[\e[31;1m\][\u@\h\[\e[33;1m\] \w]\$ \[\e[m\]'

  CONFIGURE_GNOME="false"
  UNLOCK_SCREEN="false"
  GNOME_IDLE_DELAY="0"
  GNOME_POWER_PROFILE="balanced"
  INSTALL_GNOME_TWEAKS="false"
  GNOME_FONT_FAMILY="Monospace"
  GNOME_FONT_WEIGHT="Bold"
  GNOME_FONT_SIZE="18"
  ENABLE_GNOME_EXTENSIONS="false"
  CREATE_TERMINAL_DESKTOP_ICON="false"

  CONFIGURE_KOREAN_INPUT="false"

  INSTALL_VSCODE="false"
  CONFIGURE_VSCODE_ALIAS="false"
  VSCODE_WORKDIR="/root/shell"
  VSCODE_USER_DATA_DIR="/root/vscode"

  AUTO_REBOOT="false"
}

apply_feature_selection() {
  feature_selected HOSTNAME  && APPLY_HOSTNAME="true"
  feature_selected ROOTPWD   && CHANGE_ROOT_PASSWORD="true"
  feature_selected NETWORK   && CONFIGURE_NETWORK="true"
  feature_selected EXTRANIC  && CONFIGURE_EXTRA_NIC="true"
  feature_selected FIREWALLD && DISABLE_FIREWALLD="true"
  feature_selected SELINUX   && CONFIGURE_SELINUX="true"
  feature_selected SSHKEY    && GENERATE_SSH_KEY="true"
  feature_selected HOSTS     && MANAGE_HOSTS="true"
  feature_selected PS1       && CONFIGURE_PS1="true"
  feature_selected GNOME     && CONFIGURE_GNOME="true"
  feature_selected KOREAN    && CONFIGURE_KOREAN_INPUT="true"
  feature_selected VSCODE    && INSTALL_VSCODE="true"
  feature_selected REBOOT    && AUTO_REBOOT="true"

  if [[ "$CONFIGURE_GNOME" == "true" ]]; then
    UNLOCK_SCREEN="true"
    INSTALL_GNOME_TWEAKS="true"
    ENABLE_GNOME_EXTENSIONS="true"
    CREATE_TERMINAL_DESKTOP_ICON="true"
  fi

  if [[ "$INSTALL_VSCODE" == "true" ]]; then
    CONFIGURE_VSCODE_ALIAS="true"
  fi
}

ask_required_values() {
  if [[ "$CHANGE_ROOT_PASSWORD" == "true" ]]; then
    ROOT_PASSWORD=$(ask_password "Root Password" "새 root 암호를 입력하세요.")
    [[ -n "$ROOT_PASSWORD" ]] || fatal "root 암호 변경을 선택했지만 암호가 입력되지 않았습니다."
  fi
}

ask_custom_values() {
  if [[ "$APPLY_HOSTNAME" == "true" ]]; then
    HOSTNAME_VALUE=$(ask_input "Hostname" "설정할 호스트명을 입력하세요. 현재값: ${CURRENT_HOSTNAME}" "$HOSTNAME_VALUE")
  fi

  if [[ "$CONFIGURE_NETWORK" == "true" ]]; then
    show_msg "Network Warning" \
      "기본 네트워크 설정을 변경하면 현재 네트워크 연결이 끊길 수 있습니다.\n\n이 도구는 git clone/pull/push를 수행하지 않습니다. 필요한 파일을 이미 로컬에 받은 상태에서 진행하세요." \
      13 88
    NETWORK_INTERFACE=$(ask_input "Network" "기본 NIC 인터페이스명을 입력하세요." "$NETWORK_INTERFACE")
    NETWORK_CONNECTION=$(ask_input "Network" "NetworkManager connection/profile 이름을 입력하세요." "$NETWORK_CONNECTION")
    NETWORK_IP_CIDR=$(ask_input "Network" "IPv4 주소/CIDR을 입력하세요." "$NETWORK_IP_CIDR")
    NETWORK_GATEWAY=$(ask_input "Network" "Gateway를 입력하세요." "$NETWORK_GATEWAY")
    NETWORK_DNS=$(ask_input "Network" "DNS를 입력하세요." "$NETWORK_DNS")
    NETWORK_DNS_SEARCH=$(ask_input "Network" "DNS search domain을 입력하세요." "$NETWORK_DNS_SEARCH")
  fi

  if [[ "$CONFIGURE_EXTRA_NIC" == "true" ]]; then
    EXTRA_NIC_INTERFACE=$(ask_input "Extra NIC" "추가 NIC 인터페이스명을 입력하세요. NIC는 이미 VM에 장착되어 있어야 합니다." "$EXTRA_NIC_INTERFACE")
    EXTRA_NIC_CONNECTION=$(ask_input "Extra NIC" "추가 NIC connection/profile 이름을 입력하세요." "$EXTRA_NIC_CONNECTION")
    EXTRA_NIC_IP_CIDR=$(ask_input "Extra NIC" "추가 NIC IPv4 주소/CIDR을 입력하세요." "$EXTRA_NIC_IP_CIDR")
    EXTRA_NIC_SET_GATEWAY=$(ask_yesno "Extra NIC" "추가 NIC에 Gateway를 설정할까요? 일반적으로 No입니다." no)
    if [[ "$EXTRA_NIC_SET_GATEWAY" == "true" ]]; then
      EXTRA_NIC_GATEWAY=$(ask_input "Extra NIC" "추가 NIC Gateway를 입력하세요." "10.1.93.1")
    fi
  fi

  if [[ "$CONFIGURE_SELINUX" == "true" ]]; then
    SELINUX_STATE=$(ask_menu "SELinux" "SELinux 목표 상태를 선택하세요." "$SELINUX_STATE" \
      permissive "Permissive - 문서 기본값" \
      enforcing "Enforcing" \
      disabled "Disabled - 재부팅 필요")
  fi

  if [[ "$GENERATE_SSH_KEY" == "true" ]]; then
    SSH_KEY_PATH=$(ask_input "SSH Key" "SSH private key 경로를 입력하세요." "$SSH_KEY_PATH")
    SSH_KEY_FORCE=$(ask_yesno "SSH Key" "기존 키가 있으면 덮어쓸까요?" no)
  fi

  if [[ "$CONFIGURE_PS1" == "true" ]]; then
    PS1_FILE=$(ask_input "Shell" "PS1을 적용할 파일 경로를 입력하세요." "$PS1_FILE")
  fi

  if [[ "$CONFIGURE_GNOME" == "true" ]]; then
    UNLOCK_SCREEN=$(ask_yesno "GNOME" "빈 화면 지연 시간과 화면 잠금을 비활성화할까요?" yes)
    GNOME_IDLE_DELAY=$(ask_input "GNOME" "idle delay 초 값을 입력하세요. 0은 비활성화 의미입니다." "$GNOME_IDLE_DELAY")
    GNOME_POWER_PROFILE=$(ask_menu "GNOME" "전원 모드를 선택하세요." "$GNOME_POWER_PROFILE" balanced "Balanced" performance "Performance")
    INSTALL_GNOME_TWEAKS=$(ask_yesno "GNOME" "gnome-tweaks를 설치할까요?" yes)
    GNOME_FONT_FAMILY=$(ask_input "GNOME" "고정폭 폰트 family를 입력하세요." "$GNOME_FONT_FAMILY")
    GNOME_FONT_WEIGHT=$(ask_input "GNOME" "고정폭 폰트 weight를 입력하세요." "$GNOME_FONT_WEIGHT")
    GNOME_FONT_SIZE=$(ask_input "GNOME" "고정폭 폰트 size를 입력하세요." "$GNOME_FONT_SIZE")
    ENABLE_GNOME_EXTENSIONS=$(ask_yesno "GNOME" "사용 가능한 GNOME extensions를 활성화할까요?" yes)
    CREATE_TERMINAL_DESKTOP_ICON=$(ask_yesno "GNOME" "Desktop 또는 바탕화면에 Terminal 아이콘을 만들까요?" yes)
  fi

  if [[ "$INSTALL_VSCODE" == "true" ]]; then
    CONFIGURE_VSCODE_ALIAS=$(ask_yesno "VSCode" "root용 code/vscode alias를 설정할까요?" yes)
    VSCODE_WORKDIR=$(ask_input "VSCode" "VSCode 작업 폴더를 입력하세요." "$VSCODE_WORKDIR")
    VSCODE_USER_DATA_DIR=$(ask_input "VSCode" "root 실행용 VSCode user-data-dir를 입력하세요." "$VSCODE_USER_DATA_DIR")
  fi
}

bool_mark() {
  local value="$1"
  [[ "$value" == "true" ]] && printf 'ON ' || printf 'off'
}

build_summary() {
  cat <<'SUMMARY_EOF'
Variable file:
__VAR_FILE__

Rollback backup path:
__BACKUP_PATH__

Selected modules:
[__APPLY_HOSTNAME__] HOSTNAME   target: __HOSTNAME_VALUE__
[__CONFIGURE_NETWORK__] NETWORK    iface: __NETWORK_INTERFACE__, ip: __NETWORK_IP_CIDR__
[__CONFIGURE_EXTRA_NIC__] EXTRANIC   iface: __EXTRA_NIC_INTERFACE__, ip: __EXTRA_NIC_IP_CIDR__
[__CHANGE_ROOT_PASSWORD__] ROOTPWD    [__DISABLE_FIREWALLD__] FIREWALLD   [__CONFIGURE_SELINUX__] SELINUX: __SELINUX_STATE__
[__GENERATE_SSH_KEY__] SSHKEY     [__MANAGE_HOSTS__] HOSTS      [__CONFIGURE_PS1__] PS1
[__CONFIGURE_GNOME__] GNOME      [__CONFIGURE_KOREAN_INPUT__] KOREAN     [__INSTALL_VSCODE__] VSCODE
[__AUTO_REBOOT__] REBOOT

변수 파일은 민감정보를 포함할 수 있으므로 권한 600으로 생성됩니다.
SUMMARY_EOF
}

render_summary() {
  local text
  text="$(build_summary)"
  text="${text/__VAR_FILE__/$VAR_FILE}"
  text="${text/__BACKUP_PATH__/$BACKUP_PATH}"
  text="${text/__HOSTNAME_VALUE__/$HOSTNAME_VALUE}"
  text="${text/__NETWORK_INTERFACE__/$NETWORK_INTERFACE}"
  text="${text/__NETWORK_IP_CIDR__/$NETWORK_IP_CIDR}"
  text="${text/__EXTRA_NIC_INTERFACE__/$EXTRA_NIC_INTERFACE}"
  text="${text/__EXTRA_NIC_IP_CIDR__/$EXTRA_NIC_IP_CIDR}"
  text="${text/__SELINUX_STATE__/$SELINUX_STATE}"
  text="${text/__APPLY_HOSTNAME__/$(bool_mark "$APPLY_HOSTNAME")}"
  text="${text/__CHANGE_ROOT_PASSWORD__/$(bool_mark "$CHANGE_ROOT_PASSWORD")}"
  text="${text/__CONFIGURE_NETWORK__/$(bool_mark "$CONFIGURE_NETWORK")}"
  text="${text/__CONFIGURE_EXTRA_NIC__/$(bool_mark "$CONFIGURE_EXTRA_NIC")}"
  text="${text/__DISABLE_FIREWALLD__/$(bool_mark "$DISABLE_FIREWALLD")}"
  text="${text/__CONFIGURE_SELINUX__/$(bool_mark "$CONFIGURE_SELINUX")}"
  text="${text/__GENERATE_SSH_KEY__/$(bool_mark "$GENERATE_SSH_KEY")}"
  text="${text/__MANAGE_HOSTS__/$(bool_mark "$MANAGE_HOSTS")}"
  text="${text/__CONFIGURE_PS1__/$(bool_mark "$CONFIGURE_PS1")}"
  text="${text/__CONFIGURE_GNOME__/$(bool_mark "$CONFIGURE_GNOME")}"
  text="${text/__CONFIGURE_KOREAN_INPUT__/$(bool_mark "$CONFIGURE_KOREAN_INPUT")}"
  text="${text/__INSTALL_VSCODE__/$(bool_mark "$INSTALL_VSCODE")}"
  text="${text/__AUTO_REBOOT__/$(bool_mark "$AUTO_REBOOT")}"
  printf '%s' "$text"
}

write_vars_file() {
  mkdir -p "$VAR_DIR"
  umask 077

  cat > "$VAR_FILE" <<EOFVARS
---
project_name: centosstream9-vmware-setup
project_default_path: '~/centosstream9-vmware-setup'

apply_hostname: $APPLY_HOSTNAME
hostname_value: $(yaml_quote "$HOSTNAME_VALUE")

change_root_password: $CHANGE_ROOT_PASSWORD
EOFVARS

  if [[ "$CHANGE_ROOT_PASSWORD" == "true" && -n "${ROOT_PASSWORD:-}" ]]; then
    printf 'root_password: %s\n' "$(yaml_quote "$ROOT_PASSWORD")" >> "$VAR_FILE"
  fi

  cat >> "$VAR_FILE" <<EOFVARS

configure_network: $CONFIGURE_NETWORK
network_interface: $(yaml_quote "$NETWORK_INTERFACE")
network_connection: $(yaml_quote "$NETWORK_CONNECTION")
network_ip_cidr: $(yaml_quote "$NETWORK_IP_CIDR")
network_gateway: $(yaml_quote "$NETWORK_GATEWAY")
network_dns: $(yaml_quote "$NETWORK_DNS")
network_dns_search: $(yaml_quote "$NETWORK_DNS_SEARCH")

configure_extra_nic: $CONFIGURE_EXTRA_NIC
extra_nic_interface: $(yaml_quote "$EXTRA_NIC_INTERFACE")
extra_nic_connection: $(yaml_quote "$EXTRA_NIC_CONNECTION")
extra_nic_ip_cidr: $(yaml_quote "$EXTRA_NIC_IP_CIDR")
extra_nic_set_gateway: $EXTRA_NIC_SET_GATEWAY
extra_nic_gateway: $(yaml_quote "$EXTRA_NIC_GATEWAY")

disable_firewalld: $DISABLE_FIREWALLD
configure_selinux: $CONFIGURE_SELINUX
selinux_state: $(yaml_quote "$SELINUX_STATE")

generate_ssh_key: $GENERATE_SSH_KEY
ssh_key_force: $SSH_KEY_FORCE
ssh_key_path: $(yaml_quote "$SSH_KEY_PATH")
remote_vms: []

manage_hosts: $MANAGE_HOSTS
hosts_entries:
  - ip: 192.168.10.10
    fqdn: main.example.com
    aliases: main
  - ip: 192.168.10.20
    fqdn: server1.example.com
    aliases: server1
  - ip: 192.168.10.30
    fqdn: server2.example.com
    aliases: server2

configure_ps1: $CONFIGURE_PS1
ps1_file: $(yaml_quote "$PS1_FILE")
ps1_prompt: $(yaml_quote "$PS1_PROMPT")

configure_gnome: $CONFIGURE_GNOME
unlock_screen: $UNLOCK_SCREEN
gnome_idle_delay: $GNOME_IDLE_DELAY
gnome_lock_enabled: false
gnome_power_profile: $(yaml_quote "$GNOME_POWER_PROFILE")
install_gnome_tweaks: $INSTALL_GNOME_TWEAKS
gnome_font_family: $(yaml_quote "$GNOME_FONT_FAMILY")
gnome_font_weight: $(yaml_quote "$GNOME_FONT_WEIGHT")
gnome_font_size: $GNOME_FONT_SIZE
gnome_monospace_font_name: $(yaml_quote "$GNOME_FONT_FAMILY $GNOME_FONT_WEIGHT $GNOME_FONT_SIZE")
enable_gnome_extensions: $ENABLE_GNOME_EXTENSIONS
create_terminal_desktop_icon: $CREATE_TERMINAL_DESKTOP_ICON

configure_korean_input: $CONFIGURE_KOREAN_INPUT
korean_input_sources: "[('ibus', 'hangul'), ('xkb', 'us')]"

install_vscode: $INSTALL_VSCODE
configure_vscode_alias: $CONFIGURE_VSCODE_ALIAS
vscode_workdir: $(yaml_quote "$VSCODE_WORKDIR")
vscode_user_data_dir: $(yaml_quote "$VSCODE_USER_DATA_DIR")
vscode_extensions:
  - MS-CEINTL.vscode-language-pack-ko
  - rogalmic.bash-debug
  - mads-hartmann.bash-ide-vscode
  - jeff-hykin.better-shellscript-syntax

backup_enabled: true
backup_root: $(yaml_quote "$BACKUP_ROOT")
backup_id: $(yaml_quote "$BACKUP_ID")
backup_path: $(yaml_quote "$BACKUP_PATH")

auto_reboot: $AUTO_REBOOT
EOFVARS

  chmod 600 "$VAR_FILE"
}

run_tui() {
  show_msg "CentOS Stream 9 VMware Setup" \
    "이 도구는 generated_vars/env.yml을 생성하고 localhost에 Ansible을 실행합니다.\n\nGit clone/pull/push 및 GitHub 업로드는 수행하지 않습니다.\n\n프로젝트 경로는 코드에 하드코딩하지 않고 start.sh 위치를 기준으로 계산합니다." \
    14 88

  set_default_values
  ask_checklist
  apply_feature_selection
  ask_required_values

  USE_DEFAULTS=$(ask_yesno "Default Values" \
    "선택한 항목에 기본값을 사용할까요?\n\nYes: 빠르게 진행합니다. 현재 시스템값과 문서 기준값을 사용합니다.\nNo : 호스트명, IP, SELinux, 폰트, 경로 등 세부값을 수정합니다." \
    yes)

  if [[ "$USE_DEFAULTS" == "false" ]]; then
    ask_custom_values
  fi

  BACKUP_ID="$(date +%Y%m%d_%H%M%S)"
  BACKUP_PATH="$BACKUP_ROOT/$BACKUP_ID"

  write_vars_file

  show_msg "Summary" "$(render_summary)" 22 96
  RUN_ANSIBLE=$(ask_yesno "Run Ansible" "지금 ansible-playbook을 실행할까요?\n\nNo를 선택하면 generated_vars/env.yml만 생성하고 종료합니다." yes)
}


choose_restore_backup() {
  local entries=() backup_dir backup_name
  mkdir -p "$BACKUP_ROOT"

  while IFS= read -r backup_dir; do
    backup_name="$(basename "$(dirname "$backup_dir")")"
    entries+=("$(dirname "$backup_dir")" "$backup_name")
  done < <(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -name restore_vars.yml -type f 2>/dev/null | sort -r)

  if (( ${#entries[@]} == 0 )); then
    fatal "복구 가능한 백업을 찾지 못했습니다: $BACKUP_ROOT"
  fi

  : > "$DIALOG_TMP"
  if "${DIALOG[@]}" --title "Restore Backup" --menu \
    "복구할 백업을 선택하세요. 네트워크 복구는 다음 단계에서 별도로 선택합니다." \
    18 100 10 "${entries[@]}" 2> "$DIALOG_TMP" < /dev/tty > /dev/tty; then
    RESTORE_BACKUP_PATH="$(cat "$DIALOG_TMP")"
  else
    fatal "복구가 취소되었습니다."
  fi
}

run_restore_tui() {
  show_msg "Restore Mode" \
    "이 모드는 이전 실행 직전에 생성된 backup 디렉터리를 사용해 도구가 변경한 항목을 되돌립니다.\n\n주의: VM 스냅샷이 아니므로 외부에서 동시에 변경한 내용까지 완벽히 보존할 수는 없습니다. 네트워크와 패키지 제거는 위험할 수 있어 별도 선택으로 처리합니다." \
    15 96

  choose_restore_backup
  RESTORE_NETWORK=$(ask_yesno "Restore Network" "NetworkManager connection 백업을 import할까요?\n\n주의: 현재 네트워크 연결이 끊길 수 있습니다. 기본값은 No입니다." no)
  RESTORE_PACKAGES=$(ask_yesno "Restore Packages" "이 도구 설치로 추가된 일부 선택 패키지를 제거할까요?\n\n주의: 패키지 제거는 다른 용도에 영향을 줄 수 있습니다. 기본값은 No입니다." no)

  show_msg "Restore Summary" \
    "선택한 백업:\n$RESTORE_BACKUP_PATH\n\n네트워크 복구: $RESTORE_NETWORK\n패키지 제거: $RESTORE_PACKAGES\n\nOK 후 restore.yml을 실행합니다." \
    15 96
}

run_playbook() {
  cd "$PROJECT_ROOT"
  ansible-playbook -i inventory playbook.yml -e "@$VAR_FILE"
}

run_restore_playbook() {
  cd "$PROJECT_ROOT"
  ansible-playbook -i inventory restore.yml \
    -e "restore_backup_path=$RESTORE_BACKUP_PATH" \
    -e "restore_network=$RESTORE_NETWORK" \
    -e "restore_packages=$RESTORE_PACKAGES"
}

main() {
  local mode="apply"
  if [[ "${1:-}" == "--restore" || "${1:-}" == "restore" ]]; then
    mode="restore"
  fi

  require_root "$@"
  check_tty
  check_os
  install_bootstrap_packages
  dialog_init

  if [[ "$mode" == "restore" ]]; then
    run_restore_tui
    run_restore_playbook
    exit 0
  fi

  run_tui

  if [[ "$RUN_ANSIBLE" == "true" ]]; then
    run_playbook
  else
    info "변수 파일만 생성했습니다: $VAR_FILE"
    info "나중에 실행: sudo ansible-playbook -i inventory playbook.yml -e @generated_vars/env.yml"
    info "복구 백업은 ansible-playbook 실행 직전에 생성되므로 아직 생성되지 않았습니다."
  fi
}

main "$@"
