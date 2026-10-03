import CoreLocation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var isPasscodeVisible = false
    @State private var isShowingPasscodeRequest = false
    @State private var passcodeRequestConfirmation: String?
    let showMap: () -> Void

    private var receiveRadiusLabel: String {
        let unit = model.settings.display.distanceUnit == .miles ? "mi" : "km"
        return "\(model.settings.receiveRadius) \(unit)"
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    if model.isDemoMode {
                        Button {
                            model.exitDemoMode()
                        } label: {
                            Label("Exit Demo and Set Up Callsign", systemImage: "person.badge.key.fill")
                        }
                    } else {
                        Button {
                            dismissKeyboard()
                            Task {
                                await model.enterDemoMode()
                                showMap()
                            }
                        } label: {
                            Label("Explore Demo", systemImage: "map.fill")
                        }
                    }
                } header: {
                    Text("Demo Mode")
                } footer: {
                    Text("Demo Mode uses simulated stations and disables all transmission.")
                }

                Section {
                    LabeledContent("Call Sign") {
                        TextField("Required", text: $model.settings.identity.callsign)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .disabled(model.isDemoMode)
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
                        .disabled(model.isDemoMode)
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
                            .disabled(model.isDemoMode)
                    } label: {
                        HStack(spacing: 5) {
                            Text("Passcode")
                            SettingsInfoButton(
                                title: "About APRS-IS Passcodes",
                                text: "The APRS-IS validation number derived from your call sign. It is not your FCC or website password."
                            )
                        }
                    }

                    Button {
                        dismissKeyboard()
                        isShowingPasscodeRequest = true
                    } label: {
                        Label("Request a passcode", systemImage: "key.horizontal")
                    }
                    .disabled(
                        model.isDemoMode
                            || AmateurCallsignValidator.normalizedBase(from: model.settings.identity.callsign) == nil
                    )

                    if model.isDemoMode {
                        Button {
                            model.exitDemoMode()
                        } label: {
                            Label(
                                "Exit Demo Mode to configure your callsign",
                                systemImage: "lock.open.fill"
                            )
                        }
                    }

                    if !model.isDemoMode,
                       !model.settings.identity.callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       AmateurCallsignValidator.normalizedBase(from: model.settings.identity.callsign) == nil {
                        Label("Enter a valid amateur-radio call sign.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if !model.isDemoMode,
                       model.settings.identity.isReady,
                       !model.isAPRSISPasscodeValid {
                        Label("Passcode does not match this call sign.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Amateur identity")
                } footer: {
                    Text(model.isDemoMode
                         ? "Identity settings are locked while using simulated demo data."
                         : "APRS-IS is for licensed amateur-radio use. Your passcode stays on this device.")
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
                        "Station Receive Radius: \(receiveRadiusLabel)",
                        value: $model.settings.receiveRadiusChoiceIndex,
                        in: 0...(AppSettings.receiveRadiusChoices.count - 1),
                        step: 1
                    )
                    Toggle("Moving stations", isOn: $model.settings.display.showMovingStations)
                    Toggle("Fixed stations", isOn: $model.settings.display.showFixedStations)
                    Toggle("Weather stations", isOn: $model.settings.display.showWeatherStations)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $model.settings.display.theme) {
                        ForEach(AppSettings.Display.Theme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.settings.display.theme) { _, _ in
                        model.settings.save()
                    }
                }

                Section("Units") {
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

                Section {
                    LabeledContent("Permission", value: model.locationService.authorizationStatus.label)
                    if model.locationService.authorizationStatus == .notDetermined {
                        Button("Request Location Access") { model.locationService.requestPermission() }
                    } else {
                        Button("Open iOS Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    if model.locationService.authorizationStatus == .restricted {
                        Text("Location access is restricted by device settings or management policies.")
                    } else if model.locationService.authorizationStatus != .notDetermined {
                        Text("Change location access in iOS Settings. While Using the App is enough for auto-beaconing, including when the screen is locked.")
                    }
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
            .onAppear { model.beginEditingSettings() }
            .onDisappear {
                model.endEditingSettings()
                model.saveSettings()
                Task { await model.startReceiving() }
            }
            .sheet(isPresented: $isShowingPasscodeRequest) {
                PasscodeRequestSheet(callsign: model.settings.identity.callsign) { result in
                    model.settings.identity.callsign = result.callsign
                    model.settings.identity.passcode = String(result.passcode)
                    model.saveSettings()
                    passcodeRequestConfirmation = "Your APRS-IS passcode was approved and saved for \(result.callsign)."
                }
            }
            .alert(
                "Passcode Saved",
                isPresented: Binding(
                    get: { passcodeRequestConfirmation != nil },
                    set: { if !$0 { passcodeRequestConfirmation = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(passcodeRequestConfirmation ?? "")
            }
        }
    }
}

private struct PasscodeRequestSheet: View {
    private enum FCCLookupState {
        case loading
        case matched(FCCCallsignRecord, FCCCallsignLookup.Dataset)
        case notFound(FCCCallsignLookup.Dataset)
        case unavailable
    }

    @Environment(\.dismiss) private var dismiss
    let callsign: String
    let onApproval: (PasscodeRequestResult) -> Void

    @State private var hasAttested = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var fccLookupState = FCCLookupState.loading

    private var normalizedCallsign: String {
        AmateurCallsignValidator.normalizedBase(from: callsign)
            ?? callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Passcode request") {
                    LabeledContent("Call Sign", value: normalizedCallsign)

                    Text("Beacon 73 will securely send this call sign to the passcode service for validation and approval.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                fccRecordSection

                Section {
                    Button {
                        hasAttested.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: hasAttested ? "checkmark.square.fill" : "square")
                                .font(.title3)
                                .foregroundStyle(hasAttested ? .blue : .secondary)
                            Text("I attest that I am a licensed amateur-radio operator and am the licensee, trustee, or otherwise authorized to use **\(normalizedCallsign)**.")
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Licensed operator and call sign authorization attestation")
                    .accessibilityValue(hasAttested ? "Accepted" : "Not accepted")
                    .accessibilityAddTraits(hasAttested ? .isSelected : [])
                } header: {
                    Text("Required attestation")
                } footer: {
                    Text("Your attestation and request time are recorded by the service. Your APRS-IS passcode is not stored by the service.")
                }

                Section {
                    Button {
                        submitRequest()
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text("Validating…")
                            } else {
                                Text("Submit Request")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!hasAttested || isSubmitting || isLookupLoading)
                }
            }
            .navigationTitle("Request Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSubmitting)
            .task { await loadFCCRecord() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .alert(
                "Unable to Request Passcode",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var fccRecordSection: some View {
        switch fccLookupState {
        case .loading:
            Section("FCC license record") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching FCC amateur licenses…")
                        .foregroundStyle(.secondary)
                }
            }
        case .matched(let record, let dataset):
            Section {
                if let licenseeName = record.licenseeName {
                    LabeledContent("Licensee", value: licenseeName)
                }
                LabeledContent("Status", value: record.status)
                if let operatorClass = record.operatorClassDescription {
                    LabeledContent("Class", value: operatorClass)
                }
                if let expirationDate = record.expirationDate {
                    LabeledContent("Expires", value: expirationDate)
                }
            } header: {
                Text("FCC license record")
            } footer: {
                Text("Public FCC ULS data updated \(dataset.updateDateDescription). Address and contact details are not retained by Beacon 73.")
            }
        case .notFound(let dataset):
            Section("FCC license record") {
                Label("No active U.S. FCC record was found.", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("International callsigns are not included in FCC data. You may continue if you are authorized to use this callsign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("FCC data updated \(dataset.updateDateDescription)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case .unavailable:
            Section("FCC license record") {
                Label("FCC record lookup is temporarily unavailable.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("You may still continue with the required authorization attestation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isLookupLoading: Bool {
        if case .loading = fccLookupState { return true }
        return false
    }

    private func loadFCCRecord() async {
        do {
            let lookup = try await PasscodeRequestClient().lookupCallsign(normalizedCallsign)
            if let record = lookup.record {
                fccLookupState = .matched(record, lookup.dataset)
            } else {
                fccLookupState = .notFound(lookup.dataset)
            }
        } catch {
            fccLookupState = .unavailable
        }
    }

    private func submitRequest() {
        guard hasAttested, !isSubmitting else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                let result = try await PasscodeRequestClient().requestPasscode(for: normalizedCallsign)
                onApproval(result)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
                TextField("Port", value: $model.settings.server.port, format: .number.grouping(.never))
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
