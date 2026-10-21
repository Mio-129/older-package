# older-package — Termux APT deposu

`pkg install vs-code` çalışmıyordu. Sebep paket eksikliği değil, **depo metadatasının
hatalı olması**ydı. Aşağıda neyin bozuk olduğu ve nasıl düzeltildiği var.

Yayın adresi: **https://mio-129.github.io/older-package/** (GitHub Pages, `main` / root)

## Kurulum (Termux)

```bash
pkg update
mkdir -p $PREFIX/etc/apt/sources.list.d
echo "deb [trusted=yes arch=aarch64] https://mio-129.github.io/older-package/ stable main" \
  > $PREFIX/etc/apt/sources.list.d/older-package.list
pkg update

pkg search vs-code        # listede görünmeli
apt-cache policy vs-code  # Candidate: 1.0.0
pkg install vs-code
```

> `sources.list` eklerken `arch=aarch64` yazmak zorunlu değil ama mimari uyuşmazlığı
> uyarılarını engeller. Depo imzasız olduğu için `trusted=yes` şart.

## Neden `pkg install vs-code` hiçbir şey indirmiyordu?

| # | Hata | Sonuç |
|---|------|-------|
| 1 | `Packages` içinde `Architecture: arm64` yazıyordu | Termux'ta dpkg mimarisi **`aarch64`**'tir. `arm64` yazan paket aarch64 indeksine girmez → `E: Unable to locate package vs-code` |
| 2 | `Filename: https://github.com/.../vs-code.deb` (absolute URL) | apt `Filename`'i **base URL'e göre relatif yol** olarak kullanır. İstek `https://mio-129.github.io/older-package/https://github.com/...` olur → 404. Yani Release asset'i doğrudan bu alana yazılamaz |
| 3 | `dists/stable/Release` dosyası yoktu | apt Release ile indeks bütünlüğünü doğrular; yoksa/hash yanlışsa indeksi yok sayar |
| 4 | Sadece `dists/stable/main/binary-aarch64/` vardı, `Packages` bir de `SHA256` alanı yoktu | apt indirdiği `.deb`'in bütünlüğünü doğrulayamaz |
| 5 | Yanlış konumdaki kopya: `older-package/dists/stable/main/binary-all/Packages` (içinde sadece `vs code` / `vs-code.deb` metni) ve `d.txt` | Pages kökünde `dists/` olması gerekir; iç içe `older-package/` klasörü ve `binary-all` indeksi işe yaramaz |
| 6 | `.nojekyll` yoktu | Jekyll `dists/` altındaki dosyaları işleyip bozabilir/dışlayabilir |

Ayrıca ikinci büyük engel: **`.deb` 228 MB**. GitHub Pages/git tek dosya için **100 MB**
sınırı koyar, yani bu dosya depoya konup Pages'ten servis edilemez. apt de başka bir
host'tan (Release URL'si) indirmeye izin vermediği için (madde 2) bir çözüm gerekiyor —
aşağıdaki "Pool modları" bölümü.

## Ne düzeltildi

- `Packages` artık `Architecture: aarch64`, `Filename: pool/vs-code.deb`, `Size` ve
  `SHA256` alanlarıyla üretiliyor (Release asset'inin gerçek boyutu ve sha256'sı).
- `dists/stable/Release` (MD5Sum + SHA256) eklendi.
- `Packages.gz` doğru içerikle yeniden üretildi.
- Hatalı `older-package/...` kopyası ve `d.txt` silindi.
- `.nojekyll` eklendi, `index.html` kurulum sayfası eklendi.
- Metadatayı Release'ten otomatik üreten `scripts/update-repo.sh` + GitHub Actions
  (`.github/workflows/update-repo.yml`) eklendi.

## Pool modları (`.deb` nereden inecek?)

`Filename: pool/vs-code.deb` her zaman relatif kalır; fark dosyanın nasıl servis edildiği:

### 1) `POOL_MODE=local` (varsayılan)
`.deb` `pool/` içine indirilir ve depoya commit edilir.
GitHub Pages'ten çalışır — **ancak dosya 100 MB'tan küçükse**.

```bash
./scripts/update-repo.sh          # Release'ten indirir, pool/ + dists/ güncellenir
git add -A && git commit -m "repo: update" && git push
```

### 2) `POOL_MODE=redirect` (GitHub Pages ile 228 MB için çalışmaz)
`pool/vs-code.deb` isteğini Release asset'ine 302 ile yönlendiren `_redirects` üretir.
apt 302'yi takip eder. Bu dosyayı **sadece Cloudflare Pages / Netlify** destekler;
**GitHub Pages `_redirects` desteklemez**.

```bash
POOL_MODE=redirect ./scripts/update-repo.sh
```

Aynı işi GitHub Pages üzerinde yapmanın yolu küçük bir Cloudflare Worker / kendi
sunucun / R2 kovası: `https://<host>/pool/vs-code.deb` → GitHub Release asset'ine 302.
Sonra `sources.list`'te base URL'i o host'a çevir.

### 3) Elle kurulum (bugün çalışan yol)
```bash
curl -L -o $TMPDIR/vs-code.deb \
  https://github.com/Mio-129/older-package/releases/download/1.0.0/vs-code.deb
pkg install ./vs-code.deb
```

## Önemli uyarı: bu `.deb` Termux'ta çalışmayabilir

Ubuntu/Debian için derlenmiş bir VS Code `.deb`'i **glibc** bekler; Termux **bionic
libc** kullanır. Mimari (`aarch64`) uysa bile `Error: cannot link executable` /
eksik `lib*` hataları alınır. Termux için doğru yol:

```bash
pkg install x11-repo
pkg install code-oss        # Termux'un resmî code-oss paketi (X11 gerekir)
```

Bedava ve bakımı kolay çözüm bu; kendi deponu yayınlamak istiyorsan `.deb`'i Termux
için (`termux-packages` `x11-packages/code-oss` tarifine göre) derlemen gerekir.

## Dosya düzeni

```
.
├── dists/stable/
│   ├── Release
│   └── main/binary-aarch64/Packages(.gz)
├── pool/                        # .deb'ler (local modda)
├── scripts/update-repo.sh       # metadata üretici
├── .github/workflows/update-repo.yml
├── index.html                   # Pages ana sayfası
└── .nojekyll
```

## Depoyu güncelleme

Release'e yeni `.deb` yüklediğinde Actions workflow'u (`release: published`)
otomatik çalışır. Elle:

```bash
TAG=v1.0.1 ./scripts/update-repo.sh
```

Gerekli araçlar: `curl`, `jq`, `gzip`, `sha256sum`.
