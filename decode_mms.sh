#! /usr/bin/env bash

# Copyright 2024 Sean Robertson, Michael Ong
# Apache 2.0

export PYTHONUTF8=1
[ -f "path.sh" ] && . "path.sh"

usage="Usage: $0 [-h] [-m DIR] [-d DIR] [-o DIR] [-p DIR] [-n DIR] [-N DIR] [-S INT]
[-w NAT] [-a NAT] [-B NAT] [-l NAT]"
model=exp/mms_lsah
data=
part=
out_dir=data/boothroyd
norm_wavs_out_dir=norm
noise_wavs_out_dir=noise
snr=
width=100
alpha_inv=1
beta=1
lm_ord=0
help="Decode data with an MMS model that has already been trained 

Options
    -h          Display this help message and exit
    -m DIR      The model directory (default: '$model')
    -d DIR      The data directory (default: '$data_dir')
    -p DIR      The partition name (default: '$part')
    -o DIR      The output directory (default: '$out_dir')
    -n DIR      The output subdirectory for the normalized wav files (default: '$out_dir/$norm_wavs_out_dir')
    -N DIR      The output subdirectory for the normalized wav files
                with added noise (default: '$out_dir/$noise_wavs_out_dir')
    -S INT      The current SNR value in dB (default: '$snr')
    -w NAT      pyctcdecode's beam width (default: $width)
    -a NAT      pyctcdecode's alpha, inverted (default: $alpha_inv)
    -B NAT      pyctcdecode's beta (default: $beta)
    -l NAT      n-gram LM order. 0 is greedy; 1 is prefix with no LM (default: $lm_ord)"

while getopts "hm:d:p:o:n:N:S:w:a:B:l:" name; do
    case $name in
        h)
            echo "$usage"
            echo ""
            echo "$help"
            exit 0;;
        m)
            model="$OPTARG";;
        d)
            data="$OPTARG";;
        p)
            part="$OPTARG";;
        o)
            out_dir="$OPTARG";;
        n)
            norm_wavs_out_dir="$OPTARG";;
        N)
            noise_wavs_out_dir="$OPTARG";;
        S)
            snr="$OPTARG";;
        w)
            width="$OPTARG";;
        a)
            alpha_inv="$OPTARG";;
        B)
            beta="$OPTARG";;
        l)
            lm_ord="$OPTARG";;
        *)
            echo -e "$usage"
            exit 1;;
    esac
done
shift $(($OPTIND - 1))
if [ ! -d "$model" ]; then
    echo -e "'$model' is not a directory! set -m appropriately!"
    exit 1
fi
if [ ! -d "$data" ]; then
    echo -e "'$data' is not a directory! set -d appropriately!"
    exit 1
fi
if grep -v "$part" <<< "$data"; then
    echo -e "'$part' is not a parent folder of '$data'! set -d and -p appropriately!"
    exit 1
fi
if ! mkdir -p "$out_dir" 2> /dev/null; then
    echo -e "Could not create '$out_dir'! set -o appropriately!"
    exit 1
fi
if ! mkdir -p "$out_dir/$norm_wavs_out_dir" 2> /dev/null; then
    echo -e "Could not create '$out_dir/$norm_wavs_out_dir'! set -n appropriately!"
    exit 1
fi
if ! mkdir -p "$out_dir/$noise_wavs_out_dir" 2> /dev/null; then
    echo -e "Could not create '$out_dir/$noise_wavs_out_dir'! set -N appropriately!"
    exit 1
fi
if ! [[ "$snr" =~ ^-?[0-9]+\.?[0-9]*$ ]] 2> /dev/null; then
    echo -e "$snr is not a real number! set -S appropriately, or add a leading zero!"
    exit 1
fi
if ! [ "$width" -gt 0 ] 2> /dev/null; then
    echo -e "$width is not a natural number! set -w appropriately!"
    exit 1
fi
if ! [ "$alpha_inv" -gt 0 ] 2> /dev/null; then
    echo -e "$alpha_inv is not a natural number! set -a appropriately!"
    exit 1
fi
if (( "$(bc -l <<< "$beta < 0")" )); then
    echo -e "$beta is not greater than 0! set -B appropriately!"
    exit 1
fi
if ! [ "$lm_ord" -ge 0 ] 2> /dev/null; then
    echo -e "$lm_ord is not a non-negative int! set -l appropriately!"
    exit 1
fi

if [ "$lm_ord" = 0 ]; then
    name="greedy"

    if  ! [ -f "$model/k_decode/${part}/${name}/snr${snr}_${name}.trn" ]; then
        echo "Greedily decoding '$data'"
        mkdir -p "$model/k_decode/$part/$name"
        python3 decode/mms/decode.py decode \
            "$model" "$data" "$model/k_decode/${part}/${name}/snr${snr}_${name}.csv_"
        mv "$model/k_decode/${part}/${name}/snr${snr}_${name}.csv"{_,}
        awk \
        'BEGIN {
            FS = ","
        }
        
        NR >= 2 {
            sub(/\.wav/, "", $1);
            print $2 " (" $1 ")"
        }' "$model/k_decode/${part}/${name}/snr${snr}_${name}.csv" \
        > "$model/k_decode/${part}/${name}/snr${snr}_${name}.trn_"
        mv "$model/k_decode/${part}/${name}/snr${snr}_${name}.trn"{_,}
    fi
else
    if [ ! -f "prep/ngram_lm.py" ]; then
        echo "Initializing Git submodule"
        git submodule update --init --remote prep
    fi
    if  ! [ -f "$model/k_decode/logits/${part}_snr${snr}/.done" ]; then
        echo "Dumping logits of '$spart'"
        mkdir -p "$model/k_decode/logits/${part}_snr${snr}"
        python3 ./mms.py decode --logits-dir "$model/k_decode/logits/${part}_snr${snr}" \
            "$model" "$spart" "/dev/null"
        touch "$model/k_decode/logits/${part}_snr${snr}/.done"
    fi

    if [ "$lm_ord" = 1 ]; then
        name="w${width}_nolm"
        alpha_inv=1
        beta=1
        lm_args=( )
    else
        name="w${width}_lm${lm_ord}_ainv${alpha_inv}_b${beta}"
        lm="$model/lm/${lm_ord}gram.arpa"
        lm_args=( --lm "$lm" )
        if ! [ -f "$lm" ]; then
            echo "Constructing '$lm'"
            mkdir -p "$model/lm"
            python3 ./prep/ngram_lm.py -o $lm_ord -t 0 1 < "etc/lm_text.txt" > "${lm}_"
            mv "$lm"{_,}
        fi
    fi

    if ! [ -f "$model/token2id" ]; then
        echo "Constructing '$model/token2id'"
        python3 ./mms.py vocab-to-token2id "$model/"{vocab.json,token2id}
    fi

    if ! [ -f "$model/k_decode/${part}/${name}/snr${snr}_${name}.trn" ]; then
        echo "Decoding $spart"
        mkdir -p "$model/k_decode/${part}/${name}"
        python3 ./prep/logits-to-trn-via-pyctcdecode.py \
            --char "${lm_args[@]}" \
            --words "etc/lm_words.txt" \
            --width $width \
            --beta $beta \
            --alpha-inv $alpha_inv \
            --token2id "$model/token2id" \
            "$model/k_decode/logits/${part}_snr${snr}" "$model/k_decode/${part}/${name}/snr${snr}_${name}.trn"
    fi
fi























pass
$lm_ord
$name
$model
$part
$snr
$spart
$alpha_inv
$beta

