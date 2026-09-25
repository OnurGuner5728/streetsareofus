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
| Dedicated authoritative sunucu | İstemci konum değil input gönderir; hareketi sunucu hesaplar |
| Tahmin + düzeltme + interpolasyon | Aynı `PlayerMotor` her iki tarafta; uzak oyuncular geçmişte interpolasyonla çizilir |
| Interest management | 64 m grid; 50 / 120 / 300 m katmanları farklı sıklıkta gönderilir |
| Rastgele / sosyal spawn | Yürünebilir OSM yollarından skorlu noktalar; "birileriyle karşılaş" modu canlı terimi ekler |
| Konuşma isteği | Kabul, ret ve tepkisiz kalma; ret ile sessizlik isteyene aynı görünür |
| Metin sohbeti | Yalnızca kabul edilmiş sohbetlerde; 30 m'den uzaklaşınca kapanır |
| Jestler | El sallama, selam (20 m) |
| Sustur / engelle / şikayet | Susturma yerel; engelleme kalıcı ve karşılıklı görünmezlik; şikayet olay numarası ve sohbet bağlamıyla kaydedilir |
| Hız sınırları | İstek bekleme süreleri, 3 retten sonra 60 sn, sohbet token-bucket, jest ve şikayet sınırları |
| Avatar | Boy, kilo, kas, omuz, ten, saç, üst, alt, ayakkabı; ağda yalnızca ID ve parametre gider |
| Görsel boy ≠ oyun boyu | 150–205 cm görsel; çarpışma kapsülü 155–195 cm'ye ve dar bir yarıçapa sabitlenir |
| Kalıcılık | Hesap (ilk kullanımda güven), avatar, son konum, engellemeler, şikayetler, denetim logu |
| Protokol sürümü | `PROTOCOL_VERSION` ve zone sürümü eşleşmezse bağlantı reddedilir |
| Botlar ve yük testi | `tools/bots.py smoke` / `load` |
| Atıf | "© OpenStreetMap contributors" oyunda ve menüde her zaman görünür |
| Telefon | Web export + WebSocket transport + dokunmatik kontroller; `tools/serve_web.py` |

### Şehir yaşamı

| Özellik | Nasıl |
|---|---|
| Gerçek tramvay | **T3 Kadıköy–Moda** OSM'deki gerçek 2,6 km döngüsü, 11 gerçek durağı ve rengiyle; bölgeden geçen kısmı (Altıyol, Bahariye) binilebilir |
| Her yere tramvay | Yol ağı üzerinde kapsamayı en çok artıran **K1, K2, K3** hatları üretilir; 828 binanın 784'ü bir durağa 110 m içinde. Arayüzde "simülasyon hattı" diye etiketlenir |
| Zaman tablosu | Her aracın yeri sunucu saatinin saf fonksiyonu: duraklarda bekleme, hızlanma/yavaşlama, uçta makasla karşı raya geçiş. Ağ trafiği yok, herkes aynı yerde görür |
| Binme / inme | Kapılar açıkken yanına git: **Bin**. Yolda **Durak iste**, durakta **İn**. Hat bölgeden çıkacaksa son durakta sunucu indirir. Hepsi sunucuda doğrulanır |
| Duraklar | Gerçekçi isimler (yakındaki simge yapı ya da sokak), kabin, levha, **canlı varış panosu** ("K1 Aytemiz İş Merkezi 2 dk"). Peronlar binalara göre ölçülerek yerleştirilir |
| Rota | Haritada bir yere dokun: yürüme mi, yürü + tramvay + yürü mü, **gerçek zaman tablosuyla** en hızlısı seçilir (sonraki tramvayın tam saati) |
| Yeşil tramvay | Rotandaki hat ve yöndeki tramvaylar yeşil yanar (araçta, radarda, haritada). Rotadaki tramvayda iniş durağın yaklaşınca durak isteği kendiliğinden verilir |
| Yol gösterme | Zeminde kayan ok şeridi, hedefte ışık sütunu, bineceğin durakta "Buradan bin" işareti, tek satırlık talimat |
| Radar | Sağ üstte yöne göre dönen minimap: yakındaki kişiler, uzaktakilerin yönü, tramvaylar, duraklar, rota, radar taraması. Dokun ya da Tab: büyük harita |
| Büyük harita | Kaydır, yakınlaştır (iki parmak / tekerlek), duraklara dokun (sıradaki tramvaylar), hat lejantı, kalabalık ısı hücreleri (64 m, konum değil sayı) |
| Gerçek gökyüzü | Güneş İstanbul'un **gerçek saatine ve koordinatına** göre; altın saat, alacakaranlık, gece. Gece pencereler ve dükkânlar yanar, kameraya yakın lambalar gerçek ışık verir |
| Dokular | Tamamı prosedürel shader: parke taşı, Arnavut kaldırımı, yamalı asfalt ve şerit çizgileri, kenar taşları, gerçek yaya geçitlerinde zebra, çim |
| Mimari | Pencere tipleri binaya göre değişir, çerçeve, denizlik, kat bantları, dükkân camları ve tabelaları, balkon, cumba, tente, çatı parapeti, su deposu, klima |
| Sokak | Raylar ve ray yatağı, katener direkleri ve telleri, sokak lambaları, rüzgârda sallanan ağaçlar (OSM'deki gerçek ağaçlar dahil, çarpışmalı) |
| Tempo | Yürüme 2,4 m/s, koşu 5,2 m/s: şehir büyüklüğünü hissettirir, tramvay işe yarar |

Bilerek yapılmayanlar (planda sonraki adımlar): yükseklik verisi (DEM, zemin
şu an düz), zone'lar arası geçiş (zone kenarı şimdilik görünmez duvar),
Nakama/PostgreSQL, Panoramax sokak görüntüsü, sesli sohbet, NPC, CI, export
şablonları. Ayrıntılar aşağıda.

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
yönlendirilmelidir.

### Telefondan oynamak

Tarayıcılar UDP kullanamadığı için telefon sürümü WebSocket ile konuşur. Tek
komut web export'u alır (kaynak değiştiyse), WebSocket zone sunucusunu başlatır
ve oyunu `http://127.0.0.1:8080` adresinde sunar. `/game` yolu oyun sunucusuna
aktarılır, böylece sayfa ve oyun aynı adresten çalışır:

```bash
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
düğmeler Zıpla / Koş / El salla / Selam; birine bakınca Konuş ve Kişi (sustur,
engelle, şikayet), sohbet açılınca Yaz ve Ayrıl, gelen istekte Kabul / Reddet.
Ekran yatay tutulmalı. Menüde "Tam ekran" adres çubuğunu gizler.

Masaüstü istemci de bir WebSocket sunucusuna bağlanabilir: sunucu alanına
`ws://adres:port` yazmak yeter. Bir zone sunucusu tek transport konuşur
(`--transport=enet` varsayılan, `--transport=ws`).

### Kontroller

| Tuş | İşlev |
|---|---|
| WASD, Shift, Space, fare | Yürü, koş, zıpla, bak |
| E | Bakılan kişiye konuşma isteği (4 m) |
| Y / N | Gelen isteği kabul et / reddet (ya da hiçbir şey yapma) |
| Enter, X | Sohbette yaz / sohbetten ayrıl |
| G, H | El salla, selam ver |
| M, B (iki kez), R + 1–5 | Sustur, engelle, şikayet et |
| Tab | Büyük harita (dokun/tıkla: rota) |
| F | Tramvaya bin / durak iste / in |
| F1, F3, Esc | Yardım, ağ bilgisi, menü |

## Testler

```bash
"$GODOT" --headless --path game --import      # ilk seferde sınıf önbelleği için
"$GODOT" --headless --path game -- --test     # 213 kontrol
python -m unittest discover -s world-pipeline/tests   # 22 test
python tools/bots.py smoke                    # 2 bot: tanış, konuş, yaz, el salla, kalıcılık
python tools/bots.py smoke --transport ws     # aynısı WebSocket üzerinden
python tools/bots.py commute                  # 2 yolcu bot: durağa koş, tramvaya bin, durak iste, in
python tools/bots.py load --bots 20           # sunucu tick/bant genişliği istatistikleri
```

Godot testleri şunları kapsar: avatar ve isim temizleme, ikili codec, tüm
sosyal kurallar, kalıcılık, spawn, zone yükleme, çarpışma, duvarın oyuncuyu
durdurması, **replay'in gerçek zamanlı simülasyonla aynı sonucu vermesi**,
**istemci ile sunucu fizik dünyalarının aynı input'la aynı yolu izlemesi**
(kalabalık bir sunucu dünyasında, 1 mm toleransla), her tramvayın her hatta
kesintisiz ilerlemesi, `departure_after` / sürüş süresi / binilebilirlik
tutarlılığı ve rota planlayıcının asla yürümekten yavaş tramvay seçmemesi.

Smoke testi, localhost'ta tahmin düzeltmesi 25 cm'yi geçerse de başarısız olur.

## Ölçümler (8 çekirdekli dizüstü; sunucu ve tüm botlar aynı makinede)

| Senaryo | Sunucu tick (bütçe 33 ms) | Snapshot trafiği | En büyük tahmin düzeltmesi |
|---|---|---|---|
| 2 bot, smoke | 0,5 ms | 1,6 KB/s | 0,000 m |
| 12 bot tek noktada (en kötü durum) | 3,1 ms | 40 KB/s toplam | 0,07 m |
| 20 bot dağınık | 6,4 ms | 36 KB/s toplam, istemci başına ~4 varlık | 0,000 m |

## Yol boyunca öğrenilenler

- **Godot Physics yerine Jolt:** Oyuncu hareket adımı 0,45 ms'den 0,056 ms'ye
  indi (yaklaşık 8 kat). Jolt istemci ve sunucu dünyaları arasında da
  deterministik (test ile doğrulandı).
- **ENet bant genişliği sınırı:** `bandwidth_limit(0, 0)` açıkça
  çağrılmadığında, tek bir RTT sıçraması (örneğin istemcinin dünyayı kurarken
  takılması) ENet'in güvenilmez paket throttle limitini 1/32'ye çekiyor ve
  input'ların yaklaşık %97'si saniyelerce sessizce düşüyordu. Düzeltme
  `game/net/net.gd` içinde.
- **Input dayanıklılığı:** Her paket onaylanmamış tüm input'ları (en fazla 16)
  tekrarlar. Yine de eksik kalırsa sunucu bir önceki input'la doldurur. Sunucu,
  "tick sayısından fazla input işlenmez" kuralıyla hız hilesini engellerken
  birikmiş kuyruğu eritebilir.
- **Takılma sonrası patlama:** İstemci bir takılmanın ardından kaçırdığı fizik
  adımlarını sunucuya bir anda göndermez; kaybolan zamanı düşürür.

## Yapı

```text
streetsareofus.md          ürün ve teknik plan
world-pipeline/            OSM → zone paketi (Python, bağımlılıksız)
  build_zone.py            CLI: osm | synthetic
  zonegen/                 projeksiyon, kırpma, yükseklik tahmini, spawn skorları, transit (hatlar, duraklar, peronlar)
  tests/
game/                      Godot 4.7 projesi (istemci + headless sunucu)
  net/net.gd               tüm RPC yüzeyi (autoload "Net")
  shared/                  protokol, PlayerMotor, codec, avatar kuralları, zone ve dünya kurucu
  server/                  zone sunucusu, sosyal kurallar, kalıcılık, spawn seçici
  shared/transit.gd        tramvay zaman tablosu (istemci + sunucu)
  shared/road_graph.gd     yaya ağı, Dijkstra
  shared/route_planner.gd  yürüme / tramvay rotası
  client/                  oyun istemcisi, HUD, menü, avatar, uzak oyuncu, bot, dokunmatik kontroller,
                           tram_fleet, city_map (radar + harita), navigator, city_visuals,
                           city_materials (shader'lar), sky_controller
  zones/<zone_id>/         zone.json, spawn_points.json, metadata, attribution, checksum
  tests/test_runner.gd
tools/bots.py              smoke ve yük testleri (--transport enet|ws)
tools/serve_web.py         telefon için web sürümü + WebSocket sunucusu (+ isteğe bağlı tünel)
LICENSES/                  OSM (ODbL) ve üçüncü taraf bileşenler
```

### Yeni bir zone üretmek

```bash
python world-pipeline/build_zone.py osm --zone-id tr_istanbul_moda_001 \
    --name "Moda, İstanbul" --lat 40.9840 --lon 29.0260
```

Kıyı çizgisi içeren bölgelerde deniz poligonu henüz üretilmiyor; pipeline bu
durumda uyarı verir. Pilot bölge bu yüzden kıyıdan içeride seçildi.

### Ağ protokolü

Plandaki mesajların karşılıkları (`game/net/net.gd`):

| Plan | RPC | Kanal |
|---|---|---|
| AUTH / JOIN_ZONE | `c_hello` → `s_welcome` / `s_reject` | güvenilir |
| PLAYER_INPUT | `c_inputs` (ikili, 10 bayt/input) | güvenilmez (WebSocket'te TCP) |
| PLAYER_SNAPSHOT | `s_snapshot` (ikili, 34 + 21 bayt/varlık, 15 Hz) | güvenilmez |
| AVATAR_STATE | `c_avatar`, `s_avatar`, `s_entity_enter` | güvenilir |
| INTERACTION_* | `c_interaction_request/response`, `s_interaction_incoming/result` | güvenilir |
| CHAT_MESSAGE, EMOTE | `c_chat`, `s_chat`, `c_emote`, `s_emote` | güvenilir |
| BLOCK_PLAYER | `c_block` (+ `c_report`) | güvenilir |

## Bilinen sınırlar

- Oyuncular tramvayların içinden geçebilir (oyuncular da birbirinin içinden
  geçer). Tramvay çarpışması istemci tahminiyle çelişmeden eklenmeli.
- Rota planlayıcı tek tramvay yolculuğu planlar; aktarmalı (K1'den K2'ye)
  rota henüz yok, aktarma durakları (Hasırcıbaşı) hazır.
- Üretilen hatlar gerçek değildir ve öyle etiketlenir; T3 gerçek hattır ama
  bölgenin yalnızca Altıyol–Bahariye kısmında binilebilir.
- Telefon performansı yalnızca yazılım renderer'lı emülasyonda denendi;
  gerçek cihazda ölçülmeli (balkon, tente vb. görünürlük mesafeleri ayarlanabilir).

## Sıradaki adımlar (plan sırasıyla)

1. NASADEM/SRTM yükseklik verisi (zone formatında `terrain` alanı hazır).
2. Zone geçişi: komşu zone'ları önceden yükleme ve directory üzerinden transfer
   token'ı.
3. Dünyayı parça parça kurmak (şu an bağlanırken yaklaşık 1 sn takılma var).
4. Engel kaldırma arayüzü; engelleme şu an kalıcı ve geri alınamıyor.
5. GitHub Actions: Python testleri, Godot headless testleri, smoke test,
   Windows ve Linux export. Export'ta `zones/*.json` dosyaları filtreye
   eklenmeli (Godot kaynak olmayan dosyaları varsayılan olarak paketlemez).
6. Panoramax adapter'ı (opsiyonel gerçeklik katmanı).
7. PostgreSQL ve Nakama; `ServerStore` plandaki tabloların birebir karşılığı
   olarak yazıldı.
8. Sesli sohbet (LiveKit/Mumble), MakeHuman/MPFB avatar hattı.
