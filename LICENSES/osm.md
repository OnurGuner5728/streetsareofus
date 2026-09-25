# OpenStreetMap verisi

`game/zones/tr_istanbul_kadikoy_001/` altındaki zone paketi OpenStreetMap
verisinden üretilmiştir.

- Kaynak: © OpenStreetMap katkıcıları — https://www.openstreetmap.org/copyright
- Lisans: Open Database License (ODbL) 1.0
- Alım: Overpass API üzerinden tek bir bbox sorgusu (tarih ve OSM snapshot
  zamanı her zone'un `attribution.json` dosyasında)

Yükümlülükler:

- Oyun içinde atıf her zaman görünür (HUD'ın sağ alt köşesi ve menü).
- `zone.json` bir türetilmiş veritabanıdır (Derivative Database). Oyunu
  dağıtırsak zone paketlerini de ODbL altında paylaşmak, ya da onları nasıl
  ürettiğimizi (`world-pipeline/`) açık etmek gerekir.
- OSM'nin herkese açık tile sunucuları oyun CDN'i olarak kullanılmaz. Pipeline
  zone başına tek bir küçük sorgu yapar ve sonucu `world-pipeline/cache/`
  altında saklar; aynı zone için tekrar sorgu atmaz (`--refresh` hariç).
