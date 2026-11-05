import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @EnvironmentObject var library: Library
    @State private var pickFolder = false
    @State private var confirmEmpty = false

    private var chips: [FormatChip] {
        library.quickPicks.map { FormatChip(id: $0.id.uuidString, name: $0.name, format: $0.format, pick: $0) }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (build \(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use the same format for every batch", isOn: $library.useGlobalFormat)
                } header: {
                    Text("Unpack format")
                } footer: {
                    Text(library.useGlobalFormat
                         ? "On: Unpack starts straight away with the format below."
                         : "Off: each time you unpack, you choose layers and passwords for that batch. The format below is filled in to start with.")
                }

                FormatEditor(format: $library.defaultFormat, chips: chips,
                             heading: library.useGlobalFormat ? "Format for every batch" : "Starting format")

                Section {
                    LabeledContent("Folder", value: library.exportName ?? "Not set")
                    Button(library.exportName == nil ? "Choose folder…" : "Choose a different folder…") { pickFolder = true }
                    if library.exportName != nil {
                        Toggle("Copy each finished batch here", isOn: $library.autoCopy)
                        Button("Stop exporting", role: .destructive) { library.clearExportDestination() }
                    }
                } header: {
                    Text("Export destination (optional)")
                } footer: {
                    Text("Pick a folder once, e.g. the Unzip app’s folder in Files. Each batch folder is copied there when it finishes and also stays in Unpacker.")
                }

                Section {
                    Toggle("Name videos after the original file", isOn: $library.renameVideos)
                } header: {
                    Text("Video names")
                } footer: {
                    Text("7月17日舞蹈.pdf gives 7月17日舞蹈.mp4, or 7月17日舞蹈 (1).mp4, (2)… when it holds several videos. Other files keep their names.")
                }

                Section {
                    Picker("After unpacking", selection: $library.deleteOriginals) {
                        Text("Keep originals").tag(false)
                        Text("Delete originals").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("After unpacking")
                } footer: {
                    Text(library.deleteOriginals
                         ? "Originals are deleted after they unpack. Middle layers are always deleted."
                         : "Originals move to the Originals folder after they unpack. Middle layers are always deleted.")
                }

                Section {
                    LabeledContent("Originals folder", value: plural(library.originalsCount, "file"))
                    Button("Empty Originals folder", role: .destructive) { confirmEmpty = true }
                        .disabled(library.originalsCount == 0)
                } footer: {
                    Text("Unpacker \(version) · Everything happens on this iPhone; nothing is uploaded.")
                }

                Section {
                    Text(SupportedFormats.names.joined(separator: " · "))
                        .font(.subheadline)
                    if !SupportedFormats.engineMissing.isEmpty {
                        Text("Missing from this build: " + SupportedFormats.engineMissing.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Formats it opens")
                } footer: {
                    Text("Including password-protected 7z, RAR and zip, encrypted file lists, multi-part sets (.001, .part1.rar, .r00, .z01) and archives inside archives.")
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Settings")
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { library.setExportDestination(url) }
            }
            .confirmationDialog("Delete the \(plural(library.originalsCount, "file")) in Originals?",
                                isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Empty Originals folder", role: .destructive) { library.clearOriginals() }
            }
        }
    }
}

struct FormatChip: Identifiable {
    let id: String
    let name: String
    let format: UnpackFormat
    /// Set for saved quick picks, which can be deleted.
    var pick: QuickPick?
}

/// Layers + passwords, with one-tap quick picks. Used in Settings and in the per-batch sheet.
struct FormatEditor: View {
    @Binding var format: UnpackFormat
    let chips: [FormatChip]
    let heading: String
    @EnvironmentObject var library: Library
    @State private var naming = false
    @State private var newName = ""

    private var listText: Binding<String> {
        Binding(get: { format.passwordList.joined(separator: "\n") },
                set: { format.passwordList = $0.components(separatedBy: "\n") })
    }

    private var perLayer: Binding<Bool> {
        Binding(get: { format.usesPerLayer },
                set: { on in
                    if on && format.layers == nil { format.layers = 2 }
                    format.perLayer = on
                })
    }

    private var layers: Binding<Int?> {
        Binding(get: { format.layers },
                set: { format.layers = $0; format.normalize() })
    }

    private func layerPassword(_ i: Int) -> Binding<String> {
        Binding(get: { i < format.layerPasswords.count ? format.layerPasswords[i] : "" },
                set: { value in
                    format.normalize()
                    format.layerPasswords[i] = value
                })
    }

    var body: some View {
        Group {
            if !chips.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(chips) { chip in chipView(chip) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text(heading)
                } footer: {
                    Text("Quick picks fill in everything below with one tap. Touch and hold a saved one to delete it.")
                }
            }

            Section {
                Picker("Layers", selection: layers) {
                    ForEach(UnpackFormat.layerChoices, id: \.self) { v in
                        Text(v.map { String($0) } ?? "Auto").tag(v)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(chips.isEmpty ? heading + " · layers" : "Layers")
            } footer: {
                if let n = format.layers {
                    Text("Opens exactly \(plural(n, "layer")). Anything still zipped after that is kept as a file.")
                } else {
                    Text("Keeps opening zips it finds inside, up to 6 deep. Zip-based documents like .docx stay as they are.")
                }
            }

            Section {
                Picker("Passwords", selection: perLayer) {
                    Text("Any layer").tag(false)
                    Text("Per layer").tag(true)
                }
                .pickerStyle(.segmented)
                if format.usesPerLayer, let n = format.layers {
                    ForEach(0..<n, id: \.self) { i in
                        HStack {
                            Text("Layer \(i + 1)").frame(width: 72, alignment: .leading)
                            TextField("No password", text: layerPassword(i))
                                .font(.body.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                } else {
                    TextEditor(text: listText)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 66)
                        .accessibilityLabel("Passwords, one per line")
                }
                Button("Save as a quick pick…") {
                    newName = ""
                    naming = true
                }
            } header: {
                Text("Passwords")
            } footer: {
                Text(format.usesPerLayer ? "Leave a layer empty if it has no password. Stored only on this iPhone."
                     : format.layers == nil ? "One per line, tried in order on each layer until one works. Choose a number of layers to set one per layer."
                     : "One per line, tried in order on each layer until one works. Stored only on this iPhone.")
            }
        }
        .alert("Save as a quick pick", isPresented: $naming) {
            TextField("Name, e.g. Baidu dance", text: $newName)
            Button("Save") { library.saveQuickPick(format, name: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(format.summary)
        }
    }

    private func chipView(_ chip: FormatChip) -> some View {
        let on = chip.format.key == format.key
        return Button {
            var f = chip.format
            f.normalize()
            format = f
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(chip.name).font(.subheadline.weight(.semibold))
                Text(chip.format.summary).font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(Capsule().fill(on ? Color.accentColor : Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .contextMenu {
            if let pick = chip.pick {
                Button("Delete “\(pick.name)”", role: .destructive) { library.deleteQuickPick(pick) }
            }
        }
    }
}
