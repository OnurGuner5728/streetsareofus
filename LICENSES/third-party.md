# Üçüncü taraf bileşenler

| Bileşen | Lisans | Kullanım |
|---|---|---|
| Godot Engine 4.7 | MIT | İstemci ve headless sunucu |
| Jolt Physics (Godot'ya gömülü) | MIT | Fizik motoru |
| ENet (Godot'ya gömülü) | MIT | UDP ağ katmanı |
| OpenStreetMap verisi | ODbL 1.0 | Dünya geometrisi, bkz. `osm.md` |

Avatarlar ve binalar kod içinde prosedürel olarak üretilir; projede henüz
harici bir 3B model, doku ya da font dosyası yoktur.

## Quaternius — Universal Base Characters, Universal Animation Library

- Kaynak: https://quaternius.com (itch.io: quaternius.itch.io, OpenGameArt)
- Lisans: CC0 1.0 (kamu malı). `game/assets/characters/LICENSE_UBC_CC0.txt`, `art-src/LICENSE_UAL_CC0.txt`.
- Kullanım: `game/assets/characters/` (bedenler, saçlar, dokular 1024 px'e küçültüldü), `art-src/AnimationLibrary_Godot_Standard.glb` (animasyonlar; `game/tools/bake_avatar_anims.gd` ile iskelete aktarılır).
