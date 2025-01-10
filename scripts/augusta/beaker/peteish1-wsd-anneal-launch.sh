#!/usr/bin/env bash

set -ex

NUM_NODES=$1
shift

LR=$1
shift

LOAD_STEP=$1
shift

ANNEAL_STEPS=$1
shift

gantry run \
  --workspace ai2/OLMo-mup \
  --task-name peteish1-wsd-lr${LR} \
  --description "Peteish1 WSD schedule" \
  --priority normal \
  --preemptible \
  --beaker-image michalg/cuda11.8-ubuntu20.04-arb \
  --cluster ai2/augusta-google-1 \
  --gpus 8 \
  --replicas "${NUM_NODES}" \
  --leader-selection \
  --host-networking \
  --budget ai2/oe-training \
  --no-nfs \
  --propagate-failure \
  --propagate-preemption \
  --no-python \
  --env LOG_FILTER_TYPE=local_rank0_only \
  --env OMP_NUM_THREADS=8 \
  --env OLMO_TASK=model \
  --env-secret WANDB_API_KEY=SHANEA_WANDB_API_KEY \
  --env-secret AWS_CONFIG=SHANEA_AWS_CONFIG \
  --env-secret AWS_CREDENTIALS=SHANEA_AWS_CREDENTIALS \
  --shared-memory 10GiB \
  --yes \
  --timeout=-1 \
  --allow-dirty \
  --retries 1 \
  -- /bin/bash -c "scripts/augusta/beaker/peteish1-wsd-anneal.sh \$BEAKER_LEADER_REPLICA_HOSTNAME \$BEAKER_REPLICA_RANK $LR $LOAD_STEP $ANNEAL_STEPS ${@}"
