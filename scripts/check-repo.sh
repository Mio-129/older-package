#!/usr/bin/env bash
#
# older-package depo denetleyicisi
# -------------------------------
# "apt neden 404 alıyor?" sorusunu metadata'ya bakarak cevaplar.
#
# Denetlenenler:
#   1) dists/<dist>/Release içindeki SHA256/MD5 değerleri gerçek dosyalarla uyuşuyor mu?
#   2) Packages içindeki her Filename adresi gerçekten indirilebiliyor mu (HTTP 200)?
#   3) Size / SHA256 alanları sunucudaki dosyayla uyuşuyor mu?
#
# Kullanım:
#   ./scripts/check-repo.sh                     # ağ kontrolü + Release kontrolü
#   ./scripts/check-repo.sh --offline           # sadece yerel dosyalar (CI için)
#   ./scripts/check-repo.sh --require-pool      # pool/<dosya> diskte olmak ZORUNDA
#   ./scripts/check-repo.sh --base-url https://example.com/repo/
#   ./scripts/check-repo.sh --root /yol/depo        # başka bir kopyayı denetle
#
# Ortam değişkenleri: DIST, COMPONENT, ARCH, BASE_URL
#
set -uo pipefail

REPO="${REPO:-Mio-129/older-package}"
DIST="${DIST:-stable}"
COMPONENT="${COMPONENT:-main}"
ARCH="${ARCH:-aarch64}"
BASE_URL="${BASE_URL:-https://mio-129.github.io/older-package/}"

OFFLINE=0
REQUIRE_POOL=0
ROOT_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --offline)      OFFLINE=1 ;;
    --require-pool) REQUIRE_POOL=1 ;;
    --base-url)     BASE_URL="${2:?--base-url bir deger ister}"; shift ;;
    --root)         ROOT_OVERRIDE="${2:?--root bir dizin ister}"; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "HATA: bilinmeyen arguman: $1" >&2; exit 1 ;;
  esac
  shift
done

case "$BASE_URL" in */) ;; *) BASE_URL="$BASE_URL/" ;; esac

ROOT="${ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -d "$ROOT" ] || { echo "HATA: --root dizini yok: $ROOT" >&2; exit 1; }
DISTDIR="$ROOT/dists/$DIST"
BINDIR="$DISTDIR/$COMPONENT/binary-$ARCH"
PKGS="$BINDIR/Packages"
POOLDIR="$ROOT/pool"

ERRORS=0
WARNINGS=0
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; WARNINGS=$((WARNINGS+1)); }
bad()  { echo "  ✗ $*"; ERRORS=$((ERRORS+1)); }

[ -f "$PKGS" ] || { echo "HATA: $PKGS yok" >&2; exit 1; }

echo "== Depo: $ROOT (dist=$DIST component=$COMPONENT arch=$ARCH)"
echo "== Base URL: $BASE_URL"
[ "$OFFLINE" = 1 ] && echo "== Mod: offline"

# ---------- 1) Release bütünlüğü ----------
RELEASE="$DISTDIR/Release"
if [ -f "$RELEASE" ]; then
  echo "== Release kontrolu"
  if grep -q '^SHA256:' "$RELEASE"; then
    awk '/^SHA256:/{f=1;next} /^[A-Za-z]+:/{f=0} f && NF==3 {print $1"\t"$3}' "$RELEASE" |
    while IFS=$'\t' read -r want rel; do
      f="$DISTDIR/$rel"
      if [ ! -f "$f" ]; then
        echo "  ✗ Release '$rel' diyor ama dosya yok"
        exit 1
      fi
      got="$(sha256sum "$f" | cut -d' ' -f1)"
      if [ "$got" = "$want" ]; then
        echo "  ✓ SHA256 $rel"
      else
        echo "  ✗ SHA256 uyusmuyor: $rel (Release=$want dosya=$got) — Release'i yeniden uret"
        exit 1
      fi
    done || ERRORS=$((ERRORS+1))
  else
    warn "Release icinde SHA256 bolumu yok — apt indeksi dogrulayamaz"
  fi
else
  bad "dists/$DIST/Release yok — apt bu depoyu yok sayar"
fi

# ---------- 2) Paket bazlı kontroller ----------
echo "== Paketler"
STANZAS="$(awk 'BEGIN{RS="";FS="\n"} {
    pkg=""; fn=""; sz=""; sha="";
    for (i=1;i<=NF;i++) {
      if      ($i ~ /^Package: /)  pkg=substr($i,10);
      else if ($i ~ /^Filename: /) fn=substr($i,11);
      else if ($i ~ /^Size: /)     sz=substr($i,7);
      else if ($i ~ /^SHA256: /)   sha=substr($i,9);
    }
    if (pkg != "") print pkg"\t"fn"\t"sz"\t"sha;
  }' "$PKGS")"

if [ -z "$STANZAS" ]; then
  warn "Packages bos — 'pkg install <paket>' hicbir sey bulamaz"
fi

while IFS=$'\t' read -r pkg fn sz sha; do
  [ -n "${pkg:-}" ] || continue
  echo "  - $pkg  (Filename: $fn, Size: ${sz:-?})"

  case "$fn" in
    http://*|https://*)
      bad "$pkg: Filename absolute URL. apt bunu base URL'e EKLER ve 404 alir -> relatif yol yaz" ;;
    /*)
      warn "$pkg: Filename '/' ile basliyor; sunucuda kok yol olarak cozulur" ;;
  esac

  case "$fn" in
    pool/*)
      local_file="$POOLDIR/${fn#pool/}"
      if [ -f "$local_file" ]; then
        real_size="$(stat -c %s "$local_file")"
        if [ -n "$sz" ] && [ "$real_size" != "$sz" ]; then
          bad "$pkg: pool boyutu uyusmuyor (Packages=$sz, dosya=$real_size)"
        else
          ok "$pkg: pool/${fn#pool/} diskte var ($real_size bayt)"
        fi
      elif [ "$REQUIRE_POOL" = 1 ]; then
        bad "$pkg: pool/${fn#pool/} YOK — apt 'Failed to fetch ... 404 Not Found' alir"
      else
        warn "$pkg: pool/${fn#pool/} diskte yok (proxy/redirect modunda normal)"
      fi
      ;;
  esac

  if [ "$OFFLINE" = 0 ]; then
    url="${BASE_URL}${fn}"
    resp="$(curl -sL -o /dev/null -r 0-0 --max-time 60 -w '%{http_code} %{size_download}' "$url" 2>/dev/null)"
    code="${resp%% *}"
    case "${code:-000}" in
      200|206) ok "$pkg: indirilebilir ($url)" ;;
      000)     bad "$pkg: $url adresine ulasilamadi (DNS/ag/sandbox kisiti)" ;;
      404)     bad "$pkg: HTTP 404 — $url sunucuda YOK (apt bunu indiremez)" ;;
      *)       bad "$pkg: $url -> HTTP ${code}" ;;
    esac
  fi
done <<<"$STANZAS"

echo
if [ "$ERRORS" -gt 0 ]; then
  echo "SONUC: $ERRORS hata, $WARNINGS uyari — depo apt tarafinda calismaz."
  exit 1
fi
echo "SONUC: hata yok, $WARNINGS uyari."
exit 0
