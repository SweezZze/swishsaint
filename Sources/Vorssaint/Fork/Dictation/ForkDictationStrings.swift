// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation

/// Strings for dictation. Same contract as the FeatureStrings structs:
/// memberwise init in declaration order, one static per language.
struct ForkDictationStrings {
    let triggerTitle: String
    let triggerRightCommand: String
    let triggerRightOption: String
    let triggerRightControl: String
    let triggerRightShift: String
    let triggerFn: String
    let howTo: String
    let fnCaption: String
    let openKeyboardSettings: String
    let languageTitle: String
    let languageAutomaticFormat: String
    let onDevice: String
    let onServer: String
    let soundsTitle: String
    let speechPermissionName: String
    let tryTitle: String
    let tryPlaceholder: String
    let buildCaption: String
    let problemAccessibility: String
    let problemMicrophone: String
    let problemSpeech: String
    let problemBuild: String
    let problemUnavailable: String
    let vocabularyTitle: String
    let vocabularyCaption: String
    let vocabularyPlaceholder: String
    let addButton: String
    let replacementsTitle: String
    let replacementsCaption: String
    let heardPlaceholder: String
    let writtenPlaceholder: String

    func languageAutomatic(_ name: String) -> String { String(format: languageAutomaticFormat, name) }

    func triggerName(_ trigger: ForkDictationTrigger) -> String {
        switch trigger {
        case .rightCommand: return triggerRightCommand
        case .rightOption: return triggerRightOption
        case .rightControl: return triggerRightControl
        case .rightShift: return triggerRightShift
        case .fn: return triggerFn
        }
    }

    static func strings(_ language: AppLanguage) -> ForkDictationStrings {
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

extension ForkDictationStrings {
    static let enUS = ForkDictationStrings(
        triggerTitle: "Key",
        triggerRightCommand: "Right Command",
        triggerRightOption: "Right Option",
        triggerRightControl: "Right Control",
        triggerRightShift: "Right Shift",
        triggerFn: "fn (Globe)",
        howTo: "Hold the key and speak, then let go: the text is written where the cursor is, in any app. A short tap goes hands-free, another press finishes. Escape cancels.",
        fnCaption: "For the fn key, set “Press 🌐 key to” to “Do Nothing” in System Settings › Keyboard, or macOS reacts to it too.",
        openKeyboardSettings: "Keyboard Settings",
        languageTitle: "Language",
        languageAutomaticFormat: "Automatic (%@)",
        onDevice: "Recognized on this Mac: nothing leaves it.",
        onServer: "This language goes through Apple’s dictation servers, like macOS dictation. To keep it on this Mac, add it in System Settings › Keyboard › Dictation.",
        soundsTitle: "Start and end sounds",
        speechPermissionName: "Speech Recognition",
        tryTitle: "Try it",
        tryPlaceholder: "Click here, then dictate",
        buildCaption: "This local build cannot ask for speech recognition. Dictation works in the fork’s published versions.",
        problemAccessibility: "Allow Accessibility first",
        problemMicrophone: "Allow the microphone in Settings",
        problemSpeech: "Allow speech recognition in Settings",
        problemBuild: "This build has no speech recognition",
        problemUnavailable: "Speech recognition unavailable",
        vocabularyTitle: "Vocabulary",
        vocabularyCaption: "Words dictation should know: names, brands, English terms. They are favored when what you say sounds like them.",
        vocabularyPlaceholder: "Add a word or phrase",
        addButton: "Add",
        replacementsTitle: "Replacements",
        replacementsCaption: "When dictation hears the first, it writes the second. For words it keeps getting wrong.",
        heardPlaceholder: "Heard",
        writtenPlaceholder: "Written"
    )

    static let ptBR = ForkDictationStrings(
        triggerTitle: "Tecla",
        triggerRightCommand: "Command direito",
        triggerRightOption: "Option direito",
        triggerRightControl: "Control direito",
        triggerRightShift: "Shift direito",
        triggerFn: "fn (globo)",
        howTo: "Segure a tecla e fale, depois solte: o texto é escrito onde está o cursor, em qualquer app. Um toque curto ativa o modo mãos livres, outro toque termina. Esc cancela.",
        fnCaption: "Para a tecla fn, defina “Pressionar a tecla 🌐 para” como “Não Fazer Nada” em Ajustes do Sistema › Teclado, senão o macOS também reage.",
        openKeyboardSettings: "Ajustes de Teclado",
        languageTitle: "Idioma",
        languageAutomaticFormat: "Automático (%@)",
        onDevice: "Reconhecido neste Mac: nada sai dele.",
        onServer: "Este idioma passa pelos servidores de ditado da Apple, como o ditado do macOS. Para ficar neste Mac, adicione-o em Ajustes do Sistema › Teclado › Ditado.",
        soundsTitle: "Sons de início e fim",
        speechPermissionName: "Reconhecimento de Fala",
        tryTitle: "Teste",
        tryPlaceholder: "Clique aqui e dite",
        buildCaption: "Esta versão local não pode pedir o reconhecimento de fala. O ditado funciona nas versões publicadas do fork.",
        problemAccessibility: "Permita a Acessibilidade primeiro",
        problemMicrophone: "Permita o microfone nos Ajustes",
        problemSpeech: "Permita o reconhecimento de fala",
        problemBuild: "Versão sem reconhecimento de fala",
        problemUnavailable: "Reconhecimento de fala indisponível",
        vocabularyTitle: "Vocabulário",
        vocabularyCaption: "Palavras que o ditado deve conhecer: nomes, marcas, termos em inglês. Elas são favorecidas quando o que você diz se parece com elas.",
        vocabularyPlaceholder: "Adicionar palavra ou expressão",
        addButton: "Adicionar",
        replacementsTitle: "Substituições",
        replacementsCaption: "Quando o ditado ouve a primeira, escreve a segunda. Para palavras que ele continua errando.",
        heardPlaceholder: "Ouvido",
        writtenPlaceholder: "Escrito"
    )

    static let tr = ForkDictationStrings(
        triggerTitle: "Tuş",
        triggerRightCommand: "Sağ Command",
        triggerRightOption: "Sağ Option",
        triggerRightControl: "Sağ Control",
        triggerRightShift: "Sağ Shift",
        triggerFn: "fn (Küre)",
        howTo: "Tuşu basılı tutup konuşun, sonra bırakın: metin her uygulamada imlecin olduğu yere yazılır. Kısa bir dokunuş eller serbest moda geçer, bir sonraki basış bitirir. Escape iptal eder.",
        fnCaption: "fn tuşu için Sistem Ayarları › Klavye bölümünde “🌐 tuşuna basınca” seçeneğini “Hiçbir Şey Yapma” yapın, yoksa macOS da tepki verir.",
        openKeyboardSettings: "Klavye Ayarları",
        languageTitle: "Dil",
        languageAutomaticFormat: "Otomatik (%@)",
        onDevice: "Bu Mac’te tanınır: hiçbir şey dışarı çıkmaz.",
        onServer: "Bu dil, macOS dikte özelliği gibi Apple’ın dikte sunucularından geçer. Bu Mac’te kalması için Sistem Ayarları › Klavye › Dikte bölümünden ekleyin.",
        soundsTitle: "Başlangıç ve bitiş sesleri",
        speechPermissionName: "Konuşma Tanıma",
        tryTitle: "Deneyin",
        tryPlaceholder: "Buraya tıklayın, sonra dikte edin",
        buildCaption: "Bu yerel derleme konuşma tanıma izni isteyemez. Dikte, fork’un yayımlanan sürümlerinde çalışır.",
        problemAccessibility: "Önce Erişilebilirlik izni verin",
        problemMicrophone: "Ayarlar’da mikrofona izin verin",
        problemSpeech: "Konuşma tanımaya izin verin",
        problemBuild: "Bu derlemede konuşma tanıma yok",
        problemUnavailable: "Konuşma tanıma kullanılamıyor",
        vocabularyTitle: "Sözcük dağarcığı",
        vocabularyCaption: "Diktenin bilmesi gereken sözcükler: adlar, markalar, İngilizce terimler. Söyledikleriniz onlara benzediğinde öne çıkarılır.",
        vocabularyPlaceholder: "Sözcük veya ifade ekleyin",
        addButton: "Ekle",
        replacementsTitle: "Değiştirmeler",
        replacementsCaption: "Dikte ilkini duyduğunda ikincisini yazar. Hâlâ yanlış yazdığı sözcükler için.",
        heardPlaceholder: "Duyulan",
        writtenPlaceholder: "Yazılan"
    )

    static let ru = ForkDictationStrings(
        triggerTitle: "Клавиша",
        triggerRightCommand: "Правая Command",
        triggerRightOption: "Правая Option",
        triggerRightControl: "Правая Control",
        triggerRightShift: "Правая Shift",
        triggerFn: "fn (глобус)",
        howTo: "Удерживайте клавишу и говорите, затем отпустите: текст появится там, где курсор, в любом приложении. Короткое нажатие включает режим без рук, следующее нажатие завершает. Esc отменяет.",
        fnCaption: "Для клавиши fn выберите «Ничего не делать» в пункте «Нажатие клавиши 🌐» в Системных настройках › Клавиатура, иначе macOS тоже отреагирует.",
        openKeyboardSettings: "Настройки клавиатуры",
        languageTitle: "Язык",
        languageAutomaticFormat: "Автоматически (%@)",
        onDevice: "Распознаётся на этом Mac: ничего не уходит наружу.",
        onServer: "Этот язык обрабатывается серверами диктовки Apple, как диктовка macOS. Чтобы всё оставалось на этом Mac, добавьте его в Системных настройках › Клавиатура › Диктовка.",
        soundsTitle: "Звуки начала и конца",
        speechPermissionName: "Распознавание речи",
        tryTitle: "Попробуйте",
        tryPlaceholder: "Нажмите сюда и диктуйте",
        buildCaption: "Эта локальная сборка не может запросить распознавание речи. Диктовка работает в опубликованных версиях форка.",
        problemAccessibility: "Сначала разрешите Универсальный доступ",
        problemMicrophone: "Разрешите микрофон в настройках",
        problemSpeech: "Разрешите распознавание речи",
        problemBuild: "В этой сборке нет распознавания речи",
        problemUnavailable: "Распознавание речи недоступно",
        vocabularyTitle: "Словарь",
        vocabularyCaption: "Слова, которые должна знать диктовка: имена, бренды, английские термины. Им отдаётся предпочтение, когда сказанное на них похоже.",
        vocabularyPlaceholder: "Добавить слово или фразу",
        addButton: "Добавить",
        replacementsTitle: "Замены",
        replacementsCaption: "Когда диктовка слышит первое, она пишет второе. Для слов, в которых она всё ещё ошибается.",
        heardPlaceholder: "Слышится",
        writtenPlaceholder: "Пишется"
    )

    static let es = ForkDictationStrings(
        triggerTitle: "Tecla",
        triggerRightCommand: "Comando derecha",
        triggerRightOption: "Opción derecha",
        triggerRightControl: "Control derecha",
        triggerRightShift: "Mayúsculas derecha",
        triggerFn: "fn (globo)",
        howTo: "Mantén la tecla y habla, luego suéltala: el texto se escribe donde está el cursor, en cualquier app. Una pulsación breve activa el modo manos libres, otra pulsación termina. Esc cancela.",
        fnCaption: "Para la tecla fn, elige “No hacer nada” en “Pulsar la tecla 🌐 para” en Ajustes del Sistema › Teclado, o macOS también reaccionará.",
        openKeyboardSettings: "Ajustes de Teclado",
        languageTitle: "Idioma",
        languageAutomaticFormat: "Automático (%@)",
        onDevice: "Reconocido en este Mac: nada sale de él.",
        onServer: "Este idioma pasa por los servidores de dictado de Apple, como el dictado de macOS. Para quedarte en este Mac, añádelo en Ajustes del Sistema › Teclado › Dictado.",
        soundsTitle: "Sonidos de inicio y fin",
        speechPermissionName: "Reconocimiento de voz",
        tryTitle: "Prueba",
        tryPlaceholder: "Haz clic aquí y dicta",
        buildCaption: "Esta versión local no puede pedir el reconocimiento de voz. El dictado funciona en las versiones publicadas del fork.",
        problemAccessibility: "Permite primero la Accesibilidad",
        problemMicrophone: "Permite el micrófono en Ajustes",
        problemSpeech: "Permite el reconocimiento de voz",
        problemBuild: "Versión sin reconocimiento de voz",
        problemUnavailable: "Reconocimiento de voz no disponible",
        vocabularyTitle: "Vocabulario",
        vocabularyCaption: "Palabras que el dictado debe conocer: nombres, marcas, términos en inglés. Se priorizan cuando lo que dices se parece a ellas.",
        vocabularyPlaceholder: "Añadir una palabra o frase",
        addButton: "Añadir",
        replacementsTitle: "Sustituciones",
        replacementsCaption: "Cuando el dictado oye la primera, escribe la segunda. Para las palabras que sigue escribiendo mal.",
        heardPlaceholder: "Oído",
        writtenPlaceholder: "Escrito"
    )

    static let sk = ForkDictationStrings(
        triggerTitle: "Kláves",
        triggerRightCommand: "Pravý Command",
        triggerRightOption: "Pravý Option",
        triggerRightControl: "Pravý Control",
        triggerRightShift: "Pravý Shift",
        triggerFn: "fn (glóbus)",
        howTo: "Podržte kláves a hovorte, potom ho pustite: text sa napíše tam, kde je kurzor, v ľubovoľnej apke. Krátke ťuknutie zapne režim bez rúk, ďalšie stlačenie ho ukončí. Escape zruší.",
        fnCaption: "Pre kláves fn nastavte „Stlačením klávesu 🌐“ na „Nerobiť nič“ v Systémových nastaveniach › Klávesnica, inak zareaguje aj macOS.",
        openKeyboardSettings: "Nastavenia klávesnice",
        languageTitle: "Jazyk",
        languageAutomaticFormat: "Automaticky (%@)",
        onDevice: "Rozpoznáva sa v tomto Macu: nič z neho neodchádza.",
        onServer: "Tento jazyk prechádza cez diktovacie servery Apple, ako diktovanie v macOS. Ak má zostať v tomto Macu, pridajte ho v Systémových nastaveniach › Klávesnica › Diktovanie.",
        soundsTitle: "Zvuky začiatku a konca",
        speechPermissionName: "Rozpoznávanie reči",
        tryTitle: "Vyskúšajte",
        tryPlaceholder: "Kliknite sem a diktujte",
        buildCaption: "Táto lokálna verzia nemôže požiadať o rozpoznávanie reči. Diktovanie funguje vo zverejnených verziách forku.",
        problemAccessibility: "Najprv povoľte Prístupnosť",
        problemMicrophone: "Povoľte mikrofón v nastaveniach",
        problemSpeech: "Povoľte rozpoznávanie reči",
        problemBuild: "Verzia bez rozpoznávania reči",
        problemUnavailable: "Rozpoznávanie reči nie je dostupné",
        vocabularyTitle: "Slovník",
        vocabularyCaption: "Slová, ktoré má diktovanie poznať: mená, značky, anglické výrazy. Uprednostnia sa, keď to, čo poviete, znie podobne.",
        vocabularyPlaceholder: "Pridať slovo alebo frázu",
        addButton: "Pridať",
        replacementsTitle: "Náhrady",
        replacementsCaption: "Keď diktovanie počuje prvé, napíše druhé. Pre slová, ktoré stále píše zle.",
        heardPlaceholder: "Počuté",
        writtenPlaceholder: "Napísané"
    )

    static let de = ForkDictationStrings(
        triggerTitle: "Taste",
        triggerRightCommand: "Rechte Befehlstaste",
        triggerRightOption: "Rechte Wahltaste",
        triggerRightControl: "Rechte Control-Taste",
        triggerRightShift: "Rechte Umschalttaste",
        triggerFn: "fn (Globus)",
        howTo: "Taste halten und sprechen, dann loslassen: Der Text erscheint dort, wo der Cursor steht, in jeder App. Kurz tippen schaltet freihändig, erneut drücken beendet. Esc bricht ab.",
        fnCaption: "Für die fn-Taste stelle in Systemeinstellungen › Tastatur „Taste 🌐 drücken für“ auf „Keine Aktion“, sonst reagiert auch macOS.",
        openKeyboardSettings: "Tastatureinstellungen",
        languageTitle: "Sprache",
        languageAutomaticFormat: "Automatisch (%@)",
        onDevice: "Wird auf diesem Mac erkannt: Nichts verlässt ihn.",
        onServer: "Diese Sprache läuft über Apples Diktierserver, wie das Diktieren von macOS. Damit sie auf diesem Mac bleibt, füge sie in Systemeinstellungen › Tastatur › Diktieren hinzu.",
        soundsTitle: "Start- und Endtöne",
        speechPermissionName: "Spracherkennung",
        tryTitle: "Ausprobieren",
        tryPlaceholder: "Hier klicken, dann diktieren",
        buildCaption: "Dieser lokale Build kann die Spracherkennung nicht anfragen. Diktieren funktioniert in den veröffentlichten Versionen des Forks.",
        problemAccessibility: "Erst Bedienungshilfen erlauben",
        problemMicrophone: "Mikrofon in den Einstellungen erlauben",
        problemSpeech: "Spracherkennung erlauben",
        problemBuild: "Build ohne Spracherkennung",
        problemUnavailable: "Spracherkennung nicht verfügbar",
        vocabularyTitle: "Vokabular",
        vocabularyCaption: "Wörter, die das Diktieren kennen soll: Namen, Marken, englische Begriffe. Sie werden bevorzugt, wenn das Gesagte ähnlich klingt.",
        vocabularyPlaceholder: "Wort oder Ausdruck hinzufügen",
        addButton: "Hinzufügen",
        replacementsTitle: "Ersetzungen",
        replacementsCaption: "Hört das Diktieren das Erste, schreibt es das Zweite. Für Wörter, die es immer noch falsch schreibt.",
        heardPlaceholder: "Gehört",
        writtenPlaceholder: "Geschrieben"
    )

    static let fr = ForkDictationStrings(
        triggerTitle: "Touche",
        triggerRightCommand: "Commande de droite",
        triggerRightOption: "Option de droite",
        triggerRightControl: "Contrôle de droite",
        triggerRightShift: "Majuscule de droite",
        triggerFn: "fn (globe)",
        howTo: "Maintenez la touche et parlez, puis relâchez : le texte s’écrit là où se trouve le curseur, dans n’importe quelle app. Un appui bref passe en mains libres, un nouvel appui termine. Échap annule.",
        fnCaption: "Pour la touche fn, choisissez « Ne rien faire » pour « Appuyer sur la touche 🌐 » dans Réglages Système › Clavier, sinon macOS réagit aussi.",
        openKeyboardSettings: "Réglages du clavier",
        languageTitle: "Langue",
        languageAutomaticFormat: "Automatique (%@)",
        onDevice: "Reconnue sur ce Mac : rien n’en sort.",
        onServer: "Cette langue passe par les serveurs de dictée d’Apple, comme la dictée de macOS. Pour rester sur ce Mac, ajoutez-la dans Réglages Système › Clavier › Dictée.",
        soundsTitle: "Sons de début et de fin",
        speechPermissionName: "Reconnaissance vocale",
        tryTitle: "Essai",
        tryPlaceholder: "Cliquez ici, puis dictez",
        buildCaption: "Cette version locale ne peut pas demander la reconnaissance vocale. La dictée marche dans les versions publiées du fork.",
        problemAccessibility: "Autorisez d’abord l’accessibilité",
        problemMicrophone: "Autorisez le micro dans les réglages",
        problemSpeech: "Autorisez la reconnaissance vocale",
        problemBuild: "Version sans reconnaissance vocale",
        problemUnavailable: "Reconnaissance vocale indisponible",
        vocabularyTitle: "Vocabulaire",
        vocabularyCaption: "Les mots que la dictée doit connaître : noms, marques, termes anglais. Ils sont privilégiés quand ce que vous dites leur ressemble.",
        vocabularyPlaceholder: "Ajouter un mot ou une expression",
        addButton: "Ajouter",
        replacementsTitle: "Remplacements",
        replacementsCaption: "Quand la dictée entend le premier, elle écrit le second. Pour les mots qu’elle se trompe encore à écrire.",
        heardPlaceholder: "Entendu",
        writtenPlaceholder: "Écrit"
    )

    static let it = ForkDictationStrings(
        triggerTitle: "Tasto",
        triggerRightCommand: "Comando destro",
        triggerRightOption: "Opzione destro",
        triggerRightControl: "Controllo destro",
        triggerRightShift: "Maiuscole destro",
        triggerFn: "fn (globo)",
        howTo: "Tieni premuto il tasto e parla, poi rilascia: il testo viene scritto dove si trova il cursore, in qualsiasi app. Un tocco breve passa al vivavoce, una nuova pressione termina. Esc annulla.",
        fnCaption: "Per il tasto fn, imposta “Premi il tasto 🌐 per” su “Non fare nulla” in Impostazioni di Sistema › Tastiera, altrimenti reagisce anche macOS.",
        openKeyboardSettings: "Impostazioni Tastiera",
        languageTitle: "Lingua",
        languageAutomaticFormat: "Automatica (%@)",
        onDevice: "Riconosciuta su questo Mac: non esce nulla.",
        onServer: "Questa lingua passa dai server di dettatura di Apple, come la dettatura di macOS. Per restare su questo Mac, aggiungila in Impostazioni di Sistema › Tastiera › Dettatura.",
        soundsTitle: "Suoni di inizio e fine",
        speechPermissionName: "Riconoscimento vocale",
        tryTitle: "Prova",
        tryPlaceholder: "Fai clic qui, poi detta",
        buildCaption: "Questa build locale non può chiedere il riconoscimento vocale. La dettatura funziona nelle versioni pubblicate del fork.",
        problemAccessibility: "Consenti prima l’Accessibilità",
        problemMicrophone: "Consenti il microfono nelle Impostazioni",
        problemSpeech: "Consenti il riconoscimento vocale",
        problemBuild: "Build senza riconoscimento vocale",
        problemUnavailable: "Riconoscimento vocale non disponibile",
        vocabularyTitle: "Vocabolario",
        vocabularyCaption: "Parole che la dettatura deve conoscere: nomi, marchi, termini inglesi. Sono favorite quando ciò che dici somiglia a loro.",
        vocabularyPlaceholder: "Aggiungi una parola o frase",
        addButton: "Aggiungi",
        replacementsTitle: "Sostituzioni",
        replacementsCaption: "Quando la dettatura sente la prima, scrive la seconda. Per le parole che continua a sbagliare.",
        heardPlaceholder: "Sentito",
        writtenPlaceholder: "Scritto"
    )

    static let ja = ForkDictationStrings(
        triggerTitle: "キー",
        triggerRightCommand: "右Command",
        triggerRightOption: "右Option",
        triggerRightControl: "右Control",
        triggerRightShift: "右Shift",
        triggerFn: "fn（地球儀）",
        howTo: "キーを押したまま話し、離すと、どのアプリでもカーソルの位置に文字が入力されます。短く押すとハンズフリーになり、もう一度押すと終了します。Escで取り消します。",
        fnCaption: "fnキーを使う場合は、システム設定 › キーボードで「🌐キーを押して」を「何もしない」にしてください。そうしないとmacOSも反応します。",
        openKeyboardSettings: "キーボード設定",
        languageTitle: "言語",
        languageAutomaticFormat: "自動（%@）",
        onDevice: "このMacで認識されます。外部には何も送信されません。",
        onServer: "この言語はmacOSの音声入力と同じく、Appleの音声入力サーバを使います。このMac内で処理するには、システム設定 › キーボード › 音声入力で追加してください。",
        soundsTitle: "開始音と終了音",
        speechPermissionName: "音声認識",
        tryTitle: "試す",
        tryPlaceholder: "ここをクリックして話す",
        buildCaption: "このローカルビルドは音声認識の許可を求められません。音声入力はフォークの公開版で動作します。",
        problemAccessibility: "先にアクセシビリティを許可してください",
        problemMicrophone: "設定でマイクを許可してください",
        problemSpeech: "音声認識を許可してください",
        problemBuild: "このビルドには音声認識がありません",
        problemUnavailable: "音声認識を利用できません",
        vocabularyTitle: "語彙",
        vocabularyCaption: "音声入力に覚えさせたい語句：名前、ブランド、英語の用語。話した内容が似ているときに優先されます。",
        vocabularyPlaceholder: "語句を追加",
        addButton: "追加",
        replacementsTitle: "置き換え",
        replacementsCaption: "音声入力が左の語を聞き取ると、右の語を入力します。いつも間違える語に使います。",
        heardPlaceholder: "聞き取り",
        writtenPlaceholder: "入力"
    )

    static let ko = ForkDictationStrings(
        triggerTitle: "키",
        triggerRightCommand: "오른쪽 Command",
        triggerRightOption: "오른쪽 Option",
        triggerRightControl: "오른쪽 Control",
        triggerRightShift: "오른쪽 Shift",
        triggerFn: "fn (지구본)",
        howTo: "키를 누른 채 말한 다음 떼면, 어느 앱에서든 커서 위치에 텍스트가 입력됩니다. 짧게 누르면 핸즈프리가 되고, 다시 누르면 끝납니다. Esc는 취소합니다.",
        fnCaption: "fn 키를 쓰려면 시스템 설정 › 키보드에서 ‘🌐 키를 눌러’를 ‘동작 안 함’으로 설정하세요. 그렇지 않으면 macOS도 반응합니다.",
        openKeyboardSettings: "키보드 설정",
        languageTitle: "언어",
        languageAutomaticFormat: "자동 (%@)",
        onDevice: "이 Mac에서 인식됩니다. 아무것도 밖으로 나가지 않습니다.",
        onServer: "이 언어는 macOS 받아쓰기처럼 Apple의 받아쓰기 서버를 거칩니다. 이 Mac에서만 처리하려면 시스템 설정 › 키보드 › 받아쓰기에서 추가하세요.",
        soundsTitle: "시작 및 종료 사운드",
        speechPermissionName: "음성 인식",
        tryTitle: "사용해 보기",
        tryPlaceholder: "여기를 클릭한 다음 받아쓰기",
        buildCaption: "이 로컬 빌드는 음성 인식 권한을 요청할 수 없습니다. 받아쓰기는 포크의 공개 버전에서 작동합니다.",
        problemAccessibility: "먼저 손쉬운 사용을 허용하세요",
        problemMicrophone: "설정에서 마이크를 허용하세요",
        problemSpeech: "음성 인식을 허용하세요",
        problemBuild: "음성 인식이 없는 빌드",
        problemUnavailable: "음성 인식을 사용할 수 없음",
        vocabularyTitle: "어휘",
        vocabularyCaption: "받아쓰기가 알아야 할 단어: 이름, 브랜드, 영어 용어. 말한 내용이 비슷하면 우선합니다.",
        vocabularyPlaceholder: "단어 또는 구문 추가",
        addButton: "추가",
        replacementsTitle: "대치",
        replacementsCaption: "받아쓰기가 앞의 말을 들으면 뒤의 말을 씁니다. 계속 잘못 쓰는 단어에 사용하세요.",
        heardPlaceholder: "들은 말",
        writtenPlaceholder: "쓸 말"
    )

    static let uk = ForkDictationStrings(
        triggerTitle: "Клавіша",
        triggerRightCommand: "Права Command",
        triggerRightOption: "Права Option",
        triggerRightControl: "Права Control",
        triggerRightShift: "Права Shift",
        triggerFn: "fn (глобус)",
        howTo: "Утримуйте клавішу й говоріть, потім відпустіть: текст з’явиться там, де курсор, у будь-якій програмі. Коротке натискання вмикає режим без рук, наступне натискання завершує. Esc скасовує.",
        fnCaption: "Для клавіші fn виберіть «Нічого не робити» в пункті «Натискання клавіші 🌐» у Системних параметрах › Клавіатура, інакше macOS теж зреагує.",
        openKeyboardSettings: "Параметри клавіатури",
        languageTitle: "Мова",
        languageAutomaticFormat: "Автоматично (%@)",
        onDevice: "Розпізнається на цьому Mac: нічого не виходить назовні.",
        onServer: "Ця мова проходить через сервери диктування Apple, як диктування macOS. Щоб усе лишалося на цьому Mac, додайте її в Системних параметрах › Клавіатура › Диктування.",
        soundsTitle: "Звуки початку й кінця",
        speechPermissionName: "Розпізнавання мовлення",
        tryTitle: "Спробуйте",
        tryPlaceholder: "Клацніть тут і диктуйте",
        buildCaption: "Ця локальна збірка не може запитати розпізнавання мовлення. Диктування працює в опублікованих версіях форку.",
        problemAccessibility: "Спершу дозвольте Доступність",
        problemMicrophone: "Дозвольте мікрофон у параметрах",
        problemSpeech: "Дозвольте розпізнавання мовлення",
        problemBuild: "Збірка без розпізнавання мовлення",
        problemUnavailable: "Розпізнавання мовлення недоступне",
        vocabularyTitle: "Словник",
        vocabularyCaption: "Слова, які має знати диктування: імена, бренди, англійські терміни. Їм надається перевага, коли сказане на них схоже.",
        vocabularyPlaceholder: "Додати слово чи фразу",
        addButton: "Додати",
        replacementsTitle: "Заміни",
        replacementsCaption: "Коли диктування чує перше, воно пише друге. Для слів, у яких воно досі помиляється.",
        heardPlaceholder: "Чується",
        writtenPlaceholder: "Пишеться"
    )

    static let zhHans = ForkDictationStrings(
        triggerTitle: "按键",
        triggerRightCommand: "右侧 Command",
        triggerRightOption: "右侧 Option",
        triggerRightControl: "右侧 Control",
        triggerRightShift: "右侧 Shift",
        triggerFn: "fn（地球仪）",
        howTo: "按住按键说话，然后松开：文字会写在任何 App 中光标所在的位置。短按进入免提模式，再按一次结束。按 Esc 取消。",
        fnCaption: "使用 fn 键时，请在“系统设置 › 键盘”中将“按下 🌐 键时”设为“不执行任何操作”，否则 macOS 也会响应。",
        openKeyboardSettings: "键盘设置",
        languageTitle: "语言",
        languageAutomaticFormat: "自动（%@）",
        onDevice: "在这台 Mac 上识别：不会有任何内容离开。",
        onServer: "此语言会像 macOS 听写一样经过 Apple 的听写服务器。若要留在这台 Mac 上，请在“系统设置 › 键盘 › 听写”中添加。",
        soundsTitle: "开始和结束提示音",
        speechPermissionName: "语音识别",
        tryTitle: "试一试",
        tryPlaceholder: "点按这里，然后听写",
        buildCaption: "此本地版本无法请求语音识别权限。听写可在分支的发布版本中使用。",
        problemAccessibility: "请先允许辅助功能",
        problemMicrophone: "请在设置中允许麦克风",
        problemSpeech: "请允许语音识别",
        problemBuild: "此版本没有语音识别",
        problemUnavailable: "语音识别不可用",
        vocabularyTitle: "词汇",
        vocabularyCaption: "听写需要认识的词语：人名、品牌、英文术语。当你说的话与它们相似时会优先使用。",
        vocabularyPlaceholder: "添加词语或短语",
        addButton: "添加",
        replacementsTitle: "替换",
        replacementsCaption: "听写听到前者时会写成后者。用于总是写错的词。",
        heardPlaceholder: "听到",
        writtenPlaceholder: "写成"
    )

    static let zhTW = ForkDictationStrings(
        triggerTitle: "按鍵",
        triggerRightCommand: "右側 Command",
        triggerRightOption: "右側 Option",
        triggerRightControl: "右側 Control",
        triggerRightShift: "右側 Shift",
        triggerFn: "fn（地球）",
        howTo: "按住按鍵說話，然後放開：文字會寫在任何 App 中游標所在的位置。短按進入免持模式，再按一次結束。按 Esc 取消。",
        fnCaption: "使用 fn 鍵時，請在「系統設定 › 鍵盤」中將「按下 🌐 鍵時」設為「不執行任何動作」，否則 macOS 也會回應。",
        openKeyboardSettings: "鍵盤設定",
        languageTitle: "語言",
        languageAutomaticFormat: "自動（%@）",
        onDevice: "在這台 Mac 上辨識：不會有任何內容離開。",
        onServer: "此語言會像 macOS 聽寫一樣經過 Apple 的聽寫伺服器。若要留在這台 Mac 上，請在「系統設定 › 鍵盤 › 聽寫」中加入。",
        soundsTitle: "開始與結束提示音",
        speechPermissionName: "語音辨識",
        tryTitle: "試試看",
        tryPlaceholder: "按一下這裡，然後聽寫",
        buildCaption: "此本機版本無法要求語音辨識權限。聽寫可在分支的發佈版本中使用。",
        problemAccessibility: "請先允許輔助使用",
        problemMicrophone: "請在設定中允許麥克風",
        problemSpeech: "請允許語音辨識",
        problemBuild: "此版本沒有語音辨識",
        problemUnavailable: "無法使用語音辨識",
        vocabularyTitle: "詞彙",
        vocabularyCaption: "聽寫需要認識的詞語：人名、品牌、英文術語。當你說的話與它們相似時會優先使用。",
        vocabularyPlaceholder: "加入詞語或片語",
        addButton: "加入",
        replacementsTitle: "取代",
        replacementsCaption: "聽寫聽到前者時會寫成後者。用於總是寫錯的詞。",
        heardPlaceholder: "聽到",
        writtenPlaceholder: "寫成"
    )

    static let zhHK = ForkDictationStrings(
        triggerTitle: "按鍵",
        triggerRightCommand: "右邊 Command",
        triggerRightOption: "右邊 Option",
        triggerRightControl: "右邊 Control",
        triggerRightShift: "右邊 Shift",
        triggerFn: "fn（地球）",
        howTo: "按住按鍵說話，然後放開：文字會寫在任何 App 中游標所在的位置。短按進入免提模式，再按一次結束。按 Esc 取消。",
        fnCaption: "使用 fn 鍵時，請在「系統設定 › 鍵盤」中將「按下 🌐 鍵時」設為「不執行任何動作」，否則 macOS 亦會回應。",
        openKeyboardSettings: "鍵盤設定",
        languageTitle: "語言",
        languageAutomaticFormat: "自動（%@）",
        onDevice: "在這部 Mac 上辨識：不會有任何內容離開。",
        onServer: "此語言會像 macOS 聽寫一樣經過 Apple 的聽寫伺服器。如要留在這部 Mac 上，請在「系統設定 › 鍵盤 › 聽寫」中加入。",
        soundsTitle: "開始及結束提示音",
        speechPermissionName: "語音辨識",
        tryTitle: "試試看",
        tryPlaceholder: "按一下這裡，然後聽寫",
        buildCaption: "此本機版本無法要求語音辨識權限。聽寫可在分支的發佈版本中使用。",
        problemAccessibility: "請先允許輔助使用",
        problemMicrophone: "請在設定中允許咪高峰",
        problemSpeech: "請允許語音辨識",
        problemBuild: "此版本沒有語音辨識",
        problemUnavailable: "無法使用語音辨識",
        vocabularyTitle: "詞彙",
        vocabularyCaption: "聽寫需要認識的詞語：人名、品牌、英文術語。當你說的話與它們相似時會優先使用。",
        vocabularyPlaceholder: "加入詞語或片語",
        addButton: "加入",
        replacementsTitle: "取代",
        replacementsCaption: "聽寫聽到前者時會寫成後者。用於總是寫錯的詞。",
        heardPlaceholder: "聽到",
        writtenPlaceholder: "寫成"
    )
}
