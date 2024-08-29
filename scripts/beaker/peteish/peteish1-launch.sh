#!/usr/bin/env bash

set -ex

NUM_NODES=1

gantry run \
  --workspace ai2/shanea \
  --task-name z-score-clipping \
  --description "Skip optimizer steps based on outlier loss/grad norm" \
  --priority normal \
  --preemptible \
  --beaker-image petew/olmo-torch23-gantry \
  --cluster ai2/jupiter-cirrascale-2 \
  --gpus 8 \
  --replicas "${NUM_NODES}" \
  --leader-selection \
  --host-networking \
  --budget ai2/oe-training \
  --no-nfs \
  --weka oe-training-default:/weka/oe-training-default \
  --propagate-failure \
  --propagate-preemption \
  --no-python \
  --env LOG_FILTER_TYPE=local_rank0_only \
  --env OMP_NUM_THREADS=8 \
  --env OLMO_TASK=model \
  --env R2_PROFILE=R2 \
  --env S3_PROFILE=S3 \
  --env WEKA_PROFILE=WEKA \
  --env-secret AWS_CONFIG=AWS_CONFIG \
  --env-secret AWS_CREDENTIALS=AWS_CREDENTIALS \
  --env-secret R2_ENDPOINT_URL=R2_ENDPOINT_URL \
  --env-secret WANDB_API_KEY=WANDB_API_KEY \
  --shared-memory 10GiB \
  --yes \
  --timeout=-1 \
  -- /bin/bash -c "scripts/beaker/peteish/peteish1.sh \$BEAKER_LEADER_REPLICA_HOSTNAME ${NUM_NODES} \$BEAKER_REPLICA_RANK"
