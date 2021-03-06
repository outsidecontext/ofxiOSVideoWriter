//
//  VideoWriter.m
//  Created by lukasz karluk on 15/06/12.
//  http://www.julapy.com
//

#import <AssetsLibrary/AssetsLibrary.h>
#import "VideoWriter.h"

@interface VideoWriter() {
	CMTime startTime;
    CMTime previousFrameTime;
	CMTime previousAudioTime;
    BOOL bWriting;

    BOOL bUseTextureCache;
    BOOL bEnableTextureCache;
    BOOL bTextureCacheSupported;
	BOOL bFirstAudio;
	
    CVOpenGLESTextureCacheRef _textureCache;
    CVOpenGLESTextureRef _textureRef;
    CVPixelBufferRef _textureCachePixelBuffer;
	CMSampleBufferRef _firstAudioBuffer;
}
@end


@implementation VideoWriter

@synthesize delegate;
@synthesize videoSize;
@synthesize context;
@synthesize assetWriter;
@synthesize assetWriterVideoInput;
@synthesize assetWriterAudioInput;
@synthesize assetWriterInputPixelBufferAdaptor;
@synthesize outputURL;
@synthesize enableTextureCache;
@synthesize expectsMediaDataInRealTime;

//---------------------------------------------------------------------------
- (id)initWithFile:(NSString *)file andVideoSize:(CGSize)size {
    NSString * docsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString * fullPath = [docsPath stringByAppendingPathComponent:file];
    NSURL * fileURL = [NSURL fileURLWithPath:fullPath];
	return [self initWithURL:fileURL andVideoSize:size];
}

- (id)initWithPath:(NSString *)path andVideoSize:(CGSize)size {
    NSURL * fileURL = [NSURL fileURLWithPath:path];
	return [self initWithURL:fileURL andVideoSize:size];
}

- (id)initWithURL:(NSURL *)fileURL andVideoSize:(CGSize)size {
    self = [self init];
    if(self) {
        self.outputURL = fileURL;
        self.videoSize = size;
    }
    return self;
}

- (id)setPath:(NSString *)path {
    if(self) {
        NSURL * fileURL = [NSURL fileURLWithPath:path];
        self.outputURL = fileURL;
    }
    return self;
}

- (id)init {
    self = [super init];
    if(self) {
        bWriting = NO;
        startTime = kCMTimeInvalid;
        previousFrameTime = kCMTimeInvalid;
		previousAudioTime = kCMTimeInvalid;
        videoWriterQueue = dispatch_queue_create("ofxiOSVideoWriter.VideoWriterQueue", NULL);

        bUseTextureCache = NO;
        bEnableTextureCache = NO;
        bTextureCacheSupported = NO;
        expectsMediaDataInRealTime = YES;
    }
    return self;
}

- (void)dealloc {
    self.outputURL = nil;
    
    [self disposeAssetWriterAndWriteFile:NO];
	
	if(_firstAudioBuffer) {
		CFRelease(_firstAudioBuffer);
	}
    
#if ( (__IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_6_0) || (!defined(__IPHONE_6_0)) )
    if(videoWriterQueue != NULL) {
        dispatch_release(videoWriterQueue);
    }
#endif
    
    [super dealloc];
}

//---------------------------------------------------------------------------
- (void)startRecording {
    if(bWriting == YES) {
        return;
    }
    bWriting = YES;
    
    startTime = kCMTimeZero;
    previousFrameTime = kCMTimeInvalid;
	bFirstAudio = YES;
	if(_firstAudioBuffer) {
		CFRelease(_firstAudioBuffer);
	}
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.outputURL.path]) { // remove old file.
        [[NSFileManager defaultManager] removeItemAtPath:self.outputURL.path error:nil];
    }
    
    NSLog(@"  startRecording - %@", self.outputURL);
    
    // allocate the writer object with our output file URL
    NSError *error = nil;
    self.assetWriter = [AVAssetWriter assetWriterWithURL:self.outputURL
                                                fileType:AVFileTypeQuickTimeMovie
                                                   error:&error];
    if(error) {
        NSLog(@"  error - %@", error);
        if([self.delegate respondsToSelector:@selector(videoWriterError:)]) {
            [self.delegate videoWriterError:error];
        }
        return;
    }
    
    //--------------------------------------------------------------------------- adding video input.
    NSDictionary * videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                    AVVideoCodecH264, AVVideoCodecKey,
                                    [NSNumber numberWithInt:self.videoSize.width], AVVideoWidthKey,
                                    [NSNumber numberWithInt:self.videoSize.height], AVVideoHeightKey,
                                    nil];
    
    // initialized a new input for video to receive sample buffers for writing
    // passing nil for outputSettings instructs the input to pass through appended samples, doing no processing before they are written
    self.assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                    outputSettings:videoSettings];
    self.assetWriterVideoInput.expectsMediaDataInRealTime = expectsMediaDataInRealTime;
    
    // You need to use BGRA for the video in order to get realtime encoding.
    // Color-swizzling shader is used to line up glReadPixels' normal RGBA output with the movie input's BGRA.
    NSDictionary * sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                                            [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                                            [NSNumber numberWithInt:videoSize.width], kCVPixelBufferWidthKey,
                                                            [NSNumber numberWithInt:videoSize.height], kCVPixelBufferHeightKey,
                                                            nil];
    
    self.assetWriterInputPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.assetWriterVideoInput
                                                                                                               sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
    
    if([self.assetWriter canAddInput:self.assetWriterVideoInput]) {
        [self.assetWriter addInput:self.assetWriterVideoInput];
    }
    
    //--------------------------------------------------------------------------- adding audio input.
    double preferredHardwareSampleRate = [[AVAudioSession sharedInstance] currentHardwareSampleRate];
    
    AudioChannelLayout channelLayout;
    bzero(&channelLayout, sizeof(channelLayout));
    channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    
    int numOfChannels = 1;
    if(channelLayout.mChannelLayoutTag == kAudioChannelLayoutTag_Stereo) {
        numOfChannels = 2;
    }
    
    NSDictionary * audioSettings = nil;
    
    audioSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                     [NSNumber numberWithInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                     [NSNumber numberWithInt:numOfChannels], AVNumberOfChannelsKey,
                     [NSNumber numberWithFloat:preferredHardwareSampleRate], AVSampleRateKey,
                     [NSData dataWithBytes:&channelLayout length:sizeof(channelLayout)], AVChannelLayoutKey,
                     [NSNumber numberWithInt:64000], AVEncoderBitRateKey,
                     nil];

    self.assetWriterAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                    outputSettings:audioSettings];
    self.assetWriterAudioInput.expectsMediaDataInRealTime = expectsMediaDataInRealTime;
    
    if([self.assetWriter canAddInput:self.assetWriterAudioInput]) {
        [self.assetWriter addInput:self.assetWriterAudioInput];
    }

    //--------------------------------------------------------------------------- start writing!
	[self.assetWriter startWriting];
	[self.assetWriter startSessionAtSourceTime:startTime];
    
    if(bEnableTextureCache) {
        [self initTextureCache];
    }
}

- (void)finishRecording {
    if(bWriting == NO) {
        return;
    }
    
    if(assetWriter.status == AVAssetWriterStatusCompleted ||
       assetWriter.status == AVAssetWriterStatusCancelled ||
       assetWriter.status == AVAssetWriterStatusUnknown) {
        return;
    }
    
    bWriting = NO;
    dispatch_sync(videoWriterQueue, ^{
        [self disposeAssetWriterAndWriteFile:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if([self.delegate respondsToSelector:@selector(videoWriterComplete:)]) {
                [self.delegate videoWriterComplete:self.outputURL];
            }
            NSLog(@"video saved to sandbox: %@", self.outputURL.description);
            // TODO: make this optional? E.g. if (doAutoCameraRollSave)
            // Copy the video to the photos album
            //[self saveMovieToCameraRoll];
            
        });
    });
}

- (void)cancelRecording {
    if(bWriting == NO) {
        return;
    }
    
    if(self.assetWriter.status == AVAssetWriterStatusCompleted) {
        return;
    }
    
    bWriting = NO;
    dispatch_sync(videoWriterQueue, ^{
		[self disposeAssetWriterAndWriteFile:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            if([self.delegate respondsToSelector:@selector(videoWriterCancelled)]) {
                [self.delegate videoWriterCancelled];
            }
        });
    });
}

- (void) disposeAssetWriterAndWriteFile:(BOOL)writeFile {
	[self.assetWriterVideoInput markAsFinished];
	[self.assetWriterAudioInput markAsFinished];
	
	void (^releaseAssetWriter)(void) = ^{
		self.assetWriterVideoInput = nil;
		self.assetWriterAudioInput = nil;
		self.assetWriter = nil;
		self.assetWriterInputPixelBufferAdaptor = nil;
		[self destroyTextureCache];
	};
	
	if(writeFile) {
		[self.assetWriter finishWritingWithCompletionHandler:releaseAssetWriter];
	} else {
		[self.assetWriter cancelWriting];
		releaseAssetWriter();
	}
}

- (BOOL)isWriting {
    return bWriting;
}

//--------------------------------------------------------------------------- add frame.
- (BOOL)addFrameAtTime:(CMTime)frameTime {

    if(bWriting == NO) {
        return NO;
    }
    
    if((CMTIME_IS_INVALID(frameTime)) ||
       (CMTIME_COMPARE_INLINE(frameTime, ==, previousFrameTime)) ||
       (CMTIME_IS_INDEFINITE(frameTime))) {
        return NO;
    }
    
    if(assetWriterVideoInput.readyForMoreMediaData == NO) {
        NSLog(@"[VideoWriter addFrameAtTime] - not ready for more media data");
        return NO;
    }

    //---------------------------------------------------------- fill pixel buffer.
    CVPixelBufferRef pixelBuffer = NULL;

    //----------------------------------------------------------
    // check if texture cache is enabled,
    // if so, use the pixel buffer from the texture cache.
    //----------------------------------------------------------
    
    if(bUseTextureCache == YES) {
        pixelBuffer = _textureCachePixelBuffer;
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    }
    
    //----------------------------------------------------------
    // if texture cache is disabled,
    // read the pixels from screen or fbo.
    // this is a much slower fallback alternative.
    //----------------------------------------------------------
    
    if(pixelBuffer == NULL) {
        CVPixelBufferPoolRef pixelBufferPool = [self.assetWriterInputPixelBufferAdaptor pixelBufferPool];
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, pixelBufferPool, &pixelBuffer);
        if((pixelBuffer == NULL) || (status != kCVReturnSuccess)) {
            return NO;
        } else {
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            GLubyte * pixelBufferData = (GLubyte *)CVPixelBufferGetBaseAddress(pixelBuffer);
            glReadPixels(0, 0, self.videoSize.width, self.videoSize.height, GL_RGBA, GL_UNSIGNED_BYTE, pixelBufferData);
        }
    }
    
    //----------------------------------------------------------
    dispatch_sync(videoWriterQueue, ^{
        
        BOOL bOk = [self.assetWriterInputPixelBufferAdaptor appendPixelBuffer:pixelBuffer
                                                         withPresentationTime:frameTime];
        if(bOk == NO) {
            NSString * errorDesc = self.assetWriter.error.description;
            NSLog(@"[VideoWriter addFrameAtTime] - error appending video samples - %@", errorDesc);
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        
        previousFrameTime = frameTime;
        
        if(bUseTextureCache == NO) {
            CVPixelBufferRelease(pixelBuffer);
        }
    });
    
    return YES;
}

- (BOOL)addAudio:(CMSampleBufferRef)audioBuffer {
    
    if(bWriting == NO) {
        return NO;
    }
    
    if(audioBuffer == nil) {
        NSLog(@"[VideoWriter addAudio] - audioBuffer was nil.");
        return NO;
    }
	
	if(assetWriterAudioInput.readyForMoreMediaData == NO) {
        NSLog(@"[VideoWriter addAudio] - not ready for more media data");
        return NO;
    }
	
	CMTime newBufferTime = CMSampleBufferGetPresentationTimeStamp(audioBuffer);
	if (CMTIME_COMPARE_INLINE(newBufferTime, ==, previousAudioTime)) {
		return NO;
	}
		
	previousAudioTime = newBufferTime;
	
	// hold onto the first buffer, until we've figured out when playback truly starts (which is
	// when the second buffer arrives)
	if(bFirstAudio) {
		CMSampleBufferCreateCopy(NULL, audioBuffer, &_firstAudioBuffer);
		bFirstAudio = NO;
		return NO;
	}
	// if the incoming audio buffer has an earlier timestamp than the current "first" buffer, then
	// drop the current "first" buffer and store the new one instead
	else if(_firstAudioBuffer && CMTIME_COMPARE_INLINE(CMSampleBufferGetPresentationTimeStamp(_firstAudioBuffer), >, newBufferTime)) {
		CFRelease(_firstAudioBuffer);
		CMSampleBufferCreateCopy(NULL, audioBuffer, &_firstAudioBuffer);
		return NO;
	}

    //----------------------------------------------------------
    dispatch_sync(videoWriterQueue, ^{
		
		if(_firstAudioBuffer) {
			CMSampleBufferRef correctedFirstBuffer = [self copySampleBuffer:_firstAudioBuffer withNewTime:previousFrameTime];
			[self.assetWriterAudioInput appendSampleBuffer:correctedFirstBuffer];
			CFRelease(_firstAudioBuffer);
			CFRelease(correctedFirstBuffer);
			_firstAudioBuffer = NULL;
		}
		
		BOOL bOk = [self.assetWriterAudioInput appendSampleBuffer:audioBuffer];
        if(bOk == NO) {
            NSString * errorDesc = self.assetWriter.error.description;
            NSLog(@"[VideoWriter addAudio] - error appending audio samples - %@", errorDesc);
        }
    });
    
    return YES;
}

- (CMSampleBufferRef) copySampleBuffer:(CMSampleBufferRef)inBuffer withNewTime:(CMTime)time {
	
	CMSampleTimingInfo timingInfo;
	CMSampleBufferGetSampleTimingInfo(inBuffer, 0, &timingInfo);
	timingInfo.presentationTimeStamp = time;
	
	CMSampleBufferRef outBuffer;
	CMSampleBufferCreateCopyWithNewTiming(NULL, inBuffer, 1, &timingInfo, &outBuffer);
	return outBuffer;
}

//--------------------------------------------------------------------------- texture cache.
- (void)setEnableTextureCache:(BOOL)value {
    if(bWriting == YES) {
        NSLog(@"enableTextureCache can not be changed while recording.");
    }
    bEnableTextureCache = value;
}

- (void)setExpectsMediaDataInRealTime:(BOOL)value {
    expectsMediaDataInRealTime = value;
}

- (void)initTextureCache {
    
    bTextureCacheSupported = (CVOpenGLESTextureCacheCreate != NULL);
#if TARGET_IPHONE_SIMULATOR
    bTextureCacheSupported = NO; // texture caching does not work properly on the simulator.
#endif
    bUseTextureCache = bTextureCacheSupported;
    if(bEnableTextureCache == NO) {
        bUseTextureCache = NO;
    }
    
    if(bUseTextureCache == NO) {
        return;
    }
    
    //-----------------------------------------------------------------------
    CVReturn error;
#if defined(__IPHONE_6_0)
    error = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault,
                                         NULL,
                                         context,
                                         NULL,
                                         &_textureCache);
#else
    error = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault,
                                         NULL,
                                         (__bridge void *)context,
                                         NULL,
                                         &_textureCache);
#endif
    
    if(error) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", error);
        bUseTextureCache = NO;
        return;
    }
    
    //-----------------------------------------------------------------------
    CVPixelBufferPoolRef pixelBufferPool = [self.assetWriterInputPixelBufferAdaptor pixelBufferPool];
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, pixelBufferPool, &_textureCachePixelBuffer);
    if(status != kCVReturnSuccess) {
        bUseTextureCache = NO;
        return;
    }
    
    error = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,         // CFAllocatorRef allocator
                                                         _textureCache,               // CVOpenGLESTextureCacheRef textureCache
                                                         _textureCachePixelBuffer,    // CVPixelBufferRef source pixel buffer.
                                                         NULL,                        // CFDictionaryRef textureAttributes
                                                         GL_TEXTURE_2D,               // GLenum target
                                                         GL_RGBA,                     // GLint internalFormat
                                                         (int)self.videoSize.width,   // GLsizei width
                                                         (int)self.videoSize.height,  // GLsizei height
                                                         GL_BGRA,                     // GLenum format
                                                         GL_UNSIGNED_BYTE,            // GLenum type
                                                         0,                           // size_t planeIndex
                                                         &_textureRef);               // CVOpenGLESTextureRef *textureOut
    
    if(error) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", error);
        bUseTextureCache = NO;
        return;
    }
}

- (void)destroyTextureCache {
    
    if(_textureCache) {
        CVOpenGLESTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
    
    if(_textureRef) {
        CFRelease(_textureRef);
        _textureRef = NULL;
    }
    
    if(_textureCachePixelBuffer) {
        CVPixelBufferRelease(_textureCachePixelBuffer);
        _textureCachePixelBuffer = NULL;
    }
}

- (BOOL)isTextureCached {
    return bUseTextureCache;
}

- (unsigned int)textureCacheID {
    if(_textureRef != nil) {
        return CVOpenGLESTextureGetName(_textureRef);
    }
    return 0;
}

- (int)textureCacheTarget {
    if(_textureRef != nil) {
        return CVOpenGLESTextureGetTarget(_textureRef);
    }
    return 0;
}

//---------------------------------------------------------------------------
- (void)saveMovieToCameraRoll {
    
    NSLog(@"    Attempting to copy to camera roll");
    
    // Check compatability? Sometimes this fails but the vide still copies!?
    //BOOL isVideoGood = UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(self.outputURL.path);
    //if (isVideoGood)  NSLog(@"Video CAN be saved to iOS camera roll");
    //else  NSLog(@"Video CANNOT be saved to iOS camera roll");
    
    // This works sometimes!?
    // UISaveVideoAtPathToSavedPhotosAlbum(self.outputURL.path, nil, NULL, NULL);
    
    // This will only work for iOS 8.0 +
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        // Create a change request from the asset to be modified.
        PHAssetChangeRequest *request = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:self.outputURL];
    } completionHandler:^(BOOL success, NSError *error) {
        NSLog(@"    Finished copying image. %@", (success ? @"Success." : error));
        if (success) {
            [self.delegate videoWriterSavedToCameraRoll];
        } else {
            [self.delegate videoWriterError:error];
        }
        // Remove the file from the sandbox?
        //if ([[NSFileManager defaultManager] fileExistsAtPath:self.outputURL.path]) { // remove old file.
        //    NSLog(@" remove old video at - %@", self.outputURL);
        //    [[NSFileManager defaultManager] removeItemAtPath:self.outputURL.path error:nil];
        //}
    }];
    
    // This doesn't work anymore in iOS 8.0+
    // save the movie to the camera roll
    /*
	ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
	NSLog(@"    writing \"%@\" to photos album", self.outputURL);
	[library writeVideoAtPathToSavedPhotosAlbum:self.outputURL
								completionBlock:^(NSURL *assetURL, NSError *error) {
									if (error) {
										NSLog(@"assets library failed (%@)", error);
									}
									else {
										[[NSFileManager defaultManager] removeItemAtURL:self.outputURL error:&error];
										if (error)
											NSLog(@"Couldn't remove temporary movie file \"%@\"", self.outputURL);
									}
                                    
									//self.outputURL = nil;
                                    [library release];
                                    
                                    if([self.delegate respondsToSelector:@selector(videoWriterSavedToCameraRoll)]) {
                                        [self.delegate videoWriterSavedToCameraRoll];
                                    }
								}];
     */
}

@end
