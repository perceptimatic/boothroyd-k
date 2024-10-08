#! /usr/bin/env python

# Copyright 2024 Sean Robertson, Michael Ong
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Obtains the k value for the following comparisons: hp / zp, lp / zp (default: hp = 1, lp = 2, zp = 3)
# in the given data directory (no default) using the curve of best fit f(x) = x^k, then
# writes the results to a file (default: {data_dir}/results)
# If specified (default: false), also creates graphs of the data points with the curve of best fit overlaid 
# (default: {data_dir}/hp_zp_graph.png, {data_dir}/lp_zp_graph.png, {data_dir}/overlay_graph.png)
# By default, the data points for lp / zp are blue circles with a red curve of best fit,
# and the data points for hp / zp are blue crosses with a green curve of best fit
# By default, the overlay graph also uses the same format for the data points and curves of best fit
# (i.e. the green and red curves are the curves of best fit for hp / zp and lp / zp, respectively,
# and the data points are also in the same format as in their original graphs)

# The given data directory must be formatted in the same way as the output of section_data.sh

# e.g. python get_snr_k.py --generate-images \
#                       --hp 1 --lp 4 --zp 7 \
#                       --results-path data/boothroyd/results/results \
#                       --lp-zp-path data/boothroyd/results/lp_zp_graph \
#                       --hp-zp-path data/boothroyd/results/hp_zp_graph \
#                       --overlay-path data/boothroyd/results/overlay_graph \
#                       data/boothroyd/noise/train 
# would look for subdirectories in data/boothroyd/noise/train 
# named "1", "4", and "7" for hp, lp, and zp, respectively
# and would write the graphs and the results into the directory data/boothroyd/results

import os
import sys
from typing import (
    List,
    Optional,
    TextIO,
    Tuple,
    Union,
)
from multiprocessing import Pool
import warnings
import argparse
import pathlib

import numpy as np
import jiwer
from scipy.optimize import curve_fit
import matplotlib
matplotlib.use
import matplotlib.pyplot as plt

# _AktTree is modified from the pydrobert-pytorch package
class _AltTree(object):
    def __init__(self, parent=None):
        self.parent = parent
        self.tokens = []
        if parent is not None:
            parent.tokens.append([self.tokens])

    def new_branch(self):
        assert self.parent
        self.tokens = []
        self.parent.tokens[-1].append(self.tokens)

# _trn_line_to_transcript is modified from the pydrobert-pytorch package
def _trn_line_to_transcript(x: Tuple[str, bool]) -> Optional[Tuple[str, List[str]]]:
    line, warn = x
    line = line.strip()
    if not line:
        return None
    try:
        last_open = line.rindex("(")
        last_close = line.rindex(")")
        if last_open > last_close:
            raise ValueError()
    except ValueError:
        raise IOError("Line does not end in utterance id")
    utt_id = line[last_open + 1 : last_close]
    line = line[:last_open].strip()
    transcript = []
    token = ""
    alt_tree = _AltTree()
    found_alt = False
    while len(line):
        c = line[0]
        line = line[1:]
        if c == "{":
            found_alt = True
            if token:
                if alt_tree.parent is None:
                    transcript.append(token)
                else:
                    alt_tree.tokens.append(token)
                token = ""
            alt_tree = _AltTree(alt_tree)
        elif c == "/" and alt_tree.parent is not None:
            if token:
                alt_tree.tokens.append(token)
                token = ""
            alt_tree.new_branch()
        elif c == "}" and alt_tree.parent is not None:
            if token:
                alt_tree.tokens.append(token)
                token = ""
            if not alt_tree.tokens:
                raise IOError('Empty alternate found ("{ }")')
            alt_tree = alt_tree.parent
            if alt_tree.parent is None:
                assert len(alt_tree.tokens) == 1
                transcript.append((alt_tree.tokens[0], -1, -1))
                alt_tree.tokens = []
        elif c == " ":
            if token:
                if alt_tree.parent is None:
                    transcript.append(token)
                else:
                    alt_tree.tokens.append(token)
                token = ""
        else:
            token += c
    if token and alt_tree.parent is None:
        transcript.append(token)
    if found_alt and warn:
        warnings.warn(
            'Found an alternate in transcription for utt="{}". '
            "Transcript will contain an array of alternates at that "
            "point, and will not be compatible with transcript_to_token "
            "until resolved. To suppress this warning, set warn=False"
            "".format(utt_id)
        )
    return utt_id, transcript

# read_trn_iter is modified from the pydrobert-pytorch package
def read_trn_iter(
    trn: Union[TextIO, str],
    warn: bool = True,
    processes: int = 0,
    chunk_size: int = 1000,
) -> Tuple[str, List[str]]:
    """Read a NIST sclite transcript file, yielding individual transcripts

    Identical to :func:`read_trn`, but yields individual transcript entries rather than
    a full list. Ideal for large transcript files.

    Parameters
    ----------
    trn
    warn
    processes
    chunk_size

    Yields
    ------
    utt_id : str
    transcript : list of str
    """
    # implementation note: there's a lot of weirdness here. I'm trying to
    # match sclite's behaviour. A few things
    # - the last parentheses are always the utterance. Everything else is
    #   the word
    # - An unmatched '}' is treated as a word
    # - A '/' not within curly braces is a word
    # - If the utterance ends without closing its alternate, the alternate is
    #   discarded
    # - Comments from other formats are not comments here...
    # - ...but everything passed the last pair of parentheses is ignored...
    # - ...and internal parentheses are treated as words
    # - Spaces are treated as part of the utterance id
    # - Seg faults on empty alternates
    if isinstance(trn, str):
        with open(trn) as trn:
            yield from read_trn_iter(trn, warn, processes)
    elif processes == 0:
        for line in trn:
            x = _trn_line_to_transcript((line, warn))
            if x is not None:
                yield x
    else:
        with Pool(processes) as pool:
            transcripts = pool.imap(
                _trn_line_to_transcript, ((line, warn) for line in trn), chunk_size
            )
            for x in transcripts:
                if x is not None:
                    yield x
            pool.close()
            pool.join()

def boothroyd_func(x, k):
    return x**k

def get_err(ref_file, hyp_file):
    ref_dict = dict(read_trn_iter(ref_file))
    empty_refs = set(key for key in ref_dict if not ref_dict[key])
    if empty_refs:
        print(
            "One or more reference transcriptions are empty: "
            f"{', '.join(empty_refs)}",
            file=sys.stderr,
            end="",
        )
        return 1
    keys = sorted(ref_dict)
    refs = [" ".join(ref_dict[x]) for x in keys]
    del ref_dict

    hyp_dict = dict((k, v) for (k, v) in read_trn_iter(hyp_file))
    if sorted(hyp_dict) != keys:
        keys_, keys = set(hyp_dict), set(keys)
        print(
            f"ref and hyp file have different utterances!",
            file=sys.stderr,
        )
        diff = sorted(keys - keys_)
        if diff:
            print(f"Missing from hyp: " + " ".join(diff), file=sys.stderr)
        diff = sorted(keys_ - keys)
        if diff:
            print(f"Missing from ref: " + " ".join(diff), file=sys.stderr)
        return 1
    hyps = [" ".join(hyp_dict[x]) for x in keys]
    er = jiwer.wer(refs, hyps)
    return(er)

def main(args=None):
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--generate-images", help="Whether to generate graphs of the k-value curves", action='store_true'
    )
    parser.add_argument(
        "--hp", type=str, metavar="DIR", help="The name of the 'high predictability' bin", default="1"
    )
    parser.add_argument(
        "--lp", type=str, metavar="DIR", help="The name of the 'low predictability' bin", default="2"
    )
    parser.add_argument(
        "--zp", type=str, metavar="DIR", help="The name of the 'zero predictability' bin", default="3"
    )
    parser.add_argument(
        "--results-path", type=pathlib.Path, metavar="FILE", help="The path to the results file", default=None
    )
    parser.add_argument(
        "--lp-zp-path", type=pathlib.Path, metavar="FILE", help="The path to the lp / zp graph", default=None
    )
    parser.add_argument(
        "--hp-zp-path", type=pathlib.Path, metavar="FILE", help="The path to the hp / zp graph", default=None
    )
    parser.add_argument(
        "--overlay-path", type=pathlib.Path, metavar="FILE", help="The path to the hp / zp + lp / zp graph", default=None
    )
    parser.add_argument(
        "data_dir", type=pathlib.Path, help="The data directory"
    )
    options = parser.parse_args(args)

    zp_errs = []
    lp_errs = []
    hp_errs = []

    if not options.results_path:
        options.results_path = os.path.join(options.data_dir, "results")

    for snr_dir in os.scandir(options.data_dir):
        if snr_dir.is_dir():
            for _, split_dirs, _ in os.walk(snr_dir):
                for split_dir in split_dirs:
                    ref_file = os.path.join(snr_dir, split_dir, "ref.trn")
                    hyp_file = os.path.join(snr_dir, split_dir, "hyp.trn")
                    split_dir = split_dir.strip()
                    if split_dir == options.zp:
                        zp_errs.append(get_err(ref_file,hyp_file))
                    elif split_dir == options.lp:
                        lp_errs.append(get_err(ref_file,hyp_file))
                    elif split_dir == options.hp:
                        hp_errs.append(get_err(ref_file,hyp_file))

    if not zp_errs:
        print(f"'{options.zp}' is not one of the bins in {options.data_dir}! set --zp properly.")
        return 1
    elif not lp_errs:
        print(f"'{options.lp}' is not one of the bins in {options.data_dir}! set --lp properly.")
        return 1
    elif not hp_errs:
        print(f"'{options.hp}' is not one of the bins in {options.data_dir}! set --hp properly.")
        return 1

    lz_k = curve_fit(boothroyd_func, xdata=zp_errs, ydata=lp_errs)[0][0]
    hz_k = curve_fit(boothroyd_func, xdata=zp_errs, ydata=hp_errs)[0][0]

    out = open(options.results_path, "w")
    out.write(f"LP/ZP k value:\t{lz_k}\n")
    out.write(f"HP/ZP k value:\t{hz_k}\n")
    out.close

    if options.generate_images:
        if not options.lp_zp_path:
            options.lp_zp_path = os.path.join(options.data_dir, "lp_zp_graph.png")
        if not options.hp_zp_path:
            options.hp_zp_path = os.path.join(options.data_dir, "hp_zp_graph.png")
        if not options.overlay_path:
            options.overlay_path = os.path.join(options.data_dir, "overlay_graph.png")
        
        plt.figure(figsize = (10,8))
        plt.plot(zp_errs, lp_errs, 'bo')
        xseq = np.linspace(0, 1, num=100)
        plt.plot(xseq, xseq**lz_k, 'r')
        plt.xlabel('ZP error rate')
        plt.ylabel('LP error rate')
        plt.savefig(options.lp_zp_path)

        plt.figure(figsize = (10,8))
        plt.plot(zp_errs, hp_errs, 'b+')
        xseq = np.linspace(0, 1, num=100)
        plt.plot(xseq, xseq**hz_k, 'g')
        plt.xlabel('ZP error rate')
        plt.ylabel('HP error rate')
        plt.savefig(options.hp_zp_path)

        plt.figure(figsize = (20,16))
        plt.plot(zp_errs, lp_errs, 'bo')
        plt.plot(zp_errs, hp_errs, 'b+')
        xseq = np.linspace(0, 1, num=100)
        plt.plot(xseq, xseq**lz_k, 'r')
        plt.plot(xseq, xseq**hz_k, 'g')
        plt.xlabel('ZP error rate')
        plt.ylabel('error rate')
        plt.savefig(options.overlay_path)

    exit()

if __name__ == "__main__":
    sys.exit(main())