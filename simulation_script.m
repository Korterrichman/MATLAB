%% Simulation to demonstrate mode toggling.
% Purpose:
% Show that the light and fan works in both modes and can be controlled independently.
% Phase 1: Light = Automatic, Fan = Manual
% Phase 2: Light = Manual, Fan = Automatic

clear;
clc;
close all;

%% 1. Simulation settings
numSteps = 20;
time = 1:numSteps;

% Fan thresholds
fan_on_threshold  = 29.5;
fan_off_threshold = 27.5;

%% 2. Input data for automation
% Light input: presence only
presence = [0 1 1 0 1 1 0 0 1 1  1 0 1 1 0 1 0 1 1 0];

% Fan input: temperature only
temperature = [27 28 29 30 31 30 29 28 27 28  30 31 30 29 28 27 30 31 29 28];

%% 3. Device modes
% 1 = Automatic, 0 = Manual

% Phase 1 (1:10): Light Auto, Fan Manual
% Phase 2 (11:20): Light Manual, Fan Auto
light_mode = [ones(1,10), zeros(1,10)];
fan_mode   = [zeros(1,10), ones(1,10)];

%% 4. User commands
% These are only used when the device is in Manual mode

user_light = zeros(1, numSteps);
user_fan   = zeros(1, numSteps);


% Fan manual commands
user_fan(1:20) = [0 0 1 1 0 0 1 1 0 1 1 1 0 0 1 0 1 1 0 1];
% Light manual commands 
user_light(1:20) = [1 1 0 0 1 0 1 1 0 1 0 0 1 1 0 0 1 1 0 1];

%% 5. Output states
light_state = zeros(1, numSteps);
fan_state   = zeros(1, numSteps);

%% 6. Main simulation loop
for t = 1:numSteps
    
    % Light control mechanism
    % Automatic: light follows presence
    % Manual: light follows user command
    if light_mode(t) == 1
        light_state(t) = presence(t);
    else
        light_state(t) = user_light(t);
    end
    
    % Fan control mechanism
    % Automatic: fan follows temperature thresholds
    % Manual: fan follows user command
    if fan_mode(t) == 1
        if temperature(t) >= fan_on_threshold
            fan_state(t) = 1;
        elseif temperature(t) <= fan_off_threshold
            fan_state(t) = 0;
        else
            % Keep previous state between thresholds
            if t == 1
                fan_state(t) = 0;
            else
                fan_state(t) = fan_state(t-1);
            end
        end
    else
        fan_state(t) = user_fan(t);
    end
end

%% 7. Expected automatic fan output (for accuracy check)
expected_auto_fan = zeros(1, numSteps);

for t = 1:numSteps
    if temperature(t) >= fan_on_threshold
        expected_auto_fan(t) = 1;
    elseif temperature(t) <= fan_off_threshold
        expected_auto_fan(t) = 0;
    else
        if t == 1
            expected_auto_fan(t) = 0;
        else
            expected_auto_fan(t) = expected_auto_fan(t-1);
        end
    end
end

%% 8. Accuracy checks for the two phases
phase1 = 1:10;
phase2 = 11:20;

% Phase 1:
% Light should follow presence (Automatic)
% Fan should follow user command (Manual)
phase1_light_accuracy = mean(light_state(phase1) == presence(phase1)) * 100;
phase1_fan_accuracy   = mean(fan_state(phase1) == user_fan(phase1)) * 100;

% Phase 2:
% Light should follow user command (Manual)
% Fan should follow automatic temperature logic (Automatic)
phase2_light_accuracy = mean(light_state(phase2) == user_light(phase2)) * 100;
phase2_fan_accuracy   = mean(fan_state(phase2) == expected_auto_fan(phase2)) * 100;

%% 9. Create detailed results table
% This shows all the inputs and outputs in the simulation
resultsTable = table( ...
    time', presence', temperature', light_mode', fan_mode', ...
    user_light', user_fan', light_state', fan_state', ...
    'VariableNames', { ...
    'TimeStep', 'Presence', 'Temperature', 'LightMode', 'FanMode', ...
    'UserLightCommand', 'UserFanCommand', 'LightState', 'FanState'});

writetable(resultsTable, 'mixed_mode_detailed_results.csv');

%% 10. Create summary table
% This give us a quick view of the accuracy of the system
summaryTable = table( ...
    ["Phase 1"; "Phase 2"], ...
    ["Automatic"; "Manual"], ...
    ["Manual"; "Automatic"], ...
    ["Presence"; "User Command"], ...
    ["User Command"; "Temperature"], ...
    [phase1_light_accuracy; phase2_light_accuracy], ...
    [phase1_fan_accuracy; phase2_fan_accuracy], ...
    'VariableNames', { ...
    'Phase', 'LightMode', 'FanMode', ...
    'LightControlSource', 'FanControlSource', ...
    'LightAccuracyPercent', 'FanAccuracyPercent'});

writetable(summaryTable, 'mixed_mode_summary_results.csv');

%% 11. Display the summary in the Command Window
disp('Summary of device independence test:');
disp(summaryTable);

%% 12. Plot figure to show the overall behaviour of the light and the fan
figure('Name', 'Mixed-Mode Device Independence', 'Position', [100 100 950 850]);
tiledlayout(4,1);

% Panel 1: Light input, manual command, and output
nexttile;
stairs(time, presence, 'LineWidth', 1.5);
hold on;
stairs(time, user_light, '--', 'LineWidth', 1.5);
stairs(time, light_state, 'LineWidth', 1.8);
xline(10.5, '--', 'Phase Change', 'LineWidth', 1.2);
ylim([-0.2 1.2]);
ylabel('Light');
legend('Presence', 'User Light Command', 'Light State', 'Location', 'best');
title('Light Behaviour');

% Panel 2: Fan input, manual command, and output
nexttile;
yyaxis left;
plot(time, temperature, 'LineWidth', 1.5);
hold on;
yline(fan_on_threshold, '--', 'ON Threshold');
yline(fan_off_threshold, '--', 'OFF Threshold');
ylabel('Temperature (°C)');

yyaxis right;
stairs(time, fan_state, 'LineWidth', 1.8);
hold on;
stairs(time, user_fan, '--', 'LineWidth', 1.5);
ylim([-0.2 1.2]);
ylabel('Fan / Command');
xline(10.5, '--', 'Phase Change', 'LineWidth', 1.2);
title('Fan Behaviour');
legend('Temperature', 'ON Threshold', 'OFF Threshold', 'Fan State', 'User Fan Command', 'Location', 'best');

% Panel 3: Light mode
nexttile;
stairs(time, light_mode, 'LineWidth', 1.5);
xline(10.5, '--', 'Phase Change', 'LineWidth', 1.2);
ylim([-0.2 1.2]);
yticks([0 1]);
yticklabels({'Manual','Automatic'});
ylabel('Light Mode');
title('Light Operating Mode');

% Panel 4: Fan mode
nexttile;
stairs(time, fan_mode, 'LineWidth', 1.5);
xline(10.5, '--', 'Phase Change', 'LineWidth', 1.2);
ylim([-0.2 1.2]);
yticks([0 1]);
yticklabels({'Manual','Automatic'});
ylabel('Fan Mode');
xlabel('Time Step');
title('Fan Operating Mode');

saveas(gcf, 'mixed_mode_independence_figure.png');