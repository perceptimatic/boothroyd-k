# Summary
This repository contains scripts used to calculate the textual predictability value k as described in https://arxiv.org/abs/2407.16537.

The primary script used for this purpose is run_k_value.sh, which does the following 4 steps:
1. Normalizes the provided .wav files and adds noise at various SNRs
2. Decodes the audio from step 1 using the user-provided decoding script
3. Sorts the utterances into textual predictability bins using the perplexity of each utterance
4. Calculates the k value for two pairs of bins

The user must provide the decoding script that is used in step 2.
For step 3, the user may provide a pre-made n-gram language model in order to calculate the perplexities, or a file containing the utterances and their perplexities. If these are not provided, then the script will prompt the user for the order of an n-gram model which it will construct from the data provided before using that model to calculate perplexities.

The script get_k_estimate.sh can also be run to estimate the k value at a single SNR point.
This script has the same options as run_k_value.sh, with the exception of -s (SNR), which replaces -L (SNR lower bound) and -H (SNR upper bound). 

# Installing
## Pip
``` bash
pip install -r requirements.txt
apt-get install bc
apt-get install sox
apt-get install awk
apt-get install python3-dev
```


# Data folder format
The data folder should contain .wav files with corresponding .txt transcript files that have the same name.
(For example, the transcript of the file utt01.wav should be called utt01.txt)
The .txt files in the data folder are expected to be word-level transcripts (i.e. spaces only occur between words), but phone or character level transcripts can also be used with some modifications to the analysis script (run_k_value.sh).

<details>
<summary>Using phone or character level transcripts</summary>
By default, run_k_value.sh takes in word-level transcripts (trn files) and turns them into character level transcripts (trn_char files).
<details>
<summary>Character level transcript details</summary>
In the character level transcripts that run_k_value.sh generates, each character is separated from its neighbour by a space and word boundaries are marked by underscores.
(for example, the word level transcript 'quick brown fox' would have the corresponding character level transrcipt 'q u i c k _ b r o w n _ f o x').
</details>
</details>

If the data folder has been split into different partitions, each partition should have its own subdirectory, and the transcript files for each .wav file in the partition should be located in the same subdirectory as their corresponding .wav file.
For example, if utt01.wav is located in the 'train' subdirectory, then utt01.txt should also be placed there.

# Running
The script used to obtain the k values is run_k_value.sh. Before running run_k_value.sh, you must create a bash decoding script.
By default, in run_k_value.sh this decoding script is passed a (possibly empty) string containg options and the path to a directory (that was generated earlier) that contains .wav files with added noise.
The decoding script must print to standard out.

Since the decoding script is executed with the 'source' command, if you want your decoding script to be able to handle options, OPTIND=1 must be set (in the decoding script) before parsing options.
The path to the decoding script is passed to run_k_value.sh with the '-S' flag.
The string containing the options given to the decoding script is passed to run_k_value.sh with the '-O' (capital o) flag, and it must be quoted in order to avoid being parsed by run_k_value.sh.

run_k_value.sh requires that you give it a partition of the data folder to run on with the flag '-p'. Multiple partitions can be given by placing the flag '-p' before each of them.
Example:
``` bash
run_k_value.sh -p train -p test -p dev
``` 

run_k_value.sh can accept the path to a premade perplexity file (which must contain perplexity for all utterances in all partitions) using the flag '-x'. 
If you do not provide a premade perplexity file (with '-x') or the path to a language model file for the perplexity calculation (using the flag '-P'), run_k_value.sh will ask for you to provide an order for the language model it will generate. The order of this language model is given to run_k_value.sh by using the flag '-l' (lowercase L).
When generating a language model, run_k_value.sh assumes the data folder has a partition called 'train'. It then uses the trn_char file that was generated for the train partition to create an n-gram lm with the order given by the '-l' flag.

If you need to save space, the '-D' flag deletes the .wav files that have had noise added to them, after they have been decoded.

Example call using a pre-made LM: 
``` bash
bash run_k_value.sh -S test_decode.sh -d data/raw -P 5gram.arpa -O "-a 100" -p train -p test -p dev -D 
```

Example call without a pre-made LM:
``` bash
bash run_k_value.sh -S test_decode.sh -d data/raw -l 4 -O "-a 100" -p train -p test -p dev -D
```

An estimate of the k value can also be obtained by using the script get_single_k.py, which uses the estimate (e_c) = (e_z)^k to get the value of k at a single point.

Example call of get_single_k.py: 
``` bash
python get_single_k.py hp_ref_trn hp_hyp_trn zp_ref_trn zp_hyp_trn 
```

# Results
By default, the results of the k value calculation are placed in the files named 'results' which are located in data/boothroyd/noise in the partition subfolders.

Graphs are also generated by run_k_value.sh and placed in the same folder as the 'results' files. By default, overlay_graph.png uses the same colours and data point styles as hp_zp_graph.png and lp_zp_graph.png (so by default the lp bin has a red trend line with blue circles as data points, and the hp bin has a green trend line with blue crosses as data points)