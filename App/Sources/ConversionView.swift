import SwiftUI

struct ConversionView: View {
    @Bindable var conversion: ConversionModel
    let library: LibraryModel
    @AppStorage(Prefs.deleteAAXAfterConversion) private var deleteAAX = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Convert to M4B").font(.title2.bold())
            Text(conversion.book?.title ?? "").font(.headline)
            // Matches ConversionModel.start: only account conversions move the AAX to the Trash.
            Text(deleteAAX && conversion.usesAccountKey
                 ? "Keep the original audio quality, chapters and cover. The AAX file, downloaded by OpenAudible, goes to the Trash once the M4B is saved and its length checked. OpenAudible will show it as missing."
                 : "Keep the original audio quality, chapters and cover. Your AAX file is kept.")
                .foregroundStyle(.secondary)
            if !conversion.isRunning && !conversion.succeeded && !conversion.usesAccountKey {
                SecureField("Activation bytes (8 hexadecimal characters)", text: $conversion.activationBytes)
                    .textFieldStyle(.roundedBorder)
                Text("Use the activation bytes for the Audible account that owns this AAX file.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Remember in Keychain for this book", isOn: $conversion.rememberKey)
                Text("Conversion uses FFmpeg (LGPL 2.1), included with Lectern Audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if conversion.isRunning {
                ProgressView(value: conversion.progress)
                Text(conversion.progress >= 0.99 ? "Finishing and checking audio…" : "Converting… \(Int(conversion.progress * 100))%")
                    .font(.callout).monospacedDigit()
            }
            if let message = conversion.message {
                Text(message).font(.callout).foregroundStyle(conversion.succeeded ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if conversion.isRunning {
                    Button("Cancel Conversion", role: .cancel) { conversion.cancel() }
                } else {
                    Button(conversion.succeeded ? "Done" : "Close") { conversion.dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if !conversion.succeeded && !conversion.usesAccountKey {
                        Button("Convert") { conversion.start(libraryModel: library) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(conversion.activationBytes.isEmpty || conversion.ffmpegURL == nil)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(conversion.isRunning)
    }
}
