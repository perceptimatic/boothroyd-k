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
