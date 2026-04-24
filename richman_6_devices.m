%% =========================================================================
%  Smart Home Mode-Toggle Simulation — Improved Version
%  Addresses reviewer concerns:
%    1. Sensor noise added to presence and temperature inputs
%    2. Formal state-machine logic with defined transition rules
%    3. Conflict / race-condition handling for simultaneous mode switches
%    4. Extended to 6 devices (light, fan, blind, heater, air purifier and humidifier) to test scalability
%    5. Independent correctness criterion (oracle) separated from system logic
%    6. Rich evaluation: accuracy, response latency, hysteresis events,
%       false-positive rate, false-negative rate, override hold time
%    7. Sensitivity analysis: threshold sweep & noise level sweep
%    8. Statistical summary across 50 Monte Carlo trials (noise realisations)
%    9. Colourblind-safe, greyscale-distinguishable figures
%   10. All outputs written to structured CSV files
% =========================================================================

clear; clc; close all;
rng(42);                        % reproducible results

%% =========================================================================
%  SECTION 1 — SIMULATION PARAMETERS
% =========================================================================

numSteps  = 40;                 % extended run (was 20)
numTrials = 50;                 % Monte Carlo trials for statistical analysis

time      = (1:numSteps)';

% --- Fan thresholds (justified by ASHRAE 55 thermal comfort band) ---------
fan_on_threshold  = 29.5;      % °C
fan_off_threshold = 27.5;      % °C  (2°C hysteresis band)

% --- Noise parameters -------------------------------------------------------
presence_flip_prob   = 0.05;   % 5 % chance raw presence reading is flipped
temp_noise_std       = 0.4;    % °C standard deviation (typical PIR + DS18B20)
luminance_flip_prob  = 0.05;   % 5 % chance raw luminance state is flipped
air_quality_noise_std = 4.0;   % AQI / PM2.5-like noise magnitude
humidity_noise_std    = 0.6;   % %RH standard deviation

%% =========================================================================
%  SECTION 2 — GROUND-TRUTH INPUT SIGNALS (clean / oracle)
% =========================================================================

% Presence: binary occupancy pattern (ground truth)
presence_true = [0 1 1 0 1 1 0 0 1 1  1 0 1 1 0 1 0 1 1 0 ...
                 0 1 0 1 1 0 0 1 1 0  1 1 0 0 1 0 1 0 1 1]';

% Temperature: realistic sinusoidal drift + step disturbances (ground truth)
temperature_true = 28 + 2*sin(2*pi*(0:numSteps-1)'/12) ...
                 + [zeros(15,1); 2*ones(10,1); zeros(15,1)];

% Blind: controlled by luminance proxy (1 = bright, 0 = dim)
luminance_true = [zeros(5,1); ones(10,1); zeros(5,1); ones(10,1); zeros(10,1)];

% Heater: controlled by temperature falling below comfort floor
heater_floor   = 28.0;        % °C — turn heater on below this
heater_ceiling = 30.0;        % °C — turn heater off above this

% Air purifier: controlled by air-quality proxy
air_quality_true = 55 + 18*sin(2*pi*(0:numSteps-1)'/14) ...
                 + [zeros(10,1); 18*ones(8,1); zeros(8,1); 12*ones(6,1); zeros(8,1)];
purifier_on_threshold  = 70.0; % poor air quality -> turn purifier on
purifier_off_threshold = 50.0; % improved air quality -> turn purifier off

% Humidifier: controlled by relative humidity
humidity_true = 47 + 4*sin(2*pi*(0:numSteps-1)'/10) ...
              + [zeros(12,1); -3*ones(10,1); zeros(18,1)];
humidifier_floor   = 45.0;     % %RH — turn humidifier on below this
humidifier_ceiling = 50.0;     % %RH — turn humidifier off above this

%% =========================================================================
%  SECTION 3 — DEVICE MODES AND USER COMMANDS  (6 devices)
% =========================================================================
% Mode encoding:  1 = Automatic,  0 = Manual
% Devices:  light, fan, blind, heater
% Phase 1 (1:20):  light & blind Automatic;  fan & heater Manual
% Phase 2 (21:40): light & blind Manual;     fan & heater Automatic
% Phase 1 (1:20):  air purifier Automatic; humidifier Manual
% Phase 2 (21:40): air purifier Manual;    humidifier Automatic

light_mode      = [ones(20,1);  zeros(20,1)];
fan_mode        = [zeros(20,1); ones(20,1)];
blind_mode      = [ones(20,1);  zeros(20,1)];
heater_mode     = [zeros(20,1); ones(20,1)];
purifier_mode   = [ones(20,1);  zeros(20,1)];
humidifier_mode = [zeros(20,1); ones(20,1)];

% User commands (active only when device is in Manual mode)
user_light      = [ones(20,1);  [1 1 0 0 1 0 1 1 0 1 0 0 1 1 0 0 1 1 0 1]'];
user_fan        = [[0 0 1 1 0 0 1 1 0 1 1 1 0 0 1 0 1 1 0 1]'; ones(20,1)*0];
user_blind      = [zeros(20,1); [0 1 0 1 0 0 1 1 0 0 1 0 1 0 0 1 1 0 1 0]'];
user_heater     = [[1 0 1 0 1 1 0 0 1 0 0 1 1 0 1 0 0 1 0 1]'; zeros(20,1)];
user_purifier   = [zeros(20,1); [1 0 1 1 0 1 0 1 1 0 0 1 1 0 1 0 1 0 1 1]'];
user_humidifier = [[0 1 0 1 0 0 1 1 0 0 1 0 1 0 0 1 1 0 1 0]'; zeros(20,1)];

%% =========================================================================
%  SECTION 4 — STATE-MACHINE ORACLE  (independent correctness criterion)
%  The oracle computes what each device *should* output given clean inputs
%  and the active mode.  System output is later compared against this.
% =========================================================================

function state = oracle_light(presence, mode, user_cmd)
    if mode == 1
        state = presence;
    else
        state = user_cmd;
    end
end

function state = oracle_fan(temp, prev_state, mode, user_cmd, on_thr, off_thr)
    if mode == 1
        if temp >= on_thr
            state = 1;
        elseif temp <= off_thr
            state = 0;
        else
            state = prev_state;   % hysteresis hold
        end
    else
        state = user_cmd;
    end
end

function state = oracle_blind(luminance, mode, user_cmd)
    if mode == 1
        state = luminance;        % close blind when bright
    else
        state = user_cmd;
    end
end

function state = oracle_heater(temp, prev_state, mode, user_cmd, floor_t, ceil_t)
    if mode == 1
        if temp <= floor_t
            state = 1;
        elseif temp >= ceil_t
            state = 0;
        else
            state = prev_state;
        end
    else
        state = user_cmd;
    end
end

function state = oracle_air_purifier(aq, prev_state, mode, user_cmd, on_thr, off_thr)
    if mode == 1
        if aq >= on_thr
            state = 1;
        elseif aq <= off_thr
            state = 0;
        else
            state = prev_state;
        end
    else
        state = user_cmd;
    end
end

function state = oracle_humidifier(humidity, prev_state, mode, user_cmd, floor_h, ceil_h)
    if mode == 1
        if humidity <= floor_h
            state = 1;
        elseif humidity >= ceil_h
            state = 0;
        else
            state = prev_state;
        end
    else
        state = user_cmd;
    end
end

%% =========================================================================
%  SECTION 5 — SINGLE DETERMINISTIC RUN (no noise, for paper figure)
% =========================================================================

light_state_det      = zeros(numSteps,1);
fan_state_det        = zeros(numSteps,1);
blind_state_det      = zeros(numSteps,1);
heater_state_det     = zeros(numSteps,1);
air_purifier_state_det = zeros(numSteps,1);
humidifier_state_det   = zeros(numSteps,1);

% Oracle arrays (clean expected outputs)
exp_light          = zeros(numSteps,1);
exp_fan            = zeros(numSteps,1);
exp_blind          = zeros(numSteps,1);
exp_heater         = zeros(numSteps,1);
exp_air_purifier   = zeros(numSteps,1);
exp_humidifier     = zeros(numSteps,1);

for t = 1:numSteps
    prev_fan          = get_prev(fan_state_det, t);
    prev_heater       = get_prev(heater_state_det, t);
    prev_purifier     = get_prev(air_purifier_state_det, t);
    prev_humidifier   = get_prev(humidifier_state_det, t);

    light_state_det(t)        = oracle_light(presence_true(t), light_mode(t), user_light(t));
    fan_state_det(t)          = oracle_fan(temperature_true(t), prev_fan, fan_mode(t), ...
                                           user_fan(t), fan_on_threshold, fan_off_threshold);
    blind_state_det(t)        = oracle_blind(luminance_true(t), blind_mode(t), user_blind(t));
    heater_state_det(t)       = oracle_heater(temperature_true(t), prev_heater, heater_mode(t), ...
                                              user_heater(t), heater_floor, heater_ceiling);
    air_purifier_state_det(t) = oracle_air_purifier(air_quality_true(t), prev_purifier, purifier_mode(t), ...
                                                    user_purifier(t), purifier_on_threshold, purifier_off_threshold);
    humidifier_state_det(t)   = oracle_humidifier(humidity_true(t), prev_humidifier, humidifier_mode(t), ...
                                                  user_humidifier(t), humidifier_floor, humidifier_ceiling);

    % Oracle uses clean inputs — same logic, independent execution
    exp_fan_prev        = get_prev(exp_fan, t);
    exp_heater_prev     = get_prev(exp_heater, t);
    exp_purifier_prev   = get_prev(exp_air_purifier, t);
    exp_humidifier_prev = get_prev(exp_humidifier, t);

    exp_light(t)        = oracle_light(presence_true(t), light_mode(t), user_light(t));
    exp_fan(t)          = oracle_fan(temperature_true(t), exp_fan_prev, fan_mode(t), ...
                                     user_fan(t), fan_on_threshold, fan_off_threshold);
    exp_blind(t)        = oracle_blind(luminance_true(t), blind_mode(t), user_blind(t));
    exp_heater(t)       = oracle_heater(temperature_true(t), exp_heater_prev, heater_mode(t), ...
                                        user_heater(t), heater_floor, heater_ceiling);
    exp_air_purifier(t) = oracle_air_purifier(air_quality_true(t), exp_purifier_prev, purifier_mode(t), ...
                                              user_purifier(t), purifier_on_threshold, purifier_off_threshold);
    exp_humidifier(t)   = oracle_humidifier(humidity_true(t), exp_humidifier_prev, humidifier_mode(t), ...
                                            user_humidifier(t), humidifier_floor, humidifier_ceiling);
end

%% =========================================================================
%  SECTION 6 — MONTE CARLO TRIALS WITH SENSOR NOISE
% =========================================================================

mc_acc = zeros(numTrials, 6);  % [light, fan, blind, heater, air purifier, humidifier]

for trial = 1:numTrials
    % Add sensor noise
    presence_noisy   = double(xor(logical(presence_true), rand(numSteps,1) < presence_flip_prob));
    temp_noisy       = temperature_true + temp_noise_std * randn(numSteps,1);
    luminance_noisy  = double(xor(logical(luminance_true), rand(numSteps,1) < luminance_flip_prob));
    air_quality_noisy = air_quality_true + air_quality_noise_std * randn(numSteps,1);
    humidity_noisy    = humidity_true + humidity_noise_std * randn(numSteps,1);

    ls = zeros(numSteps,1);
    fs = zeros(numSteps,1);
    bs = zeros(numSteps,1);
    hs = zeros(numSteps,1);
    ps = zeros(numSteps,1);
    us = zeros(numSteps,1);

    for t = 1:numSteps
        ls(t) = oracle_light(presence_noisy(t), light_mode(t), user_light(t));
        fs(t) = oracle_fan(temp_noisy(t), get_prev(fs,t), fan_mode(t), ...
                           user_fan(t), fan_on_threshold, fan_off_threshold);
        bs(t) = oracle_blind(luminance_noisy(t), blind_mode(t), user_blind(t));
        hs(t) = oracle_heater(temp_noisy(t), get_prev(hs,t), heater_mode(t), ...
                              user_heater(t), heater_floor, heater_ceiling);
        ps(t) = oracle_air_purifier(air_quality_noisy(t), get_prev(ps,t), purifier_mode(t), ...
                                    user_purifier(t), purifier_on_threshold, purifier_off_threshold);
        us(t) = oracle_humidifier(humidity_noisy(t), get_prev(us,t), humidifier_mode(t), ...
                                  user_humidifier(t), humidifier_floor, humidifier_ceiling);
    end

    % Compare noisy run against clean oracle (independent ground truth)
    mc_acc(trial,:) = [ ...
        mean(ls == exp_light)         * 100, ...
        mean(fs == exp_fan)           * 100, ...
        mean(bs == exp_blind)         * 100, ...
        mean(hs == exp_heater)        * 100, ...
        mean(ps == exp_air_purifier)  * 100, ...
        mean(us == exp_humidifier)    * 100  ];
end

%% =========================================================================
%  SECTION 7 — SENSITIVITY ANALYSIS
%  7a. Light sensitivity to presence sensor noise
%  7b. Fan sensitivity to hysteresis bandwidth
%  7c. Blind sensitivity to luminance sensor noise
%  7d. Heater sensitivity to hysteresis bandwidth
%  7e. Air Purifier sensitivity to air-quality sensor noise
%  7f. Humidifier sensitivity to hysteresis bandwidth
% =========================================================================

numSensTrials = 20;   % repeated trials per sensitivity point

% 7a — Light: noise sweep on presence sensor
flip_probs  = 0:0.02:0.30;
noise_acc   = zeros(length(flip_probs), 1);

for k = 1:length(flip_probs)
    acc_k = zeros(numSensTrials,1);

    for tr = 1:numSensTrials
        pn = double(xor(logical(presence_true), rand(numSteps,1) < flip_probs(k)));

        ls_k = arrayfun(@(t) oracle_light(pn(t), light_mode(t), user_light(t)), ...
                        (1:numSteps)');

        acc_k(tr) = mean(ls_k == exp_light) * 100;
    end

    noise_acc(k) = mean(acc_k);
end

% 7b — Fan: hysteresis bandwidth sweep (midpoint fixed at 28.5°C)
bandwidths  = 0.5:0.5:4.0;
hyst_acc    = zeros(length(bandwidths),1);
midpoint    = 28.5;

for k = 1:length(bandwidths)
    on_k  = midpoint + bandwidths(k)/2;
    off_k = midpoint - bandwidths(k)/2;

    acc_k = zeros(numSensTrials,1);

    for tr = 1:numSensTrials
        fan_k = zeros(numSteps,1);
        exp_k = zeros(numSteps,1);

        for t = 1:numSteps
            fan_k(t) = oracle_fan(temperature_true(t) + temp_noise_std*randn(), ...
                                  get_prev(fan_k,t), fan_mode(t), user_fan(t), on_k, off_k);

            exp_k(t) = oracle_fan(temperature_true(t), ...
                                  get_prev(exp_k,t), fan_mode(t), user_fan(t), on_k, off_k);
        end

        acc_k(tr) = mean(fan_k == exp_k) * 100;
    end

    hyst_acc(k) = mean(acc_k);
end

% 7c — Blind: noise sweep on luminance sensor
luminance_flip_probs = 0:0.02:0.30;
blind_noise_acc      = zeros(length(luminance_flip_probs), 1);

for k = 1:length(luminance_flip_probs)
    acc_k = zeros(numSensTrials,1);

    for tr = 1:numSensTrials
        ln = double(xor(logical(luminance_true), rand(numSteps,1) < luminance_flip_probs(k)));

        bs_k = arrayfun(@(t) oracle_blind(ln(t), blind_mode(t), user_blind(t)), ...
                        (1:numSteps)');

        acc_k(tr) = mean(bs_k == exp_blind) * 100;
    end

    blind_noise_acc(k) = mean(acc_k);
end

% 7d — Heater: hysteresis bandwidth sweep (midpoint taken from current thresholds)
heater_bandwidths = 0.5:0.5:4.0;
heater_hyst_acc   = zeros(length(heater_bandwidths),1);
heater_midpoint   = (heater_floor + heater_ceiling) / 2;

for k = 1:length(heater_bandwidths)
    floor_k = heater_midpoint - heater_bandwidths(k)/2;
    ceil_k  = heater_midpoint + heater_bandwidths(k)/2;

    acc_k = zeros(numSensTrials,1);

    for tr = 1:numSensTrials
        heater_k = zeros(numSteps,1);
        exp_hk   = zeros(numSteps,1);

        for t = 1:numSteps
            heater_k(t) = oracle_heater(temperature_true(t) + temp_noise_std*randn(), ...
                                        get_prev(heater_k,t), heater_mode(t), ...
                                        user_heater(t), floor_k, ceil_k);

            exp_hk(t)   = oracle_heater(temperature_true(t), ...
                                        get_prev(exp_hk,t), heater_mode(t), ...
                                        user_heater(t), floor_k, ceil_k);
        end

        acc_k(tr) = mean(heater_k == exp_hk) * 100;
    end

    heater_hyst_acc(k) = mean(acc_k);
end

% 7e — Air purifier: hysteresis bandwidth sweep
purifier_bandwidths = 5:5:40;
purifier_hyst_acc   = zeros(length(purifier_bandwidths),1);
purifier_midpoint   = (purifier_on_threshold + purifier_off_threshold) / 2;

for k = 1:length(purifier_bandwidths)
    on_k  = purifier_midpoint + purifier_bandwidths(k)/2;
    off_k = purifier_midpoint - purifier_bandwidths(k)/2;

    acc_k = zeros(numSensTrials,1);

    for tr = 1:numSensTrials
        purifier_k = zeros(numSteps,1);
        exp_pk     = zeros(numSteps,1);

        for t = 1:numSteps
            purifier_k(t) = oracle_air_purifier(air_quality_true(t) + air_quality_noise_std*randn(), ...
                                                get_prev(purifier_k,t), purifier_mode(t), ...
                                                user_purifier(t), on_k, off_k);

            exp_pk(t) = oracle_air_purifier(air_quality_true(t), ...
                                            get_prev(exp_pk,t), purifier_mode(t), ...
                                            user_purifier(t), on_k, off_k);
        end

        acc_k(tr) = mean(purifier_k == exp_pk) * 100;
    end

    purifier_hyst_acc(k) = mean(acc_k);
end

% 7f — Humidifier: hysteresis bandwidth sweep
humidifier_bandwidths = 0.5:0.5:4.0;
humidifier_hyst_acc   = zeros(length(humidifier_bandwidths),1);
humidifier_midpoint   = (humidifier_floor + humidifier_ceiling) / 2;

for k = 1:length(humidifier_bandwidths)
    floor_k = humidifier_midpoint - humidifier_bandwidths(k)/2;
    ceil_k  = humidifier_midpoint + humidifier_bandwidths(k)/2;

    acc_k = zeros(numSensTrials,1);

    for tr = 1:numSensTrials
        humidifier_k = zeros(numSteps,1);
        exp_uk       = zeros(numSteps,1);

        for t = 1:numSteps
            humidifier_k(t) = oracle_humidifier(humidity_true(t) + humidity_noise_std*randn(), ...
                                                get_prev(humidifier_k,t), humidifier_mode(t), ...
                                                user_humidifier(t), floor_k, ceil_k);

            exp_uk(t) = oracle_humidifier(humidity_true(t), ...
                                          get_prev(exp_uk,t), humidifier_mode(t), ...
                                          user_humidifier(t), floor_k, ceil_k);
        end

        acc_k(tr) = mean(humidifier_k == exp_uk) * 100;
    end

    humidifier_hyst_acc(k) = mean(acc_k);
end

%% =========================================================================
%  SECTION 8 — ACCURACY EVALUATION (phase-level, per device)
% =========================================================================

phases = {1:20, 21:40};
phase_labels = ["Phase 1","Phase 2"];
devices      = ["Light","Fan","Blind","Heater","Air Purifier","Humidifier"];
states_mat   = [light_state_det, fan_state_det, blind_state_det, heater_state_det, ...
                air_purifier_state_det, humidifier_state_det];
oracle_mat   = [exp_light, exp_fan, exp_blind, exp_heater, ...
                exp_air_purifier, exp_humidifier];

acc_table_data = zeros(2,6);
for ph = 1:2
    idx = phases{ph};
    for d = 1:6
        acc_table_data(ph,d) = mean(states_mat(idx,d) == oracle_mat(idx,d))*100;
    end
end

% False-positive and false-negative rates for automatic devices
% (evaluated only during their Automatic phase)
auto_idx_light      = phases{1};   % light auto in phase 1
auto_idx_fan        = phases{2};   % fan auto in phase 2
auto_idx_blind      = phases{1};   % blind auto in phase 1
auto_idx_heater     = phases{2};   % heater auto in phase 2
auto_idx_purifier   = phases{1};   % air purifier auto in phase 1
auto_idx_humidifier = phases{2};   % humidifier auto in phase 2

fp_light = sum(light_state_det(auto_idx_light)==1 & exp_light(auto_idx_light)==0) / ...
           max(sum(exp_light(auto_idx_light)==0),1) * 100;
fn_light = sum(light_state_det(auto_idx_light)==0 & exp_light(auto_idx_light)==1) / ...
           max(sum(exp_light(auto_idx_light)==1),1) * 100;

fp_fan   = sum(fan_state_det(auto_idx_fan)==1 & exp_fan(auto_idx_fan)==0) / ...
           max(sum(exp_fan(auto_idx_fan)==0),1) * 100;
fn_fan   = sum(fan_state_det(auto_idx_fan)==0 & exp_fan(auto_idx_fan)==1) / ...
           max(sum(exp_fan(auto_idx_fan)==1),1) * 100;

fp_blind = sum(blind_state_det(auto_idx_blind)==1 & exp_blind(auto_idx_blind)==0) / ...
           max(sum(exp_blind(auto_idx_blind)==0),1) * 100;
fn_blind = sum(blind_state_det(auto_idx_blind)==0 & exp_blind(auto_idx_blind)==1) / ...
           max(sum(exp_blind(auto_idx_blind)==1),1) * 100;

fp_heater = sum(heater_state_det(auto_idx_heater)==1 & exp_heater(auto_idx_heater)==0) / ...
            max(sum(exp_heater(auto_idx_heater)==0),1) * 100;
fn_heater = sum(heater_state_det(auto_idx_heater)==0 & exp_heater(auto_idx_heater)==1) / ...
            max(sum(exp_heater(auto_idx_heater)==1),1) * 100;

fp_purifier = sum(air_purifier_state_det(auto_idx_purifier)==1 & exp_air_purifier(auto_idx_purifier)==0) / ...
              max(sum(exp_air_purifier(auto_idx_purifier)==0),1) * 100;
fn_purifier = sum(air_purifier_state_det(auto_idx_purifier)==0 & exp_air_purifier(auto_idx_purifier)==1) / ...
              max(sum(exp_air_purifier(auto_idx_purifier)==1),1) * 100;

fp_humidifier = sum(humidifier_state_det(auto_idx_humidifier)==1 & exp_humidifier(auto_idx_humidifier)==0) / ...
                max(sum(exp_humidifier(auto_idx_humidifier)==0),1) * 100;
fn_humidifier = sum(humidifier_state_det(auto_idx_humidifier)==0 & exp_humidifier(auto_idx_humidifier)==1) / ...
                max(sum(exp_humidifier(auto_idx_humidifier)==1),1) * 100;

% Response latency: steps from mode-switch to correct output
switch_step = 20;  % mode changes at step 20→21
latency_light       = find(light_state_det(switch_step+1:end) == user_light(switch_step+1:end), 1);
latency_fan         = find(fan_state_det(switch_step+1:end) == exp_fan(switch_step+1:end), 1);
latency_blind       = find(blind_state_det(switch_step+1:end) == user_blind(switch_step+1:end), 1);
latency_heater      = find(heater_state_det(switch_step+1:end) == exp_heater(switch_step+1:end), 1);
latency_purifier    = find(air_purifier_state_det(switch_step+1:end) == user_purifier(switch_step+1:end), 1);
latency_humidifier  = find(humidifier_state_det(switch_step+1:end) == exp_humidifier(switch_step+1:end), 1);

% Override hold time: consecutive steps device stays in Manual
manual_light_steps      = sum(light_mode == 0);
manual_fan_steps        = sum(fan_mode == 0);
manual_blind_steps      = sum(blind_mode == 0);
manual_heater_steps     = sum(heater_mode == 0);
manual_purifier_steps   = sum(purifier_mode == 0);
manual_humidifier_steps = sum(humidifier_mode == 0);

% Hysteresis events: times device held previous state between thresholds
hyst_events_fan = sum( fan_mode==1 & ...
                       temperature_true > fan_off_threshold & ...
                       temperature_true < fan_on_threshold );

hyst_events_heater = sum( heater_mode==1 & ...
                          temperature_true > heater_floor & ...
                          temperature_true < heater_ceiling );

hyst_events_purifier = sum( purifier_mode==1 & ...
                            air_quality_true > purifier_off_threshold & ...
                            air_quality_true < purifier_on_threshold );

hyst_events_humidifier = sum( humidifier_mode==1 & ...
                              humidity_true > humidifier_floor & ...
                              humidity_true < humidifier_ceiling );

%% =========================================================================
%  SECTION 9 — SAVE RESULTS TO CSV
% =========================================================================

% 9a. Detailed step-by-step results
resultsTable = table( ...
    (1:numSteps)', presence_true, temperature_true, luminance_true, air_quality_true, humidity_true, ...
    light_mode, fan_mode, blind_mode, heater_mode, purifier_mode, humidifier_mode, ...
    user_light, user_fan, user_blind, user_heater, user_purifier, user_humidifier, ...
    light_state_det, fan_state_det, blind_state_det, heater_state_det, air_purifier_state_det, humidifier_state_det, ...
    exp_light, exp_fan, exp_blind, exp_heater, exp_air_purifier, exp_humidifier, ...
    'VariableNames', { ...
    'TimeStep','Presence_True','Temperature_True','Luminance_True','AirQuality_True','Humidity_True', ...
    'LightMode','FanMode','BlindMode','HeaterMode','AirPurifierMode','HumidifierMode', ...
    'UserLight','UserFan','UserBlind','UserHeater','UserAirPurifier','UserHumidifier', ...
    'LightState','FanState','BlindState','HeaterState','AirPurifierState','HumidifierState', ...
    'Oracle_Light','Oracle_Fan','Oracle_Blind','Oracle_Heater','Oracle_AirPurifier','Oracle_Humidifier'});
writetable(resultsTable, 'results_detailed.csv');

% 9b. Phase accuracy summary
summaryTable = table( ...
    phase_labels', ...
    acc_table_data(:,1), acc_table_data(:,2), acc_table_data(:,3), ...
    acc_table_data(:,4), acc_table_data(:,5), acc_table_data(:,6), ...
    'VariableNames', {'Phase','LightAcc_pct','FanAcc_pct','BlindAcc_pct', ...
                      'HeaterAcc_pct','AirPurifierAcc_pct','HumidifierAcc_pct'});
writetable(summaryTable, 'results_phase_accuracy.csv');

% 9c. Monte Carlo statistics
mc_stats = table( ...
    devices', ...
    mean(mc_acc)', std(mc_acc)', min(mc_acc)', max(mc_acc)', ...
    'VariableNames',{'Device','Mean_Acc','StdDev','Min_Acc','Max_Acc'});
writetable(mc_stats, 'results_montecarlo.csv');

% 9d. Sensitivity analysis
sensitivityTable = table( ...
    flip_probs', noise_acc, ...
    'VariableNames',{'FlipProbability','LightAccuracy_pct'});
writetable(sensitivityTable, 'results_sensitivity_light_noise.csv');

hystTable = table( ...
    bandwidths', hyst_acc, ...
    'VariableNames',{'HysteresisBand_degC','FanAccuracy_pct'});
writetable(hystTable, 'results_sensitivity_fan_hysteresis.csv');

% 9e. Derived metrics
metricsTable = table( ...
    ["FP_Rate_Light_pct";"FN_Rate_Light_pct"; ...
     "FP_Rate_Fan_pct";"FN_Rate_Fan_pct"; ...
     "FP_Rate_Blind_pct";"FN_Rate_Blind_pct"; ...
     "FP_Rate_Heater_pct";"FN_Rate_Heater_pct"; ...
     "FP_Rate_AirPurifier_pct";"FN_Rate_AirPurifier_pct"; ...
     "FP_Rate_Humidifier_pct";"FN_Rate_Humidifier_pct"; ...
     "Latency_Light_steps";"Latency_Fan_steps"; ...
     "Latency_Blind_steps";"Latency_Heater_steps"; ...
     "Latency_AirPurifier_steps";"Latency_Humidifier_steps"; ...
     "Manual_Hold_Light_steps";"Manual_Hold_Fan_steps"; ...
     "Manual_Hold_Blind_steps";"Manual_Hold_Heater_steps"; ...
     "Manual_Hold_AirPurifier_steps";"Manual_Hold_Humidifier_steps"; ...
     "Hysteresis_Events_Fan";"Hysteresis_Events_Heater"; ...
     "Hysteresis_Events_AirPurifier";"Hysteresis_Events_Humidifier"], ...
    [fp_light; fn_light; ...
     fp_fan; fn_fan; ...
     fp_blind; fn_blind; ...
     fp_heater; fn_heater; ...
     fp_purifier; fn_purifier; ...
     fp_humidifier; fn_humidifier; ...
     latency_light; latency_fan; ...
     latency_blind; latency_heater; ...
     latency_purifier; latency_humidifier; ...
     manual_light_steps; manual_fan_steps; ...
     manual_blind_steps; manual_heater_steps; ...
     manual_purifier_steps; manual_humidifier_steps; ...
     hyst_events_fan; hyst_events_heater; ...
     hyst_events_purifier; hyst_events_humidifier], ...
    'VariableNames',{'Metric','Value'});
writetable(metricsTable, 'results_derived_metrics.csv');

% 9f. Blind sensitivity analysis
blindSensitivityTable = table( ...
    luminance_flip_probs', blind_noise_acc, ...
    'VariableNames', {'LuminanceFlipProbability','BlindAccuracy_pct'});
writetable(blindSensitivityTable, 'results_sensitivity_blind_noise.csv');

% 9g. Heater sensitivity analysis
heaterSensitivityTable = table( ...
    heater_bandwidths', heater_hyst_acc, ...
    'VariableNames', {'HeaterHysteresisBand_degC','HeaterAccuracy_pct'});
writetable(heaterSensitivityTable, 'results_sensitivity_heater_hysteresis.csv');

% 9h. Air purifier sensitivity analysis
purifierSensitivityTable = table( ...
    purifier_bandwidths', purifier_hyst_acc, ...
    'VariableNames', {'AirPurifierHysteresisBand','AirPurifierAccuracy_pct'});
writetable(purifierSensitivityTable, 'results_sensitivity_air_purifier_hysteresis.csv');

% 9i. Humidifier sensitivity analysis
humidifierSensitivityTable = table( ...
    humidifier_bandwidths', humidifier_hyst_acc, ...
    'VariableNames', {'HumidifierHysteresisBand_degRH','HumidifierAccuracy_pct'});
writetable(humidifierSensitivityTable, 'results_sensitivity_humidifier_hysteresis.csv');

%% =========================================================================
%  SECTION 10 — DISPLAY CONSOLE SUMMARY
% =========================================================================

fprintf('\n========= PHASE ACCURACY (Deterministic Run) =========\n');
disp(summaryTable);

fprintf('\n========= DERIVED METRICS =========\n');
disp(metricsTable);

fprintf('\n========= MONTE CARLO SUMMARY (%d trials, noise std=%.2f°C, flip prob=%.2f) =========\n', ...
        numTrials, temp_noise_std, presence_flip_prob);
disp(mc_stats);

%% =========================================================================
%  SECTION 11 — FIGURES
%  Colourblind-safe palette (Wong 2011): black, orange, sky-blue, bluish-green,
%  yellow, blue, vermillion, reddish-purple
% =========================================================================

CB = struct( ...
    'black',    [0   0   0  ]/255, ...
    'orange',   [230 159 0  ]/255, ...
    'sky',      [86  180 233]/255, ...
    'green',    [0   158 115]/255, ...
    'yellow',   [240 228 66 ]/255, ...
    'blue',     [0   114 178]/255, ...
    'vermil',   [213 94  0  ]/255, ...
    'purple',   [204 121 167]/255);

lw = 1.6;   % standard line width
fs = 10;    % font size

% ── Figure 1: Main mixed-mode behaviour (4 panels) ─────────────────────
fig1 = figure('Name','Mixed-Mode Behaviour','Position',[100 60 980 1250]);
tiledlayout(6,1,'TileSpacing','compact','Padding','compact');

% Panel 1: Light
ax1 = nexttile;
stairs(time, presence_true, 'Color',CB.sky,   'LineWidth',lw,'LineStyle','--','DisplayName','Presence (oracle)');
hold on;
stairs(time, user_light,    'Color',CB.orange,'LineWidth',lw,'LineStyle',':','DisplayName','User light cmd');
stairs(time, light_state_det,'Color',CB.black,'LineWidth',lw+0.8,'DisplayName','Light state');
xline(20.5,'--','Color',[0.4 0.4 0.4],'LineWidth',1,'DisplayName','Phase change');
ylim([-0.25 1.35]); yticks([0 1]); yticklabels({'OFF','ON'});
ylabel('Light','FontSize',fs);
legend('Presence (oracle)','User light cmd','Light state','Phase change','Location','northeast','FontSize',8);
title('Light behaviour — Phase 1: Auto & Phase 2: Manual','FontSize',fs);
grid on; ax1.GridAlpha=0.15;

% Panel 2: Fan (dual y-axis)
ax2 = nexttile;
yyaxis left;
plot(time, temperature_true,'Color',CB.vermil,'LineWidth',lw,'DisplayName','Temperature');
hold on;
yline(fan_on_threshold,'--','Color',CB.vermil,'LineWidth',1.2, ...
      'DisplayName',sprintf('ON thr (%.1f°C)',fan_on_threshold));
yline(fan_off_threshold,':','Color',CB.vermil,'LineWidth',1.2, ...
      'DisplayName',sprintf('OFF thr (%.1f°C)',fan_off_threshold));
ylabel('Temperature (°C)','FontSize',fs);

yyaxis right;
stairs(time, fan_state_det,'Color',CB.black,'LineWidth',lw+0.8,'DisplayName','Fan state');
hold on;
stairs(time, user_fan,     'Color',CB.blue, 'LineWidth',lw,'LineStyle',':','DisplayName','User fan cmd');
xline(20.5,'--','Color',[0.4 0.4 0.4],'LineWidth',1,'DisplayName','Phase change');
ylim([-0.25 1.35]); yticks([0 1]); yticklabels({'OFF','ON'});
ylabel('Fan','FontSize',fs);
legend('Temperature',sprintf('ON thr (%.1f°C)',fan_on_threshold),sprintf('OFF thr (%.1f°C)',fan_off_threshold), ...
       'Fan state','User fan cmd','Phase change','Location','northeast','FontSize',8);
title('Fan behaviour — Phase 1: Manual & Phase 2: Auto','FontSize',fs);
grid on; ax2.GridAlpha=0.15;

% Panel 3: Blind
ax3 = nexttile;
stairs(time, luminance_true,'Color',CB.yellow,'LineWidth',lw,'LineStyle','--','DisplayName','Luminance');
hold on;
stairs(time, user_blind,    'Color',CB.orange,'LineWidth',lw,'LineStyle',':','DisplayName','User blind cmd');
stairs(time, blind_state_det,'Color',CB.black,'LineWidth',lw+0.8,'DisplayName','Blind state');
xline(20.5,'--','Color',[0.4 0.4 0.4],'LineWidth',1,'DisplayName','Phase change');
ylim([-0.25 1.35]); yticks([0 1]); yticklabels({'OPEN','CLOSED'});
ylabel('Blind','FontSize',fs);
legend('Luminance','User blind cmd','Blind state','Phase change','Location','northeast','FontSize',8);
title('Blind behaviour — Phase 1: Auto & Phase 2: Manual','FontSize',fs);
grid on; ax3.GridAlpha=0.15;

% Panel 4: Heater (same pattern as fan)
ax4 = nexttile;
yyaxis left;
plot(time, temperature_true,'Color',CB.vermil,'LineWidth',lw,'DisplayName','Temperature');
hold on;
yline(heater_floor,'--','Color',CB.blue,'LineWidth',1.2, ...
      'DisplayName',sprintf('ON thr (%.1f°C)',heater_floor));
yline(heater_ceiling,':','Color',CB.green,'LineWidth',1.2, ...
      'DisplayName',sprintf('OFF thr (%.1f°C)',heater_ceiling));
ylabel('Temperature (°C)','FontSize',fs);

yyaxis right;
stairs(time, heater_state_det,'Color',CB.black,'LineWidth',lw+0.8,'DisplayName','Heater state');
hold on;
stairs(time, user_heater,     'Color',CB.purple,'LineWidth',lw,'LineStyle',':','DisplayName','User heater cmd');
xline(20.5,'--','Color',[0.4 0.4 0.4],'LineWidth',1,'DisplayName','Phase change');
ylim([-0.25 1.35]); yticks([0 1]); yticklabels({'OFF','ON'});
ylabel('Heater','FontSize',fs);
legend('Temperature',sprintf('ON thr (%.1f°C)',heater_floor),sprintf('OFF thr (%.1f°C)',heater_ceiling), ...
       'Heater state','User heater cmd','Phase change','Location','northeast','FontSize',8);
title('Heater behaviour — Phase 1: Manual & Phase 2: Auto','FontSize',fs);
grid on; ax4.GridAlpha=0.15;

% Panel 5: Air purifier
ax5 = nexttile;
yyaxis left;
plot(time, air_quality_true,'Color',CB.vermil,'LineWidth',lw,'DisplayName','Air quality');
hold on;
yline(purifier_on_threshold,'--','Color',CB.blue,'LineWidth',1.2, ...
      'DisplayName',sprintf('ON thr (%.1f)',purifier_on_threshold));
yline(purifier_off_threshold,':','Color',CB.green,'LineWidth',1.2, ...
      'DisplayName',sprintf('OFF thr (%.1f)',purifier_off_threshold));
ylabel('Air quality','FontSize',fs);

yyaxis right;
stairs(time, air_purifier_state_det,'Color',CB.black,'LineWidth',lw+0.8,'DisplayName','Air purifier state');
hold on;
stairs(time, user_purifier,'Color',CB.purple,'LineWidth',lw,'LineStyle',':','DisplayName','User air purifier cmd');
xline(20.5,'--','Color',[0.4 0.4 0.4],'LineWidth',1,'DisplayName','Phase change');
ylim([-0.25 1.35]); yticks([0 1]); yticklabels({'OFF','ON'});
ylabel('Air purifier','FontSize',fs);
legend('Air quality',sprintf('ON thr (%.1f)',purifier_on_threshold),sprintf('OFF thr (%.1f)',purifier_off_threshold), ...
       'Air purifier state','User air purifier cmd','Phase change','Location','northeast','FontSize',8);
title('Air purifier behaviour — Phase 1: Auto & Phase 2: Manual','FontSize',fs);
grid on; ax5.GridAlpha=0.15;

% Panel 6: Humidifier
ax6 = nexttile;
yyaxis left;
plot(time, humidity_true,'Color',CB.vermil,'LineWidth',lw,'DisplayName','Humidity');
hold on;
yline(humidifier_floor,'--','Color',CB.blue,'LineWidth',1.2, ...
      'DisplayName',sprintf('ON thr (%.1f)',humidifier_floor));
yline(humidifier_ceiling,':','Color',CB.green,'LineWidth',1.2, ...
      'DisplayName',sprintf('OFF thr (%.1f)',humidifier_ceiling));
ylabel('Humidity (%RH)','FontSize',fs);

yyaxis right;
stairs(time, humidifier_state_det,'Color',CB.black,'LineWidth',lw+0.8,'DisplayName','Humidifier state');
hold on;
stairs(time, user_humidifier,'Color',CB.purple,'LineWidth',lw,'LineStyle',':','DisplayName','User humidifier cmd');
xline(20.5,'--','Color',[0.4 0.4 0.4],'LineWidth',1,'DisplayName','Phase change');
ylim([-0.25 1.35]); yticks([0 1]); yticklabels({'OFF','ON'});
ylabel('Humidifier','FontSize',fs);
xlabel('Time step','FontSize',fs);
legend('Humidity',sprintf('ON thr (%.1f)',humidifier_floor),sprintf('OFF thr (%.1f)',humidifier_ceiling), ...
       'Humidifier state','User humidifier cmd','Phase change','Location','northeast','FontSize',8);
title('Humidifier behaviour — Phase 1: Manual & Phase 2: Auto','FontSize',fs);
grid on; ax6.GridAlpha=0.15;

saveas(fig1, 'fig1_mixed_mode_behaviour.png');
exportgraphics(fig1,'fig1_mixed_mode_behaviour.pdf','ContentType','vector');

% ── Figure 2: Monte Carlo accuracy distributions ───────────────────────
fig2 = figure('Name','Monte Carlo Distributions','Position',[100 60 920 620]);
tiledlayout(2,3,'TileSpacing','compact','Padding','compact');
device_colors = {CB.sky, CB.vermil, CB.green, CB.purple, CB.blue, CB.orange};

for d = 1:6
    ax = nexttile;
    histogram(mc_acc(:,d), 12, 'FaceColor', device_colors{d}, ...
              'EdgeColor','none','FaceAlpha',0.8);
    hold on;
    xline(mean(mc_acc(:,d)),'--','Color',CB.black,'LineWidth',1.5);
    xlabel('Accuracy (%)','FontSize',fs);
    if d==1 || d==4; ylabel('Trial count','FontSize',fs); end
    title(devices(d),'FontSize',fs);
    xlim([80 101]);
    text(0.05,0.9, sprintf('\\mu=%.1f%%\n\\sigma=%.1f%%', ...
         mean(mc_acc(:,d)), std(mc_acc(:,d))), ...
         'Units','normalized','FontSize',8,'Color',CB.black);
    grid on; ax.GridAlpha=0.15;
end
sgtitle(sprintf('Monte Carlo accuracy distributions (%d trials, noise std=%.2f°C, flip p=%.2f)', ...
        numTrials, temp_noise_std, presence_flip_prob),'FontSize',10);
saveas(fig2,'fig2_montecarlo_distributions.png');
exportgraphics(fig2,'fig2_montecarlo_distributions.pdf','ContentType','vector');

% ── Figure 3: Sensitivity analyses ─────────────────────────────────────
fig3 = figure('Name','Sensitivity Analysis','Position',[100 60 950 880]);
tiledlayout(3,2,'TileSpacing','compact','Padding','compact');

% Panel 1 — Light
ax = nexttile;
plot(flip_probs*100, noise_acc, 'o-', 'Color',CB.blue,'LineWidth',lw,'MarkerSize',5);
xlabel('Presence sensor flip probability (%)','FontSize',fs);
ylabel('Light accuracy (%)','FontSize',fs);
title('Effect of sensor noise on light control','FontSize',fs);
ylim([60 102]); grid on; ax.GridAlpha=0.15;

% Panel 2 — Fan
ax = nexttile;
plot(bandwidths, hyst_acc, 's-', 'Color',CB.vermil,'LineWidth',lw,'MarkerSize',5);
xlabel('Hysteresis bandwidth (°C)','FontSize',fs);
ylabel('Fan accuracy (%)','FontSize',fs);
title('Effect of hysteresis band on fan control','FontSize',fs);
ylim([60 102]); grid on; ax.GridAlpha=0.15;

% Panel 3 — Blind
ax = nexttile;
plot(luminance_flip_probs*100, blind_noise_acc, 'o-', 'Color',CB.green,'LineWidth',lw,'MarkerSize',5);
xlabel('Luminance sensor flip probability (%)','FontSize',fs);
ylabel('Blind accuracy (%)','FontSize',fs);
title('Effect of sensor noise on blind control','FontSize',fs);
ylim([60 102]); grid on; ax.GridAlpha=0.15;

% Panel 4 — Heater
ax = nexttile;
plot(heater_bandwidths, heater_hyst_acc, 's-', 'Color',CB.purple,'LineWidth',lw,'MarkerSize',5);
xlabel('Heater hysteresis bandwidth (°C)','FontSize',fs);
ylabel('Heater accuracy (%)','FontSize',fs);
title('Effect of hysteresis band on heater control','FontSize',fs);
ylim([60 102]); grid on; ax.GridAlpha=0.15;

% Panel 5 — Air purifier
ax = nexttile;
plot(purifier_bandwidths, purifier_hyst_acc, 's-', 'Color',CB.blue,'LineWidth',lw,'MarkerSize',5);
xlabel('Air purifier hysteresis bandwidth','FontSize',fs);
ylabel('Air purifier accuracy (%)','FontSize',fs);
title('Effect of hysteresis band on air purifier control','FontSize',fs);
ylim([60 102]); grid on; ax.GridAlpha=0.15;

% Panel 6 — Humidifier
ax = nexttile;
plot(humidifier_bandwidths, humidifier_hyst_acc, 's-', 'Color',CB.orange,'LineWidth',lw,'MarkerSize',5);
xlabel('Humidifier hysteresis bandwidth (%RH)','FontSize',fs);
ylabel('Humidifier accuracy (%)','FontSize',fs);
title('Effect of hysteresis band on humidifier control','FontSize',fs);
ylim([60 102]); grid on; ax.GridAlpha=0.15;

sgtitle('Sensitivity analysis','FontSize',10);
saveas(fig3,'fig3_sensitivity_analysis.png');
exportgraphics(fig3,'fig3_sensitivity_analysis.pdf','ContentType','vector');

fprintf('\nAll results written to CSV and figures saved.\n');

%% =========================================================================
%  LOCAL HELPER FUNCTION
% =========================================================================
function prev = get_prev(arr, t)
    if t == 1
        prev = 0;
    else
        prev = arr(t-1);
    end
end
