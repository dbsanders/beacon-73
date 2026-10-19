const map = L.map("map", {
  worldCopyJump: true,
  minZoom: 2,
}).setView([20, 0], 2);

L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}", {
  maxZoom: 19,
  attribution: "Tiles &copy; Esri",
}).addTo(map);

const stationLayer = L.layerGroup().addTo(map);
const stationCount = document.getElementById("station-count");
const mapStatus = document.getElementById("map-status");

function renderStations(locations) {
  stationLayer.clearLayers();
  for (const station of locations) {
    L.circleMarker([station.latitude, station.longitude], {
      radius: 6,
      weight: 2,
      color: "#ffffff",
      fillColor: "#ff7a1a",
      fillOpacity: 0.9,
    })
      .bindPopup(document.createTextNode(station.callsign))
      .addTo(stationLayer);
  }
  stationCount.textContent = String(locations.length);
}

async function refresh() {
  try {
    const response = await fetch("/beaconwatch/api/locations", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    renderStations(payload.locations);
    if (!payload.aprsConnected) {
      mapStatus.textContent = payload.count === 0
        ? "Connecting to the worldwide APRS-IS feed…"
        : "Showing stored stations while the live feed reconnects…";
    } else {
      mapStatus.textContent = payload.count === 0
        ? "Listening for the first Beacon 73 station…"
        : "BeaconWatch is receiving worldwide APRS-IS data";
    }
  } catch (error) {
    console.error("BeaconWatch refresh failed", error);
    mapStatus.textContent = "Station data is temporarily unavailable";
  }
}

refresh();
window.setInterval(refresh, 60_000);
