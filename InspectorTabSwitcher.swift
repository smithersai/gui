import SwiftUI

struct InspectorTabSwitcher: View {
    @Binding var selectedTab: InspectorTab
    let availableTabs: [InspectorTab]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.surface1)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.tab.switcher")
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 0) {
                Spacer()
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundColor(selectedTab == tab ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 12)
                Spacer()
                Rectangle()
                    .fill(selectedTab == tab ? Theme.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tab.rawValue) tab")
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
        .accessibilityIdentifier("inspector.tab.\(tab.rawValue.lowercased())")
    }
}
