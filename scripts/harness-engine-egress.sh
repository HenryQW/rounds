#!/bin/sh
# Run inside the pinned Dagger engine container.
set -eu

if [ "$#" -ne 2 ] && [ "$#" -ne 4 ]; then
    echo 'Usage: harness-engine-egress.sh start|check network-name [proxy-ip proxy-port]' >&2
    exit 2
fi
mode=$1
network=$2
proxy=${3-}
port=${4-}
case "$network" in
    ''|*[!a-z0-9]*) exit 2 ;;
esac
[ "${#network}" -le 14 ]
if [ "$#" -eq 4 ]; then
    printf '%s\n' "$proxy" | awk -F. '
        NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++) if ($i !~ /^(0|[1-9][0-9]?[0-9]?)$/ || $i > 255) exit 1 }
    '
    case "$port" in
        ''|0*|*[!0-9]*) exit 2 ;;
    esac
    [ "$port" -le 65535 ]
fi

bridge=${network}0
chain=ROUNDS-WORKER-EGRESS
config=/etc/dagger/engine.json
settings='{"security":{"insecureRootCapabilities":false}}'
startup_stamp=/run/rounds-egress.sha256

check_rules() {
    ipv4=$(iptables -w 5 -t raw -S PREROUTING)
    ipv6=$(ip6tables -w 5 -t raw -S PREROUTING)
    worker=$(iptables -w 5 -t raw -S "$chain")
    expected="-N $chain"
    if [ -n "$proxy" ]; then
        expected="$expected
-A $chain -d $proxy/32 -p tcp -m tcp --dport $port -j RETURN"
    fi
    [ "$(printf '%s\n' "$ipv4" | sed -n '2p')" = "-A PREROUTING -i $bridge -j $chain" ] &&
    [ "$(printf '%s\n' "$ipv6" | sed -n '2p')" = "-A PREROUTING -i $bridge -j DROP" ] &&
    [ "$worker" = "$expected
-A $chain -j DROP" ]
}

case "$mode" in
    start)
        umask 077
        mkdir -p /etc/dagger
        printf '%s\n' "$settings" > "$config"
        sha256sum "$0" > "$startup_stamp"
        iptables -w 5 -t raw -N "$chain"
        if [ -n "$proxy" ]; then
            iptables -w 5 -t raw -A "$chain" -d "$proxy" -p tcp --dport "$port" -j RETURN
        fi
        iptables -w 5 -t raw -A "$chain" -j DROP
        iptables -w 5 -t raw -I PREROUTING 1 -i "$bridge" -j "$chain"
        ip6tables -w 5 -t raw -I PREROUTING 1 -i "$bridge" -j DROP
        check_rules
        exec /usr/local/bin/dagger-entrypoint.sh --network-name "$network"
        ;;
    check)
        if [ "$(cat /proc/1/comm)" != dagger-engine ] ||
            [ ! -S /run/dagger/engine.sock ] ||
            ! ip link show dev "$bridge" >/dev/null 2>&1 ||
            ! sha256sum -c "$startup_stamp" >/dev/null ||
            [ "$(cat "$config")" != "$settings" ] ||
            ! check_rules; then
            echo 'Dagger engine is not ready with the expected worker egress rules.' >&2
            exit 1
        fi
        ;;
    *) exit 2 ;;
esac
