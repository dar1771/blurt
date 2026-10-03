import BlurtEngine
import SwiftUI

struct VibeDictateSettingsTab: View {
  @ObservedObject var history: HistoryModel
  @State private var openRouterKey = ""
  @State private var vocabulary = VocabularyStore().terms.joined(separator: ", ")
  @State private var saveMessage: String?
  @AppStorage(OpenRouterModelStore.defaultsKey)
  private var modelID = OpenRouterTextNormalizer.defaultModel

  var body: some View {
    Form {
      Section("Сервисы") {
        SecureField("Ключ API OpenRouter", text: $openRouterKey)
        TextField("Модель OpenRouter", text: $modelID)
        Button("Сохранить настройки API") { saveAPIs() }
      }

      Section("Словарь") {
        TextEditor(text: $vocabulary)
          .font(.body.monospaced())
          .frame(minHeight: 90)
        Button("Сохранить словарь") { saveVocabulary() }
      }

      Section("История") {
        LabeledContent("Хранение текста", value: "30 дней")
        LabeledContent("Хранение аудио", value: "3 дня")
        Button("Очистить историю", role: .destructive) { history.clearHistory() }
      }

      Section("Конфиденциальность") {
        Text(
          "VibeDictate не собирает аналитику и телеметрию. Аудио и текст хранятся на этом Mac, "
            + "кроме отправки в настроенные вами сервисы AssemblyAI и OpenRouter."
        )
        .foregroundStyle(.secondary)
      }

      if let saveMessage {
        Text(saveMessage).font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(minHeight: 430)
    .onAppear {
      #if UITEST_HOOKS
        if UITestMode.isActive { return }
      #endif
      openRouterKey = OpenRouterAPIKeyStore.current ?? ""
    }
  }

  private func saveAPIs() {
    let keySaved = OpenRouterAPIKeyStore.save(openRouterKey)
    OpenRouterModelStore().save(modelID)
    modelID = OpenRouterModelStore().modelID
    saveMessage = keySaved ? "Настройки API сохранены." : "Не удалось сохранить ключ OpenRouter."
  }

  private func saveVocabulary() {
    let terms =
      vocabulary
      .split(whereSeparator: { $0 == "," || $0 == "\n" })
      .map(String.init)
    VocabularyStore().save(terms)
    vocabulary = VocabularyStore().terms.joined(separator: ", ")
    saveMessage = "Словарь сохранён."
  }
}
