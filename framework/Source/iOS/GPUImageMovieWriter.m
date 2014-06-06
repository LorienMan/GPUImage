#import "GPUImageMovieWriter.h"

#import "GPUImageContext.h"
#import "GLProgram.h"
#import "GPUImageFilter.h"

NSString *const kGPUImageColorSwizzlingFragmentShaderString = SHADER_STRING
(
 varying highp vec2 textureCoordinate;

 uniform sampler2D inputImageTexture;

 void main()
 {
     gl_FragColor = texture2D(inputImageTexture, textureCoordinate).bgra;
 }
);


@interface GPUImageMovieWriter ()
{
    GLuint movieFramebuffer, movieRenderbuffer;

    GLProgram *colorSwizzlingProgram;
    GLint colorSwizzlingPositionAttribute, colorSwizzlingTextureCoordinateAttribute;
    GLint colorSwizzlingInputTextureUniform;

    GLuint inputTextureForMovieRendering;

    CMTime startTime, previousFrameTime, previousAudioTime;
    CMTime pausingTimeDiff, previousTimeWhilePausing;

    dispatch_queue_t audioQueue, videoQueue;
    BOOL audioEncodingIsFinished, videoEncodingIsFinished;

    BOOL isRecording;
}

// Movie recording
- (void)initializeMovieWithOutputSettings:(NSMutableDictionary *)outputSettings;

// Frame rendering
- (void)createDataFBO;
- (void)destroyDataFBO;
- (void)setFilterFBO;

- (void)renderAtInternalSize;

@end

@implementation GPUImageMovieWriter {
    UIImage *_imageToProcessAtNextAudioBuffer;
    CVPixelBufferRef _bufferToProcessAtNextAudioBuffer;
    NSUInteger _imageToProcessAtNextAudioBufferFramePerFrame;
}

@synthesize hasAudioTrack = _hasAudioTrack;
@synthesize encodingLiveVideo = _encodingLiveVideo;
@synthesize shouldPassthroughAudio = _shouldPassthroughAudio;
@synthesize completionBlock;
@synthesize failureBlock;
@synthesize videoInputReadyCallback;
@synthesize audioInputReadyCallback;
@synthesize enabled;
@synthesize shouldInvalidateAudioSampleWhenDone = _shouldInvalidateAudioSampleWhenDone;
@synthesize paused = _paused;

@synthesize delegate = _delegate;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithMovieURL:(NSURL *)newMovieURL size:(CGSize)newSize;
{
    return [self initWithMovieURL:newMovieURL size:newSize fileType:AVFileTypeQuickTimeMovie outputSettings:nil];
}

- (id)initWithMovieURL:(NSURL *)newMovieURL size:(CGSize)newSize fileType:(NSString *)newFileType outputSettings:(NSMutableDictionary *)outputSettings;
{
    if (!(self = [super init]))
    {
		return nil;
    }

    _shouldInvalidateAudioSampleWhenDone = NO;

    self.enabled = YES;
    alreadyFinishedRecording = NO;
    videoEncodingIsFinished = NO;
    audioEncodingIsFinished = NO;

    movieWritingQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.movieWritingQueue", NULL);

    videoSize = newSize;
    movieURL = newMovieURL;
    fileType = newFileType;
    startTime = kCMTimeInvalid;
    _encodingLiveVideo = [[outputSettings objectForKey:@"EncodingLiveVideo"] isKindOfClass:[NSNumber class]] ? [[outputSettings objectForKey:@"EncodingLiveVideo"] boolValue] : YES;
    previousFrameTime = kCMTimeNegativeInfinity;
    previousAudioTime = kCMTimeNegativeInfinity;
    inputRotation = kGPUImageNoRotation;

    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];

        if ([GPUImageContext supportsFastTextureUpload])
        {
            colorSwizzlingProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImagePassthroughFragmentShaderString];
        }
        else
        {
            colorSwizzlingProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageColorSwizzlingFragmentShaderString];
        }

        if (!colorSwizzlingProgram.initialized)
        {
            [colorSwizzlingProgram addAttribute:@"position"];
            [colorSwizzlingProgram addAttribute:@"inputTextureCoordinate"];

            if (![colorSwizzlingProgram link])
            {
                NSString *progLog = [colorSwizzlingProgram programLog];
                NSLog(@"Program link log: %@", progLog);
                NSString *fragLog = [colorSwizzlingProgram fragmentShaderLog];
                NSLog(@"Fragment shader compile log: %@", fragLog);
                NSString *vertLog = [colorSwizzlingProgram vertexShaderLog];
                NSLog(@"Vertex shader compile log: %@", vertLog);
                colorSwizzlingProgram = nil;
                NSAssert(NO, @"Filter shader link failed");
            }
        }

        colorSwizzlingPositionAttribute = [colorSwizzlingProgram attributeIndex:@"position"];
        colorSwizzlingTextureCoordinateAttribute = [colorSwizzlingProgram attributeIndex:@"inputTextureCoordinate"];
        colorSwizzlingInputTextureUniform = [colorSwizzlingProgram uniformIndex:@"inputImageTexture"];

        // REFACTOR: Wrap this in a block for the image processing queue
        [GPUImageContext setActiveShaderProgram:colorSwizzlingProgram];

        glEnableVertexAttribArray(colorSwizzlingPositionAttribute);
        glEnableVertexAttribArray(colorSwizzlingTextureCoordinateAttribute);
    });

    [self initializeMovieWithOutputSettings:outputSettings];

    return self;
}

- (void)dealloc;
{
    [self destroyDataFBO];

    [self clearBufferAtNextAudioBuffer];

#if ( (__IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_6_0) || (!defined(__IPHONE_6_0)) )
    if (movieWritingQueue != NULL)
    {
        dispatch_release(movieWritingQueue);
    }
    if( audioQueue != NULL )
    {
        dispatch_release(audioQueue);
    }
    if( videoQueue != NULL )
    {
        dispatch_release(videoQueue);
    }
#endif
}

#pragma mark -
#pragma mark Movie recording

- (void)initializeMovieWithOutputSettings:(NSDictionary *)outputSettings;
{
    isRecording = NO;
    _paused = NO;

    self.enabled = YES;
    NSError *error = nil;
    assetWriter = [[AVAssetWriter alloc] initWithURL:movieURL fileType:fileType error:&error];
    if (error != nil)
    {
        NSLog(@"Error: %@", error);
        if (failureBlock)
        {
            failureBlock(error);
        }
        else
        {
            if(self.delegate && [self.delegate respondsToSelector:@selector(movieRecordingFailedWithError:)])
            {
                [self.delegate movieRecordingFailedWithError:error];
            }
        }
    }

    // Set this to make sure that a functional movie is produced, even if the recording is cut off mid-stream. Only the last second should be lost in that case.
    assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(1.0, 1000);

    // use default output settings if none specified
    if (outputSettings == nil)
    {
        NSMutableDictionary *settings = [[NSMutableDictionary alloc] init];
        [settings setObject:AVVideoCodecH264 forKey:AVVideoCodecKey];
        [settings setObject:[NSNumber numberWithInt:videoSize.width] forKey:AVVideoWidthKey];
        [settings setObject:[NSNumber numberWithInt:videoSize.height] forKey:AVVideoHeightKey];
        outputSettings = settings;
    }
    // custom output settings specified
    else
    {
		NSString *videoCodec = [outputSettings objectForKey:AVVideoCodecKey];
		NSNumber *width = [outputSettings objectForKey:AVVideoWidthKey];
		NSNumber *height = [outputSettings objectForKey:AVVideoHeightKey];

		NSAssert(videoCodec && width && height, @"OutputSettings is missing required parameters.");

        if( [outputSettings objectForKey:@"EncodingLiveVideo"] ) {
            NSMutableDictionary *tmp = [outputSettings mutableCopy];
            [tmp removeObjectForKey:@"EncodingLiveVideo"];
            outputSettings = tmp;
        }
    }


//    NSDictionary *videoCleanApertureSettings = [NSDictionary dictionaryWithObjectsAndKeys:
//                                                [NSNumber numberWithInt:videoSize.width], AVVideoCleanApertureWidthKey,
//                                                [NSNumber numberWithInt:videoSize.height], AVVideoCleanApertureHeightKey,
//                                                [NSNumber numberWithInt:0], AVVideoCleanApertureHorizontalOffsetKey,
//                                                [NSNumber numberWithInt:0], AVVideoCleanApertureVerticalOffsetKey,
//                                                nil];
//
//    NSDictionary *videoAspectRatioSettings = [NSDictionary dictionaryWithObjectsAndKeys:
//                                              [NSNumber numberWithInt:3], AVVideoPixelAspectRatioHorizontalSpacingKey,
//                                              [NSNumber numberWithInt:3], AVVideoPixelAspectRatioVerticalSpacingKey,
//                                              nil];
//
//    NSMutableDictionary * compressionProperties = [[NSMutableDictionary alloc] init];
//    [compressionProperties setObject:videoCleanApertureSettings forKey:AVVideoCleanApertureKey];
//    [compressionProperties setObject:videoAspectRatioSettings forKey:AVVideoPixelAspectRatioKey];
//    [compressionProperties setObject:[NSNumber numberWithInt: 750000] forKey:AVVideoAverageBitRateKey];
//    [compressionProperties setObject:[NSNumber numberWithInt: 16] forKey:AVVideoMaxKeyFrameIntervalKey];
//    [compressionProperties setObject:AVVideoProfileLevelH264Main31 forKey:AVVideoProfileLevelKey];
//
//    NSMutableDictionary *mOutputSettings = [outputSettings mutableCopy];
//    [mOutputSettings setObject:compressionProperties forKey:AVVideoCompressionPropertiesKey];
//    [mOutputSettings setObject:AVVideoCodecH264 forKey:AVVideoCodecKey];
//    [mOutputSettings setObject:[NSNumber numberWithInt:videoSize.width] forKey:AVVideoWidthKey];
//    [mOutputSettings setObject:[NSNumber numberWithInt:videoSize.height] forKey:AVVideoHeightKey];
//    [mOutputSettings setObject:@YES forKey:@"EncodingLiveVideo"];
//    outputSettings = [mOutputSettings copy];

    assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
    assetWriterVideoInput.expectsMediaDataInRealTime = _encodingLiveVideo;

    // You need to use BGRA for the video in order to get realtime encoding. I use a color-swizzling shader to line up glReadPixels' normal RGBA output with the movie input's BGRA.
    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                                           [NSNumber numberWithInt:videoSize.width], kCVPixelBufferWidthKey,
                                                           [NSNumber numberWithInt:videoSize.height], kCVPixelBufferHeightKey,
                                                           nil];
//    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt:kCVPixelFormatType_32ARGB], kCVPixelBufferPixelFormatTypeKey,
//                                                           nil];

    assetWriterPixelBufferInput = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:assetWriterVideoInput sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];

    [assetWriter addInput:assetWriterVideoInput];
}

- (void)startRecording;
{
    alreadyFinishedRecording = NO;
    isRecording = YES;
    _paused = NO;
    startTime = kCMTimeInvalid;
    dispatch_sync(movieWritingQueue, ^{
        if (audioInputReadyCallback == NULL)
        {
            [assetWriter startWriting];
        }
    });
	//    [assetWriter startSessionAtSourceTime:kCMTimeZero];
}

- (void)startRecordingInOrientation:(CGAffineTransform)orientationTransform;
{
	assetWriterVideoInput.transform = orientationTransform;

	[self startRecording];
}

- (void)cancelRecording;
{
    if (assetWriter.status == AVAssetWriterStatusCompleted)
    {
        return;
    }

    isRecording = NO;
    _paused = NO;
    dispatch_sync(movieWritingQueue, ^{
        alreadyFinishedRecording = YES;

        if( assetWriter.status == AVAssetWriterStatusWriting && ! videoEncodingIsFinished )
        {
            videoEncodingIsFinished = YES;
            [assetWriterVideoInput markAsFinished];
        }
        if( assetWriter.status == AVAssetWriterStatusWriting && ! audioEncodingIsFinished )
        {
            audioEncodingIsFinished = YES;
            [assetWriterAudioInput markAsFinished];
        }
        [assetWriter cancelWriting];
    });
}

- (void)finishRecording;
{
    [self finishRecordingWithCompletionHandler:NULL];
}

- (void)finishRecordingWithCompletionHandler:(void (^)(void))handler;
{
    runSynchronouslyOnVideoProcessingQueue(^{

        dispatch_sync(movieWritingQueue, ^{
            isRecording = NO;

            if (assetWriter.status == AVAssetWriterStatusCompleted || assetWriter.status == AVAssetWriterStatusCancelled || assetWriter.status == AVAssetWriterStatusUnknown)
            {
                if (handler)
                    runAsynchronouslyOnVideoProcessingQueue(handler);
                return;
            }
            if( assetWriter.status == AVAssetWriterStatusWriting && ! videoEncodingIsFinished )
            {
                videoEncodingIsFinished = YES;
                [assetWriterVideoInput markAsFinished];
            }
            if( assetWriter.status == AVAssetWriterStatusWriting && ! audioEncodingIsFinished )
            {
                audioEncodingIsFinished = YES;
                [assetWriterAudioInput markAsFinished];
            }
            isRecording = NO;
            _paused = NO;
            [assetWriter endSessionAtSourceTime:previousFrameTime];
#if (!defined(__IPHONE_6_0) || (__IPHONE_OS_VERSION_MAX_ALLOWED < __IPHONE_6_0))
            // Not iOS 6 SDK
            [assetWriter finishWriting];
            if (handler)
                runAsynchronouslyOnVideoProcessingQueue(handler);
#else
            // iOS 6 SDK
            if ([assetWriter respondsToSelector:@selector(finishWritingWithCompletionHandler:)]) {
                // Running iOS 6
                [assetWriter finishWritingWithCompletionHandler:(handler ?: ^{ })];
            }
            else {
                // Not running iOS 6
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [assetWriter finishWriting];
#pragma clang diagnostic pop
                if (handler)
                    runAsynchronouslyOnVideoProcessingQueue(handler);
            }
#endif
        });
    });
}

- (void)processAudioBuffer:(CMSampleBufferRef)audioBuffer;
{
    if (!isRecording)
    {
        return;
    }

    if (CMTIME_IS_INVALID(startTime) && !_imageToProcessAtNextAudioBuffer)
    {
        // Do not start without video frame
        return;
    }

    if (_hasAudioTrack)
    {
        CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(audioBuffer);

        if (_paused)
        {
            if (CMTIME_IS_INVALID(previousTimeWhilePausing))
            {
                if (CMTIME_IS_INVALID(pausingTimeDiff))
                {
                    pausingTimeDiff = kCMTimeZero;
                }

                previousTimeWhilePausing = currentSampleTime;
            }

            pausingTimeDiff = CMTimeAdd(pausingTimeDiff, CMTimeSubtract(currentSampleTime, previousTimeWhilePausing));
            previousTimeWhilePausing = currentSampleTime;
            return;
        }
        else
        {
            if (CMTIME_IS_VALID(previousTimeWhilePausing))
            {
                previousTimeWhilePausing = kCMTimeInvalid;
            }
            if (CMTIME_IS_VALID(pausingTimeDiff))
            {
                currentSampleTime = CMTimeSubtract(currentSampleTime, pausingTimeDiff);
            }
        }

        if (CMTIME_IS_VALID(pausingTimeDiff))
        {
            audioBuffer = [self adjustTime:audioBuffer by:pausingTimeDiff];
        }
        CFRetain(audioBuffer);

        if (CMTIME_IS_INVALID(startTime))
        {
            dispatch_sync(movieWritingQueue, ^{
                if ((audioInputReadyCallback == NULL) && (assetWriter.status != AVAssetWriterStatusWriting))
                {
                    [assetWriter startWriting];
                }
                [assetWriter startSessionAtSourceTime:currentSampleTime];
                startTime = currentSampleTime;
            });
        }

        if (!assetWriterAudioInput.readyForMoreMediaData && _encodingLiveVideo)
        {
            NSLog(@"1: Had to drop an audio frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
            if (_shouldInvalidateAudioSampleWhenDone)
            {
                CMSampleBufferInvalidate(audioBuffer);
            }
            CFRelease(audioBuffer);
            return;
        }

        previousAudioTime = currentSampleTime;

//        NSLog(@"Recorded audio sample time: %lld, %d, %lld", currentSampleTime.value, currentSampleTime.timescale, currentSampleTime.epoch);
        void(^write)() = ^() {
            while( ! assetWriterAudioInput.readyForMoreMediaData && ! _encodingLiveVideo && ! audioEncodingIsFinished ) {
                NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
                //NSLog(@"audio waiting...");
                [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
            }
            if (!assetWriterAudioInput.readyForMoreMediaData)
            {
                NSLog(@"2: Had to drop an audio frame %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
            }
            else if( ! [assetWriterAudioInput appendSampleBuffer:audioBuffer] )
            {
                NSLog(@"Problem appending audio buffer at time: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
                NSLog(@"assetWriter.status = %li", (long) assetWriter.status);
                NSLog(@"assetWriter.error = %@", assetWriter.error);
                isRecording = NO;
                _paused = NO;
            }
            else
            {
//                NSLog(@"Wrote an audio frame %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
                [self performProcessImageAtNextAudioBuffer:currentSampleTime];
            }

            if (_shouldInvalidateAudioSampleWhenDone)
            {
                CMSampleBufferInvalidate(audioBuffer);
            }
            CFRelease(audioBuffer);
        };
        if( _encodingLiveVideo )
            dispatch_async(movieWritingQueue, write);
        else
            write();
    }
}

- (CMSampleBufferRef) adjustTime:(CMSampleBufferRef) sample by:(CMTime) offset
{
    CMItemCount count;
    CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
    CMSampleTimingInfo* pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
    CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
    for (CMItemCount i = 0; i < count; i++)
    {
        pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
        pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
    }
    CMSampleBufferRef sout;
    CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
    free(pInfo);
    return sout;
}

- (void)enableSynchronizationCallbacks;
{
    if (videoInputReadyCallback != NULL)
    {
        if( assetWriter.status != AVAssetWriterStatusWriting )
        {
            [assetWriter startWriting];
        }
        videoQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.videoReadingQueue", NULL);
        [assetWriterVideoInput requestMediaDataWhenReadyOnQueue:videoQueue usingBlock:^{
            if( _paused )
            {
                //NSLog(@"video requestMediaDataWhenReadyOnQueue paused");
                // if we don't sleep, we'll get called back almost immediately, chewing up CPU
                usleep(10000);
                return;
            }
            //NSLog(@"video requestMediaDataWhenReadyOnQueue begin");
            while( assetWriterVideoInput.readyForMoreMediaData && ! _paused )
            {
                if( ! videoInputReadyCallback() && ! videoEncodingIsFinished )
                {
                    dispatch_async(movieWritingQueue, ^{
                        if( assetWriter.status == AVAssetWriterStatusWriting && ! videoEncodingIsFinished )
                        {
                            videoEncodingIsFinished = YES;
                            [assetWriterVideoInput markAsFinished];
                        }
                    });
                }
            }
            //NSLog(@"video requestMediaDataWhenReadyOnQueue end");
        }];
    }

    if (audioInputReadyCallback != NULL)
    {
        audioQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.audioReadingQueue", NULL);
        [assetWriterAudioInput requestMediaDataWhenReadyOnQueue:audioQueue usingBlock:^{
            if( _paused )
            {
                //NSLog(@"audio requestMediaDataWhenReadyOnQueue paused");
                // if we don't sleep, we'll get called back almost immediately, chewing up CPU
                usleep(10000);
                return;
            }
            //NSLog(@"audio requestMediaDataWhenReadyOnQueue begin");
            while( assetWriterAudioInput.readyForMoreMediaData && ! _paused )
            {
                if( ! audioInputReadyCallback() && ! audioEncodingIsFinished )
                {
                    dispatch_async(movieWritingQueue, ^{
                        if( assetWriter.status == AVAssetWriterStatusWriting && ! audioEncodingIsFinished )
                        {
                            audioEncodingIsFinished = YES;
                            [assetWriterAudioInput markAsFinished];
                        }
                    });
                }
            }
            //NSLog(@"audio requestMediaDataWhenReadyOnQueue end");
        }];
    }

}

- (void)processImageAtNextAudioBuffer:(UIImage *)image {
    dispatch_sync(movieWritingQueue, ^{
        _imageToProcessAtNextAudioBufferFramePerFrame = 0;
        _imageToProcessAtNextAudioBuffer = image;

        [self clearBufferAtNextAudioBuffer];
    });
}

- (void)clearBufferAtNextAudioBuffer {
    if (_bufferToProcessAtNextAudioBuffer) {
        CVPixelBufferRelease(_bufferToProcessAtNextAudioBuffer);
        _bufferToProcessAtNextAudioBuffer = nil;
    }
}

- (UIImage *)processingImageAtNextAudioBuffer {
    return _imageToProcessAtNextAudioBuffer;
}

- (void)performProcessImageAtNextAudioBuffer:(CMTime)frameTime {
    if (!isRecording) {
        return;
    }

    if (_imageToProcessAtNextAudioBufferFramePerFrame) {
        // Each 10th frame
        _imageToProcessAtNextAudioBufferFramePerFrame = (_imageToProcessAtNextAudioBufferFramePerFrame + 1) % 10;
        return;
    }

    _imageToProcessAtNextAudioBufferFramePerFrame++;
    
    UIImage *imageToProcessAtNextAudioBuffer = _imageToProcessAtNextAudioBuffer;
    if (!imageToProcessAtNextAudioBuffer) {
        return;
    }
    // Drop frames forced by images and other things with no time constants
    // Also, if two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
    if ( (CMTIME_IS_INVALID(frameTime)) || (CMTIME_COMPARE_INLINE(frameTime, <=, previousFrameTime)) || (CMTIME_IS_INDEFINITE(frameTime)) )
    {
        return;
    }

    if (!_bufferToProcessAtNextAudioBuffer) {
        _bufferToProcessAtNextAudioBuffer = [self pixelBufferFromCGImage:[imageToProcessAtNextAudioBuffer CGImage] andSize:imageToProcessAtNextAudioBuffer.size andOrientation:imageToProcessAtNextAudioBuffer.imageOrientation];
    }

    while( ! assetWriterVideoInput.readyForMoreMediaData && ! _encodingLiveVideo && ! videoEncodingIsFinished ) {
        NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.1];
        //NSLog(@"video waiting...");
        [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
    }
    if (!assetWriterVideoInput.readyForMoreMediaData)
    {
        NSLog(@"2: Had to drop a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
    }
    else if(![assetWriterPixelBufferInput appendPixelBuffer:_bufferToProcessAtNextAudioBuffer withPresentationTime:frameTime])
    {
        NSLog(@"Problem appending pixel buffer at time: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
        isRecording = NO;
        _paused = NO;
        NSLog(@"assetWriter.status = %li", (long) assetWriter.status);
        NSLog(@"assetWriter.error = %@", assetWriter.error);
    }
    else
    {
//            NSLog(@"Wrote a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
    }

    previousFrameTime = frameTime;
}

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image andSize:(CGSize)frameSize andOrientation:(UIImageOrientation)orientation {
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:YES], (__bridge NSString *) kCVPixelBufferCGImageCompatibilityKey,
            [NSNumber numberWithBool:YES], (__bridge NSString *) kCVPixelBufferCGBitmapContextCompatibilityKey,
            nil];
    CVPixelBufferRef pxBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, (NSUInteger) frameSize.width,
            (NSUInteger) frameSize.height, kCVPixelFormatType_32ARGB, (__bridge CFDictionaryRef) options,
            &pxBuffer);
    NSParameterAssert(status == kCVReturnSuccess && pxBuffer != NULL);

    CVPixelBufferLockBaseAddress(pxBuffer, 0);
    void *pxData = CVPixelBufferGetBaseAddress(pxBuffer);
    NSParameterAssert(pxData != NULL);

    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxData, (NSUInteger) frameSize.width,
            (NSUInteger) frameSize.height, 8, CVPixelBufferGetBytesPerRow(pxBuffer), rgbColorSpace,
            (CGBitmapInfo) kCGImageAlphaPremultipliedFirst);
    NSParameterAssert(context);


    CGAffineTransform transform = CGAffineTransformIdentity;
    switch (orientation) {
        case UIImageOrientationUp:
            break;

        case UIImageOrientationUpMirrored:
            transform = CGAffineTransformMakeTranslation(frameSize.width, 0.0);
            transform = CGAffineTransformScale(transform, -1.0, 1.0);
            break;

        case UIImageOrientationDown:
            transform = CGAffineTransformMakeTranslation(frameSize.width, frameSize.height);
            transform = CGAffineTransformRotate(transform, M_PI);
            break;

        case UIImageOrientationDownMirrored:
            transform = CGAffineTransformMakeTranslation(0.0, frameSize.height);
            transform = CGAffineTransformScale(transform, 1.0, -1.0);
            break;

        case UIImageOrientationLeft:
            transform = CGAffineTransformMakeTranslation(frameSize.height, 0.0);
            transform = CGAffineTransformRotate(transform, M_PI_2);
            break;

        case UIImageOrientationLeftMirrored:
            transform = CGAffineTransformMakeTranslation(frameSize.height, frameSize.width);
            transform = CGAffineTransformScale(transform, -1.0, 1.0);
            transform = CGAffineTransformRotate(transform, -M_PI_2);
            break;

        case UIImageOrientationRight:
            transform = CGAffineTransformMakeTranslation(0.0, frameSize.width);
            transform = CGAffineTransformRotate(transform, -M_PI_2);
            break;

        case UIImageOrientationRightMirrored:
            transform = CGAffineTransformMakeScale(-1.0, 1.0);
            transform = CGAffineTransformRotate(transform, M_PI_2);
            break;

        default:
            return nil;
    }

    switch (orientation) {
//        case UIImageOrientationLeft:
        case UIImageOrientationLeftMirrored:
//        case UIImageOrientationRight:
        case UIImageOrientationRightMirrored:
            CGContextScaleCTM(context, -1.0, 1.0);
//            CGContextTranslateCTM(context, -frameSize.height, 0.0);
            break;

        case UIImageOrientationUpMirrored:
        case UIImageOrientationDownMirrored:
            CGContextScaleCTM(context, 1.0, -1.0);
//            CGContextTranslateCTM(context, 0.0, -frameSize.height);
            break;

        default:
            break;
    }

    CGContextConcatCTM(context, transform);

    CGContextDrawImage(context, CGRectMake(0, 0, frameSize.width, frameSize.height), image);

    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pxBuffer, 0);

    return pxBuffer;
}

#pragma mark -
#pragma mark Frame rendering

- (void)createDataFBO;
{
    glActiveTexture(GL_TEXTURE1);
    glGenFramebuffers(1, &movieFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, movieFramebuffer);

    if ([GPUImageContext supportsFastTextureUpload])
    {
#if defined(__IPHONE_6_0)
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, [[GPUImageContext sharedImageProcessingContext] context], NULL, &coreVideoTextureCache);
#else
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)[[GPUImageContext sharedImageProcessingContext] context], NULL, &coreVideoTextureCache);
#endif

        if (err)
        {
            NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreate %d", err);
        }

        // Code originally sourced from http://allmybrain.com/2011/12/08/rendering-to-a-texture-with-ios-5-texture-cache-api/


        CVPixelBufferPoolCreatePixelBuffer (NULL, [assetWriterPixelBufferInput pixelBufferPool], &renderTarget);

        CVOpenGLESTextureCacheCreateTextureFromImage (kCFAllocatorDefault, coreVideoTextureCache, renderTarget,
                NULL, // texture attributes
                GL_TEXTURE_2D,
                GL_RGBA, // opengl format
                (int)videoSize.width,
                (int)videoSize.height,
                GL_BGRA, // native iOS format
                GL_UNSIGNED_BYTE,
                0,
                &renderTexture);

        glBindTexture(CVOpenGLESTextureGetTarget(renderTexture), CVOpenGLESTextureGetName(renderTexture));
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, CVOpenGLESTextureGetName(renderTexture), 0);
    }
    else
    {
        glGenRenderbuffers(1, &movieRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, movieRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, (int)videoSize.width, (int)videoSize.height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, movieRenderbuffer);
    }


	GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);

    NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete filter FBO: %d", status);
}

- (void)destroyDataFBO;
{
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];

        if (movieFramebuffer)
        {
            glDeleteFramebuffers(1, &movieFramebuffer);
            movieFramebuffer = 0;
        }

        if (movieRenderbuffer)
        {
            glDeleteRenderbuffers(1, &movieRenderbuffer);
            movieRenderbuffer = 0;
        }

        if ([GPUImageContext supportsFastTextureUpload])
        {
            if (coreVideoTextureCache)
            {
                CFRelease(coreVideoTextureCache);
            }

            if (renderTexture)
            {
                CFRelease(renderTexture);
            }
            if (renderTarget)
            {
                CVPixelBufferRelease(renderTarget);
            }

        }
    });
}

- (void)setFilterFBO;
{
    if (!movieFramebuffer)
    {
        [self createDataFBO];
    }

    glBindFramebuffer(GL_FRAMEBUFFER, movieFramebuffer);

    glViewport(0, 0, (int)videoSize.width, (int)videoSize.height);
}

- (void)renderAtInternalSize;
{
    [GPUImageContext useImageProcessingContext];
    [self setFilterFBO];

    [GPUImageContext setActiveShaderProgram:colorSwizzlingProgram];

    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    // This needs to be flipped to write out to video correctly
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };

    const GLfloat *textureCoordinates = [GPUImageFilter textureCoordinatesForRotation:inputRotation];

	glActiveTexture(GL_TEXTURE4);
	glBindTexture(GL_TEXTURE_2D, inputTextureForMovieRendering);
	glUniform1i(colorSwizzlingInputTextureUniform, 4);

    glVertexAttribPointer(colorSwizzlingPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
	glVertexAttribPointer(colorSwizzlingTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glFinish();
}

#pragma mark -
#pragma mark GPUImageInput protocol

- (void)newFrameReadyAtTime:(CMTime)frameTime atIndex:(NSInteger)textureIndex;
{
    if (!isRecording)
    {
        return;
    }

    if (_paused)
    {
        if (CMTIME_IS_INVALID(previousTimeWhilePausing))
        {
            if (CMTIME_IS_INVALID(pausingTimeDiff))
            {
                pausingTimeDiff = kCMTimeZero;
            }

            previousTimeWhilePausing = frameTime;
        }

        pausingTimeDiff = CMTimeAdd(pausingTimeDiff, CMTimeSubtract(frameTime, previousTimeWhilePausing));
        previousTimeWhilePausing = frameTime;
        return;
    }
    else
    {
        if (CMTIME_IS_VALID(previousTimeWhilePausing))
        {
            previousTimeWhilePausing = kCMTimeInvalid;
        }
        if (CMTIME_IS_VALID(pausingTimeDiff))
        {
            frameTime = CMTimeSubtract(frameTime, pausingTimeDiff);
        }
    }

    // Drop frames forced by images and other things with no time constants
    // Also, if two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
    if ( (CMTIME_IS_INVALID(frameTime)) || (CMTIME_COMPARE_INLINE(frameTime, <=, previousFrameTime)) || (CMTIME_IS_INDEFINITE(frameTime)) )
    {
        return;
    }

    if (CMTIME_IS_INVALID(startTime))
    {
        dispatch_sync(movieWritingQueue, ^{
            if (CMTIME_IS_VALID(startTime))
            {
                return ;
            }
            if ((videoInputReadyCallback == NULL) && (assetWriter.status != AVAssetWriterStatusWriting))
            {
                [assetWriter startWriting];
            }

            [assetWriter startSessionAtSourceTime:frameTime];
            startTime = frameTime;
        });
    }

    if (!assetWriterVideoInput.readyForMoreMediaData && _encodingLiveVideo)
    {
        NSLog(@"1: Had to drop a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
        return;
    }

    // Render the frame with swizzled colors, so that they can be uploaded quickly as BGRA frames
    [GPUImageContext useImageProcessingContext];
    [self renderAtInternalSize];

    CVPixelBufferRef pixel_buffer = NULL;

    if ([GPUImageContext supportsFastTextureUpload])
    {
        pixel_buffer = renderTarget;
        CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    }
    else
    {
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer (NULL, [assetWriterPixelBufferInput pixelBufferPool], &pixel_buffer);
        if ((pixel_buffer == NULL) || (status != kCVReturnSuccess))
        {
            CVPixelBufferRelease(pixel_buffer);
            return;
        }
        else
        {
            CVPixelBufferLockBaseAddress(pixel_buffer, 0);

            GLubyte *pixelBufferData = (GLubyte *)CVPixelBufferGetBaseAddress(pixel_buffer);
            glReadPixels(0, 0, videoSize.width, videoSize.height, GL_RGBA, GL_UNSIGNED_BYTE, pixelBufferData);
        }
    }

    void(^write)() = ^() {
        while( ! assetWriterVideoInput.readyForMoreMediaData && ! _encodingLiveVideo && ! videoEncodingIsFinished ) {
            NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.1];
            //NSLog(@"video waiting...");
            [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
        }
        if (!assetWriterVideoInput.readyForMoreMediaData)
        {
            NSLog(@"2: Had to drop a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
        }
        else if(![assetWriterPixelBufferInput appendPixelBuffer:pixel_buffer withPresentationTime:frameTime])
        {
            NSLog(@"Problem appending pixel buffer at time: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
            isRecording = NO;
            _paused = NO;
            NSLog(@"assetWriter.status = %li", (long) assetWriter.status);
            NSLog(@"assetWriter.error = %@", assetWriter.error);
        }
        else
        {
//            NSLog(@"Wrote a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
        }
        CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);

        previousFrameTime = frameTime;

        if (![GPUImageContext supportsFastTextureUpload])
        {
            CVPixelBufferRelease(pixel_buffer);
        }
    };

    if( _encodingLiveVideo )
        dispatch_async(movieWritingQueue, write);
    else
        write();
}

- (NSInteger)nextAvailableTextureIndex;
{
    return 0;
}

- (void)setInputTexture:(GLuint)newInputTexture atIndex:(NSInteger)textureIndex;
{
    inputTextureForMovieRendering = newInputTexture;
}

- (void)setInputRotation:(GPUImageRotationMode)newInputRotation atIndex:(NSInteger)textureIndex;
{
    inputRotation = newInputRotation;
}

- (void)setInputSize:(CGSize)newSize atIndex:(NSInteger)textureIndex;
{
}

- (CGSize)maximumOutputSize;
{
    return videoSize;
}

- (void)endProcessing
{
    if (completionBlock)
    {
        if (!alreadyFinishedRecording)
        {
            alreadyFinishedRecording = YES;
            completionBlock();
        }
    }
    else
    {
        if (_delegate && [_delegate respondsToSelector:@selector(movieRecordingCompleted)])
        {
            [_delegate movieRecordingCompleted];
        }
    }
}

- (BOOL)shouldIgnoreUpdatesToThisTarget;
{
    return NO;
}

- (void)setTextureDelegate:(id<GPUImageTextureDelegate>)newTextureDelegate atIndex:(NSInteger)textureIndex;
{
    textureDelegate = newTextureDelegate;
}

- (void)conserveMemoryForNextFrame;
{

}

- (BOOL)wantsMonochromeInput;
{
    return NO;
}

- (void)setCurrentlyReceivingMonochromeInput:(BOOL)newValue;
{

}

#pragma mark -
#pragma mark Accessors

- (void)setHasAudioTrack:(BOOL)newValue
{
	[self setHasAudioTrack:newValue audioSettings:nil];
}

- (void)setHasAudioTrack:(BOOL)newValue audioSettings:(NSDictionary *)audioOutputSettings;
{
    _hasAudioTrack = newValue;

    if (_hasAudioTrack)
    {
        if (_shouldPassthroughAudio)
        {
			// Do not set any settings so audio will be the same as passthrough
			audioOutputSettings = nil;
        }
        else if (audioOutputSettings == nil)
        {
            double preferredHardwareSampleRate = [[AVAudioSession sharedInstance] currentHardwareSampleRate];

            AudioChannelLayout acl;
            bzero( &acl, sizeof(acl));
            acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;

            audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                         [ NSNumber numberWithInt: kAudioFormatMPEG4AAC], AVFormatIDKey,
                                         [ NSNumber numberWithInt: 1 ], AVNumberOfChannelsKey,
                                         [ NSNumber numberWithFloat: preferredHardwareSampleRate ], AVSampleRateKey,
                                         [ NSData dataWithBytes: &acl length: sizeof( acl ) ], AVChannelLayoutKey,
                                         //[ NSNumber numberWithInt:AVAudioQualityLow], AVEncoderAudioQualityKey,
                                         [ NSNumber numberWithInt: 64000 ], AVEncoderBitRateKey,
                                         nil];

/*
            AudioChannelLayout acl;
            bzero( &acl, sizeof(acl));
            acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
            
            audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [ NSNumber numberWithInt: kAudioFormatMPEG4AAC ], AVFormatIDKey,
                                   [ NSNumber numberWithInt: 1 ], AVNumberOfChannelsKey,
                                   [ NSNumber numberWithFloat: 44100.0 ], AVSampleRateKey,
                                   [ NSNumber numberWithInt: 64000 ], AVEncoderBitRateKey,
                                   [ NSData dataWithBytes: &acl length: sizeof( acl ) ], AVChannelLayoutKey,
                                   nil];*/
        }

        assetWriterAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioOutputSettings];
        [assetWriter addInput:assetWriterAudioInput];
        assetWriterAudioInput.expectsMediaDataInRealTime = _encodingLiveVideo;
    }
    else
    {
        // Remove audio track if it exists
    }
}

- (NSArray*)metaData {
    return assetWriter.metadata;
}

- (void)setMetaData:(NSArray*)metaData {
    assetWriter.metadata = metaData;
}

- (CMTime)duration {
    if( ! CMTIME_IS_VALID(startTime) )
        return kCMTimeZero;

    CMTime result = kCMTimeZero;

    if( CMTIME_IS_VALID(pausingTimeDiff) ) {
        CMTime subResult = CMTimeSubtract(CMTimeSubtract(previousFrameTime, startTime), pausingTimeDiff);
        if (CMTIME_COMPARE_INLINE(subResult, >, result)) {
            result = subResult;
        }
    }

    if( ! CMTIME_IS_NEGATIVE_INFINITY(previousFrameTime) ) {
        CMTime subResult = CMTimeSubtract(previousFrameTime, startTime);
        if (CMTIME_COMPARE_INLINE(subResult, >, result)) {
            result = subResult;
        }
    }

    if( ! CMTIME_IS_NEGATIVE_INFINITY(previousAudioTime) ) {
        CMTime subResult = CMTimeSubtract(previousAudioTime, startTime);
        if (CMTIME_COMPARE_INLINE(subResult, >, result)) {
            result = subResult;
        }
    }

    return result;
}

- (CGAffineTransform)transform {
    return assetWriterVideoInput.transform;
}

- (void)setTransform:(CGAffineTransform)transform {
    assetWriterVideoInput.transform = transform;
}

- (AVAssetWriter*)assetWriter {
    return assetWriter;
}

@end
