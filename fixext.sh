#!/bin/bash
#
# fixext.sh - fix image/video/audio extensions based on actual file contents.
# Run with -h for usage and the full list of formats and rules.
#
# How it works: each file is identified from its magic bytes (strict signatures,
# no `file` / ImageMagick) and renamed in place if its extension is wrong.
# Anything not identified with certainty is left untouched. Files are never
# converted, moved or overwritten.
#
# Layout: option parsing -> helpers -> format validators -> detect() -> main loop
#
# needs: bash 4.4+, find, head, od, tr, dd, wc

LC_ALL=C
export LC_ALL

usage() {
    cat <<'EOF'
fixext.sh - fix image/video/audio file extensions based on actual file contents

usage: fixext.sh [-n] [-r] [-h]      (any order; short flags can be combined: -rn)

  -n, --dry-run     show what would change, rename nothing
  -r, --recursive   also process subdirectories (hidden dirs are skipped)
  -h, --help        show this help

What it does:
  Identifies each file by its magic bytes (not its name) and renames it so the
  extension matches the real format: lowercase and conventional (jpeg -> jpg,
  tiff -> tif). Files are only renamed in place, never converted, moved or
  overwritten. Anything not identified with certainty is left alone.

  Images  jpg png gif bmp tif webp heic avif ico cur psd psb jp2 jpx jpm j2k
          jxl dds hdr exr icns xcf qoi, raw: cr2 cr3 crw raf orf rw2 mrw x3f
  Video   mkv webm mp4 m4v mov 3gp 3g2 f4v mj2 avi mpg(vob) flv asf(wmv) ogv y4m
  Audio   mp3 mp2 mp1 aac flac wav aiff aifc ogg opus oga spx m4a m4b m4p f4a f4b
          wv ape mpc tta tak dsf dff amr awb au mid caf voc

How names are handled:
  - the old suffix is replaced only if it is a known media extension, otherwise
    the right one is appended: "a.v1" -> "a.v1.mp3", "noext" -> "noext.jpg"
  - ambiguous containers keep any extension valid for them and are only
    lowercased: mp4/m4a/m4v/mov, mkv/mka, wmv/wma/asf, ogg/opus/oga,
    aif/aiff, heic/heif, png/apng ...
  - duplicate markers are fine: "song.m4a (1)" -> "song.m4a (1).m4a"

Safety:
  - PROTECTED: unfinished downloads (.part .crdownload .download .!qB .aria2 ...)
    and backups (.bak .old .orig ~ .swp ...) are never touched
  - SKIP: a TIFF signature is shared by nef/arw/dng raws, so such a file is only
    renamed if it is already named .tif/.tiff, otherwise it is skipped
  - CONFLICT: the target name already exists, file left alone
  - hidden files, symlinks and directories are ignored

Output: one line per file (FIX, WOULD FIX, SKIP, PROTECTED, CONFLICT, ERROR),
then a summary (Changes, Conflicts, Skipped, Protected, Errors). Files that are
already correct or not recognized print nothing. Exit status is 1 if any Errors.
EOF
}

dry=0; recursive=0
for arg in "$@"; do
    case "$arg" in
        -h|--help)      usage; exit 0 ;;
        -n|--dry-run)   dry=1 ;;
        -r|--recursive) recursive=1 ;;
        -[nr][nr]*)     # combined short flags, e.g. -rn
            for (( i = 1; i < ${#arg}; i++ )); do
                case "${arg:i:1}" in
                    n) dry=1 ;;
                    r) recursive=1 ;;
                    *) usage >&2; exit 2 ;;
                esac
            done ;;
        *) printf 'unknown option: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

# suffixes that are safe to replace when the content says otherwise
KNOWN=" jpg jpeg jpe jfif png apng gif bmp dib tif tiff webp heic heif avif avifs ico cur psd psb jp2 j2k j2c jpc jpx jpf jpm jxl dds hdr exr icns xcf qoi bpg svg tga pcx pbm pgm ppm pnm pam xbm xpm wbmp raw cr2 cr3 crw nef nrw arw srf sr2 dng orf rw2 raf mrw x3f pef srw mp4 m4v m4a m4b m4p mov qt 3gp 3gpp 3g2 f4v f4a f4b mj2 mjp2 mkv mka mk3d mks webm weba avi mpg mpeg mpe m2v vob m2p flv wmv wma asf ogv ogg oga ogx opus spx y4m mp3 mp2 mp1 mpa aac flac wav wave aif aiff aifc wv ape mpc tta tak dsf dff amr awb au snd mid midi kar caf voc ts m2ts mts rm rmvb ra divx "

canon=""; accept=""; guard=""; R=0

# ret <canonical ext> <space separated list of exts that are fine as-is> [guard]
# guard = if set, only touch the file when its current ext is in this list
ret() { canon=$1; accept=$2; guard=${3-}; return 0; }

# numeric readers over the header hex ($hex belongs to detect(), dynamic scope)
u8()   { local s=${hex:$(($1 * 2)):2}; [ ${#s} -eq 2 ] || return 1; R=$((16#$s)); }
le16() { local s=${hex:$(($1 * 2)):4}; [ ${#s} -eq 4 ] || return 1; R=$((16#${s:2:2}${s:0:2})); }
le32() { local s=${hex:$(($1 * 2)):8}; [ ${#s} -eq 8 ] || return 1; R=$((16#${s:6:2}${s:4:2}${s:2:2}${s:0:2})); }
be32() { local s=${hex:$(($1 * 2)):8}; [ ${#s} -eq 8 ] || return 1; R=$((16#$s)); }

# hex of <count> bytes at byte <offset> of $f
hexat() { dd if="$f" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tx1 -v | tr -d ' \n'; }
fsize() { wc -c < "$f" | tr -d '[:space:]'; }

# names that must never be touched: unfinished downloads and backups.
# (a rename would break resume / the tool that owns the file)
PROTECT_RE='(\.(part|part\.met|part-frag[0-9]+|crdownload|crswap|download|downloading|partial|filepart|opdownload|unconfirmed|tmp|temp|aria2|ytdl|xltd|td|td\.cfg|fdmdownload|dtapart|dlm|rdl|bts|!sync|!qb|!ut|!bt|bc!|az!|bak[0-9]*|backup[0-9]*|bk|bkp|bck|bkup|old[0-9]*|orig[0-9]*|sav|save|saved|swp|swo|swx|rej|prev|previous|v[0-9]+|~[0-9]+~)|~)$|\.(tmp|temp|part|partial|download|crdownload)\.[a-z0-9]{1,5}$|\.f[0-9]+\.[a-z0-9]{1,5}$|^#.*#$'

is_protected() {
    local l=${f,,}
    [[ $l =~ $PROTECT_RE ]] && return 0
    # control file next to it means a downloader is still working on it
    [ -e "$f.aria2" ] || [ -e "$f.td.cfg" ] || [ -e "$f.xltd" ]
}

# ---------------------------------------------------------------- validators

is_bmp() {
    local size dib
    [ "${hex:12:8}" = 00000000 ] || return 1            # reserved
    le32 14 || return 1; dib=$R
    case $dib in 12|40|52|56|64|108|124) ;; *) return 1 ;; esac
    size=$(fsize)
    le32 10 || return 1                                  # pixel data offset
    (( R >= 14 + dib && R <= size ))
}

is_icocur() {   # $1: 1 = ico, 2 = cur
    local size n len off
    [ "${hex:0:8}" = "00000${1}00" ] || return 1
    le16 4 || return 1; n=$R
    (( n >= 1 && n <= 256 )) || return 1
    u8 9 && (( R == 0 )) || return 1                     # reserved byte, entry 1
    le32 14 || return 1; len=$R
    le32 18 || return 1; off=$R
    size=$(fsize)
    (( len > 0 && off >= 6 + 16 * n && off + len <= size ))
}

# MPEG audio frame header (8 hex chars) -> MPA_LAYER (1-3), MPA_LEN
mpa_len() {
    local h=$1 b1 b2 ver lay bi si pad sr bitrate
    local -a srt br
    [ ${#h} -eq 8 ] && [ "${h:0:2}" = ff ] || return 1
    b1=$((16#${h:2:2})); b2=$((16#${h:4:2}))
    (( (b1 & 0xE0) == 0xE0 )) || return 1
    ver=$(( (b1 >> 3) & 3 )); lay=$(( (b1 >> 1) & 3 ))
    bi=$(( b2 >> 4 )); si=$(( (b2 >> 2) & 3 )); pad=$(( (b2 >> 1) & 1 ))
    (( ver != 1 && lay != 0 && bi != 0 && bi != 15 && si != 3 )) || return 1
    case $ver in
        3) srt=(44100 48000 32000) ;;
        2) srt=(22050 24000 16000) ;;
        0) srt=(11025 12000 8000) ;;
    esac
    sr=${srt[si]}
    if (( ver == 3 )); then
        case $lay in
            3) br=(0 32 64 96 128 160 192 224 256 288 320 352 384 416 448) ;;
            2) br=(0 32 48 56 64 80 96 112 128 160 192 224 256 320 384) ;;
            1) br=(0 32 40 48 56 64 80 96 112 128 160 192 224 256 320) ;;
        esac
    else
        case $lay in
            3) br=(0 32 48 56 64 80 96 112 128 144 160 176 192 224 256) ;;
            *) br=(0 8 16 24 32 40 48 56 64 80 96 112 128 144 160) ;;
        esac
    fi
    bitrate=${br[bi]}
    case $lay in
        3) MPA_LAYER=1; MPA_LEN=$(( (12 * bitrate * 1000 / sr + pad) * 4 )) ;;
        2) MPA_LAYER=2; MPA_LEN=$(( 144 * bitrate * 1000 / sr + pad )) ;;
        1) MPA_LAYER=3
           if (( ver == 3 )); then MPA_LEN=$(( 144 * bitrate * 1000 / sr + pad ))
           else MPA_LEN=$(( 72 * bitrate * 1000 / sr + pad )); fi ;;
    esac
    (( MPA_LEN > 4 ))
}

# two consecutive valid MPEG audio frames starting at byte $1
mpa_check() {
    local l
    mpa_len "$(hexat "$1" 4)" || return 1
    l=$MPA_LAYER
    mpa_len "$(hexat $(( $1 + MPA_LEN )) 4)" || return 1
    [ "$MPA_LAYER" = "$l" ] || return 1
    MPA_LAYER=$l
}

# ADTS header (14 hex chars) -> ADTS_LEN
adts_len() {
    local h=$1 b1 b2 b3 b4 b5
    [ ${#h} -eq 14 ] && [ "${h:0:2}" = ff ] || return 1
    b1=$((16#${h:2:2})); b2=$((16#${h:4:2})); b3=$((16#${h:6:2}))
    b4=$((16#${h:8:2})); b5=$((16#${h:10:2}))
    (( (b1 & 0xF6) == 0xF0 )) || return 1                # sync + layer 00
    (( ((b2 >> 2) & 15) < 13 )) || return 1              # valid sample rate idx
    ADTS_LEN=$(( ((b3 & 3) << 11) | (b4 << 3) | (b5 >> 5) ))
    (( ADTS_LEN >= 7 ))
}

adts_check() {
    adts_len "$(hexat "$1" 7)" || return 1
    adts_len "$(hexat $(( $1 + ADTS_LEN )) 7)"
}

# byte offset just after an ID3v2 tag at start of file -> R
id3_end() {
    local ver flags s1 s2 s3 s4
    [ ${#hex} -ge 20 ] || return 1
    ver=${hex:6:2}
    case $ver in 02|03|04) ;; *) return 1 ;; esac
    flags=$((16#${hex:10:2}))
    s1=$((16#${hex:12:2})); s2=$((16#${hex:14:2}))
    s3=$((16#${hex:16:2})); s4=$((16#${hex:18:2}))
    (( s1 < 128 && s2 < 128 && s3 < 128 && s4 < 128 )) || return 1
    R=$(( 10 + ((s1 << 21) | (s2 << 14) | (s3 << 7) | s4) ))
    if [ "$ver" = 04 ] && (( flags & 0x10 )); then R=$(( R + 10 )); fi
    return 0
}

# audio stream starting at byte $1: flac / mp1-3 / aac (needs verified frames)
audio_at() {
    case "$(hexat "$1" 8)" in
        664c6143[08]0000022) ret flac "flac"; return 0 ;;
    esac
    if mpa_check "$1"; then
        case $MPA_LAYER in
            3) ret mp3 "mp3" ;;
            2) ret mp2 "mp2 mp3 mpa" ;;
            1) ret mp1 "mp1 mp3 mpa" ;;
        esac
        return 0
    fi
    if adts_check "$1"; then ret aac "aac"; return 0; fi
    return 1
}

# ISO base media (mp4 family, heic, avif, cr3...) via ftyp brands
detect_ftyp() {
    local bsz major brands=" " i end
    bsz=$((16#${hex:0:8}))
    (( bsz >= 16 )) || return 1
    major=${txt:8:4}
    end=$bsz; (( end > 512 )) && end=512
    for (( i = 16; i + 4 <= end; i += 4 )); do brands+="${txt:i:4} "; done
    case "$major" in
        "qt  ")                     ret mov  "mov qt" ;;
        "M4A ")                     ret m4a  "m4a m4b" ;;
        "M4B ")                     ret m4b  "m4b m4a" ;;
        "M4P ")                     ret m4p  "m4p" ;;
        "M4V "|M4VH|M4VP)           ret m4v  "m4v mp4" ;;
        "F4V ")                     ret f4v  "f4v mp4" ;;
        "F4A ")                     ret f4a  "f4a" ;;
        "F4B ")                     ret f4b  "f4b" ;;
        3gp?|3ge?|3gg?|3gs?)        ret 3gp  "3gp 3gpp mp4" ;;
        3g2?)                       ret 3g2  "3g2 3gp mp4" ;;
        "crx ")                     ret cr3  "cr3" ;;
        heic|heix|heim|heis|hevc|hevx|hevm|hevs) ret heic "heic heif" ;;
        avif|avis)                  ret avif "avif avifs" ;;
        mif1|msf1)
            case "$brands" in
                *" avif "*|*" avis "*)                       ret avif "avif avifs" ;;
                *" heic "*|*" heix "*|*" hevc "*|*" hevx "*) ret heic "heic heif" ;;
                *) return 1 ;;
            esac ;;
        mjp2|mj2s)                  ret mj2  "mj2 mjp2" ;;
        isom|iso[2-9]|mp41|mp42|avc1|dash|MSNV)
                                    ret mp4  "mp4 m4v m4a m4b m4p f4v f4a f4b mov 3gp 3g2" ;;
        *) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------- detection
# sets canon / accept / guard for "$f"; returns 1 if not identified

detect() {
    canon=""; accept=""; guard=""
    local hex txt o
    hex=$(head -c 512 -- "$f" 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
    [ ${#hex} -ge 24 ] || return 1                       # < 12 bytes: never guess
    txt=$(head -c 512 -- "$f" 2>/dev/null | tr -c '[:print:]' '.')

    case "$hex" in
        # ---------- images ----------
        ffd8ff*)                   ret jpg  "jpg"; return 0 ;;
        89504e470d0a1a0a*)         ret png  "png apng"; return 0 ;;
        474946383[79]61*)          ret gif  "gif"; return 0 ;;
        384250530001000000000000*) ret psd  "psd"; return 0 ;;
        384250530002000000000000*) ret psb  "psb"; return 0 ;;
        762f3101*)                 ret exr  "exr"; return 0 ;;
        444453207c000000*)         ret dds  "dds"; return 0 ;;
        ff4fff51*)                 ret j2k  "j2k j2c jpc"; return 0 ;;
        0000000c6a5020200d0a870a????????667479706a703220*) ret jp2 "jp2"; return 0 ;;
        0000000c6a5020200d0a870a????????667479706a707820*) ret jpx "jpx jpf"; return 0 ;;
        0000000c6a5020200d0a870a????????667479706a706d20*) ret jpm "jpm"; return 0 ;;
        0000000c4a584c200d0a870a*) ret jxl  "jxl"; return 0 ;;
        424d*)    is_bmp      && { ret bmp "bmp dib"; return 0; }; return 1 ;;
        00000100*) is_icocur 1 && { ret ico "ico"; return 0; }; return 1 ;;
        00000200*) is_icocur 2 && { ret cur "cur"; return 0; }; return 1 ;;
        # camera raw. tiff-based raws (nef, arw, dng...) share the tiff header,
        # so a tiff signature only ever touches files already named tif/tiff
        49492a00????????43520200*) ret cr2  "cr2"; return 0 ;;
        49492a00*|4d4d002a*|49492b00*|4d4d002b*) ret tif "tif" "tif tiff"; return 0 ;;
        49495500*)                 ret rw2  "rw2"; return 0 ;;
        4949524f*|49495253*)       ret orf  "orf"; return 0 ;;
        004d524d*)                 ret mrw  "mrw"; return 0 ;;
        464f5662*)                 ret x3f  "x3f"; return 0 ;;
        49491a0000004845415043434452*) ret crw "crw"; return 0 ;;

        # ---------- video ----------
        1a45dfa3*)                                       # EBML: matroska / webm
            [[ $hex =~ ^(..)*4282886d6174726f736b61 ]] && { ret mkv  "mkv mka mk3d mks"; return 0; }
            [[ $hex =~ ^(..)*4282847765626d ]]         && { ret webm "webm weba"; return 0; }
            return 1 ;;
        000001ba*)                                       # MPEG program stream
            u8 4 && { (( (R & 0xC4) == 0x44 )) || (( (R & 0xF1) == 0x21 )); } \
                && { ret mpg "mpg mpeg mpe vob m2p"; return 0; }
            return 1 ;;
        464c5601*)                                       # FLV
            u8 4 && (( R != 0 && (R & 0xFA) == 0 )) && [ "${hex:10:8}" = 00000009 ] \
                && { ret flv "flv"; return 0; }
            return 1 ;;
        3026b2758e66cf11a6d900aa0062ce6c*) ret asf "asf wmv wma"; return 0 ;;
        4f676753*)                                       # Ogg: look at first packet
            u8 4 && (( R == 0 )) || return 1
            u8 5 && (( R & 2 )) || return 1
            u8 26 && (( R >= 1 )) || return 1
            o=$(( 27 + R ))
            case "${hex:$((o * 2)):14}" in
                01766f72626973) ret ogg "ogg oga"; return 0 ;;
            esac
            case "${hex:$((o * 2)):10}" in
                7f464c4143)     ret oga "oga ogg"; return 0 ;;
            esac
            case "${hex:$((o * 2)):14}" in
                807468656f7261) ret ogv "ogv ogg"; return 0 ;;
            esac
            case "${txt:o:8}" in
                OpusHead)       ret opus "opus ogg oga"; return 0 ;;
                "Speex   ")     ret spx  "spx ogg oga"; return 0 ;;
            esac
            return 1 ;;

        # ---------- audio ----------
        664c6143[08]0000022*)      ret flac "flac"; return 0 ;;
        4d54686400000006000[012]*) ret mid  "mid midi kar"; return 0 ;;
        636166660001*)             ret caf  "caf"; return 0 ;;
        2321414d520a*)             ret amr  "amr"; return 0 ;;
        2321414d522d57420a*)       ret awb  "awb"; return 0 ;;
        4d502b07*|4d502b17*)       ret mpc  "mpc"; return 0 ;;
        2e736e64*)                                       # Sun/NeXT .au
            be32 4 && (( R >= 24 )) && be32 12 && (( R >= 1 && R <= 27 )) \
                && be32 20 && (( R >= 1 && R <= 256 )) && { ret au "au snd"; return 0; }
            return 1 ;;
        494433*)                                         # ID3v2: look past the tag
            id3_end && audio_at "$R"; return ;;
        ff*)                                             # bare mpeg audio / adts
            audio_at 0; return ;;
    esac

    # ---------- ascii signatures ----------
    case "$txt" in
        "FUJIFILMCCD-RAW "*)       ret raf  "raf"; return 0 ;;
        "gimp xcf "*)              ret xcf  "xcf"; return 0 ;;
        "#?RADIANCE."*|"#?RGBE."*) ret hdr  "hdr"; return 0 ;;
        "YUV4MPEG2 "*)             ret y4m  "y4m"; return 0 ;;
        "Creative Voice File"*)
            [ "${hex:38:2}" = 1a ] && { ret voc "voc"; return 0; }
            return 1 ;;
    esac

    case "${txt:0:4}" in
        RIFF)
            case "${txt:8:4}" in
                WEBP)    ret webp "webp"; return 0 ;;
                "AVI ")  ret avi  "avi";  return 0 ;;
                WAVE)    ret wav  "wav";  return 0 ;;
            esac
            return 1 ;;
        RF64|BW64)
            [ "${txt:8:4}" = WAVE ] && { ret wav "wav"; return 0; }
            return 1 ;;
        FORM)
            case "${txt:8:4}" in
                AIFF) ret aiff "aiff aif"; return 0 ;;
                AIFC) ret aifc "aifc aif"; return 0 ;;
            esac
            return 1 ;;
        FRM8)
            [ "${txt:12:4}" = "DSD " ] && { ret dff "dff"; return 0; }
            return 1 ;;
        "DSD ")
            [ "${hex:8:16}" = 1c00000000000000 ] && { ret dsf "dsf"; return 0; }
            return 1 ;;
        icns)
            be32 4 && [ "$R" = "$(fsize)" ] && { ret icns "icns"; return 0; }
            return 1 ;;
        qoif)
            be32 4 && (( R > 0 )) && be32 8 && (( R > 0 )) \
                && u8 12 && (( R == 3 || R == 4 )) && u8 13 && (( R <= 1 )) \
                && { ret qoi "qoi"; return 0; }
            return 1 ;;
        wvpk)
            u8 8 && (( R >= 2 && R <= 16 )) && u8 9 && (( R == 4 )) \
                && { ret wv "wv"; return 0; }
            return 1 ;;
        "MAC ")
            le16 4 && (( R >= 3800 && R <= 4200 )) && { ret ape "ape"; return 0; }
            return 1 ;;
        MPCK)
            [ "${txt:4:2}" = SH ] && { ret mpc "mpc"; return 0; }
            return 1 ;;
        TTA1)
            u8 4 && (( R >= 1 && R <= 3 )) && u8 5 && (( R == 0 )) \
                && { ret tta "tta"; return 0; }
            return 1 ;;
        tBaK)    ret tak "tak"; return 0 ;;
    esac

    [ "${txt:4:4}" = ftyp ] && { detect_ftyp; return; }
    return 1
}

# ---------------------------------------------------------------- main loop

# start dir, and the script's own path so it never renames itself
start=$PWD
selfpath=$(cd "$(dirname -- "$0")" 2>/dev/null && printf '%s/%s' "$PWD" "${0##*/}")
changes=0; conflicts=0; skipped=0; protected=0; errors=0

# regular files only (find -type f skips symlinks and dirs); hidden files and
# hidden dirs are pruned; without -r stay in the start dir
findopts=(-mindepth 1)
(( recursive )) || findopts+=(-maxdepth 1)

# collect the list first so renames can't disturb the traversal
mapfile -d '' files < <(find "$start" "${findopts[@]}" -name '.*' -prune -o -type f -print0)

for path in "${files[@]}"; do
    [ "$path" = "$selfpath" ] && continue
    # work inside the file's own dir so $f is a plain relative name
    dir=${path%/*}; f=${path##*/}
    cd -- "$dir" 2>/dev/null || continue
    pre=${dir#"$start"}; pre=${pre#/}; [ -n "$pre" ] && pre="$pre/"   # prefix for printed paths

    detect || continue          # not a recognized media file: leave it alone

    # unfinished download or backup: never touch
    if is_protected; then
        printf 'PROTECTED (partial download/backup): %s\n' "$pre$f"
        protected=$((protected + 1))
        continue
    fi

    # split name into base + (known media) extension
    base=$f; cur=""
    if [[ $f == *. ]]; then
        base=${f%.}
    elif [[ $f == *.* ]]; then
        suffix=${f##*.}; lc=${suffix,,}
        if [[ "$KNOWN" == *" $lc "* ]]; then cur=$lc; base=${f%.*}; fi
    fi
    [ -n "$base" ] || continue

    # tiff-signature guard: only rename files already named tif/tiff
    if [ -n "$guard" ] && [[ " $guard " != *" $cur "* ]]; then
        printf 'SKIP (ambiguous %s signature): %s\n' "$canon" "$pre$f"
        skipped=$((skipped + 1))
        continue
    fi

    # current ext is valid for this format: keep it (lowercased), else use the canonical one
    if [ -n "$cur" ] && [[ " $accept " == *" $cur "* ]]; then
        target=$cur
    else
        target=$canon
    fi

    newname="$base.$target"
    [ "$newname" = "$f" ] && continue        # already correct

    # never overwrite (a pure case change on a case-insensitive fs is the same file)
    if [ -e "$newname" ] && ! { [ "${newname,,}" = "${f,,}" ] && [ "$newname" -ef "$f" ]; }; then
        printf 'CONFLICT: %s -> %s\n' "$pre$f" "$pre$newname"
        conflicts=$((conflicts + 1))
        continue
    fi

    if (( dry )); then
        printf 'WOULD FIX: %s -> %s\n' "$pre$f" "$pre$newname"
        changes=$((changes + 1))
    else
        if mv -- "$f" "$newname"; then
            printf 'FIX: %s -> %s\n' "$pre$f" "$pre$newname"
            changes=$((changes + 1))
        else
            printf 'ERROR: could not rename %s\n' "$pre$f"
            errors=$((errors + 1))
        fi
    fi
done

# summary (exit status 1 if any rename failed)
if (( dry )); then label='Would change'; else label='Changes'; fi
printf '\n%s: %d\nConflicts: %d\nSkipped: %d\nProtected: %d\nErrors: %d\nDone\n' "$label" "$changes" "$conflicts" "$skipped" "$protected" "$errors"
(( errors == 0 ))
