:: ================================================================
::  BATCH SCRIPT FOR AUTOMATED PHOTOGRAMMETRY TRACKING WORKFLOW
::  Original by polyfjord - https://youtube.com/polyfjord
::  Modified for local mug reconstruction on NVIDIA Quadro M3000M
::  Verified against COLMAP 4.0.2 (Commit d927f7e, 2026-03-18)
:: ================================================================
::
::  CHANGES FROM ORIGINAL — all flags verified via `colmap <cmd> -h`
::
::  [feature_extractor]
::    In COLMAP 4.0, shared settings (GPU, image size) were lifted
::    out of SiftExtraction into a new FeatureExtraction namespace
::    to support multiple extractor types (SIFT, ALIKED).
::    Flags renamed accordingly:
::      --SiftExtraction.use_gpu        → --FeatureExtraction.use_gpu
::      --SiftExtraction.gpu_index      → --FeatureExtraction.gpu_index
::      --SiftExtraction.max_image_size → --FeatureExtraction.max_image_size
::
::  [sequential_matcher]
::    --SequentialMatching.overlap unchanged and valid.
::    overlap raised from 15 → 50 to compensate for wider angular
::    gaps between frames at 0.5fps on a slow turntable.
::    Note: quadratic_overlap defaults to 1 (enabled) — COLMAP
::    already does extra quadratic-interval matching automatically.
::
::  [mapper]
::    --Mapper.min_num_matches unchanged and valid. Lowered 15 → 10
::    to allow sparser frame pairs to still register.
::    --Mapper.ba_use_gpu added (default is 0 = CPU only).
::    Enabled for M3000M — GPU bundle adjustment is faster.
::    --Mapper.num_threads kept but default (-1) already uses all
::    cores; %NUMBER_OF_PROCESSORS% is equivalent.
::
::  [frame extraction]
::    EXTRACT_FPS=0.5 — one frame every 2 seconds.
::    Video is 4m 18s (258s) → ~129 images. Sweet spot for a mug.
::
:: ================================================================
@echo off

:: ================================================================
::  USER CONFIG — tweak these before running
:: ================================================================

:: How many frames per second to extract from the video.
::
:: Your video: 2K, 30fps, 4m 18s (258 seconds) = 7,740 raw frames
::
::   EXTRACT_FPS=0.3  →  ~77  images  (risky — gaps likely)
::   EXTRACT_FPS=0.5  →  ~129 images  <- RECOMMENDED for this video
::   EXTRACT_FPS=1    →  ~258 images  (workable but slower)
::   EXTRACT_FPS=2    →  ~516 images  (too many, very slow)
::
:: FFmpeg accepts decimal values here, so 0.5 works fine.
set "EXTRACT_FPS=15"

:: ================================================================
::  PATH RESOLUTION — no changes needed below this line normally
:: ================================================================

:: Resolve the top-level parent folder (one level up from this .bat)
pushd "%~dp0\.." >nul
set "TOP=%cd%"
popd >nul

:: Key directory paths
set "COLMAP_DIR=%TOP%\01 COLMAP"
set "VIDEOS_DIR=%TOP%\02 VIDEOS"
set "FFMPEG_DIR=%TOP%\03 FFMPEG"
set "SCENES_DIR=%TOP%\04 SCENES"

:: ----------------------------------------------------------------
::  Locate ffmpeg.exe (checks flat layout and bin\ subfolder)
:: ----------------------------------------------------------------
if exist "%FFMPEG_DIR%\ffmpeg.exe" (
    set "FFMPEG=%FFMPEG_DIR%\ffmpeg.exe"
) else if exist "%FFMPEG_DIR%\bin\ffmpeg.exe" (
    set "FFMPEG=%FFMPEG_DIR%\bin\ffmpeg.exe"
) else (
    echo [ERROR] ffmpeg.exe not found inside "%FFMPEG_DIR%".
    pause & goto :eof
)

:: ----------------------------------------------------------------
::  Locate colmap.exe (checks flat layout and bin\ subfolder)
:: ----------------------------------------------------------------
if exist "%COLMAP_DIR%\colmap.exe" (
    set "COLMAP=%COLMAP_DIR%\colmap.exe"
) else if exist "%COLMAP_DIR%\bin\colmap.exe" (
    set "COLMAP=%COLMAP_DIR%\bin\colmap.exe"
) else (
    echo [ERROR] colmap.exe not found inside "%COLMAP_DIR%".
    pause & goto :eof
)

:: Put COLMAP's dll folder on PATH so it can find its dependencies
set "PATH=%COLMAP_DIR%;%COLMAP_DIR%\bin;%PATH%"

:: ----------------------------------------------------------------
::  Sanity checks
:: ----------------------------------------------------------------
if not exist "%VIDEOS_DIR%" (
    echo [ERROR] Input folder "%VIDEOS_DIR%" missing.
    pause & goto :eof
)
if not exist "%SCENES_DIR%" mkdir "%SCENES_DIR%"

:: Count total video files for the progress display
for /f %%C in ('dir /b /a-d "%VIDEOS_DIR%\*" ^| find /c /v ""') do set "TOTAL=%%C"
if "%TOTAL%"=="0" (
    echo [INFO] No video files found in "%VIDEOS_DIR%".
    pause & goto :eof
)

echo ==============================================================
echo  COLMAP 4.0.2 — Starting on %TOTAL% video(s)
echo  Frame extraction rate : %EXTRACT_FPS% fps (~129 images expected)
echo ==============================================================

setlocal EnableDelayedExpansion
set /a IDX=0

for %%V in ("%VIDEOS_DIR%\*.*") do (
    if exist "%%~fV" (
        set /a IDX+=1
        call :PROCESS_VIDEO "%%~fV" "!IDX!" "%TOTAL%"
    )
)

echo --------------------------------------------------------------
echo  All jobs finished - results are in "%SCENES_DIR%".
echo --------------------------------------------------------------
pause
goto :eof


:: ================================================================
:PROCESS_VIDEO
::  %1 = full path to video   %2 = current index   %3 = total
:: ================================================================
setlocal
set "VIDEO=%~1"
set "NUM=%~2"
set "TOT=%~3"

for %%I in ("%VIDEO%") do (
    set "BASE=%%~nI"
    set "EXT=%%~xI"
)

echo.
echo [!NUM!/!TOT!] === Processing "!BASE!!EXT!" ===

:: Directory layout for this scene
set "SCENE=%SCENES_DIR%\!BASE!"
set "IMG_DIR=!SCENE!\images"
set "SPARSE_DIR=!SCENE!\sparse"

:: If scene folder already exists, skip (safe to re-run the script)
if exist "!SCENE!" (
    echo        Skip "!BASE!" - already reconstructed.
    goto :END
)

mkdir "!IMG_DIR!"    >nul
mkdir "!SPARSE_DIR!" >nul

:: ----------------------------------------------------------------
::  STEP 1 — Frame extraction
::
::  -vf fps=0.5 extracts one frame every 2 seconds.
::  For a 258-second video this gives ~129 images.
::
::  Your source is 2K (2560x1440). Frames are extracted at full
::  resolution — COLMAP's FeatureExtraction.max_image_size below
::  handles downscaling to 2048px for SIFT processing.
::
::  -qscale:v 2 is near-lossless JPEG quality (scale 1-31).
::  -loglevel warning shows codec/metadata warnings without
::  flooding the console with per-frame progress lines.
:: ----------------------------------------------------------------
echo        [1/4] Extracting frames at !EXTRACT_FPS! fps (~129 images) ...
"%FFMPEG%" -loglevel warning -stats ^
    -i "!VIDEO!" ^
    -vf fps=!EXTRACT_FPS! ^
    -qscale:v 2 ^
    "!IMG_DIR!\frame_%%06d.jpg"
if errorlevel 1 (
    echo        [FAIL] FFmpeg failed - skipping "!BASE!".
    goto :END
)

:: Confirm at least one frame was written
dir /b "!IMG_DIR!\*.jpg" >nul 2>&1 || (
    echo        [FAIL] No frames extracted - skipping "!BASE!".
    goto :END
)

:: ----------------------------------------------------------------
::  STEP 2 — SIFT feature extraction
::  Verified flags: `COLMAP.bat feature_extractor -h`
::
::  --ImageReader.single_camera 1
::      All frames come from the same lens. COLMAP estimates one
::      shared set of camera intrinsics across all images.
::      Essential for accurate reconstruction from video.
::
::  --FeatureExtraction.use_gpu 1
::      Use GPU (CUDA) for SIFT. Quadro M3000M is CUDA-capable.
::      Default is already 1, but explicit is better.
::
::  --FeatureExtraction.gpu_index 0
::      Pin to GPU 0 (your only GPU). Default -1 means auto-select
::      which also works, but 0 is unambiguous on a single-GPU machine.
::
::  --FeatureExtraction.max_image_size 2048
::      COLMAP downscales the longest edge to 2048px before SIFT.
::      Your frames are 2560px wide; this caps them conservatively
::      within the M3000M's 4GB VRAM budget. Default is -1 (no cap).
:: ----------------------------------------------------------------
echo        [2/4] COLMAP feature_extractor ...
"%COLMAP%" feature_extractor ^
    --database_path "!SCENE!\database.db" ^
    --image_path    "!IMG_DIR!" ^
    --ImageReader.single_camera 1 ^
    --FeatureExtraction.use_gpu 1 ^
    --FeatureExtraction.gpu_index 0 ^
    --FeatureExtraction.max_image_size 2048
if errorlevel 1 (
    echo        [FAIL] feature_extractor failed - skipping "!BASE!".
    goto :END
)

:: ----------------------------------------------------------------
::  STEP 3 — Sequential feature matching
::  Verified flags: `COLMAP.bat sequential_matcher -h`
::
::  --SequentialMatching.overlap 50
::      Each frame is matched against its 50 nearest neighbours in
::      each direction (100 pairs total per frame). At 0.5fps,
::      frames are 2 seconds apart — a wider window compensates
::      for the larger angular gap between them on the turntable.
::
::  Note: --SequentialMatching.quadratic_overlap defaults to 1
::  (enabled). COLMAP automatically adds quadratic-interval matches
::  on top of the linear overlap — extra coverage for free.
:: ----------------------------------------------------------------
echo        [3/4] COLMAP sequential_matcher ...
"%COLMAP%" sequential_matcher ^
    --database_path "!SCENE!\database.db" ^
    --SequentialMatching.overlap 50
if errorlevel 1 (
    echo        [FAIL] sequential_matcher failed - skipping "!BASE!".
    goto :END
)

:: ----------------------------------------------------------------
::  STEP 4 — Sparse reconstruction (Structure from Motion)
::  Verified flags: `COLMAP.bat mapper -h`
::
::  --Mapper.min_num_matches 10
::      Lowers the minimum feature matches required between a frame
::      pair from the default 15 to 10. Because frames are 2 seconds
::      apart, some pairs have fewer raw matches. This lets the
::      mapper register them rather than skipping, reducing gaps.
::
::  --Mapper.ba_use_gpu 1
::      Enables GPU-accelerated bundle adjustment. Default is 0
::      (CPU only). The M3000M is CUDA-capable so this speeds up
::      the most compute-intensive part of the reconstruction.
::
::  --Mapper.num_threads -1
::      Use all available CPU threads. -1 is already the default
::      but kept explicit for clarity. %NUMBER_OF_PROCESSORS% was
::      the original; -1 is cleaner and equivalent.
:: ----------------------------------------------------------------
echo        [4/4] COLMAP mapper ...
"%COLMAP%" mapper ^
    --database_path "!SCENE!\database.db" ^
    --image_path    "!IMG_DIR!" ^
    --output_path   "!SPARSE_DIR!" ^
    --Mapper.min_num_matches 10 ^
    --Mapper.ba_use_gpu 1 ^
    --Mapper.num_threads -1
if errorlevel 1 (
    echo        [FAIL] mapper failed - skipping "!BASE!".
    goto :END
)

:: ----------------------------------------------------------------
::  Export best model to human-readable TXT format.
::  COLMAP saves its reconstruction in sparse\0\ in binary format.
::  This converts it to cameras.txt, images.txt, points3D.txt —
::  the format expected by the next stages of the Video2Sim pipeline
::  (DA3, SAM3, HoloScene).
:: ----------------------------------------------------------------
if exist "!SPARSE_DIR!\0" (
    "%COLMAP%" model_converter ^
        --input_path  "!SPARSE_DIR!\0" ^
        --output_path "!SPARSE_DIR!" ^
        --output_type TXT >nul
    echo        [OK] Model exported to TXT in "!SPARSE_DIR!"
)

echo        [DONE] Finished "!BASE!"  (!NUM!/!TOT!)

:END
endlocal & goto :eof