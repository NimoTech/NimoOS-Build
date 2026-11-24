#!/usr/bin/env bash
# parser-unit.sh — keep the installed nimoos-parser systemd unit equal to the
# repo template. Sourced by deploy-parser.sh.
#
# Until 2026-09-04 deploy-parser.sh synced code only; the unit installed at
# first-install time stayed frozen, so the memory ceiling added to the template
# after the 2026-07-28 OOM never reached a machine that had been installed
# earlier (143 ran without MemoryMax until it was copied by hand). This makes
# the unit part of every deploy.
#
#   sync_parser_unit <template> <installed-path> <unit-name>
#     stdout: "unchanged" | "updated"
#     rc 0  installed unit equals the template (possibly after copying it)
#     rc 1  template missing — nothing touched
#     rc 2  systemd reports no memory ceiling for the unit (MemoryMax empty
#           or infinity): the template is wrong or the daemon-reload did not
#           take; do not start the service blindly.
#     rc 3  could not install the template (mkdir/cp/daemon-reload failed)
#     rc 4  the template delegates its cgroup but systemd reports Delegate
#           other than yes: the batch cgroup cannot be created. A template
#           that does not delegate (a Parser release before dynamic
#           allocation phase 2, or a rollback to one) is not held to this, so
#           an older Parser can still install its own unit.
#
#   NIMO_SUDO  privilege prefix for cp/systemctl (default "sudo"; empty = none)
#
#   parser_unit_template_delegates <template>
#     rc 0 when the template turns cgroup delegation on (the last Delegate=
#     assignment is a true boolean or a controller list), rc 1 otherwise.
#     install-parser.sh keeps an inline copy (unit_template_delegates) because
#     a `curl | bash` install fetches only a fixed list of sub-scripts;
#     install-parser.unit.test.sh checks the two copies agree.

parser_unit_template_delegates() {
    [[ -f "$1" ]] || return 1
    awk '
        /^[ \t]*[#;]/ { next }
        /^[ \t]*Delegate[ \t]*=/ {
            v = $0
            sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            last = tolower(v)
        }
        END { exit (last == "" || last == "no" || last == "false" || last == "off" || last == "0") ? 1 : 0 }
    ' "$1"
}

sync_parser_unit() {
    local src="$1" dst="$2" unit="$3"
    local sudo_cmd="${NIMO_SUDO-sudo}"
    [[ -f "$src" ]] || { echo "unit template missing: $src" >&2; return 1; }

    local state="unchanged"
    if ! cmp -s "$src" "$dst" 2>/dev/null; then
        ${sudo_cmd} mkdir -p "$(dirname "$dst")" || return 3
        ${sudo_cmd} cp "$src" "$dst" || return 3
        ${sudo_cmd} systemctl daemon-reload || return 3
        state="updated"
    fi

    local mem_max
    mem_max="$(${sudo_cmd} systemctl show "$unit" -p MemoryMax --value 2>/dev/null)"
    if [[ -z "$mem_max" || "$mem_max" == "infinity" ]]; then
        echo "the unit's memory ceiling is not in effect (MemoryMax=${mem_max:-empty}); check $dst" >&2
        return 2
    fi
    if parser_unit_template_delegates "$src"; then
        local delegate
        delegate="$(${sudo_cmd} systemctl show "$unit" -p Delegate --value 2>/dev/null)"
        if [[ "$delegate" != "yes" ]]; then
            echo "the template delegates the unit's cgroup but systemd does not (Delegate=${delegate:-empty}); check $dst and its drop-ins" >&2
            return 4
        fi
    fi
    echo "$state"
    return 0
}
