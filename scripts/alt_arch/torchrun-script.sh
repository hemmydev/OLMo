#!/usr/bin/env bash
set -exuo pipefail
IFS=$'\n\t'

BEAKER_LEADER_REPLICA_HOSTNAME=$1
shift

NUM_NODES=$1
shift

# Warm HF cache
mkdir -p /root/.cache
pushd /root/.cache
curl "https://storage.googleapis.com/dirkgr-public/huggingface_cache_v3.tar.gz" | tar --keep-newer-files -xzf -
popd
export HF_DATASETS_OFFLINE=1

# mqa-transformer-300M
# torchrun \
#   --nnodes ${NUM_NODES}:${NUM_NODES} \
#   --nproc-per-node 8 \
#   --rdzv_id=101 \
#   --rdzv_backend=c10d \
#   --rdzv_endpoint=$BEAKER_LEADER_REPLICA_HOSTNAME:29400 \
#   scripts/train.py \
#     configs/alt_arch/transformer_base-300M.yaml \
#       --run_name=mqa-transformer-300M-baseline \
#       --device_train_microbatch_size=16 \
#       --fsdp.sharding_strategy=SHARD_GRAD_OP \
#       --save_overwrite

# mamba-300M
torchrun \
  --nnodes ${NUM_NODES}:${NUM_NODES} \
  --nproc-per-node 8 \
  --rdzv_id=101 \
  --rdzv_backend=c10d \
  --rdzv_endpoint=$BEAKER_LEADER_REPLICA_HOSTNAME:29400 \
  scripts/train_alt-arch.py \
    configs/alt_arch/mamba-300M.yaml \
      --run_name=mamba-300M-bf16-param-layernorm-baseline \
      --device_train_microbatch_size=8 \
      --fsdp.sharding_strategy=SHARD_GRAD_OP \
      --save_overwrite

# zamba-300M
# torchrun \
#   --nnodes ${NUM_NODES}:${NUM_NODES} \
#   --nproc-per-node 8 \
#   --rdzv_id=101 \
#   --rdzv_backend=c10d \
#   --rdzv_endpoint=$BEAKER_LEADER_REPLICA_HOSTNAME:29400 \
#   scripts/train_alt-arch.py \
#     configs/alt_arch/zamba-300M.yaml \
#       --run_name=zamba1-300M-baseline \
#       --device_train_microbatch_size=8 \
#       --fsdp.sharding_strategy=SHARD_GRAD_OP \
#       --save_overwrite

# 7B mamba or olmo
# torchrun \
#   --nnodes ${NUM_NODES}:${NUM_NODES} \
#   --nproc-per-node 8 \
#   --rdzv_id=101 \
#   --rdzv_backend=c10d \
#   --rdzv_endpoint=$BEAKER_LEADER_REPLICA_HOSTNAME:29400 \
#   scripts/train_alt-arch.py \
#     configs/alt_arch/mamba-7B.yaml \
#       --run_name=mamba-7B \
#       --device_train_microbatch_size=2 \
#       --save_overwrite