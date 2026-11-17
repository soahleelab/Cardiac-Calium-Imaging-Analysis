# Cardiac-Calium-Imaging-Analysis
MATLAB-based clacium heatmap visualization and multi-ROI calcium transient analysis for fluorescence recordings of 3D cardiac models, including spheroids and organoids.
This repository provides two independent MATLAB scripts:
**1. 3D calcium heatmap analysis** — defines the sample boundary and generates time-resolved, pixel-wise △F/F0 heatmaps.
**2. Multi-ROI calcium transient analysis** — extracts fluorescence traces from equally sized circular regions of interest (ROIs) and quantifies calcium cycling parameters.

Both scripts can independently analyze the same input video.

# Setup for Cardiac-Calcium-Imaging-Analysis 
### 1. Installation - MATLAB
Install [MATLAB](https://www.mathworks.com/products/matlab.html) with the **Image Processing Toolbox** and **Signal Processing Toolbox**. The scripts were tested using MATLAB R2024b.
### 2. Preparation
Download the MATLAB scripts and prepare a calcium imaging video in .mp4 format. Open MATLAB and set the current folder to the directory containing the scripts. The frame rate is automatically detected, and analysis results are saved in the same directory as the input video.
