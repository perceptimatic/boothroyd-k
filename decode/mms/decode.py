# Copyright 2024 Sean Robertson, Michael Ong

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import os
import re
import pathlib
import string
from typing import Literal, Optional, Sequence, Protocol, TypeVar
import torch
from datasets import load_dataset, Audio, Dataset

from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor
from tqdm import tqdm

SPACE_PATTERN = re.compile(r"\s+")
WS = set(string.whitespace)
T = TypeVar("T")


class ArgparseType(Protocol[T]):
    metavar: str

    @staticmethod
    def to(arg: str) -> T: ...


class StringType(ArgparseType[str]):
    metavar = "STR"

    @staticmethod
    def to(arg: str) -> str:
        return arg


class TokenType(ArgparseType[str]):
    metavar = "TOK"

    @staticmethod
    def to(arg: str) -> str:
        if WS & set(arg):
            raise argparse.ArgumentTypeError(f"'{arg}' contains whitespace")
        return arg


class IntegerType(ArgparseType[int]):
    metavar = "INT"

    @staticmethod
    def to(arg: str) -> int:
        return int(arg)


class NonnegType(ArgparseType[int]):
    metavar = "NONNEG"

    @staticmethod
    def to(arg: str) -> int:
        int_ = int(arg)
        if int_ < 0:
            raise argparse.ArgumentTypeError(f"'{arg}' is not a non-negative integer")
        return int_


class NatType(ArgparseType[int]):
    metavar = "NATG"

    @staticmethod
    def to(arg: str) -> int:
        int_ = int(arg)
        if int_ <= 0:
            raise argparse.ArgumentTypeError(f"'{arg}' is not a natural number")
        return int_


class PathType(ArgparseType[pathlib.Path]):
    metavar = "PTH"

    @staticmethod
    def to(arg: str) -> pathlib.Path:
        return pathlib.Path(arg)


class WriteDirType(PathType):
    metavar = "DIR"


class WriteFileType(PathType):
    metavar = "FILE"


class ReadDirType(ArgparseType[pathlib.Path]):
    metavar = "DIR"

    @staticmethod
    def to(arg: str) -> pathlib.Path:
        pth = pathlib.Path(arg)
        if not pth.is_dir():
            raise argparse.ArgumentTypeError(f"'{arg}' is not a directory")
        return pth


class ReadFileType(ArgparseType[pathlib.Path]):
    metavar = "FILE"

    @staticmethod
    def to(arg: str) -> pathlib.Path:
        pth = pathlib.Path(arg)
        if not pth.is_file():
            raise argparse.ArgumentTypeError(f"'{arg}' is not a file")
        return pth


class Options(object):

    @classmethod
    def _add_argument(
        cls,
        parser: argparse.ArgumentParser,
        *name_or_flags: str,
        type: Optional[type[ArgparseType]] = None,
        help: Optional[str] = None,
    ):
        if type is None:
            type_, metavar = StringType.to, StringType.metavar
        else:
            type_, metavar = type.to, type.metavar
        if name_or_flags[0].startswith("-"):
            default = getattr(cls, name_or_flags[0].lstrip("-").replace("-", "_"))
        else:
            default = None
        parser.add_argument(
            *name_or_flags, metavar=metavar, default=default, type=type_, help=help
        )

    # global kwargs
    unk: str = "[UNK]"
    pad: str = "[PAD]"
    word_delimiter: str = "_"

    # global args
    cmd: Literal[
        "decode",
    ]

    lang: str = "fae"  # There's no Faetar ISO 639 code, but "fae" isn't mapped yet
    pretrained_model_id: str = "facebook/mms-1b-all"
    pretrained_model_lang: str = "ita"

    # decode kwargs
    logits_dir: Optional[pathlib.Path] = None

    # decode args
    # model_dir: pathlib.Path
    # data: pathlib.Path
    # metadata_csv: pathlib.Path

    @classmethod
    def _add_decode_args(cls, parser: argparse.ArgumentParser):

        cls._add_argument(
            parser, "--pretrained-model-id", help="model to load from hub"
        )
        cls._add_argument(
            parser, "--pretrained-model-lang", help="iso 639 code of model from hub"
        )
        cls._add_argument(
            parser,
            "model_dir",
            type=ReadDirType,
            help="Path to model dir",
        )
        cls._add_argument(
            parser,
            "data",
            type=ReadDirType,
            help="Path to AudioFolder to decode",
        )
        cls._add_argument(
            parser,
            "--logits-dir",
            type=WriteDirType,
            help="Path to dump logits to (if specified; output)",
        )
        cls._add_argument(
            parser,
            "metadata_csv",
            type=WriteFileType,
            help="Path to hypothesis metadata.csv file (output)",
        )

    @classmethod
    def parse_args(cls, args: Optional[Sequence[str]] = None, **kwargs):
        parser = argparse.ArgumentParser(**kwargs)

        cls._add_argument(
            parser, "--unk", type=TokenType, help="out-of-vocabulary type (string)"
        )
        cls._add_argument(
            parser, "--pad", type=TokenType, help="padding/blank type (string)"
        )
        cls._add_argument(
            parser,
            "--word-delimiter",
            type=TokenType,
            help="word delimiter type (string)",
        )
        cls._add_argument(parser, "--lang", type=TokenType, help="iso 639 code")

        cmds = parser.add_subparsers(
            title="steps",
            dest="cmd",
            required=True,
            metavar="STEP",
        )

        cls._add_decode_args(
            cmds.add_parser("decode", help="decode with fine-tuned mms model")
        )

        return parser.parse_args(args, namespace=cls())

def load_partition(
    options: Options,
    processor: Wav2Vec2Processor,
) -> Dataset:
    data = options.data
    data = data.absolute()

    ds = load_dataset("audiofolder", data_dir=data, split="all")
    ds = ds.cast_column(
        "audio", Audio(sampling_rate=processor.feature_extractor.sampling_rate)
    )

    def prepare_dataset(batch):
        audio = batch["audio"]
        batch["file_name"] = pathlib.Path(audio["path"]).relative_to(data).as_posix()

        # batched output is "un-batched"
        batch["input_values"] = processor(
            audio["array"], sampling_rate=audio["sampling_rate"]
        ).input_values[0]
        batch["input_length"] = len(batch["input_values"])

        if "sentence" in batch:
            batch["labels"] = processor(text=batch["sentence"]).input_ids
        return batch

    ds = ds.map(prepare_dataset, remove_columns=ds.column_names)
    return ds


if torch.cuda.is_available():
    device = torch.cuda.current_device()
else:
    device = "cpu"

args: Optional[Sequence[str]] = None
options = Options.parse_args(args)
model = Wav2Vec2ForCTC.from_pretrained(
    options.model_dir, target_lang=options.lang
).to(device)
processor = Wav2Vec2Processor.from_pretrained(
    options.model_dir, target_lang=options.lang
)

ds = load_partition(options, processor)

metadata_csv = options.metadata_csv.open("w")
metadata_csv.write("file_name,sentence\n")

if options.logits_dir is not None:
    options.logits_dir.mkdir(exist_ok=True)

for elem in tqdm(ds):
    input_dict = processor(
        elem["input_values"],
        sampling_rate=processor.feature_extractor.sampling_rate,
        return_tensors="pt",
        padding=True,
    )
    logits = model(input_dict.input_values.to(device)).logits.cpu()
    if options.logits_dir is not None:
        pt = options.logits_dir / (os.path.splitext(elem["file_name"])[0] + ".pt")
        torch.save(logits[0, :, : processor.tokenizer.vocab_size], pt)
    greedy_path = logits.argmax(-1)[0]
    text = processor.decode(greedy_path)
    text = SPACE_PATTERN.sub(" ", text)
    metadata_csv.write(f"{elem['file_name']},{text}\n")
