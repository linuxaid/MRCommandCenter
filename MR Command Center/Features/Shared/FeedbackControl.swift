import SwiftUI

/// 👍 / 👎 with an optional note. Tapping the selected thumb clears it.
struct FeedbackControl: View {
    @Binding var feedback: Feedback
    @Binding var note: String
    var subject = "this"
    @State private var isEditingNote = false

    var body: some View {
        HStack(spacing: 2) {
            thumb(.helpful, systemImage: "hand.thumbsup", label: "Helpful")
            thumb(.wrong, systemImage: "hand.thumbsdown", label: "Wrong")
            Button {
                isEditingNote = true
            } label: {
                Image(systemName: note.isEmpty ? "note.text.badge.plus" : "note.text")
            }
            .help(note.isEmpty ? "Add a note" : note)
            .accessibilityLabel(note.isEmpty ? "Add a note about \(subject)" : "Edit note: \(note)")
            .popover(isPresented: $isEditingNote) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Note").font(.headline)
                    TextField("Why it's helpful or wrong", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .frame(width: 260)
                }
                .padding(12)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func thumb(_ value: Feedback, systemImage: String, label: String) -> some View {
        let selected = feedback == value
        return Button {
            feedback = selected ? .none : value
        } label: {
            Image(systemName: selected ? systemImage + ".fill" : systemImage)
                .foregroundStyle(selected ? (value == .helpful ? Color.green : Color.red) : Color.secondary)
        }
        .help(label)
        .accessibilityLabel("Mark \(subject) as \(label.lowercased())")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
