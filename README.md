# older-package — Termux APT deposu

`pkg install vs-code` → **`Failed to fetch .../pool/vs-code.deb 404 Not Found`**

Sebep: metadata (Release/Packages) doğru, **ama `.deb` dosyası sunucuda yok**.
`vs-code.deb` 239.610.838 bayt (228.5 MB). GitHub tek dosya için **100 MB** sınırı
koyduğu için dosya depoya (`pool/`) commit edilemiyor; GitHub Pages de statik
olduğu için yönlendirme yapamıyor → `pool/vs-code.deb` isteği 404 dönüyor.

Bu README'de üç çalışan yol var: **proxy** (apt ile çalışır), **elle kurulum**
(bugün çalışır) ve paketin Termux'ta çalışıp çalışmayacağı uyarısı.

---

## 0. Hızlı teşhis

```bash
apt-cache policy vs-code        # Candidate: 1.0.0 görünüyorsa metadata sorunsuz
```

Depo tarafını bu repoda denetleyebilirsin:

```bash
./scripts/check-repo.sh --offline --require-pool
#   ✗ vs-code: pool/vs-code.deb YOK — apt 'Failed to fetch ... 404 Not Found' alir
```

Yani sorun istemcide değil: **indirilecek dosya yayınlanmamış.**

## 0.1 sources.list uyarılarını temizle

Ekrandaki şu uyarılar zararsız ama gürültülü:

```
W: Target Packages ... configured multiple times ... older-package.list:1 and ... older.list:1
W: Skipping acquire of configured file 'pkg/binary-aarch64/Packages' ... doesn't have the component 'pkg'
W: Skipping acquire of configured file 'update/binary-aarch64/Packages' ... component 'update'
```

Mükerrer dosya ve fazladan `pkg update` kelimeleri var. Tek dosya bırak:

```bash
ls $PREFIX/etc/apt/sources.list.d/                 # older.list + older-package.list görürsün
rm -f $PREFIX/etc/apt/sources.list.d/older.list
cat $PREFIX/etc/apt/sources.list.d/older-package.list   # TEK satır olmalı, aşağıdaki gibi:
# deb [trusted=yes arch=aarch64] https://mio-129.github.io/older-package/ stable main
pkg update
```

> Satırda `stable main` dışında `pkg`, `update` gibi kelimeler **olmamalı**.

---

## 1. Çözüm A — Worker proxy (apt ile, kalıcı)

GitHub Pages 100 MB'lık dosyayı servis edemez, ama **302 yönlendirmesi** yapan
küçük bir Cloudflare Worker bu işi çözer. Metadata Pages'te kalır, `.deb`
doğrudan Release asset'inden iner.

```
/pool/<dosya>   ->  https://github.com/Mio-129/older-package/releases/latest/download/<dosya>   (302)
/dists/...      ->  https://mio-129.github.io/older-package/...                                  (proxy)
```

Kurulum: **`proxy/README.md`** (tarayıcıdan, telefondan bile yapılabilir, ücretsiz plan yeter).

Sonra Termux'ta base URL'i worker'a çevir:

```bash
pkg update
echo "deb [trusted=yes arch=aarch64] https://older-package.<hesabın>.workers.dev/ stable main" \
  > $PREFIX/etc/apt/sources.list.d/older-package.list
pkg update
pkg install vs-code
```

Bu akış gerçek apt ile test edildi (apt 2.6.1): `Release` ve `Packages` worker
üzerinden geldi, `pool/vs-code.deb` 302 ile Release'e gitti, inen dosyanın
SHA256'sı `Packages` içindeki değerle eşleşti.

## 2. Çözüm B — Elle kurulum (kurulum gerektirmez, bugün çalışır)

```bash
curl -L -o $TMPDIR/vs-code.deb \
  https://github.com/Mio-129/older-package/releases/download/1.0.0/vs-code.deb
pkg install $TMPDIR/vs-code.deb
```

## 3. Çözüm C — Cloudflare Pages / Netlify (`_redirects`)

```bash
POOL_MODE=redirect ./scripts/update-repo.sh   # /pool/* -> Release 302 satırları üretir
```

Siteyi Cloudflare Pages veya Netlify'a yayınla (GitHub Pages `_redirects` desteklemez),
base URL'i o siteye çevir. `.deb` git'e girmez.

---

## Çok önemli uyarı: bu `.deb` Termux'ta çalışmayabilir

Ubuntu/Debian için derlenmiş bir VS Code `.deb`'i **glibc** ve Debian kütüphanelerini
(`libgtk-3-0`, `libnss3`, …) bekler; Termux **bionic libc** kullanır ve bu paketler
`$PREFIX` altında yoktur. Mimari (`aarch64`) uysa bile:

```
CANNOT LINK EXECUTABLE .../code: library "libgtk-3.so.0" not found
```

Termux için doğru yol:

```bash
pkg install x11-repo
pkg install code-oss     # Termux'un resmî code-oss paketi (X11 / Termux:X11 gerekir)
```

Yani "indirme düzelse" bile sonuç büyük olasılıkla çalışan bir VS Code olmaz.
Depoyu yine de ayakta tutmak istiyorsan aşağıdaki bakım bölümüne bak.

---

## Neden `Packages`/`Filename` bu şekilde?

| # | Tuzak | Sonuç |
|---|-------|-------|
| 1 | `Architecture: arm64` | Termux dpkg mimarisi **`aarch64`**; `arm64` yazan paket indekse girmez → `E: Unable to locate package` |
| 2 | `Filename: https://github.com/.../vs-code.deb` | apt `Filename`'i **base URL'e ekler**. Test: base `file:/tmp/tr/repo` + bu değer → `file:/tmp/tr/repo/https://github.com/...` → 404. Absolute URL **kullanılamaz** |
| 3 | `dists/stable/Release` yok / hash yanlış | apt indeksi yok sayar |
| 4 | `Packages` içinde `SHA256` yok | apt indirilen `.deb`'i doğrulayamaz |
| 5 | Boyut > 100 MB iken `pool/`'a koymak | git reddeder / Pages 404 (bu reponun şu anki durumu) |
| 6 | `.nojekyll` yok | Jekyll `dists/` altını bozar |

## Depo bakımı

```bash
./scripts/update-repo.sh                  # POOL_MODE=local (varsayılan) — >100 MB'ta hata verir
POOL_MODE=proxy ./scripts/update-repo.sh  # metadata üret, indirme yok (worker 302 yapar)
POOL_MODE=redirect ./scripts/update-repo.sh  # _redirects üret

./scripts/check-repo.sh                   # Release hash + her Filename HTTP 200 mü?
./scripts/check-repo.sh --offline         # sadece yerel (CI)
./scripts/check-repo.sh --offline --require-pool   # pool/ zorunlu
BASE_URL=https://older-package.<hesabın>.workers.dev/ ./scripts/check-repo.sh
```

- `scripts/update-repo.sh` artık `Packages` dosyasını geçici dosyaya yazıp en sonda
  taşır: hata durumunda yayındaki indeks bozulmaz.
- 100 MB sınırını aşan asset'te `local` mod **hata verip durur** (sessizce 404 üreten
  metadata üretmez).
- GitHub Actions (`.github/workflows/update-repo.yml`) her Release'te metadatayı
  yeniler ve `check-repo.sh --offline` ile doğrular. Varsayılan mod: `proxy`.

Gerekli araçlar: `curl`, `jq`, `gzip`, `sha256sum`.

## Dosya düzeni

```
.
├── dists/stable/
│   ├── Release
│   └── main/binary-aarch64/Packages(.gz)
├── pool/                        # .deb'ler — SADECE <100 MB ise (şu an boş, bilerek)
├── proxy/                       # Cloudflare Worker: /pool/* -> Release 302
│   ├── worker.js
│   ├── wrangler.toml
│   └── README.md
├── scripts/
│   ├── update-repo.sh           # metadata üretici
│   └── check-repo.sh            # denetleyici
├── .github/workflows/update-repo.yml
├── index.html
└── .nojekyll
```

Yayın adresi: **https://mio-129.github.io/older-package/** (`main` / root)
