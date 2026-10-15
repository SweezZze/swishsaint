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
    let sharedSettings: String
    let aboutSection: String
    let aboutBody: String
    let sourceCode: String
    let officialProject: String

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
        sharedSettings: "手勢會在被忽略的 App 中暫停，並使用此頁面設定的間距：",
        aboutSection: "關於此版本",
        aboutBody: "此版本會自動跟隨官方 Vorssaint，並加入幾個朋友做的功能。它沒有 Apple 簽署，也不是 Vorssaint 團隊製作的：這個 App 的所有功勞都歸 Vorssaint。",
        sourceCode: "原始碼",
        officialProject: "官方 Vorssaint"
    )
}
