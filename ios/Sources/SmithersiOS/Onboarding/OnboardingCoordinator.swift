#if os(iOS)
import SwiftUI

@MainActor
final class OnboardingCoordinator: ObservableObject {
    static let completionKey = "smithers.onboarding.completed"

    @Published var isPresentingFlow: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPresentingFlow = !defaults.bool(forKey: Self.completionKey)
    }

    func complete() {
        defaults.set(true, forKey: Self.completionKey)
        isPresentingFlow = false
    }

    func replay() {
        defaults.set(false, forKey: Self.completionKey)
        isPresentingFlow = true
    }

    func completeIfNeededAfterDismiss() {
        if !defaults.bool(forKey: Self.completionKey) {
            defaults.set(true, forKey: Self.completionKey)
        }
    }
}

extension View {
    func smithersOnboarding(coordinator: OnboardingCoordinator) -> some View {
        modifier(OnboardingPresentationModifier(coordinator: coordinator))
    }
}

private struct OnboardingPresentationModifier: ViewModifier {
    @ObservedObject var coordinator: OnboardingCoordinator

    func body(content: Content) -> some View {
        content
            .fullScreenCover(
                isPresented: $coordinator.isPresentingFlow,
                onDismiss: coordinator.completeIfNeededAfterDismiss
            ) {
                OnboardingFlow(onComplete: coordinator.complete)
            }
    }
}

struct OnboardingFlow: View {
    struct Step: Identifiable {
        let id: Int
        let systemImage: String
        let title: String
        let message: String
        let linkTitle: String?
        let linkURL: URL?
    }

    private static let steps: [Step] = [
        Step(
            id: 1,
            systemImage: "sparkles",
            title: "Smithers — remote agentic coding on iOS",
            message: "Start from your phone and stay close to the work while agents move through the coding loop.",
            linkTitle: nil,
            linkURL: nil
        ),
        Step(
            id: 2,
            systemImage: "person.crop.circle.badge.checkmark",
            title: "Sign in with JJHub",
            message: "Create or use a JJHub account, then connect a repository so Smithers can prepare an agent workspace.",
            linkTitle: "Sign up at jjhub.tech",
            linkURL: URL(string: "https://jjhub.tech")
        ),
        Step(
            id: 3,
            systemImage: "terminal",
            title: "Open a workspace → terminal + chat live here",
            message: "Pick a connected repo, open its workspace, and follow terminal output and agent chat in one place.",
            linkTitle: nil,
            linkURL: nil
        ),
        Step(
            id: 4,
            systemImage: "checkmark.shield",
            title: "Approve agent actions from your pocket",
            message: "Review requests when an agent needs permission, then approve or decline without leaving iOS.",
            linkTitle: nil,
            linkURL: nil
        ),
    ]

    let onComplete: () -> Void
    @State private var selectedStep = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: onComplete)
                    .accessibilityIdentifier("onboarding.skip")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            TabView(selection: $selectedStep) {
                ForEach(Self.steps) { step in
                    OnboardingStepView(step: step)
                        .tag(step.id)
                        .accessibilityIdentifier("onboarding.step.\(step.id)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Group {
                if selectedStep < Self.steps.count {
                    Button {
                        withAnimation(.easeInOut) {
                            selectedStep += 1
                        }
                    } label: {
                        Text("Next")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding.next")
                } else {
                    Button {
                        onComplete()
                    } label: {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding.get-started")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("onboarding.flow")
    }
}

private struct OnboardingStepView: View {
    let step: OnboardingFlow.Step

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)

            Image(systemName: step.systemImage)
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(step.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(step.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let linkTitle = step.linkTitle, let linkURL = step.linkURL {
                Link(linkTitle, destination: linkURL)
                    .font(.headline)
            }

            Spacer(minLength: 80)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
