# VibeDictate: подготовка релиза

Дата: 5 октября 2026. Ветка `codex/vibedictate`, PR
[#1](https://github.com/dar1771/blurt/pull/1). Релиз и merge не выполнялись.
Это проверка pipeline и конфигурации; подписанная Release-сборка не запускалась.

## Подготовлено

- Build создаёт `VibeDictate-<version>.dmg` с `VibeDictate.app` и
  `VibeDictate-<version>.app.dSYM.zip`. Upload, publish, контрольные суммы и
  повторная загрузка согласованы. Стабильный файл — `VibeDictate.dmg`.
- Подпись больше не использует закреплённые сертификат/Team ID прежнего Blurt.
  Build и install требуют явных проверенных pins VibeDictate. Формат проверяется
  до доступа к credentials; signer-pin проверяет сертификат готовых артефактов.
- CI preflight проверяет наличие полного выбранного набора notary secrets,
  а не только одного поля. Защита `release-build` и `release-publish` сохранена.
- Установка проверяет bundle ID `app.vibedictate`, версию, подпись, signer-pin
  и staple до замены приложения, затем проверяет установленную копию.
- Publish явно адресует `dar1771/blurt` и отвергает другой `origin`: GitHub CLI
  может выбрать upstream в checkout форка без явного указания репозитория.
- Reset-script адресует `app.vibedictate*`, сервисы `vibedictate*`, оба API-ключа
  и диагностические логи VibeDictate. Скрипт не запускался. История и сохранённое
  аудио остаются; встроенный reset также оставляет OpenRouter key — это явно
  описано в документации.
- README, CONTRIBUTING и RELEASE описывают VibeDictate, текущие режимы,
  локальное хранение, Dev-install и fork release URL. `BlurtEngine`, target,
  scheme, executable и исходные пути не переименованы.

## Проверки

Bash-тесты release helpers проверяют обязательные pins и отказ при неправильном
origin. Локальный `scripts/check.sh` прошёл сборку и тесты, но часть линтеров
отсутствует; UI/leak локально пропущены. Полный CI
[37297752398](https://github.com/dar1771/blurt/actions/runs/37297752398) на
коммите `7a6efb3cfbecd2f0a02ef45087adaf182dc2a3f4` завершился успешно:
check, compile и gate, включая UI/leak. Это подтверждает техническую доводку
pipeline, но не ручную приёмку и не подписанную Release-сборку.

Обработка файла 11:23 двумя реальными STT и нормализацией прошла отдельно
5 октября. Она обходит capture/session, историю и вставку; живая запись
около 10 минут остаётся непроверенной.

## Блокеры настоящего выпуска

1. Владелец должен подтвердить Developer ID Application и настроить в окружении
   `release-build` переменные `SIGNING_IDENTITY`, `SIGNING_SHA256`,
   `SIGNING_TEAM_ID` и соответствующие signing/notary secrets. Значения не
   угаданы по Apple Development подписи Dev-сборки.
2. GitHub API 5 октября около 13:43 МСК вернул `total_count: 0`: окружения
   `release-build` и `release-publish` отсутствовали. Перед выпуском нужно
   создать их и настроить branch restrictions / required reviewers. Через API
   настройки не изменялись.
3. Не завершена [ручная приёмка](./VIBEDICTATE_ACCEPTANCE.md), включая запись
   около 10 минут, полный сбой OpenRouter, смену фокуса, историю/плеер, iPhone
   и нумерацию. Автоматические UI doubles не подтверждают эти сценарии.
4. После отдельного решения владельца нужен build/sign/notarize dry run,
   установка из DMG, проверка разрешений и update-download на реальном Mac.
   Публикация и merge требуют отдельных решений.

Версия сохранена `0.1.56`. Эта доводка не меняет `project.yml`, не запускает
release-bump или release и не публикует артефакты. Инструкция по настройке
сертификата и окружений — [RELEASE.md](./RELEASE.md).
