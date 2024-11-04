#!/usr/bin/env bash

set -exuo pipefail
IFS=$'\n\t'

BEAKER_LEADER_REPLICA_HOSTNAME=$1
shift

NUM_NODES=$1
shift

NUM_GPUS=$1
shift

BEAKER_REPLICA_RANK=$1
shift

# Setup Python environment.
conda shell.bash activate base

# Install flash-attn
#conda install -y -c nvidia cuda-python
pip install packaging ninja
export FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE
pip install flash-attn==2.5.9.post1 --no-build-isolation
# pip install awscli
pip install '.[train]'
pip freeze

# # Move AWS credentials from env to relevant files
# mkdir -p ~/.aws
# printenv AWS_CONFIG > ~/.aws/config
# printenv AWS_CREDENTIALS > ~/.aws/credentials

# Force processes to synchronize at init_process_group
export TORCH_DIST_INIT_BARRIER=1

# Tell OLMo all ranks share the same filesystem for checkpoints.
export OLMO_SHARED_FS=1

export NCCL_DEBUG=INFO
export NCCL_IB_HCA="^=mlx5_bond_0"
export NCCL_SOCKET_IFNAME=ib
# export NCCL_IB_GID_INDEX=0

export WANDB_MODE="offline"

torchrun \
  --nnodes "${NUM_NODES}:${NUM_NODES}" \
  --nproc-per-node "${NUM_GPUS}" \
  --rdzv_id 12347 \
  --rdzv_backend static \
  --rdzv_endpoint "${BEAKER_LEADER_REPLICA_HOSTNAME}:29400" \
  --node_rank "${BEAKER_REPLICA_RANK}" \
  --rdzv_conf 'read_timeout=420' \
  scripts/eval.py \
    /weka/oe-training-default/ai2-llm/checkpoints/OLMo-ladder/peteish-const-1B-10xC/step0-unsharded/config.yaml \
      --run_name="${GANTRY_TASK_NAME}" \
      --save_interval_ephemeral=1000 \
      --save_folder="/workspace/ladder-test" \
      --wandb.group="ladder-backfill-test" \
      --load_path="/weka/oe-training-default/ai2-llm/checkpoints/OLMo-ladder/peteish-const-1B-10xC"

ls -l /workspace/ladder-test
ls -l /workspace/ladder-test/*