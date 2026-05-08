import SwiftUI

struct TransformEditor: View {
    let title: String
    var values: Values
    let onSave: () -> Void

    struct Values {
        var rotX: Binding<Float>
        var rotY: Binding<Float>
        var rotZ: Binding<Float>
        var scale: Binding<Float>
        var posX: Binding<Float>
        var posY: Binding<Float>
        var posZ: Binding<Float>
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rotation (degrees)") {
                    NumericRow(label: "Rot X", value: values.rotX, step: 5)
                    NumericRow(label: "Rot Y", value: values.rotY, step: 5)
                    NumericRow(label: "Rot Z", value: values.rotZ, step: 5)
                }
                Section("Scale") {
                    NumericRow(label: "Scale", value: values.scale, step: 0.05)
                }
                Section("Position (m)") {
                    NumericRow(label: "Pos X", value: values.posX, step: 0.05)
                    NumericRow(label: "Pos Y", value: values.posY, step: 0.05)
                    NumericRow(label: "Pos Z", value: values.posZ, step: 0.05)
                }
                Section {
                    Button("Save", action: onSave)
                }
            }
            .navigationTitle(title)
        }
    }
}

private struct NumericRow: View {
    let label: String
    let value: Binding<Float>
    let step: Float

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%.2f", value.wrappedValue))
                .foregroundColor(.secondary)
                .monospaced()
            Button {
                value.wrappedValue -= step
            } label: {
                Image(systemName: "minus.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            Button {
                value.wrappedValue += step
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
        }
    }
}
