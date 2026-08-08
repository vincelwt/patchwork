#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

user=${PATCHWORK_USER:-${SUDO_USER:-patchwork}}
bin=${PATCHWORK_BIN:-/home/$user/.local/bin/patchwork-relay}
service=${PATCHWORK_SERVICE:-patchwork.service}
repo=${PATCHWORK_REPOSITORY:-vincelwt/patchwork}

install -d -m 755 /usr/local/sbin /var/lib/patchwork-relay-update
cat >/usr/local/sbin/patchwork-relay-update <<EOF
#!/bin/sh
set -eu
repo='$repo'
bin='$bin'
service='$service'
state=/var/lib/patchwork-relay-update/version
release=\$(curl -fsSL --retry 3 "https://api.github.com/repos/\$repo/releases/latest" | jq -r .tag_name)
[ -n "\$release" ] && [ "\$release" != null ]
[ "\$(cat "\$state" 2>/dev/null || true)" = "\$release" ] && exit 0
tmp=\$(mktemp -d)
trap 'rm -rf "\$tmp"' EXIT
base="https://github.com/\$repo/releases/download/\$release"
curl -fsSL --retry 3 "\$base/patchwork-relay-linux-x86_64" -o "\$tmp/patchwork-relay"
curl -fsSL --retry 3 "\$base/patchwork-relay-linux-x86_64.sha256" -o "\$tmp/checksum"
(cd "\$tmp" && sed 's/patchwork-relay-linux-x86_64/patchwork-relay/' checksum | sha256sum -c -)
install -m 755 -o '$user' -g '$user' "\$tmp/patchwork-relay" "\$bin.next"
mv -f "\$bin.next" "\$bin"
systemctl restart "\$service"
printf '%s\n' "\$release" >"\$state"
EOF
chmod 755 /usr/local/sbin/patchwork-relay-update

cat >/etc/systemd/system/patchwork-relay-update.service <<'EOF'
[Unit]
Description=Update Patchwork relay from the latest GitHub release
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/patchwork-relay-update
EOF

cat >/etc/systemd/system/patchwork-relay-update.timer <<'EOF'
[Unit]
Description=Check for Patchwork relay updates hourly

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now patchwork-relay-update.timer
printf 'Patchwork relay updates enabled for %s\n' "$bin"
