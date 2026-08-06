#!/bin/bash
#
#           NimoOS Uninstaller Script v0.4.16#
#   GitHub: https://github.com/NimoTech/NimoOS
#   Issues: https://github.com/NimoTech/NimoOS/issues
#   Requires: bash, mv, rm, tr, grep, sed
#
#   This script will remove NimoOS from your system.
#
#   This only work on  Linux systems. Please
#   open an issue if you notice any bugs.
#
set -e
clear

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

###############################################################################
# Golbals                                                                     #
###############################################################################

# Not every platform has or needs sudo (https://termux.com/linux.html)
((EUID)) && sudo_cmd="sudo"

readonly NIMO_SERVICES=(
    "nimoos-gateway.service"
    "nimoos-message-bus.service"
    "nimoos-user-service.service"
    "nimoos-local-storage.service"
    "nimoos-app-management.service"
    "nimoos-terminal.service"
    "rclone.service"
    "nimoos.service"  # must be the last one so update from UI can work
    "devmon@devmon.service"
)

readonly NIMO_PATH=/var/lib/nimoos
readonly NIMO_LIB_PATH=/usr/lib/nimoos
readonly NIMO_EXEC=nimoos
readonly NIMO_BIN=/usr/bin/nimoos
readonly NIMO_SERVICE_USR=/usr/lib/systemd/system/nimoos.service
readonly NIMO_SERVICE_LIB=/lib/systemd/system/nimoos.service
readonly NIMO_SERVICE_ETC=/etc/systemd/system/nimoos.service
readonly NIMO_ADDON1=/etc/udev/rules.d/11-usb-mount.rules
readonly NIMO_ADDON2=/etc/systemd/system/usb-mount@.service
readonly NIMO_UNINSTALL_PATH=/usr/bin/nimoos-uninstall

# New Nimo Files
readonly MANIFEST=/var/lib/nimoos/manifest
readonly NIMO_CONF_PATH_OLD=/etc/nimoos.conf
readonly NIMO_CONF_PATH=/etc/nimoos
readonly NIMO_RUN_PATH=/var/run/nimoos
readonly NIMO_USER_FILES=/var/lib/nimoos
readonly NIMO_LOGS_PATH=/var/log/nimoos
readonly NIMO_HELPER_PATH=/usr/share/nimoos

readonly COLOUR_RESET='\e[0m'
readonly aCOLOUR=(
    '\e[38;5;154m' # green  	| Lines, bullets and separators
    '\e[1m'        # Bold white	| Main descriptions
    '\e[90m'       # Grey		| Credits
    '\e[91m'       # Red		| Update notifications Alert
    '\e[33m'       # Yellow		| Emphasis
)

UNINSTALL_ALL_CONTAINER=false
REMOVE_IMAGES="none"
REMOVE_APP_DATA=false

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

trap 'onCtrlC' INT
onCtrlC() {
    echo -e "${COLOUR_RESET}"
    exit 1
}

Detecting_NimoOS() {
    if [[ ! -x "$(command -v ${NIMO_EXEC})" ]]; then
        Show 2 "NimoOS is not detected, exit the script."
        exit 1
    else
        Show 0 "This script will delete the containers you no longer use, and the NimoOS configuration files."
    fi
}

# docker takes one id per argument. Quoting the command substitution passes the
# whole newline-separated list as a single argument, and the daemon answers
#   Error response from daemon: page not found
# so nothing is ever removed. xargs splits it and also does the right thing when
# the list is empty.
Unistall_Container() {
    if [[ ${UNINSTALL_ALL_CONTAINER} == true && "$(${sudo_cmd} docker ps -aq)" != "" ]]; then
        Show 2 "Start deleting containers."
        ${sudo_cmd} docker ps -aq | xargs -r ${sudo_cmd} docker stop || Show 1 "Failed to stop containers."
        ${sudo_cmd} docker ps -aq | xargs -r ${sudo_cmd} docker rm || Show 1 "Failed to delete all containers."
    fi
}

Remove_Images() {
    if [[ ${REMOVE_IMAGES} == "all" && "$(${sudo_cmd} docker images -q)" != "" ]]; then
        Show 2 "Start deleting all images."
        ${sudo_cmd} docker images -q | sort -u | xargs -r ${sudo_cmd} docker rmi -f || Show 1 "Failed to delete all images."
    elif [[ ${REMOVE_IMAGES} == "unuse" && "$(${sudo_cmd} docker images -q)" != "" ]]; then
        Show 2 "Start deleting unuse images."
        ${sudo_cmd} docker image prune -af || Show 1 "Failed to delete unuse images."
    fi
}

# Tear down the nimoos-agent Docker container. It is a NimoOS system container, so
# remove it regardless of the "delete all containers" choice above. Also clean up
# the legacy host-venv systemd unit if it lingers from older installs.
Teardown_Agent_Container() {
    command -v docker >/dev/null 2>&1 || return 0
    local app_dir="/var/lib/nimoos/apps/nimoos-agent"
    local compose="${app_dir}/docker-compose.yml"
    Show 2 "Removing nimoos-agent container..."
    if [[ -f "${compose}" ]]; then
        ${sudo_cmd} docker compose -p nimoos-agent -f "${compose}" down 2>/dev/null || true
    else
        ${sudo_cmd} docker rm -f nimoos-agent-agent-1 2>/dev/null || true
    fi
    ${sudo_cmd} docker rmi localhost/nimoos-agent:bundled 2>/dev/null || true
    ${sudo_cmd} systemctl disable --now nimoos-agent.service 2>/dev/null || true
    Show 0 "nimoos-agent container removed."
}

Uninstall_NimoOS() {

    # NIMO_SERVICES is a hand-kept list and it has fallen behind: ai, wiki,
    # search, photos, parser, openvino, local-storage-first and wiki-summary
    # were all left running by it. Discover the rest instead of adding seven
    # more names that the next new service will again be missing from.
    # nimoos.service stays last, for the reason noted on the list.
    local discovered
    discovered="$(systemctl list-unit-files 'nimoos-*' --no-legend 2>/dev/null | awk '{print $1}')"
    local -a all_services=()
    local s
    for s in ${discovered}; do
        [[ " ${NIMO_SERVICES[*]} " == *" ${s} "* ]] || all_services+=("${s}")
    done
    all_services+=("${NIMO_SERVICES[@]}")

    for SERVICE in "${all_services[@]}"; do
        Show 2 "Stopping ${SERVICE}..."
        systemctl stop "${SERVICE}" || Show 3 "Service ${SERVICE} does not exist."
        systemctl disable "${SERVICE}" || Show 3 "Service ${SERVICE} does not exist."
    done

    # The manifest lists every file the installer laid down — 711 of them on a
    # full install, including all the binaries in /usr/bin and every systemd
    # unit. It lives inside NIMO_PATH, and the block that reads it used to run
    # *after* the rm -rf below, so by then it was gone and its `if [[ -f ]]`
    # guard silently skipped everything. Every uninstall left the whole install
    # on disk. Copy it out first, then use the copy.
    local manifest_copy=""
    if [[ -f ${MANIFEST} ]]; then
        manifest_copy="$(mktemp)"
        ${sudo_cmd} cat "${MANIFEST}" > "${manifest_copy}"
    fi

    # The agent's audit log is append-only (chattr +a) on purpose, so that a
    # compromised agent cannot rewrite its own trail. Nothing can unlink it
    # while that attribute is set, not even root, and the rm -rf below fails
    # with "Operation not permitted" — taking the whole directory removal with
    # it. Uninstalling is the one time the attribute has to come off.
    if [[ -d ${NIMO_PATH} ]] && command -v chattr >/dev/null 2>&1; then
        ${sudo_cmd} find "${NIMO_PATH}" -type f -exec chattr -a -i {} + 2>/dev/null
    fi

    # Remove Service file
    if [[ -f ${NIMO_SERVICE_USR} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_SERVICE_USR}
    fi

    if [[ -f ${NIMO_SERVICE_LIB} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_SERVICE_LIB}
    fi

    if [[ -f ${NIMO_SERVICE_ETC} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_SERVICE_ETC}
    fi

    # Old NimoOS Files
    if [[ -d ${NIMO_PATH} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_PATH} || Show 1 "Failed to delete NimoOS files."
    fi

    if [[ -f ${NIMO_ADDON1} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_ADDON1}
    fi

    if [[ -f ${NIMO_ADDON2} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_ADDON2}
    fi

    if [[ -f ${NIMO_BIN} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_BIN} || Show 1 "Failed to delete NimoOS exec file."
    fi

    # New NimoOS Files

    if [[ -f ${NIMO_CONF_PATH_OLD} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_CONF_PATH_OLD}
    fi

    if [[ -n ${manifest_copy} ]]; then
        while read -r line; do
            if [[ -f ${line} ]]; then
                ${sudo_cmd} rm -rf "${line}"
            fi
        done < "${manifest_copy}"
        rm -f "${manifest_copy}"
        # Unit files were among them; forget the ones that just vanished.
        ${sudo_cmd} systemctl daemon-reload 2>/dev/null || true
    fi

    if [[ -d ${NIMO_USER_FILES} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_USER_FILES}/[0-9]*
        ${sudo_cmd} rm -rf ${NIMO_USER_FILES}/db
        ${sudo_cmd} rm -rf ${NIMO_USER_FILES}/*.db
    fi

    ${sudo_cmd} rm -rf ${NIMO_USER_FILES}/www
    ${sudo_cmd} rm -rf ${NIMO_USER_FILES}/migration

    if [[ -d ${NIMO_HELPER_PATH} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_HELPER_PATH}
    fi

    if [[ -d ${NIMO_LOGS_PATH} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_LOGS_PATH}
    fi

    if [[ ${REMOVE_APP_DATA} = true ]]; then
        $sudo_cmd rm -fr /DATA/AppData || Show 1 "Failed to delete AppData."
    fi

    if [[ -d ${NIMO_CONF_PATH} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_CONF_PATH}
    fi

    # /usr/lib/nimoos holds the bundled ttyd binary (terminal service); not covered by
    # the manifest or /var/lib cleanup. tmux is a system apt package and is left as-is.
    if [[ -d ${NIMO_LIB_PATH} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_LIB_PATH}
    fi

    if [[ -d ${NIMO_RUN_PATH} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_RUN_PATH}
    fi

    if [[ -f ${NIMO_UNINSTALL_PATH} ]]; then
        ${sudo_cmd} rm -rf ${NIMO_UNINSTALL_PATH}
    fi

}

# Check user
if [ "$(id -u)" -ne 0 ];then
    Show 1 "Please execute with a root user, or use ${aCOLOUR[4]}sudo nimoos-uninstall${COLOUR_RESET}."
    exit 1
fi


#Inputs

Detecting_NimoOS

while true; do
    echo -n -e "         ${aCOLOUR[4]}Do you want delete all containers? Y/n :${COLOUR_RESET}"
    read -r input
    case $input in
    [yY][eE][sS] | [yY])
        UNINSTALL_ALL_CONTAINER=true
        break
        ;;
    [nN][oO] | [nN])
        UNINSTALL_ALL_CONTAINER=false
        break
        ;;
    *)
        Warn "         Invalid input..."
        ;;
    esac
done < /dev/tty

if [[ ${UNINSTALL_ALL_CONTAINER} == true ]]; then
    while true; do
        echo -n -e "         ${aCOLOUR[4]}Do you want delete all images? Y/n :${COLOUR_RESET}"
        read -r input
        case $input in
        [yY][eE][sS] | [yY])
            REMOVE_IMAGES="all"
            break
            ;;
        [nN][oO] | [nN])
            REMOVE_IMAGES="none"
            break
            ;;
        *)
            Warn "         Invalid input..."
            ;;
        esac
    done < /dev/tty

    while true; do
        echo -n -e "         ${aCOLOUR[4]}Do you want delete all AppData of NimoOS? Y/n :${COLOUR_RESET}"
        read -r input
        case $input in
        [yY][eE][sS] | [yY])
            REMOVE_APP_DATA=true
            break
            ;;
        [nN][oO] | [nN])
            REMOVE_APP_DATA=false
            break
            ;;
        *)
            Warn "         Invalid input..."
            ;;
        esac
    done < /dev/tty
else
    while true; do
        echo -n -e "         ${aCOLOUR[4]}Do you want to delete all images that are not used by the container? Y/n :${COLOUR_RESET}"
        read -r input
        case $input in
        [yY][eE][sS] | [yY])
            REMOVE_IMAGES="unuse"
            break
            ;;
        [nN][oO] | [nN])
            REMOVE_IMAGES="none"
            break
            ;;
        *)
            Warn "         Invalid input..."
            ;;
        esac
    done < /dev/tty
fi


Unistall_Container
Remove_Images
Teardown_Agent_Container
Uninstall_NimoOS

Show 0 "NimoOS uninstall completely."


