#!/bin/bash
#SBATCH --job-name=holoscene_plant
#SBATCH --partition=gpu
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --mem=128gb
#SBATCH --time=12:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --output=/home/crajashekhar/cup1/holoscene_plant_%j.log

echo "============================================"
echo " HoloScene Job Start: $(date)"
echo " Node: $(hostname)"
echo "============================================"

module load cuda12.8/toolkit/12.8.1
nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader

# ── Environment ───────────────────────────────────────────────────────────────
export SCENE_NAME=plant
export DATA_ROOT=/home/crajashekhar/cup1/data/input/custom
export OUTPUT_ROOT=/home/crajashekhar/cup1/data/output/custom
export IMG_WIDTH=1280
export IMG_HEIGHT=720
export TORCH_CUDA_ARCH_LIST="8.9"
export TCNN_CUDA_ARCHITECTURES="89"
export PYTORCH_SKIP_CUDA_CHECK=1
export WANDB_MODE=disabled
export PATH=/home/crajashekhar/.conda/envs/holoscene_env/bin:${PATH}
export PYTHONPATH=/home/crajashekhar/cup1/holoscene_src:/home/crajashekhar/cup1/holoscene_src/MVMeshRecon:${PYTHONPATH}
export CACHE_ROOT=/home/crajashekhar/cup1/data/cache/holoscene
export HF_HOME=${CACHE_ROOT}/hf

mkdir -p ${CACHE_ROOT}/ckpts ${CACHE_ROOT}/lama \
         ${CACHE_ROOT}/omnidata ${HF_HOME}

PYTHON=/home/crajashekhar/.conda/envs/holoscene_env/bin/python3
PIP=/home/crajashekhar/.conda/envs/holoscene_env/bin/pip
TORCH_LIB=/home/crajashekhar/.conda/envs/holoscene_env/lib/python3.10/site-packages/torch/lib
CONDA_LIB=/home/crajashekhar/.conda/envs/holoscene_env/lib
export LD_LIBRARY_PATH=${TORCH_LIB}:${CONDA_LIB}:${LD_LIBRARY_PATH}

echo "SCENE_NAME:  ${SCENE_NAME}"
echo "DATA_ROOT:   ${DATA_ROOT}"
echo "IMG:         ${IMG_WIDTH}x${IMG_HEIGHT}"
echo "Node GPU:    $(nvidia-smi --query-gpu=name --format=csv,noheader)"

# ── Verify inputs ─────────────────────────────────────────────────────────────
TRANSFORMS="${DATA_ROOT}/${SCENE_NAME}/transforms.json"
MASK_COUNT=$(ls "${DATA_ROOT}/${SCENE_NAME}/instance_mask/" | wc -l)
FRAME_COUNT=$(ls "${DATA_ROOT}/${SCENE_NAME}/images/" | wc -l)

[ ! -f "${TRANSFORMS}" ] && echo "ERROR: transforms.json missing" && exit 1
[ "${MASK_COUNT}" -eq 0 ] && echo "ERROR: No masks found" && exit 1

echo "transforms.json : found"
echo "instance masks  : ${MASK_COUNT} files"
echo "frames          : ${FRAME_COUNT}"

# ── Install standard deps ─────────────────────────────────────────────────────
echo "--- Checking standard dependencies ---"
${PIP} install omegaconf pyhocon imageio imageio-ffmpeg \
    trimesh pysdf usd-core diffusers "numpy<2" -q \
    --break-system-packages 2>/dev/null || \
${PIP} install omegaconf pyhocon imageio imageio-ffmpeg \
    trimesh pysdf usd-core diffusers "numpy<2" -q

# ── Build tinycudann from source on compute node ──────────────────────────────
echo "--- Building tinycudann on compute node (GPU arch 89 = L40s) ---"
${PYTHON} -c "import tinycudann; print('tinycudann already installed')" 2>/dev/null || {

    GCC_ROOT=/cm/local/apps/gcc/13.1.0
    GCC_INC=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0/include
    CUDA_ROOT=/cm/shared/apps/cuda12.8/toolkit/12.8.1
    export TORCH_CUDA_ARCH_LIST="8.9"
    export TCNN_CUDA_ARCHITECTURES="89"
    export PYTORCH_SKIP_CUDA_CHECK=1

    export PATH=${GCC_ROOT}/bin:${GCC_ROOT}/libexec/gcc/x86_64-linux-gnu/13.1.0:${PATH}
    export CC=${GCC_ROOT}/bin/gcc
    export CXX=${GCC_ROOT}/bin/g++
    export CUDA_HOME=${CUDA_ROOT}
    export LD_LIBRARY_PATH=${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}
    export LIBRARY_PATH=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0:${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LIBRARY_PATH}

    # Tell nvcc to use our gcc and pass its include dir as a system include
    # -ccbin sets the host compiler; -Xcompiler passes flags through to it
    export NVCC_PREPEND_FLAGS="-ccbin ${GCC_ROOT}/bin/g++ -Xcompiler -isystem,${GCC_INC}"

    # Also needed for the C++ compilation steps that go through gcc directly
    export CFLAGS="-isystem ${GCC_INC}"
    export CXXFLAGS="-isystem ${GCC_INC}"

    cd /home/crajashekhar/cup1/tinycudann_src/bindings/torch

    # Clean any previous failed build artifacts
    rm -rf build/

    TCNN_CUDA_ARCHITECTURES="89" \
    CC=${GCC_ROOT}/bin/gcc \
    CXX=${GCC_ROOT}/bin/g++ \
    NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS}" \
    ${PYTHON} setup.py install 2>&1 | tail -20

    cd /home/crajashekhar/cup1
}

# Verify
${PYTHON} -c "import tinycudann; print('tinycudann OK')" || {
    echo "ERROR: tinycudann failed to build. Check log."
    exit 1
}
# ── Build gsplat on compute node ─────────────────────────────────────────────
echo "--- Building gsplat on compute node ---"
${PYTHON} -c "import gsplat; print('gsplat already installed')" 2>/dev/null || {
    GCC_ROOT=/cm/local/apps/gcc/13.1.0
    GCC_INC=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0/include
    CUDA_ROOT=/cm/shared/apps/cuda12.8/toolkit/12.8.1
    export TORCH_CUDA_ARCH_LIST="8.9"
    export TCNN_CUDA_ARCHITECTURES="89"
    export PYTORCH_SKIP_CUDA_CHECK=1
    export CC=${GCC_ROOT}/bin/gcc
    export CXX=${GCC_ROOT}/bin/g++
    export PATH=${GCC_ROOT}/bin:${GCC_ROOT}/libexec/gcc/x86_64-linux-gnu/13.1.0:${PATH}
    export CUDA_HOME=${CUDA_ROOT}
    export CFLAGS="-isystem ${GCC_INC}"
    export CXXFLAGS="-isystem ${GCC_INC}"
    export LIBRARY_PATH=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0:${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LIBRARY_PATH}
    export LD_LIBRARY_PATH=${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}
    ${PYTHON} -m pip install --no-build-isolation \
        /home/crajashekhar/cup1/gsplat_src 2>&1 | tail -50
}
${PYTHON} -c "import gsplat; print('gsplat OK')" || { echo "ERROR: gsplat failed"; exit 1; }

# ── Build nvdiffrast on compute node ─────────────────────────────────────────
echo "--- Building nvdiffrast on compute node ---"
${PYTHON} -c "import nvdiffrast; print('nvdiffrast already installed')" 2>/dev/null || {
    GCC_ROOT=/cm/local/apps/gcc/13.1.0
    GCC_INC=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0/include
    CUDA_ROOT=/cm/shared/apps/cuda12.8/toolkit/12.8.1
    export TORCH_CUDA_ARCH_LIST="8.9"
    export TCNN_CUDA_ARCHITECTURES="89"
    export PYTORCH_SKIP_CUDA_CHECK=1
    export CC=${GCC_ROOT}/bin/gcc
    export CXX=${GCC_ROOT}/bin/g++
    export PATH=${GCC_ROOT}/bin:${GCC_ROOT}/libexec/gcc/x86_64-linux-gnu/13.1.0:${PATH}
    export CUDA_HOME=${CUDA_ROOT}
    export CFLAGS="-isystem ${GCC_INC}"
    export CXXFLAGS="-isystem ${GCC_INC}"
    export LIBRARY_PATH=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0:${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LIBRARY_PATH}
    export LD_LIBRARY_PATH=${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}
    ${PYTHON} -m pip install --no-build-isolation \
        /home/crajashekhar/cup1/nvdiffrast_src 2>&1 | tail -5
}
${PYTHON} -c "import nvdiffrast; print('nvdiffrast OK')" || { echo "ERROR: nvdiffrast failed"; exit 1; }
# ── Build pytorch3d on compute node ──────────────────────────────────────────
echo "--- Building pytorch3d on compute node ---"
${PYTHON} -c "from pytorch3d import _C; print('pytorch3d already built')" 2>/dev/null || {
    GCC_ROOT=/cm/local/apps/gcc/13.1.0
    GCC_INC=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0/include
    CUDA_ROOT=/cm/shared/apps/cuda12.8/toolkit/12.8.1
    export TORCH_CUDA_ARCH_LIST="8.9"
    export TCNN_CUDA_ARCHITECTURES="89"
    export PYTORCH_SKIP_CUDA_CHECK=1
    export CC=${GCC_ROOT}/bin/gcc
    export CXX=${GCC_ROOT}/bin/g++
    export PATH=${GCC_ROOT}/bin:${GCC_ROOT}/libexec/gcc/x86_64-linux-gnu/13.1.0:${PATH}
    export CUDA_HOME=${CUDA_ROOT}
    export CFLAGS="-isystem ${GCC_INC}"
    export CXXFLAGS="-isystem ${GCC_INC}"
    export LIBRARY_PATH=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0:${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LIBRARY_PATH}
    export LD_LIBRARY_PATH=${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}
    export MAX_JOBS=8
    ${PYTHON} -m pip install --no-build-isolation \
        /home/crajashekhar/cup1/pytorch3d_build 2>&1 | tail -10
}
${PYTHON} -c "from pytorch3d import _C; print('pytorch3d OK')" || {
    echo "ERROR: pytorch3d _C extension failed"
    exit 1
}



# ── Run HoloScene ─────────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_ROOT}"
cd /home/crajashekhar/cup1/repo/modules/holoscene

echo "--- Setting compiler environment for JIT CUDA extensions ---"
GCC_ROOT=/cm/local/apps/gcc/13.1.0
GCC_INC=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0/include
CUDA_ROOT=/cm/shared/apps/cuda12.8/toolkit/12.8.1
    export TORCH_CUDA_ARCH_LIST="8.9"
    export TCNN_CUDA_ARCHITECTURES="89"
    export PYTORCH_SKIP_CUDA_CHECK=1
export CC=${GCC_ROOT}/bin/gcc
export CXX=${GCC_ROOT}/bin/g++
export PATH=${GCC_ROOT}/bin:${GCC_ROOT}/libexec/gcc/x86_64-linux-gnu/13.1.0:${PATH}
export CUDA_HOME=${CUDA_ROOT}
export CFLAGS="-isystem ${GCC_INC}"
export CXXFLAGS="-isystem ${GCC_INC}"
export LIBRARY_PATH=${GCC_ROOT}/lib/gcc/x86_64-linux-gnu/13.1.0:${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LIBRARY_PATH}
export LD_LIBRARY_PATH=${CUDA_ROOT}/lib64/stubs:${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}
echo "--- Starting HoloScene pipeline: $(date) ---"

SCENE_NAME="${SCENE_NAME}" \
DATA_ROOT="${DATA_ROOT}" \
OUTPUT_ROOT="${OUTPUT_ROOT}" \
IMG_WIDTH="${IMG_WIDTH}" \
IMG_HEIGHT="${IMG_HEIGHT}" \
WANDB_MODE=disabled \
CACHE_ROOT="${CACHE_ROOT}" \
bash /home/crajashekhar/cup1/repo/modules/holoscene/hs_process.sh

EXIT_CODE=$?

echo "============================================"
echo " HoloScene Job End: $(date)"
echo " Exit code: ${EXIT_CODE}"
echo "============================================"

if [ ${EXIT_CODE} -eq 0 ]; then
    echo "SUCCESS. USD output:"
    find "${OUTPUT_ROOT}" \
        \( -name "*.usd" -o -name "*.usdc" -o -name "*.usda" \) 2>/dev/null
    echo "GLB output:"
    find "${OUTPUT_ROOT}" -name "*.glb" 2>/dev/null
else
    echo "FAILED. Check log above."
fi

exit ${EXIT_CODE}
