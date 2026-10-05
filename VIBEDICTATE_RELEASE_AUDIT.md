# VibeDictate: аудит подготовки релиза

Дата: 5 октября 2026. Проверены файлы ветки `codex/vibedictate` в PR [#1](https://github.com/dar1771/blurt/pull/1). Это проверка кода и конфигурации, не пробная подписанная Release-сборка. Релиз не публиковался.

## Вывод

Текущий release pipeline **не готов выпускать VibeDictate**. Сборка приложения в `App/Blurt/project.yml` использует `app.vibedictate` и отображаемое имя `VibeDictate`, но выпуск, установка, ссылки на скачивание и документация по-прежнему рассчитаны на Blurt. CI `check.sh` подтверждает разработческую сборку; он не выполняет подпись Developer ID, нотариализацию или публикацию.

- `scripts/release-build.sh`: закреплены Developer ID fingerprint и Team ID
  `B2VQF7Q2QY` прежнего проекта. DMG содержит `Blurt.app`; образ и dSYM
  называются `Blurt-*`. Перед выпуском нужны Developer ID Application и
  нотариальные данные команды VibeDictate, проверенные fingerprint/Team ID и
  артефакты с именем VibeDictate.
- `.github/workflows/release.yml` и `scripts/release-publish.sh` загружают
  `Blurt-*` и публикуют `Blurt.dmg`. Имена нужно согласовать в upload, publish,
  контрольных суммах и повторной загрузке. Нужно проверить защиту окружений
  `release-build` и `release-publish` в настройках репозитория.
- `scripts/release-install.sh` ищет в DMG `Blurt.app` и устанавливает
  `/Applications/Blurt.app`. Нужно устанавливать VibeDictate и проверять его
  bundle ID, версию, подпись и staple.
- `scripts/reset-install.sh` удаляет разрешения и ключи старых
  `dev.alex.blurt*`, не затрагивает `app.vibedictate*`. Нужно обновить bundle ID,
  имена приложений, сервисы Keychain и каталог логов. Этот скрипт удаляет
  разрешения и ключи; его нельзя запускать на пользовательском Mac без решения.
- `README.md`, `CONTRIBUTING.md`, `RELEASE.md` описывают Blurt и содержат
  ссылки на релизы `AssemblyAI/blurt`, включая скачивание `Blurt.dmg`.
  В `CONTRIBUTING.md` также устарели bundle ID и путь Dev-приложения. Нужно
  обновить инструкции для VibeDictate и текущего репозитория. Технические
  идентификаторы `BlurtEngine`, Xcode target, scheme и пути исходников пока
  сохраняются.
- Feed в `Sources/BlurtEngine/HostIdentity.swift` уже указывает на
  `dar1771/blurt/releases/latest`; `GitHubRelease` выбирает первый `.dmg`.
  После переименования артефакта нужно проверить обновление приложения на
  пробном сценарии до выдачи ссылки пользователям.

Версия в `project.yml` ветки и в `main` репозитория `dar1771/blurt` на дату аудита одинаковая: `0.1.56`. Поэтому один только merge текущего PR не должен запустить автоматический выпуск по правилу изменения версии. Доступ к значениям GitHub secrets и настройкам protected environments этим аудитом не подтверждён. Локальный `security find-identity -v -p codesigning` в текущем окружении не показал действительных подписывающих сертификатов; это не проверяет секреты GitHub Actions.

## Следующий этап

1. Завершить оставшиеся сценарии ручной приёмки из `VIBEDICTATE_ACCEPTANCE.md`.
2. Исправить согласованно release-скрипты, workflow и документацию, проверить `scripts/check.sh` и CI в этом PR.
3. После настройки Developer ID и нотариальных данных выполнить **только build/sign/notarize dry run** из ветки, скачать DMG и проверить установку на Mac. Публикация релиза и merge требуют отдельного решения пользователя.
