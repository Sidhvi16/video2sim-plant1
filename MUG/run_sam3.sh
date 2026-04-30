#!/bin/bash
# ============================================================
#  SLURM Job Script — SAM3 (Segment Anything Model 3)
#  SLU Libra HPC | Partition: gpu | GPU: L40s (40GB)
#  Runtime: conda environment da3_env
#
#  Pre-requisites:
#    1. DA3 complete — transforms.json must exist
#    2. prompts.txt must exist in data/input/custom/plant/
#    3. HF_TOKEN exported before sbatch:
#       export HF_TOKEN=hf_xxx && sbatch run_sam3.sh
#
#  Output:
#    ~/${directory_name}/data/input/custom/plant/instance_mask/
# ============================================================

#SBATCH --job-name=sam3_plant
#SBATCH --partition=gpu
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --mem=64gb
#SBATCH --time=04:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --output=sam3_plant_%j.log

# Change this as per the directory name
directory_name="cup1"

echo "============================================"
echo " SAM3 Job Start: $(date)"
echo " Node: $(hostname)"
echo "============================================"

module load cuda12.8/toolkit/12.8.1

nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# Confirm transforms.json exists
TRANSFORMS=~/${directory_name}/data/input/custom/plant/transforms.json
if [ ! -f "$TRANSFORMS" ]; then
    echo "ERROR: transforms.json not found. Run DA3 first."
    exit 1
fi

# Confirm frames exist
FRAME_COUNT=$(ls ~/${directory_name}/data/input/custom/plant/images/ | wc -l)
echo "Frames found: ${FRAME_COUNT}"

# Confirm prompts.txt exists
PROMPTS=~/${directory_name}/data/input/custom/plant/prompts.txt
if [ ! -f "$PROMPTS" ]; then
    echo "ERROR: prompts.txt not found."
    exit 1
fi

# Create output directory
mkdir -p ~/${directory_name}/data/input/custom/plant/instance_mask
mkdir -p ~/${directory_name}/data/cache/sam3

# Set environment variables
export SCENE_NAME=plant
export DATA_ROOT=/home/crajashekhar/${directory_name}/data/input/custom
export OUTPUT_ROOT=/home/crajashekhar/${directory_name}/data/output/custom
export SAM3_MIN_SCORE=0.10
export SAM3_MIN_FRAME_DURATION=40.0
export HF_HOME=/home/crajashekhar/${directory_name}/data/cache/sam3
export HF_TOKEN="${HF_TOKEN}"
export TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0"

echo "SCENE_NAME:  ${SCENE_NAME}"
echo "DATA_ROOT:   ${DATA_ROOT}"
echo "HF_TOKEN set: $([ -n "$HF_TOKEN" ] && echo YES || echo NO)"

# SAM3 reads prompts.txt from the working directory
cd ~/${directory_name}/data/input/custom/plant

echo "Starting SAM3 inference..."
/home/crajashekhar/.conda/envs/da3_env/bin/python3 \
  /home/crajashekhar/${directory_name}/repo/modules/sam3/sam3_process.py

EXIT_CODE=$?
echo "============================================"
echo " SAM3 Job End: $(date)"
echo " Exit code: ${EXIT_CODE}"
echo "============================================"

if [ $EXIT_CODE -eq 0 ]; then
    echo "SUCCESS: masks saved to:"
    echo "  ~/${directory_name}/data/input/custom/plant/instance_mask/"
    MASK_COUNT=$(ls ~/${directory_name}/data/input/custom/plant/instance_mask/ | wc -l)
    echo "  Mask files: ${MASK_COUNT}"
else
    echo "FAILED: Check log above for errors."
fi

exit $EXIT_CODE
