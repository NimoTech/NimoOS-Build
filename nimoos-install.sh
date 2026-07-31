#!/usr/bin/bash
#
#           NimoOS Installer Script v0.4.16#
#   GitHub: https://github.com/NimoTech/NimoOS
#   Issues: https://github.com/NimoTech/NimoOS/issues
#   Requires: bash, mv, rm, tr, grep, sed, curl/wget, tar, smartmontools, parted, ntfs-3g, net-tools
#
#   This script installs NimoOS to your system.
#   Usage:
#
#   	$ wget -qO- https://nimoos-s3-bucket.s3.us-east-2.amazonaws.com/get/nimoos-install.sh | sudo bash
#   	  or
#   	$ curl -fsSL https://nimoos-s3-bucket.s3.us-east-2.amazonaws.com/get/nimoos-install.sh | sudo bash
#
#   In automated environments, you may want to run as root.
#   If using curl, we recommend using the -fsSL flags.
#
#   This only work on  Linux systems. Please
#   open an issue if you notice any bugs.
#
clear
echo -e "\e[0m\c"

# shellcheck disable=SC2016
echo '
░███    ░██ ░██                             ░██████     ░██████   
░████   ░██                                ░██   ░██   ░██   ░██  
░██░██  ░██ ░██░█████████████   ░███████  ░██     ░██ ░██         
░██ ░██ ░██ ░██░██   ░██   ░██ ░██    ░██ ░██     ░██  ░████████  
░██  ░██░██ ░██░██   ░██   ░██ ░██    ░██ ░██     ░██         ░██ 
░██   ░████ ░██░██   ░██   ░██ ░██    ░██  ░██   ░██   ░██   ░██  
░██    ░███ ░██░██   ░██   ░██  ░███████    ░██████     ░██████   
                                                                  
'
export PATH=/usr/sbin:$PATH
export DEBIAN_FRONTEND=noninteractive

set -e

###############################################################################
# GOLBALS                                                                     #
###############################################################################

((EUID)) && sudo_cmd="sudo"

# shellcheck source=/dev/null
source /etc/os-release

# SYSTEM REQUIREMENTS
readonly MINIMUM_DISK_SIZE_GB="5"
readonly MINIMUM_MEMORY="400"
readonly MINIMUM_DOCKER_VERSION="20"
readonly NIMO_DEPANDS_COMMAND=('wget' 'curl' 'smartctl' 'parted' 'ntfs-3g' 'netstat' 'udevil' 'smbd' 'mount.cifs' 'mount.mergerfs' 'unzip' 'mkfs.btrfs')
readonly NIMO_DEPANDS_PACKAGE=('wget' 'curl' 'smartmontools' 'parted' 'ntfs-3g' 'net-tools' 'udevil' 'samba' 'cifs-utils' 'mergerfs' 'unzip' 'btrfs-progs')

# SYSTEM INFO
PHYSICAL_MEMORY=$(LC_ALL=C free -m | awk '/Mem:/ { print $2 }')
readonly PHYSICAL_MEMORY

FREE_DISK_BYTES=$(LC_ALL=C df -P / | tail -n 1 | awk '{print $4}')
readonly FREE_DISK_BYTES

readonly FREE_DISK_GB=$((FREE_DISK_BYTES / 1024 / 1024))

LSB_DIST=$( ([ -n "${ID_LIKE}" ] && echo "${ID_LIKE}") || ([ -n "${ID}" ] && echo "${ID}"))
readonly LSB_DIST

DIST=$(echo "${ID}")
readonly DIST

UNAME_M="$(uname -m)"
readonly UNAME_M

UNAME_U="$(uname -s)"
readonly UNAME_U

readonly NIMO_CONF_PATH=/etc/nimoos/gateway.ini
readonly NIMO_UNINSTALL_URL="https://nimoos-s3-bucket.s3.us-east-2.amazonaws.com/get/nimoos-uninstall-v0.4.17.sh"
readonly NIMO_UNINSTALL_PATH=/usr/bin/nimoos-uninstall

# REQUIREMENTS CONF PATH
# Udevil
readonly UDEVIL_CONF_PATH=/etc/udevil/udevil.conf
readonly DEVMON_CONF_PATH=/etc/conf.d/devmon

# COLORS
readonly COLOUR_RESET='\e[0m'
readonly aCOLOUR=(
    '\e[38;5;154m' # green  	| Lines, bullets and separators
    '\e[1m'        # Bold white	| Main descriptions
    '\e[90m'       # Grey		| Credits
    '\e[91m'       # Red		| Update notifications Alert
    '\e[33m'       # Yellow		| Emphasis
)

readonly GREEN_LINE=" ${aCOLOUR[0]}─────────────────────────────────────────────────────$COLOUR_RESET"
readonly GREEN_BULLET=" ${aCOLOUR[0]}-$COLOUR_RESET"
readonly GREEN_SEPARATOR="${aCOLOUR[0]}:$COLOUR_RESET"

# NIMOOS VARIABLES
TARGET_ARCH=""
TMP_ROOT=/tmp/nimoos-installer
REGION="UNKNOWN"
NIMO_DOWNLOAD_DOMAIN="https://nimoos-s3-bucket.s3.us-east-2.amazonaws.com/"

trap 'onCtrlC' INT
onCtrlC() {
    echo -e "${COLOUR_RESET}"
    exit 1
}

###############################################################################
# Helpers                                                                     #
###############################################################################

#######################################
# Custom printing function
# Globals:
#   None
# Arguments:
#   $1 0:OK   1:FAILED  2:INFO  3:NOTICE
#   message
# Returns:
#   None
#######################################

Show() {
    # OK
    if (($1 == 0)); then
        echo -e "${aCOLOUR[2]}[$COLOUR_RESET${aCOLOUR[0]}  OK  $COLOUR_RESET${aCOLOUR[2]}]$COLOUR_RESET $2"
    # FAILED
    elif (($1 == 1)); then
        echo -e "${aCOLOUR[2]}[$COLOUR_RESET${aCOLOUR[3]}FAILED$COLOUR_RESET${aCOLOUR[2]}]$COLOUR_RESET $2"
        exit 1
    # INFO
    elif (($1 == 2)); then
        echo -e "${aCOLOUR[2]}[$COLOUR_RESET${aCOLOUR[0]} INFO $COLOUR_RESET${aCOLOUR[2]}]$COLOUR_RESET $2"
    # NOTICE
    elif (($1 == 3)); then
        echo -e "${aCOLOUR[2]}[$COLOUR_RESET${aCOLOUR[4]}NOTICE$COLOUR_RESET${aCOLOUR[2]}]$COLOUR_RESET $2"
    fi
}

Warn() {
    echo -e "${aCOLOUR[3]}$1$COLOUR_RESET"
}

GreyStart() {
    echo -e "${aCOLOUR[2]}\c"
}

ColorReset() {
    echo -e "$COLOUR_RESET\c"
}

# Clear Terminal
Clear_Term() {

    # Without an input terminal, there is no point in doing this.
    [[ -t 0 ]] || return

    # Printing terminal height - 1 newlines seems to be the fastest method that is compatible with all terminal types.
    lines=$(tput lines) i newlines
    local lines

    for ((i = 1; i < ${lines% *}; i++)); do newlines+='\n'; done
    echo -ne "\e[0m$newlines\e[H"

}

# Check file exists
exist_file() {
    if [ -e "$1" ]; then
        return 1
    else
        return 2
    fi
}

###############################################################################
# FUNCTIONS                                                                   #
###############################################################################



# 0 Download domain and region
#
# The download domain is the same worldwide — one bucket behind one CDN — so
# unlike upstream CasaOS there is no per-region artifact host to choose.
#
# REGION is still detected, but only to pick Docker's own package mirror during
# Install_Docker; it does not affect where NimoOS artifacts come from.
Get_Download_Url_Domain() {
    # ipconfig.io/country and ifconfig.io/country_code report the country code
    REGION=$(${sudo_cmd} curl --connect-timeout 2 -s ipconfig.io/country || echo "")
    if [ "${REGION}" = "" ]; then
       REGION=$(${sudo_cmd} curl --connect-timeout 2 -s https://ifconfig.io/country_code || echo "")
    fi
    NIMO_DOWNLOAD_DOMAIN="https://nimoos-s3-bucket.s3.us-east-2.amazonaws.com/"
}

# 1 Check Arch
Check_Arch() {
    case $UNAME_M in
    *aarch64*)
        TARGET_ARCH="arm64"
        ;;
    *64*)
        TARGET_ARCH="amd64"
        ;;
    *armv7*)
        TARGET_ARCH="arm-7"
        ;;
    *)
        Show 1 "Aborted, unsupported or unknown architecture: $UNAME_M"
        exit 1
        ;;
    esac
    Show 0 "Your hardware architecture is : $UNAME_M"
    NIMO_PACKAGES=(
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-Gateway/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-gateway-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-MessageBus/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-message-bus-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-UserService/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-user-service-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-LocalStorage/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-local-storage-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-AppManagement/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-app-management-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-CLI/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-cli-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-UI/releases/download/v1.9.4-alpha1/linux-all-nimoos-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-AppStore/releases/download/v1.0.9/linux-all-appstore-v1.0.9.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-AI/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-ai-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-Wiki/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-wiki-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-Search/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-search-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-Photos/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-photos-v1.9.4-alpha1.tar.gz"
        "${NIMO_DOWNLOAD_DOMAIN}nimoos/NimoOS-Terminal/releases/download/v1.9.4-alpha1/linux-${TARGET_ARCH}-nimoos-terminal-v1.9.4-alpha1.tar.gz"
    )
}

# PACKAGE LIST OF NIMOOS (make sure the services are in the right order)
NIMO_SERVICES=(
    "nimoos-gateway.service"
"nimoos-message-bus.service"
"nimoos-user-service.service"
"nimoos-local-storage.service"
"nimoos-app-management.service"
"nimoos-terminal.service"
"nimoos-ai.service"
"ollama.service"
"rclone.service"
"nimoos.service"  # must be the last one so update from UI can work
)

# 2 Check Distribution
Check_Distribution() {
    sType=0
    notice=""
    case $LSB_DIST in
    *debian*) ;;

    *ubuntu*) ;;

    *raspbian*) ;;

    *openwrt*)
        Show 1 "Aborted, OpenWrt cannot be installed using this script."
        exit 1
        ;;
    *alpine*)
        Show 1 "Aborted, Alpine installation is not yet supported."
        exit 1
        ;;
    *trisquel*) ;;

    *)
        sType=3
        notice="We have not tested it on this system and it may fail to install."
        ;;
    esac
    Show ${sType} "Your Linux Distribution is : ${DIST} ${notice}"

    if [[ ${sType} == 1 ]]; then
        select yn in "Yes" "No"; do
            case $yn in
            [yY][eE][sS] | [yY])
                Show 0 "Distribution check has been ignored."
                break
                ;;
            [nN][oO] | [nN])
                Show 1 "Already exited the installation."
                exit 1
                ;;
            esac
        done < /dev/tty # < /dev/tty is used to read the input from the terminal
    fi
}

# 3 Check OS
Check_OS() {
    if [[ $UNAME_U == *Linux* ]]; then
        Show 0 "Your System is : $UNAME_U"
    else
        Show 1 "This script is only for Linux."
        exit 1
    fi
}

# 4 Check Memory
Check_Memory() {
    if [[ "${PHYSICAL_MEMORY}" -lt "${MINIMUM_MEMORY}" ]]; then
        Show 1 "requires atleast 400MB physical memory."
        exit 1
    fi
    Show 0 "Memory capacity check passed."
}

# 5 Check Disk
Check_Disk() {
    if [[ "${FREE_DISK_GB}" -lt "${MINIMUM_DISK_SIZE_GB}" ]]; then
        echo -e "${aCOLOUR[4]}Recommended free disk space is greater than ${MINIMUM_DISK_SIZE_GB}GB, Current free disk space is ${aCOLOUR[3]}${FREE_DISK_GB}GB${COLOUR_RESET}${aCOLOUR[4]}.\nContinue installation?${COLOUR_RESET}"
        select yn in "Yes" "No"; do
            case $yn in
            [yY][eE][sS] | [yY])
                Show 0 "Disk capacity check has been ignored."
                break
                ;;
            [nN][oO] | [nN])
                Show 1 "Already exited the installation."
                exit 1
                ;;
            esac
        done < /dev/tty  # < /dev/tty is used to read the input from the terminal
    else
        Show 0 "Disk capacity check passed."
    fi
}

# Check Port Use
Check_Port() {
    TCPListeningnum=$(${sudo_cmd} netstat -an | grep ":$1 " | awk '$1 == "tcp" && $NF == "LISTEN" {print $0}' | wc -l)
    UDPListeningnum=$(${sudo_cmd} netstat -an | grep ":$1 " | awk '$1 == "udp" && $NF == "0.0.0.0:*" {print $0}' | wc -l)
    ((Listeningnum = TCPListeningnum + UDPListeningnum))
    if [[ $Listeningnum == 0 ]]; then
        echo "0"
    else
        echo "1"
    fi
}

# Get an available port
Get_Port() {
    CurrentPort=$(${sudo_cmd} cat ${NIMO_CONF_PATH} | grep HttpPort | awk '{print $3}')
    if [[ $CurrentPort == "$Port" ]]; then
        for PORT in {80..65536}; do
            if [[ $(Check_Port "$PORT") == 0 ]]; then
                Port=$PORT
                break
            fi
        done
    else
        Port=$CurrentPort
    fi
}

# Update package

Update_Package_Resource() {
    Show 2 "Updating package manager..."
    GreyStart
    if [ -x "$(command -v apk)" ]; then
        ${sudo_cmd} apk update
    elif [ -x "$(command -v apt-get)" ]; then
        ${sudo_cmd} apt-get update -qq
    elif [ -x "$(command -v dnf)" ]; then
        ${sudo_cmd} dnf check-update
    elif [ -x "$(command -v zypper)" ]; then
        ${sudo_cmd} zypper update
    elif [ -x "$(command -v yum)" ]; then
        ${sudo_cmd} yum update
    fi
    ColorReset
    Show 0 "Update package manager complete."
}

# Install depends package
Install_Depends() {
    for ((i = 0; i < ${#NIMO_DEPANDS_COMMAND[@]}; i++)); do
        cmd=${NIMO_DEPANDS_COMMAND[i]}
        if [[ ! -x $(${sudo_cmd} which "$cmd") ]]; then
            packagesNeeded=${NIMO_DEPANDS_PACKAGE[i]}
            Show 2 "Install the necessary dependencies: \e[33m$packagesNeeded \e[0m"
            GreyStart
            if [ -x "$(command -v apk)" ]; then
                ${sudo_cmd} apk add --no-cache "$packagesNeeded"
            elif [ -x "$(command -v apt-get)" ]; then
                ${sudo_cmd} apt-get -y -qq install "$packagesNeeded" --no-upgrade
            elif [ -x "$(command -v dnf)" ]; then
                ${sudo_cmd} dnf install "$packagesNeeded"
            elif [ -x "$(command -v zypper)" ]; then
                ${sudo_cmd} zypper install "$packagesNeeded"
            elif [ -x "$(command -v yum)" ]; then
                ${sudo_cmd} yum install -y "$packagesNeeded"
            elif [ -x "$(command -v pacman)" ]; then
                ${sudo_cmd} pacman -S "$packagesNeeded"
            elif [ -x "$(command -v paru)" ]; then
                ${sudo_cmd} paru -S "$packagesNeeded"
            else
                Show 1 "Package manager not found. You must manually install: \e[33m$packagesNeeded \e[0m"
            fi
            ColorReset
        fi
    done
}

Check_Dependency_Installation() {
    for ((i = 0; i < ${#NIMO_DEPANDS_COMMAND[@]}; i++)); do
        cmd=${NIMO_DEPANDS_COMMAND[i]}
        if [[ ! -x $(${sudo_cmd} which "$cmd") ]]; then
            packagesNeeded=${NIMO_DEPANDS_PACKAGE[i]}
            Show 1 "Dependency \e[33m$packagesNeeded \e[0m installation failed, please try again manually!"
            exit 1
        fi
    done
}

# Check Docker running
Check_Docker_Running() {
    for ((i = 1; i <= 3; i++)); do
        sleep 3
        if [[ ! $(${sudo_cmd} systemctl is-active docker) == "active" ]]; then
            Show 1 "Docker is not running, try to start"
            ${sudo_cmd} systemctl start docker
        else
            break
        fi
    done
}

#Check Docker Installed and version
Check_Docker_Install() {
    if [[ -x "$(command -v docker)" ]]; then
        Docker_Version=$(${sudo_cmd} docker version --format '{{.Server.Version}}')
        if [[ $? -ne 0 ]]; then
            Install_Docker
        elif [[ ${Docker_Version:0:2} -lt "${MINIMUM_DOCKER_VERSION}" ]]; then
            Show 1 "Recommended minimum Docker version is \e[33m${MINIMUM_DOCKER_VERSION}.xx.xx\e[0m,\Current Docker version is \e[33m${Docker_Version}\e[0m,\nPlease uninstall current Docker and rerun the NimoOS installation script."
            exit 1
        else
            Show 0 "Current Docker version is ${Docker_Version}."
        fi
    else
        Install_Docker
    fi
}

# Check Docker installed
Check_Docker_Install_Final() {
    if [[ -x "$(command -v docker)" ]]; then
        Docker_Version=$(${sudo_cmd} docker version --format '{{.Server.Version}}')
        if [[ $? -ne 0 ]]; then
            Install_Docker
        elif [[ ${Docker_Version:0:2} -lt "${MINIMUM_DOCKER_VERSION}" ]]; then
            Show 1 "Recommended minimum Docker version is \e[33m${MINIMUM_DOCKER_VERSION}.xx.xx\e[0m,\Current Docker version is \e[33m${Docker_Version}\e[0m,\nPlease uninstall current Docker and rerun the NimoOS installation script."
            exit 1
        else
            Show 0 "Current Docker version is ${Docker_Version}."
            Check_Docker_Running
        fi
    else
        Show 1 "Installation failed, please run 'curl -fsSL https://get.docker.com | bash' and rerun the NimoOS installation script."
        exit 1
    fi
}

#Install Docker
Install_Docker() {
    Show 2 "Install the necessary dependencies: \e[33mDocker \e[0m"
    if [[ ! -d "${PREFIX}/etc/apt/sources.list.d" ]]; then
        ${sudo_cmd} mkdir -p "${PREFIX}/etc/apt/sources.list.d"
    fi
    GreyStart
    # Always fetch the installer from Docker's own domain. The official script
    # takes --mirror itself, so a China mirror needs no third-party host; this
    # used to curl a domain nobody here controls straight into root's shell.
    if [[ "${REGION}" = "China" ]] || [[ "${REGION}" = "CN" ]]; then
        ${sudo_cmd} curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    else
        ${sudo_cmd} curl -fsSL https://get.docker.com | bash
    fi
    ColorReset
    if [[ $? -ne 0 ]]; then
        Show 1 "Installation failed, please try again."
        exit 1
    else
        Check_Docker_Install_Final
    fi
}

###############################################################################
# Docker API override for NimoOS                                             #
###############################################################################

Apply_Docker_API_Override() {
    Show 2 "Applying Docker API compatibility override for NimoOS..."
    local override_dir="/etc/systemd/system/docker.service.d"
    local override_file="${override_dir}/override.conf"

    ${sudo_cmd} mkdir -p "${override_dir}" || Show 3 "Failed to create ${override_dir} (non-fatal)."

    ${sudo_cmd} tee "${override_file}" >/dev/null <<'EOF'
[Service]
Environment=DOCKER_MIN_API_VERSION=1.24
EOF

    Show 0 "Docker API override written to ${override_file}"

    # Reload systemd and restart Docker to apply the override
    ${sudo_cmd} systemctl daemon-reload || Show 3 "systemd daemon-reload failed (non-fatal)."
    if ! ${sudo_cmd} systemctl restart docker; then
        Show 3 "Failed to restart Docker after API override. Please check 'systemctl status docker'."
    else
        Show 0 "Docker restarted with API override. NimoOS should now be able to talk to newer Docker versions."
    fi
}

###############################################################################
# Rclone & other components                                                  #
###############################################################################

#Install Rclone
Install_rclone_from_source() {
  ${sudo_cmd} wget -qO ./install.sh https://rclone.org/install.sh
  # Fetch rclone from its own official mirror.
  #
  # This used to rewrite downloads.rclone.org to a mirror: our bucket for CN,
  # and get.casaos.io otherwise. Both were wrong. The bucket has no rclone/
  # prefix, so the CN path 404'd; and get.casaos.io is CasaOS's own
  # infrastructure, which we should not be sending our users' downloads to.
  # rclone's official downloads are globally available, so no mirror is needed.
  ${sudo_cmd} chmod +x ./install.sh
  ${sudo_cmd} ./install.sh || {
    Show 1 "Installation failed, please try again."
    ${sudo_cmd} rm -rf install.sh
    exit 1
  }
  ${sudo_cmd} rm -rf install.sh
  Show 0 "Rclone v1.61.1 installed successfully."
}

Install_Rclone() {
  Show 2 "Install the necessary dependencies: Rclone"
  if [[ -x "$(command -v rclone)" ]]; then
    version=$(rclone --version 2>>errors | head -n 1)
    target_version="rclone v1.61.1"
    rclone1="${PREFIX}/usr/share/man/man1/rclone.1.gz"
    if [ "$version" != "$target_version" ]; then
      Show 3 "Will change rclone from $version to $target_version."
      rclone_path=$(command -v rclone)
      ${sudo_cmd} rm -rf "${rclone_path}"
      if [[ -f "$rclone1" ]]; then
        ${sudo_cmd} rm -rf "$rclone1"
      fi
      Install_rclone_from_source
    else
      Show 2 "Target version already installed."
    fi
  else
    Install_rclone_from_source
  fi
  ${sudo_cmd} systemctl enable rclone || Show 3 "Service rclone does not exist."
}

Install_Ollama() {
  if [[ -x "$(command -v ollama)" ]]; then
    Show 0 "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
    ${sudo_cmd} systemctl enable ollama 2>/dev/null || true
    return
  fi
  Show 2 "Installing Ollama..."
  ${sudo_cmd} curl -fsSL https://ollama.com/install.sh | ${sudo_cmd} sh
  ${sudo_cmd} systemctl enable ollama 2>/dev/null || true
  Show 0 "Ollama installed."
}

# The terminal component depends on tmux and ttyd.
# tmux comes from apt (true colour needs >= 3.2, satisfied by Debian 11+);
# ttyd is fetched per architecture (mirror first, GitHub as a fallback) into
# /usr/lib/nimoos/ttyd. Idempotent: skipped when already present.
Install_Terminal_Deps() {
    if ! command -v tmux >/dev/null 2>&1; then
        Show 2 "Installing tmux (terminal dependency)..."
        ${sudo_cmd} apt-get install -y tmux || Show 3 "tmux install failed; terminal will be degraded."
    fi
    if [ ! -x /usr/lib/nimoos/ttyd ]; then
        local ttyd_ver="1.7.7" ttyd_asset=""
        case "$(uname -m)" in
            x86_64)  ttyd_asset="ttyd.x86_64" ;;
            aarch64) ttyd_asset="ttyd.aarch64" ;;
            armv7l)  ttyd_asset="ttyd.arm" ;;
            *) Show 3 "Unsupported arch $(uname -m) for ttyd; terminal will be degraded." ;;
        esac
        if [ -n "${ttyd_asset}" ]; then
            local ttyd_gh="https://github.com/tsl0922/ttyd/releases/download/${ttyd_ver}/${ttyd_asset}"
            local ttyd_primary="${NIMO_DOWNLOAD_DOMAIN}ttyd/${ttyd_ver}/${ttyd_asset}"
            ${sudo_cmd} mkdir -p /usr/lib/nimoos
            Show 2 "Fetching ttyd ${ttyd_ver} (${ttyd_asset})..."
            if ${sudo_cmd} curl -fsSL --connect-timeout 20 -o /usr/lib/nimoos/ttyd "${ttyd_primary}" 2>/dev/null \
               || ${sudo_cmd} curl -fsSL --connect-timeout 20 -o /usr/lib/nimoos/ttyd "${ttyd_gh}"; then
                ${sudo_cmd} chmod 755 /usr/lib/nimoos/ttyd
            else
                Show 3 "Failed to fetch ttyd; terminal will be degraded."
            fi
        fi
    fi
}

# nimoos-agent now ships as an offline Docker container (see install-ai.sh and
# nimoos-stack-install.sh) brought up by Install_Stack below, so the core
# install no longer builds a host venv.

#Configuration Addons
Configuration_Addons() {
    Show 2 "Configuration NimoOS Addons"
    #Remove old udev rules
    if [[ -f "${PREFIX}/etc/udev/rules.d/11-usb-mount.rules" ]]; then
        ${sudo_cmd} rm -rf "${PREFIX}/etc/udev/rules.d/11-usb-mount.rules"
    fi

    if [[ -f "${PREFIX}/etc/systemd/system/usb-mount@.service" ]]; then
        ${sudo_cmd} rm -rf "${PREFIX}/etc/systemd/system/usb-mount@.service"
    fi

    #Udevil
    if [[ -f $PREFIX${UDEVIL_CONF_PATH} ]]; then

        # GreyStart
        # Add a devmon user
        USERNAME=devmon
        id ${USERNAME} &>/dev/null || {
            ${sudo_cmd} useradd -M -u 300 ${USERNAME}
            ${sudo_cmd} usermod -L ${USERNAME}
        }

        ${sudo_cmd} sed -i '/exfat/s/, nonempty//g' "$PREFIX"${UDEVIL_CONF_PATH}
        ${sudo_cmd} sed -i '/default_options/s/, noexec//g' "$PREFIX"${UDEVIL_CONF_PATH}
        ${sudo_cmd} sed -i '/^ARGS/cARGS="--mount-options nosuid,nodev,noatime --ignore-label EFI"' "$PREFIX"${DEVMON_CONF_PATH}

        # Add and start Devmon service
        GreyStart
        ${sudo_cmd} systemctl enable devmon@devmon
        ${sudo_cmd} systemctl start devmon@devmon
        ColorReset
        # ColorReset
    fi
}

# Download And Install NimoOS
DownloadAndInstallNimoOS() {
    if [ -z "${BUILD_DIR}" ]; then
        ${sudo_cmd} rm -rf ${TMP_ROOT}
        mkdir -p ${TMP_ROOT} || Show 1 "Failed to create temporary directory"
        TMP_DIR=$(${sudo_cmd} mktemp -d -p ${TMP_ROOT} || Show 1 "Failed to create temporary directory")

        pushd "${TMP_DIR}"

        for PACKAGE in "${NIMO_PACKAGES[@]}"; do
            Show 2 "Downloading ${PACKAGE}..."
            GreyStart
            ${sudo_cmd} wget -t 3 -q --show-progress -c  "${PACKAGE}" || Show 1 "Failed to download package"
            ColorReset
        done

        for PACKAGE_FILE in linux-*.tar.gz; do
            Show 2 "Extracting ${PACKAGE_FILE}..."
            GreyStart
            ${sudo_cmd} tar zxf "${PACKAGE_FILE}" || Show 1 "Failed to extract package"
            ColorReset
        done

        BUILD_DIR=$(${sudo_cmd} realpath -e "${TMP_DIR}"/build || Show 1 "Failed to find build directory")

        popd
    fi

    for SERVICE in "${NIMO_SERVICES[@]}"; do
        if ${sudo_cmd} systemctl --quiet is-active "${SERVICE}"; then
            Show 2 "Stopping ${SERVICE}..."
            GreyStart
            ${sudo_cmd} systemctl stop "${SERVICE}" || Show 3 "Service ${SERVICE} does not exist."
            ColorReset
        fi
    done
    
    # Migration scripts
    MIGRATION_SCRIPT_DIR="${BUILD_DIR}/scripts/migration/script.d"

    if [ -d "${MIGRATION_SCRIPT_DIR}" ]; then
        for MIGRATION_SCRIPT in "${MIGRATION_SCRIPT_DIR}"/*.sh; do
            # Ensure it is a file before running
            if [ -f "${MIGRATION_SCRIPT}" ]; then
                chmod +x "${MIGRATION_SCRIPT}"
                if [ -x "${MIGRATION_SCRIPT}" ]; then
                    echo "[ INFO ] Running ${MIGRATION_SCRIPT}..."
                    ${sudo_cmd} "${MIGRATION_SCRIPT}" || Show 1 "Failed to run ${MIGRATION_SCRIPT}"
                fi
            fi
        done
    fi


    Show 2 "Installing NimoOS..."
    SYSROOT_DIR=$(realpath -e "${BUILD_DIR}"/sysroot || Show 1 "Failed to find sysroot directory")

    # Generate manifest for uninstallation
    MANIFEST_FILE=${BUILD_DIR}/sysroot/var/lib/nimoos/manifest
    ${sudo_cmd} touch "${MANIFEST_FILE}" || Show 1 "Failed to create manifest file"

    # Setup scripts
    SETUP_SCRIPT_DIR="${BUILD_DIR}/scripts/setup/script.d"

    if [ -d "${SETUP_SCRIPT_DIR}" ]; then
        for SETUP_SCRIPT in "${SETUP_SCRIPT_DIR}"/*.sh; do
            if [ -f "${SETUP_SCRIPT}" ]; then
                chmod +x "${SETUP_SCRIPT}"
                # DO NOT RUN THEM HERE
            fi
        done
    fi
    
    # Copy files to system first so service scripts can find the sample files in /etc/
    GreyStart
    find "${SYSROOT_DIR}" -type f | ${sudo_cmd} cut -c ${#SYSROOT_DIR}- | ${sudo_cmd} cut -c 2- | ${sudo_cmd} tee "${MANIFEST_FILE}" >/dev/null || Show 1 "Failed to create manifest file"

    # Use tar rather than cp -rf: on usrmerge systems /lib, /bin and /sbin are
    # symlinks into /usr/*, so cp -rf fails replacing a symlink with a
    # directory; tar --keep-directory-symlink follows them and merges into /usr.
    ${sudo_cmd} tar -cf - -C "${SYSROOT_DIR}" . | ${sudo_cmd} tar -C / --keep-directory-symlink -xf - \
        || Show 1 "Failed to install NimoOS"
    ${sudo_cmd} systemctl daemon-reload || Show 3 "systemd daemon-reload failed (non-fatal)."
    ColorReset
    
    # NOW run the setup scripts from script.d since files are copied
    if [ -d "${SETUP_SCRIPT_DIR}" ]; then
        for SETUP_SCRIPT in "${SETUP_SCRIPT_DIR}"/*.sh; do
            if [ -x "${SETUP_SCRIPT}" ]; then
                echo "[ INFO ] Running ${SETUP_SCRIPT}..."
                ${sudo_cmd} "${SETUP_SCRIPT}" || Show 1 "Failed to run ${SETUP_SCRIPT}"
            fi
        done
    fi
    
    # NOTE: service.d/<svc>/<os>/setup-<svc>.sh is dispatched by the script.d
    # NN-setup-<svc>.sh entries above (each picks the right OS via /etc/os-release).
    # Do NOT re-run a raw `find service.d -name setup-*.sh` here: it would execute
    # every service's debian/arch/ubuntu variant (running Arch scripts on Debian)
    # and re-download the Photos ML bundle (~443MB) multiple times.

    UI_EVENTS_REG_SCRIPT=/etc/nimoos/start.d/register-ui-events.sh
    if [[ -f ${UI_EVENTS_REG_SCRIPT} ]]; then
        ${sudo_cmd} chmod +x $UI_EVENTS_REG_SCRIPT
    fi
    
    # No app store URL rewriting here. This used to sed
    # https://github.com/IceWhaleTech/_appstore/ into a NimoTech/_appstore/ prefix
    # on the download domain, but that pattern appears in no conf template we ship
    # (the sample lists jsDelivr and big-bear URLs instead), and that prefix does
    # not exist in the bucket. The rewrite was inherited dead code, and leaving it
    # in place would have pointed the store at a 404 the moment it did match.
    # The shipped store URLs live in app-management.conf.sample.

    #Download Uninstall Script
    if [[ -f $PREFIX/tmp/nimoos-uninstall ]]; then
        ${sudo_cmd} rm -rf "$PREFIX/tmp/nimoos-uninstall"
    fi
    ${sudo_cmd} curl -fsSLk "$NIMO_UNINSTALL_URL" >"$PREFIX/tmp/nimoos-uninstall"
    ${sudo_cmd} cp -rf "$PREFIX/tmp/nimoos-uninstall" $NIMO_UNINSTALL_PATH || {
        Show 1 "Download uninstall script failed, Please check if your internet connection is working and retry."
        exit 1
    }

    ${sudo_cmd} chmod +x $NIMO_UNINSTALL_PATH
    
    Install_Rclone
    Install_Ollama
    Install_Terminal_Deps
    # Install_Stack deploys nimoos-agent as a container; no venv here

    for SERVICE in "${NIMO_SERVICES[@]}"; do
        Show 2 "Starting ${SERVICE}..."
        GreyStart
        ${sudo_cmd} systemctl enable "${SERVICE}" 2>/dev/null || true   # enable at boot; new services are not enabled by default
        ${sudo_cmd} systemctl start "${SERVICE}" || Show 3 "Service ${SERVICE} does not exist."
        ColorReset
    done
}

Clean_Temp_Files() {
    Show 2 "Clean temporary files..."
    ${sudo_cmd} rm -rf "${TMP_DIR}" || Show 1 "Failed to clean temporary files"
}

Check_Service_status() {
    for SERVICE in "${NIMO_SERVICES[@]}"; do
        Show 2 "Checking ${SERVICE}..."
        if [[ $(${sudo_cmd} systemctl is-active "${SERVICE}") == "active" ]]; then
            Show 0 "${SERVICE} is running."
        else
            Show 1 "${SERVICE} is not running, Please reinstall."
            exit 1
        fi
    done
}

# Get the physical NIC IP
Get_IPs() {
    PORT=$(${sudo_cmd} cat ${NIMO_CONF_PATH} | grep port | sed 's/port=//')
    ALL_NIC=$($sudo_cmd ls /sys/class/net/ | grep -v "$(ls /sys/devices/virtual/net/)")
    for NIC in ${ALL_NIC}; do
        IP=$($sudo_cmd ifconfig "${NIC}" | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | sed -e 's/addr://g')
        if [[ -n $IP ]]; then
            if [[ "$PORT" -eq "80" ]]; then
                echo -e "${GREEN_BULLET} http://$IP (${NIC})"
            else
                echo -e "${GREEN_BULLET} http://$IP:$PORT (${NIC})"
            fi
        fi
    done
}

# Show Welcome Banner
Welcome_Banner() {
    NIMO_TAG=$(nimoos -v)

    echo -e "${GREEN_LINE}${aCOLOUR[1]}"
    echo -e " NimoOS ${NIMO_TAG}${COLOUR_RESET} is running at${COLOUR_RESET}${GREEN_SEPARATOR}"
    echo -e "${GREEN_LINE}"
    Get_IPs
    echo -e " Open your browser and visit the above address."
    echo -e "${GREEN_LINE}"
    echo -e ""
    echo -e " ${aCOLOUR[2]}NimoOS Project  : https://github.com/NimoTech/NimoOS"
    echo -e " ${aCOLOUR[2]}NimoOS Team     : https://github.com/NimoTech/NimoOS#maintainers"
    echo -e " ${aCOLOUR[2]}Website         : https://github.com/NimoTech/NimoOS"
    echo -e ""
    echo -e " ${COLOUR_RESET}${aCOLOUR[1]}Uninstall       ${COLOUR_RESET}: nimoos-uninstall"
    echo -e "${COLOUR_RESET}"
}

# Install retrieval / AI stack (qdrant/parser/search/wiki/photos/ai) in one go
# Use the self-contained nimoos-stack-install.sh so the user does not have to
# run a second script. Set NIMO_SKIP_STACK=1 to skip it; the stack is heavy
# (Python venv, models, Ollama).
Install_Stack() {
    if [[ "${NIMO_SKIP_STACK:-0}" == "1" ]]; then
        Show 3 "Skipping retrieval/AI stack (NIMO_SKIP_STACK=1)."
        return
    fi
    Show 2 "Installing retrieval/AI stack: qdrant/parser/search/wiki/photos/ai"
    Show 3 "  (heavy: Python venv + ~3GB models + Ollama; set NIMO_SKIP_STACK=1 to skip)"
    local stack_url="${NIMO_DOWNLOAD_DOMAIN}get/nimoos-stack-install.sh"
    local stack_sh="${TMP_ROOT}/nimoos-stack-install.sh"
    ${sudo_cmd} mkdir -p "${TMP_ROOT}"
    if ! ${sudo_cmd} curl -fsSL "${stack_url}" -o "${stack_sh}"; then
        Show 3 "Failed to download stack installer (${stack_url}), skipping stack."
        return
    fi
    # Non-fatal: a stack failure does not affect the installed core
    ${sudo_cmd} bash "${stack_sh}" --start --continue \
        || Show 3 "Stack install reported errors (non-fatal); core NimoOS is installed."
}

###############################################################################
# Main                                                                        #
###############################################################################

#Usage
usage() {
    cat <<-EOF
		Usage: install.sh [options]
		Valid options are:
		    -p <build_dir>          Specify build directory (Local install)
		    -h                      Show this help message and exit
	EOF
    exit "$1"
}

while getopts ":p:h" arg; do
    case "$arg" in
    p)
        BUILD_DIR=$OPTARG
        ;;
    h)
        usage 0
        ;;
    *)
        usage 1
        ;;
    esac
done

# Step 0 : Get Download Url Domain
Get_Download_Url_Domain
# Step 1: Check ARCH
Check_Arch

# Step 2: Check OS
Check_OS

# Step 3: Check Distribution
Check_Distribution

# Step 4: Check System Required
Check_Memory
Check_Disk

# Step 5: Install Depends
Update_Package_Resource
Install_Depends
Check_Dependency_Installation

# Step 6: Check And Install Docker
Check_Docker_Install
Apply_Docker_API_Override

# Step 7: Configuration Addon
Configuration_Addons

# Step 8: Download And Install NimoOS
DownloadAndInstallNimoOS

# Step 9: Check Service Status
Check_Service_status

# Step 10: Install retrieval / AI stack (one-shot, skip with NIMO_SKIP_STACK=1)
Install_Stack

# Step 11: Clear Term and Show Welcome Banner
Welcome_Banner
