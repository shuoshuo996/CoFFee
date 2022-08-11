function fData = CFF_convert_KMALLdata_to_fData(KMALLdataGroup,varargin)
%CFF_CONVERT_KMALLDATA_TO_FDATA  Convert kmall data to the CoFFee format
%
%   Converts Kongsberg EM series data FROM the KMALLdata format (read by
%   CFF_READ_KMALL) TO the CoFFee fData format used in processing.
%
%   fData = CFF_CONVERT_KMALLDATA_TO_FDATA(KMALLdata) converts the contents
%   of one KMALLdata structure to a structure in the fData format.
%
%   fData = CFF_CONVERT_KMALLDATA_TO_FDATA(KMALLdataGroup) converts an
%   array of two KMALLdata structures into one fData sructure. The pair of
%   structure must correspond to an .kmall/.kmwcd pair of files. Do not try
%   to use this feature to convert KMALLdata structures from different
%   acquisition files. It will not work. Convert each into its own fData
%   structure.
%
%   Note that the KMALLdata structures are converted to fData in the order
%   they are in input, and that the first ones take precedence. Aka in the
%   example above, if the second structure contains a type of datagram that
%   is already in the first, they will NOT be converted. This is to avoid
%   doubling up the data that may exist in duplicate in the pair of raw
%   files. You need to order the KMALLdata structures in input in order of
%   desired precedence.
%
%   fData = CFF_CONVERT_KMALLDATA_TO_FDATA(KMALLdata,dr_sub,db_sub)
%   operates the conversion with a sub-sampling of the water-column data
%   (either WC or AP datagrams) in range and in beams. For example, to
%   sub-sample range by a factor of 10 and beams by a factor of 2, use:
%   fData = CFF_CONVERT_KMALLDATA_TO_FDATA(KMALLdata,10,2).

%   DEV NOTE: To date (July 2021), the fData format is based on three
%   dimensions ping x beam x sample, but the lowest-level unit in kmall is
%   the "swath" to accomodate dual-and multi-swath operating modes. For
%   example, in dual-swath mode, a single Tx transducer will transmit 2
%   pulses to create two along-swathes, and in kmall those two swathes are
%   recorded with the same ping counter because they were produced at about
%   the same time. 
%   To deal with this, we're going to create new "swath numbers" based on
%   the original ping number and swath counter for a ping.
%   For example a ping #832 made up of four swathes counted 0-3 will have
%   new "swath numbers" of 832.00, 832.01, 832.02, and 832.03. We will
%   maintain the current "ping" nomenclature in fData, but using those
%   swath numbers.
%   Note that if we have single-swath data, then the swath number matches
%   the ping number (832). 
%   Note that this is made more complicated by the fact that an individual
%   swathe can have its data on multiple consecutive datagrams, as
%   different "Rx fans" (i.e multiple Rx heads) are recorded on separate
%   datagrams.
%
%   NOTE: a new "inspection" mode with alternating low/high frequency trips
%   up the code. To fix eventually when needed XXX2
%   There also seem to be some issues with location of bottom on some
%   dual head data. To fix eventually XXX1
%

%   Authors: Alex Schimel (NGU, alexandre.schimel@ngu.no) and Yoann
%   Ladroit (NIWA, yoann.ladroit@niwa.co.nz)
%   2017-2021; Last revision: 21-07-2021


%% Input arguments management
p = inputParser;

% array of KMALLdata structures
addRequired(p,'KMALLdataGroup',@(x) isstruct(x) || iscell(x));

% decimation factor in range and beam
addOptional(p,'dr_sub',1,@(x) isnumeric(x)&&x>0);
addOptional(p,'db_sub',1,@(x) isnumeric(x)&&x>0);

% information communication
addParameter(p,'comms',CFF_Comms()); % no communication by default

% parse inputs
parse(p,KMALLdataGroup,varargin{:})

% and get results
KMALLdataGroup = p.Results.KMALLdataGroup;
dr_sub = p.Results.dr_sub;
db_sub = p.Results.db_sub;
global comms
if ischar(p.Results.comms)
    comms = CFF_Comms(p.Results.comms);
else
    comms = p.Results.comms;
end
clear p;

if isstruct(KMALLdataGroup)
    % just one structure
    KMALLdataGroup = {KMALLdataGroup};
end

% check input
if numel(KMALLdataGroup)==1
    % single KMALLdata structure
    
    % check it's from Kongsberg and that source file exist
    has_KMALLfilename = isfield(KMALLdataGroup{1}, 'KMALLfilename');
    if ~has_KMALLfilename || ~CFF_check_KMALLfilename(KMALLdataGroup{1}.KMALLfilename)
        error('Invalid input');
    end
    
elseif numel(KMALLdataGroup)==2
    % pair of KMALLdata structures
    
    % check it's from a pair of Kongsberg kmall/kmwcd files and that source
    % files exist
    has_KMALLfilename = cell2mat(cellfun(@(x) isfield(x, 'KMALLfilename'), KMALLdataGroup, 'UniformOutput', false));
    rawfilenames = cellfun(@(x) x.KMALLfilename, KMALLdataGroup, 'UniformOutput', false);
    if ~all(has_KMALLfilename) || ~CFF_check_KMALLfilename(rawfilenames)
        error('Invalid input');
    end
    
else
    error('Invalid input');
end


%% Prep

% start message
comms.start('Converting to fData format');

% number of individual KMALLdata structures in input KMALLdataGroup
nStruct = length(KMALLdataGroup);

% initialize fData, with current version number
fData.MET_Fmt_version = CFF_get_current_fData_version();

% initialize source filenames
fData.ALLfilename = cell(1,nStruct);

% start progress
comms.progress(0,nStruct);


%% take one KMALLdata structure at a time and add its contents to fData
for iF = 1:nStruct
    
    % get current structure
    KMALLdata = KMALLdataGroup{iF};
    
    % add source filename
    KMALLfilename = KMALLdata.KMALLfilename;
    fData.ALLfilename{iF} = KMALLfilename;
    
    % now reading each type of datagram.
    % Note we only convert the datagrams if fData does not already contain
    % any.
    
    
    %% '#IIP - Installation parameters and sensor setup'
    if isfield(KMALLdata,'EMdgmIIP') && ~isfield(fData,'IP_ASCIIparameters')
        
        comms.step('Converting #IIP'); 
        
        % number of entries
        % nD = numel(KMALLdata.EMdgmIIP);
        
        % get date and time-since-midnight-in-milleseconds from header
        % [fData.IP_1D_Date, fData.IP_1D_TimeSinceMidnightInMilliseconds] = CFF_get_date_and_TSMIM_from_kmall_header([KMALLdata.EMdgmIIP.header]);
        
        % DEV NOTES: Only value needed (to date) is the "sonar
        % heading offset". In installation parameters datagrams of .all
        % files, we only had one field "S1H" per head. Here we have heading
        % values for both the Tx and Rx antennae. So not sure which one we
        % should take, or the difference between the two... but for now,
        % take the value from Rx.
        
        % read ASCIIdata
        ASCIIdata = KMALLdata.EMdgmIIP(1).install_txt;
        
        % remove carriage returns, tabs and linefeed
        ASCIIdata = regexprep(ASCIIdata,char(9),'');
        ASCIIdata = regexprep(ASCIIdata,newline,'');
        ASCIIdata = regexprep(ASCIIdata,char(13),'');
        
        % read some fields and record value in old field for the software
        % to pick up
        try
            IP_ASCIIparameters.TRAI_RX1 = CFF_read_TRAI(ASCIIdata,'TRAI_RX1');
            IP_ASCIIparameters.S1H = IP_ASCIIparameters.TRAI_RX1.H;
        catch
            % at least in some EM2040C dual head data, I've found this
            % field missing and instead having TRAI_HD1
            IP_ASCIIparameters.TRAI_HD1 = CFF_read_TRAI(ASCIIdata,'TRAI_HD1');
            IP_ASCIIparameters.S1H = IP_ASCIIparameters.TRAI_HD1.H;
        end
        
        % finally store in fData
        fData.IP_ASCIIparameters = IP_ASCIIparameters;
        
    end
    
    
    %% '#MRZ - Multibeam (M) raw range (R) and depth(Z) datagram'
    if isfield(KMALLdata,'EMdgmMRZ') && ~isfield(fData,'X8_1D_Date')
        
        comms.step('Converting #MRZ'); 
        
        % DEV NOTE: note we don't decimate beam data here as we do for
        % water-column data
        
        % remove duplicate datagrams
        EMdgmMRZ = CFF_remove_duplicate_KMALL_datagrams(KMALLdata.EMdgmMRZ);

        % extract data
        header   = [EMdgmMRZ.header];
        cmnPart  = [EMdgmMRZ.cmnPart];
        pingInfo = [EMdgmMRZ.pingInfo];
        rxInfo   = [EMdgmMRZ.rxInfo];
        sounding = [EMdgmMRZ.sounding];
        % CFF_get_kmall_TxRx_info(cmnPart) % evaluate to get info for debugging
        
        % DEV NOTE: In the .all format, we only record two fields from the
        % "Runtime Parameters" datagram: "TransmitPowerReMaximum" for
        % radiometric corrections, and "ReceiveBeamwidth" for estimation of
        % the bottom echo for its removal. In the .kmall format, these two
        % values are found in the MRZ datagrams.
        
        % Receive beamwidth
        Rx_BW = unique([pingInfo.receiveArraySizeUsed_deg]);
        if numel(Rx_BW)>1
            comms.error('Found more than one Rx beamwidth records. Keeping only the first value');
        end
        fData.Ru_1D_ReceiveBeamwidth = Rx_BW(1);
        
        % Transmit Power Re Maximum
        Tx_pow = unique([pingInfo.transmitPower_dB]);
        if numel(Tx_pow)>1
            comms.error('Found more than one Tx Power records. Keeping only the first value');
        end
        fData.Ru_1D_TransmitPowerReMaximum = Tx_pow(1);
                
        % number of datagrams
        nDatag = numel(cmnPart);
        
        % number of pings
        dtg_pingCnt = [cmnPart.pingCnt]; % actual ping number for each datagram
        dtg_swathAlongPosition = [cmnPart.swathAlongPosition]; % swath number for a ping
        dtg_swathCnt = dtg_pingCnt + 0.01.*dtg_swathAlongPosition; % "new ping number" for each datagram
        [swath_counter, iFirstDatagram, iC] = unique(dtg_swathCnt,'stable'); % list of swath numbers
        nSwaths = numel(swath_counter); % total number of swaths in file
        
        % number of beams
        dtg_nBeams = [rxInfo.numSoundingsMaxMain]; % number of beams per datagram ("main soundings" only. Ignoring "extra detections")
        nBeams = arrayfun(@(idx) sum(dtg_nBeams(iC==idx)), 1:nSwaths); % total number of beams per swath
        maxnBeams = nanmax(nBeams); % maximum number of "beams per swath" in the file
        
        % date and time
        [dtg_date,dtg_TSMIM] = CFF_get_date_and_TSMIM_from_kmall_header(header); % date and time per datagram
        fData.X8_1P_Date = dtg_date(iFirstDatagram); % date per swath
        fData.X8_1P_TimeSinceMidnightInMilliseconds = dtg_TSMIM(iFirstDatagram); % time per swath
        
        % record data per ping
        fData.X8_1P_PingCounter             = NaN; % unused anyway
        fData.X8_1P_HeadingOfVessel         = NaN; % unused anyway
        fData.X8_1P_SoundSpeedAtTransducer  = NaN; % unused anyway
        fData.X8_1P_TransmitTransducerDepth = NaN; % unused anyway
        fData.X8_1P_NumberOfBeamsInDatagram = NaN; % unused anyway
        fData.X8_1P_NumberOfValidDetections = NaN; % unused anyway
        fData.X8_1P_SamplingFrequencyInHz   = NaN; % unused anyway
        
        % initialize data per beam and ping
        fData.X8_BP_DepthZ                       = nan(maxnBeams,nSwaths);
        fData.X8_BP_AcrosstrackDistanceY         = nan(maxnBeams,nSwaths);
        fData.X8_BP_AlongtrackDistanceX          = NaN; % unused anyway
        fData.X8_BP_DetectionWindowLength        = NaN; % unused anyway
        fData.X8_BP_QualityFactor                = NaN; % unused anyway
        fData.X8_BP_BeamIncidenceAngleAdjustment = NaN; % unused anyway
        fData.X8_BP_DetectionInformation         = NaN; % unused anyway
        fData.X8_BP_RealTimeCleaningInformation  = NaN; % unused anyway
        fData.X8_BP_ReflectivityBS               = nan(maxnBeams,nSwaths);
        fData.X8_B1_BeamNumber                   = (1:maxnBeams)';
        
        % record data per beam and ping
        for iS = 1:nSwaths
            dtg_iS = find(iC==iS); % indices of datagrams for that swath
            nB_tot = 0; % initialize total number of beams recorded so far for that swath
            for iD = 1:numel(dtg_iS)
                SD = sounding(dtg_iS(iD)); % soundings data for that datagram
                nB = dtg_nBeams(dtg_iS(iD)); % number of actual beams in this datagram (ignoring "extra detections")
                iB_dst = nB_tot + (1:nB); % indices of beams in output arrays
                fData.X8_BP_DepthZ(iB_dst,iS)               = SD.z_reRefPoint_m(1:nB);
                fData.X8_BP_AcrosstrackDistanceY(iB_dst,iS) = SD.y_reRefPoint_m(1:nB);
                fData.X8_BP_ReflectivityBS(iB_dst,iS)       = SD.reflectivity1_dB(1:nB);
                nB_tot = nB_tot + nB; % update total number of beams recorded so far for this swath
            end
        end
        
        % debug graph
        debugDisp = 0;
        if debugDisp
            f = figure();
            ax_z = axes(f,'outerposition',[0 0.66 1 0.3]);
            imagesc(ax_z, -fData.X8_BP_DepthZ);
            colorbar(ax_z); grid on; title(ax_z, 'bathy'); colormap(ax_z,'jet');
            ax_y = axes(f,'outerposition',[0 0.33 1 0.3]);
            imagesc(ax_y, fData.X8_BP_AcrosstrackDistanceY);
            colorbar(ax_y); grid on; title(ax_y, 'across-track distance');
            ax_bs = axes(f,'outerposition',[0 0 1 0.3]);
            imagesc(ax_bs, fData.X8_BP_ReflectivityBS);
            caxis(ax_bs, [prctile(fData.X8_BP_ReflectivityBS(:),5), prctile(fData.X8_BP_ReflectivityBS(:),95)]);
            colorbar(ax_bs); grid on; title(ax_bs, 'BS (scaled 5-95th percentile)'); colormap(ax_bs,'gray');
            drawnow;
        end

    end
    
    %% '#MWC - Multibeam (M) water (W) column (C) datagram'
    if isfield(KMALLdata,'EMdgmMWC') && ~isfield(fData,'WC_1D_Date')
        
        comms.step('Converting #MWC'); 
        
        % remove duplicate datagrams
        EMdgmMWC = CFF_remove_duplicate_KMALL_datagrams(KMALLdata.EMdgmMWC);
        
        % extract data
        header = [EMdgmMWC.header];
        cmnPart = [EMdgmMWC.cmnPart];
        rxInfo  = [EMdgmMWC.rxInfo];
        % CFF_get_kmall_TxRx_info(cmnPart) % evaluate to get info for debugging
        
        % number of datagrams
        nDatag = numel(EMdgmMWC);
        
        % number of pings
        dtg_pingCnt = [cmnPart.pingCnt]; % actual ping number for each datagram
        dtg_swathAlongPosition = [cmnPart.swathAlongPosition]; % swath number for a ping
        dtg_swathCnt = dtg_pingCnt + 0.01.*dtg_swathAlongPosition; % "new ping number" for each datagram
        [swath_counter, iFirstDatagram, iC] = unique(dtg_swathCnt,'stable'); % list of swath numbers
        nSwaths = numel(swath_counter); % total number of swaths in file
        
        % number of beams
        dtg_nBeams = [rxInfo.numBeams]; % number of beams per datagram
        nBeams = arrayfun(@(idx) sum(dtg_nBeams(iC==idx)), 1:nSwaths); % total number of beams per swath
        maxnBeams = nanmax(nBeams); % maximum number of "beams per swath" in the file
        maxnBeams_sub = ceil(maxnBeams/db_sub); % maximum number of beams TO READ per swath
        
        % number of samples
        dtg_nSamples = arrayfun(@(idx) [EMdgmMWC(idx).beamData_p(:).numSampleData], 1:nDatag, 'UniformOutput', false); % number of samples per ping per datagram
        [maxnSamples_groups, ping_group_start, ping_group_end] = CFF_group_pings(dtg_nSamples, swath_counter, dtg_swathCnt); % making groups of pings to limit size of memmaped files
        maxnSamples_groups = ceil(maxnSamples_groups/dr_sub); % maximum number of samples TO READ, per group.
        
        % add the WCD decimation factors given here in input
        fData.dr_sub = dr_sub;
        fData.db_sub = db_sub;
        
        % data per ping
        % here taken from first datagram. Ideally, check consistency
        % between datagrams for a given ping
        [dtg_date,dtg_TSMIM] = CFF_get_date_and_TSMIM_from_kmall_header(header); % date and time per datagram
        fData.WC_1P_Date = dtg_date(iFirstDatagram); % date per swath
        fData.WC_1P_TimeSinceMidnightInMilliseconds = dtg_TSMIM(iFirstDatagram); % time per swath
        fData.WC_1P_PingCounter               = swath_counter;
        fData.WC_1P_NumberOfDatagrams         = NaN; % unused anyway
        fData.WC_1P_NumberOfTransmitSectors   = NaN; % unused anyway
        fData.WC_1P_TotalNumberOfReceiveBeams = NaN; % unused anyway
        fData.WC_1P_SoundSpeed                = [rxInfo(iFirstDatagram).soundVelocity_mPerSec];
        fData.WC_1P_SamplingFrequencyHz       = [rxInfo(iFirstDatagram).sampleFreq_Hz];
        fData.WC_1P_TXTimeHeave               = NaN; % unused anyway
        fData.WC_1P_TVGFunctionApplied        = [rxInfo(iFirstDatagram).TVGfunctionApplied];
        fData.WC_1P_TVGOffset                 = [rxInfo(iFirstDatagram).TVGoffset_dB];
        fData.WC_1P_ScanningInfo              = NaN; % unused anyway
        
        % data per transmit sector and ping
        fData.WC_TP_TiltAngle            = NaN; % unused anyway
        fData.WC_TP_CenterFrequency      = NaN; % unused anyway
        fData.WC_TP_TransmitSectorNumber = NaN; % unused anyway
        
        % initialize data per (decimated) beam and ping
        fData.WC_BP_BeamPointingAngle      = nan(maxnBeams_sub,nSwaths);
        fData.WC_BP_StartRangeSampleNumber = nan(maxnBeams_sub,nSwaths);
        fData.WC_BP_NumberOfSamples        = nan(maxnBeams_sub,nSwaths);
        fData.WC_BP_DetectedRangeInSamples = zeros(maxnBeams_sub,nSwaths);
        fData.WC_BP_TransmitSectorNumber   = NaN; % unused anyway
        fData.WC_BP_BeamNumber             = NaN; % unused anyway
        fData.WC_BP_SystemSerialNumber     = NaN; % unused anyway
        
        % The actual water-column data will not be saved in fData but in
        % binary files. Get the output directory to store those files 
        wc_dir = CFF_converted_data_folder(KMALLfilename);
                
        % Clean up that folder first before adding anything to it
        CFF_clean_delete_fdata(wc_dir);
        
        % DEV NOTE: Info format for raw WC data and storage
        % In these raw datagrams, you have both amplitude and phase.
        %
        % Amplitude samples are recorded exactly as in the .all format, 
        % that is in "int8" (signed integers from -128 to 127) with -128
        % being the NaN value. Raw values needs to be multiplied by a 
        % factor of 1/2 to retrieve the true value, aka real values go from
        % -127/2 = -63.5 dB to 127/2 = 63.5 dB in increments of 0.5 dB
        % For storage, we keep the same format in order to save disk space.
        %
        % Phase might or might not be recorded, and depending on the value
        % of the flag may be recorded in 'int8' with a factor of 180./128,
        % or in 'int16' with a factor of 0.01.
        %
        % For storage, we keep the same format in order to save disk space.
        
        % initialize data-holding binary files for Amplitude
        fData = CFF_init_memmapfiles(fData, ...
            'field', 'WC_SBP_SampleAmplitudes', ...
            'wc_dir', wc_dir, ...
            'Class', 'int8', ...
            'Factor', 1./2, ...
            'Nanval', intmin('int8'), ...
            'Offset', 0, ...
            'MaxSamples', maxnSamples_groups, ...
            'MaxBeams', maxnBeams_sub, ...
            'ping_group_start', ping_group_start, ...
            'ping_group_end', ping_group_end);
        
        % was phase recorded
        dtg_phaseFlag = [rxInfo.phaseFlag];
        if all(dtg_phaseFlag==0)
            phaseFlag = 0;
        elseif all(dtg_phaseFlag==1)
            phaseFlag = 1;
        elseif all(dtg_phaseFlag==2)
            phaseFlag = 2;
        else
            % hopefully this error should never occur. Otherwise it's
            % fixable but have to change the code a bit.
            error('phase flag is inconsistent across ping records in this file.')
        end
        
        % record phase data, if available
        if phaseFlag
            
            % two different formats for raw phase, depending on the value
            % of the flag. Keep the same for storage
            if phaseFlag==1
                phaseFormat = 'int8';
                phaseFactor = 180./128;
            else
                phaseFormat = 'int16';
                phaseFactor = 0.01;
            end
            phaseNanValue = intmin(phaseFormat);
            
            % initialize data-holding binary files for Phase
            fData = CFF_init_memmapfiles(fData, ...
                'field', 'WC_SBP_SamplePhase', ...
                'wc_dir', wc_dir, ...
                'Class', phaseFormat, ...
                'Factor', phaseFactor, ...
                'Nanval', phaseNanValue, ...
                'Offset', 0, ...
                'MaxSamples', maxnSamples_groups, ...
                'MaxBeams', maxnBeams_sub, ...
                'ping_group_start', ping_group_start, ...
                'ping_group_end', ping_group_end);
            
        end
        
        % Also the samples data were not recorded, only their location in
        % the source file, so we need to fopen the source file to grab the
        % data.
        fid = fopen(KMALLfilename,'r','l');
        
        % debug graph
        debugDisp = 0;
        if debugDisp
            f = figure();
            if ~phaseFlag
                ax_mag = axes(f,'outerposition',[0 0 1 1]);
                title('WCD amplitude');
            else
                ax_mag = axes(f,'outerposition',[0 0.5 1 0.5]);
                title('WCD amplitude');
                ax_phase = axes(f,'outerposition',[0 0 1 0.5]);
                title('WCD phase');
            end
        end
        
        % initialize ping group number
        iG = 1;
        
        % now get data for each swath...
        for iS = 1:nSwaths
            
            % ping group number is the index of the memmaped file in which
            % that swath's data will be saved.
            if iS > ping_group_end(iG)
                iG = iG+1;
            end
            
            % (re-)initialize amplitude and phase arrays for that swath
            Mag_tmp = intmin('int8').*ones(maxnSamples_groups(iG),maxnBeams_sub,'int8');
            if phaseFlag
                Ph_tmp = phaseNanValue.*ones(maxnSamples_groups(iG),maxnBeams_sub,phaseFormat);
            end
            
            % data for one swath can be spread over several datagrams,
            % typically when using dual Rx systems, so we're going to loop
            % over all datagrams to grab this swath's entire data
            dtg_iS = find(iC==iS); % indices of datagrams for that swath
            nB_tot = 0; % initialize total number of beams recorded so far for that swath
            iB_src_start = 1; % index of first beam to read in a datagram, start with 1 and to be updated later
            
            % in each datagram...
            for iD = 1:numel(dtg_iS)
                
                % beamData_p for this datagram
                BD = EMdgmMWC(dtg_iS(iD)).beamData_p;
                
                % important variables for data to grab
                nRx = numel(BD.beamPointAngReVertical_deg); % total number of beams in this datagram
                iB_src = iB_src_start:db_sub:nRx; % indices of beams to read in this datagram
                nB = numel(iB_src); % number of beams to record from this datagram
                iB_dst = nB_tot + (1:nB); % indices of those beams in output arrays
                
                % data per beam
                fData.WC_BP_BeamPointingAngle(iB_dst,iS)      = BD.beamPointAngReVertical_deg(iB_src);
                fData.WC_BP_StartRangeSampleNumber(iB_dst,iS) = BD.startRangeSampleNum(iB_src);
                fData.WC_BP_NumberOfSamples(iB_dst,iS)        = BD.numSampleData(iB_src);
                fData.WC_BP_DetectedRangeInSamples(iB_dst,iS) = BD.detectedRangeInSamplesHighResolution(iB_src);
                
                % in each beam...
                for iB = 1:nB
                    
                    % data size
                    sR = BD.startRangeSampleNum(iB_src(iB)); % start range sample number
                    nS = BD.numSampleData(iB_src(iB)); % number of samples in this beam
                    nS_sub = ceil(nS/dr_sub); % number of samples we're going to record
                    
                    % get to start of amplitude block
                    dpif = BD.sampleDataPositionInFile(iB_src(iB));
                    fseek(fid,dpif,-1);
                    
                    % amplitude block is nS records of 1 byte each.
                    Mag_tmp(sR+1:sR+nS_sub,iB_dst(iB)) = fread(fid, nS_sub, 'int8=>int8',dr_sub-1); % read with decimation
                    
                    if phaseFlag
                        % go to start of phase block
                        fseek(fid,dpif+nS,-1);
                        
                        if phaseFlag == 1
                            % phase block is nS records of 1 byte each.
                            Ph_tmp(sR+1:sR+nS_sub,iB_dst(iB)) = fread(fid, nS_sub, 'int8=>int8',dr_sub-1); % read with decimation
                        else
                            % phase block is nS records of 2 bytes each.
                            % XXX1 case not tested yet. Find suitable data
                            % files 
                            Ph_tmp(sR+1:sR+nS_sub,iB_dst(iB)) = fread(fid, nS_sub, 'int16=>int16',2*dr_sub-2); % read with decimation
                        end
                    end
                end
                
                % update variables before reading next datagram, if
                % necessary
                nB_tot = nB_tot + nB; % total number of beams recorded so far for this swath
                iB_src_start = iB_src(end) - nRx + db_sub; % index of first beam to read in next datagram
                
            end
            
            % debug graph
            if debugDisp
                % display amplitude
                imagesc(ax_mag,double(Mag_tmp)./2);
                colorbar(ax_mag)
                title(ax_mag, sprintf('Ping %i/%i, WCD amplitude',iS,nSwaths));
                % display phase
                if phaseFlag
                    imagesc(ax_phase,double(Ph_tmp).*phaseFactor);
                    colorbar(ax_phase)
                    title(ax_phase, 'WCD phase');
                end
                drawnow;
            end
            
            % finished reading this swath's WC data. Store the data in the
            % appropriate binary file, at the appropriate ping, through the
            % memory mapping
            fData.WC_SBP_SampleAmplitudes{iG}.Data.val(:,:,iS-ping_group_start(iG)+1) = Mag_tmp;
            if phaseFlag
                fData.WC_SBP_SamplePhase{iG}.Data.val(:,:,iS-ping_group_start(iG)+1) = Ph_tmp;
            end
            
        end
        
        % close the original raw file
        fclose(fid);
        
    end
    
    %% '#SPO - Sensor (S) data for position (PO)'
    if isfield(KMALLdata,'EMdgmSPO') && ~isfield(fData,'Po_1D_Date')
        
        comms.step('Converting #SPO'); 
        
        % extract data
        header     = [KMALLdata.EMdgmSPO.header];
        sensorData = [KMALLdata.EMdgmSPO.sensorData];
        
        % DEV NOTE: There are many entries here but I found a lot of issues
        % in the heading. Digging in the data revealed that many successive
        % entries have same values of timeFromSensor_sec, latitude,
        % longitude, and other values. Yet speed and heading change with
        % every entry... and heading has errors. I suspect those two values
        % are (badly) calculated fromt the lat/long. So now we only record
        % one entry per unique time stamp. Note the time stamp is in
        % seconds so no more than one record per second. The nanosecond
        % field is wrong. Alex 12 july 2021
        
        % get unique time entries from sensorData
        % idx_t = 1:numel(sensorData); % for test to store all
        idx_t = [1, find([0, diff([sensorData.timeFromSensor_sec])]~=0)];
        
        % number of entries to record
        nD = numel(idx_t);
        
        % get date and time-since-midnight-in-milleseconds from header
        [dtg_date,dtg_TSMIM] = CFF_get_date_and_TSMIM_from_kmall_header(header); % date and time per datagram
        fData.Po_1D_Date = dtg_date(idx_t);
        fData.Po_1D_TimeSinceMidnightInMilliseconds = dtg_TSMIM(idx_t);
        
        fData.Po_1D_Latitude                    = [sensorData(idx_t).correctedLat_deg]; % in decimal degrees
        fData.Po_1D_Longitude                   = [sensorData(idx_t).correctedLong_deg]; % in decimal degrees
        fData.Po_1D_SpeedOfVesselOverGround     = [sensorData(idx_t).speedOverGround_mPerSec]; % in m/s
        fData.Po_1D_HeadingOfVessel             = [sensorData(idx_t).courseOverGround_deg]; % in degrees relative to north
        fData.Po_1D_MeasureOfPositionFixQuality = [sensorData(idx_t).posFixQuality_m];
        fData.Po_1D_PositionSystemDescriptor    = zeros(1,nD); % dummy values
        
    end
    
    %% communicate progress
    comms.progress(iF,nStruct);
    
end


%% end message
comms.finish('Done');


%% nested functions

    function out_EM_struct = CFF_remove_duplicate_KMALL_datagrams(in_EM_struct)
        % DEV NOTE: I have found occurences of duplicate MRZ datagrams in some test
        % files. Not sure how common it is, but the conversion code ends up
        % duplicating the data too. Instead of modifying the code everywhere to be
        % always considering the possibility of duplicates, it's easier to look for
        % them at the start and remove them before parsing.
        % In the examples I found, it would be sufficient to check for the set
        % unicity of the cmnPart fields pingCnt, rxFanIndex, and
        % swathAlongPosition. But the range of cases covered by the kmall format
        % can be complicated (including systems with dual Rx heads and dual Tx
        % heads in multi-swath mode!!! see documentation of EMdgmMbody_def) so to
        % be entierely safe, we will instead use ALL the fields of cmnPart in a
        % test for set unicity.
        
        if isfield(in_EM_struct, 'cmnPart')
            
            cmnPart_table = struct2table([in_EM_struct.cmnPart]);
            [~, ia, ~] = unique(cmnPart_table,'rows', 'stable');
            idx_duplicates = ~ismember(1:size(cmnPart_table,1), ia);
            
            % remove duplicates
            out_EM_struct = in_EM_struct(~idx_duplicates);
            
            % info
            if any(idx_duplicates)
                infoStr = sprintf('Found and discarded %i duplicate datagrams',sum(idx_duplicates));
                comms.info(infoStr);
            end
            
        else
            out_EM_struct = in_EM_struct;
        end
        
    end

end


%%
function out_struct = CFF_read_TRAI(ASCIIdata, TRAI_code)

out_struct = struct;

[iS,iE] = regexp(ASCIIdata,[TRAI_code ':.+?,']);

if isempty(iS)
    % no match, exit
    return
end

TRAI_TX1_ASCII = ASCIIdata(iS+9:iE-1);

yo(:,1) = [1; strfind(TRAI_TX1_ASCII,';')'+1]; % beginning of ASCII field name
yo(:,2) = strfind(TRAI_TX1_ASCII,'=')'-1; % end of ASCII field name
yo(:,3) = strfind(TRAI_TX1_ASCII,'=')'+1; % beginning of ASCII field value
yo(:,4) = [strfind(TRAI_TX1_ASCII,';')'-1;length(TRAI_TX1_ASCII)]; % end of ASCII field value

for ii = 1:size(yo,1)
    
    % get field string
    field = TRAI_TX1_ASCII(yo(ii,1):yo(ii,2));
    
    % try turn value into numeric
    value = str2double(TRAI_TX1_ASCII(yo(ii,3):yo(ii,4)));
    if length(value)~=1
        % looks like it cant. Keep as string
        value = TRAI_TX1_ASCII(yo(ii,3):yo(ii,4));
    end
    
    % store field/value
    out_struct.(field) = value;
    
end

end


%%
function [KM_date, TSMIM] = CFF_get_date_and_TSMIM_from_kmall_header(header)

% get values
time_sec = [header.time_sec];
time_nanosec = [header.time_nanosec];

% convert raw to datetime
dt = datetime(time_sec + time_nanosec.*10^-9,'ConvertFrom','posixtime');

% convert datetime to date and TSMIM
KM_date = convertTo(dt, 'yyyymmdd');
TSMIM = milliseconds(timeofday(dt));

end

%%
function str = CFF_get_kmall_TxRx_info(cmnPart)

% Single or Dual Tx
iTx = unique([cmnPart.txTransducerInd]);
if numel(iTx)==1 && iTx==0
    str = 'Single Tx, ';
elseif numel(iTx)==2 && all(iTx==[0,1])
    str = 'Dual Tx, ';
else
    str = '??? Tx, ';
end

% Single or Dual Rx
iRx = unique([cmnPart.numRxTransducers]);
iRx2 = unique([cmnPart.rxTransducerInd]);
if numel(iRx)==1 && iRx==1
    % should be single
    if numel(iRx2)==1 && iRx2==0
        % confirmed
        str = [str, 'Single Rx, '];
    else
        % unconfirmed
        str = [str, '??? Rx, '];
    end
elseif numel(iRx)==1 && iRx==2
    % should be dual
    if numel(iRx2)==2 && all(iRx2==[0,1])
        % confirmed
        str = [str, 'Dual Rx, '];
    else
        % unconfirmed
        str = [str, '??? Rx, '];
    end
else
    str = [str, '??? Rx, '];
end

% Single or Multi Swath
iSw = unique([cmnPart.swathsPerPing]);
iSw2 = unique([cmnPart.swathAlongPosition]);
if numel(iSw)==1 && iSw==1
    % should be single
    if numel(iSw2)==1 && iSw2==0
        % confirmed
        str = [str, 'Single Swath.'];
    else
        % unconfirmed
        str = [str, '??? Swath.'];
    end
elseif numel(iSw)==1 && iSw==2
    % should be dual
    if numel(iSw2)==2 && all(iSw2==[0,1])
        % confirmed
        str = [str, 'Dual Swath.'];
    else
        % unconfirmed
        str = [str, '??? Swath.'];
    end
elseif numel(iSw)==1 && iSw>2
    % should be multi (more than 2)
    if numel(iSw2)==iSw && all(iSw2==[0:iSw-1])
        % confirmed
        str = [str, sprintf('Multi Swath (%i).',iSw)];
    else
        % unconfirmed
        str = [str, '??? Swath.'];
    end
else
    str = [str, '??? Swath.'];
end

end