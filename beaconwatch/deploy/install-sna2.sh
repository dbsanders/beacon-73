#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd "$(dirname "$0")/.." && pwd)
nginx_site=/etc/nginx/sites-available/k6bat.com.conf
backup_path="${nginx_site}.beaconwatch-backup-$(date -u +%Y%m%dT%H%M%SZ)"
country_data=$(mktemp)
trap 'rm -f "$country_data"' EXIT

if [[ $(id -u) -ne 0 ]]; then
  echo "Run this installer with sudo on sna2." >&2
  exit 1
fi

if [[ $(hostname) != sna2 ]]; then
  echo "Refusing to install: expected hostname sna2." >&2
  exit 1
fi

if ! cmp -s "$nginx_site" "$source_dir/deploy/k6bat.com.conf.expected"; then
  echo "Refusing to replace $nginx_site because it changed after inspection." >&2
  diff -u "$source_dir/deploy/k6bat.com.conf.expected" "$nginx_site" || true
  exit 1
fi

install -d -o root -g root -m 0755 /opt/beaconwatch
install -d -o root -g root -m 0755 /opt/beaconwatch/web
install -d -o bret -g www-data -m 0750 /var/lib/beaconwatch
install -o root -g root -m 0755 "$source_dir/beaconwatch.py" /opt/beaconwatch/beaconwatch.py
install -o root -g root -m 0644 "$source_dir/web/index.html" /opt/beaconwatch/web/index.html
install -o root -g root -m 0644 "$source_dir/web/styles.css" /opt/beaconwatch/web/styles.css
install -o root -g root -m 0644 "$source_dir/web/app.js" /opt/beaconwatch/web/app.js
curl --fail --silent --show-error --location \
  https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/countries-50m.json \
  --output "$country_data"
echo "04342cdc1e3016bcd7db1630de95684d67b79fe3c8c460321e87aef469502394  $country_data" | sha256sum --check --status
install -o root -g root -m 0644 "$country_data" /opt/beaconwatch/web/countries-50m.json
install -o root -g root -m 0644 "$source_dir/deploy/beaconwatch.service" /etc/systemd/system/beaconwatch.service

cp --preserve=mode,ownership,timestamps "$nginx_site" "$backup_path"
install -o root -g root -m 0644 "$source_dir/deploy/k6bat.com.conf" "$nginx_site"
if ! nginx -t; then
  cp --preserve=mode,ownership,timestamps "$backup_path" "$nginx_site"
  echo "nginx validation failed; restored $backup_path" >&2
  exit 1
fi

systemctl daemon-reload
systemctl enable --now beaconwatch.service
systemctl reload nginx

echo "BeaconWatch installed. nginx backup: $backup_path"
systemctl --no-pager --full status beaconwatch.service
