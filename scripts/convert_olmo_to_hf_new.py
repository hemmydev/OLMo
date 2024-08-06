# Copyright 2024 EleutherAI and The HuggingFace Inc. team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
import argparse
import gc
import json
import os
import shutil
from pathlib import Path
from typing import Any, Dict

import torch
import yaml
from tokenizers import Tokenizer
from transformers import OlmoConfig, OlmoForCausalLM  # pyright: ignore
from transformers.models.gpt_neox.tokenization_gpt_neox_fast import GPTNeoXTokenizerFast

"""
Sample usage:
```
python src/transformers/models/olmo/convert_olmo_weights_to_hf.py \
    --input_dir /path/to/downloaded/olmo/weights --model_size 7B --output_dir /output/path
```
Thereafter, models can be loaded via:
```py
from transformers import OlmoForCausalLM, AutoTokenizer
model = OlmoForCausalLM.from_pretrained("/output/path")
tokenizer = AutoTokenizer.from_pretrained("/output/path")
```
Important note: you need to be able to host the whole model in RAM to execute this script
(even if the biggest versions come in several checkpoints they each contain a part of each
weight of the model, so we need to load them all in RAM).
"""


def compute_intermediate_size(n, ffn_dim_multiplier=1, multiple_of=256):
    return multiple_of * ((int(ffn_dim_multiplier * int(8 * n / 3)) + multiple_of - 1) // multiple_of)


def read_json(path):
    with open(path, "r") as f:
        return json.load(f)


def write_json(text, path):
    with open(path, "w") as f:
        json.dump(text, f)


def write_model(
    model_path,
    input_base_path,
    include_tokenizer=True,
    tokenizer_path=None,
    tokenizer_name_or_path=None,
    safe_serialization=True,
    fix_eos_token_id=True,
    tmp_cleanup=True,
):
    os.makedirs(model_path, exist_ok=True)
    tmp_model_path = os.path.join(model_path, "tmp")
    os.makedirs(tmp_model_path, exist_ok=True)

    config_path = Path(input_base_path) / "config.yaml"
    olmo_config = yaml.safe_load(config_path.read_text())["model"]

    n_layers = olmo_config["n_layers"]
    n_heads = olmo_config["n_heads"]
    dim = olmo_config["d_model"]
    dims_per_head = dim // n_heads
    base = 10000.0
    inv_freq = 1.0 / (base ** (torch.arange(0, dims_per_head, 2).float() / dims_per_head))
    max_position_embeddings = olmo_config["max_sequence_length"]

    vocab_size = olmo_config.get("embedding_size", olmo_config["vocab_size"])

    if olmo_config.get("n_kv_heads", None) is not None:
        num_key_value_heads = olmo_config["n_kv_heads"]  # for GQA / MQA
    elif olmo_config["multi_query_attention"]:  # compatibility with other checkpoints
        num_key_value_heads = 1
    else:
        num_key_value_heads = n_heads

    print(f"Fetching all parameters from the checkpoint at {input_base_path}.")

    # Not sharded
    # (The sharded implementation would also work, but this is simpler.)
    loaded = torch.load(os.path.join(input_base_path, "model.pt"), map_location="cpu")

    param_count = 0
    index_dict: Dict[str, Any] = {"weight_map": {}}
    for layer_i in range(n_layers):
        filename = f"pytorch_model-{layer_i + 1}-of-{n_layers + 1}.bin"
        # Unsharded
        # TODO: Layernorm stuff
        # TODO: multi query attention
        fused_dims = [dim, dims_per_head * num_key_value_heads, dims_per_head * num_key_value_heads]
        q_proj_weight, k_proj_weight, v_proj_weight = torch.split(
            loaded[f"transformer.blocks.{layer_i}.att_proj.weight"], fused_dims, dim=0
        )
        up_proj_weight, gate_proj_weight = torch.chunk(
            loaded[f"transformer.blocks.{layer_i}.ff_proj.weight"], 2, dim=0
        )
        state_dict = {
            f"model.layers.{layer_i}.self_attn.q_proj.weight": q_proj_weight,
            f"model.layers.{layer_i}.self_attn.k_proj.weight": k_proj_weight,
            f"model.layers.{layer_i}.self_attn.v_proj.weight": v_proj_weight,
            f"model.layers.{layer_i}.self_attn.o_proj.weight": loaded[
                f"transformer.blocks.{layer_i}.attn_out.weight"
            ],
            f"model.layers.{layer_i}.mlp.gate_proj.weight": gate_proj_weight,
            f"model.layers.{layer_i}.mlp.down_proj.weight": loaded[f"transformer.blocks.{layer_i}.ff_out.weight"],
            f"model.layers.{layer_i}.mlp.up_proj.weight": up_proj_weight,
        }

        state_dict[f"model.layers.{layer_i}.self_attn.rotary_emb.inv_freq"] = inv_freq

        for k, v in state_dict.items():
            index_dict["weight_map"][k] = filename
            param_count += v.numel()
        torch.save(state_dict, os.path.join(tmp_model_path, filename))

    filename = f"pytorch_model-{n_layers + 1}-of-{n_layers + 1}.bin"

    # Unsharded
    # TODO: Deal with weight-tying
    state_dict = {
        "model.embed_tokens.weight": loaded["transformer.wte.weight"],
        "lm_head.weight": (
            loaded["transformer.ff_out.weight"]
            if "transformer.ff_out.weight" in loaded
            else loaded["transformer.wte.weight"]
        ),
    }

    for k, v in state_dict.items():
        index_dict["weight_map"][k] = filename
        param_count += v.numel()
    torch.save(state_dict, os.path.join(tmp_model_path, filename))

    # Write configs
    index_dict["metadata"] = {"total_size": param_count * 2}
    write_json(index_dict, os.path.join(tmp_model_path, "pytorch_model.bin.index.json"))

    if olmo_config.get("mlp_hidden_size", None) is not None:
        intermediate_size = olmo_config["mlp_hidden_size"] // 2
    else:
        intermediate_size = (dim * olmo_config["mlp_ratio"]) // 2

    if fix_eos_token_id and olmo_config["eos_token_id"] == 0:
        # Fixing a bug in OLMo where eos token id was incorrectly set
        print("Changing eos_token_id from 0 to 50279.")
        olmo_config["eos_token_id"] = 50279

    config = OlmoConfig(
        vocab_size=vocab_size,
        hidden_size=dim,
        intermediate_size=intermediate_size,
        num_hidden_layers=n_layers,
        num_attention_heads=n_heads,
        num_key_value_heads=num_key_value_heads,
        max_position_embeddings=max_position_embeddings,
        pad_token_id=olmo_config["pad_token_id"],
        bos_token_id=None,
        eos_token_id=olmo_config["eos_token_id"],
        tie_word_embeddings=olmo_config.get("weight_tying", True),
        rope_theta=base,
        clip_qkv=olmo_config.get("clip_qkv"),
    )
    config.save_pretrained(tmp_model_path)

    # Make space so we can load the model properly now.
    del state_dict
    del loaded
    gc.collect()

    if include_tokenizer:
        _write_tokenizer(
            output_path=model_path,
            config=config,
            checkpoint_dir=input_base_path,
            input_tokenizer_path=tokenizer_path,
            tokenizer_name_or_path=tokenizer_name_or_path,
        )

    print("Loading the checkpoint in a OLMo model.")
    model = OlmoForCausalLM.from_pretrained(tmp_model_path, torch_dtype=torch.float32, low_cpu_mem_usage=True)
    # Avoid saving this as part of the config.
    del model.config._name_or_path
    print("Saving in the Transformers format.")
    model.save_pretrained(model_path, safe_serialization=safe_serialization)
    if tmp_cleanup:
        # Make cleanup optional; attempting to `rmtree` the `tmp_model_path` causes
        # errors if using NFS.
        shutil.rmtree(tmp_model_path)


def _write_tokenizer(
    output_path: Path,
    config: OlmoConfig,
    checkpoint_dir: str,
    input_tokenizer_path: Path | None,
    tokenizer_name_or_path: str | None = None,
) -> None:
    print(f"Saving a {GPTNeoXTokenizerFast.__name__} to {output_path}.")

    if input_tokenizer_path is not None:
        base_tokenizer = Tokenizer.from_file(str(input_tokenizer_path))
    elif tokenizer_name_or_path is not None:
        if Path(tokenizer_name_or_path).is_file():
            base_tokenizer = Tokenizer.from_file(tokenizer_name_or_path)
        else:
            base_tokenizer = Tokenizer.from_pretrained(tokenizer_name_or_path)
    else:
        config_path = Path(checkpoint_dir) / "config.yaml"
        tokenizer_config = yaml.safe_load(config_path.read_text())["tokenizer"]

        # Initialize tokenizer and validate vocab size.
        if Path(tokenizer_config["identifier"]).is_file():
            base_tokenizer = Tokenizer.from_file(tokenizer_config["identifier"])
        else:
            base_tokenizer = Tokenizer.from_pretrained(tokenizer_config["identifier"])

    eos_token_id = config.eos_token_id if config.eos_token_id is not None else base_tokenizer.get_vocab_size() - 1
    pad_token_id = config.pad_token_id if config.pad_token_id is not None else eos_token_id

    tokenizer = GPTNeoXTokenizerFast(
        tokenizer_object=base_tokenizer,
        eos_token=base_tokenizer.decode([eos_token_id], skip_special_tokens=False),
        pad_token=base_tokenizer.decode([pad_token_id], skip_special_tokens=False),
        unk_token=None,  # pyright: ignore
        bos_token=None,  # pyright: ignore
    )

    tokenizer.save_pretrained(output_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input_dir",
        required=True,
        help="Location of OLMo weights, which contains config.yaml and model.pt.",
    )
    parser.add_argument(
        "--no_tokenizer",
        action="store_false",
        dest="include_tokenizer",
        help="If set, do not convert OLMo tokenizer to HF tokenizer.",
    )
    parser.add_argument(
        "--tokenizer_json_path",
        type=Path,
        default=None,
        help="Location of OLMo tokenizer json file. Defaults to what is set in the config file.",
    )
    parser.add_argument(
        "--tokenizer_name_or_path",
        type=str,
        default=None,
        help="Name or path of the tokenizer to use; if not provided, uses whatever is in the checkpoint.",
    )
    parser.add_argument(
        "--output_dir",
        required=True,
        help="Location to write HF model and tokenizer",
    )
    parser.add_argument(
        "--no_fix_eos_token_id",
        action="store_false",
        dest="fix_eos_token_id",
        help=(
            "If set, does not change eos token id from 0 to 50279 if it is 0. "
            "Changing 0 to 50279 is a bug fix, so use this option with care."
        ),
    )
    parser.add_argument(
        "--no_tmp_cleanup",
        action="store_false",
        dest="tmp_cleanup",
        help="If passed, don't remove temp dir at end of HF conversion.",
    )
    parser.add_argument("--safe_serialization", type=bool, help="Whether or not to save using `safetensors`.")
    # Different OLMo versions used different default values for max_position_embeddings, hence the need to
    # be able to specify which version is being used.
    args = parser.parse_args()
    write_model(
        model_path=args.output_dir,
        input_base_path=args.input_dir,
        safe_serialization=args.safe_serialization,
        include_tokenizer=args.include_tokenizer,
        tokenizer_path=args.tokenizer_json_path,
        tokenizer_name_or_path=args.tokenizer_name_or_path,
        fix_eos_token_id=args.fix_eos_token_id,
        tmp_cleanup=args.tmp_cleanup,
    )


if __name__ == "__main__":
    main()
