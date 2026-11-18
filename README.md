# Cardiac-Calcium-Imaging-Analysis
MATLAB-based clacium heatmap visualization and multi-ROI calcium transient analysis for fluorescence recordings of 3D cardiac models, including spheroids and organoids.
This repository provides two independent MATLAB scripts:

**1. 3D calcium heatmap analysis** — defines the sample boundary and generates time-resolved, pixel-wise △F/F0 heatmaps.

**2. Multi-ROI calcium transient analysis** — extracts fluorescence traces from equally sized circular regions of interest (ROIs) and quantifies calcium cycling parameters.

Both scripts can independently analyze the same input video.

# Setup
### 1. Installation - MATLAB
Install [MATLAB](https://www.mathworks.com/products/matlab.html) with the **Image Processing Toolbox** and **Signal Processing Toolbox**. The scripts were tested using MATLAB R2024b.
### 2. Preparation
Download the MATLAB scripts and prepare a calcium imaging video in **.mp4** format. Open MATLAB and set the current folder to the directory containing the scripts. The frame rate is automatically detected, and analysis results are saved in the same directory as the input video.

# Running Tutorial
### 1. 3D Calcium Heatmap Analysis
Run Calcium_Heatmap_3D.m in MATLAB.
1. Select an input video and specify the analysis time range.
   
   <img width="400" alt="time range" src="https://github.com/user-attachments/assets/c5aed79f-5cb7-4903-a09d-4131180f52d3" />
3. Draw a freehand ROI around the sample to generate a 3D tissue mask.
   <img width="1097" height="385" alt="masking" src="https://github.com/user-attachments/assets/d02bb4b2-56a0-4646-b128-f4f146fb585e" />
4. Select a sample-free region for background correction.
   
   <img width="400" alt="background selection" src="https://github.com/user-attachments/assets/ef140ac7-d302-4a60-bc51-f6ed2ebfc42a" />
5. Set the heatmap color scale (or use automatic scaling) to generate the △F/F0 heatmap.
   <img width="400" alt="color scale" src="https://github.com/user-attachments/assets/54a040b8-b108-4793-bd56-0beddc00811a" />

**Output**
: Tissue mask image, △F/F0 heatmap video, calcium transient plots, and exel analysis results.

### 2. Multi-ROI Calcium Transient Analysis
Run Calcium_MultiROI_Analysis.m in MATLAB.
1. Select an input video and specify the analysis time range.
2. Draw the first circular ROI, then select the centers of five additional ROIs with the same radius.
   <img width="400" alt="ROI selection" src="https://github.com/user-attachments/assets/4d414988-9532-4111-bc75-611e85708a55" />
3. Select a sample-free region for background correction.
4. The script automatically generates △F/F0  traces and quantifies calcium transient parameters.

**Output**
: ROI selection images, individual and overlaid △F/F0 traces, and excel files containing calcium cycling frequency, cycle duration, peak amplitude, and temporal parameters.
