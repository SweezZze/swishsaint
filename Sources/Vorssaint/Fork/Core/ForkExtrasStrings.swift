// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// Strings for the Extras page, the fork's own page of the Settings. Same
/// contract as the FeatureStrings structs: memberwise init in declaration
/// order, one static per language.
struct ForkExtrasStrings {
    let pageTitle: String
    let intro: String
    let featuresSection: String
    let gesturesTitle: String
    let gesturesSummary: String
    let claudeUsageTitle: String
    let claudeUsageSummary: String
    let claudeUsageStatusFormat: String
    let claudeUsageWaiting: String
    let dictationTitle: String
    let dictationSummary: String
    let sharedSettings: String
    let aboutSection: String
    let aboutBody: String
    let sourceCode: String
    let officialProject: String

    func claudeUsageStatus(_ when: String) -> String { String(format: claudeUsageStatusFormat, when) }

    static func strings(_ language: AppLanguage) -> ForkExtrasStrings {
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

extension ForkExtrasStrings {
    static let enUS = ForkExtrasStrings(
        pageTitle: "Extras",
        intro: "Features added by this unofficial version of Vorssaint. Each one has its own switch and stops completely when it is off.",
        featuresSection: "Features",
        gesturesTitle: "Trackpad gestures",
        gesturesSummary: "Two fingers on a title bar to place, close or center a window, and on the Dock to quit an app or empty the Trash.",
        claudeUsageTitle: "Claude limits through Claude Code",
        claudeUsageSummary: "The Dynamic Island’s Agents section shows your plan’s session and week as your account counts them, read by Claude Code every five minutes, without the Claude app. The check costs nothing.",
        claudeUsageStatusFormat: "Read from your account by Claude Code, updated %@",
        claudeUsageWaiting: "Waiting for Claude Code’s first answer. It needs to be installed and signed in with a plan.",
        dictationTitle: "Dictation",
        dictationSummary: "Hold a key of your choice, speak, let go: the text is written in any app, where the cursor is. Uses Apple’s speech recognition, at no cost.",
        sharedSettings: "The gestures pause in the ignored apps and use the gaps set on this page:",
        aboutSection: "About this version",
        aboutBody: "This version follows the official Vorssaint automatically and adds a few features made by friends. It is neither signed by Apple nor made by the Vorssaint team: all credit for the app goes to Vorssaint.",
        sourceCode: "Source code",
        officialProject: "Official Vorssaint"
    )

    static let ptBR = ForkExtrasStrings(
        pageTitle: "Extras",
        intro: "Recursos adicionados por esta versão não oficial do Vorssaint. Cada um tem seu próprio botão e para por completo quando está desligado.",
        featuresSection: "Recursos",
        gesturesTitle: "Gestos do trackpad",
        gesturesSummary: "Dois dedos na barra de título para posicionar, fechar ou centralizar uma janela, e no Dock para encerrar um app ou esvaziar o Lixo.",
        claudeUsageTitle: "Limites do Claude via Claude Code",
        claudeUsageSummary: "A seção Agentes do Dynamic Island mostra a sessão e a semana do seu plano como a sua conta as conta, lidas pelo Claude Code a cada cinco minutos, sem o app Claude. A verificação não custa nada.",
        claudeUsageStatusFormat: "Lidos da sua conta pelo Claude Code, atualizados %@",
        claudeUsageWaiting: "Aguardando a primeira resposta do Claude Code. Ele precisa estar instalado e conectado a um plano.",
        dictationTitle: "Ditado",
        dictationSummary: "Segure uma tecla à sua escolha, fale e solte: o texto é escrito em qualquer app, onde está o cursor. Usa o reconhecimento de fala da Apple, sem custo.",
        sharedSettings: "Os gestos pausam nos apps ignorados e usam os espaçamentos definidos nesta página:",
        aboutSection: "Sobre esta versão",
        aboutBody: "Esta versão acompanha o Vorssaint oficial automaticamente e adiciona alguns recursos feitos por amigos. Ela não é assinada pela Apple nem feita pela equipe do Vorssaint: todo o crédito do app é do Vorssaint.",
        sourceCode: "Código-fonte",
        officialProject: "Vorssaint oficial"
    )

    static let tr = ForkExtrasStrings(
        pageTitle: "Ekstralar",
        intro: "Vorssaint'in bu resmî olmayan sürümünün eklediği özellikler. Her birinin kendi anahtarı vardır ve kapalıyken tamamen durur.",
        featuresSection: "Özellikler",
        gesturesTitle: "İzleme dörtgeni hareketleri",
        gesturesSummary: "Bir pencereyi yerleştirmek, kapatmak ya da ortalamak için başlık çubuğunda, bir uygulamadan çıkmak ya da Çöp Sepeti'ni boşaltmak için Dock'ta iki parmak.",
        claudeUsageTitle: "Claude Code ile Claude sınırları",
        claudeUsageSummary: "Dynamic Island’ın Ajanlar bölümü, planınızın oturumunu ve haftasını hesabınızın saydığı gibi gösterir; Claude Code bunları beş dakikada bir, Claude uygulaması olmadan okur. Kontrol hiçbir şeye mal olmaz.",
        claudeUsageStatusFormat: "Claude Code ile hesabınızdan okundu, %@ güncellendi",
        claudeUsageWaiting: "Claude Code’un ilk yanıtı bekleniyor. Yüklü ve bir plana giriş yapmış olması gerekir.",
        dictationTitle: "Dikte",
        dictationSummary: "Seçtiğiniz bir tuşu basılı tutun, konuşun, bırakın: metin her uygulamada imlecin olduğu yere yazılır. Apple’ın konuşma tanımasını ücretsiz kullanır.",
        sharedSettings: "Hareketler yok sayılan uygulamalarda duraklar ve bu sayfada ayarlanan boşlukları kullanır:",
        aboutSection: "Bu sürüm hakkında",
        aboutBody: "Bu sürüm resmî Vorssaint'i kendiliğinden izler ve arkadaşların yaptığı birkaç özellik ekler. Apple tarafından imzalanmamıştır ve Vorssaint ekibi tarafından yapılmamıştır: uygulamanın tüm emeği Vorssaint'e aittir.",
        sourceCode: "Kaynak kodu",
        officialProject: "Resmî Vorssaint"
    )

    static let ru = ForkExtrasStrings(
        pageTitle: "Дополнения",
        intro: "Функции, добавленные этой неофициальной версией Vorssaint. У каждой свой переключатель, и выключенная она полностью останавливается.",
        featuresSection: "Функции",
        gesturesTitle: "Жесты трекпада",
        gesturesSummary: "Два пальца на строке заголовка, чтобы разместить, закрыть или отцентрировать окно, и на Dock, чтобы завершить приложение или очистить Корзину.",
        claudeUsageTitle: "Лимиты Claude через Claude Code",
        claudeUsageSummary: "Раздел «Агенты» в Dynamic Island показывает сессию и неделю вашего тарифа так, как их считает аккаунт: Claude Code читает их каждые пять минут, без приложения Claude. Проверка ничего не стоит.",
        claudeUsageStatusFormat: "Из вашего аккаунта через Claude Code, обновлено %@",
        claudeUsageWaiting: "Ожидание первого ответа Claude Code. Он должен быть установлен и подключён к тарифу.",
        dictationTitle: "Диктовка",
        dictationSummary: "Удерживайте выбранную клавишу, говорите, отпустите: текст появится в любом приложении, там, где курсор. Использует распознавание речи Apple, бесплатно.",
        sharedSettings: "Жесты приостанавливаются в игнорируемых приложениях и используют отступы, заданные на этой странице:",
        aboutSection: "Об этой версии",
        aboutBody: "Эта версия автоматически следует за официальным Vorssaint и добавляет несколько функций, сделанных друзьями. Она не подписана Apple и не создана командой Vorssaint: все заслуги за приложение принадлежат Vorssaint.",
        sourceCode: "Исходный код",
        officialProject: "Официальный Vorssaint"
    )

    static let es = ForkExtrasStrings(
        pageTitle: "Extras",
        intro: "Funciones añadidas por esta versión no oficial de Vorssaint. Cada una tiene su propio interruptor y se detiene por completo cuando está desactivada.",
        featuresSection: "Funciones",
        gesturesTitle: "Gestos del trackpad",
        gesturesSummary: "Dos dedos en la barra de título para colocar, cerrar o centrar una ventana, y en el Dock para salir de una app o vaciar la Papelera.",
        claudeUsageTitle: "Límites de Claude con Claude Code",
        claudeUsageSummary: "La sección Agentes del Dynamic Island muestra la sesión y la semana de tu plan tal como las cuenta tu cuenta, leídas por Claude Code cada cinco minutos, sin la app de Claude. La comprobación no cuesta nada.",
        claudeUsageStatusFormat: "Leídos de tu cuenta por Claude Code, actualizados %@",
        claudeUsageWaiting: "Esperando la primera respuesta de Claude Code. Debe estar instalado y con sesión iniciada en un plan.",
        dictationTitle: "Dictado",
        dictationSummary: "Mantén la tecla que elijas, habla y suéltala: el texto se escribe en cualquier app, donde está el cursor. Usa el reconocimiento de voz de Apple, sin coste.",
        sharedSettings: "Los gestos se pausan en las apps ignoradas y usan los márgenes definidos en esta página:",
        aboutSection: "Acerca de esta versión",
        aboutBody: "Esta versión sigue al Vorssaint oficial automáticamente y añade algunas funciones hechas por amigos. No está firmada por Apple ni la hace el equipo de Vorssaint: todo el mérito de la app es de Vorssaint.",
        sourceCode: "Código fuente",
        officialProject: "Vorssaint oficial"
    )

    static let sk = ForkExtrasStrings(
        pageTitle: "Doplnky",
        intro: "Funkcie pridané touto neoficiálnou verziou Vorssaint. Každá má vlastný prepínač a po vypnutí sa úplne zastaví.",
        featuresSection: "Funkcie",
        gesturesTitle: "Gestá trackpadu",
        gesturesSummary: "Dva prsty na titulkovom pruhu na umiestnenie, zatvorenie alebo vycentrovanie okna a na Docku na ukončenie aplikácie alebo vyprázdnenie Koša.",
        claudeUsageTitle: "Limity Claude cez Claude Code",
        claudeUsageSummary: "Sekcia Agenti v Dynamic Island zobrazuje reláciu a týždeň vášho plánu tak, ako ich počíta váš účet. Claude Code ich načíta každých päť minút, bez aplikácie Claude. Kontrola nič nestojí.",
        claudeUsageStatusFormat: "Načítané z vášho účtu cez Claude Code, aktualizované %@",
        claudeUsageWaiting: "Čaká sa na prvú odpoveď Claude Code. Musí byť nainštalovaný a prihlásený k plánu.",
        dictationTitle: "Diktovanie",
        dictationSummary: "Podržte zvolený kláves, hovorte, pustite: text sa napíše v ľubovoľnej apke tam, kde je kurzor. Používa rozpoznávanie reči od Apple, zadarmo.",
        sharedSettings: "Gestá sa pozastavia v ignorovaných aplikáciách a používajú medzery nastavené na tejto stránke:",
        aboutSection: "O tejto verzii",
        aboutBody: "Táto verzia automaticky sleduje oficiálny Vorssaint a pridáva niekoľko funkcií od priateľov. Nie je podpísaná spoločnosťou Apple ani vytvorená tímom Vorssaint: všetka zásluha za aplikáciu patrí Vorssaint.",
        sourceCode: "Zdrojový kód",
        officialProject: "Oficiálny Vorssaint"
    )

    static let de = ForkExtrasStrings(
        pageTitle: "Extras",
        intro: "Funktionen, die diese inoffizielle Version von Vorssaint hinzufügt. Jede hat ihren eigenen Schalter und hält ausgeschaltet vollständig an.",
        featuresSection: "Funktionen",
        gesturesTitle: "Trackpad-Gesten",
        gesturesSummary: "Zwei Finger auf der Titelleiste, um ein Fenster anzuordnen, zu schließen oder zu zentrieren, und im Dock, um eine App zu beenden oder den Papierkorb zu leeren.",
        claudeUsageTitle: "Claude-Limits über Claude Code",
        claudeUsageSummary: "Der Bereich Agenten der Dynamic Island zeigt Sitzung und Woche deines Abos so, wie dein Konto sie zählt, alle fünf Minuten von Claude Code gelesen, ohne die Claude-App. Die Abfrage kostet nichts.",
        claudeUsageStatusFormat: "Von Claude Code aus deinem Konto gelesen, aktualisiert %@",
        claudeUsageWaiting: "Warte auf die erste Antwort von Claude Code. Es muss installiert und mit einem Abo angemeldet sein.",
        dictationTitle: "Diktieren",
        dictationSummary: "Eine Taste deiner Wahl halten, sprechen, loslassen: Der Text erscheint in jeder App dort, wo der Cursor steht. Nutzt Apples Spracherkennung, kostenlos.",
        sharedSettings: "Die Gesten pausieren in den ignorierten Apps und nutzen die auf dieser Seite eingestellten Abstände:",
        aboutSection: "Über diese Version",
        aboutBody: "Diese Version folgt dem offiziellen Vorssaint automatisch und fügt einige von Freunden gebaute Funktionen hinzu. Sie ist weder von Apple signiert noch vom Vorssaint-Team: Alle Anerkennung für die App gebührt Vorssaint.",
        sourceCode: "Quellcode",
        officialProject: "Offizielles Vorssaint"
    )

    static let fr = ForkExtrasStrings(
        pageTitle: "Extras",
        intro: "Les fonctions ajoutées par cette version non officielle de Vorssaint. Chacune a son interrupteur et s’arrête complètement quand elle est coupée.",
        featuresSection: "Fonctions",
        gesturesTitle: "Gestes du trackpad",
        gesturesSummary: "Deux doigts sur une barre de titre pour ranger, fermer ou centrer une fenêtre, et sur le Dock pour quitter une app ou vider la Corbeille.",
        claudeUsageTitle: "Limites Claude via Claude Code",
        claudeUsageSummary: "La section Agents du Dynamic Island affiche la session et la semaine de votre forfait telles que votre compte les compte, lues par Claude Code toutes les cinq minutes, sans l’app Claude. La vérification ne coûte rien.",
        claudeUsageStatusFormat: "Lues sur votre compte par Claude Code, mises à jour %@",
        claudeUsageWaiting: "En attente de la première réponse de Claude Code. Il doit être installé et connecté à un forfait.",
        dictationTitle: "Dictée vocale",
        dictationSummary: "Maintenez la touche de votre choix, parlez, relâchez : le texte s’écrit dans n’importe quelle app, là où se trouve le curseur. Utilise la reconnaissance vocale d’Apple, gratuitement.",
        sharedSettings: "Les gestes se mettent en pause dans les apps ignorées et utilisent les espacements réglés sur cette page :",
        aboutSection: "À propos de cette version",
        aboutBody: "Cette version suit le Vorssaint officiel automatiquement et ajoute quelques fonctions faites entre amis. Elle n’est ni signée par Apple ni faite par l’équipe de Vorssaint : tout le mérite de l’app revient à Vorssaint.",
        sourceCode: "Code source",
        officialProject: "Vorssaint officiel"
    )

    static let it = ForkExtrasStrings(
        pageTitle: "Extra",
        intro: "Le funzioni aggiunte da questa versione non ufficiale di Vorssaint. Ognuna ha il suo interruttore e si ferma del tutto quando è spenta.",
        featuresSection: "Funzioni",
        gesturesTitle: "Gesti del trackpad",
        gesturesSummary: "Due dita sulla barra del titolo per sistemare, chiudere o centrare una finestra, e sul Dock per uscire da un’app o svuotare il Cestino.",
        claudeUsageTitle: "Limiti di Claude tramite Claude Code",
        claudeUsageSummary: "La sezione Agenti del Dynamic Island mostra la sessione e la settimana del tuo piano come le conta il tuo account, lette da Claude Code ogni cinque minuti, senza l’app Claude. Il controllo non costa nulla.",
        claudeUsageStatusFormat: "Letti dal tuo account tramite Claude Code, aggiornati %@",
        claudeUsageWaiting: "In attesa della prima risposta di Claude Code. Deve essere installato e connesso a un piano.",
        dictationTitle: "Dettatura",
        dictationSummary: "Tieni premuto un tasto a tua scelta, parla, rilascia: il testo viene scritto in qualsiasi app, dove si trova il cursore. Usa il riconoscimento vocale di Apple, gratis.",
        sharedSettings: "I gesti si mettono in pausa nelle app ignorate e usano gli spazi impostati in questa pagina:",
        aboutSection: "Informazioni su questa versione",
        aboutBody: "Questa versione segue automaticamente il Vorssaint ufficiale e aggiunge alcune funzioni fatte da amici. Non è firmata da Apple né realizzata dal team di Vorssaint: tutto il merito dell’app va a Vorssaint.",
        sourceCode: "Codice sorgente",
        officialProject: "Vorssaint ufficiale"
    )

    static let ja = ForkExtrasStrings(
        pageTitle: "エクストラ",
        intro: "この Vorssaint 非公式版が追加した機能です。それぞれに専用のスイッチがあり、オフにすると完全に停止します。",
        featuresSection: "機能",
        gesturesTitle: "トラックパッドジェスチャ",
        gesturesSummary: "タイトルバー上の2本指でウインドウを配置・閉じる・中央に移動し、Dock 上でアプリを終了したりゴミ箱を空にしたりします。",
        claudeUsageTitle: "Claude Code で Claude の上限を表示",
        claudeUsageSummary: "Dynamic Island のエージェントセクションに、アカウントが数えるプランのセッションと週の使用量を表示します。Claude Code が5分ごとに読み取り、Claude アプリは不要です。確認に費用はかかりません。",
        claudeUsageStatusFormat: "Claude Codeでアカウントから取得（最終更新：%@）",
        claudeUsageWaiting: "Claude Code の最初の応答を待っています。インストールしてプランにサインインしている必要があります。",
        dictationTitle: "音声入力",
        dictationSummary: "好きなキーを押したまま話して離すと、どのアプリでもカーソルの位置に文字が入力されます。Appleの音声認識を無料で使います。",
        sharedSettings: "ジェスチャは無視するアプリでは一時停止し、このページで設定した間隔を使います:",
        aboutSection: "このバージョンについて",
        aboutBody: "このバージョンは公式の Vorssaint に自動で追従し、友人たちが作った機能をいくつか追加しています。Apple による署名はなく、Vorssaint チームが作ったものでもありません。アプリの功績はすべて Vorssaint にあります。",
        sourceCode: "ソースコード",
        officialProject: "公式 Vorssaint"
    )

    static let ko = ForkExtrasStrings(
        pageTitle: "추가 기능",
        intro: "이 Vorssaint 비공식 버전이 추가한 기능입니다. 각각 자체 스위치가 있으며 끄면 완전히 멈춥니다.",
        featuresSection: "기능",
        gesturesTitle: "트랙패드 제스처",
        gesturesSummary: "제목 막대에서 두 손가락으로 윈도우를 배치·닫기·가운데 정렬하고, Dock에서 앱을 종료하거나 휴지통을 비웁니다.",
        claudeUsageTitle: "Claude Code로 Claude 한도 보기",
        claudeUsageSummary: "Dynamic Island의 에이전트 섹션에 계정이 집계하는 플랜의 세션과 주간 사용량을 표시합니다. Claude Code가 5분마다 읽으며 Claude 앱은 필요 없습니다. 확인에는 비용이 들지 않습니다.",
        claudeUsageStatusFormat: "Claude Code로 계정에서 읽음, %@ 업데이트됨",
        claudeUsageWaiting: "Claude Code의 첫 응답을 기다리는 중입니다. 설치되어 있고 플랜으로 로그인되어 있어야 합니다.",
        dictationTitle: "받아쓰기",
        dictationSummary: "원하는 키를 누른 채 말하고 떼면, 어느 앱에서든 커서 위치에 텍스트가 입력됩니다. Apple 음성 인식을 무료로 사용합니다.",
        sharedSettings: "제스처는 무시하는 앱에서 일시 정지되며 이 페이지에서 설정한 간격을 사용합니다:",
        aboutSection: "이 버전에 관하여",
        aboutBody: "이 버전은 공식 Vorssaint를 자동으로 따라가며 친구들이 만든 몇 가지 기능을 더합니다. Apple의 서명도 없고 Vorssaint 팀이 만든 것도 아닙니다. 앱의 모든 공로는 Vorssaint에 있습니다.",
        sourceCode: "소스 코드",
        officialProject: "공식 Vorssaint"
    )

    static let uk = ForkExtrasStrings(
        pageTitle: "Додатки",
        intro: "Функції, додані цією неофіційною версією Vorssaint. Кожна має власний перемикач і вимкнена повністю зупиняється.",
        featuresSection: "Функції",
        gesturesTitle: "Жести трекпада",
        gesturesSummary: "Два пальці на рядку заголовка, щоб розмістити, закрити або вирівняти вікно по центру, і на Dock, щоб завершити застосунок або очистити Кошик.",
        claudeUsageTitle: "Ліміти Claude через Claude Code",
        claudeUsageSummary: "Розділ «Агенти» в Dynamic Island показує сесію й тиждень вашого тарифу так, як їх рахує обліковий запис: Claude Code читає їх кожні п’ять хвилин, без програми Claude. Перевірка нічого не коштує.",
        claudeUsageStatusFormat: "Прочитано з вашого облікового запису через Claude Code, оновлено %@",
        claudeUsageWaiting: "Очікування першої відповіді Claude Code. Він має бути встановлений і підключений до тарифу.",
        dictationTitle: "Диктування",
        dictationSummary: "Утримуйте вибрану клавішу, говоріть, відпустіть: текст з’явиться в будь-якій програмі, там, де курсор. Використовує розпізнавання мовлення Apple, безкоштовно.",
        sharedSettings: "Жести призупиняються в ігнорованих застосунках і використовують відступи, задані на цій сторінці:",
        aboutSection: "Про цю версію",
        aboutBody: "Ця версія автоматично стежить за офіційним Vorssaint і додає кілька функцій, зроблених друзями. Вона не підписана Apple і не створена командою Vorssaint: уся заслуга за застосунок належить Vorssaint.",
        sourceCode: "Вихідний код",
        officialProject: "Офіційний Vorssaint"
    )

    static let zhHans = ForkExtrasStrings(
        pageTitle: "附加功能",
        intro: "这个 Vorssaint 非官方版本添加的功能。每个功能都有自己的开关，关闭后会完全停止。",
        featuresSection: "功能",
        gesturesTitle: "触控板手势",
        gesturesSummary: "在标题栏上用两指放置、关闭或居中窗口，在程序坞上用两指退出 App 或清倒废纸篓。",
        claudeUsageTitle: "通过 Claude Code 查看 Claude 额度",
        claudeUsageSummary: "Dynamic Island 的智能体部分会按你的账户统计显示套餐的会话和每周用量，由 Claude Code 每五分钟读取一次，无需 Claude App。检查不产生任何费用。",
        claudeUsageStatusFormat: "由 Claude Code 从你的账户读取，上次更新：%@",
        claudeUsageWaiting: "正在等待 Claude Code 的第一次回复。它需要已安装并登录套餐。",
        dictationTitle: "语音听写",
        dictationSummary: "按住你选择的按键说话，松开后文字会写在任何 App 的光标位置。使用 Apple 的语音识别，免费。",
        sharedSettings: "手势会在被忽略的 App 中暂停，并使用此页面设置的间距：",
        aboutSection: "关于此版本",
        aboutBody: "此版本会自动跟随官方 Vorssaint，并添加一些朋友们做的功能。它既没有 Apple 签名，也不是 Vorssaint 团队制作的：这个 App 的全部功劳归于 Vorssaint。",
        sourceCode: "源代码",
        officialProject: "官方 Vorssaint"
    )

    static let zhTW = ForkExtrasStrings(
        pageTitle: "額外功能",
        intro: "這個 Vorssaint 非官方版本加入的功能。每個功能都有自己的開關，關閉後會完全停止。",
        featuresSection: "功能",
        gesturesTitle: "觸控式軌跡板手勢",
        gesturesSummary: "在標題列上用兩指放置、關閉或置中視窗，在 Dock 上用兩指結束 App 或清空垃圾桶。",
        claudeUsageTitle: "透過 Claude Code 查看 Claude 額度",
        claudeUsageSummary: "Dynamic Island 的代理程式區塊會依你的帳號統計顯示方案的工作階段與每週用量，由 Claude Code 每五分鐘讀取一次，不需要 Claude App。檢查不會產生任何費用。",
        claudeUsageStatusFormat: "由 Claude Code 從你的帳號讀取，上次更新：%@",
        claudeUsageWaiting: "正在等待 Claude Code 的第一次回覆。它需要已安裝並登入方案。",
        dictationTitle: "語音聽寫",
        dictationSummary: "按住你選擇的按鍵說話，放開後文字會寫在任何 App 的游標位置。使用 Apple 的語音辨識，免費。",
        sharedSettings: "手勢會在被忽略的 App 中暫停，並使用此頁面設定的間距：",
        aboutSection: "關於此版本",
        aboutBody: "此版本會自動跟隨官方 Vorssaint，並加入幾個朋友做的功能。它沒有 Apple 簽署，也不是 Vorssaint 團隊製作的：這個 App 的所有功勞都屬於 Vorssaint。",
        sourceCode: "原始碼",
        officialProject: "官方 Vorssaint"
    )

    static let zhHK = ForkExtrasStrings(
        pageTitle: "額外功能",
        intro: "這個 Vorssaint 非官方版本加入的功能。每個功能都有自己的開關，關閉後會完全停止。",
        featuresSection: "功能",
        gesturesTitle: "觸控板手勢",
        gesturesSummary: "在標題列上用兩指放置、關閉或置中視窗，在 Dock 上用兩指結束 App 或清空垃圾桶。",
        claudeUsageTitle: "透過 Claude Code 查看 Claude 額度",
        claudeUsageSummary: "Dynamic Island 的代理程式部分會按你的帳戶統計顯示計劃的工作階段及每週用量，由 Claude Code 每五分鐘讀取一次，毋須 Claude App。檢查唔會產生任何費用。",
        claudeUsageStatusFormat: "由 Claude Code 從你的帳戶讀取，上次更新：%@",
        claudeUsageWaiting: "正在等待 Claude Code 的第一次回覆。佢需要已安裝並登入計劃。",
        dictationTitle: "語音聽寫",
        dictationSummary: "按住你揀選的按鍵說話，放開後文字會寫在任何 App 的游標位置。使用 Apple 的語音辨識，免費。",
        sharedSettings: "手勢會在被忽略的 App 中暫停，並使用此頁面設定的間距：",
        aboutSection: "關於此版本",
        aboutBody: "此版本會自動跟隨官方 Vorssaint，並加入幾個朋友做的功能。它沒有 Apple 簽署，也不是 Vorssaint 團隊製作的：這個 App 的所有功勞都歸 Vorssaint。",
        sourceCode: "原始碼",
        officialProject: "官方 Vorssaint"
    )
}
