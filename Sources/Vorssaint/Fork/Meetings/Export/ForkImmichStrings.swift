// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation

/// Strings for the Immich export and the Google Drive hint of the drop
/// folder. Same contract as the FeatureStrings structs: memberwise init in
/// declaration order, one static per language.
struct ForkImmichStrings {
    let caption: String
    let address: String
    let key: String
    let keyNew: String
    let keySaved: String
    let keyMissing: String
    let album: String
    let albumDefault: String
    let albumCaption: String
    let test: String
    let testDoneFormat: String
    let driveTip: String

    func testDone(_ status: Int) -> String { String(format: testDoneFormat, status) }

    static func strings(_ language: AppLanguage) -> ForkImmichStrings {
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

extension ForkImmichStrings {
    static let enUS = ForkImmichStrings(
        caption: "Each meeting’s video goes to your own Immich server, with its title as description, into the album chosen. It takes an HTTPS address and an API key (Immich › Account Settings › API Keys) allowed asset.upload, asset.update, album.read, album.create, albumAsset.create and user.read.",
        address: "Server address",
        key: "API key",
        keyNew: "New API key",
        keySaved: "API key saved in the Keychain.",
        keyMissing: "No API key yet: nothing is sent without one.",
        album: "Album",
        albumDefault: "Meetings",
        albumCaption: "Made when missing. Left empty, the video only lands in the timeline.",
        test: "Test the connection",
        testDoneFormat: "Key accepted by the server (%d).",
        driveTip: "For Google Drive: install Google Drive for desktop, then choose a folder of “My Drive” here. Each meeting is copied there and Google Drive uploads it."
    )

    static let ptBR = ForkImmichStrings(
        caption: "O vídeo de cada reunião vai para o seu próprio servidor Immich, com o título como descrição, no álbum escolhido. É preciso um endereço HTTPS e uma chave de API (Immich › Ajustes da conta › Chaves de API) com asset.upload, asset.update, album.read, album.create, albumAsset.create e user.read.",
        address: "Endereço do servidor",
        key: "Chave de API",
        keyNew: "Nova chave de API",
        keySaved: "Chave de API salva nas Chaves.",
        keyMissing: "Ainda sem chave de API: nada é enviado sem ela.",
        album: "Álbum",
        albumDefault: "Reuniões",
        albumCaption: "Criado se não existir. Vazio, o vídeo vai só para a linha do tempo.",
        test: "Testar a conexão",
        testDoneFormat: "Chave aceita pelo servidor (%d).",
        driveTip: "Para o Google Drive: instale o Google Drive para computador e escolha aqui uma pasta de “Meu Drive”. Cada reunião é copiada para lá e o Google Drive a envia."
    )

    static let tr = ForkImmichStrings(
        caption: "Her toplantının videosu, başlığı açıklama olarak, seçilen albüme kendi Immich sunucunuza gider. Bir HTTPS adresi ve asset.upload, asset.update, album.read, album.create, albumAsset.create ve user.read izinli bir API anahtarı gerekir (Immich › Hesap Ayarları › API Anahtarları).",
        address: "Sunucu adresi",
        key: "API anahtarı",
        keyNew: "Yeni API anahtarı",
        keySaved: "API anahtarı Anahtar Zinciri’ne kaydedildi.",
        keyMissing: "Henüz API anahtarı yok: onsuz hiçbir şey gönderilmez.",
        album: "Albüm",
        albumDefault: "Toplantılar",
        albumCaption: "Yoksa oluşturulur. Boş bırakılırsa video yalnızca zaman çizelgesine gelir.",
        test: "Bağlantıyı sına",
        testDoneFormat: "Anahtar sunucu tarafından kabul edildi (%d).",
        driveTip: "Google Drive için: Masaüstü için Google Drive’ı kurun, sonra burada “Drive’ım” içinden bir klasör seçin. Her toplantı oraya kopyalanır ve Google Drive onu yükler."
    )

    static let ru = ForkImmichStrings(
        caption: "Видео каждой встречи отправляется на ваш собственный сервер Immich с названием в описании, в выбранный альбом. Нужен адрес HTTPS и ключ API (Immich › Настройки аккаунта › Ключи API) с правами asset.upload, asset.update, album.read, album.create, albumAsset.create и user.read.",
        address: "Адрес сервера",
        key: "Ключ API",
        keyNew: "Новый ключ API",
        keySaved: "Ключ API сохранён в Связке ключей.",
        keyMissing: "Ключа API ещё нет: без него ничего не отправляется.",
        album: "Альбом",
        albumDefault: "Встречи",
        albumCaption: "Создаётся, если его нет. Если пусто, видео попадает только в ленту.",
        test: "Проверить подключение",
        testDoneFormat: "Сервер принял ключ (%d).",
        driveTip: "Для Google Диска: установите Google Диск для компьютера и выберите здесь папку из «Мой диск». Каждая встреча копируется туда, и Google Диск её загружает."
    )

    static let es = ForkImmichStrings(
        caption: "El vídeo de cada reunión va a tu propio servidor Immich, con su título como descripción, al álbum elegido. Hace falta una dirección HTTPS y una clave de API (Immich › Ajustes de la cuenta › Claves de API) con asset.upload, asset.update, album.read, album.create, albumAsset.create y user.read.",
        address: "Dirección del servidor",
        key: "Clave de API",
        keyNew: "Nueva clave de API",
        keySaved: "Clave de API guardada en el Llavero.",
        keyMissing: "Aún no hay clave de API: sin ella no se envía nada.",
        album: "Álbum",
        albumDefault: "Reuniones",
        albumCaption: "Se crea si no existe. Si se deja vacío, el vídeo solo llega a la cronología.",
        test: "Probar la conexión",
        testDoneFormat: "Clave aceptada por el servidor (%d).",
        driveTip: "Para Google Drive: instala Google Drive para ordenador y elige aquí una carpeta de “Mi unidad”. Cada reunión se copia allí y Google Drive la sube."
    )

    static let sk = ForkImmichStrings(
        caption: "Video každého stretnutia ide na váš vlastný server Immich, s názvom ako popisom, do zvoleného albumu. Treba adresu HTTPS a kľúč API (Immich › Nastavenia účtu › Kľúče API) s oprávneniami asset.upload, asset.update, album.read, album.create, albumAsset.create a user.read.",
        address: "Adresa servera",
        key: "Kľúč API",
        keyNew: "Nový kľúč API",
        keySaved: "Kľúč API je uložený v Kľúčenke.",
        keyMissing: "Kľúč API zatiaľ chýba: bez neho sa nič neodošle.",
        album: "Album",
        albumDefault: "Stretnutia",
        albumCaption: "Vytvorí sa, ak neexistuje. Ak ostane prázdne, video príde len do časovej osi.",
        test: "Otestovať pripojenie",
        testDoneFormat: "Server kľúč prijal (%d).",
        driveTip: "Pre Disk Google: nainštalujte Disk Google pre počítač a vyberte tu priečinok z „Môj disk“. Každé stretnutie sa tam skopíruje a Disk Google ho odošle."
    )

    static let de = ForkImmichStrings(
        caption: "Das Video jeder Besprechung geht auf deinen eigenen Immich-Server, mit dem Titel als Beschreibung, in das gewählte Album. Nötig sind eine HTTPS-Adresse und ein API-Schlüssel (Immich › Kontoeinstellungen › API-Schlüssel) mit asset.upload, asset.update, album.read, album.create, albumAsset.create und user.read.",
        address: "Serveradresse",
        key: "API-Schlüssel",
        keyNew: "Neuer API-Schlüssel",
        keySaved: "API-Schlüssel im Schlüsselbund gesichert.",
        keyMissing: "Noch kein API-Schlüssel: Ohne ihn wird nichts gesendet.",
        album: "Album",
        albumDefault: "Besprechungen",
        albumCaption: "Wird angelegt, falls es fehlt. Leer landet das Video nur in der Zeitleiste.",
        test: "Verbindung testen",
        testDoneFormat: "Schlüssel vom Server angenommen (%d).",
        driveTip: "Für Google Drive: Installiere Google Drive für den Desktop und wähle hier einen Ordner aus „Meine Ablage“. Jede Besprechung wird dorthin kopiert und von Google Drive hochgeladen."
    )

    static let fr = ForkImmichStrings(
        caption: "La vidéo de chaque réunion part sur votre propre serveur Immich, avec son titre en description, dans l’album choisi. Il faut une adresse HTTPS et une clé API (Immich › Paramètres du compte › Clés API) autorisée pour asset.upload, asset.update, album.read, album.create, albumAsset.create et user.read.",
        address: "Adresse du serveur",
        key: "Clé API",
        keyNew: "Nouvelle clé API",
        keySaved: "Clé API enregistrée dans le Trousseau.",
        keyMissing: "Pas encore de clé API\u{00A0}: rien n’est envoyé sans elle.",
        album: "Album",
        albumDefault: "Réunions",
        albumCaption: "Créé s’il n’existe pas. Laissé vide, la vidéo arrive seulement dans la chronologie.",
        test: "Tester la connexion",
        testDoneFormat: "Clé acceptée par le serveur (%d).",
        driveTip: "Pour Google Drive\u{00A0}: installez Google Drive pour ordinateur, puis choisissez ici un dossier de «\u{00A0}Mon Drive\u{00A0}». Chaque réunion y est copiée et Google Drive l’envoie."
    )

    static let it = ForkImmichStrings(
        caption: "Il video di ogni riunione va sul tuo server Immich, con il titolo come descrizione, nell’album scelto. Servono un indirizzo HTTPS e una chiave API (Immich › Impostazioni account › Chiavi API) con asset.upload, asset.update, album.read, album.create, albumAsset.create e user.read.",
        address: "Indirizzo del server",
        key: "Chiave API",
        keyNew: "Nuova chiave API",
        keySaved: "Chiave API salvata nel Portachiavi.",
        keyMissing: "Ancora nessuna chiave API: senza non viene inviato nulla.",
        album: "Album",
        albumDefault: "Riunioni",
        albumCaption: "Creato se manca. Se vuoto, il video arriva solo nella cronologia.",
        test: "Prova la connessione",
        testDoneFormat: "Chiave accettata dal server (%d).",
        driveTip: "Per Google Drive: installa Google Drive per desktop, poi scegli qui una cartella di “Il mio Drive”. Ogni riunione vi viene copiata e Google Drive la carica."
    )

    static let ja = ForkImmichStrings(
        caption: "各会議のビデオを、タイトルを説明に付けて、選んだアルバムに自分のImmichサーバへ送ります。HTTPSのアドレスと、asset.upload、asset.update、album.read、album.create、albumAsset.create、user.readを許可したAPIキー（Immich › アカウント設定 › APIキー）が必要です。",
        address: "サーバのアドレス",
        key: "APIキー",
        keyNew: "新しいAPIキー",
        keySaved: "APIキーをキーチェーンに保存しました。",
        keyMissing: "APIキーがまだありません。キーがないと何も送信されません。",
        album: "アルバム",
        albumDefault: "会議",
        albumCaption: "ない場合は作成します。空のままにすると、ビデオはタイムラインにだけ入ります。",
        test: "接続をテスト",
        testDoneFormat: "サーバがキーを受け付けました（%d）。",
        driveTip: "Googleドライブの場合：パソコン版Googleドライブをインストールし、ここで「マイドライブ」内のフォルダを選んでください。各会議がそこにコピーされ、Googleドライブがアップロードします。"
    )

    static let ko = ForkImmichStrings(
        caption: "각 회의의 비디오를 제목을 설명으로 붙여 선택한 앨범에 내 Immich 서버로 보냅니다. HTTPS 주소와 asset.upload, asset.update, album.read, album.create, albumAsset.create, user.read 권한이 있는 API 키(Immich › 계정 설정 › API 키)가 필요합니다.",
        address: "서버 주소",
        key: "API 키",
        keyNew: "새 API 키",
        keySaved: "API 키를 키체인에 저장했습니다.",
        keyMissing: "아직 API 키가 없습니다. 키가 없으면 아무것도 보내지 않습니다.",
        album: "앨범",
        albumDefault: "회의",
        albumCaption: "없으면 만듭니다. 비워 두면 비디오는 타임라인에만 들어갑니다.",
        test: "연결 테스트",
        testDoneFormat: "서버가 키를 수락했습니다(%d).",
        driveTip: "Google 드라이브의 경우: 데스크톱용 Google 드라이브를 설치한 다음 여기에서 ‘내 드라이브’의 폴더를 선택하세요. 각 회의가 그곳에 복사되고 Google 드라이브가 업로드합니다."
    )

    static let uk = ForkImmichStrings(
        caption: "Відео кожної зустрічі надсилається на ваш власний сервер Immich із назвою в описі, до вибраного альбому. Потрібна адреса HTTPS і ключ API (Immich › Налаштування облікового запису › Ключі API) з правами asset.upload, asset.update, album.read, album.create, albumAsset.create і user.read.",
        address: "Адреса сервера",
        key: "Ключ API",
        keyNew: "Новий ключ API",
        keySaved: "Ключ API збережено у Связці ключів.",
        keyMissing: "Ключа API ще немає: без нього нічого не надсилається.",
        album: "Альбом",
        albumDefault: "Зустрічі",
        albumCaption: "Створюється, якщо його немає. Якщо порожньо, відео потрапляє лише до стрічки.",
        test: "Перевірити з’єднання",
        testDoneFormat: "Сервер прийняв ключ (%d).",
        driveTip: "Для Google Диска: установіть Google Диск для комп’ютера, потім виберіть тут папку з «Мій диск». Кожна зустріч копіюється туди, і Google Диск її вивантажує."
    )

    static let zhHans = ForkImmichStrings(
        caption: "每次会议的视频会以标题作为描述，发送到你自己的 Immich 服务器中所选的相簿。需要 HTTPS 地址和允许 asset.upload、asset.update、album.read、album.create、albumAsset.create 及 user.read 的 API 密钥（Immich › 账户设置 › API 密钥）。",
        address: "服务器地址",
        key: "API 密钥",
        keyNew: "新的 API 密钥",
        keySaved: "API 密钥已存入钥匙串。",
        keyMissing: "还没有 API 密钥：没有它不会发送任何内容。",
        album: "相簿",
        albumDefault: "会议",
        albumCaption: "不存在时会创建。留空时，视频只进入时间线。",
        test: "测试连接",
        testDoneFormat: "服务器已接受密钥（%d）。",
        driveTip: "使用 Google 云端硬盘：安装电脑版 Google 云端硬盘，然后在这里选择“我的云端硬盘”中的文件夹。每次会议都会复制到那里，由 Google 云端硬盘上传。"
    )

    static let zhTW = ForkImmichStrings(
        caption: "每次會議的影片會以標題作為說明，傳送到你自己的 Immich 伺服器中所選的相簿。需要 HTTPS 位址和允許 asset.upload、asset.update、album.read、album.create、albumAsset.create 及 user.read 的 API 金鑰（Immich › 帳號設定 › API 金鑰）。",
        address: "伺服器位址",
        key: "API 金鑰",
        keyNew: "新的 API 金鑰",
        keySaved: "API 金鑰已存入鑰匙圈。",
        keyMissing: "還沒有 API 金鑰：沒有它不會傳送任何內容。",
        album: "相簿",
        albumDefault: "會議",
        albumCaption: "不存在時會建立。留空時，影片只會進入時間軸。",
        test: "測試連線",
        testDoneFormat: "伺服器已接受金鑰（%d）。",
        driveTip: "使用 Google 雲端硬碟：安裝電腦版 Google 雲端硬碟，然後在這裡選擇「我的雲端硬碟」中的檔案夾。每次會議都會複製到那裡，由 Google 雲端硬碟上傳。"
    )

    static let zhHK = ForkImmichStrings(
        caption: "每次會議的影片會以標題作為描述，傳送到你自己的 Immich 伺服器中所揀選的相簿。需要 HTTPS 位址和允許 asset.upload、asset.update、album.read、album.create、albumAsset.create 及 user.read 的 API 密鑰（Immich › 帳戶設定 › API 密鑰）。",
        address: "伺服器位址",
        key: "API 密鑰",
        keyNew: "新的 API 密鑰",
        keySaved: "API 密鑰已存入鎖匙圈。",
        keyMissing: "仲未有 API 密鑰：冇咗佢唔會傳送任何內容。",
        album: "相簿",
        albumDefault: "會議",
        albumCaption: "不存在時會建立。留空時，影片只會進入時間線。",
        test: "測試連線",
        testDoneFormat: "伺服器已接受密鑰（%d）。",
        driveTip: "使用 Google 雲端硬碟：安裝電腦版 Google 雲端硬碟，然後在這裡揀選「我的雲端硬碟」中的資料夾。每次會議都會複製到那裡，由 Google 雲端硬碟上載。"
    )
}
