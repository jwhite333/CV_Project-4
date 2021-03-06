clear;
clc;
close all;
%  Exploiting the Circulant Structure of Tracking-by-detection with Kernels
%
%  Main script for tracking, with a gaussian kernel.
%
%  Jo�o F. Henriques, 2012
%  http://www.isr.uc.pt/~henriques/


%choose the path to the videos (you'll be able to choose one with the GUI)
base_path = './data/';


%parameters according to the paper
padding = 1;					%extra area surrounding the target
output_sigma_factor = 1/16;		%spatial bandwidth (proportional to target)
sigma = 0.2;					%gaussian kernel bandwidth
lambda = 1e-2;					%regularization
interp_factor = 0.075;			%linear interpolation factor for adaptation
occluded = false;


%notation: variables ending with f are in the frequency domain.

%ask the user for the video
video_path = choose_video(base_path);
if isempty(video_path), return, end  %user cancelled
[img_files, pos, target_sz, resize_image, ground_truth, video_path] = ...
    load_video_info(video_path);


%window size, taking padding into account
sz = floor(target_sz * (1 + padding));

%desired output (gaussian shaped), bandwidth proportional to target size
output_sigma = sqrt(prod(target_sz)) * output_sigma_factor;
[rs, cs] = ndgrid((1:sz(1)) - floor(sz(1)/2), (1:sz(2)) - floor(sz(2)/2));
yCoord = exp(-0.5 / output_sigma^2 * (rs.^2 + cs.^2));
yf = fft2(yCoord);

%store pre-computed cosine window
cos_window = hann(sz(1)) * hann(sz(2))';


time = 0;  %to calculate FPS
positions = zeros(numel(img_files), 2);  %to calculate precision

originalPos(1,:) = pos;
threshold = 5;
count = 0;
hankel_order = 9;
req_measurements = hankel_order*2-1;
sq_error = 0;

for frame = 1:numel(img_files)
    %load image
    im = imread([video_path img_files{frame}]);
    if size(im,3) > 1,
        im = rgb2gray(im);
    end
    if resize_image,
        im = imresize(im, 0.5);
    end
    
    tic()
    
    %extract and pre-process subwindow
    x = get_subwindow(im, pos, sz, cos_window);
    
    if frame > 1,
        %calculate response of the classifier at all locations
        k = dense_gauss_kernel(sigma, x, z);
        response = real(ifft2(alphaf .* fft2(k)));   %(Eq. 9)
        
        %target location is at the maximum response
        [row, col] = find(response == max(response(:)), 1);
  
        originalPos(frame,:) = pos - floor(sz/2) + [row, col];
        
        
        %PSR
        sideLobe = response;
        r1 = row - 5;
        r2 = row + 5;
        c1 = col - 5;
        c2 = col + 5;
        [m,n]=size(sideLobe);
        if r1 < 1, r1 =1; end
        if r2 > m, r2 =m; end
        if c1 < 1, c1 =1; end
        if c2 > n, c2 = n; end
        
        % Ignore window around peak
        ignore_index = zeros(size(sideLobe));
        ignore_index(r1:r2,c1:c2) = 1;
        
        % Get mean/std dev outside window
        meanValue = mean(mean(sideLobe(ignore_index ~= 1)));
        stdValue = std(sideLobe(ignore_index ~= 1));
        
        PSR(frame,1) = (max(response(:)) - meanValue)/stdValue;  
          
        % Hankel Matrix
        if frame > req_measurements && PSR(frame,1) < threshold
            occluded = true;
            fprintf("Occluded, PSR = %.2f\n",PSR(frame,1));
            
            % Creating the hankel matrix 
            Hx = zeros(hankel_order,hankel_order);
            Hy = zeros(hankel_order,hankel_order);
            for i = 1:hankel_order
                for j = 1:hankel_order
                    index = i+j-2;
                    %Hx(i,j) = positions(frame-req_measurements+index,1);
                    Hy(i,j) = positions(frame-req_measurements+index,2);
                end
            end
            
            %x_coeff = linsolve(Hx(:,1:hankel_order-1),Hx(:,hankel_order));
            y_coeff = linsolve(Hy(:,1:hankel_order-1),Hy(:,hankel_order));
            
            %x_guess = round(Hx(end,2:end)*x_coeff);
            y_guess = round(Hy(end,2:end)*y_coeff);
                
            [m,n]=size(im);
            %x_guess = min(max(1,x_guess),m);
            y_guess = min(max(1,y_guess),n);
            
            % Assume constant velocity for the X direction
            V = positions(frame-1,:) -  positions(frame-2,:);
            xTemp = positions(frame-1,1)+V(1,1);
            pos= [xTemp,y_guess];
            
            fprintf("Estimated position: [%i,%i]\n",xTemp,y_guess);
        else
            % Recaculate the pos (given code)
            pos = pos - floor(sz/2) + [row, col];
            occluded = false;
        end
    end
    
    % Don't retrain on occluded template
    if ~occluded
        %get subwindow at current estimated target position, to train classifer
        x = get_subwindow(im, pos, sz, cos_window);

        %Kernel Regularized Least-Squares, calculate alphas (in Fourier domain)
        k = dense_gauss_kernel(sigma, x);
        new_alphaf = yf ./ (fft2(k) + lambda);   %(Eq. 7)
        new_z = x;

        if frame == 1,  %first frame, train with a single image
            alphaf = new_alphaf;
            z = x;
        else
            %subsequent frames, interpolate model
            alphaf = (1 - interp_factor) * alphaf + interp_factor * new_alphaf;
            z = (1 - interp_factor) * z + interp_factor * new_z;
        end
    end
    
    %save position and calculate FPS
    positions(frame,:) = pos;
    time = time + toc();
    
    %visualization
    rect_position = [pos([2,1]) - target_sz([2,1])/2, target_sz([2,1])];
    if frame == 1,  %first frame, create GUI
        figure('NumberTitle','off', 'Name',['Tracker - ' video_path]);
        im_handle = imshow(im, 'Border','tight', 'InitialMag',200);
        rect_handle = rectangle('Position',rect_position, 'EdgeColor','g');
    else
        try  %subsequent frames, update GUI
            set(im_handle, 'CData', im)
            set(rect_handle, 'Position', rect_position)
        catch  %#ok, user has closed the window
            return
        end
    end
    
    drawnow
     	%pause(0.05)  %uncomment to run slower
        
    % Calculate squared error ignoring NaN
    if frame < 352
        sq_error = sq_error + (ground_truth(frame,1)-pos(1))^2 + (ground_truth(frame,2)-pos(2))^2;
    end
end

if resize_image, positions = positions * 2; end

disp(['Frames-per-second: ' num2str(numel(img_files) / time)])

%show the precisions plot
show_precision(positions, ground_truth, video_path)

fprintf("Total squared error: %.2f\n",sq_error);

