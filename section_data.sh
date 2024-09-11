#! /usr/bin/env bash

# Copyright 2024 Michael Ong
# Apache 2.0

# Finds the utterances in the given perplexity file (no default) 
# that correspond to the utterances in the given hypothesis trn file (no default),
# then removes the utterances with the top and bottom 5% perplexities before
# splitting the given files evenly by perplexity
# into the given number of bins (no default)
# and placeing the resulting hypothesis and reference trn files 
# into subdirectories of the given output directory (no default)

# The format of the hypothesis trn file is:
# utterance (file_name)

# the perplexity file has the following (tab-separated) format:
# perplexity    utterance   (file_name)
# (this is the format of the files that are created by the script get_perplexity.py)

# e.g. bash section_data.sh \
#           data/boothroyd/noise/train/perplexity_5gram.arpa \
#           data/boothroyd/trns/train/snr-10.trn \
#           3 \
#           data/boothroyd/noise/train/snr-10
# takes the perplexity file data/boothroyd/noise/train/perplexity_5gram.arpa 
# and the hypothesis trn file data/boothroyd/trns/train/snr-10.trn, 
# isolates the utterances with perplexities in the 5th to 95th percentile,
# then splits the perplexity file and the hypothesis trn file into 3 ref.trn files and 3 hyp.trn files, respectively
# before placing these files in data/boothroyd/noise/train/snr-10/{1,2,3}

# bin N contains the utterances with perplexities
# falling between the (5 + 90/(N-1))th percentile and the (5 + 90/N)th percentile


if [ $# -ne 4 ]; then
    echo "Usage: $0 perp_file hypothesis_trn_file num-to-split out-dir"
    exit 1
fi

perp_file="$1"
hyp_trn="$2"
ns="$3"
out_dir="$4"

if [ ! -f "$perp_file" ]; then
    echo "'$perp_file' is not a file"
    exit 1
fi

if [ ! -f "$hyp_trn" ]; then
    echo "'$hyp_trn' is not a file"
    exit 1
fi

if ! [ "$ns" -ge 0 ] 2> /dev/null; then
    echo -e "'$ns' is not a non-negative int"
    exit 1
fi

if [ ! -d "$out_dir" ]; then
    echo "'$out_dir' is not a directory"
    exit 1
fi

set -eo pipefail

if [ "$(wc -l <<< "$(grep -F "$(awk '{print $NF}' "$hyp_trn")" "$perp_file")")" -ne $(wc -l < "$hyp_trn") ]; then
    echo -e "'$perp_file' is missing utterances correpsonding to the following utterances in '$hyp_trn':"
    grep -vF "$(awk '{print $NF}' "$perp_file")" "$hyp_trn"
    exit 1
fi

for i in $(seq 1 $ns); do
    mkdir -p "$out_dir/$i"
done

grep -F "$(awk '{print $NF}' "$hyp_trn")" "$perp_file" |
awk '{print $0"\t"NR}' |
sort -n -k 1,1 |
awk -v ns="$ns" -v lines="$(wc -l < "$hyp_trn")" -v filename="$(basename "$perp_file")" -v out_dir="$out_dir" \
'BEGIN {
    FS = "\t";
    OFS = " ";
}

NR == FNR {
    cut = 0.05;

    for (i = 1; i <= ns; i++) {
        out_ref_path = out_dir "/" i "/ref.trn"
        if ((NR >= (lines * cut)) && (NR <= (lines * (1 - cut)))) {
            if ((NR > ((lines * (1 - 2 * cut)) * ((i - 1) / ns) + (lines * cut))) && (NR <= ((lines * (1 - 2 * cut)) * (i / ns) + (lines * cut)))) {
                print $4 "\t" $2, $3 > out_ref_path;
                ind_name = sprintf("%s_%s", $4, i);
                extract[ind_name] = "x";
            }
        }
    }
}

NR != FNR {
    for (i = 1; i <= ns; i++) {
        out_hyp_path = out_dir "/" i "/hyp.trn"
        for (ind_name in extract) {
            if (ind_name == FNR "_" i) {
                print $0 > out_hyp_path;
                delete extract[ind_name];
                next;
            }
            else {
                continue
            }
        }
    }
}' "-" "$hyp_trn"

for file in "$out_dir"/*/hyp.trn; do
    sort -nk 1,1 "$file" |
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
    }' > "$file"_
    mv "$file"{_,}
done

for file in "$out_dir"/*/ref.trn; do
    sort -nk 1,1 "$file" |
    awk 'BEGIN {FS = "\t"} {print $2}' > "$file"_
    mv "$file"{_,}
done