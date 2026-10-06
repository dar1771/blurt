import SwiftUI

struct ClipboardSyncSettingsView: View {
  @ObservedObject var model: ClipboardSyncModel
  @State private var code = ""
  @State private var showCode = false
  @State private var clearingFiles = false

  var body: some View {
    Form {
      Section {
        Toggle(
          "Синхронизировать буфер между Mac",
          isOn: Binding(
            get: { model.enabled }, set: { model.setEnabled($0) })
        )
        .disabled(!model.hasKey)
        .accessibilityIdentifier(UITestIdentifiers.clipboardSyncToggle)
        Text(model.status).foregroundStyle(.secondary)
          .accessibilityIdentifier(UITestIdentifiers.clipboardSyncStatus)
        if model.enabled {
          HStack {
            Button(model.paused ? "Продолжить" : "Пауза") { model.togglePause() }
            Button("Отправить текущий буфер") { model.sendNow() }.disabled(model.paused)
          }
        }
      } header: {
        Text("Общий буфер")
      } footer: {
        Text(
          "Текст, картинки и обычные файлы передаются с шифрованием между Mac в одной локальной сети. "
            + "Интернет и облако не используются. Приложение должно работать на обоих Mac.")
      }
      Section {
        if showCode {
          TextField("Код группы", text: $code).font(.system(.caption, design: .monospaced))
        } else {
          SecureField("Код группы", text: $code)
        }
        Toggle("Показать код", isOn: $showCode)
        if model.hasKey && code.isEmpty {
          Button("Показать сохранённый код") {
            if let stored = model.revealCode() {
              code = stored
              showCode = true
            }
          }
        }
        HStack {
          Button("Создать группу") {
            if let generated = model.generateCode() {
              code = generated
              showCode = true
            }
          }
          .accessibilityIdentifier(UITestIdentifiers.clipboardCreateGroup)
          Button("Подключиться") { model.installCode(code) }.disabled(code.isEmpty)
          Button("Скопировать код") { model.copyCode(code) }.disabled(code.isEmpty)
        }
      } header: {
        Text("Подключение Mac")
      } footer: {
        Text(
          "Создайте группу на первом Mac и введите тот же код на остальных. "
            + "Любой Mac с этим кодом получает и меняет общий буфер. Храните код в секрете. "
            + "Создание нового кода отключает связь с прежней группой.")
      }
      Section {
        Text(
          "До 20 МБ за одну передачу; до 16 файлов. Папки и ссылки не передаются. "
            + "Данные с метками секретного и временного буфера пропускаются. "
            + "Кэш до 200 МБ. Файлы старше 7 дней удаляются при новой передаче; для постоянного хранения вставьте их в Finder."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Удалить полученные файлы…", role: .destructive) { clearingFiles = true }
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .alert("Удалить полученные файлы?", isPresented: $clearingFiles) {
      Button("Удалить", role: .destructive) { Task { await model.clearReceivedFiles() } }
      Button("Отмена", role: .cancel) {}
    } message: {
      Text("Файлы в буфере перестанут вставляться. Сначала сохраните нужные файлы в Finder. Код группы останется.")
    }
  }
}
