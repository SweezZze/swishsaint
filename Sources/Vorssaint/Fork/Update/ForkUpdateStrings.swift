// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// Strings for the fork's own updater. Same contract as the FeatureStrings
/// structs: memberwise init in declaration order, one static per language.
struct ForkUpdateStrings {
    let section: String
    let caption: String
    let currentBuild: String
    let basedOn: String
    let unknownBuild: String
    let check: String
    let checking: String
    let upToDate: String
    let availableTitle: String
    let availableBody: String
    let install: String
    let later: String
    let downloading: String
    let installing: String
    let openReleasesPage: String
    let checkFailed: String
    let downloadFailed: String
    let damaged: String
    let untrusted: String
    let cannotReplace: String
    let localBuild: String

    static var current: ForkUpdateStrings { strings(L10n.shared.language) }

    static func strings(_ language: AppLanguage) -> ForkUpdateStrings {
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
}

extension ForkUpdateStrings {
    static let enUS = ForkUpdateStrings(
        section: "Updates",
        caption: "This unofficial version updates itself from its own releases, never from the official app. An update installs only if it is signed like this copy, so the Accessibility permission stays granted.",
        currentBuild: "Installed build",
        basedOn: "Based on Vorssaint",
        unknownBuild: "unknown",
        check: "Check for updates",
        checking: "Checking…",
        upToDate: "This is the latest version.",
        availableTitle: "A new version is available",
        availableBody: "The app will quit, update itself and open again in a few seconds.",
        install: "Install",
        later: "Later",
        downloading: "Downloading…",
        installing: "Installing, the app will open again…",
        openReleasesPage: "Open the downloads page",
        checkFailed: "Could not check for updates. Check your connection and try again.",
        downloadFailed: "The download failed. Try again in a moment.",
        damaged: "The download is damaged. Nothing was changed; try again.",
        untrusted: "This download is not signed like your copy, so it was not installed.",
        cannotReplace: "The app cannot replace itself where it is. Move it to the Applications folder, or download the new version from its page.",
        localBuild: "This copy was built on this Mac: it does not update itself."
    )

    static let ptBR = ForkUpdateStrings(
        section: "Atualizações",
        caption: "Esta versão não oficial se atualiza a partir das próprias versões publicadas, nunca do app oficial. Uma atualização só é instalada se estiver assinada como esta cópia, então a permissão de Acessibilidade continua concedida.",
        currentBuild: "Build instalado",
        basedOn: "Baseado no Vorssaint",
        unknownBuild: "desconhecido",
        check: "Procurar atualizações",
        checking: "Procurando…",
        upToDate: "Esta é a versão mais recente.",
        availableTitle: "Uma nova versão está disponível",
        availableBody: "O app vai fechar, se atualizar e abrir de novo em alguns segundos.",
        install: "Instalar",
        later: "Depois",
        downloading: "Baixando…",
        installing: "Instalando, o app vai abrir de novo…",
        openReleasesPage: "Abrir a página de downloads",
        checkFailed: "Não foi possível procurar atualizações. Verifique a conexão e tente de novo.",
        downloadFailed: "O download falhou. Tente de novo em instantes.",
        damaged: "O download está corrompido. Nada foi alterado; tente de novo.",
        untrusted: "Este download não está assinado como a sua cópia, então não foi instalado.",
        cannotReplace: "O app não consegue se substituir onde está. Mova-o para a pasta Aplicativos ou baixe a nova versão na página dela.",
        localBuild: "Esta cópia foi compilada neste Mac: ela não se atualiza sozinha."
    )

    static let tr = ForkUpdateStrings(
        section: "Güncellemeler",
        caption: "Bu resmî olmayan sürüm kendi yayınlarından güncellenir, asla resmî uygulamadan değil. Bir güncelleme yalnızca bu kopya gibi imzalanmışsa yüklenir; böylece Erişilebilirlik izni verilmiş olarak kalır.",
        currentBuild: "Yüklü derleme",
        basedOn: "Temel alınan Vorssaint",
        unknownBuild: "bilinmiyor",
        check: "Güncellemeleri denetle",
        checking: "Denetleniyor…",
        upToDate: "Bu en son sürüm.",
        availableTitle: "Yeni bir sürüm var",
        availableBody: "Uygulama kapanacak, kendini güncelleyecek ve birkaç saniye içinde yeniden açılacak.",
        install: "Yükle",
        later: "Sonra",
        downloading: "İndiriliyor…",
        installing: "Yükleniyor, uygulama yeniden açılacak…",
        openReleasesPage: "İndirme sayfasını aç",
        checkFailed: "Güncellemeler denetlenemedi. Bağlantınızı denetleyip yeniden deneyin.",
        downloadFailed: "İndirme başarısız oldu. Birazdan yeniden deneyin.",
        damaged: "İndirilen dosya bozuk. Hiçbir şey değişmedi; yeniden deneyin.",
        untrusted: "Bu indirme kopyanız gibi imzalanmamış, bu yüzden yüklenmedi.",
        cannotReplace: "Uygulama bulunduğu yerde kendini değiştiremiyor. Onu Uygulamalar klasörüne taşıyın ya da yeni sürümü sayfasından indirin.",
        localBuild: "Bu kopya bu Mac'te derlendi: kendini güncellemez."
    )

    static let ru = ForkUpdateStrings(
        section: "Обновления",
        caption: "Эта неофициальная версия обновляется из собственных выпусков и никогда — из официального приложения. Обновление устанавливается, только если оно подписано так же, как эта копия, поэтому разрешение Универсального доступа сохраняется.",
        currentBuild: "Установленная сборка",
        basedOn: "На основе Vorssaint",
        unknownBuild: "неизвестно",
        check: "Проверить обновления",
        checking: "Проверка…",
        upToDate: "Это последняя версия.",
        availableTitle: "Доступна новая версия",
        availableBody: "Приложение закроется, обновится и снова откроется через несколько секунд.",
        install: "Установить",
        later: "Позже",
        downloading: "Загрузка…",
        installing: "Установка, приложение снова откроется…",
        openReleasesPage: "Открыть страницу загрузок",
        checkFailed: "Не удалось проверить обновления. Проверьте подключение и повторите попытку.",
        downloadFailed: "Загрузка не удалась. Повторите попытку чуть позже.",
        damaged: "Загруженный файл повреждён. Ничего не изменено; повторите попытку.",
        untrusted: "Эта загрузка подписана не так, как ваша копия, поэтому она не установлена.",
        cannotReplace: "Приложение не может заменить себя в этом месте. Переместите его в папку «Программы» или загрузите новую версию с её страницы.",
        localBuild: "Эта копия собрана на этом Mac: она не обновляется сама."
    )

    static let es = ForkUpdateStrings(
        section: "Actualizaciones",
        caption: "Esta versión no oficial se actualiza desde sus propias publicaciones, nunca desde la app oficial. Una actualización solo se instala si está firmada como esta copia, así que el permiso de Accesibilidad sigue concedido.",
        currentBuild: "Compilación instalada",
        basedOn: "Basada en Vorssaint",
        unknownBuild: "desconocida",
        check: "Buscar actualizaciones",
        checking: "Buscando…",
        upToDate: "Esta es la versión más reciente.",
        availableTitle: "Hay una nueva versión disponible",
        availableBody: "La app se cerrará, se actualizará y se volverá a abrir en unos segundos.",
        install: "Instalar",
        later: "Más tarde",
        downloading: "Descargando…",
        installing: "Instalando, la app se volverá a abrir…",
        openReleasesPage: "Abrir la página de descargas",
        checkFailed: "No se pudieron buscar actualizaciones. Revisa la conexión y vuelve a intentarlo.",
        downloadFailed: "La descarga falló. Vuelve a intentarlo en un momento.",
        damaged: "La descarga está dañada. No se cambió nada; vuelve a intentarlo.",
        untrusted: "Esta descarga no está firmada como tu copia, así que no se instaló.",
        cannotReplace: "La app no puede reemplazarse donde está. Muévela a la carpeta Aplicaciones o descarga la nueva versión desde su página.",
        localBuild: "Esta copia se compiló en este Mac: no se actualiza sola."
    )

    static let sk = ForkUpdateStrings(
        section: "Aktualizácie",
        caption: "Táto neoficiálna verzia sa aktualizuje zo svojich vlastných vydaní, nikdy z oficiálnej aplikácie. Aktualizácia sa nainštaluje, len ak je podpísaná rovnako ako táto kópia, takže povolenie Prístupnosti zostane udelené.",
        currentBuild: "Nainštalovaná zostava",
        basedOn: "Založené na Vorssaint",
        unknownBuild: "neznáma",
        check: "Vyhľadať aktualizácie",
        checking: "Vyhľadáva sa…",
        upToDate: "Toto je najnovšia verzia.",
        availableTitle: "Je dostupná nová verzia",
        availableBody: "Aplikácia sa ukončí, aktualizuje a o pár sekúnd sa znova otvorí.",
        install: "Inštalovať",
        later: "Neskôr",
        downloading: "Sťahuje sa…",
        installing: "Inštaluje sa, aplikácia sa znova otvorí…",
        openReleasesPage: "Otvoriť stránku na stiahnutie",
        checkFailed: "Aktualizácie sa nepodarilo vyhľadať. Skontrolujte pripojenie a skúste to znova.",
        downloadFailed: "Sťahovanie zlyhalo. Skúste to o chvíľu znova.",
        damaged: "Stiahnutý súbor je poškodený. Nič sa nezmenilo; skúste to znova.",
        untrusted: "Toto stiahnutie nie je podpísané ako vaša kópia, preto sa nenainštalovalo.",
        cannotReplace: "Aplikácia sa nemôže nahradiť na mieste, kde je. Presuňte ju do priečinka Aplikácie alebo si stiahnite novú verziu z jej stránky.",
        localBuild: "Táto kópia bola zostavená na tomto Macu: sama sa neaktualizuje."
    )

    static let de = ForkUpdateStrings(
        section: "Updates",
        caption: "Diese inoffizielle Version aktualisiert sich über ihre eigenen Veröffentlichungen, nie über die offizielle App. Ein Update wird nur installiert, wenn es wie diese Kopie signiert ist – so bleibt die Bedienungshilfen-Berechtigung erhalten.",
        currentBuild: "Installierter Build",
        basedOn: "Basiert auf Vorssaint",
        unknownBuild: "unbekannt",
        check: "Nach Updates suchen",
        checking: "Suche…",
        upToDate: "Das ist die neueste Version.",
        availableTitle: "Eine neue Version ist verfügbar",
        availableBody: "Die App wird beendet, aktualisiert sich und öffnet sich in wenigen Sekunden wieder.",
        install: "Installieren",
        later: "Später",
        downloading: "Wird geladen…",
        installing: "Wird installiert, die App öffnet sich wieder…",
        openReleasesPage: "Downloadseite öffnen",
        checkFailed: "Es konnte nicht nach Updates gesucht werden. Prüfe die Verbindung und versuche es erneut.",
        downloadFailed: "Der Download ist fehlgeschlagen. Versuche es gleich noch einmal.",
        damaged: "Der Download ist beschädigt. Es wurde nichts geändert; versuche es erneut.",
        untrusted: "Dieser Download ist nicht wie deine Kopie signiert und wurde deshalb nicht installiert.",
        cannotReplace: "Die App kann sich an ihrem Ort nicht ersetzen. Verschiebe sie in den Ordner „Programme“ oder lade die neue Version von ihrer Seite.",
        localBuild: "Diese Kopie wurde auf diesem Mac gebaut: Sie aktualisiert sich nicht selbst."
    )

    static let fr = ForkUpdateStrings(
        section: "Mises à jour",
        caption: "Cette version non officielle se met à jour depuis ses propres publications, jamais depuis l’app officielle. Une mise à jour ne s’installe que si elle est signée comme cette copie, donc l’autorisation Accessibilité reste accordée.",
        currentBuild: "Version installée",
        basedOn: "Basée sur Vorssaint",
        unknownBuild: "inconnue",
        check: "Rechercher les mises à jour",
        checking: "Recherche…",
        upToDate: "C’est la dernière version.",
        availableTitle: "Une nouvelle version est disponible",
        availableBody: "L’app va se fermer, se mettre à jour et se rouvrir en quelques secondes.",
        install: "Installer",
        later: "Plus tard",
        downloading: "Téléchargement…",
        installing: "Installation, l’app va se rouvrir…",
        openReleasesPage: "Ouvrir la page des téléchargements",
        checkFailed: "Impossible de rechercher les mises à jour. Vérifiez la connexion et réessayez.",
        downloadFailed: "Le téléchargement a échoué. Réessayez dans un instant.",
        damaged: "Le téléchargement est abîmé. Rien n’a été modifié, réessayez.",
        untrusted: "Ce téléchargement n’est pas signé comme votre copie, il n’a donc pas été installé.",
        cannotReplace: "L’app ne peut pas se remplacer là où elle est. Placez-la dans le dossier Applications, ou téléchargez la nouvelle version depuis sa page.",
        localBuild: "Cette copie a été compilée sur ce Mac : elle ne se met pas à jour toute seule."
    )

    static let it = ForkUpdateStrings(
        section: "Aggiornamenti",
        caption: "Questa versione non ufficiale si aggiorna dalle proprie pubblicazioni, mai dall’app ufficiale. Un aggiornamento si installa solo se è firmato come questa copia, così il permesso di Accessibilità resta concesso.",
        currentBuild: "Build installata",
        basedOn: "Basata su Vorssaint",
        unknownBuild: "sconosciuta",
        check: "Cerca aggiornamenti",
        checking: "Ricerca…",
        upToDate: "Questa è la versione più recente.",
        availableTitle: "È disponibile una nuova versione",
        availableBody: "L’app si chiuderà, si aggiornerà e si riaprirà in pochi secondi.",
        install: "Installa",
        later: "Più tardi",
        downloading: "Download in corso…",
        installing: "Installazione, l’app si riaprirà…",
        openReleasesPage: "Apri la pagina dei download",
        checkFailed: "Impossibile cercare aggiornamenti. Controlla la connessione e riprova.",
        downloadFailed: "Il download non è riuscito. Riprova tra poco.",
        damaged: "Il download è danneggiato. Non è stato cambiato nulla; riprova.",
        untrusted: "Questo download non è firmato come la tua copia, quindi non è stato installato.",
        cannotReplace: "L’app non può sostituirsi dove si trova. Spostala nella cartella Applicazioni o scarica la nuova versione dalla sua pagina.",
        localBuild: "Questa copia è stata compilata su questo Mac: non si aggiorna da sola."
    )

    static let ja = ForkUpdateStrings(
        section: "アップデート",
        caption: "この非公式版は独自のリリースからアップデートされ、公式アプリからは決してアップデートされません。アップデートはこのコピーと同じ署名がある場合にのみインストールされるため、アクセシビリティの許可はそのまま保たれます。",
        currentBuild: "インストール済みのビルド",
        basedOn: "ベースの Vorssaint",
        unknownBuild: "不明",
        check: "アップデートを確認",
        checking: "確認中…",
        upToDate: "最新バージョンです。",
        availableTitle: "新しいバージョンがあります",
        availableBody: "アプリは終了してアップデートし、数秒後に再び開きます。",
        install: "インストール",
        later: "あとで",
        downloading: "ダウンロード中…",
        installing: "インストール中です。アプリは再び開きます…",
        openReleasesPage: "ダウンロードページを開く",
        checkFailed: "アップデートを確認できませんでした。接続を確認してもう一度お試しください。",
        downloadFailed: "ダウンロードに失敗しました。少し待ってからもう一度お試しください。",
        damaged: "ダウンロードしたファイルが壊れています。何も変更されていません。もう一度お試しください。",
        untrusted: "このダウンロードはお使いのコピーと同じ署名ではないため、インストールされませんでした。",
        cannotReplace: "アプリは今の場所で自身を置き換えられません。「アプリケーション」フォルダに移動するか、新しいバージョンをそのページからダウンロードしてください。",
        localBuild: "このコピーはこの Mac でビルドされたため、自動ではアップデートされません。"
    )

    static let ko = ForkUpdateStrings(
        section: "업데이트",
        caption: "이 비공식 버전은 자체 릴리스에서 업데이트되며 공식 앱에서는 절대 업데이트되지 않습니다. 업데이트는 이 사본과 같은 서명이 있을 때만 설치되므로 손쉬운 사용 권한이 그대로 유지됩니다.",
        currentBuild: "설치된 빌드",
        basedOn: "기반 Vorssaint",
        unknownBuild: "알 수 없음",
        check: "업데이트 확인",
        checking: "확인 중…",
        upToDate: "최신 버전입니다.",
        availableTitle: "새 버전이 있습니다",
        availableBody: "앱이 종료된 후 업데이트하고 몇 초 뒤에 다시 열립니다.",
        install: "설치",
        later: "나중에",
        downloading: "다운로드 중…",
        installing: "설치 중입니다. 앱이 다시 열립니다…",
        openReleasesPage: "다운로드 페이지 열기",
        checkFailed: "업데이트를 확인할 수 없습니다. 연결을 확인하고 다시 시도하세요.",
        downloadFailed: "다운로드에 실패했습니다. 잠시 후 다시 시도하세요.",
        damaged: "다운로드한 파일이 손상되었습니다. 아무것도 바뀌지 않았으니 다시 시도하세요.",
        untrusted: "이 다운로드는 사용 중인 사본과 같은 서명이 아니어서 설치되지 않았습니다.",
        cannotReplace: "앱이 현재 위치에서 자신을 교체할 수 없습니다. 응용 프로그램 폴더로 옮기거나 새 버전을 해당 페이지에서 다운로드하세요.",
        localBuild: "이 사본은 이 Mac에서 빌드되어 스스로 업데이트되지 않습니다."
    )

    static let uk = ForkUpdateStrings(
        section: "Оновлення",
        caption: "Ця неофіційна версія оновлюється з власних випусків і ніколи — з офіційного застосунку. Оновлення встановлюється, лише якщо воно підписане так само, як ця копія, тож дозвіл Універсального доступу зберігається.",
        currentBuild: "Встановлена збірка",
        basedOn: "На основі Vorssaint",
        unknownBuild: "невідомо",
        check: "Перевірити оновлення",
        checking: "Перевірка…",
        upToDate: "Це остання версія.",
        availableTitle: "Доступна нова версія",
        availableBody: "Застосунок закриється, оновиться і знову відкриється за кілька секунд.",
        install: "Встановити",
        later: "Пізніше",
        downloading: "Завантаження…",
        installing: "Встановлення, застосунок знову відкриється…",
        openReleasesPage: "Відкрити сторінку завантажень",
        checkFailed: "Не вдалося перевірити оновлення. Перевірте з’єднання і спробуйте ще раз.",
        downloadFailed: "Не вдалося завантажити. Спробуйте ще раз за мить.",
        damaged: "Завантажений файл пошкоджено. Нічого не змінено; спробуйте ще раз.",
        untrusted: "Це завантаження підписане не так, як ваша копія, тому його не встановлено.",
        cannotReplace: "Застосунок не може замінити себе в цьому місці. Перемістіть його в папку «Програми» або завантажте нову версію з її сторінки.",
        localBuild: "Цю копію зібрано на цьому Mac: вона не оновлюється сама."
    )

    static let zhHans = ForkUpdateStrings(
        section: "更新",
        caption: "这个非官方版本通过自己的发布版本更新，从不通过官方 App 更新。只有与此副本签名相同的更新才会安装，因此辅助功能权限会保持授予状态。",
        currentBuild: "已安装的版本号",
        basedOn: "基于 Vorssaint",
        unknownBuild: "未知",
        check: "检查更新",
        checking: "正在检查…",
        upToDate: "这是最新版本。",
        availableTitle: "有新版本可用",
        availableBody: "App 将退出、完成更新，并在几秒后重新打开。",
        install: "安装",
        later: "稍后",
        downloading: "正在下载…",
        installing: "正在安装，App 将重新打开…",
        openReleasesPage: "打开下载页面",
        checkFailed: "无法检查更新。请检查网络连接后重试。",
        downloadFailed: "下载失败。请稍后重试。",
        damaged: "下载的文件已损坏。未做任何更改，请重试。",
        untrusted: "此下载与你的副本签名不同，因此没有安装。",
        cannotReplace: "App 无法在当前位置替换自身。请将它移到“应用程序”文件夹，或从页面下载新版本。",
        localBuild: "这个副本是在这台 Mac 上构建的：它不会自动更新。"
    )

    static let zhTW = ForkUpdateStrings(
        section: "更新",
        caption: "這個非官方版本會從自己的發行版本更新，絕不從官方 App 更新。只有與此副本簽署相同的更新才會安裝，因此輔助使用權限會維持授予狀態。",
        currentBuild: "已安裝的版本號",
        basedOn: "基於 Vorssaint",
        unknownBuild: "未知",
        check: "檢查更新",
        checking: "正在檢查…",
        upToDate: "這是最新版本。",
        availableTitle: "有新版本可用",
        availableBody: "App 將結束、完成更新，並在幾秒後重新打開。",
        install: "安裝",
        later: "稍後",
        downloading: "正在下載…",
        installing: "正在安裝，App 將重新打開…",
        openReleasesPage: "打開下載頁面",
        checkFailed: "無法檢查更新。請檢查網路連線後再試一次。",
        downloadFailed: "下載失敗。請稍後再試一次。",
        damaged: "下載的檔案已損毀。未做任何更改，請再試一次。",
        untrusted: "此下載與你的副本簽署不同，因此沒有安裝。",
        cannotReplace: "App 無法在目前位置取代自己。請將它移到「應用程式」檔案夾，或從頁面下載新版本。",
        localBuild: "這個副本是在這台 Mac 上建置的：它不會自動更新。"
    )

    static let zhHK = ForkUpdateStrings(
        section: "更新",
        caption: "這個非官方版本會從自己的發佈版本更新，絕不從官方 App 更新。只有與此副本簽署相同的更新才會安裝，因此輔助使用權限會保持授予狀態。",
        currentBuild: "已安裝的版本號",
        basedOn: "基於 Vorssaint",
        unknownBuild: "未知",
        check: "檢查更新",
        checking: "正在檢查…",
        upToDate: "這是最新版本。",
        availableTitle: "有新版本可用",
        availableBody: "App 會結束、完成更新，並在幾秒後重新打開。",
        install: "安裝",
        later: "稍後",
        downloading: "正在下載…",
        installing: "正在安裝，App 會重新打開…",
        openReleasesPage: "打開下載頁面",
        checkFailed: "無法檢查更新。請檢查網絡連線後再試。",
        downloadFailed: "下載失敗。請稍後再試。",
        damaged: "下載的檔案已損壞。未有作任何更改，請再試。",
        untrusted: "此下載與你的副本簽署不同，因此沒有安裝。",
        cannotReplace: "App 無法在目前位置取代自己。請將它移到「應用程式」檔案夾，或從頁面下載新版本。",
        localBuild: "這個副本是在這部 Mac 上建置的：它不會自動更新。"
    )
}
