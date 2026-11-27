# BeaconWatch

BeaconWatch is a privacy-minimized APRS-IS receiver and map for Beacon 73. It connects to the worldwide filtered feed at `rotate.aprs2.net:14580` with the APRS-IS unproto/TOCALL filter `u/APB730`, and it also rejects non-`APB730` packets locally.

The database deliberately retains only one base callsign and coordinate pair per operator, grouping APRS SSIDs such as `KN6KCE-5` and `KN6KCE-9` into one map point. The first decoded position is retained until a later position from any SSID is more than 250 km away, at which point that same row is replaced. Existing SSID rows are consolidated when the service starts; a bare-callsign row takes precedence, or the alphabetically first SSID row if none exists. It does not store packet bodies, comments, paths, IP addresses, timestamps, or location history.

Beacon 73 currently transmits uncompressed APRS positions, which this service decodes. Other packet types and position encodings are ignored.

## Local checks

```sh
cd beaconwatch
python3 -m unittest -v
BEACONWATCH_APRS_HOST=127.0.0.1 python3 beaconwatch.py
curl http://127.0.0.1:20242/beaconwatch/health
curl http://127.0.0.1:20242/beaconwatch/api/locations
```

The receiver runs without third-party Python packages. The map loads Leaflet 1.9.4, Leaflet.markercluster 1.5.3, D3 Geo, and TopoJSON Client from unpkg, plus Esri World Street Map tiles. Nearby stations collapse into numbered clusters until the map is zoomed in far enough to show their individual callsigns. A country summary classifies each coordinate against the 50 m Natural Earth boundaries distributed by world-atlas. The installer downloads the pinned boundary file, verifies its checksum, and serves it locally with the other static assets.

## Production layout on sna2

- Application: `/opt/beaconwatch`
- SQLite database: `/var/lib/beaconwatch/locations.db`
- Service: `/etc/systemd/system/beaconwatch.service`
- Listener: `127.0.0.1:20242`
- Public URL: `https://k6bat.com/beaconwatch/`

The installer first compares the live nginx site with the inspected baseline and refuses to overwrite it if anything has changed. It keeps a timestamped backup and restores that backup if `nginx -t` fails. From the staged directory on `sna2`, run:

```sh
cd /home/bret/beaconwatch
sudo ./deploy/install-sna2.sh
```

For a manual installation, insert `deploy/nginx-location.conf` inside the existing `k6bat.com` server block, install the application and unit using the paths above, and validate before activating:

```sh
sudo nginx -t
sudo systemctl daemon-reload
sudo systemctl enable --now beaconwatch.service
sudo systemctl reload nginx
```

The existing Cloudflare Tunnel already sends `k6bat.com` to nginx, so no DNS or Tunnel route change is needed.
