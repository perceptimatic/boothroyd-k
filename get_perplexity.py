# Copyright 2024 Michael Ong
# Apache 2.0

# Calculates the perplexity of utterances in a given trn file (no default) 
# using a given kenlm language model (no default)
# then writes to a given output file (no default)

# trn files have the format:
# utterance (file_name)
# kenlm models are n-gram language models

# e.g. python get_perplexity.py \
#               5gram.arpa \
#               data/boothroyd/noise/train/trn_char \
#               data/boothroyd/noise/train/perplexity_5gram.arpa
# calculates the perplexity of the utterances in data/boothroyd/noise/train/trn_char using the lm 5gram.arpa
# then places the results in data/boothroyd/noise/train/perplexity_5gram.arpa

# the perplexity file has the following (tab-separated) format:
# perplexity    utterance   (file_name)

import kenlm
import sys

lm_file_path = sys.argv[1]
trn_file = sys.argv[2]
out_path = sys.argv[3]

model = kenlm.Model(lm_file_path)

out = open(out_path, "w")

with open(trn_file, "r") as f:
    for line in f:
        sentence, file = line.rsplit(maxsplit=1)
        perp = model.perplexity(sentence)
        out.write(f"{perp:.1f}\t{sentence}\t{file}\n")
out.close()
f.close()
