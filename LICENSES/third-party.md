# Üçüncü taraf bileşenler

| Bileşen | Lisans | Kullanım |
|---|---|---|
| Godot Engine 4.7 | MIT | İstemci ve headless sunucu |
| Jolt Physics (Godot'ya gömülü) | MIT | Fizik motoru |
| ENet (Godot'ya gömülü) | MIT | UDP ağ katmanı |
| OpenStreetMap verisi | ODbL 1.0 | Dünya geometrisi, bkz. `osm.md` |

Avatarlar ve binalar kod içinde prosedürel olarak üretilir; harici 3B model olarak yalnızca
aşağıdaki Quaternius avatarları, doku olarak da ambientCG bina malzemeleri vardır; font dosyası yoktur.

## Quaternius — Universal Base Characters, Universal Animation Library

- Kaynak: https://quaternius.com (itch.io: quaternius.itch.io, OpenGameArt)
- Lisans: CC0 1.0 (kamu malı). `game/assets/characters/LICENSE_UBC_CC0.txt`, `art-src/LICENSE_UAL_CC0.txt`.
- Kullanım: `game/assets/characters/` (bedenler, saçlar, dokular 1024 px'e küçültüldü), `art-src/AnimationLibrary_Godot_Standard.glb` (animasyonlar; `game/tools/bake_avatar_anims.gd` ile iskelete aktarılır).

## ambientCG — bina cephe ve çatı dokuları

- Kaynak: https://ambientcg.com (Lennart Demes / Struffel Productions)
- Lisans: CC0 1.0 (kamu malı), atıf gerekmez; kaynak yine de belirtilir.
- Kullanım: `game/assets/textures/` — yalnızca albedo (+ normal) haritaları, 1K JPG paketlerinden
  256/512 px'e küçültülüp yeniden JPG olarak kaydedildi; normal haritalar yeniden normalize edildi.
  Cephe ve çatı gölgelendiricileri (`game/client/city_materials.gd`) bunları yükler.

| Dosya | ambientCG kimliği | Nerede |
|---|---|---|
| `facade_plaster_*` | Plaster002 | Boyalı/sıvalı beton cephe (renk köşe rengiyle verilir) |
| `facade_brick_*` | Bricks085 | Tuğla cepheler |
| `facade_stone_albedo` | Tiles143 | Taş kaplama (zemin kat ve ticari binalar) |
| `roof_tiles_*` | RoofingTiles012A | Kiremit çatılar |
| `roof_flat_*` | Asphalt031 | Düz çatılar (beton/asfalt kaplama) |

