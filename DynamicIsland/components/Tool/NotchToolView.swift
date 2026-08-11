import AppKit
import SwiftUI

private enum ToolKind: String, CaseIterable, Identifiable {
    case base64 = "Base64"
    case timestamp = "Timestamp"

    var id: String { rawValue }
}

private enum Base64Direction: String, CaseIterable, Identifiable {
    case encode = "Encode"
    case decode = "Decode"

    var id: String { rawValue }
}

private enum TimestampDirection: String, CaseIterable, Identifiable {
    case timestampToDate = "Timestamp → Date"
    case dateToTimestamp = "Date → Timestamp"

    var id: String { rawValue }
}

struct NotchToolView: View {
    @State private var selectedTool: ToolKind = .base64
    @State private var base64Direction: Base64Direction = .encode
    @State private var timestampDirection: TimestampDirection = .timestampToDate
    @State private var input = ""
    @State private var output = ""
    @State private var secondaryOutput: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            Picker("Tool", selection: $selectedTool) {
                ForEach(ToolKind.allCases) { tool in
                    Text(tool.rawValue).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            directionPicker

            VStack(alignment: .leading, spacing: 5) {
                Text(inputTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text(inputPlaceholder)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $input)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(3)
                }
                .frame(height: 58)
                .background(
                    .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                Button("Convert") {
                    convert()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    swapDirection()
                } label: {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(output.isEmpty)

                Button {
                    clear()
                } label: {
                    Label("Clear", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    copyOutput()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(output.isEmpty)
                .accessibilityLabel("Copy result")
                .help("Copy result")
            }

            outputView
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onChange(of: selectedTool) { _, _ in
            clear()
        }
        .onChange(of: base64Direction) { _, _ in
            clearResult()
        }
        .onChange(of: timestampDirection) { _, _ in
            clearResult()
        }
        .onChange(of: input) { _, _ in
            errorMessage = nil
        }
    }

    @ViewBuilder
    private var directionPicker: some View {
        switch selectedTool {
        case .base64:
            Picker("Direction", selection: $base64Direction) {
                ForEach(Base64Direction.allCases) { direction in
                    Text(direction.rawValue).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .timestamp:
            Picker("Direction", selection: $timestampDirection) {
                ForEach(TimestampDirection.allCases) { direction in
                    Text(direction.rawValue).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var outputView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Result")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if output.isEmpty {
                        Text("Converted value appears here")
                            .foregroundStyle(.tertiary)
                    } else if let secondaryOutput {
                        Text("Seconds: \(output)")
                        Text("Milliseconds: \(secondaryOutput)")
                    } else {
                        Text(output)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 52)
            .background(
                .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var inputTitle: String {
        switch selectedTool {
        case .base64:
            return base64Direction == .encode ? "Text" : "Base64"
        case .timestamp:
            return timestampDirection == .timestampToDate ? "Timestamp" : "Date"
        }
    }

    private var inputPlaceholder: String {
        switch selectedTool {
        case .base64:
            return base64Direction == .encode ? "Enter UTF-8 text" : "Enter Base64 text"
        case .timestamp:
            return timestampDirection == .timestampToDate
                ? "10-digit seconds or 13-digit milliseconds"
                : "yyyy-MM-dd HH:mm:ss"
        }
    }

    private func convert() {
        do {
            switch selectedTool {
            case .base64:
                output =
                    try base64Direction == .encode
                    ? ToolConverter.encodeBase64(input)
                    : ToolConverter.decodeBase64(input)
                secondaryOutput = nil
            case .timestamp:
                switch timestampDirection {
                case .timestampToDate:
                    output = try ToolConverter.dateString(fromTimestamp: input)
                    secondaryOutput = nil
                case .dateToTimestamp:
                    let result = try ToolConverter.timestamps(fromDateString: input)
                    output = String(result.seconds)
                    secondaryOutput = String(result.milliseconds)
                }
            }
            errorMessage = nil
        } catch {
            clearResult()
            errorMessage =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func swapDirection() {
        guard !output.isEmpty else { return }

        input = output
        switch selectedTool {
        case .base64:
            base64Direction = base64Direction == .encode ? .decode : .encode
        case .timestamp:
            timestampDirection =
                timestampDirection == .timestampToDate
                ? .dateToTimestamp
                : .timestampToDate
        }
        clearResult()
    }

    private func clear() {
        input = ""
        clearResult()
    }

    private func clearResult() {
        output = ""
        secondaryOutput = nil
        errorMessage = nil
    }

    private func copyOutput() {
        guard !output.isEmpty else { return }

        let value =
            secondaryOutput.map {
                "Seconds: \(output)\nMilliseconds: \($0)"
            } ?? output
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

#Preview {
    NotchToolView()
        .frame(width: 690, height: 300)
        .preferredColorScheme(.dark)
}
