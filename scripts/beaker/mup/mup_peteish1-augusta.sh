#!/usr/bin/env bash
set -exuo pipefail
IFS=$'\n\t'

BEAKER_LEADER_REPLICA_HOSTNAME=$1
shift

NUM_NODES=$1
shift

BEAKER_REPLICA_RANK=$1
shift

WIDTH=$1
shift

LR=$1
shift

# augusta specific environment
export LD_LIBRARY_PATH="/var/lib/tcpxo/lib64:${LD_LIBRARY_PATH}"
export NCCL_CROSS_NIC=0
export NCCL_ALGO=Ring,Tree
export NCCL_PROTO=Simple
export NCCL_MIN_NCHANNELS=4
export NCCL_P2P_NET_CHUNKSIZE=524288
export NCCL_P2P_PCI_CHUNKSIZE=524288
export NCCL_P2P_NVL_CHUNKSIZE=1048576
export NCCL_FASTRAK_NUM_FLOWS=2
export NCCL_FASTRAK_ENABLE_CONTROL_CHANNEL=0
export NCCL_BUFFSIZE=8388608
export NCCL_FASTRAK_USE_SNAP=1
export CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_FASTRAK_ENABLE_HOTPATH_LOGGING=0
export NCCL_TUNER_PLUGIN=libnccl-tuner.so
export NCCL_TUNER_CONFIG_PATH=/var/lib/tcpxo/lib64/a3plus_tuner_config.textproto
export NCCL_SHIMNET_GUEST_CONFIG_CHECKER_CONFIG_FILE=/var/lib/tcpxo/lib64/a3plus_guest_config.textproto
export NCCL_FASTRAK_PLUGIN_ACCEPT_TIMEOUT_MS=600000
export NCCL_NVLS_ENABLE=0
export NCCL_DEBUG=WARN
export NCCL_FASTRAK_CTRL_DEV=enp0s12
export NCCL_FASTRAK_IFNAME=enp6s0,enp7s0,enp13s0,enp14s0,enp134s0,enp135s0,enp141s0,enp142s0
export NCCL_SOCKET_IFNAME=enp0s12
export NCCL_USE_SNAP=1
export NCCL_FASTRAK_USE_LLCM=1
export NCCL_FASTRAK_LLCM_DEVICE_DIRECTORY=/dev/aperture_devices

# Install flash-attn
#conda install -y pytorch-cuda==12.4 packaging ninja cccl cuda-nvcc libcusolver-dev cuda-profiler-api libcusparse-dev libcublas-dev -c pytorch -c nvidia
#pip install flash-attn==2.5.9.post1 --no-build-isolation
pip install '.[train]'
pip install --no-deps pyparsing pillow kiwisolver fonttools cycler contourpy matplotlib seaborn
pip install --no-deps git+https://github.com/2015aroras/mup@69628833d4fa7fe9aedcf54511549f6ac8718e8f
pip freeze

# Force processes to synchronize at init_process_group
export TORCH_DIST_INIT_BARRIER=1
# Better error handling from Python
export PYTHONFAULTHANDLER=1

NAME=${GANTRY_TASK_NAME// /_}
RUN_NAME=$NAME-$(date -u +"%Y%m%d_%H%M%S")
SAVE_FOLDER=/data/$RUN_NAME
mkdir -p $SAVE_FOLDER

export HF_DATASETS_OFFLINE=1

# Move AWS credentials from env to relevant files
mkdir -p ~/.aws
printenv AWS_CONFIG > ~/.aws/config
printenv AWS_CREDENTIALS > ~/.aws/credentials

export CHECKPOINTS_PATH=gs:/
export DATA_PATH=gs:/

export RUN_NAME="peteish1_${WIDTH}_${LR}"
export MAX_STEPS=10000
export GROUP_NAME="peteish1_${MAX_STEPS}steps"

# Just trying to figure out why augusta is failing
gcloud config list
nslookup metadata.google.internal
ping -c 3 metadata.google.internal
cat /etc/resolv.conf

torchrun \
  --nnodes ${NUM_NODES}:${NUM_NODES} \
  --nproc-per-node 8 \
  --rdzv_id=101 \
  --rdzv_backend=c10d \
  --rdzv_endpoint=$BEAKER_LEADER_REPLICA_HOSTNAME:29400 \
  --node_rank=$BEAKER_REPLICA_RANK \
  scripts/train.py configs/peteish1.yaml \
    --run_name=$RUN_NAME \
    --wandb.name=$NAME \
    --wandb.group=$GROUP_NAME \
    --wandb.project=olmo-mup \
    --load_path="gs://ai2-llm/checkpoints/OLMo-mup/peteish1_v2_512_2.44e-4/step0" \
    --save_folder=$SAVE_FOLDER \
    --model.use_mup \
    --model.mup_query_zero_init=false \
    --model.mup_base_shapes=configs/peteish1.bsh \
    --model.d_model=$WIDTH \
    --optimizer.learning_rate=$LR \
    --save_interval_ephemeral=250 \
    --scheduler.t_warmup=1000 \
    --scheduler.t_max=$MAX_STEPS \
    --stop_at=$MAX_STEPS \
    --eval_interval=500 \
    --fsdp.sharding_strategy=HYBRID_SHARD \
    --fsdp.hybrid_sharding_num_model_replicas="${BEAKER_REPLICA_COUNT}" \
    --fsdp.wrapping_strategy=by_block_and_size \
    --remote_save_folder="gs://ai2-llm/checkpoints/OLMo-mup/${GROUP_NAME}/${NAME}" \
    --sharded_checkpointer=olmo_core \
    --device_train_microbatch_size=4 \
    --device_eval_batch_size=8 \
    --compile.fullgraph=false \
    --fused_loss=false \
    --model.flash_attention=false \
    --data.num_workers=32 \
    --optimizer.metrics_log_interval=10 \
    --data.prefetch_factor=8 \
    --try_load_latest_save \
    --save_overwrite \
    "${@}"

# --load_path="${CHECKPOINTS_PATH}/ai2-llm/checkpoints/OLMo-mup/peteish1_2048_1.56e-2/step0" \
# --load_path="${CHECKPOINTS_PATH}/ai2-llm/checkpoints/OLMo-mup/peteish1_v2_512_2.44e-4/step0" \