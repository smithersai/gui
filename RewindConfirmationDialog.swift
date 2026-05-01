import SwiftUI

private struct RewindConfirmationDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    var frameNo: Int?
    var onConfirm: (Int) -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Confirm Rewind",
            isPresented: $isPresented,
            presenting: frameNo
        ) { frameNo in
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Rewind", role: .destructive) {
                onConfirm(frameNo)
            }
        } message: { frameNo in
            Text("Rewind this run to frame \(frameNo)? This cannot be undone.")
        }
    }
}

extension View {
    func rewindConfirmationDialog(
        isPresented: Binding<Bool>,
        frameNo: Int?,
        onConfirm: @escaping (Int) -> Void
    ) -> some View {
        modifier(
            RewindConfirmationDialogModifier(
                isPresented: isPresented,
                frameNo: frameNo,
                onConfirm: onConfirm
            )
        )
    }
}
