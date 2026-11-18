%% Clean up
clc; clear; close all;

%% File
[fileName, filePath] = uigetfile('*.mp4', 'Select a video file');
if isequal(fileName, 0); error('No file selected.'); end
fullFileName = fullfile(filePath, fileName);
[~, folderName, ~] = fileparts(fileName);

obj0 = VideoReader(fullFileName);
if obj0.NumFrames < 10; error('Video too short.'); end
fps = obj0.FrameRate;

%% ============================================================
% 분석 시간 구간 선택 (초 단위)
%% ============================================================
totalSec = obj0.Duration;
fprintf('Video duration: %.3f s | FrameRate: %.3f fps\n', totalSec, fps);

ansTW = inputdlg( ...
    {sprintf('Start time (s) [0 ~ %.3f]', totalSec), ...
     sprintf('End time (s) [0 ~ %.3f]', totalSec)}, ...
    'Analysis time window', [1 40], {'0', num2str(totalSec,'%.3f')});

if isempty(ansTW)
    tStart = 0; tEnd = totalSec;
else
    tStart = str2double(ansTW{1});
    tEnd   = str2double(ansTW{2});
    if ~isfinite(tStart), tStart = 0; end
    if ~isfinite(tEnd),   tEnd   = totalSec; end
end

tStart = max(0, min(totalSec, tStart));
tEnd   = max(0, min(totalSec, tEnd));
if tEnd < tStart, tmp=tStart; tStart=tEnd; tEnd=tmp; end

startFrame = max(1, floor(tStart * fps) + 1);
endFrame   = min(obj0.NumFrames, ceil(tEnd * fps));
fprintf('Using window: %.3f–%.3f s  (frames %d–%d)\n', tStart, tEnd, startFrame, endFrame);

%% ============================================================
% 3D spheroid analysis only (the original 3D mask algorithm is unchanged)
%% ============================================================
sampleType = '3D';

%% ============================================================
% 1) Rough ROI로 샘플 지정 -> iso-style sampleMask 생성
%% ============================================================
refFrame = read(VideoReader(fullFileName), 1);

figure('Color','k'); imshow(refFrame);
title('Draw ROUGH mask around the sample (double-click to finish)', 'Color','w');
h = drawfreehand('Color','y');
roughMask = createMask(h);
close(gcf);

[sampleMask, maskDebug] = refine_sample_mask(fullFileName, roughMask);

% mask 스냅샷 저장
maskFig = figure('Visible','off','Color','k');
imshow(maskDebug.meanImg_pct, [0 100]); hold on;
visboundaries(sampleMask, 'Color','w', 'LineWidth', 1.0);
title(sprintf('Final sample mask | %s', sampleType), 'Color','w');
exportgraphics(maskFig, fullfile(filePath, [folderName '_SampleMask.png']), 'Resolution', 200);
close(maskFig);

%% ============================================================
% 1.5) 배경 ROI 박스 선택
%% ============================================================
figure('Color','k'); imshow(refFrame);
title('Draw BACKGROUND ROI rectangle (NO sample). Double-click to finish.', 'Color','w');
hbg = drawrectangle('Color','c');
wait(hbg);
bgRect = round(hbg.Position);  % [x y w h]
close(gcf);

H = obj0.Height; W = obj0.Width;
bgRoiMask = false(H,W);
x1 = max(1, bgRect(1));
y1 = max(1, bgRect(2));
x2 = min(W, x1 + bgRect(3) - 1);
y2 = min(H, y1 + bgRect(4) - 1);
bgRoiMask(y1:y2, x1:x2) = true;

% 배경 ROI에서 샘플 픽셀 제외(안전)
bgRoiMask = bgRoiMask & ~sampleMask;
if nnz(bgRoiMask) < 100
    warning('Background ROI has too few pixels after excluding sample. BG ROI를 샘플 없는 곳에 다시 잡는 걸 권장.');
end

%% ============================================================
% 2) 샘플/배경 신호 추출 (선택 구간만)
%% ============================================================
obj = VideoReader(fullFileName);
nFramesSel = endFrame - startFrame + 1;
frameTime  = ((startFrame:endFrame) - 1) / fps;

sampleVals = nan(nFramesSel,1);  % S(t)
bgVals_t   = nan(nFramesSel,1);  % B(t)

% ----- 여기만 조절하면 배경이 "더 어둡게/덜 어둡게" 잡힘 -----
bgMode = 'prctile';   % 'median' | 'mean' | 'prctile'
bgDarkPrctile = 20;   % bgMode='prctile'일 때 10~40 (작을수록 더 어둡게)

sampleMode = 'median'; % 'mean' | 'median'

for k = 1:nFramesSel
    frIdx = startFrame + k - 1;
    fr = read(obj, frIdx);
    if size(fr,3)==3, g = rgb2gray(fr); else, g = fr; end
    g = double(g);

    sPix = g(sampleMask);
    bPix = g(bgRoiMask);

    % 샘플
    if strcmp(sampleMode,'mean')
        sampleVals(k) = mean(sPix, 'omitnan');
    else
        sampleVals(k) = median(sPix, 'omitnan');
    end

    % 배경
    if isempty(bPix)
        bgVals_t(k) = 0;
    else
        switch bgMode
            case 'mean'
                bgVals_t(k) = mean(bPix, 'omitnan');
            case 'median'
                bgVals_t(k) = median(bPix, 'omitnan');
            otherwise % 'prctile'
                bgVals_t(k) = prctile(bPix, bgDarkPrctile);
        end
    end
end

%% ============================================================
% 2.5) 그래프/엑셀용 dF/F0: (S-B) 기반
%% ============================================================
S = fillmissing(sampleVals,'linear','EndValues','nearest');
S = smoothdata(S, 'movmedian', 3);
S = smoothdata(S, 'movmean', 5);

B = fillmissing(bgVals_t,'linear','EndValues','nearest');
B = smoothdata(B, 'movmedian', 3);
B = smoothdata(B, 'movmean', 5);

xCorrTrace = S - B;
xCorrTrace(xCorrTrace < 0) = 0;

F0_mean = prctile(xCorrTrace, 5);
F0_floor_mean = prctile(xCorrTrace, 2);
F0_mean = max(F0_mean, max(F0_floor_mean, 1));   % 절대 floor

%% ============================================================
% 3) beat 분석 (bgOffset=0, intensityValues=xCorrTrace)
%    ✅ decay(10/50/90) 포함 버전
%% ============================================================
[result_raw, result_zero, ~] = analyze_sample_signal_two_outputs(xCorrTrace, frameTime, fullfile(filePath, folderName), fps, 0, F0_mean);

% 이후 코드가 result를 쓰고 있으면 기본은 "raw(영점맞춤X)"로 유지
result = result_raw;

%% ============================================================
% 4) Heatmap vmax (사용자 지정)
%% ============================================================
ansVmax = inputdlg( ...
    {'Heatmap colorbar max (dF/F0). Leave blank for auto-calculation:'}, ...
    'Heatmap Vmax', [1 55], {''});

dffMeanVals = result.intensityTable.("dF/F0");
dffMeanVals = dffMeanVals(isfinite(dffMeanVals));

if isempty(dffMeanVals)
    vmaxFromGraph = 1;
else
    vmaxFromGraph = prctile(dffMeanVals, 99.5);
end

if isempty(ansVmax) || isempty(strtrim(ansVmax{1}))
    % 빈칸이면 기존 자동 방식 사용
    vmaxHeat = 1.2 * vmaxFromGraph;
    vmaxMode = "Auto";
else
    vmaxHeat = str2double(ansVmax{1});
    if ~isfinite(vmaxHeat) || vmaxHeat <= 0
        warning('Invalid vmax input -> auto mode used.');
        vmaxHeat = 1.2 * vmaxFromGraph;
        vmaxMode = "Auto";
    else
        vmaxMode = "Manual";
    end
end

if ~isfinite(vmaxHeat) || vmaxHeat <= 0
    vmaxHeat = 1;
end

%% ============================================================
% 5) 히트맵 생성 (BG ROI 기반)
%% ============================================================
heatmapSmoothSigma = 1.2;
f0FloorPrctile_px  = 5;

create_dff0_heatmap_video_with_bgROI(fullFileName, filePath, folderName, sampleMask, vmaxHeat, ...
    bgRoiMask, bgMode, bgDarkPrctile, f0FloorPrctile_px, heatmapSmoothSigma, startFrame, endFrame);

%% ============================================================
% 6) Excel 저장  (✅ Beat Metrics에 decay 포함)
%% ============================================================
exportName = fullfile(filePath, [folderName '.xlsx']);
% (A) 기존 방식(raw, 영점맞춤 X)
writetable(result_raw.intensityTable,  exportName, 'Sheet','Results_Sample_RAW');
writetable(result_raw.beatMetrics,     exportName, 'Sheet','Beat Metrics_RAW');
writetable(result_raw.intervalMetrics, exportName, 'Sheet','Intervals_RAW');

% (B) local minima zero 영점맞춤 적용
writetable(result_zero.intensityTable,  exportName, 'Sheet','Results_Sample_Zeroed');
writetable(result_zero.beatMetrics,     exportName, 'Sheet','Beat Metrics_Zeroed');
writetable(result_zero.intervalMetrics, exportName, 'Sheet','Intervals_Zeroed');

Summary = table;
Summary.AnalysisStart_s = tStart;
Summary.AnalysisEnd_s   = tEnd;
Summary.FrameRate_FPS   = fps;
Summary.NumFrames       = nFramesSel;
Summary.NumFramesTotal  = obj0.NumFrames;

Summary.SampleArea_px   = nnz(sampleMask);

Summary.BPM_Mean        = mean(result.beatMetrics.BPM,'omitnan');
Summary.F0_mean_bgtrace  = F0_mean;
Summary.F0_floor_bgtrace = F0_floor_mean;

Summary.BG_Mode     = string(bgMode);
Summary.BG_Prctile  = bgDarkPrctile;
Summary.Sample_Mode = string(sampleMode);

Summary.BGROI_x = x1; Summary.BGROI_y = y1;
Summary.BGROI_w = (x2-x1+1); Summary.BGROI_h = (y2-y1+1);

Summary.HeatmapVmax_FromGraph = vmaxFromGraph;
Summary.HeatmapVmax_Final     = vmaxHeat;
Summary.HeatmapSmoothSigma    = heatmapSmoothSigma;
Summary.HeatmapF0FloorPct_px  = f0FloorPrctile_px;

writetable(Summary, exportName, 'Sheet','Summary', 'WriteMode','overwrite');

disp('Done: Beat Metrics sheet includes decay (10/50/90) + BPM.');

%% ======================================================================
% helper 1) refine_sample_mask (iso 스타일)
%% ======================================================================
function [sampleMask, dbg] = refine_sample_mask(fullFileName, roughMask)
% refine_sample_mask: 3D iso-style score mask (std/amp weighted)
% + fill inside + smooth boundary
%
% NOTE: peak/beat detection is handled elsewhere; this function ONLY builds sampleMask.

obj = VideoReader(fullFileName);
H = obj.Height; W = obj.Width;

meanAcc = zeros(H,W,'double');
M2      = zeros(H,W,'double');
minImg  = inf(H,W);
maxImg  = -inf(H,W);

cnt = 0;
while hasFrame(obj)
    cnt = cnt + 1;
    fr = readFrame(obj);
    if size(fr,3)==3, g = rgb2gray(fr); else, g = fr; end
    g = double(g);

    % online mean / var
    delta = g - meanAcc;
    meanAcc = meanAcc + delta / cnt;
    delta2 = g - meanAcc;
    M2 = M2 + delta .* delta2;

    minImg = min(minImg, g);
    maxImg = max(maxImg, g);
end

meanImg_all = meanAcc;
stdImg_all  = sqrt(M2 / max(cnt-1,1));
ampImg_all  = maxImg - minImg;

% =========================================================
% Robust normalization (within roughMask) -> stable contrast
% =========================================================
rm = roughMask & isfinite(meanImg_all);
if nnz(rm) < 10
    rm = true(H,W);
end

% mean image -> 0~100
v = meanImg_all(rm); v = v(isfinite(v));
p1 = prctile(v, 1); p99 = prctile(v, 99);
meanImg_pct = 100 * (meanImg_all - p1) / (p99 - p1 + eps);
meanImg_pct = max(0, min(100, meanImg_pct));
meanN = meanImg_pct / 100;

% std -> 0~1
v = stdImg_all(rm); v = v(isfinite(v));
p1 = prctile(v, 1); p99 = prctile(v, 99);
stdN = (stdImg_all - p1) / (p99 - p1 + eps);
stdN = max(0, min(1, stdN));

% amp -> 0~1
v = ampImg_all(rm); v = v(isfinite(v));
p1 = prctile(v, 1); p99 = prctile(v, 99);
ampN = (ampImg_all - p1) / (p99 - p1 + eps);
ampN = max(0, min(1, ampN));

% =========================================================
% Build mask
% =========================================================
% -------------------------
% 3D: original iso-style score mask
% + fill inside + smooth boundary
% -------------------------
maskScore = 0.20*meanN + 0.25*stdN + 0.55*ampN;

if exist('imgaussfilt','file')==2
    maskScoreSm = imgaussfilt(maskScore, 1.2);
else
    maskScoreSm = maskScore;
end
maskScoreSm(~roughMask) = 0;

% Otsu on roughMask only
if exist('graythresh','file')==2
    otsuLevel = graythresh(maskScoreSm(roughMask));
else
    vv = maskScoreSm(roughMask);
    otsuLevel = median(vv(:), 'omitnan');
    if ~isfinite(otsuLevel), otsuLevel = 0.5; end
end

looseLevel = max(0, 0.75 * otsuLevel);
coreLevel  = min(1, 1.05 * otsuLevel);

looseMask = (maskScoreSm > looseLevel) & roughMask;
coreMask  = (maskScoreSm > coreLevel ) & roughMask;
if ~any(coreMask(:)), coreMask = looseMask; end

if exist('imreconstruct','file')==2
    sampleMask = imreconstruct(coreMask, looseMask);
else
    sampleMask = looseMask;
end

% --- connect broken boundary, then fill inside ---
areaRM = nnz(roughMask);
closeRad = min(15, max(6, round(sqrt(areaRM)/120))); % typically 6~15
openRad  = min(6,  max(2, round(closeRad/3)));

if exist('strel','file')==2
    seClose = strel('disk', closeRad);
    seOpen  = strel('disk', openRad);

    if exist('imclose','file')==2, sampleMask = imclose(sampleMask, seClose); end
    if exist('imfill','file')==2,  sampleMask = imfill(sampleMask, 'holes'); end
    if exist('imopen','file')==2,  sampleMask = imopen(sampleMask, seOpen);  end
else
    if exist('imfill','file')==2, sampleMask = imfill(sampleMask, 'holes'); end
end

% remove small pieces, keep largest
minAreaPix = max(200, round(numel(sampleMask)*0.002));
if exist('bwareaopen','file')==2, sampleMask = bwareaopen(sampleMask, minAreaPix); end
if exist('bwareafilt','file')==2 && any(sampleMask(:))
    sampleMask = bwareafilt(sampleMask, 1);
end

% --- smooth boundary to avoid "jagged / broken-looking" outline ---
sigmaMask3D = 2.0;
thrMask3D   = 0.45;

if exist('imgaussfilt','file')==2 && any(sampleMask(:))
    soft = imgaussfilt(double(sampleMask), sigmaMask3D);
    sampleMask = soft >= thrMask3D;
end

if exist('strel','file')==2
    seFinal = strel('disk', 4);
    if exist('imclose','file')==2, sampleMask = imclose(sampleMask, seFinal); end
end
if exist('imfill','file')==2, sampleMask = imfill(sampleMask, 'holes'); end
if exist('bwareafilt','file')==2 && any(sampleMask(:))
    sampleMask = bwareafilt(sampleMask, 1);
end

sampleMask = sampleMask & roughMask;

% fallback
if ~any(sampleMask(:))
    warning('iso-style mask failed -> using roughMask as sample');
    sampleMask = roughMask;
end

dbg.meanImg_pct = meanImg_pct;
end


%% ======================================================================
% helper 2) 샘플 전체 신호 분석
%% ======================================================================
function [out_raw, out_zero, plots] = analyze_sample_signal_two_outputs(intensityValues, frameTime, saveBasePath, fps, bgOffset, F0_mean)
% out_raw  : 기존 방식 (영점맞춤 X)
% out_zero : local minima 기반 영점맞춤 (beat마다 baseline을 0으로)

% =========================
% 0) 공통 전처리
% =========================
x = fillmissing(intensityValues,'linear','EndValues','nearest');
x = smoothdata(x, 'movmedian', 3);
x = smoothdata(x, 'movmean', 5);

xCorr = x - bgOffset;
xCorr(xCorr < 0) = 0;

FF0_global  = xCorr / max(F0_mean, eps);
dFF0_global = (xCorr - F0_mean) / max(F0_mean, eps);
dFF0_global(dFF0_global < 0) = 0;

% =========================
% 1) minima 기반 beat segmentation
% =========================
tmp = smoothdata(dFF0_global, 'movmean', max(3, round(0.05*fps)));
minIdx = find(islocalmin(tmp));
if numel(minIdx) < 2
    minIdx = find(islocalmin(xCorr));
end
minGap = max(2, round(0.2*fps));
minIdx = enforce_min_distance(minIdx, minGap);

% 시작/끝 포함 (마지막 beat 누락 방지)
minIdx = unique([1; minIdx(:); numel(dFF0_global)]);
minIdx = sort(minIdx(:));

% =========================
% 2) peak detection (RAW dF/F0 기반)
% =========================
sig = smoothdata(dFF0_global, 'movmean', max(3, round(0.03*fps)));

minPeakDist = max(2, round(0.30 * fps));
sigFinite = sig(isfinite(sig));
if isempty(sigFinite)
    sigRange = 0;
else
    sigRange = prctile(sigFinite, 95) - prctile(sigFinite, 5);
end
minProm  = max(0.02, 0.20 * sigRange);
minWidth = max(1, round(0.02 * fps));

[pks, pkIdx] = findpeaks(sig, ...
    'MinPeakDistance', minPeakDist, ...
    'MinPeakProminence', minProm, ...
    'MinPeakWidth', minWidth);

pkIdx = keep_one_peak_per_segment(pkIdx, pks, minIdx);

% =========================
% 3) (A) RAW 결과 생성
% =========================
[out_raw, plots_raw] = build_metrics_tables( ...
    frameTime, xCorr, FF0_global, dFF0_global, minIdx, pkIdx, saveBasePath, 'RAW');

% =========================
% 4) (B) local minima zero 영점맞춤 버전 생성
%     - 각 beat 구간 [minIdx(b) : minIdx(b+1)] 에서 baseline을 0으로 재정의
% =========================
dFF0_zero = dFF0_global;   % 복사
FF0_zero  = FF0_global;    % (원하면 F/F0도 beat-wise로 바꿀 수 있지만 기본은 유지)

for b = 1:numel(minIdx)-1
    st_i = minIdx(b);
    en_i = minIdx(b+1);
    if en_i <= st_i, continue; end

    base = min(dFF0_global(st_i:en_i), [], 'omitnan'); % local minima
    if ~isfinite(base), base = 0; end

    z = dFF0_global(st_i:en_i) - base;
    z(z < 0) = 0;
    dFF0_zero(st_i:en_i) = z;
end

dFF0_zero(~isfinite(dFF0_zero)) = 0;

[out_zero, plots_zero] = build_metrics_tables( ...
    frameTime, xCorr, FF0_zero, dFF0_zero, minIdx, pkIdx, saveBasePath, 'Zeroed');

plots = struct();
plots.raw  = plots_raw;
plots.zero = plots_zero;

end  % <-- 이 end가 analyze_sample_signal_two_outputs 함수 끝



function [out, plots] = build_metrics_tables(frameTime, xCorr, FF0, dFF0, minIdx, pkIdx, saveBasePath, tag)
% tag: 'RAW' or 'Zeroed'

% =========================
% Beat metrics (+decay + cycle duration + BPM)
% =========================
beatMetrics = table();

for b = 1:max(0, numel(minIdx)-1)
    st_i = minIdx(b);
    en_i = minIdx(b+1);

    st = frameTime(st_i);
    en = frameTime(en_i);

    cycleDur = en - st;       % calcium cycle duration (s)
    bpm = 60 ./ cycleDur;     % BPM

    segPk = pkIdx(pkIdx > st_i & pkIdx < en_i);

    if isempty(segPk)
        pk = NaN; Fmax = NaN; dFmax = NaN;
        t10 = NaN; t50 = NaN; t90 = NaN;
    else
        peakI = segPk(1);
        pk = frameTime(peakI);

        Fmax  = max(FF0(st_i:en_i),  [], 'omitnan');
        dFmax = max(dFF0(st_i:en_i), [], 'omitnan');

        % ---- Time to decay (dF/F0 기준) ----
        peakVal = dFF0(peakI);
        if ~isfinite(peakVal) || peakVal <= 0
            t10 = NaN; t50 = NaN; t90 = NaN;
        else
            % peak -> 90%, 50%, 10% of peak로 떨어지는 시간
            targets = [0.9 0.5 0.1] * peakVal;
            t10 = NaN; t50 = NaN; t90 = NaN;

            for tt = 1:3
                idx = find(dFF0(peakI:en_i) <= targets(tt), 1, 'first');
                if isempty(idx), continue; end
                dt = frameTime(peakI + idx - 1) - frameTime(peakI);

                if tt == 1, t10 = dt;
                elseif tt == 2, t50 = dt;
                else, t90 = dt;
                end
            end
        end
    end

    beatMetrics = [beatMetrics; table(st, pk, en, cycleDur, bpm, Fmax, dFmax, t10, t50, t90)]; %#ok<AGROW>
end

if ~isempty(beatMetrics)
    beatMetrics.Properties.VariableNames = { ...
        'Start Time','Peak Time','End Time', ...
        'Calcium cycle duration (s)','BPM', ...
        'F/F0 Max','dF/F0 Max', ...
        'Time to Decay 10% (s)','Time to Decay 50% (s)','Time to Decay 90% (s)'};
else
    beatMetrics = table('Size',[0 10], ...
        'VariableTypes',{'double','double','double','double','double','double','double','double','double','double'}, ...
        'VariableNames',{ ...
        'Start Time','Peak Time','End Time', ...
        'Calcium cycle duration (s)','BPM', ...
        'F/F0 Max','dF/F0 Max', ...
        'Time to Decay 10% (s)','Time to Decay 50% (s)','Time to Decay 90% (s)'});
end

% =========================
% Intervals
% =========================
if height(beatMetrics) >= 2
    startIntervals = diff(beatMetrics.('Start Time'));
    peakIntervals  = diff(beatMetrics.('Peak Time'));
    endIntervals   = diff(beatMetrics.('End Time'));
    intervalMetrics = table(startIntervals, peakIntervals, endIntervals, ...
        'VariableNames', {'Start-to-Start Interval','Peak-to-Peak Interval','End-to-End Interval'});
else
    intervalMetrics = table([],[],[], ...
        'VariableNames', {'Start-to-Start Interval','Peak-to-Peak Interval','End-to-End Interval'});
end

% =========================
% Results table
% =========================
intensityTable = table(frameTime(:), xCorr(:), FF0(:), dFF0(:), ...
    'VariableNames', {'Time (s)','Intensity','F/F0','dF/F0'});

% =========================
% Plot 저장 (RAW / Zeroed 각각 파일로 저장)
% =========================
f = figure('Visible','off');
plot(frameTime, dFF0, 'b-'); hold on;
plot(frameTime(pkIdx), dFF0(pkIdx), 'ko', 'MarkerSize', 4, 'LineWidth', 1);
title(sprintf('dF/F0 (%s; peaks marked)', tag));
xlabel('Time (s)'); ylabel('dF/F0'); grid on;
saveas(f, [saveBasePath '_Sample_dFF0_Plot_' tag '.png']);
close(f);

out.intensityTable  = intensityTable;
out.beatMetrics     = beatMetrics;
out.intervalMetrics = intervalMetrics;
plots = struct();

end

function idxOut = enforce_min_distance(idxIn, minDist)
if isempty(idxIn), idxOut = idxIn; return; end
idxIn = sort(idxIn(:));
idxOut = idxIn(1);
for k = 2:numel(idxIn)
    if idxIn(k) - idxOut(end) >= minDist
        idxOut(end+1,1) = idxIn(k); %#ok<AGROW>
    end
end
end

function pkIdxOut = keep_one_peak_per_segment(pkIdx, pks, minIdx)
pkIdxOut = [];
if isempty(pkIdx) || numel(minIdx) < 2, return; end
for b = 1:numel(minIdx)-1
    st = minIdx(b);
    en = minIdx(b+1);
    inSeg = find(pkIdx > st & pkIdx < en);
    if isempty(inSeg), continue; end
    [~, m] = max(pks(inSeg));
    pkIdxOut(end+1,1) = pkIdx(inSeg(m)); %#ok<AGROW>
end
pkIdxOut = sort(pkIdxOut);
end

%% ======================================================================
% helper 3) dF/F0 heatmap video (BG ROI 기반)
%% ======================================================================
function create_dff0_heatmap_video_with_bgROI(fullFileName, filePath, folderName, sampleMask, vmax, ...
    bgRoiMask, bgMode, bgDarkPrctile, f0FloorPrctile_px, smoothSigma, startFrame, endFrame)

obj = VideoReader(fullFileName);
fps = obj.FrameRate;
H = obj.Height; W = obj.Width;

nFramesSel = endFrame - startFrame + 1;
stack = zeros(H,W,nFramesSel,'single');
bgVec = zeros(nFramesSel,1);

% 1) 프레임 스택 + 프레임별 배경 B(t) 계산
for k = 1:nFramesSel
    frIdx = startFrame + k - 1;
    fr = read(obj, frIdx);
    if size(fr,3)==3, g = rgb2gray(fr); else, g = fr; end
    g = double(g);

    bPix = g(bgRoiMask);
    if isempty(bPix)
        b = 0;
    else
        switch bgMode
            case 'mean'
                b = mean(bPix, 'omitnan');
            case 'median'
                b = median(bPix, 'omitnan');
            otherwise
                b = prctile(bPix, bgDarkPrctile);
        end
    end
    bgVec(k) = b;

    gCorr = g - b;
    gCorr(gCorr < 0) = 0;

    stack(:,:,k) = single(gCorr);
end

% 2) pixel-wise F0 (10th percentile)
F0img = prctile(double(stack), 10, 3);
F0img = imgaussfilt(F0img, 1);

% 3) F0 floor (폭발 방지) — percentile + 절대 floor
f0vals = F0img(sampleMask);
f0vals = f0vals(isfinite(f0vals));
if isempty(f0vals)
    f0Floor = 1;
else
    f0Floor = prctile(f0vals, f0FloorPrctile_px);
    if ~isfinite(f0Floor) || f0Floor <= 0, f0Floor = 1; end
    f0Floor = max(f0Floor, 1);
end
F0img = max(F0img, f0Floor);

% 4) dF/F0
dff = (double(stack) - F0img) ./ F0img;
dff(~isfinite(dff)) = 0;
dff(dff < 0) = 0;

if ~isfinite(vmax) || vmax <= 0, vmax = 1; end

outName = fullfile(filePath, [folderName '_dFF0_Heatmap_BGROI.mp4']);
vw = VideoWriter(outName, 'MPEG-4');
vw.FrameRate = fps;
open(vw);

fig = figure('Visible','off','Color','k','Position',[100 100 900 700]);
ax = axes(fig); set(ax,'Color','k');

imgH = imagesc(ax, zeros(H,W), [0 vmax]);
axis(ax,'image'); axis(ax,'off');
colormap(ax, jet(256));
set(imgH, 'AlphaData', sampleMask);

cb = colorbar(ax);
cb.Color = 'w';
cb.Label.String = 'dF/F0';
cb.Label.Color = 'w';
title(ax, sprintf('dF/F0 Heatmap (BG ROI corrected) (0 to %.2f)', vmax), ...
    'Color','w','FontWeight','bold');

for t = 1:size(dff,3)
    tmp = dff(:,:,t);

    if smoothSigma > 0
        tmp = imgaussfilt(tmp, smoothSigma);
    end

    tmp(tmp > vmax) = vmax;
    tmp(tmp < 0) = 0;

    tmp(~sampleMask) = 0;
    set(imgH, 'CData', tmp);
    drawnow;

    frOut = getframe(fig);
    img = frOut.cdata;
    hh = size(img,1); ww = size(img,2);
    img = img(1:(hh-mod(hh,2)), 1:(ww-mod(ww,2)), :);
    writeVideo(vw, img);
end

close(vw); close(fig);
try implay(outName); end
end

%% ======================================================================
% local: choose_center_component
%% ======================================================================
function outMask = choose_center_component(inMask, scoreMap)
outMask = false(size(inMask));
if ~any(inMask(:)), return; end

CC = bwconncomp(inMask);
if CC.NumObjects == 1
    outMask = inMask;
    return;
end

imgSize = size(inMask);
cx0 = (imgSize(2)+1)/2;
cy0 = (imgSize(1)+1)/2;
diagLen = hypot(imgSize(1), imgSize(2));

bestScore = -inf;
bestIdx = 1;

allAreas = cellfun(@numel, CC.PixelIdxList);
maxArea = max(allAreas);

for k = 1:CC.NumObjects
    pix = CC.PixelIdxList{k};
    [yy, xx] = ind2sub(imgSize, pix);

    areaNorm = numel(pix) / (maxArea + eps);
    meanScore = mean(scoreMap(pix));

    cxd = mean(xx);
    cyd = mean(yy);
    distNorm = hypot(cxd-cx0, cyd-cy0) / (diagLen + eps);

    totalScore = 0.50*meanScore + 0.35*areaNorm - 0.35*distNorm;

    if totalScore > bestScore
        bestScore = totalScore;
        bestIdx = k;
    end
end

outMask(CC.PixelIdxList{bestIdx}) = true;
if exist('imfill','file')==2
    outMask = imfill(outMask, 'holes');
end
end