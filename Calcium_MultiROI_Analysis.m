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
H = obj0.Height;
W = obj0.Width;

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
% 1) 원형 ROI 1개 지정 후, 같은 크기로 추가 5개 지정 (총 6개)
%% ============================================================
refFrame = read(VideoReader(fullFileName), 1);
numROIs = 6;
[roiMasks, roiCenters, roiRadius] = draw_same_size_circle_rois(refFrame, numROIs);
unionRoiMask = false(H, W);
for r = 1:numROIs
    unionRoiMask = unionRoiMask | roiMasks(:,:,r);
end

% ROI overview 저장
roiFig = figure('Visible','off','Color','k');
imshow(refFrame); hold on;
for r = 1:numROIs
    plot_circle_outline(roiCenters(r,:), roiRadius, 'y', 1.5);
    text(roiCenters(r,1), roiCenters(r,2), sprintf('  ROI %d', r), ...
        'Color','y','FontSize',10,'FontWeight','bold');
end
title(sprintf('Circular ROIs (n = %d)', numROIs), 'Color','w');
exportgraphics(roiFig, fullfile(filePath, [folderName '_ROI_Overview.png']), 'Resolution', 200);
close(roiFig);

% ROI 정의 테이블
roiAreaPx = squeeze(sum(sum(roiMasks,1),2));
roiDefinitionTable = table((1:numROIs)', roiCenters(:,1), roiCenters(:,2), ...
    repmat(roiRadius, numROIs, 1), roiAreaPx(:), ...
    'VariableNames', {'ROI','CenterX_px','CenterY_px','Radius_px','Area_px'});

%% ============================================================
% 1.5) 배경 ROI 박스 선택 (기존 방식 유지)
%% ============================================================
figure('Color','k'); imshow(refFrame);
hold on;
for r = 1:numROIs
    plot_circle_outline(roiCenters(r,:), roiRadius, 'y', 1.2);
end
title('Draw BACKGROUND ROI rectangle (NO sample). Double-click to finish.', 'Color','w');
hbg = drawrectangle('Color','c');
wait(hbg);
bgRect = round(hbg.Position);  % [x y w h]
close(gcf);

bgRoiMask = false(H, W);
x1 = max(1, bgRect(1));
y1 = max(1, bgRect(2));
x2 = min(W, x1 + bgRect(3) - 1);
y2 = min(H, y1 + bgRect(4) - 1);
bgRoiMask(y1:y2, x1:x2) = true;

% 배경 ROI에서 샘플 ROI 제외(안전)
bgRoiMask = bgRoiMask & ~unionRoiMask;
if nnz(bgRoiMask) < 100
    warning('Background ROI has too few pixels after excluding ROI masks. BG ROI를 샘플 없는 곳에 다시 잡는 걸 권장.');
end

% Background overview 저장
bgFig = figure('Visible','off','Color','k');
imshow(refFrame); hold on;
for r = 1:numROIs
    plot_circle_outline(roiCenters(r,:), roiRadius, 'y', 1.2);
end
plot_mask_boundary(bgRoiMask, 'c', 1.0);
title('ROIs + Background ROI', 'Color','w');
exportgraphics(bgFig, fullfile(filePath, [folderName '_ROI_Background_Overview.png']), 'Resolution', 200);
close(bgFig);

%% ============================================================
% 2) ROI별 샘플/배경 신호 추출 (선택 구간만)
%% ============================================================
obj = VideoReader(fullFileName);
nFramesSel = endFrame - startFrame + 1;
frameTime  = ((startFrame:endFrame) - 1) / fps;

sampleVals = nan(nFramesSel, numROIs);  % 각 ROI의 S(t)
bgVals_t   = nan(nFramesSel, 1);        % 공통 B(t)

% ----- 여기만 조절하면 배경이 "더 어둡게/덜 어둡게" 잡힘 -----
bgMode = 'prctile';   % 'median' | 'mean' | 'prctile'
bgDarkPrctile = 20;   % bgMode='prctile'일 때 10~40 (작을수록 더 어둡게)

sampleMode = 'median'; % 'mean' | 'median'

for k = 1:nFramesSel
    frIdx = startFrame + k - 1;
    fr = read(obj, frIdx);
    if size(fr,3)==3, g = rgb2gray(fr); else, g = fr; end
    g = double(g);

    bPix = g(bgRoiMask);
    if isempty(bPix)
        bgVals_t(k) = 0;
    else
        switch bgMode
            case 'mean'
                bgVals_t(k) = mean(bPix, 'omitnan');
            case 'median'
                bgVals_t(k) = median(bPix, 'omitnan');
            otherwise
                bgVals_t(k) = prctile(bPix, bgDarkPrctile);
        end
    end

    for r = 1:numROIs
        sPix = g(roiMasks(:,:,r));
        if isempty(sPix)
            sampleVals(k, r) = NaN;
        else
            if strcmp(sampleMode,'mean')
                sampleVals(k, r) = mean(sPix, 'omitnan');
            else
                sampleVals(k, r) = median(sPix, 'omitnan');
            end
        end
    end
end

%% ============================================================
% 3) ROI별 분석 + 그래프 저장 + Excel 저장
%% ============================================================
exportName = fullfile(filePath, [folderName '_MultiROI.xlsx']);
if exist(exportName, 'file') == 2
    delete(exportName);
end

roiSummary = table();
allBeatMetricsRaw = table();
allBeatMetricsZero = table();
allIntervalMetricsRaw = table();
allIntervalMetricsZero = table();

all_dFF0_raw  = nan(nFramesSel, numROIs);
all_dFF0_zero = nan(nFramesSel, numROIs);

for r = 1:numROIs
    roiLabel = sprintf('ROI%d', r);

    S = fillmissing(sampleVals(:,r), 'linear', 'EndValues', 'nearest');
    S = smoothdata(S, 'movmedian', 3);
    S = smoothdata(S, 'movmean', 5);

    B = fillmissing(bgVals_t, 'linear', 'EndValues', 'nearest');
    B = smoothdata(B, 'movmedian', 3);
    B = smoothdata(B, 'movmean', 5);

    xCorrTrace = S - B;
    xCorrTrace(xCorrTrace < 0) = 0;

    F0_mean = prctile(xCorrTrace, 5);
    F0_floor_mean = prctile(xCorrTrace, 2);
    F0_mean = max(F0_mean, max(F0_floor_mean, 1));

    [result_raw, result_zero, ~] = analyze_sample_signal_two_outputs( ...
        xCorrTrace, frameTime, fullfile(filePath, folderName), fps, 0, F0_mean, roiLabel);

    all_dFF0_raw(:,r)  = result_raw.intensityTable.('dF/F0');
    all_dFF0_zero(:,r) = result_zero.intensityTable.('dF/F0');

    % 시트명은 31자 이하 유지
    writetable(result_raw.intensityTable,  exportName, 'Sheet', sprintf('%s_RAW', roiLabel));
    writetable(result_raw.beatMetrics,     exportName, 'Sheet', sprintf('%s_RAW_Beats', roiLabel));
    writetable(result_raw.intervalMetrics, exportName, 'Sheet', sprintf('%s_RAW_Intv', roiLabel));

    writetable(result_zero.intensityTable,  exportName, 'Sheet', sprintf('%s_ZERO', roiLabel));
    writetable(result_zero.beatMetrics,     exportName, 'Sheet', sprintf('%s_ZERO_Beats', roiLabel));
    writetable(result_zero.intervalMetrics, exportName, 'Sheet', sprintf('%s_ZERO_Intv', roiLabel));

    % 종합 시트용 테이블 누적
    beatRawTmp = result_raw.beatMetrics;
    if ~isempty(beatRawTmp)
        beatRawTmp = addvars(beatRawTmp, repmat(string(roiLabel), height(beatRawTmp), 1), ...
            'Before', 1, 'NewVariableNames', 'ROI');
        allBeatMetricsRaw = [allBeatMetricsRaw; beatRawTmp]; %#ok<AGROW>
    end

    beatZeroTmp = result_zero.beatMetrics;
    if ~isempty(beatZeroTmp)
        beatZeroTmp = addvars(beatZeroTmp, repmat(string(roiLabel), height(beatZeroTmp), 1), ...
            'Before', 1, 'NewVariableNames', 'ROI');
        allBeatMetricsZero = [allBeatMetricsZero; beatZeroTmp]; %#ok<AGROW>
    end

    intRawTmp = result_raw.intervalMetrics;
    if ~isempty(intRawTmp)
        intRawTmp = addvars(intRawTmp, repmat(string(roiLabel), height(intRawTmp), 1), ...
            'Before', 1, 'NewVariableNames', 'ROI');
        allIntervalMetricsRaw = [allIntervalMetricsRaw; intRawTmp]; %#ok<AGROW>
    end

    intZeroTmp = result_zero.intervalMetrics;
    if ~isempty(intZeroTmp)
        intZeroTmp = addvars(intZeroTmp, repmat(string(roiLabel), height(intZeroTmp), 1), ...
            'Before', 1, 'NewVariableNames', 'ROI');
        allIntervalMetricsZero = [allIntervalMetricsZero; intZeroTmp]; %#ok<AGROW>
    end

    % ROI summary
    roiSummary = [roiSummary; table( ...
        string(roiLabel), roiCenters(r,1), roiCenters(r,2), roiRadius, roiAreaPx(r), ...
        F0_mean, F0_floor_mean, ...
        mean(result_raw.beatMetrics.BPM, 'omitnan'), ...
        mean(result_zero.beatMetrics.BPM, 'omitnan'), ...
        max(result_raw.intensityTable.('dF/F0'), [], 'omitnan'), ...
        max(result_zero.intensityTable.('dF/F0'), [], 'omitnan'), ...
        'VariableNames', {'ROI','CenterX_px','CenterY_px','Radius_px','Area_px', ...
        'F0_mean_bgtrace','F0_floor_bgtrace','BPM_Mean_RAW','BPM_Mean_ZERO','dFF0_Max_RAW','dFF0_Max_ZERO'})]; %#ok<AGROW>
end

% 공통 시트 저장
writetable(roiDefinitionTable, exportName, 'Sheet', 'ROI_Definitions');
writetable(roiSummary, exportName, 'Sheet', 'ROI_Summary');

if ~isempty(allBeatMetricsRaw)
    writetable(allBeatMetricsRaw, exportName, 'Sheet', 'All_Beats_RAW');
end
if ~isempty(allBeatMetricsZero)
    writetable(allBeatMetricsZero, exportName, 'Sheet', 'All_Beats_ZERO');
end
if ~isempty(allIntervalMetricsRaw)
    writetable(allIntervalMetricsRaw, exportName, 'Sheet', 'All_Intv_RAW');
end
if ~isempty(allIntervalMetricsZero)
    writetable(allIntervalMetricsZero, exportName, 'Sheet', 'All_Intv_ZERO');
end

save_overlay_dff0_plot(frameTime, all_dFF0_raw,  fullfile(filePath, [folderName '_AllROI_dFF0_Overlay_RAW.png']),  'All ROI dF/F0 Overlay (RAW)');
save_overlay_dff0_plot(frameTime, all_dFF0_zero, fullfile(filePath, [folderName '_AllROI_dFF0_Overlay_ZERO.png']), 'All ROI dF/F0 Overlay (ZERO)');

Summary = table;
Summary.AnalysisStart_s = tStart;
Summary.AnalysisEnd_s   = tEnd;
Summary.FrameRate_FPS   = fps;
Summary.NumFrames       = nFramesSel;
Summary.NumFramesTotal  = obj0.NumFrames;
Summary.NumROIs         = numROIs;
Summary.CircleRadius_px = roiRadius;
Summary.BG_Mode         = string(bgMode);
Summary.BG_Prctile      = bgDarkPrctile;
Summary.Sample_Mode     = string(sampleMode);
Summary.BGROI_x         = x1;
Summary.BGROI_y         = y1;
Summary.BGROI_w         = (x2-x1+1);
Summary.BGROI_h         = (y2-y1+1);

writetable(Summary, exportName, 'Sheet', 'Summary');

disp('Done: ROI별 dF/F0 plot, intensity/F/F0/dF/F0 plot, beat metrics, interval metrics 저장 완료.');

%% ======================================================================
% helper 1) 동일 크기 원형 ROI 6개 지정
%% ======================================================================
function [roiMasks, roiCenters, roiRadius] = draw_same_size_circle_rois(refFrame, numROIs)
[H, W, ~] = size(refFrame);
roiMasks = false(H, W, numROIs);
roiCenters = nan(numROIs, 2);

fig = figure('Color', 'k');
imshow(refFrame); hold on;
title('Draw ROI 1 as a circle (set size and position, then double-click)', 'Color', 'w');
h = drawcircle('Color', 'y', 'LineWidth', 1.2);
wait(h);
roiCenters(1,:) = h.Center;
roiRadius = h.Radius;
roiMasks(:,:,1) = make_circle_mask(roiCenters(1,:), roiRadius, H, W);
plot_circle_outline(roiCenters(1,:), roiRadius, 'y', 1.5);

for r = 2:numROIs
    title(sprintf('Click the CENTER for ROI %d (same radius as ROI 1)', r), 'Color', 'w');
    [x, y] = ginput(1);
    roiCenters(r,:) = [x, y];
    roiMasks(:,:,r) = make_circle_mask(roiCenters(r,:), roiRadius, H, W);
    plot_circle_outline(roiCenters(r,:), roiRadius, 'y', 1.5);
    text(roiCenters(r,1), roiCenters(r,2), sprintf('  %d', r), ...
        'Color', 'y', 'FontSize', 10, 'FontWeight', 'bold');
end

close(fig);
end

%% ======================================================================
% helper 2) 샘플 전체 신호 분석
%% ======================================================================
function [out_raw, out_zero, plots] = analyze_sample_signal_two_outputs(intensityValues, frameTime, saveBasePath, fps, bgOffset, F0_mean, roiLabel)
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
    frameTime, xCorr, FF0_global, dFF0_global, minIdx, pkIdx, saveBasePath, 'RAW', roiLabel);

% =========================
% 4) (B) local minima zero 영점맞춤 버전 생성
% =========================
dFF0_zero = dFF0_global;
FF0_zero  = FF0_global;

for b = 1:numel(minIdx)-1
    st_i = minIdx(b);
    en_i = minIdx(b+1);
    if en_i <= st_i, continue; end

    base = min(dFF0_global(st_i:en_i), [], 'omitnan');
    if ~isfinite(base), base = 0; end

    z = dFF0_global(st_i:en_i) - base;
    z(z < 0) = 0;
    dFF0_zero(st_i:en_i) = z;
end

dFF0_zero(~isfinite(dFF0_zero)) = 0;

[out_zero, plots_zero] = build_metrics_tables( ...
    frameTime, xCorr, FF0_zero, dFF0_zero, minIdx, pkIdx, saveBasePath, 'ZERO', roiLabel);

plots = struct();
plots.raw  = plots_raw;
plots.zero = plots_zero;
end

function [out, plots] = build_metrics_tables(frameTime, xCorr, FF0, dFF0, minIdx, pkIdx, saveBasePath, tag, roiLabel)
% tag: 'RAW' or 'ZERO'

% =========================
% Beat metrics (+decay + cycle duration + BPM)
% =========================
beatMetrics = table();

for b = 1:max(0, numel(minIdx)-1)
    st_i = minIdx(b);
    en_i = minIdx(b+1);

    st = frameTime(st_i);
    en = frameTime(en_i);

    cycleDur = en - st;
    bpm = 60 ./ cycleDur;

    segPk = pkIdx(pkIdx > st_i & pkIdx < en_i);

    if isempty(segPk)
        pk = NaN; Fmax = NaN; dFmax = NaN;
        t10 = NaN; t50 = NaN; t90 = NaN;
    else
        peakI = segPk(1);
        pk = frameTime(peakI);

        Fmax  = max(FF0(st_i:en_i),  [], 'omitnan');
        dFmax = max(dFF0(st_i:en_i), [], 'omitnan');

        peakVal = dFF0(peakI);
        if ~isfinite(peakVal) || peakVal <= 0
            t10 = NaN; t50 = NaN; t90 = NaN;
        else
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
% Plot 저장
% =========================
% (1) dF/F0 단독 그래프
f1 = figure('Visible','off');
plot(frameTime, dFF0, 'b-', 'LineWidth', 1.2); hold on;
if ~isempty(pkIdx)
    plot(frameTime(pkIdx), dFF0(pkIdx), 'ko', 'MarkerSize', 4, 'LineWidth', 1);
end
title(sprintf('%s dF/F0 (%s; peaks marked)', roiLabel, tag));
xlabel('Time (s)'); ylabel('dF/F0'); grid on;
saveas(f1, sprintf('%s_%s_dFF0_%s.png', saveBasePath, roiLabel, tag));
close(f1);

% (2) Intensity / F/F0 / dF/F0 묶음 그래프
f2 = figure('Visible','off', 'Position', [100 100 1000 750]);
subplot(3,1,1);
plot(frameTime, xCorr, 'k-', 'LineWidth', 1.1);
title(sprintf('%s Intensity (%s)', roiLabel, tag));
xlabel('Time (s)'); ylabel('Intensity'); grid on;

subplot(3,1,2);
plot(frameTime, FF0, 'm-', 'LineWidth', 1.1);
title(sprintf('%s F/F0 (%s)', roiLabel, tag));
xlabel('Time (s)'); ylabel('F/F0'); grid on;

subplot(3,1,3);
plot(frameTime, dFF0, 'b-', 'LineWidth', 1.1); hold on;
if ~isempty(pkIdx)
    plot(frameTime(pkIdx), dFF0(pkIdx), 'ko', 'MarkerSize', 4, 'LineWidth', 1);
end
title(sprintf('%s dF/F0 (%s)', roiLabel, tag));
xlabel('Time (s)'); ylabel('dF/F0'); grid on;
saveas(f2, sprintf('%s_%s_Traces_%s.png', saveBasePath, roiLabel, tag));
close(f2);

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
% helper 3) ROI별 dF/F0 겹침 플롯 저장
%% ======================================================================
function save_overlay_dff0_plot(frameTime, dffMat, saveName, plotTitle)
if isempty(dffMat) || all(all(~isfinite(dffMat)))
    return;
end

f = figure('Visible','off', 'Position', [100 100 1100 500]);
plot(frameTime, dffMat, 'LineWidth', 1.1);
xlabel('Time (s)');
ylabel('dF/F0');
title(plotTitle);
grid on;

legendLabels = arrayfun(@(x) sprintf('ROI %d', x), 1:size(dffMat,2), 'UniformOutput', false);
legend(legendLabels, 'Location', 'eastoutside');

saveas(f, saveName);
close(f);
end

%% ======================================================================
% helper 4) 원형 mask 생성
%% ======================================================================
function mask = make_circle_mask(center, radius, H, W)
[xx, yy] = meshgrid(1:W, 1:H);
mask = (xx - center(1)).^2 + (yy - center(2)).^2 <= radius.^2;
end

%% ======================================================================
% helper 5) 원 그리기
%% ======================================================================
function plot_circle_outline(center, radius, colorStr, lineWidth)
theta = linspace(0, 2*pi, 300);
x = center(1) + radius * cos(theta);
y = center(2) + radius * sin(theta);
plot(x, y, 'Color', colorStr, 'LineWidth', lineWidth);
end


%% ======================================================================
% helper 6) mask boundary 그리기
%% ======================================================================
function plot_mask_boundary(mask, colorStr, lineWidth)
B = bwboundaries(mask);
for k = 1:numel(B)
    bd = B{k};
    plot(bd(:,2), bd(:,1), 'Color', colorStr, 'LineWidth', lineWidth);
end
end
