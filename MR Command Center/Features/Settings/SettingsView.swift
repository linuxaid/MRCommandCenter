import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountsSettingsView()
            }
            Tab("Skills", systemImage: "book.closed") {
                SkillsSettingsView()
            }
            Tab("AI Review", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("Prompts", systemImage: "text.badge.star") {
                PromptsSettingsView()
            }
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Checks", systemImage: "checklist") {
                ChecksSettingsView()
            }
        }
        .frame(width: 760)
        .frame(minHeight: 560)
    }
}
