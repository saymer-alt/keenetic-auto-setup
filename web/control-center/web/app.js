'use strict';
const words={
 ru:{
  openMihomo:'Открыть MetaCubeXD ↗',openMT:'Открыть MagiTrickle ↗',openGenerator:'Открыть генератор конфигов ↗',serviceLinksNote:'Ссылки ведут на адрес этого роутера и стандартные порты: MagiTrickle 8080, MetaCubeXD 9090. Доступность панелей не проверяется. Если порты изменены, используйте их фактические адреса.',serviceLinksProxy:'Для открытия MagiTrickle и MetaCubeXD перейдите к локальному HTTP-адресу роутера: внешний HTTPS-адрес панели не определяет адреса этих сервисов.',appearanceHeading:'Внешний вид',themeLabel:'Тема',themeAuto:'Как в системе',themeLight:'Светлая',themeDark:'Тёмная',themeHelp:'Выбор сохраняется только в этом браузере и не меняет настройки роутера.',
  updatesHeading:'Обновления Mihomo',updatesHelp:'Ручная проверка канала entware-go:latest. Обновление выполняет штатный KAS; конфиг сохраняется. Mihomo может ненадолго остановиться. Обновление MagiTrickle доступно в отдельном блоке ниже.',updateCheck:'Проверить обновления Mihomo',updateApply:'Обновить Mihomo',updateNone:'Проверка обновлений ещё не выполнялась.',updateChecking:'Проверяем доступную версию…',updateAvailable:'Работающий Mihomo: {current}. Пакет на GitHub: {available}-{release}.',updateOlder:'Доступная версия старее установленной. Понижение версии не предлагается.',updateSame:'Версия Mihomo совпадает. Выпуск пакета по записи KAS не подтверждён.',updatePackageMetadata:'Данные opkg: {version} (могут отличаться от работающего файла).',updateSamePackage:'Обновление не требуется: версия и записанный выпуск пакета совпадают.',updateNewerPackage:'Доступен новый выпуск пакета для этой версии Mihomo.',updateOlderPackage:'Доступный выпуск пакета старее записи KAS. Понижение не предлагается.',updateInvalidState:'Запись KAS не соответствует текущему файлу. Обновление этого выпуска заблокировано; проверьте Doctor.',updateUnknown:'Текущая версия не подтверждена; решение примет штатный скрипт KAS.',updateConfirm:'Запустить штатное обновление Mihomo из entware-go:latest? KAS заново проверит доступный пакет. Возможна короткая остановка Mihomo. Конфиг сохраняется. Не перезагружайте роутер во время операции.',updateRunning:'Обновление Mihomo выполняется. Не перезагружайте роутер.',updateChanged:'Обновление завершено. Файл Mihomo изменён.',updateUnchanged:'Обновление завершено. Файл Mihomo не изменился.',updateUnverified:'Обновление завершено; изменение файла не подтверждено. Проверьте состояние через Doctor.',updateFailed:'Обновление не завершилось успешно. Проверьте фактическое состояние через Doctor; откат не подтверждён.',updateRequestError:'Не удалось получить состояние обновления: {code}. Если операция была запущена, она может продолжаться.',updateCheckError:'Не удалось проверить обновления: {code}.',updateCancelled:'Обновление отменено до запуска.',

  mtHeading:'Обновления MagiTrickle',mtHelp:'Проверка обновляет индексы подключённых репозиториев opkg. Установка обновляет только пакет MagiTrickle и его зависимости; сервис перезапускается, возможен перерыв DNS и маршрутизации. Автоматический откат пакета не предусмотрен.',mtCheck:'Проверить обновления MagiTrickle',mtApply:'Обновить MagiTrickle',mtChecking:'Обновляем индексы opkg и проверяем MagiTrickle…',mtAvailable:'Установленный пакет: {current}. Доступно обновление: {available}.',mtNoUpgrade:'Установленный пакет: {current}. Подключённые репозитории не предлагают обновление.',mtConfirm:'Обновить пакет MagiTrickle через opkg и перезапустить сервис? Возможен временный перерыв DNS и маршрутизации. Пакет сохраняет изменённые конфиги по правилам opkg; автоматического отката нет. Не перезагружайте роутер.',mtRunning:'Обновление MagiTrickle выполняется. Не перезагружайте роутер.',mtChanged:'Пакет MagiTrickle обновлён; процесс запущен, конфиги не изменились. Доступ клиентов не проверен.',mtUnchanged:'Обновление MagiTrickle не требуется. Сервис не перезапускался.',mtFailed:'Обновление MagiTrickle не подтверждено: {code}. Проверьте состояние через Doctor; автоматического отката нет.',
  processRunning:'Процесс запущен',processStopped:'Процесс не найден',processAbsent:'Не установлен',processUnknown:'Процесс не удалось проверить',runtimeVersion:'{version} (API)',packageVersion:'{version} (пакет)',watchdogDigest:'Установлен · SHA256 {sha}',doctorOK:'Диагностика завершена. Ошибок и предупреждений не обнаружено.',doctorWARN:'Диагностика завершена. Предупреждения: {warn}; ошибки: {fail}.',doctorFAIL:'Диагностика завершена. Ошибки: {fail}; предупреждения: {warn}.',doctorUnknown:'Диагностика завершена. Итоговый результат не распознан — проверьте отчёт.',processHelp:'Процессы проверены по исполняемым файлам. Это не проверка доступа в Интернет. Версия пакета может отличаться от работающей программы.',
  versionsHeading:'Версии',coreLabel:'Комплект KAS',watchdogLabel:'Применённый watchdog',versionsHelp:'Версия пакета и применённого watchdog могут различаться. Это сведения о файлах, а не проверка работающих сервисов.',projectLink:'Проект на GitHub',buildDevelopment:'сборка для разработки',versionsUnavailable:'Сведения недоступны',coreAbsent:'Без пакета kas-core',coreModified:'Файлы комплекта изменены',versionIdentity:'{version} · {sha}',watchdogCurrent:'{version} · файл совпадает с записью',watchdogUnrecorded:'Версия не подтверждена',watchdogStale:'Файл отличается от записи о применении',watchdogBundleChanged:'Применён {version}; комплект обновлён',watchdogInvalid:'Запись о применении недоступна',
  settingsHeading:'Порт и вход',settingsHelp:'По HTTP пароль передаётся без шифрования. Для защищённого подключения используйте VPN или HTTPS.',settingsPort:'Порт панели (1–65535)',settingsMode:'Вход в панель',settingsNone:'Без пароля',settingsEntware:'Учётная запись Entware / SSH',settingsPanel:'Отдельный пароль панели',settingsLogin:'Логин: {login}',settingsCurrent:'Пароль текущего входа ({login}) для подтверждения',settingsPassword:'Новый пароль панели',settingsRootPassword:'Действующий пароль root в Entware',settingsRepeat:'Повторите новый пароль',settingsPanelHelp:'Логин kas. Пароль: 12–128 байт. Пустое поле сохраняет уже заданный пароль панели.',settingsEntwareHelp:'Логин root. Проверяется действующий пароль Entware; системный пароль не изменяется. Для входа по HTTP используйте доверенную сеть или VPN.',settingsNoneHelp:'Вход без пароля; доступ определяется сетью и настройкой Home ниже.',settingsLoading:'Читаем порт и настройки входа…',settingsSaving:'Сохраняем настройки…',settingsError:'Настройки не сохранены или не прочитаны: {code}',settingsSaved:'Настройки сохранены.',settingsPortChanged:'Настройки сохранены. Откройте новый адрес панели:',settingsInvalid:'Укажите порт 1–65535 и поддерживаемый способ входа.',settingsPasswordInvalid:'Новый пароль должен занимать 12–128 байт и совпадать с повтором.',settingsCurrentRequired:'Введите текущий пароль для подтверждения.',settingsRootRequired:'Введите действующий пароль root в Entware.',settingsConfirm:'Сохранить настройки? {warning}',settingsDisableWarning:'Вход по паролю будет отключён.',settingsPortWarning:'Порт изменится с {before} на {after}; откройте новый адрес после сохранения.',settingsCancelled:'Изменение отменено.',
  operationDismiss:'Закрыть уведомление',operationDetails:'Подробнее',navOverview:'Обзор',navSubscriptions:'Подписки',navConfiguration:'Конфигурация',navDiagnostics:'Диагностика',navSettings:'Настройки',overviewDescription:'Основные сведения и быстрый доступ к управлению.',subscriptionsDescription:'Выбирайте, какие серверы использовать в подписках.',configurationDescription:'Загрузка готовой конфигурации Mihomo.',diagnosticsDescription:'Проверка KAS и отчёт для поиска проблем.',settingsDescription:'Параметры доступа к панели.',experiment:'Экспериментальная версия',localBadge:'Панель роутера ↗',quickHeading:'Управление',quickSubscriptions:'Серверы подписки',quickSubscriptionsHelp:'Выбрать серверы для исключения',quickConfiguration:'Загрузить конфиг',quickConfigurationHelp:'Применить готовый YAML',searchLabel:'Поиск серверов',searchPlaceholder:'Название сервера',nodesHeading:'Серверы',selectionCount:'Выбрано: {selected} · Показано: {visible} из {total}',searchEmpty:'По этому запросу серверов нет.',filterEmpty:'Загрузите список, чтобы выбрать серверы.',filterDetails:'Действующий фильтр',exportHelpLabel:'Для чего нужен экспорт?',filePresent:'Файл найден',fileAbsent:'Файл не найден',fileUnknown:'Нет данных',footerNote:'Управление на вашем роутере',skipLink:'К содержимому',
  accessHeading:'Доступ к панели',accessHomeOnly:'Разрешать доступ только из домашней сети Home',accessHelp:'По умолчанию ограничение выключено: можно подключаться из других подсетей, включая SSTP/L2TP, если это разрешают маршруты и firewall роутера. Эта опция не открывает порты и не настраивает VPN.',accessSave:'Сохранить',accessLoading:'Читаем настройку доступа…',accessOn:'Ограничение Home включено. Другие подсети, включая VPN, отклоняются.',accessOff:'Ограничение Home выключено. Доступ определяется маршрутами и firewall роутера.',accessError:'Не удалось изменить или прочитать настройку: {code}',accessEnableConfirm:'Разрешить доступ только из Home? Подключение через VPN или другую подсеть может потерять доступ к панели. Восстановить доступ можно из Home или через SSH.',accessDisableConfirm:'Выключить ограничение Home? Панель станет доступна из других подсетей, которым firewall разрешает подключаться к её адресу.',
  scope:'Экспериментальная панель. Доступ к адресу роутера определяется его маршрутами и firewall; пароль и ограничение Home необязательны.',status:'Состояние',unknown:'Состояние сети не проверено',binary:'Файлы: Mihomo {m}; MagiTrickle {mt}. Наличие файла не означает работающий сервис.',present:'есть',absent:'не найден',refresh:'Обновить',
  config:'Конфигурация Mihomo',configHelp:'Загрузите готовый config.yaml или вставьте его содержимое. Если выбран файл, будет использован он. Данные не сохраняются в хранилище браузера.',fileLabel:'Выберите файл YAML',pasteLabel:'Или вставьте конфигурацию',warning:'Внимание: применение может временно остановить Mihomo. Предыдущая конфигурация сохраняется и откатывается штатным импортером при предусмотренных им ошибках. Во время операции не перезагружайте роутер.',apply:'Применить YAML',confirm:'Заменить текущий config.yaml? Mihomo может быть временно перезапущен.',applying:'Импорт выполняется. Не выключайте роутер…',importOk:'Импортер завершён успешно. Код выхода: {exit}',importFail:'Импортер сообщил об ошибке. Код выхода: {exit}. Подробности и фактическое состояние проверьте через Doctor/SSH. {code}',importNone:'Импорт ещё не выполнялся.',importError:'Не удалось выполнить запрос импорта: {code}',fileTooLarge:'YAML слишком большой (лимит 1 МиБ).',emptyFile:'Выберите YAML или вставьте его содержимое.',
  providers:'Экспорт имён серверов',providersHelp:'Можно скачать совместимый с Mihomo Unified Generator JSON: только имена узлов и провайдеров, без паролей и адресов. Затем в генераторе выберите «Импорт узлов из работающего Mihomo» → «Загрузить .json». Сам Mihomo не изменяется.',providersDownload:'Скачать JSON имён узлов',providersDisabled:'Экспорт не включён администратором',providersWorking:'Получаем список из работающего Mihomo…',providersSuccess:'Файл имён узлов сохранён. Загрузите его в Mihomo Builder и выберите исключения.',providersError:'Не удалось получить имена: {code}. Проверьте доступность локального API Mihomo и его secret.',
  filterHeading:"Серверы подписки",filterHelp:"Отметьте серверы, которые нужно исключить из подписки. Остальные настройки конфига сохранятся.",filterLoad:"Загрузить список серверов",filterProviderLabel:'Провайдер:',filterPreview:"Исключить выбранные",filterClear:"Снять фильтр",filterHint:"Галочка означает исключить сервер. Уже исключённые серверы могут отсутствовать в списке. Снятие фильтра отменяет все его исключения.",filterNoProvider:'Поддерживаемых HTTP-провайдеров нет',filterExisting:'Существующий exclude-filter: {filter}',filterNoFilter:'не задан',filterLoading:'Читаем локальные данные…',filterLoaded:'Провайдеры загружены. Выберите исключения.',filterNamesUnavailable:'Имена узлов недоступны: {code}. Существующий фильтр можно снять; выбор исключений станет доступен после обновления списка.',filterDisabled:'Редактор недоступен в этом режиме запуска панели. В установленном IPK используйте штатный запуск службы панели.',filterCannotLoad:'Не удалось прочитать данные: {code}',filterNoNames:'Доступных узлов нет (либо они уже скрыты действующим фильтром).',filterTooMany:'Показаны первые {count} узлов; полный список доступен в JSON-экспорте.',filterPreviewing:"Проверяем изменение…",filterPreviewReady:"Изменение проверено.",filterPreviewError:'Ошибка предпросмотра: {code}',filterNothing:'Выберите хотя бы один узел.',filterProposed:"Фильтр сейчас: {before}\nПосле изменения: {after}",filterApply:'Применить показанное изменение',filterClearConfirm:"Снять фильтр провайдера «{provider}»? Это отменит все исключения этого фильтра. Mihomo может быть кратковременно перезапущен.",filterCancelled:"Изменение отменено.",filterApplyConfirm:"Исключить выбранные серверы ({count}) из провайдера «{provider}»? Существующий фильтр будет заменён. Mihomo может быть кратковременно перезапущен.",filterApplying:'Применение выполняется штатным импортёром. Не выключайте роутер…',filterApplyDone:'Штатный импортёр завершён успешно.',filterApplyReady:"Фильтр обновлён. Список серверов загружен заново.",filterApplyNoChange:"Изменения не требуются.",filterApplyError:'Не удалось запустить применение: {code}',filterApplyFail:'Импортёр сообщил об ошибке. Изменение могло не примениться; фактическое состояние проверьте через Doctor/SSH.',
  doctor:'Диагностика Doctor',help:'Запуск штатного Doctor по запросу. Результат не означает, что маршрутизация каждого клиента проверена.',run:'Запустить Doctor',copy:'Копировать отчёт',copyDone:'Отчёт скопирован.',copyManual:'Браузер запретил копирование. Отчёт выделен — нажмите Ctrl+C или выберите «Копировать» в меню.',details:'Реальный вывод команды',running:'Doctor выполняется…',finished:'Команда завершена; код выхода: {exit}',failed:'Команда не завершилась успешно; код выхода: {exit}; ошибка: {code}',error:'Не удалось выполнить запрос: {code}',footer:'Перед отправкой отчёта проверьте, что в нём нет личных данных. При ошибке импорта проверьте фактическое состояние через Doctor или SSH.',timestamp:'Время: {time}',notrun:'Doctor ещё не запускался.'
 },
 en:{
  openMihomo:'Open MetaCubeXD ↗',openMT:'Open MagiTrickle ↗',openGenerator:'Open config generator ↗',serviceLinksNote:'Links use this router address and default ports: MagiTrickle 8080, MetaCubeXD 9090. Panel reachability is not tested. If ports were changed, use their actual addresses.',serviceLinksProxy:'Use the router’s local HTTP address to open MagiTrickle and MetaCubeXD: an external HTTPS panel address does not establish these service addresses.',appearanceHeading:'Appearance',themeLabel:'Theme',themeAuto:'System default',themeLight:'Light',themeDark:'Dark',themeHelp:'This choice is saved only in this browser and does not change router settings.',
  updatesHeading:'Mihomo updates',updatesHelp:'Manual check of entware-go:latest. The canonical KAS updater preserves the config. Mihomo may stop briefly. MagiTrickle has separate update controls below.',updateCheck:'Check Mihomo updates',updateApply:'Update Mihomo',updateNone:'Updates have not been checked.',updateChecking:'Checking available version…',updateAvailable:'Running Mihomo: {current}. Package on GitHub: {available}-{release}.',updateOlder:'The available version is older. Downgrade is not offered.',updateSame:'The Mihomo version matches. The KAS package release is unconfirmed.',updatePackageMetadata:'opkg metadata: {version} (may differ from the running file).',updateSamePackage:'No update required: version and recorded package release match.',updateNewerPackage:'A newer package release is available for this Mihomo version.',updateOlderPackage:'The available package release is older than the KAS record. No downgrade is offered.',updateInvalidState:'The KAS record does not match the current file. Package update blocked; check Doctor.',updateUnknown:'The installed version is unconfirmed; the canonical updater decides.',updateConfirm:'Run the canonical Mihomo update from entware-go:latest? The updater will recheck the available package. Mihomo may stop briefly. The config is preserved. Do not reboot during the operation.',updateRunning:'The canonical Mihomo updater is running. Do not reboot.',updateChanged:'The canonical updater finished. The Mihomo file changed.',updateUnchanged:'The canonical updater finished. The Mihomo file did not change.',updateUnverified:'The canonical updater finished; file change is unconfirmed. Check with Doctor.',updateFailed:'The update did not finish successfully. Check actual state with Doctor; rollback is unconfirmed.',updateRequestError:'Could not retrieve update state: {code}. A previously started operation may still be running.',updateCheckError:'Could not check updates: {code}.',updateCancelled:'Update cancelled before starting.',

  mtHeading:'MagiTrickle updates',mtHelp:'Checking refreshes configured opkg repository indices. Installation updates only MagiTrickle and its dependencies and restarts the service; DNS and routing may pause. No automatic package rollback.',mtCheck:'Check MagiTrickle updates',mtApply:'Update MagiTrickle',mtChecking:'Refreshing opkg indices and checking MagiTrickle…',mtAvailable:'Installed package: {current}. Available update: {available}.',mtNoUpgrade:'Installed package: {current}. Configured repositories offer no upgrade.',mtConfirm:'Update MagiTrickle through opkg and restart its service? DNS and routing may pause. opkg conffile rules apply; no automatic rollback. Do not reboot.',mtRunning:'MagiTrickle update is running. Do not reboot.',mtChanged:'MagiTrickle package updated; process running and configs unchanged. Client connectivity not tested.',mtUnchanged:'No MagiTrickle update required. Service was not restarted.',mtFailed:'MagiTrickle update is unconfirmed: {code}. Check Doctor; no automatic rollback.',
  processRunning:'Process running',processStopped:'Process not found',processAbsent:'Not installed',processUnknown:'Process could not be checked',runtimeVersion:'{version} (API)',packageVersion:'{version} (package)',watchdogDigest:'Installed · SHA256 {sha}',doctorOK:'Diagnostics completed. No errors or warnings found.',doctorWARN:'Diagnostics completed. Warnings: {warn}; errors: {fail}.',doctorFAIL:'Diagnostics completed. Errors: {fail}; warnings: {warn}.',doctorUnknown:'Diagnostics completed. Summary not recognized — review the report.',processHelp:'Processes checked against their executable files. Internet access has not been tested. Package versions can differ from running programs.',
  versionsHeading:'Versions',coreLabel:'KAS tools package',watchdogLabel:'Applied watchdog',versionsHelp:'The package and applied watchdog versions can differ. These are file identities, not running-service health checks.',projectLink:'Project on GitHub',buildDevelopment:'development build',versionsUnavailable:'Information unavailable',coreAbsent:'No kas-core package',coreModified:'Package files have changed',versionIdentity:'{version} · {sha}',watchdogCurrent:'{version} · file matches the receipt',watchdogUnrecorded:'Version not confirmed',watchdogStale:'File differs from its activation receipt',watchdogBundleChanged:'Applied {version}; package has changed',watchdogInvalid:'Activation receipt unavailable',
  settingsHeading:'Port and sign-in',settingsHelp:'HTTP sends passwords without encryption. Use VPN or HTTPS for a protected connection.',settingsPort:'Panel port (1–65535)',settingsMode:'Panel sign-in',settingsNone:'No password',settingsEntware:'Entware / SSH account',settingsPanel:'Separate panel password',settingsLogin:'Login: {login}',settingsCurrent:'Current sign-in password ({login}) to confirm changes',settingsPassword:'New panel password',settingsRootPassword:'Existing Entware root password',settingsRepeat:'Repeat new password',settingsPanelHelp:'Login kas. Password: 12–128 bytes. Leave empty to keep an existing panel password.',settingsEntwareHelp:'Login root. Verifies the existing Entware password; the system password is never changed. Use a trusted network or VPN for HTTP login.',settingsNoneHelp:'No password; network reachability and the Home setting below determine access.',settingsLoading:'Reading port and sign-in settings…',settingsSaving:'Saving settings…',settingsError:'Settings could not be saved or read: {code}',settingsSaved:'Settings saved.',settingsPortChanged:'Settings saved. Open the new panel address:',settingsInvalid:'Enter a port from 1–65535 and a supported sign-in mode.',settingsPasswordInvalid:'The new password must be 12–128 bytes and match its repeat.',settingsCurrentRequired:'Enter the current password to confirm changes.',settingsRootRequired:'Enter the existing Entware root password.',settingsConfirm:'Save settings? {warning}',settingsDisableWarning:'Password sign-in will be disabled.',settingsPortWarning:'The port will change from {before} to {after}; open the new address after saving.',settingsCancelled:'Change cancelled.',
  operationDismiss:'Dismiss notification',operationDetails:'Details',navOverview:'Overview',navSubscriptions:'Subscriptions',navConfiguration:'Configuration',navDiagnostics:'Diagnostics',navSettings:'Settings',overviewDescription:'Essential information and quick access to controls.',subscriptionsDescription:'Choose which servers to use in your subscriptions.',configurationDescription:'Upload a complete Mihomo configuration.',diagnosticsDescription:'Check KAS and collect a troubleshooting report.',settingsDescription:'Control access to this panel.',experiment:'Experimental version',localBadge:'Router panel ↗',quickHeading:'Quick actions',quickSubscriptions:'Subscription servers',quickSubscriptionsHelp:'Choose servers to exclude',quickConfiguration:'Upload configuration',quickConfigurationHelp:'Apply a complete YAML file',searchLabel:'Search servers',searchPlaceholder:'Server name',nodesHeading:'Servers',selectionCount:'Selected: {selected} · Showing: {visible} of {total}',searchEmpty:'No servers match your search.',filterEmpty:'Load the list to choose servers.',filterDetails:'Current filter',exportHelpLabel:'What is this export for?',filePresent:'Binary file found',fileAbsent:'Binary file not found',fileUnknown:'No data',footerNote:'Management on your router',skipLink:'Skip to content',
  accessHeading:'Panel access',accessHomeOnly:'Allow access only from the Home subnet',accessHelp:'Off by default: other subnets, including SSTP/L2TP, can connect when router routing and firewall allow it. This setting does not open ports or configure VPN.',accessSave:'Save',accessLoading:'Reading access policy…',accessOn:'Home-only restriction is enabled. Other subnets, including VPN clients, are rejected.',accessOff:'Home-only restriction is off. Router routing and firewall determine access.',accessError:'Unable to save or read access policy: {code}',accessEnableConfirm:'Restrict access to Home? VPN or other-subnet clients may lose panel access. Recovery requires Home access or SSH.',accessDisableConfirm:'Disable the Home-only restriction? Other subnets allowed by the router firewall will be able to reach the panel.',
  scope:'Experimental panel. Router routing and firewall determine reachability; password and Home-only restriction are optional.',status:'Status',unknown:'Network health has not been tested',binary:'Files: Mihomo {m}; MagiTrickle {mt}. Presence does not prove service health.',present:'found',absent:'not found',refresh:'Refresh',
  config:'Mihomo configuration',configHelp:'Upload a complete config.yaml or paste its contents. A selected file takes precedence. Configuration data is not saved in browser storage.',fileLabel:'YAML file (takes precedence if selected):',pasteLabel:'Or paste complete YAML:',warning:'Warning: applying may temporarily stop Mihomo. The canonical importer maintains previous-config backup and rollback for the failures it handles. Do not reboot the router mid-operation.',apply:'Apply YAML',confirm:'Replace current config.yaml? Mihomo might restart temporarily.',applying:'Import is running. Do not power off the router…',importOk:'Importer finished successfully. Exit code: {exit}',importFail:'Importer failed. Exit code: {exit}. Check the actual state with Doctor/SSH. {code}',importNone:'No import has been started.',importError:'Import request failed: {code}',fileTooLarge:'YAML exceeds 1 MiB.',emptyFile:'Select a YAML file or paste its contents.',
  providers:'Export server names',providersHelp:'Download a JSON compatible with Mihomo Unified Generator: provider and node names only, no server addresses or passwords. In the builder use “Import nodes from running Mihomo” → “Upload .json”. This does not change Mihomo.',providersDownload:'Download node names JSON',providersDisabled:'Export is not enabled by the administrator',providersWorking:'Reading active Mihomo providers…',providersSuccess:'Names JSON saved. Upload it to Mihomo Builder and choose exclusions.',providersError:'Unable to read names: {code}. Check the local Mihomo API and its secret.',
  filterHeading:"Subscription servers",filterHelp:"Select servers to exclude from this subscription. Other configuration settings are preserved.",filterLoad:"Load server list",filterProviderLabel:'Provider:',filterPreview:"Exclude selected",filterClear:"Clear filter",filterHint:"Checked servers will be excluded. Already excluded servers may be absent from the list. Clearing the filter removes all of its exclusions.",filterNoProvider:'No supported HTTP providers',filterExisting:'Existing exclude-filter: {filter}',filterNoFilter:'not set',filterLoading:'Reading local data…',filterLoaded:'Providers loaded. Select exclusions.',filterNamesUnavailable:'Node names unavailable: {code}. You can clear the existing filter; exclusion selection requires refreshing the node list.',filterDisabled:'The editor is unavailable in this launch mode. For an installed IPK, use the normal panel service startup.',filterCannotLoad:'Cannot read data: {code}',filterNoNames:'No visible nodes (or already hidden by the active filter).',filterTooMany:'Showing first {count} nodes; full list is available via JSON export.',filterPreviewing:"Checking the change…",filterPreviewReady:"Change checked.",filterPreviewError:'Preview error: {code}',filterNothing:'Select at least one node.',filterProposed:"Current filter: {before}\nAfter change: {after}",filterApply:'Apply shown change',filterClearConfirm:"Clear the filter for provider \u201c{provider}\u201d? This removes all exclusions in that filter. Mihomo may restart briefly.",filterCancelled:"Change cancelled.",filterApplyConfirm:"Exclude selected servers ({count}) from provider “{provider}”? The existing filter will be replaced. Mihomo may restart briefly.",filterApplying:'Applying through the canonical importer. Do not power off the router…',filterApplyDone:'The canonical importer completed successfully.',filterApplyReady:"Filter updated. Server list refreshed.",filterApplyNoChange:"No changes needed.",filterApplyError:'Could not start the apply: {code}',filterApplyFail:'The importer reported an error. The change may not be applied; check the actual state with Doctor/SSH.',
  doctor:'Doctor diagnostics',help:'Run the canonical Doctor on demand. This does not prove every client route.',run:'Run Doctor',copy:'Copy report',copyDone:'Report copied.',copyManual:'The browser blocked copying. The report is selected — press Ctrl+C or choose Copy from the menu.',details:'Original command output',running:'Doctor is running…',finished:'Command finished; exit code: {exit}',failed:'Command did not complete successfully; exit code: {exit}; error: {code}',error:'Request failed: {code}',footer:'Do not claim rollback without checking the actual router state. Review diagnostics manually before sharing.',timestamp:'Time: {time}',notrun:'Doctor has not been run yet.'
 }
};
let lang=(navigator.language||'en').toLowerCase().startsWith('ru')?'ru':'en';
try{const s=localStorage.getItem('kas_lang');if(s==='ru'||s==='en')lang=s;}catch(_){}
let componentsData=null;
let mtCheckData=null,mtChecking=false,mtMessage='';
let updateCheckData=null,updateOperation=null,updateChecking=false,updateSubmitting=false,updateMessage='',updatePollTimer=null,updateEpoch=0,updateKnownID=null;
let statusData=null,doctorData=null,busy=false,importData=null,submitting=false,pollTimer=null,importMessage='';
let exporting=false,providerMessage='';
let lastOperation='import',importView='configuration',copyStatus='';
let importObserved=false,importDismissed=false;
let accessData=null,accessBusy=false,accessStatus='';
let settingsData=null,settingsBusy=false,settingsStatus='';
let filterInspect=null,filterNodes=null,filterStatus='',filterSelectedProvider='',filterLoading=false,filterBusy=false;
let filterPending=null,filterAwaitingApply=false;
const el=id=>document.getElementById(id);
const t=(key,params={})=>{
 const value=words[lang][key]??words.en[key]??key;
 return value.replace(/\{(\w+)\}/g,(_,k)=>String(params[k]??''));
};
const set=(id,value)=>{el(id).textContent=value;};
function draw(){
 drawSettings();
 drawComponents();
 document.documentElement.lang=lang;
 const view=document.documentElement.dataset?.view||'overview';
 set('page-title',t({overview:'navOverview',subscriptions:'navSubscriptions',configuration:'navConfiguration',diagnostics:'navDiagnostics',settings:'navSettings'}[view]));
 set('page-description',t({overview:'overviewDescription',subscriptions:'subscriptionsDescription',configuration:'configurationDescription',diagnostics:'diagnosticsDescription',settings:'settingsDescription'}[view]));
 el('filter-search').placeholder=t('searchPlaceholder');
 set('mihomo-file',serviceText('mihomo',statusData?.mihomo_binary));
 set('magitrickle-file',serviceText('magitrickle',statusData?.magitrickle_binary));
 if(el('filter-empty'))set('filter-empty',t('filterEmpty'));
 updateFilterSearch();
 set('access-state',accessBusy?t('accessLoading'):accessStatus||(accessData?t(accessData.home_only?'accessOn':'accessOff'):''));
 el('access-home-only').disabled=accessBusy||!accessData;el('access-save').disabled=accessBusy||!accessData;
 for(const [id,key] of [['operation-dismiss','operationDismiss'],['operation-open','operationDetails'],['nav-overview','navOverview'],['nav-subscriptions','navSubscriptions'],['nav-configuration','navConfiguration'],['nav-diagnostics','navDiagnostics'],['nav-settings','navSettings'],['experiment','experiment'],['local-badge','localBadge'],['quick-heading','quickHeading'],['quick-subscriptions','quickSubscriptions'],['quick-subscriptions-help','quickSubscriptionsHelp'],['quick-configuration','quickConfiguration'],['quick-configuration-help','quickConfigurationHelp'],['filter-search-label','searchLabel'],['nodes-heading','nodesHeading'],['filter-details-label','filterDetails'],['export-help-label','exportHelpLabel'],['footer-note','footerNote'],['skip-link','skipLink'],['filter-search-empty','searchEmpty'],['scope','scope'],['access-heading','accessHeading'],['access-label','accessHomeOnly'],['access-help','accessHelp'],['access-save','accessSave'],['status-heading','status'],['refresh','refresh'],['config-heading','config'],['config-help','configHelp'],['file-label','fileLabel'],['paste-label','pasteLabel'],['config-warning','warning'],['apply','apply'],['filter-heading','filterHeading'],['filter-help','filterHelp'],['filter-load','filterLoad'],['filter-provider-label','filterProviderLabel'],['filter-preview','filterPreview'],['filter-clear','filterClear'],['filter-hint','filterHint'],['providers-heading','providers'],['providers-help','providersHelp'],['providers-download','providersDownload'],['doctor-heading','doctor'],['doctor-help','help'],['run','run'],['copy','copy'],['details-label','details'],['footer','footer']])set(id,t(key));
 set('status-text',statusData?t('unknown')+' — '+t('timestamp',{time:statusData.timestamp}):t('unknown'));
 set('binary-text',statusData?.runtime?t('processHelp'):statusData?t('binary',{m:t(statusData.mihomo_binary?'present':'absent'),mt:t(statusData.magitrickle_binary?'present':'absent')}):'');
 const runningImport=importData?.state==='RUNNING';
 const runningUpdate=updateOperation?.state==='RUNNING';
 const maintenanceBusy=runningImport||runningUpdate||updateSubmitting||mtChecking;
 let message=t('importNone');
 if(importData){
  if(runningImport)message=t('applying');
  else if(importData.state==='OK')message=t('importOk',{exit:importData.exit_code});
  else if(importData.state==='FAIL'||importData.error_code&&importData.error_code!=='NO_OPERATION')message=t('importFail',{exit:importData.exit_code??'?',code:importData.error_code??'UNKNOWN'});
 }
 if(importMessage)message=importMessage;
 set('config-state',message);
 const hasImportResult=['OK','FAIL'].includes(importData?.state)||Boolean(importMessage);
 // Finished Doctor output belongs to Diagnostics; keep only progress global.
 const showDoctor=busy&&view!=='diagnostics';
 // Recovered terminal results are history, not new global notifications.
 if(runningImport){importObserved=true;importDismissed=false;}
 const showImport=runningImport||hasImportResult&&importObserved&&!importDismissed&&view===importView;
 el('operation-dismiss').hidden=runningImport||runningUpdate||showDoctor||!showImport;
 el('operation-banner').hidden=!showDoctor&&!showImport&&!runningUpdate;
 set('operation-message',runningUpdate?t(updateOperation.component==='magitrickle'?'mtRunning':'updateRunning'):showDoctor?t('running'):showImport?message:'');
 el('operation-open').setAttribute('data-view',runningUpdate?'overview':showDoctor?'diagnostics':importView);
 el('operation-banner').setAttribute('data-state',showDoctor?'running':importData?.state==='FAIL'?'warning':'done');
 el('apply').disabled=submitting||maintenanceBusy;
 set('filter-state',filterLoading?t('filterLoading'):filterStatus);
 el('filter-load').disabled=filterLoading||filterBusy;
 el('filter-preview').disabled=!filterInspect||!filterNodes||filterBusy||filterLoading||!filterSelectedProvider||maintenanceBusy;
 const chosen=(filterInspect?.providers||[]).find(p=>p.name===filterSelectedProvider);
 el('filter-clear').disabled=!chosen?.has_filter||filterBusy||filterLoading||maintenanceBusy;
 el('filter-provider').disabled=!filterSelectedProvider||filterBusy||filterLoading||maintenanceBusy;
 for(const node of el('filter-node-list').querySelectorAll('input'))node.disabled=filterBusy||filterLoading||maintenanceBusy;
 set('providers-state',exporting?t('providersWorking'):providerMessage);
 el('providers-download').disabled=exporting;
 set('doctor-state',busy?t('running'):doctorData?doctorResultText()+' — '+t('timestamp',{time:doctorData.timestamp}):t('notrun'));
 set('output',doctorData?.details||'');
 globalThis.kasDoctorReport?.render(el('doctor-summary'),doctorData,lang);
 set('copy-state',copyStatus?t(copyStatus):'');
 el('copy').disabled=!doctorData||!doctorData.details;el('run').disabled=busy||maintenanceBusy;
 drawUpdates();drawMTUpdates();drawAppearanceLinks();
 if(maintenanceBusy){el('settings-save').disabled=true;el('access-save').disabled=true;el('access-home-only').disabled=true;}
 el('ru').setAttribute('aria-pressed',String(lang==='ru'));el('en').setAttribute('aria-pressed',String(lang==='en'));
}
function serviceText(name,present){
 const observation=statusData?.runtime?.[name];
 if(!observation)return statusData?t(present?'filePresent':'fileAbsent'):t('fileUnknown');
 const key={running:'processRunning',stopped:'processStopped',absent:'processAbsent',unknown:'processUnknown'}[observation.state]||'processUnknown';
 let text=t(key);
 if(typeof observation.version==='string'&&/^[0-9][A-Za-z0-9.+~-]{0,63}$/.test(observation.version)&&['api','package'].includes(observation.version_source))text+=' · '+t(observation.version_source==='api'?'runtimeVersion':'packageVersion',{version:observation.version});
 return text;
}
function doctorResultText(){
 if(doctorData.error_code)return t('failed',{exit:doctorData.exit_code??'?',code:doctorData.error_code});
 const summary=doctorData.summary;
 if(summary&&['OK','WARN','FAIL'].includes(summary.verdict)&&['ok','warn','fail','info'].every(key=>Number.isInteger(summary[key])&&summary[key]>=0&&summary[key]<=999999)){
  const verdict=summary.fail>0?'FAIL':summary.warn>0?'WARN':'OK';
  if(summary.verdict===verdict&&doctorData.exit_code===({OK:0,WARN:1,FAIL:2})[verdict])return t('doctor'+verdict,summary);
 }
 return doctorData.exit_code===0?t('doctorUnknown'):t('failed',{exit:doctorData.exit_code??'?',code:'EXIT_NONZERO'});
}
function validComponents(data){
 const version=value=>typeof value==='string'&&/^(development|[0-9][A-Za-z0-9.+~-]{0,63})$/.test(value);
 const source=value=>typeof value==='string'&&/^[a-f0-9]{40}$/.test(value);
 if(!data||!version(data.panel?.version)||!(data.panel.source_sha===''||source(data.panel.source_sha)))return false;
 if(!['absent','present','modified','unavailable'].includes(data.core?.state)||!['unrecorded','current','stale','bundle_changed','invalid_receipt','unverified'].includes(data.watchdog?.state))return false;
 if(data.core.version!==undefined&&!version(data.core.version))return false;
 if(data.core.state==='present'&&(!version(data.core.version)||!source(data.core.source_sha)))return false;
 if(['current','bundle_changed'].includes(data.watchdog.state)&&!version(data.watchdog.recorded_version))return false;
 return true;
}
function drawComponents(){
 for(const [id,key] of [['versions-heading','versionsHeading'],['core-label','coreLabel'],['watchdog-label','watchdogLabel'],['versions-help','versionsHelp'],['project-link','projectLink']])set(id,t(key));
 if(!componentsData){set('panel-build','KAS Web · '+t('versionsUnavailable'));set('core-version',t('versionsUnavailable'));set('watchdog-version',t('versionsUnavailable'));return;}
 const {panel,core,watchdog}=componentsData;
 set('panel-build','KAS Web '+(panel.version==='development'?t('buildDevelopment'):panel.version)+(panel.source_sha?' · '+panel.source_sha.slice(0,7):''));
 set('core-version',core.state==='present'?t('versionIdentity',{version:core.version,sha:core.source_sha.slice(0,7)}):t(core.state==='absent'?'coreAbsent':core.state==='modified'?'coreModified':'versionsUnavailable'));
 const keys={current:'watchdogCurrent',bundle_changed:'watchdogBundleChanged',stale:'watchdogStale',invalid_receipt:'watchdogInvalid'};
 set('watchdog-version',watchdog.state==='unrecorded'&&/^[a-f0-9]{64}$/.test(watchdog.installed_sha256||'')?t('watchdogDigest',{sha:watchdog.installed_sha256.slice(0,12)}):t(keys[watchdog.state]||'watchdogUnrecorded',{version:watchdog.recorded_version||''}));
}
async function refreshComponents(){
 try{const response=await fetch('/api/components',{cache:'no-store',credentials:'same-origin'}),data=await response.json();componentsData=response.ok&&validComponents(data)?data:null;}
 catch(_){componentsData=null;}
 draw();
}
// Credentials stay only in these transient form inputs and the request body.
function clearSettingsPasswords(){for(const id of ['settings-current','settings-password','settings-repeat'])el(id).value='';}
function validSettings(data){return data&&Number.isInteger(data.port)&&data.port>=1&&data.port<=65535&&['none','panel','entware'].includes(data.auth_mode)&&data.login===({none:'',panel:'kas',entware:'root'}[data.auth_mode])&&typeof data.password_set==='boolean';}
function drawSettings(){
 for(const [id,key] of [['settings-heading','settingsHeading'],['settings-help','settingsHelp'],['settings-port-label','settingsPort'],['settings-mode-label','settingsMode'],['settings-none','settingsNone'],['settings-entware','settingsEntware'],['settings-panel','settingsPanel'],['settings-repeat-label','settingsRepeat'],['settings-save','accessSave'],['settings-reload','refresh']])set(id,t(key));
 set('settings-current-label',t('settingsCurrent',{login:settingsData?.login||''}));
 const mode=el('settings-mode').value;
 const panel=mode==='panel',root=mode==='entware'&&settingsData?.auth_mode!=='entware';
 el('settings-current-row').hidden=!settingsData||settingsData.auth_mode==='none';
 el('settings-password-row').hidden=!panel&&!root;
 el('settings-repeat-row').hidden=!panel;
 set('settings-password-label',t(root?'settingsRootPassword':'settingsPassword'));
 set('settings-login',mode==='none'?'':t('settingsLogin',{login:panel?'kas':'root'}));
 set('settings-mode-help',t(panel?'settingsPanelHelp':mode==='entware'?'settingsEntwareHelp':'settingsNoneHelp'));
 for(const id of ['settings-port','settings-mode','settings-current','settings-password','settings-repeat','settings-save'])el(id).disabled=settingsBusy||!settingsData;
 el('settings-reload').disabled=settingsBusy;
 set('settings-state',settingsBusy?t(settingsData?'settingsSaving':'settingsLoading'):settingsStatus);
}
async function refreshSettings(){
 if(settingsBusy)return;
 settingsBusy=true;settingsData=null;settingsStatus='';clearSettingsPasswords();el('settings-address').hidden=true;draw();
 try{
  const response=await fetch('/api/settings',{cache:'no-store',credentials:'same-origin'}),data=await response.json();
  if(!response.ok||!validSettings(data))throw Error(data.error_code||'HTTP_'+response.status);
  settingsData={port:data.port,auth_mode:data.auth_mode,login:data.login,password_set:data.password_set};
  el('settings-port').value=String(data.port);el('settings-mode').value=data.auth_mode;
 }catch(e){settingsStatus=t('settingsError',{code:e.message||'UNKNOWN'});}
 finally{settingsBusy=false;draw();}
}
function safeSettingsAddress(value,port){
 try{
  const url=new URL(value),current=new URL(window.location.href);
  // Display only the current router host, the committed port, and a plain HTTP root URL.
  if(url.protocol!=='http:'||url.hostname!==current.hostname||url.username||url.password||url.pathname!=='/'||url.search||url.hash)return '';
  const host=url.hostname.includes(':')?'['+url.hostname.replace(/^\[|\]$/g,'')+']':url.hostname;
  const expected='http://'+host+':'+port;
  if(value!==expected&&value!==expected+'/')return '';
  return expected+'/';
 }catch(_){return '';}
}
async function saveSettings(){
 if(settingsBusy||!settingsData)return;
 const port=Number(el('settings-port').value),mode=el('settings-mode').value;
 const password=el('settings-password').value,repeat=el('settings-repeat').value,current=el('settings-current').value;
 clearSettingsPasswords();el('settings-address').hidden=true;
 const fail=key=>{settingsStatus=t(key);draw();};
 if(!Number.isInteger(port)||port<1||port>65535||!['none','panel','entware'].includes(mode))return fail('settingsInvalid');
 if(settingsData.auth_mode!=='none'&&!current)return fail('settingsCurrentRequired');
 const body={port,auth_mode:mode};
 if(mode==='panel'){
  const length=new TextEncoder().encode(password).length;
  if((password&&(length<12||length>128||password!==repeat))||(!password&&(repeat||settingsData.auth_mode!=='panel'||!settingsData.password_set)))return fail('settingsPasswordInvalid');
  if(password)body.password=password;
 }else if(mode==='entware'&&settingsData.auth_mode!=='entware'){
  if(!password)return fail('settingsRootRequired');
  body.password=password;
 }
 if(settingsData.auth_mode!=='none')body.current_password=current;
 const warning=[];
 if(mode==='none'&&settingsData.auth_mode!=='none')warning.push(t('settingsDisableWarning'));
 if(port!==settingsData.port)warning.push(t('settingsPortWarning',{before:settingsData.port,after:port}));
 if(!window.confirm(t('settingsConfirm',{warning:warning.join(' ')})))return fail('settingsCancelled');
 settingsBusy=true;settingsStatus='';draw();
 try{
  const response=await fetch('/api/settings',{method:'POST',cache:'no-store',credentials:'same-origin',headers:{'Content-Type':'application/json','X-KAS-Confirm':'settings'},body:JSON.stringify(body)}),data=await response.json();
  if(!response.ok||!validSettings(data))throw Error(data.error_code||'HTTP_'+response.status);
  const changed=data.port!==settingsData.port;
  settingsData={port:data.port,auth_mode:data.auth_mode,login:data.login,password_set:data.password_set};
  el('settings-port').value=String(data.port);el('settings-mode').value=data.auth_mode;
  settingsStatus=t('settingsSaved');
  const address=changed?safeSettingsAddress(data.url,data.port):'';
  if(address){el('settings-address').href=address;set('settings-address',address);el('settings-address').hidden=false;settingsStatus=t('settingsPortChanged');}
 }catch(e){settingsStatus=t('settingsError',{code:e.message||'UNKNOWN'});}
 finally{settingsBusy=false;clearSettingsPasswords();draw();}
}
async function refreshAccess(){
 if(accessBusy)return;
 accessBusy=true;accessStatus='';draw();
 try{
  const response=await fetch('/api/access',{cache:'no-store'});
  const data=await response.json();
  if(!response.ok||typeof data.home_only!=='boolean')throw Error(data.error_code||'HTTP_'+response.status);
  accessData=data;el('access-home-only').checked=data.home_only;
 }catch(e){accessData=null;accessStatus=t('accessError',{code:e.message||'UNKNOWN'});}
 finally{accessBusy=false;draw();}
}
async function saveAccess(){
 if(accessBusy||!accessData)return;
 const homeOnly=el('access-home-only').checked;
 if(homeOnly===accessData.home_only)return;
 if(!window.confirm(t(homeOnly?'accessEnableConfirm':'accessDisableConfirm'))){el('access-home-only').checked=accessData.home_only;return;}
 accessBusy=true;accessStatus='';draw();
 try{
  const response=await fetch('/api/access',{method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'access'},body:JSON.stringify({home_only:homeOnly})});
  const data=await response.json();
  if(!response.ok||typeof data.home_only!=='boolean')throw Error(data.error_code||'HTTP_'+response.status);
  accessData=data;el('access-home-only').checked=data.home_only;
 }catch(e){el('access-home-only').checked=accessData.home_only;accessStatus=t('accessError',{code:e.message||'UNKNOWN'});}
 finally{accessBusy=false;draw();}
}
async function refresh(){
 refreshComponents();
 try{const resp=await fetch('/api/status',{cache:'no-store'});if(!resp.ok)throw Error('HTTP '+resp.status);statusData=await resp.json();}
 catch(e){statusData=null;set('status-text',t('error',{code:String(e)}));return;}
 draw();
}
async function runDoctor(){
 lastOperation='doctor';
 if(busy||importData?.state==='RUNNING'||updateOperation?.state==='RUNNING'||updateSubmitting||mtChecking)return;busy=true;copyStatus='';draw();
 try{const resp=await fetch('/api/doctor',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}',cache:'no-store'});
  doctorData=await resp.json();if(!resp.ok&&!doctorData.error_code)doctorData.error_code='HTTP_'+resp.status;}
 catch(e){doctorData={error_code:String(e),timestamp:new Date().toISOString(),details:''};}
 finally{busy=false;draw();}
}
function schedulePoll(){
 if(pollTimer!==null)return;
 pollTimer=setTimeout(()=>{pollTimer=null;refreshImport();},1500);
}
async function refreshImport(){
 let wasRunning=false;
 if(importData)wasRunning=importData.state==='RUNNING';
 try{
  const resp=await fetch('/api/config/operation',{cache:'no-store'});
  if(!resp.ok)throw Error('HTTP '+resp.status);
  importData=await resp.json();
  importMessage='';
 }catch(e){importMessage=t('importError',{code:String(e)});}
 if(filterAwaitingApply&&importData&&importData.state!=='RUNNING'){
  // A filter apply finished: report its result honestly, then refresh the
  // SHA, filter lines and node list from the actual router state.
  const ok=importData.state==='OK';
  filterAwaitingApply=false;filterPending=null;set('filter-result','');
  if(filterInspect)await loadFilterEditor();
  filterStatus=ok?(filterNodes?t('filterApplyReady'):t('filterApplyDone')+' '+filterStatus):t('filterApplyFail');
 }
 draw();
 if(importData?.state==='RUNNING')schedulePoll();
}
async function applyYAML(){
 lastOperation='import';importView='configuration';
 if(submitting||importData?.state==='RUNNING'||updateOperation?.state==='RUNNING'||updateSubmitting||mtChecking)return;
 importObserved=true;importDismissed=false;
 const file=el('config-file').files[0];
 const pasted=el('yaml-paste').value;
 if(!file&&!pasted){importMessage=t('emptyFile');draw();return;}
 const limit=1024*1024;
 let bytes;
 if(file){
  if(file.size>limit){importMessage=t('fileTooLarge');draw();return;}
  bytes=new Uint8Array(await file.arrayBuffer());
 }else{bytes=new TextEncoder().encode(pasted);}
 if(bytes.length===0){importMessage=t('emptyFile');draw();return;}
 if(bytes.length>limit){importMessage=t('fileTooLarge');draw();return;}
 if(!window.confirm(t('confirm')))return;
 submitting=true;importMessage='';draw();
 try{
  const resp=await fetch('/api/config/import',{method:'POST',headers:{'Content-Type':'application/x-yaml','X-KAS-Confirm':'apply'},body:bytes,cache:'no-store'});
  importData=await resp.json();
  if(resp.status!==202){importMessage=t('importError',{code:importData?.error_code??'HTTP_'+resp.status});}
  else{
   el('config-file').value='';el('yaml-paste').value='';
   schedulePoll();
  }
 }catch(e){importMessage=t('importError',{code:String(e)});}
 finally{submitting=false;draw();}
}
for(const l of ['ru','en'])el(l).addEventListener('click',()=>{lang=l;try{localStorage.setItem('kas_lang',l)}catch(_){}draw();});
el('refresh').addEventListener('click',()=>{refresh();refreshAccess();refreshSettings();});
el('settings-form').addEventListener('submit',event=>{event.preventDefault();saveSettings();});
el('settings-mode').addEventListener('change',()=>{clearSettingsPasswords();draw();});
el('settings-reload').addEventListener('click',refreshSettings);
el('access-save').addEventListener('click',saveAccess);
el('run').addEventListener('click',runDoctor);
async function exportProviders(){
 if(exporting)return;
 exporting=true;providerMessage='';draw();
 try{
  const response=await fetch('/api/providers/names',{cache:'no-store',credentials:'same-origin'});
  if(!response.ok){
   if(response.status===404){providerMessage=t('providersDisabled');return;}
   let code='HTTP_'+response.status;
   try{const error=await response.json();code=error.error_code||code;}catch(_){}
   providerMessage=t('providersError',{code});return;
  }
  const file=await response.blob();
  if(file.size>1024*1024){providerMessage=t('providersError',{code:'RESPONSE_TOO_LARGE'});return;}
  const url=URL.createObjectURL(file);
  const a=document.createElement('a');
  a.href=url;a.download='mihomo-providers-names.json';
  document.body.appendChild(a);a.click();a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),1000);
  providerMessage=t('providersSuccess');
 }catch(_){providerMessage=t('providersError',{code:'NETWORK_ERROR'});}
 finally{exporting=false;draw();}
}
// Read-only staged filter editor. Do not persist node names or raw provider JSON.
function renderFilterNodes(){
 // A fresh snapshot invalidates any previously previewed change.
 filterPending=null;
 const selector=el('filter-provider');
 const providers=(filterInspect?.providers||[]).filter(p=>p.http);
 selector.replaceChildren();
 for(const provider of providers){
  const o=document.createElement('option');o.value=provider.name;o.textContent=provider.name;selector.appendChild(o);
 }
 if(!providers.some(p=>p.name===filterSelectedProvider))filterSelectedProvider=providers[0]?.name||'';
 selector.value=filterSelectedProvider;selector.disabled=!filterSelectedProvider;
 const chosen=providers.find(p=>p.name===filterSelectedProvider);
 set('filter-existing',chosen?t('filterExisting',{filter:chosen.has_filter?chosen.existing_filter:t('filterNoFilter')}):t('filterNoProvider'));
 const list=el('filter-node-list');list.replaceChildren();el('filter-search').value='';
 const available=filterNodes?.providers?.[filterSelectedProvider]?.proxies||[];
 const names=[...new Set(available.map(p=>p.name).filter(x=>typeof x==='string'&&x))];
 for(const name of names.slice(0,400)){
  const label=document.createElement('label');
  const check=document.createElement('input');check.type='checkbox';check.value=name;
  label.appendChild(check);const title=document.createElement('span');title.textContent=name;label.appendChild(title);
  list.appendChild(label);
 }
 if(names.length===0){const tip=document.createElement('p');tip.textContent=t('filterNoNames');list.appendChild(tip);}
 if(names.length>400){const tip=document.createElement('p');tip.textContent=t('filterTooMany',{count:400});list.appendChild(tip);}
 draw();
}
function updateFilterSearch(){
 const query=el('filter-search').value.trim().toLocaleLowerCase(lang);
 const inputs=[...el('filter-node-list').querySelectorAll('input')];
 let visible=0;
 for(const input of inputs){
  const match=input.value.toLocaleLowerCase(lang).includes(query);
  if(input.parentElement)input.parentElement.hidden=!match;
  if(match)visible++;
 }
 set('filter-summary',inputs.length?t('selectionCount',{selected:inputs.filter(input=>input.checked).length,visible,total:inputs.length}):'');
 el('filter-search-empty').hidden=!inputs.length||visible>0;
}
async function readFilterJSON(url){
 const response=await fetch(url,{cache:'no-store'});
 if(!response.ok){
  let code='HTTP_'+response.status;
  try{const data=await response.json();code=data.error_code||code;}catch(_){}
  throw Error(code);
 }
 return response.json();
}
async function loadFilterEditor(){
 if(filterLoading)return;
 filterLoading=true;filterStatus='';filterPending=null;set('filter-result','');draw();
 try{
  // A names failure must not discard the successfully inspected config:
  // clearing needs only the provider name and the approved config SHA.
  const [inspect,nodes]=await Promise.allSettled([
   readFilterJSON('/api/filter/providers'),readFilterJSON('/api/providers/names')
  ]);
  if(inspect.status!=='fulfilled')throw inspect.reason;
  filterInspect=inspect.value;
  filterNodes=nodes.status==='fulfilled'?nodes.value:null;
  filterStatus=filterNodes?t('filterLoaded'):t('filterNamesUnavailable',{code:nodes.reason?.message||'UNKNOWN'});
  renderFilterNodes();
 }catch(e){filterInspect=null;filterNodes=null;filterSelectedProvider='';filterPending=null;filterStatus=e.message==='EDITOR_DISABLED'?t('filterDisabled'):t('filterCannotLoad',{code:e.message||'UNKNOWN'});el('filter-node-list').replaceChildren();el('filter-provider').replaceChildren();set('filter-existing','');set('filter-result','');}
 finally{filterLoading=false;draw();}
}
async function previewFilterChange(clear){
 if(!filterInspect||!filterSelectedProvider||filterBusy)return;
 const provider=filterSelectedProvider,sourceSHA=filterInspect.source_sha;
 const names=clear?[]:[...el('filter-node-list').querySelectorAll('input:checked')].map(el=>el.value);
 if(!clear&&!filterNodes)return;
 if(!clear&&!names.length){filterStatus=t('filterNothing');draw();return;}
 filterBusy=true;filterStatus=t('filterPreviewing');set('filter-result','');filterPending=null;draw();
 try{
  const response=await fetch('/api/filter/preview',{
   method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'preview'},
   body:JSON.stringify({provider,names,clear,source_sha:sourceSHA})
  });
  const data=await response.json();
  if(!response.ok)throw Error(data.error_code||'HTTP_'+response.status);
  set('filter-result',t('filterProposed',{before:data.existing_filter||t('filterNoFilter'),after:data.proposed_filter||t('filterNoFilter')}));
  filterPending={provider,names,clear,source_sha:sourceSHA};
  filterStatus=t('filterPreviewReady');
 }catch(e){filterStatus=t('filterPreviewError',{code:e.message||'UNKNOWN'});}
 finally{filterBusy=false;draw();}
}
// Explicit, separately confirmed write through the canonical importer.
// The server re-verifies the source SHA and its importer owns the rest.
async function applyFilterChange(){
 lastOperation='import';importView='subscriptions';
 if(!filterPending||filterBusy||importData?.state==='RUNNING')return;
 if(!window.confirm(t(filterPending.clear?'filterClearConfirm':'filterApplyConfirm',{provider:filterPending.provider,count:filterPending.names.length}))){filterPending=null;filterStatus=t('filterCancelled');set('filter-result','');draw();return;}
 filterBusy=true;filterStatus=t('filterApplying');draw();
 try{
  const response=await fetch('/api/filter/apply',{
   method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'apply'},
   body:JSON.stringify({provider:filterPending.provider,names:filterPending.names,clear:filterPending.clear,source_sha:filterPending.source_sha})
  });
  if(response.status===200){
   const data=await response.json();
   if(data.applied===false){
    filterPending=null;filterStatus=t('filterApplyNoChange');set('filter-result','');draw();return;
   }
  }
  const data=await response.json();
  if(response.status!==202)throw Error(data.error_code||'HTTP_'+response.status);
  importObserved=true;importDismissed=false;
  importData=data;importMessage='';filterAwaitingApply=true;
  schedulePoll();
 }catch(e){filterStatus=t('filterApplyError',{code:e.message||'UNKNOWN'});}
 finally{filterBusy=false;draw();}
}
// One user action: server-side preview, explicit confirmation, then canonical
// apply. No separate UI preparation/apply buttons. Keep the approved request
// (including source SHA and provider) captured across asynchronous steps.
async function changeFilter(clear){
 if(filterBusy||filterLoading||importData?.state==='RUNNING'||!filterInspect||!filterSelectedProvider)return;
 const provider=filterInspect.providers.find(p=>p.name===filterSelectedProvider);
 if(clear&&!provider?.has_filter)return;
 filterPending=null;
 await previewFilterChange(clear);
 if(filterPending)await applyFilterChange();
}
el('filter-search').addEventListener('input',updateFilterSearch);
el('filter-node-list').addEventListener('change',updateFilterSearch);
el('filter-load').addEventListener('click',loadFilterEditor);
el('filter-provider').addEventListener('change',()=>{filterSelectedProvider=el('filter-provider').value;filterStatus='';set('filter-result','');renderFilterNodes();});
el('filter-preview').addEventListener('click',()=>changeFilter(false));
el('filter-clear').addEventListener('click',()=>changeFilter(true));

el('apply').addEventListener('click',applyYAML);
el('providers-download').addEventListener('click',exportProviders);
// HTTP LAN origins do not expose the modern Clipboard API in Chromium.
// Keep the user-triggered copy fallback and explain browser denial visibly.
async function copyDoctorReport(){
 if(!doctorData?.details)return;
 let copied=false;
 try{
  if(navigator.clipboard?.writeText){await navigator.clipboard.writeText(doctorData.details);copied=true;}
 }catch(_){} // A denied modern API may still allow a user-triggered copy command.
 if(!copied){
  // A textarea preserves whitespace, including the report's trailing newline.
  const previous=document.activeElement,area=document.createElement('textarea');
  area.value=doctorData.details;area.readOnly=true;area.setAttribute('aria-label',t('copy'));
  area.style.position='fixed';area.style.left='-9999px';
  document.body.appendChild(area);
  try{area.select();copied=document.execCommand('copy');}catch(_){}
  finally{area.remove();previous?.focus({preventScroll:true});}
 }
 if(!copied){
  const output=el('output');output.closest('details').open=true;
  const range=document.createRange();range.selectNodeContents(output);
  const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
 }
 copyStatus=copied?'copyDone':'copyManual';
 // Do not redraw the report: that would discard the manual-copy selection.
 set('copy-state',t(copyStatus));
}
el('copy').addEventListener('click',copyDoctorReport);
el('operation-dismiss').addEventListener('click',()=>{
 if(importData?.state==='RUNNING'||busy||updateOperation?.state==='RUNNING')return;
 importDismissed=true;draw();
});
window.kasDraw=draw;
draw();refresh();refreshImport();refreshAccess();refreshSettings();refreshUpdateOperation();

function updateResultText(){
 if(updateOperation?.component==='magitrickle')return '';
 if(updateOperation?.state==='RUNNING')return t('updateRunning');
 if(updateOperation?.state==='FAIL')return t('updateFailed');
 if(updateOperation?.state==='OK')return t(({CHANGED:'updateChanged',UNCHANGED:'updateUnchanged'})[updateOperation.outcome]||'updateUnverified');
 return '';
}
function drawUpdates(){
 for(const [id,key] of [['updates-heading','updatesHeading'],['updates-help','updatesHelp'],['update-check','updateCheck'],['update-mihomo','updateApply']])set(id,t(key));
 const occupied=busy||importData?.state==='RUNNING'||updateOperation?.state==='RUNNING'||updateSubmitting||mtChecking;
 el('update-check').disabled=occupied||updateChecking;
 el('update-mihomo').disabled=occupied||updateChecking||updateCheckData?.state!=='AVAILABLE'||!mihomoOffered(updateCheckData.relation);
 let message=updateResultText()||t('updateNone');
 if(updateCheckData?.state==='AVAILABLE'&&!['OK','FAIL'].includes(updateOperation?.state)){
  message=t('updateAvailable',{current:updateCheckData.current_version||'?',available:updateCheckData.available_version,release:updateCheckData.package_release});
  const relationKey=({older:'updateOlder',same_runtime:'updateSame',same_package:'updateSamePackage',newer_package:'updateNewerPackage',older_package:'updateOlderPackage',invalid_state:'updateInvalidState',unknown:'updateUnknown'})[updateCheckData.relation];if(relationKey)message+=' '+t(relationKey);
  if(updateCheckData.installed_package_version)message+=' '+t('updatePackageMetadata',{version:updateCheckData.installed_package_version});
 }
 if(updateMessage)message=updateMessage;
 if(updateChecking)message=t('updateChecking');
 if(updateOperation?.state==='RUNNING'&&updateOperation.component!=='magitrickle')message=t('updateRunning');
 set('updates-state',message);
}
function mihomoOffered(relation){return ['newer','newer_package','unknown'].includes(relation);}
function validUpdateCheck(data){
 const version=v=>typeof v==='string'&&/^[0-9]+\.[0-9]+\.[0-9]+$/.test(v)&&v.length<=32;
 return data?.state==='AVAILABLE'&&version(data.available_version)&&Number.isInteger(data.package_release)&&data.package_release>0&&data.package_release<=999999999&&['newer','older','same_runtime','same_package','newer_package','older_package','invalid_state','unknown'].includes(data.relation)&&(data.current_version===undefined||typeof data.current_version==='string'&&/^[0-9][A-Za-z0-9.+~-]{0,63}$/.test(data.current_version));
}
async function checkMihomoUpdates(){
 if(mtChecking||updateChecking||updateSubmitting||updateOperation?.state==='RUNNING'||busy||importData?.state==='RUNNING')return;
 const epoch=++updateEpoch;updateChecking=true;updateCheckData=null;updateOperation=null;updateMessage='';draw();
 try{
  const response=await fetch('/api/updates/check',{method:'POST',credentials:'same-origin',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'check-updates'},body:'{}'});
  const data=await response.json();if(epoch!==updateEpoch)return;if(!response.ok||!validUpdateCheck(data))throw Error(data.error_code||'INVALID_RESPONSE');updateCheckData=data;
 }catch(e){updateMessage=t('updateCheckError',{code:e.message||'UNKNOWN'});}
 finally{if(epoch===updateEpoch){updateChecking=false;draw();}}
}
function scheduleUpdatePoll(){
 if(updatePollTimer!==null)return;
 updatePollTimer=setTimeout(()=>{updatePollTimer=null;refreshUpdateOperation();},1500);
}
async function refreshUpdateOperation(){
 const epoch=updateEpoch,expectedID=updateOperation?.id;
 const wasRunning=updateOperation?.state==='RUNNING';
 try{
  const response=await fetch('/api/updates/operation',{cache:'no-store',credentials:'same-origin'}),data=await response.json();
  if(epoch!==updateEpoch)return;
  if(!response.ok||!['UNKNOWN','RUNNING','OK','FAIL'].includes(data.state))throw Error(data.error_code||'INVALID_RESPONSE');
  if(data.id)updateKnownID=data.id;
  if(expectedID&&data.id&&data.id!==expectedID){
   updateCheckData=null;updateOperation=data.state==='RUNNING'?data:null;updateMessage=t('updateRequestError',{code:'STATUS_REPLACED'});draw();if(updateOperation?.state==='RUNNING')scheduleUpdatePoll();return;
  }
  if(data.state==='UNKNOWN'&&wasRunning){updateOperation=null;updateMessage=t('updateRequestError',{code:'STATUS_LOST'});}
  else {updateOperation=data.state==='UNKNOWN'?null:data;updateMessage='';}
  if(wasRunning&&updateOperation&&updateOperation.state!=='RUNNING'){updateCheckData=null;mtCheckData=null;refresh();}
 }catch(e){updateMessage=t('updateRequestError',{code:e.message||'UNKNOWN'});}
 draw();if(updateOperation?.state==='RUNNING')scheduleUpdatePoll();
}
async function startMihomoUpdate(){
 if(mtChecking||updateSubmitting||updateOperation?.state==='RUNNING'||updateCheckData?.state!=='AVAILABLE'||!mihomoOffered(updateCheckData.relation)||busy||importData?.state==='RUNNING')return;
 if(!window.confirm(t('updateConfirm'))){updateMessage=t('updateCancelled');draw();return;}
 const priorID=updateKnownID;
 ++updateEpoch;updateSubmitting=true;updateCheckData=null;updateMessage='';draw();
 try{
  const response=await fetch('/api/updates/mihomo',{method:'POST',cache:'no-store',credentials:'same-origin',headers:{'Content-Type':'application/json','X-KAS-Confirm':'update-mihomo'},body:'{}'}),data=await response.json();
  if(!response.ok||data.state!=='RUNNING')throw Error(data.error_code||'INVALID_RESPONSE');updateOperation=data;updateKnownID=data.id;updateCheckData=null;scheduleUpdatePoll();
 }catch(e){await reconcileUpdateStart(priorID,'mihomo',e);}
 finally{updateSubmitting=false;draw();}
}
el('update-check').addEventListener('click',checkMihomoUpdates);
el('update-mihomo').addEventListener('click',startMihomoUpdate);

function drawMTUpdates(){
 for(const [id,key] of [['mt-heading','mtHeading'],['mt-help','mtHelp'],['mt-check','mtCheck'],['update-mt','mtApply']])set(id,t(key));
 const occupied=busy||importData?.state==='RUNNING'||updateOperation?.state==='RUNNING'||updateSubmitting||updateChecking||mtChecking;
 el('mt-check').disabled=occupied;el('update-mt').disabled=occupied||mtCheckData?.relation!=='newer';
 let text=t('updateNone');
 if(mtCheckData)text=t(mtCheckData.relation==='newer'?'mtAvailable':'mtNoUpgrade',{current:mtCheckData.current_version,available:mtCheckData.available_version});
 if(mtMessage)text=mtMessage;
 if(mtChecking)text=t('mtChecking');
 if(updateOperation?.component==='magitrickle'){
  if(updateOperation.state==='RUNNING')text=t('mtRunning');
  else if(updateOperation.state==='FAIL')text=t('mtFailed',{code:updateOperation.error_code||'UNKNOWN'});
  else if(updateOperation.state==='OK')text=t(updateOperation.outcome==='CHANGED'?'mtChanged':'mtUnchanged');
  if(updateMessage)text=updateMessage;
 }
 set('mt-state',text);
}
async function checkMTUpdates(){
 if(mtChecking||updateChecking||updateSubmitting||busy||importData?.state==='RUNNING'||updateOperation?.state==='RUNNING')return;
 const epoch=++updateEpoch;mtChecking=true;mtCheckData=null;updateOperation=null;mtMessage='';updateMessage='';draw();
 try{
  const response=await fetch('/api/updates/magitrickle/check',{method:'POST',credentials:'same-origin',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'check-magitrickle'},body:'{}'}),data=await response.json();
  if(epoch!==updateEpoch)return;
  const version=v=>typeof v==='string'&&/^[0-9][A-Za-z0-9.+~-]{0,63}$/.test(v);
  if(!response.ok||data.state!=='AVAILABLE'||!version(data.current_version)||!['newer','no_upgrade'].includes(data.relation)||data.relation==='newer'&&!version(data.available_version))throw Error(data.error_code||'INVALID_RESPONSE');
  mtCheckData=data;
 }catch(e){mtMessage=t('updateCheckError',{code:e.message||'UNKNOWN'});}
 finally{if(epoch===updateEpoch){mtChecking=false;draw();}}
}
async function startMTUpdate(){
 if(mtChecking||updateChecking||updateSubmitting||busy||importData?.state==='RUNNING'||updateOperation?.state==='RUNNING'||mtCheckData?.relation!=='newer')return;
 if(!window.confirm(t('mtConfirm'))){mtMessage=t('updateCancelled');draw();return;}
 const priorID=updateKnownID;
 ++updateEpoch;updateSubmitting=true;mtCheckData=null;updateCheckData=null;mtMessage='';updateMessage='';draw();
 try{
  const response=await fetch('/api/updates/magitrickle',{method:'POST',credentials:'same-origin',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'update-magitrickle'},body:'{}'}),data=await response.json();
  if(!response.ok||data.state!=='RUNNING'||data.component!=='magitrickle')throw Error(data.error_code||'INVALID_RESPONSE');
  updateOperation=data;updateKnownID=data.id;scheduleUpdatePoll();
 }catch(e){await reconcileUpdateStart(priorID,'magitrickle',e);}
 finally{updateSubmitting=false;draw();}
}
el('mt-check').addEventListener('click',checkMTUpdates);
el('update-mt').addEventListener('click',startMTUpdate);

async function reconcileUpdateStart(priorID,component,error){
 const message=t('updateRequestError',{code:error.message||'UNKNOWN'});
 await refreshUpdateOperation();
 if(updateOperation&&(updateOperation.id===priorID||(updateOperation.component||'mihomo')!==component))updateOperation=null;
 if(!updateOperation){if(component==='magitrickle')mtMessage=message;else updateMessage=message;}
}

function drawAppearanceLinks(){
 for(const [id,key] of [['open-mihomo','openMihomo'],['open-mt','openMT'],['open-generator','openGenerator'],['appearance-heading','appearanceHeading'],['theme-label','themeLabel'],['theme-auto','themeAuto'],['theme-light','themeLight'],['theme-dark','themeDark'],['theme-help','themeHelp']])set(id,t(key));
 el('theme-mode').value=window.kasTheme?.get()||'auto';
 const source=new URL(window.location.href);
 for(const [id,port,path] of [['local-badge','','/'],['open-mihomo','9090','/ui/'],['open-mt','8080','/']]){
  const link=el(id);link.target='_blank';link.rel='noopener noreferrer';link.hidden=source.protocol!=='http:';
  if(!link.hidden){const url=new URL(source.href);url.username='';url.password='';url.port=port;url.pathname=path;url.search='';url.hash='';link.href=url.href;}
 }
 const generator=el('open-generator');generator.href='https://saymer-alt.github.io/link-generators/';generator.target='_blank';generator.rel='noopener noreferrer';generator.hidden=false;
 set('service-links-note',t(source.protocol==='http:'?'serviceLinksNote':'serviceLinksProxy'));
}
el('theme-mode').addEventListener('change',()=>{window.kasTheme?.set(el('theme-mode').value);draw();});
