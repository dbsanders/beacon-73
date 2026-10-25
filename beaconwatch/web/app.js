const map = L.map("map", {
  worldCopyJump: true,
  minZoom: 2,
}).setView([20, 0], 2);

L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}", {
  maxZoom: 19,
  attribution: "Tiles &copy; Esri",
}).addTo(map);

const stationIcon = L.divIcon({
  className: "station-marker",
  iconSize: [14, 14],
  iconAnchor: [7, 7],
  popupAnchor: [0, -8],
});

const stationLayer = L.markerClusterGroup({
  maxClusterRadius: 48,
  showCoverageOnHover: false,
  spiderfyOnMaxZoom: true,
  iconCreateFunction(cluster) {
    const count = cluster.getChildCount();
    const diameter = count < 10 ? 36 : count < 100 ? 42 : 48;
    return L.divIcon({
      className: "station-cluster",
      html: `<span>${count}</span>`,
      iconSize: [diameter, diameter],
    });
  },
}).addTo(map);
const stationCount = document.getElementById("station-count");
const mapStatus = document.getElementById("map-status");
const countryList = document.getElementById("country-list");
let countryFeaturesPromise;

function loadCountryFeatures() {
  if (!countryFeaturesPromise) {
    countryFeaturesPromise = fetch("/beaconwatch/countries-50m.json")
      .then((response) => {
        if (!response.ok) throw new Error(`Country boundaries: HTTP ${response.status}`);
        return response.json();
      })
      .then((topology) => topojson.feature(topology, topology.objects.countries).features);
  }
  return countryFeaturesPromise;
}

function replaceCountryList(items) {
  countryList.replaceChildren(...items);
}

function countryListItem(name, count) {
  const item = document.createElement("li");
  const countryName = document.createElement("span");
  const stationTotal = document.createElement("strong");
  countryName.textContent = name;
  stationTotal.textContent = String(count);
  item.append(countryName, stationTotal);
  return item;
}

async function renderCountrySummary(locations) {
  if (locations.length === 0) {
    replaceCountryList([countryListItem("No stations yet", 0)]);
    return;
  }

  try {
    const countries = await loadCountryFeatures();
    const counts = new Map();

    for (const station of locations) {
      const country = countries.find((feature) => (
        d3.geoContains(feature, [station.longitude, station.latitude])
      ));
      const name = country?.properties?.name ?? "Outside mapped countries";
      counts.set(name, (counts.get(name) ?? 0) + 1);
    }

    const items = [...counts]
      .sort(([firstName, firstCount], [secondName, secondCount]) => (
        secondCount - firstCount || firstName.localeCompare(secondName)
      ))
      .map(([name, count]) => countryListItem(name, count));
    replaceCountryList(items);
  } catch (error) {
    console.error("BeaconWatch country summary failed", error);
    const unavailable = document.createElement("li");
    unavailable.className = "country-placeholder";
    unavailable.textContent = "Country totals are temporarily unavailable";
    unavailable.title = error instanceof Error ? error.message : "Unknown country lookup error";
    replaceCountryList([unavailable]);
  }
}

function renderStations(locations) {
  stationLayer.clearLayers();
  for (const station of locations) {
    L.marker([station.latitude, station.longitude], {
      icon: stationIcon,
      title: station.callsign,
      alt: station.callsign,
    })
      .bindPopup(document.createTextNode(station.callsign))
      .addTo(stationLayer);
  }
  stationCount.textContent = String(locations.length);
  renderCountrySummary(locations);
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
