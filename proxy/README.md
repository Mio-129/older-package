# proxy/ — 228 MB'lık `.deb` için köprü (Cloudflare Worker)

## Neden bu klasör var?

Depo metadatası doğru ama `.deb` GitHub'da **depoda duramıyor**:

| Kısıt | Sonuç |
|---|---|
| GitHub tek dosya = **100 MB** | 239.610.838 baytlık `vs-code.deb` commit edilemez |
| GitHub Pages = statik, yönlendirme yok | `pool/vs-code.deb` → **404** (senin aldığın hata) |
| apt `Filename` alanı | absolute URL kabul etmez, base URL'e ekler → Release linki yazılamaz |

Bu worker iki satırlık bir köprü kurar:

```
/      ve /dists/...  ->  https://mio-129.github.io/older-package/...   (proxy)
/pool/<dosya>         ->  https://github.com/Mio-129/older-package/releases/latest/download/<dosya>   (302)
```

apt 302'yi takip eder, 239 MB'ı doğrudan GitHub'dan indirir → `pkg install vs-code`
komutu **çalışır**. Ücretsiz plan yeterli (yönlendirme yaptığı için trafik worker'dan geçmez).

## Kurulum — yol 1: tarayıcıdan (telefondan bile olur)

1. <https://dash.cloudflare.com> → ücretsiz hesap → **Workers & Pages** → **Create** →
   **Worker** → isim: `older-package` → **Deploy**.
2. **Edit code** → `proxy/worker.js` içeriğinin tamamını yapıştır → **Deploy**.
3. Üstteki URL'i not al: `https://older-package.<hesabın>.workers.dev`
4. Termux'ta:

```bash
pkg update
mkdir -p $PREFIX/etc/apt/sources.list.d
rm -f $PREFIX/etc/apt/sources.list.d/older.list            # varsa mükerrer dosyayı sil
echo "deb [trusted=yes arch=aarch64] https://older-package.<hesabın>.workers.dev/ stable main" \
  > $PREFIX/etc/apt/sources.list.d/older-package.list
pkg update
apt-cache policy vs-code                                   # Candidate: 1.0.0
pkg install vs-code
```

Farklı bir Worker adresi/alan adı kullanacaksan `PAGES_BASE` ve `POOL_BASE`
değişkenlerini Worker ayarlarından (`Settings → Variables`) değiştir.

## Kurulum — yol 2: wrangler CLI

```bash
cd proxy
npx wrangler deploy            # giriş: npx wrangler login
```

`wrangler.toml` içindeki `POOL_BASE` varsayılan olarak
`releases/latest/download` kullanır; yani **yeni Release yüklediğinde worker'ı
güncellemen gerekmez**. Belirli bir sürüme sabitlemek istersen:

```bash
npx wrangler deploy --var POOL_BASE:https://github.com/Mio-129/older-package/releases/download/1.0.0
```

## Doğrulama

```bash
BASE=https://older-package.<hesabın>.workers.dev
curl -sI $BASE/dists/stable/Release      | head -1   # 200
curl -sI $BASE/pool/vs-code.deb          | grep -i '^location'   # 302 -> github.com/.../vs-code.deb
curl -sL -o /dev/null -w '%{http_code} %{size_download}\n' $BASE/pool/vs-code.deb   # 200 239610838
```

Depo tarafını da denetleyebilirsin:

```bash
./scripts/check-repo.sh --base-url "$BASE/"
```

## Alternatifler

- **Cloudflare Pages / Netlify**: `POOL_MODE=redirect ./scripts/update-repo.sh`
  `_redirects` dosyası üretir; siteyi oraya yayınlarsın (GitHub Pages `_redirects`
  desteklemez).
- **Hiç uğraşmadan**: `.deb`'i elle kur (bkz. ana README, "Elle kurulum").
  Zaten bu paket Termux'ta glibc/bionic uyuşmazlığı yüzünden çalışmayabilir —
  ana README'deki `code-oss` notuna bak.
