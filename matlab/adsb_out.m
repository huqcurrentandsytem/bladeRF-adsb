%% TX Side
% Change
adsb.type = 'ext' ;
adsb.df = 17 ;
adsb.ca = 5 ;
adsb.address = '75804b';

% Only used in extended
adsb.message1.hex = '580FF2CF7E9BA6' ;
adsb.message2.hex = '580FF6B283EB7A' ;
adsb.message1.bin = [
    int32(dec2bin(hex2dec(adsb.message1.hex(1:7)),28))-'0' ...
    int32(dec2bin(hex2dec(adsb.message1.hex(8:end)),28))-'0'
] ;
adsb.message2.bin = [
    int32(dec2bin(hex2dec(adsb.message2.hex(1:7)),28))-'0' ...
    int32(dec2bin(hex2dec(adsb.message2.hex(8:end)),28))-'0'
] ;

% Don't change
adsb.ppm.zero = [ 0 1 ] ;
adsb.ppm.one = [ 1 0 ] ;
adsb.preamble = [ 1 0 1 0 0 0 0 1 0 1 0 0 0 0 0 0 ] ;
adsb.df = int32(dec2bin(adsb.df,5))-'0';
adsb.ca = int32(dec2bin(adsb.ca,3))-'0';
adsb.address = int32(dec2bin(hex2dec(adsb.address),24))-'0';

% Short message
adsb.payload = [ adsb.df adsb.ca adsb.address ] ;

% Extended
if strcmp(adsb.type,'ext') == true
    adsb.payload = [ adsb.payload adsb.message1.bin ] ;
end

% Find parity and append it to payload
% CRC24 = 24 23 22 21 20 19 18 17 16 15 14 13 10 3 1
adsb.crc24 = comm.CRCGenerator([1 1 1 1 1 1 1 1 1 1 1 1 1 0 1 0 0 0 0 0 0 1 0 0 1]) ;
adsb.payload = step(adsb.crc24, logical(adsb.payload)' )';

% Encode to be PPM
for x=0:length(adsb.payload)-1
    if adsb.payload(x+1) == 0
        adsb.encoded(2*x+1:2*x+2) = adsb.ppm.zero ;
    else
        adsb.encoded(2*x+1:2*x+2) = adsb.ppm.one ;
    end
end

% Add preamble
adsb.tx = [ adsb.preamble adsb.encoded ] ;

% Upsample
SPS = 8 ;
adsb.tx8sps = filter(ones(1,SPS), 1, upsample(adsb.tx,SPS)) ;

% Make average power ~1.0
adsb.tx8sps = adsb.tx8sps + adsb.tx8sps*1j ;

% Add in some dead air on both sides of the message
adsb.tx8sps = [ zeros(1,1000) adsb.tx8sps zeros(1,1000) ] ;

% TX spectrum limiting
h = firpm( 90, [0 1.3/SPS 2.0/SPS 1], [1 1 0 0] ) ;
adsb.tx8spsfilt = conv(adsb.tx8sps, h) ;

% Send 1000 messages
NUM_MSGS = 1000 ;
adsb.tx8spsfilt = repmat(adsb.tx8spsfilt, 1, NUM_MSGS) ;
adsb.tx8norm = adsb.tx8spsfilt./max(abs(adsb.tx8spsfilt)) ;

%% Channel
%SNR = 15 ;
%SNR = SNR - (3*SPS/2) ;
%gain.signal = 1.0 ;
%gain.noise = 10^(-SNR/20) ;

len = length(adsb.tx8spsfilt) ;
%adsb.noise = (randn(1,len)/sqrt(2) + randn(1,len)*1j/sqrt(2)).*gain.noise ;

%adsb.channel = (adsb.tx8spsfilt + adsb.noise)./(gain.signal+sqrt(2)*gain.noise) ;

%% RX Side
% Bandwidth filter - no decimation
%adsb.rx8spsfilt = conv(adsb.channel, h) ;

% Decimate to 2MHz for dump1090
%adsb.rx1090 = adsb.rx8spsfilt(1:8:end) ;

%% ADC Noise
% For a -85dBm signal coming into a bladeRF with 14MHz bandwidth, connected
% to the ADSB antenna, the average noise floor is around -48dBFS.  A tone
% coming into the board at -85dBm deflects to around -20dBFS.  If we want
% to decode things coming in at -88dBFS, then we need to set the threshold
% for tripping to be at -23dBFS.  This should be ~25dB 

% This is going to setup the ADC to look like what we want with an average
% noise floor and a slight DC offset
adc.dc = 0 + 0*1j ;
adc.namp = 2048*10^(-16.5/20) ;
adc.nvec = (randn(1, len) + randn(1, len)*1j)./sqrt(2) ;
adc.noise = adc.nvec * adc.namp ;

%% ADC Signal
adc.sin_dBFS = 12 ;
adc.samp = 2048/(2^(-adc.sin_dBFS/6.02)) ;

% Calibration - tone was coming in at -19dBFS with noise at -48dBFS using
% an FFT of length 512
%adc.sig = adc.noise + ones(1, 512).*adc.samp ;

% Add in the signal and noise for a low SNR signal
adc.sig = ...
    adc.noise + ...
    adc.dc + ...
    adc.samp .* adsb.tx8norm .* exp((1:length(adsb.tx8norm))*1j*2*pi*1/4) ;

% Clamp signal
for x=1:length(adc.sig)
   if( real(adc.sig(x)) > 2047 )
       adc.sig(x) = 2047 + 1j*imag(adc.sig(x)) ;
   elseif( real(adc.sig(x)) < -2047 )
       adc.sig(x) = -2047 + 1j*imag(adc.sig(x)) ;
   end
   
   if( imag(adc.sig(x)) > 2047 )
       adc.sig(x) = real(adc.sig(x)) + 2047*1j ;
   elseif( imag(adc.sig(x)) < -2047 )
       adc.sig(x) = real(adc.sig(x)) - 1j*2047 ;
   end
end

%% Receiver
THRESHOLD = 175 ;

% Mix to baseband
rx.bb = adc.sig .* exp((1:length(adc.sig))*1j*2*pi*-1/4) ;

% Filter
rx.bbfilt = conv(rx.bb, h) ;

% Absolute value
rx.absbb = abs(rx.bbfilt) ;

% Leading edge detection
rx.leading = zeros(1, length(rx.absbb)) ;
for x=2:length(rx.absbb)-5
    if( sum(rx.absbb(x:x+4) > THRESHOLD) == 5 )
        if( 20*log10(rx.absbb(x)/rx.absbb(x-1)) > 2.4 && ...
            20*log10(rx.absbb(x)/rx.absbb(x+1)) < 2.4 )
            rx.leading(x) = 1 ;
        end
    end
end

% Falling edge detection
rx.falling = zeros(1, length(rx.absbb)) ;
for x=5:length(rx.absbb)-1
    if( sum(rx.absbb(x-4:x) > THRESHOLD) == 5 )
        if( 20*log10(rx.absbb(x-1)/rx.absbb(x)) > 2.4 && ...
            20*log10(rx.absbb(x+1)/rx.absbb(x)) < 2.4 )
            rx.falling(x) = 1 ;
        end
    end
end

% Preamble detection
rx.preamble = zeros(1, length(rx.absbb)) ;
for x=1:length(rx.absbb)-100
    if( rx.absbb(x) > THRESHOLD && ...
        sum(rx.absbb(x:x+4) > THRESHOLD) == 5 && ...
        sum(rx.absbb(x+2*SPS:x+2*SPS+4) > THRESHOLD) == 5 && ...
        sum(rx.absbb(x+7*SPS:x+7*SPS+4) > THRESHOLD) == 5 && ...
        sum(rx.absbb(x+9*SPS:x+9*SPS+4) > THRESHOLD) == 5 && ...
        rx.leading(x) + rx.leading(x+2*SPS) + rx.leading(x+7*SPS) + rx.leading(9*SPS) > 1 )
        rx.preamble(x) = 1 ;
    end
end

% Reference power level
rx.rpl = zeros(1, length(rx.absbb)) ;
for x=1:length(rx.absbb)-100
    if( rx.preamble(x) == 1 )
        rx.rpl(x) = max(rx.absbb(x:x+4)) + ...
                    max(rx.absbb(x+2*SPS:x+2*SPS+4)) + ...
                    max(rx.absbb(x+7*SPS:x+7*SPS+4)) + ...
                    max(rx.absbb(x+9*SPS:x+9*SPS+4)) ;
    end
end
rx.rpl = rx.rpl ./ 4 ;

% Consistent power test
rx.cpl = rx.preamble ;
rx.means = zeros(4, length(rx.preamble)) ;
rx.lows = zeros(1, length(rx.preamble)) ;
rx.highs = zeros(1, length(rx.preamble)) ;
for x=1:length(rx.preamble)
    if( rx.cpl(x) == 1 )
        m = zeros(1, 4) ;
        m(1) = mean(rx.absbb(x:x+4)) ;
        m(2) = mean(rx.absbb(x+2*SPS:x+2*SPS+4)) ;
        m(3) = mean(rx.absbb(x+7*SPS:x+7*SPS+4)) ;
        m(4) = mean(rx.absbb(x+9*SPS:x+9*SPS+4)) ;
        rx.means(1:4,x) = m ;
        count = 0 ;
        low = rx.rpl(x)*0.7071 ;
        high = rx.rpl(x)*1.4142 ;
        rx.lows(1,x) = low ;
        rx.highs(1,x) = high ;
        for n=1:4
            if( (m(n) > low) && (high > m(n)) )
                count = count + 1 ;
            end
        end
        if( count < 2 )
            rx.cpl(x) = 0 ;
        end
    end
end

% DF Validation
rx.df = rx.cpl ;
for x=1:length(rx.cpl)
    % Make sure there are appropriate bits in the DF field bits, one high
    % and one low per bit
    % TODO
end

% Message Decoding
skipcount = 0 ;
rx.decoded = rx.df ;
for x=1:length(rx.decoded)-1
    % Skip over bits we've already decoded
    if( skipcount > 0 )
        skipcount = skipcount - 1 ;
        rx.decoded(x) = 0 ;
        continue ;
    end
    
    if( rx.decoded(x) == 1 )
        % Re-Triggering
        % We are pretty sure we've hit a preamble,
        % so check the future and see if there is another
        % preamble right after this one which may be better
        if( rx.decoded(x+1) == 1 )
            if( rx.rpl(x+1) > rx.rpl(x)*1.414 )
                % Next preamble we want to actually decode
                % because it's better!
                rx.decoded(x) = 0 ;
                continue ;
            end
        end
        
        % Skip the rest of the message
        skipcount = 240*SPS ;
        
        % Perform bit confidence detection on the signal
        % TODO
        
        % Decode the signal
        % TODO
        
        % If it doesn't pass CRC, then brute-force the 5 weakest bits
        % TODO
        
        % Still couldn't decode+pass CRC, then lost message 
        % TODO
    end
end
