# Streets Are Of Us

Gerçek dünya tabanlı, canlı ve sosyal bir FPS prototipi. Ürün ve teknik plan
[streetsareofus.md](streetsareofus.md) içinde. Bu depo, planın ilk "vertical
slice" hedefini uygular:

> Gerçek bir mahalle + headless sunucu + birden fazla oyuncu + yürüme +
> birbirini görme + konuşma isteği (kabul / ret / tepkisiz).

Pilot bölge: **Kadıköy, İstanbul** (Bahariye / Söğütlüçeşme çevresi, 512×512 m,
828 bina, 134 yol, OpenStreetMap'ten).

## Neler çalışıyor

| Plan maddesi | Durum |
|---|---|
| OSM → oynanabilir 3B dünya | `world-pipeline/` OSM'den zone paketi üretir; Godot bina, yol, park ve ağaçları kurar |
| Görsel ≠ çarpışma geometrisi | Binalar konveks prizmalar, pencereler shader'da; ağaç gövdeleri sunucuda da var |
| lat/lon → yerel metre | Zone merkezli ENU; kayıtlı konumlar 64-bit enlem/boylam |
| **Gerçek arazi (DEM)** | Kadıköy'ün gerçek yükseklik verisi (SRTM 30 m, OpenTopoData): bölgede **32 m** fark, Moda yönüne yokuşlar, Söğütlüçeşme vadisine iniş. Radar verisindeki çatı tümsekleri yumuşatılır. Zemin çarpışması, görünen zemin ve zemine konan her şey aynı üçgenleri izler (test: 2 cm içinde). Binalar en alçak zemin noktalarına oturur, yokuş tarafında duvar toprağa girer; yollar, raylar, parklar, kaldırım taşları, arabalar (eğime göre yatık), peronlar ve tramvaylar (yokuşta burunları kalkar) araziyi izler |
| Dedicated authoritative sunucu | İstemci konum değil input gönderir; hareketi sunucu hesaplar |
| Tahmin + düzeltme + interpolasyon | Aynı `PlayerMotor` her iki tarafta; uzak oyuncular geçmişte interpolasyonla çizilir |
| Interest management | 64 m grid; 50 / 120 / 300 m katmanları farklı sıklıkta gönderilir |
| Rastgele / sosyal spawn | Yürünebilir OSM yollarından skorlu noktalar; "birileriyle karşılaş" modu canlı terimi ekler. Kimse arabanın, bankın içinde doğmaz |
| Konuşma isteği | Kabul, ret ve tepkisiz kalma; ret ile sessizlik isteyene aynı görünür |
| Metin sohbeti | Yalnızca kabul edilmiş sohbetlerde; 30 m'den uzaklaşınca kapanır |
| Jestler | El sallama, selam (20 m) |
| Sustur / engelle / şikayet | Susturma yerel; engelleme kalıcı ve karşılıklı görünmezlik; şikayet olay numarası ve sohbet bağlamıyla kaydedilir |
| **Engel kaldırma** | Menü → **Engellenenler**: engellediğin herkes (isim, tarih), iki dokunuşla **Engeli kaldır**. Karşı tarafa bildirim gitmez; birbirinizi bir sonraki snapshot'ta yeniden görürsünüz |
| Hız sınırları | İstek bekleme süreleri, 3 retten sonra 60 sn, sohbet token-bucket, jest ve şikayet sınırları |
| **Gerçek insanlar** | Avatarlar artık gerçek, rigli insan modelleri: Quaternius **Universal Base Characters** (CC0; kadın ve erkek beden, ~14 bin üçgen, 8 LOD, 65 kemik, parmaklar dahil) ve **Universal Animation Library** (CC0). Animasyonlar `game/tools/bake_avatar_anims.gd` ile iskelete aktarılır (dünya-uzayı retarget; kütüphanedeki dövüş duruşu şehirde doğal dursun diye bacaklar ve eller gevşetilip ayaklar yere oturtulur): bekleme, yürüme, koşu, sprint, zıplama/düşme/iniş, konuşurken el-kol jestleri, banka oturma/kalkma, dans. Oynatma hızı gerçek hıza göre ayarlanır. Üstüne bir `SkeletonModifier3D` başı bakılan yöne çevirir, el sallama ve baş sallamayı hangi animasyon oynarsa oynasın ekler |
| **Avatar editörü** | Sekmeli (Beden / Yüz / Saç / Üst / Alt / Ayakkabı / Aksesuar) + **Rastgele**. Beden tipi (kadın/erkek), boy (model ölçeği), bacak boyu ve baş (kemik ölçeği), kilo, kas, göğüs, kalça, omuz (shader'da bölgesel şekillendirme). Yüz şekli, 8 ten tonu, 6 göz rengi (iris), kaş (ince/normal/kalın), sakal: kirli sakal, bıyık, keçi sakalı, kısa sakal (boyanır), gür sakal (model). Saç: kazıtılmış, kısa, uzun, topuz (modeller), kıvırcık, afro. Kıyafetler bedenin üstüne shader'la giydirilir: model T-pozunda olduğu için kol boyu = |x|, paça = y; kumaş kalınlığı ve bolluğu (Laplace ile yumuşatılmış bedene göre çukurları doldurur), gömlek patisi ve düğmeleri, kapüşonlu fermuarı, açık ceket önü, kot dokusu, ayakkabı tabanı. Etek, elbise ve mont etekleri, kapüşon, yaka, şapkalar, gözlükler, çantalar ve atkı kemiklere takılı parçalar. Ağda yalnızca ID ve parametre gider |
| **Gardırop** | Oyun içinde Menü → **Görünüm (kıyafet)**: kendini ayna gibi karşıdan görerek değiştir, **Kaydet ve giy** ile herkes yeni halini görür (vazgeçersen hiçbir şey gitmez) |
| **Kamera** | **V** (telefonda **Kamera** düğmesi) ya da Menü: **Birinci şahıs → Arkadan (omuz üstü) → Uzaktan**. Üçüncü şahısta kendi karakterini görürsün; fare tekerleği uzaklığı ayarlar, kamera duvara girmez (yay kolu). Seçim hatırlanır |
| Görsel boy ≠ oyun boyu | 150–205 cm görsel; çarpışma kapsülü 155–195 cm'ye ve dar bir yarıçapa sabitlenir |
| Kalıcılık | Hesap (ilk kullanımda güven), avatar, son konum, engellemeler, şikayetler, denetim logu |
| Protokol sürümü | `PROTOCOL_VERSION` (şu an 4) ve zone sürümü eşleşmezse bağlantı reddedilir |
| Botlar ve yük testi | `tools/bots.py smoke` / `commute` / `load` |
| Atıf | "© OpenStreetMap contributors" oyunda ve menüde her zaman görünür |
| Telefon | Web export + WebSocket transport + dokunmatik kontroller; `tools/serve_web.py` |

### Şehir yaşamı

| Özellik | Nasıl |
|---|---|
| Gerçek tramvay | **T3 Kadıköy–Moda** OSM'deki gerçek 2,6 km döngüsü, 11 gerçek durağı ve rengiyle; bölgeden geçen kısmı (Altıyol, Bahariye) binilebilir |
| Her yere tramvay | Yol ağı üzerinde kapsamayı en çok artıran **K1, K2, K3** hatları üretilir; 828 binanın 784'ü bir durağa 110 m içinde. Arayüzde "simülasyon hattı" diye etiketlenir |
| Zaman tablosu | Her aracın yeri sunucu saatinin saf fonksiyonu: duraklarda bekleme, hızlanma/yavaşlama, uçta makasla karşı raya geçiş. Ağ trafiği yok, herkes aynı yerde görür |
| Binme / inme | Kapılar açıkken yanına git: **Bin**. Yolda **Durak iste**, durakta **İn** (kapılar kapanırken basılırsa sonraki durak istenir). Hat bölgeden çıkacaksa son durakta sunucu indirir |
| Duraklar | **Yükseltilmiş peron** (25 cm, beyaz kenar çizgisi ve sarı hissedilebilir şerit), kabin, bank, levha, **canlı varış panosu** ("K1 Aytemiz İş Merkezi 2 dk") |
| Rota | Haritada bir yere dokun: yürüme mi, yürü + tramvay + yürü mü, **gerçek zaman tablosuyla** en hızlısı seçilir |
| Yeşil tramvay | Rotandaki hat ve yöndeki tramvaylar yeşil yanar (araçta, radarda, haritada); iniş durağın yaklaşınca durak isteği kendiliğinden verilir |
| Yol gösterme | Zeminde kayan ok şeridi, hedefte ışık sütunu, bineceğin durakta "Buradan bin" işareti, tek satırlık talimat |
| Radar | Sağ üstte yöne göre dönen minimap: yakındaki kişiler, uzaktakilerin yönü, tramvaylar, duraklar, rota. Dokun ya da Tab: büyük harita |
| Büyük harita | Kaydır, yakınlaştır, duraklara dokun (sıradaki tramvaylar), hat lejantı, kalabalık ısı hücreleri (64 m, konum değil sayı) |
| Gerçek gökyüzü | Güneş İstanbul'un **gerçek saatine ve koordinatına** göre; altın saat, alacakaranlık, gece. Gece pencereler, dükkânlar ve lambalar yanar |
| **Gece ışığı** | Gece kapkaranlık değil: ay ışıklı mavimsi dolgu ışığı, biraz daha pozlama, daha güçlü ay. Her sokak lambasının altında sıcak bir ışık havuzu ve lamba başında hale (iki MultiMesh, additive; her kalite seviyesinde, telefonda da çalışır). Orta/Yüksek'te en yakın 4/10 lambaya gerçek ışık |
| **Banklara oturma** | Bankın yanında **E** / **Otur**: sunucu en yakın boş yeri (bank başına 2 kişi) doğrular, oturma animasyonu oynar, herkes oturduğunu görür; yürüyünce kalkarsın (kalkış istemci tahmininde de birebir). Oturup konuşurken el-kol jestleri |
| **Dans** | **J** / **Dans**: 8 saniye dans (yakındaki herkes görür; yürüyünce biter) |
| **Gerçek hava** | Sunucu Kadıköy'ün anlık havasını **Open-Meteo**'dan 15 dakikada bir alır (anahtarsız; yalnızca bölgenin koordinatı gider) ve herkese aynısını dağıtır: yağmur (kameranın çevresinde GPU'da düşen damlalar), ıslanan ve yavaşça kuruyan sokaklar, asfaltta su birikintileri, kar (kaldırım ve çatılarda birikir), sis, bulut katmanı, kapalı havada gri gök ve yumuşak ışık, fırtınada şimşek ve gök gürültüsü, rüzgârla sallanan ağaçlar. HUD'da "13°C · Yağmurlu" |
| **Yayalar [NPC]** | Kaldırımlarda yürüyen, ara sıra vitrin önünde duran, oyunculara yol veren yayalar. Plandaki kurala uygun olarak açıkça **NPC** olarak etiketlenir ("yapay bir figür; sohbet edilemez"), gerçek kişi sanılmaz. Hareketleri sunucu saatinin deterministik fonksiyonu: herkes aynı yayayı aynı yerde görür, ağ trafiği yok. Saate göre yoğunluk (gece seyrek) |
| **Sokak kedileri** | Park etmiş arabaların kaputunda ve banklarda uyuyan, kaldırımda gezinen kediler (herkes için aynı). Yanına git: **E** / **Sev** → mırlar |
| **Güvercinler** | Meydan, park ve durak önlerinde yem arayan sürüler; biri yaklaşınca (koşarak daha uzaktan) havalanır, başka yere konar |
| **Tabelalar** | OSM'deki 394 gerçek işletmenin adı (kafe, restoran, eczane "ECZANE", banka, dükkân) bulunduğu binanın sokağa bakan cephesinde; kavşaklarda mavi **İstanbul sokak levhaları** ("Bahariye Cd.", "Nail Bey Sk.") |
| Sokak eşyası | **93 park etmiş araba** (bir kısmı sarı taksi, tramvay yollarında, kavşak ve geçitlerde park yok), bank, yaya bölgesi girişlerinde **babalar**, sokak lambaları, katener, raylar |
| **Sesler** | Hepsi istemcide sentezlenir (indirilecek ses dosyası yok): şehir uğultusu (gece azalır), hızına göre tramvay gürültüsü, tramvay zili, ayak sesleri, martılar, serçeler, yağmur, gök gürültüsü, tekme ve konteyner çarpma sesleri, konuşma isteği sinyali, kedi mırlaması |
| Dokular | Tamamı prosedürel shader: parke taşı, Arnavut kaldırımı, yamalı asfalt ve şerit çizgileri, kenar taşları, zebra, çim |
| Mimari | Pencere tipleri binaya göre değişir, çerçeve, denizlik, kat bantları, dükkân camları, balkon, cumba, tente, çatı parapeti, su deposu, klima |
| Tempo | Yürüme 2,4 m/s, koşu 5,2 m/s: şehir büyüklüğünü hissettirir, tramvay işe yarar |
| Ses ayarı | Menü → **Ses: Açık / Kısık / Kapalı** (hatırlanır). Ayak sesleri yumuşak ve kısık; yürürken seyrek, koşarken sık |

### Fizik

| Özellik | Nasıl |
|---|---|
| **Tramvaylar katı** | Duran tramvay duvar gibidir. Hareket eden bir tramvay önündekini **yana fırlatır** (hafif havaya kalkma, ekran sarsıntısı, "Tramvay çarptı!"). Tramvay yaklaşırken raydaysan uyarı ve **zil** |
| Tahminle uyumlu | Her input, istemcinin gördüğü sunucu tick'iyle damgalanır; tramvaylar o tick'teki yerlerinde hesaplanır. İstemci tahmini ve sunucu **birebir aynı** sonucu verir (test: iki koşu aynı noktaya, 1 mm) |
| Basamak çıkma | 36 cm'ye kadar kenarlara (peron, basamak) yürüyerek çıkılır, daha yüksekleri duvar; kamera yumuşakça yükselir |
| Katı sokak eşyası | Park etmiş arabalar, banklar, babalar, lamba direkleri, durak kabini sunucuda ve istemcide aynı yerde çarpışmalı |
| **Serbest nesneler** | 119 nesne sunucuda rijit cisim (Jolt): parklarda **futbol topları**, kavşaklarda **büyük çöp konteynerleri**, gerçek kafelerin önünde **masa ve sandalyeler**. Yürüyerek itilir, koşarak ya da zıplayarak **top havalanır**, sandalyeler devrilir, tramvay çarptığında savrulur. Yalnızca hareket edenler gönderilir (nesne başı 16 bayt); oyuna sonradan girenler yerinden oynamışları alır; uzun süre dokunulmayanlar kimse yakında değilken yerine döner |

### Performans (telefon)

| Önlem | Etki |
|---|---|
| Kalite kademeleri | **Düşük / Orta / Yüksek / Otomatik** (Menü → Grafik). Telefon ve tarayıcı Düşük ile başlar; fps birkaç saniye 24'ün altında kalırsa kalite kendiliğinden bir kademe iner, en altta 3B çözünürlük %80–60'a düşer |
| Düşük kalite | Gölge, glow ve gece lamba ışıkları yok; tek oktav gürültülü ucuz yüzey shader'ları (Voronoi yok); kısa görüş ve eşya mesafeleri, sis; dekoratif eşya gizli |
| Birleştirilmiş mesh | Tramvay kısmı, avatar uzvu, durak: onlarca kutu yerine tek mesh. Çizim çağrısı 444 → 237 (Orta), 137 (Düşük) |
| Tek çizim çağrısı | Yayalar, kediler, güvercinler, nesne türleri, yağmur: her biri bir MultiMesh, animasyon vertex shader'da |
| Betik yükü | Radar dönüşü transform ile (12 Hz yeniden çizim), dokunmatik düğmeler yalnızca değişince çizilir, HUD 10 Hz, sokak adı ızgara indeksiyle, tramvay zaman tablosu paketli dizilerle (`state()` 66 → 32 µs), uzak tramvay ve oyuncular daha seyrek güncellenir |
| FPS göstergesi | Menü → **FPS göstergesi** (kalite ve çözünürlükle birlikte) |

Bilerek yapılmayanlar (planda sonraki adımlar): zone'lar arası geçiş (zone
kenarı şimdilik görünmez duvar), Nakama/PostgreSQL, Panoramax sokak görüntüsü,
sesli sohbet, LLM'li NPC, CI.

## Gereksinimler

- **Godot 4.7** (standart sürüm, .NET değil). Bu makinede kurulu:
  `%LOCALAPPDATA%\Programs\Godot\Godot_v4.7.2-stable_win64.exe`
  (konsol çıktısı için `..._console.exe`).
- **Python 3.10+**, yalnızca standart kütüphane.

Aşağıdaki komutlarda `GODOT`, konsol sürümünün yoludur:

```bash
export GODOT="$LOCALAPPDATA/Programs/Godot/Godot_v4.7.2-stable_win64_console.exe"
```

## Hızlı başlangıç

**Oyna (tek bilgisayar):** Godot ile `game/` projesini aç ve çalıştır (ya da
`"$GODOT" --path game`). Menüde bir isim yaz ve **Yerel sunucu başlat ve
bağlan**'a bas.

**Kendi başına sosyal akışı denemek:** Sunucuyu `--cluster` ile başlat (herkes
aynı noktada doğar), yanına yerinde duran, istekleri kabul eden ve el sallayan
bir bot koy, sonra menüden **Bağlan**:

```bash
"$GODOT" --headless --path game -- --server --cluster
"$GODOT" --headless --path game -- --bot=idle --connect=127.0.0.1:7000 --name=Ayşe
"$GODOT" --path game
```

**Ayrı sunucu (LAN / internet):**

```bash
"$GODOT" --headless --path game -- --server --port=7000 --zone=tr_istanbul_kadikoy_001
```

Sunucu verisi varsayılan olarak `user://server_data` altına yazılır
(`--data-dir=` ile değiştirilebilir). Evden internete açmak için UDP 7000
yönlendirilmelidir. Hava durumu varsayılan olarak canlıdır; internetsiz
ortamda ya da denemek için `--weather=off|clear|cloudy|rain|storm|fog|snow`.

### Telefondan oynamak

Bağlantı koparsa istemci aynı hesapla, kaldığı yerden **kendiliğinden yeniden
bağlanır** (3 deneme). Menüdeki **Bağlantıyı kes** iki dokunuş ister (yanlışlıkla
çıkılmasın). Tarayıcıdaki hatalar, sekmenin arka plana geçmesi, sayfanın
kapanması ve oturum sonu (süre, fps, kalite) sunucuya küçük bir kayıt olarak
gelir: `build/client_logs.jsonl` ve konsolda `[client-log]` satırları (IP
tutulmaz). "Oyun kapandı" gibi durumlar buradan incelenir.

Tarayıcılar UDP kullanamadığı için telefon sürümü WebSocket ile konuşur. Tek
komut web export'u alır (kaynak değiştiyse), WebSocket zone sunucusunu başlatır
ve oyunu `http://127.0.0.1:8080` adresinde sunar. `/game` yolu oyun sunucusuna
aktarılır, böylece sayfa ve oyun aynı adresten çalışır:

```bash
python tools/serve_web.py --bot --cluster --tunnel --apk  # + Android uygulaması
python tools/serve_web.py --bot --cluster          # yalnızca bu bilgisayar
python tools/serve_web.py --bot --cluster --lan    # aynı Wi-Fi'deki telefon
python tools/serve_web.py --bot --cluster --tunnel # internetten: Cloudflare quick tunnel
```

`--tunnel` için `cloudflared` gerekir (PATH'te ya da
`%LOCALAPPDATA%\Programs\cloudflared\cloudflared.exe`). Hesap istemez; çıktıda
`https://….trycloudflare.com` adresi yazar. Bu adresi bilen herkes oyuna
girebilir, işin bitince komutu durdur. `--lan` için Windows Güvenlik Duvarı'nın
Python'a gelen bağlantı izni vermesi gerekir. Web export'u için Godot'nun
**web** export şablonları kurulu olmalı.

Telefonda: sol başparmak joystick, sağ taraf sürükleyerek bakış, sağdaki
düğmeler Zıpla / Koş / El salla / Selam, üstte Kamera ve Menü; birine bakınca Konuş ve Kişi (sustur,
engelle, şikayet), sohbet açılınca Yaz ve Ayrıl, gelen istekte Kabul / Reddet,
kedinin yanında Sev, tramvay yanında Bin / Durak iste / İn. Ekran yatay
tutulmalı. Menüde "Tam ekran" adres çubuğunu gizler; oyun içi Menü'de
Görünüm (kıyafet), Kamera, Ses, Engellenenler, Grafik kalitesi ve FPS göstergesi
var.

**Android uygulaması (APK)** tarayıcıdan belirgin şekilde akıcıdır (tarayıcı katmanı yok, doğal OpenGL ES). `--apk` ile `build/android/streetsareofus.apk` üretilir ve `/streetsareofus.apk` adresinden indirilir; Android tarayıcıdan girenlere menüde **Android uygulamasını indir** düğmesi çıkar (tıklayınca oyunun adresi panoya kopyalanır). Kurmak için telefonda "bilinmeyen kaynaklardan yükleme"ye izin ver; uygulamada **Sunucu** alanına telefon linkini (https://….trycloudflare.com) yapıştır, `wss://…/game`'e kendisi çevirir. APK bu makinenin Android debug anahtarıyla imzalanır (anahtar repoya girmez). Gerekenler: Godot Android şablonları, Android SDK (build-tools), JDK 17+ (Godot editör ayarlarında `export/android/java_sdk_path`).

Masaüstü istemci de bir WebSocket sunucusuna bağlanabilir: sunucu alanına
`ws://adres:port` yazmak yeter. Bir zone sunucusu tek transport konuşur
(`--transport=enet` varsayılan, `--transport=ws`).

### Kontroller

| Tuş | İşlev |
|---|---|
| WASD, Shift, Space, fare | Yürü, koş, zıpla, bak (koşarak topa girersen top havalanır) |
| E | Bakılan kişiye konuşma isteği (4 m); kedinin yanındaysan sev |
| Y / N | Gelen isteği kabul et / reddet (ya da hiçbir şey yapma) |
| Enter, X | Sohbette yaz / sohbetten ayrıl |
| G, H | El salla, selam ver |
| M, B (iki kez), R + 1–5 | Sustur, engelle, şikayet et |
| Tab | Büyük harita (dokun/tıkla: rota) |
| F | Tramvaya bin / durak iste / in |
| E (bankın yanında), J | Banka otur (yürüyünce kalkarsın), dans et |
| V, fare tekerleği | Kamera: birinci şahıs / arkadan / uzaktan; üçüncü şahısta uzaklık |
| F1, F3, Esc | Yardım, ağ bilgisi, menü (Görünüm, Kamera, Ses, Engellenenler, Grafik, FPS) |

## Testler

```bash
"$GODOT" --headless --path game --import      # ilk seferde sınıf önbelleği için
"$GODOT" --headless --path game -- --test     # 270 kontrol
python -m unittest discover -s world-pipeline/tests   # 26 test
python tools/bots.py smoke                    # 2 bot: tanış, konuş, yaz, el salla, engelle, engeli kaldır, kalıcılık
python tools/bots.py smoke --transport ws     # aynısı WebSocket üzerinden
python tools/bots.py commute                  # 2 yolcu bot: durağa koş, tramvaya bin, durak iste, in
python tools/bots.py load --bots 20           # sunucu tick/bant genişliği istatistikleri
```

Test sunucuları gerçek havayı çekmez (`--weather=clear`).

Godot testleri şunları kapsar: avatar ve isim temizleme (yeni alanlar, eski
"kep" saçı, avatar değişince kapsülün sınırlar içinde yeniden boyutlanması),
ikili codec (input
dünya tick'i dahil, 16 bit sarma), nesne pozlarının santim/derece
hassasiyetinde taşınması, tüm sosyal kurallar, kalıcılık ve engel kaldırma,
spawn, zone yükleme, çarpışma, duvarın oyuncuyu durdurması, **replay'in gerçek
zamanlı simülasyonla aynı sonucu vermesi**, **istemci ile sunucu fizik
dünyalarının aynı input'la aynı yolu izlemesi**, **basamak çıkma** (25 cm
evet, 60 cm hayır), **tramvayın raydakini yana fırlatması ve bunun
deterministik olması**, duran tramvayın katı olması, **koşan oyuncunun topu
tekmelemesi**, yayaların binalara girmeden ve sıçramadan yürümesi, **arazi
çarpışmasının `Terrain.height()` ile örtüşmesi, binaların zemine oturması,
yokuş çıkılabilmesi**, tramvay
zaman tablosu tutarlılığı ve rota planlayıcının asla yürümekten yavaş tramvay
seçmemesi.

Smoke testi, localhost'ta tahmin düzeltmesi 25 cm'yi geçerse de başarısız olur.

## Ölçümler (8 çekirdekli dizüstü, Iris Xe; sunucu ve tüm botlar aynı makinede)

| Senaryo | Sunucu tick (bütçe 33 ms) | Snapshot trafiği | En büyük tahmin düzeltmesi |
|---|---|---|---|
| 2 bot, smoke | 0,5 ms | 1,6 KB/s | 0,000 m |
| 12 bot tek noktada (en kötü durum; arazi, 119 fizik nesnesi, 22 tramvay gövdesi) | 6,6 ms | 45 KB/s toplam | 0,1 m |

İstemci (Compatibility renderer, 854×480, telefon benzeri ayar, Iris Xe): Orta
kalitede çizim çağrısı 444 → 237; Düşük kalitede ~140 çizim çağrısı, arazi
dahil 130 fps.

## Yol boyunca öğrenilenler

- **Godot Physics yerine Jolt:** Oyuncu hareket adımı 0,45 ms'den 0,056 ms'ye
  indi (yaklaşık 8 kat). Jolt istemci ve sunucu dünyaları arasında da
  deterministik (test ile doğrulandı).
- **ENet bant genişliği sınırı:** `bandwidth_limit(0, 0)` açıkça
  çağrılmadığında, tek bir RTT sıçraması ENet'in güvenilmez paket throttle
  limitini 1/32'ye çekiyor ve input'ların yaklaşık %97'si saniyelerce sessizce
  düşüyordu. Düzeltme `game/net/net.gd` içinde.
- **Input dayanıklılığı:** Her paket onaylanmamış tüm input'ları (en fazla 16)
  tekrarlar. Yine de eksik kalırsa sunucu bir önceki input'la doldurur.
- **Hareketli engel + tahmin:** Tramvay sunucunun o anki saatinde değil,
  input'un damgasındaki tick'te hesaplanır; böylece istemci ne gördüyse sunucu da
  onu simüle eder ve çarpışmalar düzeltme doğurmaz.
- **Telefonda takılmanın asıl sebebi** çizim çağrısı sayısı (her kutu ayrı
  nesne) ve piksel başına dört oktavlı gürültüydü; betik tarafında ise her
  karede yeniden çizilen arayüz ve sözlüklerle çalışan zaman tablosu.
- **Nesneler oyuncuyu durdurmaz, oyuncu nesneyi iter:** Oyuncu hareketi
  nesnelere bağlı olsaydı istemci tahmini sunucunun nesne konumlarını bilemeyeceği
  için sürekli düzeltme olurdu.

## Yapı

```text
streetsareofus.md          ürün ve teknik plan
world-pipeline/            OSM → zone paketi (Python, bağımlılıksız)
  build_zone.py            CLI: osm | synthetic
  zonegen/                 projeksiyon, kırpma, yükseklik tahmini, spawn skorları, transit (hatlar, duraklar, peronlar)
  tests/
game/                      Godot 4.7 projesi (istemci + headless sunucu)
  net/net.gd               tüm RPC yüzeyi (autoload "Net")
  shared/                  protokol, PlayerMotor (basamak, tramvay çarpışması), codec, avatar kuralları,
                           zone ve dünya kurucu, street_layout (sokak eşyası yerleşimi), prop_layout,
                           crowd (NPC yayalar), transit (zaman tablosu), road_graph, route_planner
  server/                  zone sunucusu, sosyal kurallar, kalıcılık, spawn seçici,
                           prop_world (rijit cisimler), weather_service (Open-Meteo)
  client/                  oyun istemcisi, HUD, menü, avatar, uzak oyuncu, bot, dokunmatik kontroller,
                           tram_fleet, city_map (radar + harita), navigator, city_visuals, city_materials,
                           sky_controller, graphics_quality, mesh_merger, prop_view, crowd_view, critters,
                           weather_view, city_sounds, frame_profiler
  zones/<zone_id>/         zone.json, spawn_points.json, metadata, attribution, checksum
  assets/characters/        CC0 insan modelleri, saçlar, pişmiş animasyon kütüphaneleri ve gövde mesh'leri
  tools/                   bake_avatar_anims.gd (retarget + gövde verisi), pose_preview.gd
  tests/test_runner.gd
tools/bots.py              smoke, commute ve yük testleri (--transport enet|ws)
tools/serve_web.py         telefon için web sürümü + WebSocket sunucusu (+ tünel, + Android APK)
art-src/                   animasyon kütüphanesinin kaynak glTF'i (CC0)
LICENSES/                  OSM (ODbL) ve üçüncü taraf bileşenler
```

Geliştirme araçları: istemci `--perf` ile iki saniyede bir fps, çizim çağrısı
ve bölüm bölüm betik süresi yazar (`--perf=Ad1,Ad2` o sahne parçalarını
gizleyerek maliyetini ölçer); `--quality=low|medium|high`,
`--screenshot=dosya.png` (`--look-npc`, `--look-sign`, `--tram-shot` ile
kadraj). Bu pencereler odak almaz ve ekranın dışında durur.

### Yeni bir zone üretmek

```bash
python world-pipeline/build_zone.py osm --zone-id tr_istanbul_moda_001 \
    --name "Moda, İstanbul" --lat 40.9840 --lon 29.0260
```

Yükseklik verisi OpenTopoData'dan (SRTM, olmazsa ASTER) ya da Open-Meteo'dan
(Copernicus 90 m) çekilir ve `world-pipeline/cache/` altında saklanır; düz zemin
için `--flat`. Zone içeriği değiştiğinde `--version` artırılmalı (Kadıköy şu an
v3): sunucu ve istemci farklı sürümdeyse bağlantı açık bir mesajla reddedilir.

Kıyı çizgisi içeren bölgelerde deniz poligonu henüz üretilmiyor; pipeline bu
durumda uyarı verir. Pilot bölge bu yüzden kıyıdan içeride seçildi.

### Ağ protokolü

Plandaki mesajların karşılıkları (`game/net/net.gd`):

| Plan | RPC | Kanal |
|---|---|---|
| AUTH / JOIN_ZONE | `c_hello` → `s_welcome` / `s_reject` (+ `s_weather`, `s_props`) | güvenilir |
| PLAYER_INPUT | `c_inputs` (ikili, 12 bayt/input, dünya tick'i dahil) | güvenilmez (WebSocket'te TCP) |
| PLAYER_SNAPSHOT | `s_snapshot` (ikili, 34 + 21 bayt/varlık + 16 bayt/hareketli nesne, 15 Hz) | güvenilmez |
| AVATAR_STATE | `c_avatar`, `s_avatar`, `s_entity_enter` | güvenilir |
| INTERACTION_* | `c_interaction_request/response`, `s_interaction_incoming/result` | güvenilir |
| CHAT_MESSAGE, EMOTE | `c_chat`, `s_chat`, `c_emote`, `s_emote` | güvenilir |
| BLOCK_PLAYER | `c_block`, `c_blocked_list` → `s_blocked_list`, `c_unblock` (+ `c_report`) | güvenilir |
| Tramvay | `c_board`, `c_alight`, `s_ride`, `s_rider` | güvenilir |

## Bilinen sınırlar

- Oyuncular birbirinin ve serbest nesnelerin içinden geçer (nesneleri sunucu
  iter; itme istemcide yaklaşık bir gidiş-dönüş gecikmesiyle görünür).
- Yayalar oyunculardan kaçınmaz; güvercinler her istemcide ayrı simüle edilir.
- Kaldırımlar yükseltilmemiş (yol ile kaldırım aynı yüzeyde; kenar taşı yalnızca görsel).
- Binalar düz tabanlı: dik yokuşta alt kattaki dükkân camları yokuş tarafında toprağa girer.
- Rota planlayıcı tek tramvay yolculuğu planlar; aktarmalı rota henüz yok.
- Üretilen hatlar gerçek değildir ve öyle etiketlenir; T3 gerçek hattır ama
  bölgenin yalnızca Altıyol–Bahariye kısmında binilebilir.
- Telefon performansı masaüstünde telefon benzeri ayarlarla ölçüldü; gerçek
  cihazda FPS göstergesiyle doğrulanmalı.

## Sıradaki adımlar (plan sırasıyla)

1. Yükseltilmiş kaldırımlar ve basamaklı OSM yolları (`steps`); `PlayerMotor`
   basamak çıkma hazır.
2. Zone geçişi: komşu zone'ları önceden yükleme ve directory üzerinden transfer
   token'ı.
3. Dünyayı parça parça kurmak (şu an bağlanırken kısa bir takılma var).
4. GitHub Actions: Python testleri, Godot headless testleri, smoke test,
   Windows ve Linux export.
5. Panoramax adapter'ı (opsiyonel gerçeklik katmanı).
6. PostgreSQL ve Nakama; `ServerStore` plandaki tabloların birebir karşılığı
   olarak yazıldı.
7. Sesli sohbet (LiveKit/Mumble), gerçek modellerle yayalar (en yakın NPC'ler), planın
   sırasıyla LLM'li NPC diyaloğu.
