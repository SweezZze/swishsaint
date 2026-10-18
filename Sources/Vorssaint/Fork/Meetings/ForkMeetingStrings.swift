// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Strings for meetings. Same contract as `ForkDictationStrings`: memberwise
/// init in declaration order, one static per language. The short notices and
/// failure summaries fit the island, the pill and the bubble (28 characters at
/// most, numbers filled in); the remedies are whole sentences for the page and
/// VoiceOver. Grouped by theme: each later part of the feature adds its own
/// group, and its texts in every language.
struct ForkMeetingStrings {
    // MARK: Library folder and names

    /// The folder made in Movies for the meetings, frozen at the first recording.
    let folderName: String
    /// The title of a meeting recorded by hand without a name.
    let untitledMeeting: String

    // MARK: Island, pill and bubble notices: short

    let noticeStarted: String
    let noticeResumed: String
    let noticeSaved: String
    let noticeRecovered: String
    /// Its detail is the new microphone's name.
    let noticeMicrophone: String
    let noticeMicrophoneSilent: String
    /// Its detail is `diskMinutesFormat`.
    let noticeDiskLow: String
    let noticeDisplayChanged: String
    let diskMinutesFormat: String

    // MARK: VoiceOver

    let voiceStarted: String
    let voicePaused: String
    let voiceResumed: String
    let voiceStopped: String
    let voiceMicrophoneFormat: String
    let voiceMicrophoneSilent: String
    let voiceDiskLowFormat: String
    let voiceDisplayChanged: String

    // MARK: Failures: a short summary, then what to do

    let failScreenDenied: String
    let failScreenDeniedRemedy: String
    let failScreenRevoked: String
    let failScreenRevokedRemedy: String
    let failMicrophoneDenied: String
    let failMicrophoneDeniedRemedy: String
    let failSystemAudio: String
    let failSystemAudioRemedy: String
    let failDiskAtStartFormat: String
    let failDiskAtStartRemedy: String
    let failDiskFull: String
    let failDiskFullRemedy: String
    let failStreamStopped: String
    let failStreamStoppedRemedy: String
    let failRecorderBusy: String
    let failRecorderBusyRemedy: String
    let failFolder: String
    let failFolderRemedy: String
    let failCapture: String
    let failCaptureRemedy: String
    let failWriter: String
    let failWriterRemedy: String
    let failFinalPass: String
    let failFinalPassRemedy: String
    let failBuild: String
    let failBuildRemedy: String

    static var current: ForkMeetingStrings { strings(L10n.shared.language) }

    func diskMinutes(_ minutes: Int) -> String { String(format: diskMinutesFormat, minutes) }
    func voiceMicrophone(_ name: String) -> String { String(format: voiceMicrophoneFormat, name) }
    func voiceDiskLow(_ minutes: Int) -> String { String(format: voiceDiskLowFormat, minutes) }
    func failDiskAtStart(gigabytes: Int) -> String { String(format: failDiskAtStartFormat, gigabytes) }

    static func strings(_ language: AppLanguage) -> ForkMeetingStrings {
        switch language {
        case .enUS: return .enUS
        case .ptBR: return .ptBR
        case .tr: return .tr
        case .ru: return .ru
        case .es: return .es
        case .sk: return .sk
        case .de: return .de
        case .fr: return .fr
        case .it: return .it
        case .ja: return .ja
        case .ko: return .ko
        case .uk: return .uk
        case .zhHans: return .zhHans
        case .zhTW: return .zhTW
        case .zhHK: return .zhHK
        }
    }

    // MARK: Live

    /// The pill's words beside its time. Like every text of the pill and the
    /// bubble, 28 characters at most.
    let pillPaused: String
    let pillStopping: String
    let pillFinalizing: String
    /// The filmed window is minimized: the picture holds its last frame.
    let pillPictureFrozen: String
    /// The pill's buttons and meters, read by VoiceOver and shown as tooltips.
    let pillPause: String
    let pillResume: String
    let pillStop: String
    /// ⧉ while the window is filmed, then while the display is.
    let pillFilmDisplay: String
    let pillFilmWindow: String
    let pillMicrophoneLevel: String
    let pillMeetingLevel: String
    let pillMicrophoneOff: String
    let pillElapsed: String
    /// The pill as a whole, for VoiceOver.
    let pillRecording: String
    /// The buttons of the island's card and of the bubble.
    let actionShow: String
    let actionOpenSettings: String
    let actionOpenMeetings: String
    let bubbleClose: String
}

extension ForkMeetingStrings {
    static let enUS = ForkMeetingStrings(
        folderName: "Meetings",
        untitledMeeting: "Meeting",
        noticeStarted: "Recording started",
        noticeResumed: "Recording resumed",
        noticeSaved: "Meeting saved",
        noticeRecovered: "Meeting recovered",
        noticeMicrophone: "Microphone changed",
        noticeMicrophoneSilent: "Microphone is silent",
        noticeDiskLow: "Disk almost full",
        noticeDisplayChanged: "Display changed",
        diskMinutesFormat: "~%d min of disk left",
        voiceStarted: "Meeting recording started.",
        voicePaused: "Meeting recording paused.",
        voiceResumed: "Meeting recording resumed.",
        voiceStopped: "Meeting recording stopped. The file is being finished.",
        voiceMicrophoneFormat: "The recording now uses the microphone %@.",
        voiceMicrophoneSilent: "The microphone sends no sound. Check the microphone chosen for meetings.",
        voiceDiskLowFormat: "The disk is almost full. Minutes of recording left: %d.",
        voiceDisplayChanged: "The display changed. The recording now films the display of the meeting window.",
        failScreenDenied: "Screen Recording not allowed",
        failScreenDeniedRemedy: "Without it, nothing can be filmed. Allow Vorssaint in System Settings › Privacy & Security › Screen & System Audio Recording.",
        failScreenRevoked: "Screen access withdrawn",
        failScreenRevokedRemedy: "Screen Recording was turned off during the meeting: the recording stopped and its file is kept. Allow it again in System Settings › Privacy & Security › Screen & System Audio Recording.",
        failMicrophoneDenied: "Microphone not allowed",
        failMicrophoneDeniedRemedy: "The meeting is recorded without your voice. Allow the microphone in System Settings › Privacy & Security › Microphone.",
        failSystemAudio: "App sound unavailable",
        failSystemAudioRemedy: "The meeting app’s sound could not be recorded on its own, so the whole Mac’s sound is recorded instead. Allow system audio in System Settings › Privacy & Security › Screen & System Audio Recording.",
        failDiskAtStartFormat: "%d GB of free space needed",
        failDiskAtStartRemedy: "A meeting needs room before it starts, so it never fills the disk halfway through. Free up space, or choose a folder on another disk on the Meetings page.",
        failDiskFull: "Disk full: recording stopped",
        failDiskFullRemedy: "The recording stopped before the disk filled up, and its file is kept. Free up space before the next meeting.",
        failStreamStopped: "Stopped by macOS",
        failStreamStoppedRemedy: "macOS stopped the capture, for example from the recording indicator in the menu bar. The file is kept; start a new recording if the meeting goes on.",
        failRecorderBusy: "Screen recording in progress",
        failRecorderBusyRemedy: "Vorssaint’s screen recorder is running. Stop it first, then record the meeting.",
        failFolder: "Meetings folder unavailable",
        failFolderRemedy: "The meetings folder can’t be written to: it was moved, it is read-only, or its disk is disconnected. Choose another one on the Meetings page.",
        failCapture: "Recording didn’t start",
        failCaptureRemedy: "macOS did not start the capture. Try again; if it keeps failing, allow Screen Recording again in System Settings.",
        failWriter: "Recording interrupted",
        failWriterRemedy: "The file could not be closed properly. What was recorded is kept, and Vorssaint recovers it at its next launch.",
        failFinalPass: "Couldn’t finish the file",
        failFinalPassRemedy: "The video stays readable in the meeting’s folder, with the meeting and your microphone on separate tracks.",
        failBuild: "Incomplete local build",
        failBuildRemedy: "This local build lacks the fork’s permission texts: macOS shows the official ones when it asks. A published build of the fork has the right texts.",
        // MARK: Live
        pillPaused: "Paused",
        pillStopping: "Stopping…",
        pillFinalizing: "Finishing…",
        pillPictureFrozen: "Window minimized: frozen",
        pillPause: "Pause recording",
        pillResume: "Resume recording",
        pillStop: "Stop recording",
        pillFilmDisplay: "Film the whole screen",
        pillFilmWindow: "Film the meeting window",
        pillMicrophoneLevel: "Your microphone",
        pillMeetingLevel: "Meeting sound",
        pillMicrophoneOff: "Microphone not recorded",
        pillElapsed: "Recorded time",
        pillRecording: "Meeting recording",
        actionShow: "Show in Finder",
        actionOpenSettings: "Open System Settings",
        actionOpenMeetings: "Meetings settings",
        bubbleClose: "Close"
    )
}

extension ForkMeetingStrings {
    static let ptBR = ForkMeetingStrings(
        folderName: "Reuniões",
        untitledMeeting: "Reunião",
        noticeStarted: "Gravação iniciada",
        noticeResumed: "Gravação retomada",
        noticeSaved: "Reunião salva",
        noticeRecovered: "Reunião recuperada",
        noticeMicrophone: "Microfone alterado",
        noticeMicrophoneSilent: "Microfone sem som",
        noticeDiskLow: "Disco quase cheio",
        noticeDisplayChanged: "Tela alterada",
        diskMinutesFormat: "~%d min de disco",
        voiceStarted: "Gravação da reunião iniciada.",
        voicePaused: "Gravação da reunião pausada.",
        voiceResumed: "Gravação da reunião retomada.",
        voiceStopped: "Gravação da reunião parada. O arquivo está sendo finalizado.",
        voiceMicrophoneFormat: "A gravação agora usa o microfone %@.",
        voiceMicrophoneSilent: "O microfone não envia som. Verifique o microfone escolhido para as reuniões.",
        voiceDiskLowFormat: "O disco está quase cheio. Minutos de gravação restantes: %d.",
        voiceDisplayChanged: "A tela mudou. A gravação agora filma a tela onde está a janela da reunião.",
        failScreenDenied: "Acesso à tela negado",
        failScreenDeniedRemedy: "Sem ele, nada pode ser filmado. Permita o Vorssaint em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema.",
        failScreenRevoked: "Acesso à tela retirado",
        failScreenRevokedRemedy: "A gravação de tela foi desativada durante a reunião: a gravação parou e o arquivo foi mantido. Permita de novo em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema.",
        failMicrophoneDenied: "Microfone não permitido",
        failMicrophoneDeniedRemedy: "A reunião é gravada sem a sua voz. Permita o microfone em Ajustes do Sistema › Privacidade e Segurança › Microfone.",
        failSystemAudio: "Som dos apps indisponível",
        failSystemAudioRemedy: "Não foi possível gravar só o som do app da reunião, então o som de todo o Mac está sendo gravado. Permita o áudio do sistema em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema.",
        failDiskAtStartFormat: "São necessários %d GB livres",
        failDiskAtStartRemedy: "Uma reunião precisa de espaço antes de começar, para nunca encher o disco no meio. Libere espaço ou escolha uma pasta em outro disco na página Reuniões.",
        failDiskFull: "Disco cheio: gravação parada",
        failDiskFullRemedy: "A gravação parou antes de o disco encher, e o arquivo foi mantido. Libere espaço antes da próxima reunião.",
        failStreamStopped: "Parada pelo macOS",
        failStreamStoppedRemedy: "O macOS parou a captura, por exemplo pelo indicador de gravação na barra de menus. O arquivo foi mantido; inicie uma nova gravação se a reunião continuar.",
        failRecorderBusy: "Gravação de tela em curso",
        failRecorderBusyRemedy: "O gravador de tela do Vorssaint está em uso. Pare-o primeiro e depois grave a reunião.",
        failFolder: "Pasta inacessível",
        failFolderRemedy: "Não é possível gravar na pasta de reuniões: ela foi movida, é somente leitura ou o disco dela está desconectado. Escolha outra na página Reuniões.",
        failCapture: "A gravação não começou",
        failCaptureRemedy: "O macOS não iniciou a captura. Tente de novo; se continuar falhando, permita de novo a gravação de tela em Ajustes do Sistema.",
        failWriter: "Gravação interrompida",
        failWriterRemedy: "O arquivo não pôde ser fechado corretamente. O que foi gravado é mantido, e o Vorssaint o recupera na próxima vez que abrir.",
        failFinalPass: "Arquivo não finalizado",
        failFinalPassRemedy: "O vídeo continua legível na pasta da reunião, com a reunião e o seu microfone em faixas separadas.",
        failBuild: "Versão local incompleta",
        failBuildRemedy: "Esta versão local não tem os textos de permissão do fork: o macOS mostra os oficiais ao pedir. Uma versão publicada do fork tem os textos certos.",
        // MARK: Live
        pillPaused: "Pausada",
        pillStopping: "Parando…",
        pillFinalizing: "Finalizando…",
        pillPictureFrozen: "Janela minimizada: congelada",
        pillPause: "Pausar gravação",
        pillResume: "Retomar gravação",
        pillStop: "Parar gravação",
        pillFilmDisplay: "Filmar a tela inteira",
        pillFilmWindow: "Filmar a janela da reunião",
        pillMicrophoneLevel: "Seu microfone",
        pillMeetingLevel: "Som da reunião",
        pillMicrophoneOff: "Microfone não gravado",
        pillElapsed: "Tempo gravado",
        pillRecording: "Gravação de reunião",
        actionShow: "Mostrar no Finder",
        actionOpenSettings: "Abrir Ajustes do Sistema",
        actionOpenMeetings: "Ajustes das reuniões",
        bubbleClose: "Fechar"
    )
}

extension ForkMeetingStrings {
    static let tr = ForkMeetingStrings(
        folderName: "Toplantılar",
        untitledMeeting: "Toplantı",
        noticeStarted: "Kayıt başladı",
        noticeResumed: "Kayıt sürdürüldü",
        noticeSaved: "Toplantı kaydedildi",
        noticeRecovered: "Toplantı kurtarıldı",
        noticeMicrophone: "Mikrofon değişti",
        noticeMicrophoneSilent: "Mikrofon sessiz",
        noticeDiskLow: "Disk neredeyse dolu",
        noticeDisplayChanged: "Ekran değişti",
        diskMinutesFormat: "~%d dk disk kaldı",
        voiceStarted: "Toplantı kaydı başladı.",
        voicePaused: "Toplantı kaydı duraklatıldı.",
        voiceResumed: "Toplantı kaydı sürdürüldü.",
        voiceStopped: "Toplantı kaydı durduruldu. Dosya tamamlanıyor.",
        voiceMicrophoneFormat: "Kayıt artık %@ mikrofonunu kullanıyor.",
        voiceMicrophoneSilent: "Mikrofon ses göndermiyor. Toplantılar için seçilen mikrofonu kontrol edin.",
        voiceDiskLowFormat: "Disk neredeyse dolu. Kalan kayıt dakikası: %d.",
        voiceDisplayChanged: "Ekran değişti. Kayıt artık toplantı penceresinin bulunduğu ekranı çekiyor.",
        failScreenDenied: "Ekran erişimi reddedildi",
        failScreenDeniedRemedy: "Bu izin olmadan hiçbir şey kaydedilemez. Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı’ndan Vorssaint’e izin verin.",
        failScreenRevoked: "Ekran erişimi kaldırıldı",
        failScreenRevokedRemedy: "Toplantı sırasında ekran kaydı izni kapatıldı: kayıt durdu ve dosyası saklandı. Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı’ndan yeniden izin verin.",
        failMicrophoneDenied: "Mikrofona izin yok",
        failMicrophoneDeniedRemedy: "Toplantı sesiniz olmadan kaydediliyor. Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon’dan mikrofona izin verin.",
        failSystemAudio: "Uygulama sesi kullanılamıyor",
        failSystemAudioRemedy: "Toplantı uygulamasının sesi tek başına kaydedilemedi, bu yüzden tüm Mac’in sesi kaydediliyor. Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı’ndan sistem sesine izin verin.",
        failDiskAtStartFormat: "%d GB boş alan gerekli",
        failDiskAtStartRemedy: "Bir toplantı, diski yarıda doldurmamak için başlamadan önce yer ister. Yer açın ya da Toplantılar sayfasından başka bir diskte bir klasör seçin.",
        failDiskFull: "Disk dolu: kayıt durdu",
        failDiskFullRemedy: "Kayıt, disk dolmadan önce durdu ve dosyası saklandı. Bir sonraki toplantıdan önce yer açın.",
        failStreamStopped: "macOS tarafından durduruldu",
        failStreamStoppedRemedy: "macOS yakalamayı durdurdu, örneğin menü çubuğundaki kayıt göstergesinden. Dosya saklandı; toplantı sürüyorsa yeni bir kayıt başlatın.",
        failRecorderBusy: "Ekran kaydı sürüyor",
        failRecorderBusyRemedy: "Vorssaint’in ekran kaydedicisi çalışıyor. Önce onu durdurun, sonra toplantıyı kaydedin.",
        failFolder: "Klasöre erişilemiyor",
        failFolderRemedy: "Toplantı klasörüne yazılamıyor: taşınmış, salt okunur ya da diskinin bağlantısı kesilmiş. Toplantılar sayfasından başka bir klasör seçin.",
        failCapture: "Kayıt başlamadı",
        failCaptureRemedy: "macOS yakalamayı başlatmadı. Yeniden deneyin; başarısız olmaya devam ederse Sistem Ayarları’nda ekran kaydına yeniden izin verin.",
        failWriter: "Kayıt kesildi",
        failWriterRemedy: "Dosya düzgün kapatılamadı. Kaydedilenler saklandı ve Vorssaint bir sonraki açılışta onları kurtarır.",
        failFinalPass: "Dosya tamamlanamadı",
        failFinalPassRemedy: "Video, toplantı klasöründe oynatılabilir kalır; toplantı ve mikrofonunuz ayrı kanallardadır.",
        failBuild: "Yerel sürüm eksik",
        failBuildRemedy: "Bu yerel sürümde fork’un izin metinleri yok: macOS izin isterken resmî metinleri gösterir. Fork’un yayımlanmış bir sürümünde doğru metinler vardır.",
        // MARK: Live
        pillPaused: "Duraklatıldı",
        pillStopping: "Durduruluyor…",
        pillFinalizing: "Tamamlanıyor…",
        pillPictureFrozen: "Pencere küçültüldü: donuk",
        pillPause: "Kaydı duraklat",
        pillResume: "Kayda devam et",
        pillStop: "Kaydı durdur",
        pillFilmDisplay: "Tüm ekranı çek",
        pillFilmWindow: "Toplantı penceresini çek",
        pillMicrophoneLevel: "Mikrofonunuz",
        pillMeetingLevel: "Toplantı sesi",
        pillMicrophoneOff: "Mikrofon kaydedilmiyor",
        pillElapsed: "Kaydedilen süre",
        pillRecording: "Toplantı kaydı",
        actionShow: "Finder’da göster",
        actionOpenSettings: "Sistem Ayarları’nı aç",
        actionOpenMeetings: "Toplantı ayarları",
        bubbleClose: "Kapat"
    )
}

extension ForkMeetingStrings {
    static let ru = ForkMeetingStrings(
        folderName: "Встречи",
        untitledMeeting: "Встреча",
        noticeStarted: "Запись начата",
        noticeResumed: "Запись продолжена",
        noticeSaved: "Встреча сохранена",
        noticeRecovered: "Встреча восстановлена",
        noticeMicrophone: "Микрофон сменился",
        noticeMicrophoneSilent: "Микрофон молчит",
        noticeDiskLow: "Диск почти заполнен",
        noticeDisplayChanged: "Экран сменился",
        diskMinutesFormat: "Диск: ~%d мин",
        voiceStarted: "Запись встречи начата.",
        voicePaused: "Запись встречи приостановлена.",
        voiceResumed: "Запись встречи продолжена.",
        voiceStopped: "Запись встречи остановлена. Файл завершается.",
        voiceMicrophoneFormat: "Теперь запись идёт с микрофона %@.",
        voiceMicrophoneSilent: "Микрофон не передаёт звук. Проверьте микрофон, выбранный для встреч.",
        voiceDiskLowFormat: "Диск почти заполнен. Осталось минут записи: %d.",
        voiceDisplayChanged: "Экран сменился. Теперь записывается экран, на котором находится окно встречи.",
        failScreenDenied: "Нет доступа к экрану",
        failScreenDeniedRemedy: "Без него ничего не записать. Разрешите Vorssaint в Системных настройках › Конфиденциальность и безопасность › Запись экрана и системного аудио.",
        failScreenRevoked: "Доступ к экрану отозван",
        failScreenRevokedRemedy: "Запись экрана отключили во время встречи: запись остановлена, файл сохранён. Снова разрешите её в Системных настройках › Конфиденциальность и безопасность › Запись экрана и системного аудио.",
        failMicrophoneDenied: "Микрофон не разрешён",
        failMicrophoneDeniedRemedy: "Встреча записывается без вашего голоса. Разрешите микрофон в Системных настройках › Конфиденциальность и безопасность › Микрофон.",
        failSystemAudio: "Звук приложений недоступен",
        failSystemAudioRemedy: "Не удалось записать отдельно звук приложения встречи, поэтому записывается звук всего Mac. Разрешите системное аудио в Системных настройках › Конфиденциальность и безопасность › Запись экрана и системного аудио.",
        failDiskAtStartFormat: "Нужно %d ГБ свободного места",
        failDiskAtStartRemedy: "Встрече нужно место ещё до начала, чтобы диск никогда не заполнился посередине. Освободите место или выберите папку на другом диске на странице «Встречи».",
        failDiskFull: "Диск полон: остановлено",
        failDiskFullRemedy: "Запись остановлена до того, как диск заполнился, файл сохранён. Освободите место перед следующей встречей.",
        failStreamStopped: "Остановлено macOS",
        failStreamStoppedRemedy: "macOS остановила захват, например через индикатор записи в строке меню. Файл сохранён; начните новую запись, если встреча продолжается.",
        failRecorderBusy: "Идёт запись экрана",
        failRecorderBusyRemedy: "Запись экрана в Vorssaint уже идёт. Сначала остановите её, затем запишите встречу.",
        failFolder: "Папка недоступна",
        failFolderRemedy: "В папку встреч нельзя записать: её переместили, она только для чтения или её диск отключён. Выберите другую на странице «Встречи».",
        failCapture: "Запись не началась",
        failCaptureRemedy: "macOS не запустила захват. Попробуйте ещё раз; если ошибка повторяется, снова разрешите запись экрана в Системных настройках.",
        failWriter: "Запись прервана",
        failWriterRemedy: "Файл не удалось корректно закрыть. Записанное сохранено, и Vorssaint восстановит его при следующем запуске.",
        failFinalPass: "Файл не завершён",
        failFinalPassRemedy: "Видео по-прежнему воспроизводится из папки встречи, а встреча и ваш микрофон лежат на отдельных дорожках.",
        failBuild: "Неполная локальная сборка",
        failBuildRemedy: "В этой локальной сборке нет текстов разрешений форка: при запросе macOS показывает официальные. В опубликованной сборке форка тексты правильные.",
        // MARK: Live
        pillPaused: "Пауза",
        pillStopping: "Остановка…",
        pillFinalizing: "Завершение…",
        pillPictureFrozen: "Окно свёрнуто: стоп-кадр",
        pillPause: "Приостановить запись",
        pillResume: "Продолжить запись",
        pillStop: "Остановить запись",
        pillFilmDisplay: "Снимать весь экран",
        pillFilmWindow: "Снимать окно встречи",
        pillMicrophoneLevel: "Ваш микрофон",
        pillMeetingLevel: "Звук встречи",
        pillMicrophoneOff: "Микрофон не записывается",
        pillElapsed: "Записанное время",
        pillRecording: "Запись встречи",
        actionShow: "Показать в Finder",
        actionOpenSettings: "Открыть Системные настройки",
        actionOpenMeetings: "Настройки встреч",
        bubbleClose: "Закрыть"
    )
}

extension ForkMeetingStrings {
    static let es = ForkMeetingStrings(
        folderName: "Reuniones",
        untitledMeeting: "Reunión",
        noticeStarted: "Grabación iniciada",
        noticeResumed: "Grabación reanudada",
        noticeSaved: "Reunión guardada",
        noticeRecovered: "Reunión recuperada",
        noticeMicrophone: "Micrófono cambiado",
        noticeMicrophoneSilent: "Micrófono sin sonido",
        noticeDiskLow: "Disco casi lleno",
        noticeDisplayChanged: "Pantalla cambiada",
        diskMinutesFormat: "~%d min de disco libres",
        voiceStarted: "Grabación de la reunión iniciada.",
        voicePaused: "Grabación de la reunión en pausa.",
        voiceResumed: "Grabación de la reunión reanudada.",
        voiceStopped: "Grabación de la reunión detenida. Se está terminando el archivo.",
        voiceMicrophoneFormat: "La grabación usa ahora el micrófono %@.",
        voiceMicrophoneSilent: "El micrófono no envía sonido. Revisa el micrófono elegido para las reuniones.",
        voiceDiskLowFormat: "El disco está casi lleno. Minutos de grabación restantes: %d.",
        voiceDisplayChanged: "La pantalla cambió. La grabación filma ahora la pantalla donde está la ventana de la reunión.",
        failScreenDenied: "Acceso a pantalla denegado",
        failScreenDeniedRemedy: "Sin él no se puede grabar nada. Permite Vorssaint en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema.",
        failScreenRevoked: "Acceso a pantalla retirado",
        failScreenRevokedRemedy: "La grabación de pantalla se desactivó durante la reunión: la grabación se detuvo y su archivo se conserva. Vuelve a permitirla en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema.",
        failMicrophoneDenied: "Micrófono no permitido",
        failMicrophoneDeniedRemedy: "La reunión se graba sin tu voz. Permite el micrófono en Ajustes del Sistema › Privacidad y seguridad › Micrófono.",
        failSystemAudio: "Audio de apps no disponible",
        failSystemAudioRemedy: "No se pudo grabar solo el sonido de la app de la reunión, así que se graba el sonido de todo el Mac. Permite el audio del sistema en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema.",
        failDiskAtStartFormat: "Se necesitan %d GB libres",
        failDiskAtStartRemedy: "Una reunión necesita espacio antes de empezar, para no llenar nunca el disco a mitad. Libera espacio o elige una carpeta en otro disco en la página Reuniones.",
        failDiskFull: "Disco lleno: se detuvo",
        failDiskFullRemedy: "La grabación se detuvo antes de llenar el disco y su archivo se conserva. Libera espacio antes de la próxima reunión.",
        failStreamStopped: "Detenida por macOS",
        failStreamStoppedRemedy: "macOS detuvo la captura, por ejemplo desde el indicador de grabación de la barra de menús. El archivo se conserva; inicia una nueva grabación si la reunión continúa.",
        failRecorderBusy: "Grabación de pantalla activa",
        failRecorderBusyRemedy: "La grabadora de pantalla de Vorssaint está en marcha. Detenla primero y luego graba la reunión.",
        failFolder: "Carpeta no accesible",
        failFolderRemedy: "No se puede escribir en la carpeta de reuniones: se movió, es de solo lectura o su disco está desconectado. Elige otra en la página Reuniones.",
        failCapture: "La grabación no empezó",
        failCaptureRemedy: "macOS no inició la captura. Inténtalo de nuevo; si sigue fallando, vuelve a permitir la grabación de pantalla en Ajustes del Sistema.",
        failWriter: "Grabación interrumpida",
        failWriterRemedy: "El archivo no se pudo cerrar bien. Lo grabado se conserva y Vorssaint lo recupera en su próximo inicio.",
        failFinalPass: "Archivo no terminado",
        failFinalPassRemedy: "El vídeo sigue siendo legible en la carpeta de la reunión, con la reunión y tu micrófono en pistas separadas.",
        failBuild: "Versión local incompleta",
        failBuildRemedy: "A esta versión local le faltan los textos de permiso del fork: macOS muestra los oficiales al preguntar. Una versión publicada del fork tiene los textos correctos.",
        // MARK: Live
        pillPaused: "En pausa",
        pillStopping: "Deteniendo…",
        pillFinalizing: "Finalizando…",
        pillPictureFrozen: "Ventana oculta: imagen fija",
        pillPause: "Pausar grabación",
        pillResume: "Reanudar grabación",
        pillStop: "Detener grabación",
        pillFilmDisplay: "Grabar toda la pantalla",
        pillFilmWindow: "Grabar la ventana",
        pillMicrophoneLevel: "Tu micrófono",
        pillMeetingLevel: "Sonido de la reunión",
        pillMicrophoneOff: "Micrófono no grabado",
        pillElapsed: "Tiempo grabado",
        pillRecording: "Grabación de reunión",
        actionShow: "Mostrar en el Finder",
        actionOpenSettings: "Abrir Ajustes del Sistema",
        actionOpenMeetings: "Ajustes de reuniones",
        bubbleClose: "Cerrar"
    )
}

extension ForkMeetingStrings {
    static let sk = ForkMeetingStrings(
        folderName: "Stretnutia",
        untitledMeeting: "Stretnutie",
        noticeStarted: "Nahrávanie spustené",
        noticeResumed: "Nahrávanie pokračuje",
        noticeSaved: "Stretnutie uložené",
        noticeRecovered: "Stretnutie zachránené",
        noticeMicrophone: "Mikrofón sa zmenil",
        noticeMicrophoneSilent: "Mikrofón je tichý",
        noticeDiskLow: "Disk je takmer plný",
        noticeDisplayChanged: "Obrazovka sa zmenila",
        diskMinutesFormat: "Disk: ~%d min",
        voiceStarted: "Nahrávanie stretnutia sa spustilo.",
        voicePaused: "Nahrávanie stretnutia je pozastavené.",
        voiceResumed: "Nahrávanie stretnutia pokračuje.",
        voiceStopped: "Nahrávanie stretnutia sa zastavilo. Súbor sa dokončuje.",
        voiceMicrophoneFormat: "Nahrávanie teraz používa mikrofón %@.",
        voiceMicrophoneSilent: "Mikrofón neposiela žiadny zvuk. Skontrolujte mikrofón zvolený pre stretnutia.",
        voiceDiskLowFormat: "Disk je takmer plný. Zostávajúce minúty nahrávania: %d.",
        voiceDisplayChanged: "Obrazovka sa zmenila. Nahrávanie teraz sníma obrazovku s oknom stretnutia.",
        failScreenDenied: "Obrazovka nie je povolená",
        failScreenDeniedRemedy: "Bez toho sa nedá nič nahrať. Povoľte Vorssaint v Nastaveniach systému › Súkromie a bezpečnosť › Nahrávanie obrazovky a systémového audia.",
        failScreenRevoked: "Prístup k obrazovke odobratý",
        failScreenRevokedRemedy: "Nahrávanie obrazovky bolo počas stretnutia vypnuté: nahrávanie sa zastavilo a jeho súbor zostal zachovaný. Povoľte ho znova v Nastaveniach systému › Súkromie a bezpečnosť › Nahrávanie obrazovky a systémového audia.",
        failMicrophoneDenied: "Mikrofón nie je povolený",
        failMicrophoneDeniedRemedy: "Stretnutie sa nahráva bez vášho hlasu. Povoľte mikrofón v Nastaveniach systému › Súkromie a bezpečnosť › Mikrofón.",
        failSystemAudio: "Zvuk aplikácií nedostupný",
        failSystemAudioRemedy: "Zvuk aplikácie stretnutia sa nepodarilo nahrať samostatne, preto sa nahráva zvuk celého Macu. Povoľte systémové audio v Nastaveniach systému › Súkromie a bezpečnosť › Nahrávanie obrazovky a systémového audia.",
        failDiskAtStartFormat: "Treba %d GB voľného miesta",
        failDiskAtStartRemedy: "Stretnutie potrebuje miesto ešte pred začiatkom, aby nikdy nezaplnilo disk v polovici. Uvoľnite miesto alebo na stránke Stretnutia vyberte priečinok na inom disku.",
        failDiskFull: "Disk plný: zastavené",
        failDiskFullRemedy: "Nahrávanie sa zastavilo skôr, než sa disk zaplnil, a jeho súbor zostal zachovaný. Pred ďalším stretnutím uvoľnite miesto.",
        failStreamStopped: "Zastavené systémom macOS",
        failStreamStoppedRemedy: "macOS zastavil snímanie, napríklad cez indikátor nahrávania na lište menu. Súbor zostal zachovaný; ak stretnutie pokračuje, spustite nové nahrávanie.",
        failRecorderBusy: "Nahráva sa obrazovka",
        failRecorderBusyRemedy: "Nahrávač obrazovky Vorssaint beží. Najprv ho zastavte, potom nahrajte stretnutie.",
        failFolder: "Priečinok nedostupný",
        failFolderRemedy: "Do priečinka stretnutí sa nedá zapisovať: bol presunutý, je len na čítanie alebo je jeho disk odpojený. Vyberte iný na stránke Stretnutia.",
        failCapture: "Nahrávanie sa nespustilo",
        failCaptureRemedy: "macOS nespustil snímanie. Skúste to znova; ak to stále zlyháva, znova povoľte nahrávanie obrazovky v Nastaveniach systému.",
        failWriter: "Nahrávanie prerušené",
        failWriterRemedy: "Súbor sa nepodarilo správne zavrieť. Nahraté zostáva zachované a Vorssaint ho obnoví pri ďalšom spustení.",
        failFinalPass: "Súbor sa nedokončil",
        failFinalPassRemedy: "Video zostáva prehrateľné v priečinku stretnutia, so stretnutím a vaším mikrofónom na samostatných stopách.",
        failBuild: "Neúplná lokálna verzia",
        failBuildRemedy: "Tejto lokálnej verzii chýbajú texty povolení forku: macOS pri žiadosti zobrazí oficiálne texty. Zverejnená verzia forku má správne texty.",
        // MARK: Live
        pillPaused: "Pozastavené",
        pillStopping: "Zastavuje sa…",
        pillFinalizing: "Dokončuje sa…",
        pillPictureFrozen: "Okno skryté: obraz stojí",
        pillPause: "Pozastaviť nahrávanie",
        pillResume: "Pokračovať v nahrávaní",
        pillStop: "Zastaviť nahrávanie",
        pillFilmDisplay: "Nahrávať celú obrazovku",
        pillFilmWindow: "Nahrávať okno stretnutia",
        pillMicrophoneLevel: "Váš mikrofón",
        pillMeetingLevel: "Zvuk stretnutia",
        pillMicrophoneOff: "Mikrofón sa nenahráva",
        pillElapsed: "Nahraný čas",
        pillRecording: "Nahrávanie stretnutia",
        actionShow: "Zobraziť vo Finderi",
        actionOpenSettings: "Otvoriť Systémové nastavenia",
        actionOpenMeetings: "Nastavenia stretnutí",
        bubbleClose: "Zavrieť"
    )
}

extension ForkMeetingStrings {
    static let de = ForkMeetingStrings(
        folderName: "Besprechungen",
        untitledMeeting: "Besprechung",
        noticeStarted: "Aufnahme gestartet",
        noticeResumed: "Aufnahme fortgesetzt",
        noticeSaved: "Besprechung gespeichert",
        noticeRecovered: "Aufnahme wiederhergestellt",
        noticeMicrophone: "Mikrofon gewechselt",
        noticeMicrophoneSilent: "Mikrofon ist stumm",
        noticeDiskLow: "Speicher fast voll",
        noticeDisplayChanged: "Bildschirm gewechselt",
        diskMinutesFormat: "~%d Min. Speicher übrig",
        voiceStarted: "Aufnahme der Besprechung gestartet.",
        voicePaused: "Aufnahme der Besprechung pausiert.",
        voiceResumed: "Aufnahme der Besprechung fortgesetzt.",
        voiceStopped: "Aufnahme der Besprechung beendet. Die Datei wird fertiggestellt.",
        voiceMicrophoneFormat: "Die Aufnahme verwendet jetzt das Mikrofon %@.",
        voiceMicrophoneSilent: "Das Mikrofon liefert keinen Ton. Prüfe das für Besprechungen gewählte Mikrofon.",
        voiceDiskLowFormat: "Der Speicher ist fast voll. Verbleibende Aufnahmeminuten: %d.",
        voiceDisplayChanged: "Der Bildschirm hat gewechselt. Die Aufnahme filmt jetzt den Bildschirm mit dem Besprechungsfenster.",
        failScreenDenied: "Bildschirmzugriff verweigert",
        failScreenDeniedRemedy: "Ohne ihn kann nichts gefilmt werden. Erlaube Vorssaint unter Systemeinstellungen › Datenschutz & Sicherheit › Aufnahme von Bildschirm und Systemaudio.",
        failScreenRevoked: "Bildschirmzugriff entzogen",
        failScreenRevokedRemedy: "Die Bildschirmaufnahme wurde während der Besprechung ausgeschaltet: Die Aufnahme wurde beendet, ihre Datei bleibt erhalten. Erlaube sie erneut unter Systemeinstellungen › Datenschutz & Sicherheit › Aufnahme von Bildschirm und Systemaudio.",
        failMicrophoneDenied: "Mikrofon nicht erlaubt",
        failMicrophoneDeniedRemedy: "Die Besprechung wird ohne deine Stimme aufgenommen. Erlaube das Mikrofon unter Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon.",
        failSystemAudio: "App-Ton nicht verfügbar",
        failSystemAudioRemedy: "Der Ton der Besprechungs-App ließ sich nicht allein aufnehmen, daher wird der Ton des ganzen Mac aufgenommen. Erlaube Systemaudio unter Systemeinstellungen › Datenschutz & Sicherheit › Aufnahme von Bildschirm und Systemaudio.",
        failDiskAtStartFormat: "%d GB freier Speicher nötig",
        failDiskAtStartRemedy: "Eine Besprechung braucht vor dem Start Platz, damit sie den Speicher nie mittendrin füllt. Gib Speicher frei oder wähle auf der Seite „Besprechungen“ einen Ordner auf einem anderen Laufwerk.",
        failDiskFull: "Speicher voll: gestoppt",
        failDiskFullRemedy: "Die Aufnahme wurde beendet, bevor der Speicher voll war, und ihre Datei bleibt erhalten. Gib vor der nächsten Besprechung Speicher frei.",
        failStreamStopped: "Von macOS gestoppt",
        failStreamStoppedRemedy: "macOS hat die Aufnahme gestoppt, zum Beispiel über die Aufnahmeanzeige in der Menüleiste. Die Datei bleibt erhalten; starte eine neue Aufnahme, wenn die Besprechung weitergeht.",
        failRecorderBusy: "Bildschirmaufnahme läuft",
        failRecorderBusyRemedy: "Die Bildschirmaufnahme von Vorssaint läuft. Beende sie zuerst und nimm dann die Besprechung auf.",
        failFolder: "Ordner nicht erreichbar",
        failFolderRemedy: "In den Ordner für Besprechungen kann nicht geschrieben werden: Er wurde verschoben, ist schreibgeschützt oder sein Laufwerk ist getrennt. Wähle auf der Seite „Besprechungen“ einen anderen.",
        failCapture: "Aufnahme startet nicht",
        failCaptureRemedy: "macOS hat die Aufnahme nicht gestartet. Versuche es erneut; wenn es weiter scheitert, erlaube die Bildschirmaufnahme in den Systemeinstellungen erneut.",
        failWriter: "Aufnahme unterbrochen",
        failWriterRemedy: "Die Datei konnte nicht sauber geschlossen werden. Das Aufgenommene bleibt erhalten, und Vorssaint stellt es beim nächsten Start wieder her.",
        failFinalPass: "Datei nicht fertiggestellt",
        failFinalPassRemedy: "Das Video bleibt im Ordner der Besprechung abspielbar, mit der Besprechung und deinem Mikrofon auf getrennten Spuren.",
        failBuild: "Lokaler Build unvollständig",
        failBuildRemedy: "Diesem lokalen Build fehlen die Berechtigungstexte des Forks: macOS zeigt bei der Anfrage die offiziellen. Ein veröffentlichter Build des Forks hat die richtigen Texte.",
        // MARK: Live
        pillPaused: "Pausiert",
        pillStopping: "Wird gestoppt…",
        pillFinalizing: "Wird abgeschlossen…",
        pillPictureFrozen: "Fenster minimiert: Standbild",
        pillPause: "Aufnahme pausieren",
        pillResume: "Aufnahme fortsetzen",
        pillStop: "Aufnahme stoppen",
        pillFilmDisplay: "Ganzen Bildschirm filmen",
        pillFilmWindow: "Besprechungsfenster filmen",
        pillMicrophoneLevel: "Dein Mikrofon",
        pillMeetingLevel: "Ton der Besprechung",
        pillMicrophoneOff: "Mikrofon nicht aufgenommen",
        pillElapsed: "Aufgenommene Zeit",
        pillRecording: "Besprechungsaufnahme",
        actionShow: "Im Finder zeigen",
        actionOpenSettings: "Systemeinstellungen öffnen",
        actionOpenMeetings: "Besprechungseinstellungen",
        bubbleClose: "Schließen"
    )
}

extension ForkMeetingStrings {
    static let fr = ForkMeetingStrings(
        folderName: "Réunions",
        untitledMeeting: "Réunion",
        noticeStarted: "Enregistrement démarré",
        noticeResumed: "Enregistrement repris",
        noticeSaved: "Réunion enregistrée",
        noticeRecovered: "Réunion récupérée",
        noticeMicrophone: "Micro changé",
        noticeMicrophoneSilent: "Micro muet",
        noticeDiskLow: "Disque presque plein",
        noticeDisplayChanged: "Écran changé",
        diskMinutesFormat: "~%d min de disque",
        voiceStarted: "Enregistrement de la réunion démarré.",
        voicePaused: "Enregistrement de la réunion en pause.",
        voiceResumed: "Enregistrement de la réunion repris.",
        voiceStopped: "Enregistrement de la réunion arrêté. Le fichier est en cours de finalisation.",
        voiceMicrophoneFormat: "L’enregistrement utilise maintenant le micro %@.",
        voiceMicrophoneSilent: "Le micro n’envoie aucun son. Vérifiez le micro choisi pour les réunions.",
        voiceDiskLowFormat: "Le disque est presque plein. Minutes d’enregistrement restantes : %d.",
        voiceDisplayChanged: "L’écran a changé. L’enregistrement filme maintenant l’écran où se trouve la fenêtre de la réunion.",
        failScreenDenied: "Accès à l’écran refusé",
        failScreenDeniedRemedy: "Sans lui, rien ne peut être filmé. Autorisez Vorssaint dans Réglages Système › Confidentialité et sécurité › Enregistrement de l’écran et de l’audio du système.",
        failScreenRevoked: "Accès à l’écran retiré",
        failScreenRevokedRemedy: "L’enregistrement de l’écran a été coupé pendant la réunion : l’enregistrement s’est arrêté et son fichier est gardé. Autorisez-le de nouveau dans Réglages Système › Confidentialité et sécurité › Enregistrement de l’écran et de l’audio du système.",
        failMicrophoneDenied: "Micro non autorisé",
        failMicrophoneDeniedRemedy: "La réunion est enregistrée sans votre voix. Autorisez le micro dans Réglages Système › Confidentialité et sécurité › Micro.",
        failSystemAudio: "Son des apps indisponible",
        failSystemAudioRemedy: "Le son de l’app de visio n’a pas pu être enregistré seul : c’est le son de tout le Mac qui est enregistré. Autorisez l’audio du système dans Réglages Système › Confidentialité et sécurité › Enregistrement de l’écran et de l’audio du système.",
        failDiskAtStartFormat: "Il faut %d Go libres",
        failDiskAtStartRemedy: "Une réunion demande de la place avant de commencer, pour ne jamais remplir le disque en route. Libérez de l’espace, ou choisissez un dossier sur un autre disque sur la page Réunions.",
        failDiskFull: "Disque plein : arrêt",
        failDiskFullRemedy: "L’enregistrement s’est arrêté avant que le disque soit plein, et son fichier est gardé. Libérez de l’espace avant la prochaine réunion.",
        failStreamStopped: "Arrêté par macOS",
        failStreamStoppedRemedy: "macOS a arrêté la capture, par exemple depuis l’indicateur d’enregistrement de la barre des menus. Le fichier est gardé ; relancez un enregistrement si la réunion continue.",
        failRecorderBusy: "Enregistrement d’écran actif",
        failRecorderBusyRemedy: "L’enregistreur d’écran de Vorssaint tourne. Arrêtez-le d’abord, puis enregistrez la réunion.",
        failFolder: "Dossier inaccessible",
        failFolderRemedy: "Le dossier des réunions ne peut pas être écrit : il a été déplacé, il est en lecture seule, ou son disque est débranché. Choisissez-en un autre sur la page Réunions.",
        failCapture: "Démarrage impossible",
        failCaptureRemedy: "macOS n’a pas démarré la capture. Réessayez ; si l’échec se répète, autorisez de nouveau l’enregistrement de l’écran dans Réglages Système.",
        failWriter: "Enregistrement interrompu",
        failWriterRemedy: "Le fichier n’a pas pu être fermé proprement. Ce qui a été enregistré est gardé, et Vorssaint le récupère à son prochain lancement.",
        failFinalPass: "Finalisation impossible",
        failFinalPassRemedy: "La vidéo reste lisible dans le dossier de la réunion, avec la réunion et votre micro sur des pistes séparées.",
        failBuild: "Version locale incomplète",
        failBuildRemedy: "Cette version locale n’a pas les textes d’autorisation du fork : macOS affiche les textes officiels quand il demande. Une version publiée du fork a les bons textes.",
        // MARK: Live
        pillPaused: "En pause",
        pillStopping: "Arrêt…",
        pillFinalizing: "Finalisation…",
        pillPictureFrozen: "Fenêtre réduite, image figée",
        pillPause: "Mettre en pause",
        pillResume: "Reprendre l’enregistrement",
        pillStop: "Arrêter l’enregistrement",
        pillFilmDisplay: "Filmer tout l’écran",
        pillFilmWindow: "Filmer la fenêtre",
        pillMicrophoneLevel: "Votre micro",
        pillMeetingLevel: "Son de la réunion",
        pillMicrophoneOff: "Micro non enregistré",
        pillElapsed: "Durée enregistrée",
        pillRecording: "Enregistrement de réunion",
        actionShow: "Afficher dans le Finder",
        actionOpenSettings: "Ouvrir les Réglages",
        actionOpenMeetings: "Réglages des réunions",
        bubbleClose: "Fermer"
    )
}

extension ForkMeetingStrings {
    static let it = ForkMeetingStrings(
        folderName: "Riunioni",
        untitledMeeting: "Riunione",
        noticeStarted: "Registrazione avviata",
        noticeResumed: "Registrazione ripresa",
        noticeSaved: "Riunione salvata",
        noticeRecovered: "Riunione recuperata",
        noticeMicrophone: "Microfono cambiato",
        noticeMicrophoneSilent: "Microfono muto",
        noticeDiskLow: "Disco quasi pieno",
        noticeDisplayChanged: "Schermo cambiato",
        diskMinutesFormat: "~%d min di disco",
        voiceStarted: "Registrazione della riunione avviata.",
        voicePaused: "Registrazione della riunione in pausa.",
        voiceResumed: "Registrazione della riunione ripresa.",
        voiceStopped: "Registrazione della riunione fermata. Il file è in fase di completamento.",
        voiceMicrophoneFormat: "La registrazione ora usa il microfono %@.",
        voiceMicrophoneSilent: "Il microfono non invia alcun suono. Controlla il microfono scelto per le riunioni.",
        voiceDiskLowFormat: "Il disco è quasi pieno. Minuti di registrazione rimasti: %d.",
        voiceDisplayChanged: "Lo schermo è cambiato. La registrazione ora riprende lo schermo in cui si trova la finestra della riunione.",
        failScreenDenied: "Accesso allo schermo negato",
        failScreenDeniedRemedy: "Senza di esso non si può riprendere nulla. Consenti Vorssaint in Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema.",
        failScreenRevoked: "Accesso allo schermo tolto",
        failScreenRevokedRemedy: "La registrazione dello schermo è stata disattivata durante la riunione: la registrazione si è fermata e il suo file è conservato. Consentila di nuovo in Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema.",
        failMicrophoneDenied: "Microfono non consentito",
        failMicrophoneDeniedRemedy: "La riunione viene registrata senza la tua voce. Consenti il microfono in Impostazioni di Sistema › Privacy e sicurezza › Microfono.",
        failSystemAudio: "Audio app non disponibile",
        failSystemAudioRemedy: "Non è stato possibile registrare solo l’audio dell’app della riunione, quindi viene registrato l’audio di tutto il Mac. Consenti l’audio di sistema in Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema.",
        failDiskAtStartFormat: "Servono %d GB liberi",
        failDiskAtStartRemedy: "Una riunione richiede spazio prima di iniziare, così non riempie mai il disco a metà. Libera spazio o scegli una cartella su un altro disco nella pagina Riunioni.",
        failDiskFull: "Disco pieno: fermata",
        failDiskFullRemedy: "La registrazione si è fermata prima che il disco fosse pieno, e il suo file è conservato. Libera spazio prima della prossima riunione.",
        failStreamStopped: "Fermata da macOS",
        failStreamStoppedRemedy: "macOS ha fermato l’acquisizione, per esempio dall’indicatore di registrazione nella barra dei menu. Il file è conservato; avvia una nuova registrazione se la riunione continua.",
        failRecorderBusy: "Registrazione schermo attiva",
        failRecorderBusyRemedy: "Il registratore dello schermo di Vorssaint è in funzione. Fermalo prima, poi registra la riunione.",
        failFolder: "Cartella non accessibile",
        failFolderRemedy: "Non è possibile scrivere nella cartella delle riunioni: è stata spostata, è di sola lettura o il suo disco è scollegato. Scegline un’altra nella pagina Riunioni.",
        failCapture: "Registrazione non avviata",
        failCaptureRemedy: "macOS non ha avviato l’acquisizione. Riprova; se continua a non riuscire, consenti di nuovo la registrazione dello schermo in Impostazioni di Sistema.",
        failWriter: "Registrazione interrotta",
        failWriterRemedy: "Il file non si è potuto chiudere correttamente. Ciò che è stato registrato è conservato, e Vorssaint lo recupera al prossimo avvio.",
        failFinalPass: "File non completato",
        failFinalPassRemedy: "Il video resta leggibile nella cartella della riunione, con la riunione e il tuo microfono su tracce separate.",
        failBuild: "Build locale incompleta",
        failBuildRemedy: "In questa build locale mancano i testi di autorizzazione del fork: macOS mostra quelli ufficiali quando chiede. Una build pubblicata del fork ha i testi giusti.",
        // MARK: Live
        pillPaused: "In pausa",
        pillStopping: "Interruzione…",
        pillFinalizing: "Finalizzazione…",
        pillPictureFrozen: "Finestra ridotta: bloccata",
        pillPause: "Metti in pausa",
        pillResume: "Riprendi la registrazione",
        pillStop: "Ferma la registrazione",
        pillFilmDisplay: "Registra tutto lo schermo",
        pillFilmWindow: "Registra la finestra",
        pillMicrophoneLevel: "Il tuo microfono",
        pillMeetingLevel: "Audio della riunione",
        pillMicrophoneOff: "Microfono non registrato",
        pillElapsed: "Tempo registrato",
        pillRecording: "Registrazione riunione",
        actionShow: "Mostra nel Finder",
        actionOpenSettings: "Apri Impostazioni di Sistema",
        actionOpenMeetings: "Impostazioni riunioni",
        bubbleClose: "Chiudi"
    )
}

extension ForkMeetingStrings {
    static let ja = ForkMeetingStrings(
        folderName: "ミーティング",
        untitledMeeting: "ミーティング",
        noticeStarted: "録画を開始しました",
        noticeResumed: "録画を再開しました",
        noticeSaved: "ミーティングを保存しました",
        noticeRecovered: "ミーティングを復元しました",
        noticeMicrophone: "マイクが変わりました",
        noticeMicrophoneSilent: "マイクが無音です",
        noticeDiskLow: "ディスクの空きがわずかです",
        noticeDisplayChanged: "ディスプレイが変わりました",
        diskMinutesFormat: "ディスク残り約%d分",
        voiceStarted: "ミーティングの録画を開始しました。",
        voicePaused: "ミーティングの録画を一時停止しました。",
        voiceResumed: "ミーティングの録画を再開しました。",
        voiceStopped: "ミーティングの録画を停止しました。ファイルを仕上げています。",
        voiceMicrophoneFormat: "録画はマイク“%@”を使用しています。",
        voiceMicrophoneSilent: "マイクから音が届いていません。ミーティング用に選んだマイクを確認してください。",
        voiceDiskLowFormat: "ディスクの空きがわずかです。録画できる残りの分数：%d。",
        voiceDisplayChanged: "ディスプレイが変わりました。ミーティングのウインドウがあるディスプレイを録画しています。",
        failScreenDenied: "画面収録が許可されていません",
        failScreenDeniedRemedy: "許可がないと何も録画できません。システム設定 › プライバシーとセキュリティ › 画面とシステムオーディオ収録で Vorssaint を許可してください。",
        failScreenRevoked: "画面収録の許可が取り消されました",
        failScreenRevokedRemedy: "ミーティング中に画面収録がオフにされたため、録画を停止し、ファイルは保持しました。システム設定 › プライバシーとセキュリティ › 画面とシステムオーディオ収録でもう一度許可してください。",
        failMicrophoneDenied: "マイクが許可されていません",
        failMicrophoneDeniedRemedy: "ミーティングはあなたの声なしで録画されます。システム設定 › プライバシーとセキュリティ › マイクでマイクを許可してください。",
        failSystemAudio: "アプリの音声を利用できません",
        failSystemAudioRemedy: "ミーティングアプリの音声だけを録音できなかったため、Mac 全体の音声を録音しています。システム設定 › プライバシーとセキュリティ › 画面とシステムオーディオ収録でシステムオーディオを許可してください。",
        failDiskAtStartFormat: "%d GB の空き容量が必要です",
        failDiskAtStartRemedy: "途中でディスクがいっぱいにならないよう、ミーティングは開始前に空き容量を確認します。空き容量を増やすか、「ミーティング」ページで別のディスクのフォルダを選んでください。",
        failDiskFull: "ディスクがいっぱいで停止",
        failDiskFullRemedy: "ディスクがいっぱいになる前に録画を停止し、ファイルは保持しました。次のミーティングまでに空き容量を増やしてください。",
        failStreamStopped: "macOS が録画を停止しました",
        failStreamStoppedRemedy: "メニューバーの収録インジケータなどから、macOS がキャプチャを停止しました。ファイルは保持しています。ミーティングが続く場合は新しく録画を開始してください。",
        failRecorderBusy: "画面収録が実行中です",
        failRecorderBusyRemedy: "Vorssaint の画面収録が実行中です。先に停止してから、ミーティングを録画してください。",
        failFolder: "フォルダにアクセスできません",
        failFolderRemedy: "ミーティングのフォルダに書き込めません。移動された、読み出し専用になった、またはディスクが取り外された可能性があります。「ミーティング」ページで別のフォルダを選んでください。",
        failCapture: "録画を開始できませんでした",
        failCaptureRemedy: "macOS がキャプチャを開始しませんでした。もう一度試してください。失敗が続く場合は、システム設定で画面収録をもう一度許可してください。",
        failWriter: "録画が中断されました",
        failWriterRemedy: "ファイルを正しく閉じられませんでした。録画済みの部分は保持され、Vorssaint の次回起動時に復元されます。",
        failFinalPass: "ファイルを仕上げられません",
        failFinalPassRemedy: "ビデオはミーティングのフォルダ内でそのまま再生でき、ミーティングとあなたのマイクは別々のトラックに入っています。",
        failBuild: "ローカルビルドが不完全",
        failBuildRemedy: "このローカルビルドにはフォークの許可テキストがありません。macOS は許可を求めるときに公式のテキストを表示します。公開されたフォークのビルドには正しいテキストがあります。",
        // MARK: Live
        pillPaused: "一時停止中",
        pillStopping: "停止中…",
        pillFinalizing: "仕上げ中…",
        pillPictureFrozen: "ウインドウ最小化：静止画",
        pillPause: "録画を一時停止",
        pillResume: "録画を再開",
        pillStop: "録画を停止",
        pillFilmDisplay: "画面全体を録画",
        pillFilmWindow: "ミーティングのウインドウを録画",
        pillMicrophoneLevel: "あなたのマイク",
        pillMeetingLevel: "ミーティングの音声",
        pillMicrophoneOff: "マイクは録音されません",
        pillElapsed: "録画時間",
        pillRecording: "ミーティングの録画",
        actionShow: "Finderに表示",
        actionOpenSettings: "システム設定を開く",
        actionOpenMeetings: "ミーティングの設定",
        bubbleClose: "閉じる"
    )
}

extension ForkMeetingStrings {
    static let ko = ForkMeetingStrings(
        folderName: "회의",
        untitledMeeting: "회의",
        noticeStarted: "녹화 시작됨",
        noticeResumed: "녹화 재개됨",
        noticeSaved: "회의 저장됨",
        noticeRecovered: "회의 복구됨",
        noticeMicrophone: "마이크 변경됨",
        noticeMicrophoneSilent: "마이크 소리 없음",
        noticeDiskLow: "디스크 공간 부족",
        noticeDisplayChanged: "디스플레이 변경됨",
        diskMinutesFormat: "디스크 약 %d분 남음",
        voiceStarted: "회의 녹화를 시작했습니다.",
        voicePaused: "회의 녹화를 일시 정지했습니다.",
        voiceResumed: "회의 녹화를 재개했습니다.",
        voiceStopped: "회의 녹화를 중지했습니다. 파일을 마무리하는 중입니다.",
        voiceMicrophoneFormat: "이제 %@ 마이크로 녹음합니다.",
        voiceMicrophoneSilent: "마이크에서 소리가 들어오지 않습니다. 회의용으로 선택한 마이크를 확인하세요.",
        voiceDiskLowFormat: "디스크 공간이 거의 없습니다. 남은 녹화 시간(분): %d.",
        voiceDisplayChanged: "디스플레이가 바뀌었습니다. 이제 회의 윈도우가 있는 디스플레이를 녹화합니다.",
        failScreenDenied: "화면 녹화가 허용되지 않음",
        failScreenDeniedRemedy: "허용하지 않으면 아무것도 녹화할 수 없습니다. 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 Vorssaint를 허용하세요.",
        failScreenRevoked: "화면 녹화 권한이 철회됨",
        failScreenRevokedRemedy: "회의 중에 화면 녹화가 꺼져 녹화를 중지했으며 파일은 보존되었습니다. 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 다시 허용하세요.",
        failMicrophoneDenied: "마이크가 허용되지 않음",
        failMicrophoneDeniedRemedy: "회의가 내 목소리 없이 녹화됩니다. 시스템 설정 › 개인정보 보호 및 보안 › 마이크에서 마이크를 허용하세요.",
        failSystemAudio: "앱 소리를 사용할 수 없음",
        failSystemAudioRemedy: "회의 앱의 소리만 따로 녹음할 수 없어 Mac 전체의 소리를 녹음합니다. 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 시스템 오디오를 허용하세요.",
        failDiskAtStartFormat: "%dGB의 여유 공간 필요",
        failDiskAtStartRemedy: "회의 도중 디스크가 가득 차지 않도록 시작 전에 공간을 확인합니다. 공간을 확보하거나 ‘회의’ 페이지에서 다른 디스크의 폴더를 선택하세요.",
        failDiskFull: "디스크가 가득 차 중지됨",
        failDiskFullRemedy: "디스크가 가득 차기 전에 녹화를 중지했으며 파일은 보존되었습니다. 다음 회의 전에 공간을 확보하세요.",
        failStreamStopped: "macOS가 녹화를 중지함",
        failStreamStoppedRemedy: "메뉴 막대의 녹화 표시기 등에서 macOS가 캡처를 중지했습니다. 파일은 보존되었습니다. 회의가 계속되면 새 녹화를 시작하세요.",
        failRecorderBusy: "화면 녹화가 진행 중",
        failRecorderBusyRemedy: "Vorssaint의 화면 녹화가 진행 중입니다. 먼저 중지한 다음 회의를 녹화하세요.",
        failFolder: "폴더에 접근할 수 없음",
        failFolderRemedy: "회의 폴더에 쓸 수 없습니다. 폴더가 이동되었거나, 읽기 전용이거나, 디스크 연결이 해제되었습니다. ‘회의’ 페이지에서 다른 폴더를 선택하세요.",
        failCapture: "녹화를 시작하지 못함",
        failCaptureRemedy: "macOS가 캡처를 시작하지 않았습니다. 다시 시도하세요. 계속 실패하면 시스템 설정에서 화면 녹화를 다시 허용하세요.",
        failWriter: "녹화가 중단됨",
        failWriterRemedy: "파일을 제대로 닫지 못했습니다. 녹화된 내용은 보존되며 Vorssaint를 다음에 실행할 때 복구됩니다.",
        failFinalPass: "파일을 마무리하지 못함",
        failFinalPassRemedy: "비디오는 회의 폴더에서 그대로 재생할 수 있으며, 회의와 내 마이크는 별도 트랙에 들어 있습니다.",
        failBuild: "로컬 빌드가 불완전함",
        failBuildRemedy: "이 로컬 빌드에는 포크의 권한 텍스트가 없어 macOS가 요청할 때 공식 텍스트를 표시합니다. 게시된 포크 빌드에는 올바른 텍스트가 있습니다.",
        // MARK: Live
        pillPaused: "일시 정지됨",
        pillStopping: "중지하는 중…",
        pillFinalizing: "마무리하는 중…",
        pillPictureFrozen: "윈도우 최소화: 정지 화면",
        pillPause: "녹화 일시 정지",
        pillResume: "녹화 재개",
        pillStop: "녹화 중지",
        pillFilmDisplay: "전체 화면 녹화",
        pillFilmWindow: "회의 윈도우 녹화",
        pillMicrophoneLevel: "내 마이크",
        pillMeetingLevel: "회의 소리",
        pillMicrophoneOff: "마이크 녹음 안 함",
        pillElapsed: "녹화된 시간",
        pillRecording: "회의 녹화",
        actionShow: "Finder에서 보기",
        actionOpenSettings: "시스템 설정 열기",
        actionOpenMeetings: "회의 설정",
        bubbleClose: "닫기"
    )
}

extension ForkMeetingStrings {
    static let uk = ForkMeetingStrings(
        folderName: "Зустрічі",
        untitledMeeting: "Зустріч",
        noticeStarted: "Запис розпочато",
        noticeResumed: "Запис продовжено",
        noticeSaved: "Зустріч збережено",
        noticeRecovered: "Зустріч відновлено",
        noticeMicrophone: "Мікрофон змінено",
        noticeMicrophoneSilent: "Мікрофон мовчить",
        noticeDiskLow: "Диск майже заповнений",
        noticeDisplayChanged: "Екран змінено",
        diskMinutesFormat: "Диск: ~%d хв",
        voiceStarted: "Запис зустрічі розпочато.",
        voicePaused: "Запис зустрічі призупинено.",
        voiceResumed: "Запис зустрічі продовжено.",
        voiceStopped: "Запис зустрічі зупинено. Файл завершується.",
        voiceMicrophoneFormat: "Тепер запис іде з мікрофона %@.",
        voiceMicrophoneSilent: "Мікрофон не передає звуку. Перевірте мікрофон, вибраний для зустрічей.",
        voiceDiskLowFormat: "Диск майже заповнений. Залишилося хвилин запису: %d.",
        voiceDisplayChanged: "Екран змінився. Тепер записується екран, на якому розташоване вікно зустрічі.",
        failScreenDenied: "Немає доступу до екрана",
        failScreenDeniedRemedy: "Без нього нічого не записати. Дозвольте Vorssaint у Системних параметрах › Приватність і безпека › Записування системного звуку й екрана.",
        failScreenRevoked: "Доступ до екрана відкликано",
        failScreenRevokedRemedy: "Записування екрана вимкнули під час зустрічі: запис зупинено, файл збережено. Знову дозвольте його в Системних параметрах › Приватність і безпека › Записування системного звуку й екрана.",
        failMicrophoneDenied: "Мікрофон не дозволено",
        failMicrophoneDeniedRemedy: "Зустріч записується без вашого голосу. Дозвольте мікрофон у Системних параметрах › Приватність і безпека › Мікрофон.",
        failSystemAudio: "Звук програм недоступний",
        failSystemAudioRemedy: "Не вдалося записати окремо звук програми зустрічі, тому записується звук усього Mac. Дозвольте системний звук у Системних параметрах › Приватність і безпека › Записування системного звуку й екрана.",
        failDiskAtStartFormat: "Треба %d ГБ вільного місця",
        failDiskAtStartRemedy: "Зустрічі потрібне місце ще до початку, щоб диск ніколи не заповнився посередині. Звільніть місце або виберіть папку на іншому диску на сторінці «Зустрічі».",
        failDiskFull: "Диск повний: зупинено",
        failDiskFullRemedy: "Запис зупинено до того, як диск заповнився, файл збережено. Звільніть місце перед наступною зустріччю.",
        failStreamStopped: "Зупинено macOS",
        failStreamStoppedRemedy: "macOS зупинила захоплення, наприклад через індикатор запису в рядку меню. Файл збережено; почніть новий запис, якщо зустріч триває.",
        failRecorderBusy: "Триває запис екрана",
        failRecorderBusyRemedy: "Запис екрана у Vorssaint уже триває. Спершу зупиніть його, потім запишіть зустріч.",
        failFolder: "Папка недоступна",
        failFolderRemedy: "У папку зустрічей не можна записати: її перемістили, вона лише для читання або її диск від’єднано. Виберіть іншу на сторінці «Зустрічі».",
        failCapture: "Запис не розпочався",
        failCaptureRemedy: "macOS не запустила захоплення. Спробуйте ще раз; якщо помилка повторюється, знову дозвольте записування екрана в Системних параметрах.",
        failWriter: "Запис перервано",
        failWriterRemedy: "Файл не вдалося коректно закрити. Записане збережено, і Vorssaint відновить його під час наступного запуску.",
        failFinalPass: "Файл не завершено",
        failFinalPassRemedy: "Відео й далі відтворюється з папки зустрічі, а зустріч і ваш мікрофон записані на окремих доріжках.",
        failBuild: "Неповна локальна збірка",
        failBuildRemedy: "У цій локальній збірці немає текстів дозволів форку: під час запиту macOS показує офіційні. В опублікованій збірці форку тексти правильні.",
        // MARK: Live
        pillPaused: "Призупинено",
        pillStopping: "Зупинка…",
        pillFinalizing: "Завершення…",
        pillPictureFrozen: "Вікно згорнуто: стоп-кадр",
        pillPause: "Призупинити запис",
        pillResume: "Продовжити запис",
        pillStop: "Зупинити запис",
        pillFilmDisplay: "Знімати весь екран",
        pillFilmWindow: "Знімати вікно зустрічі",
        pillMicrophoneLevel: "Ваш мікрофон",
        pillMeetingLevel: "Звук зустрічі",
        pillMicrophoneOff: "Мікрофон не записується",
        pillElapsed: "Записаний час",
        pillRecording: "Запис зустрічі",
        actionShow: "Показати у Finder",
        actionOpenSettings: "Відкрити Системні параметри",
        actionOpenMeetings: "Параметри зустрічей",
        bubbleClose: "Закрити"
    )
}

extension ForkMeetingStrings {
    static let zhHans = ForkMeetingStrings(
        folderName: "会议",
        untitledMeeting: "会议",
        noticeStarted: "已开始录制",
        noticeResumed: "已恢复录制",
        noticeSaved: "会议已保存",
        noticeRecovered: "会议已恢复",
        noticeMicrophone: "麦克风已更换",
        noticeMicrophoneSilent: "麦克风没有声音",
        noticeDiskLow: "磁盘几乎已满",
        noticeDisplayChanged: "显示器已更换",
        diskMinutesFormat: "磁盘约剩 %d 分钟",
        voiceStarted: "已开始录制会议。",
        voicePaused: "会议录制已暂停。",
        voiceResumed: "会议录制已恢复。",
        voiceStopped: "会议录制已停止，正在完成文件。",
        voiceMicrophoneFormat: "现在使用麦克风“%@”录制。",
        voiceMicrophoneSilent: "麦克风没有传来声音。请检查为会议选择的麦克风。",
        voiceDiskLowFormat: "磁盘几乎已满。剩余可录制分钟数：%d。",
        voiceDisplayChanged: "显示器已更换。现在录制会议窗口所在的显示器。",
        failScreenDenied: "未允许屏幕录制",
        failScreenDeniedRemedy: "没有该权限就无法录制任何内容。请在“系统设置”›“隐私与安全性”›“屏幕与系统音频录制”中允许 Vorssaint。",
        failScreenRevoked: "屏幕录制权限已撤销",
        failScreenRevokedRemedy: "会议期间屏幕录制被关闭：录制已停止，文件已保留。请在“系统设置”›“隐私与安全性”›“屏幕与系统音频录制”中重新允许。",
        failMicrophoneDenied: "未允许麦克风",
        failMicrophoneDeniedRemedy: "会议将在没有你声音的情况下录制。请在“系统设置”›“隐私与安全性”›“麦克风”中允许麦克风。",
        failSystemAudio: "无法获取 App 声音",
        failSystemAudioRemedy: "无法单独录制会议 App 的声音，因此改为录制整台 Mac 的声音。请在“系统设置”›“隐私与安全性”›“屏幕与系统音频录制”中允许系统音频。",
        failDiskAtStartFormat: "需要 %d GB 可用空间",
        failDiskAtStartRemedy: "会议开始前需要预留空间，以免中途占满磁盘。请释放空间，或在“会议”页面选择其他磁盘上的文件夹。",
        failDiskFull: "磁盘已满，录制已停止",
        failDiskFullRemedy: "录制在磁盘占满前已停止，文件已保留。请在下次会议前释放空间。",
        failStreamStopped: "macOS 停止了录制",
        failStreamStoppedRemedy: "macOS 停止了捕获，例如通过菜单栏中的录制指示器。文件已保留；如果会议仍在进行，请开始新的录制。",
        failRecorderBusy: "正在进行屏幕录制",
        failRecorderBusyRemedy: "Vorssaint 的屏幕录制正在进行。请先停止它，然后再录制会议。",
        failFolder: "无法访问文件夹",
        failFolderRemedy: "无法写入会议文件夹：它可能已被移动、为只读，或其磁盘已断开。请在“会议”页面选择其他文件夹。",
        failCapture: "录制未能开始",
        failCaptureRemedy: "macOS 没有开始捕获。请重试；如果仍然失败，请在“系统设置”中重新允许屏幕录制。",
        failWriter: "录制已中断",
        failWriterRemedy: "文件未能正常关闭。已录制的内容会保留，Vorssaint 会在下次启动时恢复它。",
        failFinalPass: "无法完成文件",
        failFinalPassRemedy: "视频在会议文件夹中仍可播放，会议声音和你的麦克风位于不同的音轨。",
        failBuild: "本地版本不完整",
        failBuildRemedy: "此本地版本缺少此分支的权限说明文字：macOS 请求权限时会显示官方文字。此分支的已发布版本包含正确的文字。",
        // MARK: Live
        pillPaused: "已暂停",
        pillStopping: "正在停止…",
        pillFinalizing: "正在完成…",
        pillPictureFrozen: "窗口已最小化：画面静止",
        pillPause: "暂停录制",
        pillResume: "继续录制",
        pillStop: "停止录制",
        pillFilmDisplay: "录制整个屏幕",
        pillFilmWindow: "录制会议窗口",
        pillMicrophoneLevel: "你的麦克风",
        pillMeetingLevel: "会议声音",
        pillMicrophoneOff: "未录制麦克风",
        pillElapsed: "已录制时长",
        pillRecording: "会议录制",
        actionShow: "在访达中显示",
        actionOpenSettings: "打开系统设置",
        actionOpenMeetings: "会议设置",
        bubbleClose: "关闭"
    )
}

extension ForkMeetingStrings {
    static let zhTW = ForkMeetingStrings(
        folderName: "會議",
        untitledMeeting: "會議",
        noticeStarted: "已開始錄製",
        noticeResumed: "已繼續錄製",
        noticeSaved: "會議已儲存",
        noticeRecovered: "會議已復原",
        noticeMicrophone: "麥克風已變更",
        noticeMicrophoneSilent: "麥克風沒有聲音",
        noticeDiskLow: "磁碟空間快用完了",
        noticeDisplayChanged: "顯示器已變更",
        diskMinutesFormat: "磁碟約剩 %d 分鐘",
        voiceStarted: "已開始錄製會議。",
        voicePaused: "會議錄製已暫停。",
        voiceResumed: "會議錄製已繼續。",
        voiceStopped: "會議錄製已停止，正在完成檔案。",
        voiceMicrophoneFormat: "現在使用麥克風「%@」錄製。",
        voiceMicrophoneSilent: "麥克風沒有傳來聲音。請檢查為會議選擇的麥克風。",
        voiceDiskLowFormat: "磁碟空間快用完了。剩餘可錄製分鐘數：%d。",
        voiceDisplayChanged: "顯示器已變更。現在錄製會議視窗所在的顯示器。",
        failScreenDenied: "未允許螢幕錄製",
        failScreenDeniedRemedy: "沒有此權限就無法錄製任何內容。請在「系統設定」›「隱私權與安全性」›「螢幕與系統音訊錄製」中允許 Vorssaint。",
        failScreenRevoked: "螢幕錄製權限已撤銷",
        failScreenRevokedRemedy: "會議期間螢幕錄製被關閉：錄製已停止，檔案已保留。請在「系統設定」›「隱私權與安全性」›「螢幕與系統音訊錄製」中重新允許。",
        failMicrophoneDenied: "未允許麥克風",
        failMicrophoneDeniedRemedy: "會議會在沒有你聲音的情況下錄製。請在「系統設定」›「隱私權與安全性」›「麥克風」中允許麥克風。",
        failSystemAudio: "無法取得 App 聲音",
        failSystemAudioRemedy: "無法單獨錄製會議 App 的聲音，因此改為錄製整台 Mac 的聲音。請在「系統設定」›「隱私權與安全性」›「螢幕與系統音訊錄製」中允許系統音訊。",
        failDiskAtStartFormat: "需要 %d GB 可用空間",
        failDiskAtStartRemedy: "會議開始前需要預留空間，以免中途塞滿磁碟。請釋放空間，或在「會議」頁面選擇其他磁碟上的檔案夾。",
        failDiskFull: "磁碟已滿，錄製已停止",
        failDiskFullRemedy: "錄製在磁碟塞滿前已停止，檔案已保留。請在下次會議前釋放空間。",
        failStreamStopped: "macOS 停止了錄製",
        failStreamStoppedRemedy: "macOS 停止了擷取，例如透過選單列中的錄製指示器。檔案已保留；如果會議仍在進行，請開始新的錄製。",
        failRecorderBusy: "正在進行螢幕錄製",
        failRecorderBusyRemedy: "Vorssaint 的螢幕錄製正在進行。請先停止，再錄製會議。",
        failFolder: "無法存取檔案夾",
        failFolderRemedy: "無法寫入會議檔案夾：它可能已被搬移、為唯讀，或其磁碟已中斷連線。請在「會議」頁面選擇其他檔案夾。",
        failCapture: "錄製未能開始",
        failCaptureRemedy: "macOS 沒有開始擷取。請再試一次；如果仍然失敗，請在「系統設定」中重新允許螢幕錄製。",
        failWriter: "錄製已中斷",
        failWriterRemedy: "檔案未能正常關閉。已錄製的內容會保留，Vorssaint 會在下次啟動時復原。",
        failFinalPass: "無法完成檔案",
        failFinalPassRemedy: "影片在會議檔案夾中仍可播放，會議聲音和你的麥克風位於不同的音軌。",
        failBuild: "本機版本不完整",
        failBuildRemedy: "此本機版本缺少此分支的權限說明文字：macOS 要求權限時會顯示官方文字。此分支的已發布版本包含正確的文字。",
        // MARK: Live
        pillPaused: "已暫停",
        pillStopping: "正在停止…",
        pillFinalizing: "正在完成…",
        pillPictureFrozen: "視窗已縮到最小：畫面靜止",
        pillPause: "暫停錄製",
        pillResume: "繼續錄製",
        pillStop: "停止錄製",
        pillFilmDisplay: "錄製整個螢幕",
        pillFilmWindow: "錄製會議視窗",
        pillMicrophoneLevel: "你的麥克風",
        pillMeetingLevel: "會議聲音",
        pillMicrophoneOff: "未錄製麥克風",
        pillElapsed: "已錄製時間",
        pillRecording: "會議錄製",
        actionShow: "在 Finder 中顯示",
        actionOpenSettings: "打開系統設定",
        actionOpenMeetings: "會議設定",
        bubbleClose: "關閉"
    )
}

extension ForkMeetingStrings {
    static let zhHK = ForkMeetingStrings(
        folderName: "會議",
        untitledMeeting: "會議",
        noticeStarted: "已開始錄製",
        noticeResumed: "已恢復錄製",
        noticeSaved: "會議已儲存",
        noticeRecovered: "會議已復原",
        noticeMicrophone: "麥克風已變更",
        noticeMicrophoneSilent: "麥克風沒有聲音",
        noticeDiskLow: "磁碟空間差不多用完",
        noticeDisplayChanged: "顯示器已變更",
        diskMinutesFormat: "磁碟約剩 %d 分鐘",
        voiceStarted: "已開始錄製會議。",
        voicePaused: "會議錄製已暫停。",
        voiceResumed: "會議錄製已恢復。",
        voiceStopped: "會議錄製已停止，正在完成檔案。",
        voiceMicrophoneFormat: "現在使用麥克風「%@」錄製。",
        voiceMicrophoneSilent: "麥克風沒有傳來聲音。請檢查為會議選擇的麥克風。",
        voiceDiskLowFormat: "磁碟空間差不多用完。剩餘可錄製分鐘數：%d。",
        voiceDisplayChanged: "顯示器已變更。現在錄製會議視窗所在的顯示器。",
        failScreenDenied: "未允許螢幕錄製",
        failScreenDeniedRemedy: "沒有此權限就無法錄製任何內容。請在「系統設定」›「隱私權與安全性」›「螢幕與系統音訊錄製」中允許 Vorssaint。",
        failScreenRevoked: "螢幕錄製權限已撤銷",
        failScreenRevokedRemedy: "會議期間螢幕錄製被關閉：錄製已停止，檔案已保留。請在「系統設定」›「隱私權與安全性」›「螢幕與系統音訊錄製」中重新允許。",
        failMicrophoneDenied: "未允許麥克風",
        failMicrophoneDeniedRemedy: "會議會在沒有你聲音的情況下錄製。請在「系統設定」›「隱私權與安全性」›「麥克風」中允許麥克風。",
        failSystemAudio: "無法取得 App 聲音",
        failSystemAudioRemedy: "無法單獨錄製會議 App 的聲音，因此改為錄製整台 Mac 的聲音。請在「系統設定」›「隱私權與安全性」›「螢幕與系統音訊錄製」中允許系統音訊。",
        failDiskAtStartFormat: "需要 %d GB 可用空間",
        failDiskAtStartRemedy: "會議開始前需要預留空間，以免中途塞滿磁碟。請釋放空間，或在「會議」頁面選擇其他磁碟上的檔案夾。",
        failDiskFull: "磁碟已滿，錄製已停止",
        failDiskFullRemedy: "錄製在磁碟塞滿前已停止，檔案已保留。請在下次會議前釋放空間。",
        failStreamStopped: "macOS 停止了錄製",
        failStreamStoppedRemedy: "macOS 停止了擷取，例如透過選單列中的錄製指示器。檔案已保留；如果會議仍在進行，請開始新的錄製。",
        failRecorderBusy: "正在進行螢幕錄製",
        failRecorderBusyRemedy: "Vorssaint 的螢幕錄製正在進行。請先停止，再錄製會議。",
        failFolder: "無法存取檔案夾",
        failFolderRemedy: "無法寫入會議檔案夾：它可能已被搬移、為唯讀，或其磁碟已中斷連線。請在「會議」頁面選擇其他檔案夾。",
        failCapture: "錄製未能開始",
        failCaptureRemedy: "macOS 沒有開始擷取。請再試一次；如果仍然失敗，請在「系統設定」中重新允許螢幕錄製。",
        failWriter: "錄製已中斷",
        failWriterRemedy: "檔案未能正常關閉。已錄製的內容會保留，Vorssaint 會在下次啟動時還原。",
        failFinalPass: "無法完成檔案",
        failFinalPassRemedy: "影片在會議檔案夾中仍可播放，會議聲音和你的麥克風位於不同的音軌。",
        failBuild: "本機版本不完整",
        failBuildRemedy: "此本機版本缺少此分支的權限說明文字：macOS 要求權限時會顯示官方文字。此分支的已發布版本包含正確的文字。",
        // MARK: Live
        pillPaused: "已暫停",
        pillStopping: "正在停止…",
        pillFinalizing: "正在完成…",
        pillPictureFrozen: "視窗已縮到最小：畫面靜止",
        pillPause: "暫停錄製",
        pillResume: "繼續錄製",
        pillStop: "停止錄製",
        pillFilmDisplay: "錄製整個螢幕",
        pillFilmWindow: "錄製會議視窗",
        pillMicrophoneLevel: "你的麥克風",
        pillMeetingLevel: "會議聲音",
        pillMicrophoneOff: "未錄製麥克風",
        pillElapsed: "已錄製時間",
        pillRecording: "會議錄製",
        actionShow: "在 Finder 中顯示",
        actionOpenSettings: "打開系統設定",
        actionOpenMeetings: "會議設定",
        bubbleClose: "關閉"
    )
}
