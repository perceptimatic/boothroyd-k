#! /usr/bin/env bash

# Copyright 2024 Sean Robertson, Michael Ong
# Apache 2.0

# Calculates the k value (as described by boothroyd) for the given datasets 

export PYTHONUTF8=1
[ -f "path.sh" ] && . "path.sh"

usage="Usage: $0 [-h] [-D] [-S STR] [-O STR] [-d DIR] [-p DIR] [-P FILE]
[-o DIR] [-n DIR] [-N DIR] [-t DIR] [-L INT] [-H INT] [-l NAT] [-x FILE] [-k STR]"
delete_wavs=false
decode_script=
decode_script_opts=
data=
partitions=()
perplexity_lm=
perplexity_filepath=
k_opts=
out_dir=data/boothroyd
norm_wavs_out_dir=norm
noise_wavs_out_dir=noise
trns_out_dir=trns
snr_low=-10
snr_high=30
lm_ord=0
help="Determine the k value for a given model.
The data directory should contain either wavs + a trn file,
or wavs + corresponding txt files

Options
    -h          Display this help message and exit
    -D          Deletes the wav files in the noise dir after decoding (default: '$delete_wavs')
    -S STR      The decoding script (default: '$decode_script')
    -O STR      Options for the decoding script (default: '$decode_script_opts')
    -d DIR      The data directory (default: '$data_dir')
    -p DIR      The partition(s) of the data directory that the k value will be calculated for (default: '$partitions')
    -P FILE     The kenlm language model used to calculate the perplexity (default: '$perplexity_lm')
    -o DIR      The output directory (default: '$out_dir')
    -n DIR      The output subdirectory for the normalized wav files (default: '$out_dir/$norm_wavs_out_dir')
    -N DIR      The output subdirectory for the normalized wav files
                with added noise (default: '$out_dir/$noise_wavs_out_dir')
    -t DIR      The output subdirectory for the decoded hypothesis trn files (default: '$out_dir/$trns_out_dir')
    -L INT      The lower bound (inclusive) of signal-to-noise ratio (SNR) in dB (default: '$snr_low')
    -H INT      The upper bound (inclusive) of signal-to-noise ratio (SNR) in dB (default: '$snr_high')
    -l NAT      n-gram LM order (default: '$lm_ord')
    -x FILE     The path to the perplexity file (default: '$perplexity_filepath')
    -k STR      Options for the k calculation script (default: '$k_opts')"

while getopts "hDS:O:d:p:P:o:n:N:t:L:H:l:x:k:" name; do
    case $name in
        h)
            echo "$usage"
            echo ""
            echo "$help"
            exit 0;;
        D)
            delete_wavs=true;;
        S)
            decode_script="$OPTARG";;
        O)
            decode_script_opts="$OPTARG";;
        d)
            data="$OPTARG";;
        p)
            partitions+=("$OPTARG");;
        P)
            perplexity_lm="$OPTARG";;
        o)
            out_dir="$OPTARG";;
        n)
            norm_wavs_out_dir="$OPTARG";;
        N)
            noise_wavs_out_dir="$OPTARG";;
        t)
            trns_out_dir="$OPTARG";;
        L)
            snr_low="$OPTARG";;
        H)
            snr_high="$OPTARG";;
        l)
            lm_ord="$OPTARG";;
        x)
            perplexity_filepath="$OPTARG";;
        k)
            k_opts="$OPTARG";;
        *)
            echo -e "$usage"
            exit 1;;
    esac
done
shift "$(($OPTIND - 1))"
if [ -z "$decode_script" ]; then
    echo -e "'$decode_script' has not been assigned! set -S appropriately!"
    exit 1
fi
if [ ! -d "$data" ]; then
    echo -e "'$data' is not a directory! set -d appropriately!"
    exit 1
fi
if (( ${#partitions[@]} == 0 )); then
    echo -e "No partitions of '$data' have been provided! set -p appropriately!"
    exit 1
fi
for part in "${partitions[@]}"; do
    if [ ! -d "$data/$part" ]; then
        echo -e "'$part' does not exist as a subdirectory of '$data'! set -d or -p appropriately!"
        exit 1
    fi
done
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
if ! mkdir -p "$out_dir/$trns_out_dir" 2> /dev/null; then
    echo -e "Could not create '$out_dir/$trns_out_dir'! set -t appropriately!"
    exit 1
fi
if ! [[ "$snr_low" =~ ^-?[0-9]+\.?[0-9]*$ ]] 2> /dev/null; then
    echo -e "$snr_low is not a real number! set -L appropriately, or add a leading zero!"
    exit 1
fi
if ! [[ "$snr_high" =~ ^-?[0-9]+\.?[0-9]*$ ]] 2> /dev/null; then
    echo -e "$snr_high is not a real number! set -H appropriately, or add a leading zero!"
    exit 1
fi
if ! [[ "$(bc -l <<< "$snr_low <= $snr_high")" -ne 0 ]]; then
    echo -e "$snr_low is greater than $snr_high! set -L and -H appropriately!"
    exit 1
fi
if ! [ "$lm_ord" -ge 0 ] 2> /dev/null; then
    echo -e "$lm_ord is not a non-negative int! set -l appropriately!"
    exit 1
fi
if [ -z "$perplexity_filepath" ]; then
    echo -e "-x has not been set, so the perplexity will be calculated for each partition"
    echo -e "and the results will be placed in the following location(s):"
    for part in "${partitions[@]}"; do
        echo -e "$out_dir/$noise_wavs_out_dir/$part/"
    done
fi
if [ ! -f "$perplexity_filepath" ]; then
    echo -e "'$perplexity_filepath' is not a file, so the perplexity will be calculated and the result will be placed in this location"
    if [ ! -f "$perplexity_lm" ]; then
        if [ ! $lm_ord -ge 2 ]; then
        echo -e "'$perplexity_lm' is not a file! set -P appropriately!"
        echo -e "If you want to train an n-gram language model and use it for the perplexity calculation, set -l to be greater than 1."
        exit 1
        fi
        echo -e "'$perplexity_lm' is not a file, but -l is greater than 1, so the perplexity calculation will train an n-gram language model and use it."
    fi
fi

set -eo pipefail

for part in "${partitions[@]}"; do
    # Data prep -------------------------------------------------
    mkdir -p "$out_dir/$norm_wavs_out_dir/$part"
    mkdir -p "$out_dir/$noise_wavs_out_dir/$part"
    mkdir -p "$out_dir/$trns_out_dir/$part"

    if ! [ -f "$out_dir/$norm_wavs_out_dir/$part/.done" ]; then
        # Normalize data volume to same reference average RMS
        bash normalize_data_volume.sh -d "$data/$part" -o "$out_dir/$norm_wavs_out_dir/$part"
        touch "$out_dir/$norm_wavs_out_dir/$part/.done"
    fi

    if ! [ -f "$data/$part/trn" ]; then
        :> "$data/$part/trn"
        for file in "$data"/"$part"/*.wav; do
            filename="$(basename "$file" .wav)"
            printf "%s (%s)\n" "$(< "${file%%.wav}.txt")" "$filename" >> "$data/$part/trn"
        done
    fi

    if ! [ -f "$out_dir/$noise_wavs_out_dir/$part/trn_char" ]; then
        awk \
        'BEGIN {
            FS = " ";
            OFS = " ";
        }

        {
            filename = $NF;
            NF --;
            gsub(/ /, "_");
            gsub(/\S/, "& ");
            gsub(/ +/, " ");
            print $0 filename;
        }' "$data/$part/trn" > "$out_dir/$noise_wavs_out_dir/$part/trn_char"
    fi

    for snr in $(seq $snr_low $snr_high); do
        spart="$out_dir/$noise_wavs_out_dir/$part/snr${snr}"
        if ! [[ -f "$spart/.done_noise" || -f "$spart/.done_split" ]]; then
            bash add_noise.sh -d "$out_dir/$norm_wavs_out_dir/$part" -s "$snr" \
            -o "$out_dir/$noise_wavs_out_dir/$part"
            touch "$spart/.done_noise"
        fi

        # Decoding -------------------------------------------------

        spart_trn="$out_dir/$trns_out_dir/$part/snr$snr.trn"
        if [ ! -f "$spart_trn" ]; then
            . "$decode_script" $decode_script_opts "$spart" > "$spart_trn"
        fi
        
        if $delete_wavs; then
            rm -rf "$spart"
            mkdir -p "$spart"
        fi
        
        # k calculation -------------------------------------------------
        if [ ! -f "$perplexity_lm" ] && [ ! -f "$perplexity_filepath" ]; then
            echo "Training a $lm_ord-gram language model on the train set..."
            python3 ngram_lm.py -o $lm_ord -t 0 1 <<< "$(awk '{NF--; print $0}' "$out_dir/$noise_wavs_out_dir/train/trn_char")" > "${lm_ord}gram.arpa_"
            mv "${lm_ord}gram.arpa"{_,}
            perplexity_lm="${lm_ord}gram.arpa"
        fi

        if [ ! -f "$perplexity_filepath" ]; then
            if [ -z "$perplexity_filepath" ]; then
                perplexity_filepath="$out_dir/$noise_wavs_out_dir/$part/perplexity_$(basename $perplexity_lm)"
            fi
            python3 get_perplexity.py \
            "$perplexity_lm" "$out_dir/$noise_wavs_out_dir/$part/trn_char" "$perplexity_filepath"
        fi

        if [ ! -f "$spart/.done_split" ]; then
            bash section_data.sh \
            "$perplexity_filepath" \
            "$spart_trn" 3 "$spart"
            echo -e "split using: $perplexity_filepath" > "$spart/.done_split"
        fi
    done

    python3 get_snr_k.py $k_opts "$out_dir/$noise_wavs_out_dir/$part"
done