set -euo pipefail
set -x

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root!" >&2
  exit 1
fi

ip -n "$PIA_NETNS" link delete dev "$PIA_INTERFACE" || true

privkey="$(wg genkey)"
pubkey="$(wg pubkey <<<"$privkey")"

response="$(curl --silent --retry 5 --connect-timeout 5 'https://serverlist.piaservers.net/vpninfo/servers/v6' | head -n1)"
mapfile -t ports < <(jq --raw-output '.groups.wg[].ports[]' <<<"$response")
# shellcheck disable=SC2016
mapfile -t ips < <(jq --raw-output --arg region "$PIA_REGION" '.regions[] | select(.id == $region) | .servers.wg[].ip' <<<"$response")
# shellcheck disable=SC2016
mapfile -t names < <(jq --raw-output --arg region "$PIA_REGION" '.regions[] | select(.id == $region) | .servers.wg[].cn' <<<"$response")

# TODO: randomize?
port="${ports[0]}"
ip="${ips[0]}"
name="${names[0]}"

if test -n "${PIA_USER_FILE:-}"; then
  PIA_USER="$(<"$PIA_USER_FILE")"
fi
if test -n "${PIA_USER_CMD:-}"; then
  PIA_USER="$("$0" -c "$PIA_USER_CMD")"
fi

if test -n "${PIA_PASS_FILE:-}"; then
  PIA_PASS="$(<"$PIA_PASS_FILE")"
fi
if test -n "${PIA_PASS_CMD:-}"; then
  PIA_PASS="$("$0" -c "$PIA_PASS_CMD")"
fi

# FIXME this token will eventually expire because of not refreshing the
# endpoint, causing pia-wg-pf to fail to update ports
# https://github.com/pia-foss/manual-connections/blob/master/get_token.sh
response="$(curl --silent --retry 5 --connect-timeout 5 --user "$PIA_USER:$PIA_PASS" 'https://www.privateinternetaccess.com/gtoken/generateToken')"
if [ "$(jq --raw-output '.status' <<<"$response")" != 'OK' ]; then
  echo 'generateToken error!' >&2
  echo "$response" >&2
  exit 1
fi
token="$(jq --raw-output '.token' <<<"$response")"

response="$(
  curl --silent --retry 5 --connect-timeout 5 --get \
    --connect-to "$name::$ip:" \
    --cacert "$PIA_CERT" \
    --data-urlencode "pt=$token" \
    --data-urlencode "pubkey=$pubkey" \
    "https://$name:$port/addKey"
)"
if [ "$(jq --raw-output '.status' <<<"$response")" != 'OK' ]; then
  echo 'addKey error!' >&2
  echo "$response" >&2
  exit 1
fi
myip="$(jq --raw-output '.peer_ip' <<<"$response")"
vip="$(jq --raw-output '.server_vip' <<<"$response")"
port="$(jq --raw-output '.server_port' <<<"$response")"
servkey="$(jq --raw-output '.server_key' <<<"$response")"
# mapfile -t dnss < <(jq --raw-output '.dns_servers[]' <<<"$response")

ip netns add "$PIA_NETNS" || true
ip -n "$PIA_NETNS" link set lo up || true

ip link add "$PIA_INTERFACE" type wireguard
ip link set "$PIA_INTERFACE" netns "$PIA_NETNS"

ip -n "$PIA_NETNS" link set dev "$PIA_INTERFACE" up
ip netns exec "$PIA_NETNS" wg set "$PIA_INTERFACE" private-key <(cat <<<"$privkey") peer "$servkey" endpoint "$ip:$port" allowed-ips '0.0.0.0/0'
ip -n "$PIA_NETNS" addr replace "$myip" dev "$PIA_INTERFACE"
ip -n "$PIA_NETNS" route add default dev "$PIA_INTERFACE"

ip netns exec "$PIA_NETNS" ping -n -c 1 -w 5 -s 1024 "$vip"

rm /tmp/pia.info.sh &>/dev/null || true # rm file that may have wrong perms that clobbering wont resolve.
umask 077
cat << EOF >/tmp/pia.info.sh
ip='$ip'
myip='$myip'
name='$name'
token='$token'
EOF
