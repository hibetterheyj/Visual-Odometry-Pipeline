%% Setup
close all;clear;clc;

% add path of functions
addpath(genpath('utils'))
addpath('Continuous_operation')  
addpath('Initialization')  

ds = 0; % 0: KITTI, 1: Malaga, 2: parking

if ds == 0
    % need to set kitti_path to folder containing "05" and "poses"
    kitti_path = 'data/kitti'; 
    assert(exist('kitti_path', 'var') ~= 0);
    ground_truth = load([kitti_path '/poses/05.txt']);
    ground_truth = ground_truth(:, [end-8 end]);
    last_frame = 4540;
    K = [7.188560000000e+02 0 6.071928000000e+02
        0 7.188560000000e+02 1.852157000000e+02
        0 0 1];
elseif ds == 1
    % Path containing the many files of Malaga 7.
    malaga_path = 'data/malaga';
    assert(exist('malaga_path', 'var') ~= 0);
    images = dir([malaga_path ...
        '/malaga-urban-dataset-extract-07_rectified_800x600_Images']);
    left_images = images(3:2:end);
    last_frame = length(left_images);
    K = [621.18428 0 404.0076
        0 621.18428 309.05989
        0 0 1];
elseif ds == 2
    % Path containing images, depths and all...
    parking_path = 'data/parking';
    assert(exist('parking_path', 'var') ~= 0);
    last_frame = 598;
    K = load([parking_path '/K.txt']);
     
    ground_truth = load([parking_path '/poses.txt']);
    ground_truth = ground_truth(:, [end-8 end]);
else
    assert(false);
end

%% Bootstrap
% need to set bootstrap_frames
if ds == 0
    img0 = imread([kitti_path '/05/image_0/' ...
        sprintf('%06d.png',bootstrap_frames(1))]);
    img1 = imread([kitti_path '/05/image_0/' ...
        sprintf('%06d.png',bootstrap_frames(2))]);
elseif ds == 1
    img0 = rgb2gray(imread([malaga_path ...
        '/malaga-urban-dataset-extract-07_rectified_800x600_Images/' ...
        left_images(bootstrap_frames(1)).name]));
    img1 = rgb2gray(imread([malaga_path ...
        '/malaga-urban-dataset-extract-07_rectified_800x600_Images/' ...
        left_images(bootstrap_frames(2)).name]));
elseif ds == 2
    img0 = rgb2gray(imread([parking_path ...
        sprintf('/images/img_%05d.png',bootstrap_frames(1))]));
    img1 = rgb2gray(imread([parking_path ...
        sprintf('/images/img_%05d.png',bootstrap_frames(2))]));
else
    assert(false);
end


%% Directly get bootstrap from exe7, for debugging continuous operation only
debug = true;

K = load('data/data_exe7/K.txt');
S.P = load('data/data_exe7/keypoints.txt')'; %(row,col)
S.X = load('data/data_exe7/p_W_landmarks.txt')';
S.C = [];%(row,col)
S.F = [];%(row,col)
S.F_W = []; % normalized image coordinates (expressed in world coordinate)
S.T = [];
idx = rand(200,1);

database_image = imread('data/data_exe7/000000.png');
bootstrap_frames = zeros(2,1);
last_frame = 9;

%% Continuous operation

% generate and initialize KLT tracker
% for landmark tracking
KLT_tracker_L = vision.PointTracker('BlockSize',[15 15],'NumPyramidLevels',2,...
    'MaxIterations',50,'MaxBidirectionalError',3);
initialize(KLT_tracker_L,fliplr(S.P'),database_image);
% [features, valid_key_points] = detectkeypoints(database_image); 
% initialize(KLT_tracker_c,valid_key_points.Location,database_image);
prev_img = database_image;

% for candidate keypoints tracking
KLT_tracker_C = vision.PointTracker('BlockSize',[15 15],'NumPyramidLevels',2,...
    'MaxIterations',50,'MaxBidirectionalError',3);

% parameters for discarding redundant new candidate keypoints
r_discard_redundant = 5;

% parameters for deciding whether or not to add a triangulated landmark
angle_threshold = pi*20/180; %start with pi*10/180 dervie by Rule of the thumb:
    
range = (bootstrap_frames(2)+1):last_frame;
for i = range
    fprintf('\n\nProcessing frame %d\n=====================\n', i);
    if ds == 0
        image = imread([kitti_path '/05/image_0/' sprintf('%06d.png',i)]);
    elseif ds == 1
        image = rgb2gray(imread([malaga_path ...
            '/malaga-urban-dataset-extract-07_rectified_800x600_Images/' ...
            left_images(i).name]));
    elseif ds == 2
        image = im2uint8(rgb2gray(imread([parking_path ...
            sprintf('/images/img_%05d.png',i)])));
    else
        assert(false);
    end
    
    %%%% only for debug
    image = imread(['data/data_exe7/' sprintf('%06d.png',i)]);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%% assciate keypoints %%%%%%%%%%%%%%%%%%%%%%%
    % detect keypoints
    [features, valid_key_candidates] = detectkeypoints(image); 
    % figure(1); imshow(image); hold on;plot(valid_key_points); % plot
    
    % KLT tracking
    [matched_points,validity] = KLT_tracker_L(image);
    matched_points_valid = fliplr(matched_points(validity,:));
    
    % perform RANSAC to find best Pose and inliers
    [R_C_W, t_C_W, inlier_mask, max_num_inliers_history, num_iteration_history] = ...
        ransacLocalization(matched_points_valid', S.X(:,validity), K);
    R_W_C = R_C_W';
    T_W_C = -R_C_W'*t_C_W;
    
    % plotting
%     plot_KLT_debug(S,fliplr(matched_points),prev_img,image,validity,inlier_mask);
    
    % update KLT_tracker (for landmarks)
    release(KLT_tracker_L);
    S.P = matched_points_valid((inlier_mask)>0,:)';
    S.X = S.X(:,validity);
    S.X = S.X(:,(inlier_mask)>0);
    initialize(KLT_tracker_L,fliplr(S.P'),image);
    
    % track candidate keypoints
    if ~isempty(S.C)
        [matched_points_candidate,validity_candidate] = KLT_tracker_L(image);
        matched_points_valid_candidate = fliplr(matched_points_candidate(validity_candidate,:)); %(u,v) to (row,col)
        S.C = S.C(:,validity_candidate);
        S.F = S.F(:,validity_candidate);
        S.F_W = S.F_W(:,validity_candidate);
        S.T = S.T(:,validity_candidate);
        
        % calculate angle
        temp = fliplr(matched_points_valid_candidate)'; % (row, col) to (u,v)
        normalized_matched_candidate = K\[temp; ones(1,size(temp,2))];
        normalized_matched_candidate_world = R_W_C*normalized_matched_candidate...
            + repmat(T_W_C, [1 size(normalized_matched_candidate,2)]);
        angles = acos(sum(normalized_matched_candidate_world.*S.F_W,1)./...
            (vecnorm(normalized_matched_candidate_world).*vecnorm(S.F_W)));
        whehter_append = angles>angle_threshold;
        
        % append landmarks for candidate keypoints whose angle is larger
        % than given threshold
        num_added = sum(whehter_append);
        p_first = [flipud(S.F(:,whehter_append)); ones(1,num_added)]; %(u,v,1)
        M_vec_current = S.T(:,whehter_append);
        p_current = [temp(:,whehter_append); ones(1,num_added)]; %(u,v,1)
        M_current = K*[R_C_W t_C_W];
        for ii = 1:num_added
            M_first = K*[reshape(M_vec_current(1:9,ii),[3,3]) M_vec_current(10:12,ii)];
            P_est = linearTriangulation(p_current(:,ii),p_first(:,ii),M_current,M_first);
        end
    end
        
    % discard redundant new candidate keypoints (whose distance to any
    % existing keypoints is less than 'r_discard_redundant')
    redundant_map = ones(size(image)); 
    for ii = 1:size(S.P,2)
        redundant_map(max(1,floor(S.P(1,ii)-r_discard_redundant)):...
            min(ceil(S.P(1,ii)+r_discard_redundant),size(redundant_map,1)),...
            max(1,floor(S.P(2,ii)-r_discard_redundant)):...
            min(ceil(S.P(2,ii)+r_discard_redundant),size(redundant_map,2))) = 0;
    end
    no_discard = ones(size(valid_key_candidates.Location,1),1);
    for ii = 1:size(valid_key_candidates.Location,1)
        no_discard(ii) = redundant_map(round(valid_key_candidates.Location(ii,2)),round(valid_key_candidates.Location(ii,1)));
    end
    no_discard = logical(no_discard);
    
    % plot for debugging
    plot_discard_debug(image,S,valid_key_candidates,no_discard)
    
    valid_key_candidates = valid_key_candidates(no_discard); 
    S.C = [S.C, flipud(valid_key_candidates.Location')];
    S.F = [S.F, flipud(valid_key_candidates.Location')];
    unnormalized_camera_coord = [valid_key_candidates.Location';...
        ones(1,size(valid_key_candidates.Location,1))]; % (u,v)
    normalized_camera_coord = K\unnormalized_camera_coord;
    normalized_camera_coord_world = R_W_C*normalized_camera_coord...
        + repmat(T_W_C, [1 size(normalized_camera_coord,2)]);
    S.F_W = [S.F_W normalized_camera_coord_world];
    S.T = [S.T, repmat([R_C_W(:);t_C_W(:)],1,size(valid_key_candidates.Location,1))];
    
    % update KLT_tracker (for candidate)
    if ~isempty(S.C)
        release(KLT_tracker_C);
        initialize(KLT_tracker_C,fliplr(S.C'),image);
    end
    
    % Makes sure that plots refresh.    
    pause(0.01);
    
    prev_img = image;
end