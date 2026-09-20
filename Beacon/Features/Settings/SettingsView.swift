import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isPasscodeVisible = false
    let showMap: () -> Void

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Call Sign") {
                        TextField("Required", text: $model.settings.identity.callsign)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }

                    LabeledContent {
                        Picker("", selection: Binding(
                            get: {
                                let value = Int(model.settings.identity.ssid) ?? 0
                                return min(max(value, 0), 15)
                            },
                            set: { model.settings.identity.ssid = String($0) }
                        )) {
                            ForEach(0...15, id: \.self) { value in
                                Text(value == 0 ? "0 — No suffix" : String(value)).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 5) {
                            Text("SSID")
                            SettingsInfoButton(
                                title: "About SSID",
                                text: "A suffix from 0–15 that distinguishes this phone from your other APRS stations. Zero sends only your base call sign."
                            )
                        }
                    }

                    LabeledContent {
                            HStack(spacing: 8) {
                                Group {
                                    if isPasscodeVisible {
                                        TextField("Required", text: $model.settings.identity.passcode)
                                    } else {
                                        SecureField("Required", text: $model.settings.identity.passcode)
                                    }
                                }
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)

                                Image(systemName: isPasscodeVisible ? "eye.fill" : "eye")
                                    .foregroundStyle(isPasscodeVisible ? .blue : .secondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                                    .onLongPressGesture(
                                        minimumDuration: .infinity,
                                        maximumDistance: .infinity,
                                        pressing: { isPasscodeVisible = $0 },
                                        perform: {}
                                    )
                                    .accessibilityLabel("Reveal passcode")
                                    .accessibilityHint("Press and hold to show the entered passcode")
                            }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Passcode")
                            SettingsInfoButton(
                                title: "About APRS-IS Passcodes",
                                text: "The APRS-IS validation number derived from your call sign. It is not your FCC or website password."
                            )
                        }
                    }

                    if model.settings.identity.isReady, !model.isAPRSISPasscodeValid {
                        Label("Passcode does not match this call sign.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Amateur identity")
                } footer: {
                    Text("APRS-IS is for licensed amateur-radio use. Your passcode stays on this device.")
                }

                Section("Beaconing") {
                    Picker("Mode", selection: $model.settings.beaconing.mode) {
                        ForEach(AppSettings.Beaconing.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if model.settings.beaconing.mode == .timed {
                        Stepper(
                            "Every \(Int(model.settings.beaconing.timedInterval ?? 120)) seconds",
                            value: Binding(
                                get: { model.settings.beaconing.timedInterval ?? 120 },
                                set: { model.settings.beaconing.timedInterval = $0 }
                            ),
                            in: 30...1_800,
                            step: 30
                        )
                    }
                    LabeledContent("Beacon Message") {
                        TextField("Message", text: $model.settings.beaconing.comment)
                            .multilineTextAlignment(.trailing)
                    }
                    NavigationLink {
                        APRSSymbolPickerView(selection: $model.settings.beaconing.symbol)
                    } label: {
                        let symbol = APRSSymbolCatalog.selection(from: model.settings.beaconing.symbol)
                        LabeledContent("APRS Symbol") {
                            HStack(spacing: 8) {
                                APRSSymbolIcon(symbol: symbol, size: 26)
                                Text(symbol.name).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Stations") {
                    Stepper(
                        "Station Receive Radius: \(model.settings.server.filterRadiusKilometers) km",
                        value: $model.settings.server.filterRadiusKilometers,
                        in: 10...500,
                        step: 10
                    )
                    Toggle("Moving stations", isOn: $model.settings.display.showMovingStations)
                    Toggle("Fixed stations", isOn: $model.settings.display.showFixedStations)
                    Toggle("Weather stations", isOn: $model.settings.display.showWeatherStations)
                }

                Section("Map") {
                    Picker("Speed", selection: $model.settings.display.speedUnit) {
                        ForEach(AppSettings.Display.SpeedUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Distance", selection: $model.settings.display.distanceUnit) {
                        ForEach(AppSettings.Display.DistanceUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                Section {
                    NavigationLink("APRS-IS server") { ServerSettingsView() }
                    NavigationLink("APRS-IS diagnostics") { APRSISDiagnosticsView() }
                    NavigationLink("SmartBeaconing thresholds") { SmartBeaconingSettingsView() }
                } header: {
                    Text("Advanced")
                }

                Section("Location") {
                    LabeledContent("Permission", value: model.locationService.authorizationStatus.label)
                    Button("Request Location Access") { model.locationService.requestPermission() }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissKeyboard()
                        model.saveSettings()
                        Task { await model.startReceiving() }
                        showMap()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Home")
                        }
                    }
                }
                keyboardDoneButton
            }
            .onDisappear {
                model.saveSettings()
                Task { await model.startReceiving() }
            }
        }
    }
}

private struct SettingsInfoButton: View {
    let title: String
    let text: String
    @State private var isShowingHelp = false

    var body: some View {
        Button {
            isShowingHelp = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .popover(isPresented: $isShowingHelp, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(idealWidth: 300)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct APRSISDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var didCopy = false

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status", value: model.connectionState.label)
                LabeledContent("Server", value: "\(model.settings.server.host):\(model.settings.server.port)")
                LabeledContent("Filter", value: model.aprsFilterDescription)
                LabeledContent("Last stream data") {
                    Text(model.lastStreamActivityAt?.formatted(date: .omitted, time: .standard) ?? "None")
                        .foregroundStyle(model.lastStreamActivityAt == nil ? .secondary : .primary)
                }
            }

            Section("Packet counters") {
                LabeledContent("Received", value: "\(model.receivedPacketCount)")
                LabeledContent("Decoded stations", value: "\(model.stations.count)")
                LabeledContent("Visible nearby", value: "\(model.nearbyStations.count)")
                LabeledContent("Hidden by filters", value: "\(model.hiddenNearbyStationCount)")
                LabeledContent("Unsupported", value: "\(model.unsupportedPacketCount)")
            }

            Section {
                Button {
                    Task { await model.reconnectAPRSIS() }
                } label: {
                    Label("Reconnect Now", systemImage: "arrow.clockwise")
                }

                Button {
                    UIPasteboard.general.string = model.aprsDiagnosticReport
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy Diagnostic Log", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(model.aprsDiagnosticEntries.isEmpty)

                Button(role: .destructive) {
                    model.clearAPRSDiagnostics()
                    didCopy = false
                } label: {
                    Label("Clear Log", systemImage: "trash")
                }
                .disabled(model.aprsDiagnosticEntries.isEmpty)
            }

            Section {
                if model.aprsDiagnosticEntries.isEmpty {
                    Text("No stream activity recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.aprsDiagnosticEntries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .foregroundStyle(entry.isConnectionEvent ? .blue : .primary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Newest stream entries first")
            } footer: {
                Text("The app keeps the latest 300 entries. APRS passcodes and outbound login commands are never recorded.")
            }
        }
        .navigationTitle("APRS-IS Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct APRSSymbolPickerView: View {
    @Binding var selection: String
    @State private var searchText = ""

    private var symbols: [APRSSymbol] {
        let matches = searchText.isEmpty ? APRSSymbolCatalog.all : APRSSymbolCatalog.all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.codeLabel.localizedCaseInsensitiveContains(searchText)
        }
        return matches.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.codeLabel < $1.codeLabel : comparison == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section("Symbols") {
                ForEach(symbols) { symbol in
                    Button {
                        selection = symbol.packetValue
                    } label: {
                        HStack(spacing: 14) {
                            APRSSymbolIcon(symbol: symbol, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(symbol.name).foregroundStyle(.primary)
                                Text(symbol.codeLabel)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection == symbol.packetValue || APRSSymbolCatalog.selection(from: selection).id == symbol.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search symbols")
        .navigationTitle("APRS Symbol")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Host", text: $model.settings.server.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $model.settings.server.port, format: .number)
                    .keyboardType(.numberPad)
            } footer: {
                Text("The default rotating APRS-IS endpoint is appropriate for most users.")
            }
        }
        .navigationTitle("APRS-IS Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { keyboardDoneButton }
    }
}

@ToolbarContentBuilder
private var keyboardDoneButton: some ToolbarContent {
    ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { dismissKeyboard() }
            .fontWeight(.semibold)
    }
}

@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

private struct SmartBeaconingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Intervals") {
                Stepper("Stopped: \(Int(model.settings.beaconing.stoppedInterval / 60)) min",
                        value: $model.settings.beaconing.stoppedInterval, in: 300...3_600, step: 60)
                Stepper("Moving: \(Int(model.settings.beaconing.slowInterval)) sec",
                        value: $model.settings.beaconing.slowInterval, in: 60...600, step: 30)
                Stepper("Fast: \(Int(model.settings.beaconing.fastInterval)) sec",
                        value: $model.settings.beaconing.fastInterval, in: 15...180, step: 15)
            }
            Section("Turns and GPS") {
                Stepper("Turn threshold: \(Int(model.settings.beaconing.turnThresholdDegrees))°",
                        value: $model.settings.beaconing.turnThresholdDegrees, in: 10...90, step: 5)
                Stepper("Max accuracy: \(Int(model.settings.beaconing.maximumAccuracyMeters)) m",
                        value: $model.settings.beaconing.maximumAccuracyMeters, in: 10...500, step: 10)
            }
        }
        .navigationTitle("SmartBeaconing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
