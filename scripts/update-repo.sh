#!/usr/bin/env bash
#
# older-package apt deposu üreticisi
# ----------------------------------
# GitHub Release'lerindeki .deb dosyalarını okuyup Termux'un beklediği
#   dists/<dist>/<component>/binary-<arch>/Packages(.gz)
#   dists/<dist>/Release
# dosyalarını üretir.
#
# ÖNEMLİ: apt, Packages içindeki "Filename" alanını base URL'e göre
# RELATİF bir yol olarak kullanır. Absolute URL yazmak çalışmaz
# (apt "https://..." kısmını da base URL'e ekler ve 404 alır).
# Bu yüzden .deb'ler depo ile aynı adreste yayınlanmalı.
#
# Kullanım:
#   ./scripts/update-repo.sh                    # latest release, pool/ içine indir
#   DOWNLOAD=0 ./scripts/update-repo.sh         # indirme yok (Release API size+digest)
#   TAG=v1.0.0 ./scripts/update-repo.sh         # belirli release
#
#   POOL_MODE=local      (varsayılan) .deb pool/ içinde durur, git'e girer.
#                        100 MB'tan büyük .deb'de hata verir (GitHub sınırı).
#   POOL_MODE=redirect   .deb git'e girmez; bunun yerine "pool/<adi>" isteklerini
#                        GitHub Release asset'ine 302 ile yönlendiren bir
#                        "_redirects" dosyası üretir (Cloudflare Pages / Netlify).
#                        GitHub Pages _redirects desteklemez!
#   POOL_MODE=proxy      .deb git'e girmez, indirilmez. Metadata aynı kalır
#                        (Filename: pool/<adi>); yönlendirmeyi proxy/ altındaki
#                        Cloudflare Worker yapar. Kaynak adresi olarak worker'ın
#                        host'u kullanılır. Bkz. proxy/README.md
#
set -euo pipefail

REPO="${REPO:-Mio-129/older-package}"
DIST="${DIST:-stable}"
COMPONENT="${COMPONENT:-main}"
# DİKKAT: Termux'ta dpkg mimarisi "aarch64"tir, "arm64" DEĞİL.
# "arm64" yazılırsa apt paketi hiç görmez -> "Unable to locate package".
ARCH="${ARCH:-aarch64}"
TAG="${TAG:-latest}"
DOWNLOAD="${DOWNLOAD:-1}"
POOL_MODE="${POOL_MODE:-local}"
# GitHub 100 MB'tan buyuk dosyayi depoya kabul etmez (git push reddeder).
# Bu yuzden pool/ icine konabilecek en buyuk .deb 100 MB'tir; asan dosya
# GitHub Pages'te 404 verir. Asagidaki sinir bunu erkenden yakalar.
MAX_LOCAL_BYTES="${MAX_LOCAL_BYTES:-104857600}"
case "$POOL_MODE" in
  local|redirect|proxy) ;;
  *) echo "HATA: POOL_MODE '$POOL_MODE' gecersiz (local|redirect|proxy)" >&2; exit 1 ;;
esac
MAINTAINER="${MAINTAINER:-Mio-129 <290256825+Mio-129@users.noreply.github.com>}"
PACKAGE_DESCRIPTION="${PACKAGE_DESCRIPTION:-Visual Studio Code for Termux}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISTDIR="$ROOT/dists/$DIST"
BINDIR="$DISTDIR/$COMPONENT/binary-$ARCH"
POOLDIR="$ROOT/pool"
API="https://api.github.com/repos/$REPO"

command -v curl >/dev/null || { echo "HATA: curl gerekli (pkg install curl)" >&2; exit 1; }
command -v jq   >/dev/null || { echo "HATA: jq gerekli (pkg install jq)"   >&2; exit 1; }

api_get() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$1"
  fi
}

echo ">> Release bilgisi alınıyor ($REPO, tag=$TAG)"
if [ "$TAG" = "latest" ]; then
  REL_JSON="$(api_get "$API/releases/latest")"
else
  REL_JSON="$(api_get "$API/releases/tags/$TAG")"
fi

REL_TAG="$(jq -r '.tag_name' <<<"$REL_JSON")"
VERSION="${REL_TAG#v}"   # 1.0.0
echo "   tag=$REL_TAG  surum=$VERSION"

mapfile -t ASSETS < <(
  jq -r '.assets[]
         | select(.name | endswith(".deb"))
         | [.name, (.size|tostring), (.digest // ""), .browser_download_url]
         | @tsv' <<<"$REL_JSON"
)
if [ "${#ASSETS[@]}" -eq 0 ]; then
  echo "HATA: '$REL_TAG' release'inde .deb asset yok. Once .deb'i Release'e yukle." >&2
  exit 1
fi

mkdir -p "$BINDIR" "$POOLDIR"
PKGS="$BINDIR/Packages"
: > "$PKGS.tmp"
REDIRECTS=""
[ "$POOL_MODE" = "redirect" ] && REDIRECTS="$ROOT/_redirects" && : > "$REDIRECTS"

for row in "${ASSETS[@]}"; do
  IFS=$'\t' read -r name size digest url <<<"$row"
  # paket adı: "vs-code.deb" -> "vs-code"
  # (sadece "ad_1.2.3_aarch64.deb" gibi sürüm ekini at, "vs_code" bozulmasın)
  pkg="$(sed -E 's/_[0-9][^_]*$//' <<<"${name%.deb}")"

  # --- 100 MB siniri: pool/ icine giremeyecek dosyayi indekse YAZMA ---
  if [ "$POOL_MODE" = "local" ] && [ "$size" -gt "$MAX_LOCAL_BYTES" ]; then
    {
      echo "HATA: $name = $size bayt ($(awk -v b="$size" 'BEGIN{printf "%.1f", b/1048576}') MB)"
      echo "      GitHub tek dosya icin 100 MB siniri koyar; bu dosya depoya giremez,"
      echo "      dolayisiyla Pages'te pool/$name adresi 404 doner."
      echo "      (apt: 'Failed to fetch .../pool/$name 404 Not Found')"
      echo
      echo "      Secenekler:"
      echo "      1) Worker proxy (metadata Pages'te kalir, /pool/* -> Release 302):"
      echo "           POOL_MODE=proxy ./scripts/update-repo.sh      # proxy/README.md"
      echo "      2) Cloudflare Pages / Netlify (_redirects uretir):"
      echo "           POOL_MODE=redirect ./scripts/update-repo.sh"
      echo "      3) Depo olmadan elle kurulum:"
      echo "           curl -L -o \$TMPDIR/$name $url && pkg install \$TMPDIR/$name"
      echo
      echo "      (MAX_LOCAL_BYTES ile sinir degistirilebilir ama git yine reddeder.)"
    } >&2
    exit 2
  fi

  if [ "$DOWNLOAD" = "1" ] && [ "$POOL_MODE" = "local" ]; then
    if [ ! -f "$POOLDIR/$name" ]; then
      echo ">> Indiriliyor: $name ($size bayt)"
      curl -fL --retry 3 --retry-delay 2 -o "$POOLDIR/$name.part" "$url"
      mv "$POOLDIR/$name.part" "$POOLDIR/$name"
    else
      echo ">> Zaten var: pool/$name"
    fi
    size="$(stat -c %s "$POOLDIR/$name")"
    digest="sha256:$(sha256sum "$POOLDIR/$name" | cut -d' ' -f1)"
  fi

  if [ "$POOL_MODE" = "redirect" ]; then
    printf '/pool/%s %s 302\n' "$name" "$url" >> "$REDIRECTS"
    echo ">> redirect: /pool/$name -> $url"
  fi

  if [ "$POOL_MODE" = "proxy" ]; then
    echo ">> proxy: /pool/$name istegi worker tarafindan su adrese yonlendirilecek:"
    echo "          $url"
  fi

  if [ -z "$digest" ]; then
    echo "HATA: $name icin SHA256 yok (Release API 'digest' bos). DOWNLOAD=1 dene." >&2
    exit 1
  fi
  sha="${digest#sha256:}"

  {
    echo "Package: $pkg"
    echo "Version: $VERSION"
    echo "Architecture: $ARCH"
    echo "Maintainer: $MAINTAINER"
    echo "Priority: optional"
    echo "Section: devel"
    echo "Filename: pool/$name"
    echo "Size: $size"
    echo "SHA256: $sha"
    echo "Description: $PACKAGE_DESCRIPTION"
    echo " Termux (aarch64) icin hazirlanmis $pkg paketi."
    echo
  } >> "$PKGS.tmp"

  echo "   + $pkg $VERSION ($ARCH)  -> pool/$name"
done

mv "$PKGS.tmp" "$PKGS"

echo ">> Packages.gz uretiliyor"
gzip -9n -c "$PKGS" > "$PKGS.gz"

echo ">> Release uretiliyor"
{
  echo "Origin: older-package"
  echo "Label: older-package"
  echo "Suite: $DIST"
  echo "Codename: $DIST"
  echo "Architectures: $ARCH"
  echo "Components: $COMPONENT"
  echo "Description: Termux icin older-package deposu"
  echo "Date: $(LC_ALL=C date -Ru)"
  echo "MD5Sum:"
  for f in "$PKGS" "$PKGS.gz"; do
    printf " %s %s %s\n" "$(md5sum "$f" | cut -d' ' -f1)" "$(stat -c %s "$f")" "${f#"$DISTDIR"/}"
  done
  echo "SHA256:"
  for f in "$PKGS" "$PKGS.gz"; do
    printf " %s %s %s\n" "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c %s "$f")" "${f#"$DISTDIR"/}"
  done
} > "$DISTDIR/Release"

echo ">> Bitti: dists/$DIST (surum $VERSION, mod: $POOL_MODE)"
if [ "$POOL_MODE" = "local" ]; then
  echo "   pool/ icerigi git'e eklenmeli: git add -A && git commit && git push"
else
  echo "   pool/ bilerek bos. /pool/* yonlendirmesini barindiran host'u kullan"
  echo "   (proxy/README.md veya _redirects). Denetim: ./scripts/check-repo.sh --offline"
fi
