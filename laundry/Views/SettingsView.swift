import SwiftUI

struct SettingsView: View {
    @Environment(SettingsViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            Form {
                Section {
                    Toggle("Freed slot notifications", isOn: Binding(
                        get: { vm.settings.isEnabled },
                        set: { _ in vm.toggleEnabled() }
                    ))
                } footer: {
                    Text("Get notified when a booked slot may have freed up because someone didn't activate their session in time. Only sent when you're at home.")
                }

                if vm.settings.isEnabled {
                    Section("Home Location") {
                        if vm.settings.hasHomeLocation {
                            HStack {
                                Label("Location set", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("Clear") { vm.clearHomeLocation() }
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Button {
                                Task { await vm.setCurrentLocationAsHome() }
                            } label: {
                                HStack {
                                    Text("Use Current Location")
                                    Spacer()
                                    if vm.isRequestingLocation {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(vm.isRequestingLocation)
                        }
                        if let status = vm.locationStatus, !vm.settings.hasHomeLocation {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Home WiFi") {
                        if let ssid = vm.settings.homeWiFiSSID {
                            HStack {
                                Label(ssid, systemImage: "wifi")
                                Spacer()
                                Button("Clear") { vm.clearWiFiSSID() }
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Button {
                                Task { await vm.detectCurrentWiFi() }
                            } label: {
                                HStack {
                                    Text("Use Current WiFi")
                                    Spacer()
                                    if vm.isRequestingWiFi {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(vm.isRequestingWiFi)
                        }
                    }

                    Section("Detection Radius") {
                        Stepper(
                            "\(Int(vm.settings.homeRadiusMeters))m",
                            value: Binding(
                                get: { vm.settings.homeRadiusMeters },
                                set: { vm.updateRadius($0) }
                            ),
                            in: 50...500,
                            step: 50
                        )
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
