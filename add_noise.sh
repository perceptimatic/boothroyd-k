#! /usr/bin/env bash

# Copyright 2024 Sean Robertson, Michael Ong
# Apache 2.0

# Generates a given type of noise (default: whitenoise) with sox 
# and places it a subdirectory of the given output directory (no default) called "noise", 
# then mixes the noise with the .wav files in the given data directory (no default)
# at the given SNR (in dB) (no default) and outputs the mixed .wav files 
# into subdirectories of the output directory labelled with the given SNR

# e.g. bash add_noise.sh -n pinknoise -d data/boothroyd/norm/train -s 10 -o data/boothroyd/noise/train
# would create a pink noise file and place it in data/boothroyd/noise/train/noise
# then mix the generated pink noise with the .wav files in data/boothroyd/norm/train with an SNR of 10 dB
# and place the mixed .wav files in data/boothroyd/noise/train/snr10

echo "$0 $*"

usage="Usage: $0 [-h] [-n TYPE] [-d DIR] [-s REAL] [-o DIR]"
noise_type=whitenoise
data_dir=
snr=
out_dir=
help="Adds generated noise to .wav files

Options
    -h          Display this help message and exit
    -n TYPE     The type of noise generated with the sox synth
                command (default: '$noise_type')
    -d DIR      The data directory (default: '$data_dir')
    -s REAL     The signal to noise ratio in dB (default: '$snr')
    -o DIR      The output directory (default: '$out_dir')"

while getopts "hn:d:s:o:" name; do
    case $name in
        h)
            echo "$usage"
            echo ""
            echo "$help"
            exit 0;;
        n)
            noise_type="$OPTARG";;
        d)
            data_dir="$OPTARG";;
        s)
            snr="$OPTARG";;
        o)
            out_dir="$OPTARG";;
        *)
            echo -e "$usage"
            exit 1;;
    esac
done
shift $(($OPTIND - 1))
if [ ! -d "$data_dir" ]; then
    echo -e "'$data_dir' is not a directory! Set -d appropriately!"
    exit 1
fi
if ! mkdir -p "$out_dir" 2> /dev/null; then
    echo -e "Could not create '$out_dir'! set -o appropriately!"
    exit 1
fi
if ! [ "$(grep -Ew "sine|square|triangle|sawtooth|trapezium|exp|(|white|pink|brown)noise" <<< "$noise_type")" ] 2> /dev/null; then
    echo -e "$noise_type is not a valid noise type! set -n appropriately!"
    exit 1
fi
if ! [[ "$snr" =~ ^-?[0-9]+\.?[0-9]*$ ]] 2> /dev/null; then
    echo -e "$snr is not a real number! set -s appropriately, or add a leading zero!"
    exit 1
fi

set -eo pipefail

mkdir -p "$out_dir/noise"
mkdir -p "$out_dir/snr${snr}"

max_dur=0

for file in "$data_dir"/*.wav; do
  file_dur="$(soxi -D "$file")"
  max_dur="$(bc -l <<< "if ($file_dur > $max_dur) {$file_dur;} else {$max_dur;}")"
done

full_noise_file="$out_dir/noise/${noise_type}_${max_dur}.wav"

# -R flag should keep this file the same, no matter how many times it's
# called
sox -R -r 16k -n $full_noise_file synth $max_dur $noise_type

for file in "$data_dir"/*.wav; do
  filename="$(basename "$file")"
  file_dur="$(soxi -D "$file")"
  trimmed_noise_rms_amp="$(sox "$full_noise_file" -n trim 0 "$file_dur" stat 2>&1 | awk '/RMS\s+amplitude:/ {print $3}')"
  file_rms_amp="$(sox "$file" -n stat 2>&1 | awk '/RMS\s+amplitude:/ {print $3}')"
  # calculates $file_rms_amp / ((10^($snr / 20)))
  target_rms_amp="$(bc -l <<< "$file_rms_amp / e(l(10) * ($snr / 20))")"
  vol_shift="$(bc -l <<< "$target_rms_amp / $trimmed_noise_rms_amp")"
  out_path="$out_dir/snr${snr}/$filename"

  sox -r 16k -m "$file" -v "$vol_shift" "$full_noise_file" -t wav "$out_path" trim 0 "$file_dur"
done