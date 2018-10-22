/*
 Copyright 2015 OpenMarket Ltd
 Copyright 2018 New Vector Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXKAttachment.h"

#import "MXMediaManager.h"
#import "MXKTools.h"
#import "MXEncryptedAttachments.h"

#import <MobileCoreServices/MobileCoreServices.h>

// The size of thumbnail we request from the server
// Note that this is smaller than the ones we upload: when sending, one size
// must fit all, including the web which will want relatively high res thumbnails.
// We, however, are a mobile client and so would prefer smaller thumbnails, which
// we can have if they're being generated by the media repo.
static const int kThumbnailWidth = 320;
static const int kThumbnailHeight = 240;

NSString *const kMXKAttachmentErrorDomain = @"kMXKAttachmentErrorDomain";

@interface MXKAttachment ()
{
    /**
     The information on the encrypted content.
     */
    MXEncryptedContentFile *contentFile;
    
    /**
     The information on the encrypted thumbnail.
     */
    MXEncryptedContentFile *thumbnailFile;
    
    /**
     Observe Attachment download
     */
    id onAttachmentDownloadEndObs;
    id onAttachmentDownloadFailureObs;
    
    /**
     The local path used to store the attachment with its original name
     */
    NSString* documentCopyPath;
}

@end

@interface MXKAttachment ()
@property (nonatomic) MXSession *sess;
@end

@implementation MXKAttachment

- (instancetype)initWithEvent:(MXEvent *)mxEvent andMatrixSession:(MXSession*)mxSession
{
    self = [super init];
    self.sess = mxSession;
    if (self)
    {
        // Make a copy as the data can be read at anytime later
        _eventId = mxEvent.eventId;
        _eventRoomId = mxEvent.roomId;
        _eventSentState = mxEvent.sentState;
        
        NSDictionary *eventContent = mxEvent.content;
        
        // Set default thumbnail orientation
        _thumbnailOrientation = UIImageOrientationUp;
        
        if (mxEvent.eventType == MXEventTypeSticker)
        {
            _type = MXKAttachmentTypeSticker;
            MXJSONModelSetDictionary(_thumbnailInfo, eventContent[@"info"][@"thumbnail_info"]);
        }
        else
        {
            // Note: mxEvent.eventType is supposed to be MXEventTypeRoomMessage here.
            NSString *msgtype = eventContent[@"msgtype"];
            if ([msgtype isEqualToString:kMXMessageTypeImage])
            {
                _type = MXKAttachmentTypeImage;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeAudio])
            {
                _type = MXKAttachmentTypeAudio;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeVideo])
            {
                _type = MXKAttachmentTypeVideo;
                MXJSONModelSetDictionary(_thumbnailInfo, eventContent[@"info"][@"thumbnail_info"]);
            }
            else if ([msgtype isEqualToString:kMXMessageTypeLocation])
            {
                // Not supported yet
                // _type = MXKAttachmentTypeLocation;
                return nil;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeFile])
            {
                _type = MXKAttachmentTypeFile;
            }
            else
            {
                return nil;
            }
        }
        
        MXJSONModelSetString(_originalFileName, eventContent[@"body"]);
        MXJSONModelSetDictionary(_contentInfo, eventContent[@"info"]);
        MXJSONModelSetMXJSONModel(thumbnailFile, MXEncryptedContentFile, _contentInfo[@"thumbnail_file"]);
        MXJSONModelSetMXJSONModel(contentFile, MXEncryptedContentFile, eventContent[@"file"]);
        
        // Retrieve the content url by taking into account the potential encryption.
        if (contentFile)
        {
            _isEncrypted = YES;
            _contentURL = contentFile.url;
        }
        else
        {
            _isEncrypted = NO;
            MXJSONModelSetString(_contentURL, eventContent[@"url"]);
        }
        
        // Note: When the attachment uploading is in progress, the upload id is stored in the content url (nasty trick).
        // Check whether the attachment is currently uploading.
        if ([_contentURL hasPrefix:kMXMediaUploadIdPrefix])
        {
            // In this case we consider the upload id as the absolute url.
            _actualURL = _contentURL;
        }
        else
        {
            // Prepare the absolute URL from the mxc: content URL
            _actualURL = [mxSession.matrixRestClient urlOfContent:_contentURL];
        }
        
        NSString *mimetype = nil;
        if (_contentInfo)
        {
            MXJSONModelSetString(mimetype, _contentInfo[@"mimetype"]);
        }
        
        _cacheFilePath = [MXMediaManager cachePathForMediaWithURL:_actualURL andType:mimetype inFolder:_eventRoomId];
        
        // Deduce the thumbnail information from the retrieved data.
        _thumbnailURL = [self getThumbnailUrlForSize:CGSizeMake(kThumbnailWidth, kThumbnailHeight)];
        _thumbnailMimeType = [self getThumbnailMimeType];
    }
    return self;
}

- (void)dealloc
{
    [self destroy];
}

- (void)destroy
{
    if (onAttachmentDownloadEndObs)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadEndObs];
        onAttachmentDownloadEndObs = nil;
    }

    if (onAttachmentDownloadFailureObs)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadFailureObs];
        onAttachmentDownloadFailureObs = nil;
    }
    
    // Remove the temporary file created to prepare attachment sharing
    if (documentCopyPath)
    {
        [[NSFileManager defaultManager] removeItemAtPath:documentCopyPath error:nil];
        documentCopyPath = nil;
    }
    
    _previewImage = nil;
}

- (NSString*)cacheThumbnailPath
{
    if (self.thumbnailURL)
    {
        return [MXMediaManager cachePathForMediaWithURL:self.thumbnailURL
                                                andType:self.thumbnailMimeType
                                               inFolder:_eventRoomId];
    }
    return nil;
}

- (NSString *)getThumbnailUrlForSize:(CGSize)size
{
    if (thumbnailFile && thumbnailFile.url)
    {
        // there's an encrypted thumbnail: we just return the mxc url
        // since it will have to be decrypted before downloading anyway,
        // so the URL is really just a key into the cache.
        return thumbnailFile.url;
    }
    
    if (_type == MXKAttachmentTypeVideo || _type == MXKAttachmentTypeSticker)
    {
        if (_contentInfo)
        {
            // Look for a clear video thumbnail url
            NSString *unencrypted_thumb_url = _contentInfo[@"thumbnail_url"];
            
            // Note: When the uploading is in progress, the upload id is stored in the content url (nasty trick).
            // Prepare the absolute URL from the mxc: content URL, only if the thumbnail is not currently uploading.
            if (![unencrypted_thumb_url hasPrefix:kMXMediaUploadIdPrefix])
            {
                unencrypted_thumb_url = [self.sess.matrixRestClient urlOfContent:unencrypted_thumb_url];
            }
            
            return unencrypted_thumb_url;
        }
    }
    
    // Consider the case of the unencrypted url
    if (!_isEncrypted && _contentURL && ![_contentURL hasPrefix:kMXMediaUploadIdPrefix])
    {
        return [self.sess.matrixRestClient urlOfContentThumbnail:_contentURL
                                                   toFitViewSize:size
                                                      withMethod:MXThumbnailingMethodScale];
    }
    
    return nil;
}

- (NSString *)getThumbnailMimeType
{
    if (thumbnailFile && thumbnailFile.mimetype)
    {
        return thumbnailFile.mimetype;
    }
    
    return _thumbnailInfo[@"mimetype"];
}

- (UIImage *)getCachedThumbnail
{
    NSString *cacheFilePath = self.cacheThumbnailPath;
    if (cacheFilePath)
    {
        UIImage *thumb = [MXMediaManager getFromMemoryCacheWithFilePath:cacheFilePath];
        if (thumb) return thumb;
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:cacheFilePath])
        {
            return [MXMediaManager loadThroughCacheWithFilePath:cacheFilePath];
        }
    }
    return nil;
}

- (void)getThumbnail:(void (^)(UIImage *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    if (!self.thumbnailURL)
    {
        // there is no thumbnail: if we're an image, return the full size image. Otherwise, nothing we can do.
        if (_type == MXKAttachmentTypeImage)
        {
            [self getImage:onSuccess failure:onFailure];
        }
        return;
    }
    
    NSString *thumbCachePath = self.cacheThumbnailPath;
    if (thumbCachePath)
    {
        UIImage *thumb = [MXMediaManager getFromMemoryCacheWithFilePath:thumbCachePath];
        if (thumb)
        {
            onSuccess(thumb);
            return;
        }
    }
    
    if (thumbnailFile && thumbnailFile.url)
    {
        MXWeakify(self);
        
        void (^decryptAndCache)(void) = ^{
            MXStrongifyAndReturnIfNil(self);
            NSInputStream *instream = [[NSInputStream alloc] initWithFileAtPath:thumbCachePath];
            NSOutputStream *outstream = [[NSOutputStream alloc] initToMemory];
            NSError *err = [MXEncryptedAttachments decryptAttachment:self->thumbnailFile inputStream:instream outputStream:outstream];
            if (err) {
                NSLog(@"Error decrypting attachment! %@", err.userInfo);
                if (onFailure) onFailure(err);
                return;
            }
            
            UIImage *img = [UIImage imageWithData:[outstream propertyForKey:NSStreamDataWrittenToMemoryStreamKey]];
            [MXMediaManager cacheImage:img withCachePath:thumbCachePath];
            onSuccess(img);
        };
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:thumbCachePath])
        {
            decryptAndCache();
        }
        else
        {
            NSString *actualUrl = [self.sess.matrixRestClient urlOfContent:thumbnailFile.url];
            [MXMediaManager downloadMediaFromURL:actualUrl andSaveAtFilePath:thumbCachePath success:^() {
                
                decryptAndCache();
                
            } failure:^(NSError *error) {
                
                if (onFailure) onFailure(error);
                
            }];
        }
        return;
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:thumbCachePath])
    {
        onSuccess([MXMediaManager loadThroughCacheWithFilePath:thumbCachePath]);
    }
    else
    {
        [MXMediaManager downloadMediaFromURL:self.thumbnailURL andSaveAtFilePath:thumbCachePath success:^{
            onSuccess([MXMediaManager loadThroughCacheWithFilePath:thumbCachePath]);
            
        } failure:^(NSError *error) {
            
            if (onFailure) onFailure(error);
            
        }];
    }
}

- (void)getImage:(void (^)(UIImage *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    [self getAttachmentData:^(NSData *data) {
        
        UIImage *img = [UIImage imageWithData:data];
        if (onSuccess) onSuccess(img);
        
    } failure:^(NSError *error) {
        
        if (onFailure) onFailure(error);
        
    }];
}

- (void)getAttachmentData:(void (^)(NSData *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    MXWeakify(self);
    [self prepare:^{
        MXStrongifyAndReturnIfNil(self);
        if (self->contentFile)
        {
            // decrypt the encrypted file
            NSInputStream *instream = [[NSInputStream alloc] initWithFileAtPath:self.cacheFilePath];
            NSOutputStream *outstream = [[NSOutputStream alloc] initToMemory];
            NSError *err = [MXEncryptedAttachments decryptAttachment:self->contentFile inputStream:instream outputStream:outstream];
            if (err)
            {
                NSLog(@"Error decrypting attachment! %@", err.userInfo);
                return;
            }
            onSuccess([outstream propertyForKey:NSStreamDataWrittenToMemoryStreamKey]);
        }
        else
        {
            onSuccess([NSData dataWithContentsOfFile:self.cacheFilePath]);
        }
    } failure:^(NSError *error) {
        
        if (onFailure) onFailure(error);
        
    }];
}

- (void)decryptToTempFile:(void (^)(NSString *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    MXWeakify(self);
    [self prepare:^{
        MXStrongifyAndReturnIfNil(self);
        NSString *tempPath = [self getTempFile];
        if (!tempPath)
        {
            if (onFailure) onFailure([NSError errorWithDomain:kMXKAttachmentErrorDomain code:0 userInfo:@{@"err": @"error_creating_temp_file"}]);
            return;
        }
        
        NSInputStream *inStream = [NSInputStream inputStreamWithFileAtPath:self.cacheFilePath];
        NSOutputStream *outStream = [NSOutputStream outputStreamToFileAtPath:tempPath append:NO];
        
        NSError *err = [MXEncryptedAttachments decryptAttachment:self->contentFile inputStream:inStream outputStream:outStream];
        if (err) {
            if (onFailure) onFailure(err);
            return;
        }
        onSuccess(tempPath);
    } failure:^(NSError *error) {
        if (onFailure) onFailure(error);
    }];
}

- (NSString *)getTempFile
{
    // create a file with an appropriate extension because iOS detects based on file extension
    // all over the place
    NSString *ext = [MXTools fileExtensionFromContentType:_contentInfo[@"mimetype"]];
    NSString *filenameTemplate = [NSString stringWithFormat:@"attatchment.XXXXXX%@", ext];
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:filenameTemplate];
    
    const char *templateCstr = [template fileSystemRepresentation];
    char *tempPathCstr = (char *)malloc(strlen(templateCstr) + 1);
    strcpy(tempPathCstr, templateCstr);
    
    int fd = mkstemps(tempPathCstr, (int)ext.length);
    if (!fd)
    {
        return nil;
    }
    close(fd);
    
    NSString *tempPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:tempPathCstr
                                                                                     length:strlen(tempPathCstr)];
    free(tempPathCstr);
    return tempPath;
}

- (void)prepare:(void (^)(void))onAttachmentReady failure:(void (^)(NSError *error))onFailure
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:_cacheFilePath])
    {
        // Done
        if (onAttachmentReady)
        {
            onAttachmentReady ();
        }
    }
    else
    {
        // Trigger download if it is not already in progress
        MXMediaLoader* loader = [MXMediaManager existingDownloaderWithOutputFilePath:_cacheFilePath];
        if (!loader)
        {
            loader = [MXMediaManager downloadMediaFromURL:_actualURL andSaveAtFilePath:_cacheFilePath];
        }
        
        if (loader)
        {
            MXWeakify(self);
            
            // Add observers
            onAttachmentDownloadEndObs = [[NSNotificationCenter defaultCenter] addObserverForName:kMXMediaDownloadDidFinishNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
                
                MXStrongifyAndReturnIfNil(self);
                
                // Sanity check
                if ([notif.object isKindOfClass:[NSString class]])
                {
                    NSString* url = notif.object;
                    NSString* cacheFilePath = notif.userInfo[kMXMediaLoaderFilePathKey];
                    
                    if ([url isEqualToString:self.actualURL] && cacheFilePath.length)
                    {
                        // Remove the observers
                        [[NSNotificationCenter defaultCenter] removeObserver:self->onAttachmentDownloadEndObs];
                        [[NSNotificationCenter defaultCenter] removeObserver:self->onAttachmentDownloadFailureObs];
                        self->onAttachmentDownloadEndObs = nil;
                        self->onAttachmentDownloadFailureObs = nil;
                        
                        if (onAttachmentReady)
                        {
                            onAttachmentReady ();
                        }
                    }
                }
            }];
            
            onAttachmentDownloadFailureObs = [[NSNotificationCenter defaultCenter] addObserverForName:kMXMediaDownloadDidFailNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
                
                MXStrongifyAndReturnIfNil(self);
                
                // Sanity check
                if ([notif.object isKindOfClass:[NSString class]])
                {
                    NSString* url = notif.object;
                    NSError* error = notif.userInfo[kMXMediaLoaderErrorKey];
                    
                    if ([url isEqualToString:self.actualURL])
                    {
                        // Remove the observers
                        [[NSNotificationCenter defaultCenter] removeObserver:self->onAttachmentDownloadEndObs];
                        [[NSNotificationCenter defaultCenter] removeObserver:self->onAttachmentDownloadFailureObs];
                        self->onAttachmentDownloadEndObs = nil;
                        self->onAttachmentDownloadFailureObs = nil;
                        
                        if (onFailure)
                        {
                            onFailure (error);
                        }
                    }
                }
            }];
        }
        else if (onFailure)
        {
            onFailure (nil);
        }
    }
}

- (void)save:(void (^)(void))onSuccess failure:(void (^)(NSError *error))onFailure
{
    if (_type == MXKAttachmentTypeImage || _type == MXKAttachmentTypeVideo)
    {
        MXWeakify(self);
        if (self.isEncrypted) {
            [self decryptToTempFile:^(NSString *path) {
                MXStrongifyAndReturnIfNil(self);
                NSURL* url = [NSURL fileURLWithPath:path];
                
                [MXMediaManager saveMediaToPhotosLibrary:url
                                                  isImage:(self.type == MXKAttachmentTypeImage)
                                                  success:^(NSURL *assetURL){
                                                      if (onSuccess)
                                                      {
                                                          [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                                                          onSuccess();
                                                      }
                                                  }
                                                  failure:onFailure];
            } failure:onFailure];
        }
        else
        {
            [self prepare:^{
                MXStrongifyAndReturnIfNil(self);
                NSURL* url = [NSURL fileURLWithPath:self.cacheFilePath];
                
                [MXMediaManager saveMediaToPhotosLibrary:url
                                                  isImage:(self.type == MXKAttachmentTypeImage)
                                                  success:^(NSURL *assetURL){
                                                      if (onSuccess)
                                                      {
                                                          onSuccess();
                                                      }
                                                  }
                                                  failure:onFailure];
            } failure:onFailure];
        }
    }
    else
    {
        // Not supported
        if (onFailure)
        {
            onFailure(nil);
        }
    }
}

- (void)copy:(void (^)(void))onSuccess failure:(void (^)(NSError *error))onFailure
{
    MXWeakify(self);
    [self prepare:^{
        MXStrongifyAndReturnIfNil(self);
        if (self.type == MXKAttachmentTypeImage)
        {
            [self getImage:^(UIImage *img) {
                [[UIPasteboard generalPasteboard] setImage:img];
                if (onSuccess)
                {
                    onSuccess();
                }
            } failure:^(NSError *error) {
                if (onFailure) onFailure(error);
            }];
        }
        else
        {
            MXWeakify(self);
            [self getAttachmentData:^(NSData *data) {
                if (data)
                {
                    MXStrongifyAndReturnIfNil(self);
                    NSString* UTI = (__bridge_transfer NSString *) UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[self.cacheFilePath pathExtension] , NULL);
                    
                    if (UTI)
                    {
                        [[UIPasteboard generalPasteboard] setData:data forPasteboardType:UTI];
                        if (onSuccess)
                        {
                            onSuccess();
                        }
                    }
                }
            } failure:^(NSError *error) {
                if (onFailure) onFailure(error);
            }];
        }
        
        // Unexpected error
        if (onFailure)
        {
            onFailure(nil);
        }
        
    } failure:onFailure];
}

- (void)prepareShare:(void (^)(NSURL *fileURL))onReadyToShare failure:(void (^)(NSError *error))onFailure
{
    MXWeakify(self);
    void (^haveFile)(NSString *) = ^(NSString *path) {
        // Prepare the file URL by considering the original file name (if any)
        NSURL *fileUrl;
        MXStrongifyAndReturnIfNil(self);
        // Check whether the original name retrieved from event body has extension
        if (self.originalFileName && [self.originalFileName pathExtension].length)
        {
            // Copy the cached file to restore its original name
            // Note:  We used previously symbolic link (instead of copy) but UIDocumentInteractionController failed to open Office documents (.docx, .pptx...).
            self->documentCopyPath = [[MXMediaManager getCachePath] stringByAppendingPathComponent:self.originalFileName];
            
            [[NSFileManager defaultManager] removeItemAtPath:self->documentCopyPath error:nil];
            if ([[NSFileManager defaultManager] copyItemAtPath:path toPath:self->documentCopyPath error:nil])
            {
                fileUrl = [NSURL fileURLWithPath:self->documentCopyPath];
            }
        }
        
        if (!fileUrl)
        {
            // Use the cached file by default
            fileUrl = [NSURL fileURLWithPath:path];
        }
        
        onReadyToShare (fileUrl);
    };
    
    if (self.isEncrypted)
    {
        [self decryptToTempFile:^(NSString *path) {
            haveFile(path);
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        } failure:onFailure];
    }
    else
    {
        // First download data if it is not already done
        [self prepare:^{
            haveFile(self.cacheFilePath);
        } failure:onFailure];
    }
}

- (void)onShareEnded
{
    // Remove the temporary file created to prepare attachment sharing
    if (documentCopyPath)
    {
        [[NSFileManager defaultManager] removeItemAtPath:documentCopyPath error:nil];
        documentCopyPath = nil;
    }
}

@end
