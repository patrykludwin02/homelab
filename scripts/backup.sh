#!/bin/bash
# Kopia zapasowa homelab:
#   1. zrzut bazy Immich (pg_dumpall, gzip)
#   2. archiwum repozytorium + CONFIG_ROOT (jeśli leży poza repo) + wolumeny Dockera
#   3. lustro biblioteki zdjęć Immich na karcie SD
#   4. rotacja archiwów starszych niż RETENTION_DAYS
#
# Skrypt przerywa działanie przy pierwszym błędzie i niczego nie usuwa,
# jeśli backup się nie udał.
set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:-/home/homelab/homelab}"
SD_MOUNT="${SD_MOUNT:-/mnt/karta_sd}"
BACKUP_DIR="${BACKUP_DIR:-$SD_MOUNT/backupy}"
PHOTOS_BACKUP_DIR="${PHOTOS_BACKUP_DIR:-$SD_MOUNT/immich_library}"
DB_CONTAINER="${DB_CONTAINER:-immich_postgres}"
DOCKER_VOLUMES="${DOCKER_VOLUMES:-portainer_portainer_data}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

DATE=$(date +"%Y-%m-%d_%H-%M")
ARCHIVE="$BACKUP_DIR/homelab_config_$DATE.tar.gz"
DUMP="$SOURCE_DIR/immich/database_dump.sql.gz"

VOL_DIR="$(mktemp -d)"
cleanup() { rm -rf "$VOL_DIR"; rm -f "$DUMP.tmp" "$ARCHIVE.tmp"; }
trap cleanup EXIT

log() { echo "[$(date +'%F %T')] $*"; }
die() { log "BŁĄD: $*" >&2; exit 1; }

# Wartość zmiennej z pliku .env (bez cudzysłowów); pusty wynik, gdy brak
env_value() {
    [ -f "$1" ] || return 0
    grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- | tr -d "\"'" || true
}

# Tylko jedna instancja naraz
exec 9>/tmp/homelab-backup.lock
flock -n 9 || die "poprzedni backup jeszcze trwa"

# --- Sprawdzenia wstępne ---------------------------------------------------
for cmd in docker rsync flock gzip; do
    command -v "$cmd" >/dev/null || die "brak polecenia: $cmd (sudo apt install rsync util-linux)"
done
mountpoint -q "$SD_MOUNT" || die "$SD_MOUNT nie jest zamontowany"
[ -w "$SD_MOUNT" ] || die "$SD_MOUNT jest tylko do odczytu (błąd karty SD?)"
[ -d "$SOURCE_DIR" ] || die "brak katalogu $SOURCE_DIR"
mkdir -p "$BACKUP_DIR"

IMMICH_ENV="$SOURCE_DIR/immich/.env"
MEDIA_ENV="$SOURCE_DIR/media-stack/.env"
DB_USER="$(env_value "$IMMICH_ENV" DB_USERNAME)"
DB_USER="${DB_USER:-postgres}"
UPLOAD_LOCATION="$(env_value "$IMMICH_ENV" UPLOAD_LOCATION)"
DB_DATA_LOCATION="$(env_value "$IMMICH_ENV" DB_DATA_LOCATION)"
CONFIG_ROOT="$(env_value "$MEDIA_ENV" CONFIG_ROOT)"
DATA_ROOT="$(env_value "$MEDIA_ENV" DATA_ROOT)"

# Ścieżki względne z .env liczą się od katalogu stosu
abs_path() { case "$2" in ""|/*) echo "$2" ;; *) echo "$SOURCE_DIR/$1/${2#./}" ;; esac; }
UPLOAD_LOCATION="$(abs_path immich "$UPLOAD_LOCATION")"
DB_DATA_LOCATION="$(abs_path immich "$DB_DATA_LOCATION")"

# --- 1. Zrzut bazy Immich --------------------------------------------------
log "Zrzut bazy Immich ($DB_CONTAINER)"
docker exec "$DB_CONTAINER" pg_dumpall --clean --if-exists -U "$DB_USER" | gzip > "$DUMP.tmp"
[ -s "$DUMP.tmp" ] || die "zrzut bazy jest pusty"
mv "$DUMP.tmp" "$DUMP"
chmod 600 "$DUMP"

# --- 2. Archiwum konfiguracji ----------------------------------------------
TAR_PATHS=( -C / "${SOURCE_DIR#/}" )
if [ -n "$CONFIG_ROOT" ] && [ -d "$CONFIG_ROOT" ]; then
    case "$CONFIG_ROOT/" in
        "$SOURCE_DIR"/*) ;;                       # już w repozytorium
        *) TAR_PATHS+=( "${CONFIG_ROOT#/}" ) ;;
    esac
fi

# Wolumeny Dockera (np. dane Portainera) lądują w archiwum jako osobne pliki
for vol in $DOCKER_VOLUMES; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        log "Wolumen $vol"
        docker run --rm -v "$vol":/v:ro -v "$VOL_DIR":/out alpine \
            tar czf "/out/volume_$vol.tar.gz" -C /v . \
            || log "OSTRZEŻENIE: nie udało się spakować wolumenu $vol"
    else
        log "Pomijam wolumen $vol (nie istnieje)"
    fi
done

log "Archiwum $ARCHIVE"
# Wykluczenia: dane multimedialne, żywe pliki PostgreSQL (jest zrzut) i biblioteka Immich
# (kopiowana osobno). Ścieżki z .env leżące w repozytorium są wykluczane automatycznie.
EXCLUDES=( --exclude='media-stack/data'
           --exclude="${SOURCE_DIR#/}/immich/postgres"
           --exclude="${SOURCE_DIR#/}/immich/library" )
for big in "$DATA_ROOT" "$UPLOAD_LOCATION" "$DB_DATA_LOCATION"; do
    case "$big/" in "$SOURCE_DIR"/?*) EXCLUDES+=( --exclude="${big#/}" ) ;; esac
done

# Kod 1 z tar ("plik zmienił się w trakcie") nie jest błędem, kod 2 (np. brak uprawnień) jest
rc=0
tar -czf "$ARCHIVE.tmp" "${EXCLUDES[@]}" "${TAR_PATHS[@]}" -C "$VOL_DIR" . || rc=$?
[ "$rc" -le 1 ] || die "tar zakończył się kodem $rc (brak uprawnień do części plików? uruchom skrypt jako root: sudo crontab -e)"
mv "$ARCHIVE.tmp" "$ARCHIVE"
chmod 600 "$ARCHIVE"

# --- 3. Biblioteka zdjęć Immich --------------------------------------------
if [ -n "$UPLOAD_LOCATION" ] && [ -d "$UPLOAD_LOCATION" ]; then
    # Zabezpieczenie przed lustrem z pustego katalogu (np. odmontowany dysk)
    [ -n "$(ls -A "$UPLOAD_LOCATION" 2>/dev/null)" ] || die "$UPLOAD_LOCATION jest pusty, pomijam rsync --delete"
    log "Zdjęcia: $UPLOAD_LOCATION -> $PHOTOS_BACKUP_DIR"
    mkdir -p "$PHOTOS_BACKUP_DIR"
    # thumbs/ i encoded-video/ Immich odtwarza sam
    rsync -a --delete --exclude='thumbs/' --exclude='encoded-video/' \
        "$UPLOAD_LOCATION"/ "$PHOTOS_BACKUP_DIR"/
else
    log "Pomijam zdjęcia (UPLOAD_LOCATION='$UPLOAD_LOCATION' nie istnieje)"
fi

# --- 4. Rotacja (dopiero po udanym backupie) -------------------------------
find "$BACKUP_DIR" -name "homelab_config_*.tar.gz" -type f -mtime +"$RETENTION_DAYS" -delete

log "Gotowe: $(du -h "$ARCHIVE" | cut -f1) $ARCHIVE"
