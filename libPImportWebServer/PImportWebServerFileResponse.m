/*
 Copyright (c) 2012-2015, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#if !__has_feature(objc_arc)

#endif

#import <sys/stat.h>

#import "PImportWebServerPrivate.h"

#define kFileReadBufferSize (32 * 1024)

@interface PImportWebServerFileResponse () {
@private
  NSString* _path;
  NSUInteger _offset;
  NSUInteger _size;
  int _file;
}
@end

@implementation PImportWebServerFileResponse

+ (instancetype)responseWithFile:(NSString*)path {
  return [[[self class] alloc] initWithFile:path];
}

+ (instancetype)responseWithFile:(NSString*)path isAttachment:(BOOL)attachment {
  return [[[self class] alloc] initWithFile:path isAttachment:attachment];
}

+ (instancetype)responseWithFile:(NSString*)path byteRange:(NSRange)range {
  return [[[self class] alloc] initWithFile:path byteRange:range];
}

+ (instancetype)responseWithFile:(NSString*)path byteRange:(NSRange)range isAttachment:(BOOL)attachment {
  return [[[self class] alloc] initWithFile:path byteRange:range isAttachment:attachment];
}

- (instancetype)initWithFile:(NSString*)path {
  return [self initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:NO];
}

- (instancetype)initWithFile:(NSString*)path isAttachment:(BOOL)attachment {
  return [self initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:attachment];
}

- (instancetype)initWithFile:(NSString*)path byteRange:(NSRange)range {
  return [self initWithFile:path byteRange:range isAttachment:NO];
}

static inline NSDate* _NSDateFromTimeSpec(const struct timespec* t) {
  return [NSDate dateWithTimeIntervalSince1970:((NSTimeInterval)t->tv_sec + (NSTimeInterval)t->tv_nsec / 1000000000.0)];
}

- (instancetype)initWithFile:(NSString*)path byteRange:(NSRange)range isAttachment:(BOOL)attachment {
  struct stat info;
  BOOL isDir = NO;
  [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
  
  if (lstat([path fileSystemRepresentation], &info) || /*!(info.st_mode & S_IFREG) || (files && [files count])*/ isDir ) {
	  GWS_DNOT_REACHED();
		NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL]?:[NSArray array];
  //if([[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL]) {
		NSMutableDictionary *dirContent = [NSMutableDictionary dictionary];
		for(NSString* fileNow in files) {
			struct stat infoNow;
			NSString* fullPath = [path stringByAppendingPathComponent:fileNow];
			if (lstat([fullPath fileSystemRepresentation], &infoNow) == 0 ) {
				BOOL isDirNow = NO;
				[[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDirNow];
				[dirContent setObject:@{@"size": @(infoNow.st_size), @"isFile": (infoNow.st_mode & S_IFREG)?@YES:@NO, @"isDir": isDirNow?@YES:@NO, @"isLink": (infoNow.st_mode & S_IFLNK)?@YES:@NO,} forKey:fileNow];
			}		
		}
		if(isDir) {
			
			NSMutableData* dataMut = [[NSMutableData alloc] init];
			NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:dataMut];
			[archiver encodeObject:@{@"path": path, @"total": @([files count]), @"content": dirContent,} forKey:@"response"];
			[archiver finishEncoding];
			return (PImportWebServerFileResponse*)[PImportWebServerDataResponse responseWithData:dataMut contentType:@"application/oct-stream"];
			
			//return (PImportWebServerFileResponse*)[PImportWebServerDataResponse responseWithJSONObject:@{@"path": path, @"total": @([files count]), @"content": dirContent,}];
			
			
		}/* else {
			return (PImportWebServerFileResponse*)[PImportWebServerDataResponse responseWithData:[NSData data] contentType:@"application/oct-stream"];
		}*/
		
   //}
	
	return (PImportWebServerFileResponse*)[PImportWebServerDataResponse responseWithData:[NSData data] contentType:@"application/oct-stream"];
    //return nil;
  }
#ifndef __LP64__
  if (info.st_size >= (off_t)4294967295) {  // In 32 bit mode, we can't handle files greater than 4 GiBs (don't use "NSUIntegerMax" here to avoid potential unsigned to signed conversion issues)
    GWS_DNOT_REACHED();
    return (PImportWebServerFileResponse*)[PImportWebServerDataResponse responseWithData:[NSData data] contentType:@"application/oct-stream"];
    return nil;
  }
#endif
  NSUInteger fileSize = (NSUInteger)info.st_size;
  
  BOOL hasByteRange = PImportWebServerIsValidByteRange(range);
  if (hasByteRange) {
    if (range.location != NSUIntegerMax) {
      range.location = MIN(range.location, fileSize);
      range.length = MIN(range.length, fileSize - range.location);
    } else {
      range.length = MIN(range.length, fileSize);
      range.location = fileSize - range.length;
    }
    if (range.length == 0) {
      return nil;  // TODO: Return 416 status code and "Content-Range: bytes */{file length}" header
    }
  } else {
    range.location = 0;
    range.length = fileSize;
  }
  
  if ((self = [super init])) {
    _path = [path copy];
    _offset = range.location;
    _size = range.length;
    if (hasByteRange) {
      [self setStatusCode:kPImportWebServerHTTPStatusCode_PartialContent];
      [self setValue:[NSString stringWithFormat:@"bytes %lu-%lu/%lu", (unsigned long)_offset, (unsigned long)(_offset + _size - 1), (unsigned long)fileSize] forAdditionalHeader:@"Content-Range"];
      GWS_LOG_DEBUG(@"Using content bytes range [%lu-%lu] for file \"%@\"", (unsigned long)_offset, (unsigned long)(_offset + _size - 1), path);
    }
    
    if (attachment) {
      NSString* fileName = [path lastPathComponent];
      NSData* data = [[fileName stringByReplacingOccurrencesOfString:@"\"" withString:@""] dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
      NSString* lossyFileName = data ? [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] : nil;
      if (lossyFileName) {
        NSString* value = [NSString stringWithFormat:@"attachment; filename=\"%@\"; filename*=UTF-8''%@", lossyFileName, PImportWebServerEscapeURLString(fileName)];
        [self setValue:value forAdditionalHeader:@"Content-Disposition"];
      } else {
        GWS_DNOT_REACHED();
      }
    }
    
    self.contentType = PImportWebServerGetMimeTypeForExtension([_path pathExtension]);
    self.contentLength = _size;
    self.lastModifiedDate = _NSDateFromTimeSpec(&info.st_mtimespec);
    self.eTag = [NSString stringWithFormat:@"%llu/%li/%li", info.st_ino, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec];
  }
  return self;
}

- (BOOL)open:(NSError**)error {
  _file = open([_path fileSystemRepresentation], O_NOFOLLOW | O_RDONLY);
  if (_file <= 0) {
    if (error) {
      *error = PImportWebServerMakePosixError(errno);
    }
    return NO;
  }
  if (lseek(_file, _offset, SEEK_SET) != (off_t)_offset) {
    if (error) {
      *error = PImportWebServerMakePosixError(errno);
    }
    close(_file);
    return NO;
  }
  return YES;
}

- (NSData*)readData:(NSError**)error {
  size_t length = MIN((NSUInteger)kFileReadBufferSize, _size);
  NSMutableData* data = [[NSMutableData alloc] initWithLength:length];
  ssize_t result = read(_file, data.mutableBytes, length);
  if (result < 0) {
    if (error) {
      *error = PImportWebServerMakePosixError(errno);
    }
    return nil;
  }
  if (result > 0) {
    [data setLength:result];
    _size -= result;
  }
  return data;
}

- (void)close {
  close(_file);
}

- (NSString*)description {
  NSMutableString* description = [NSMutableString stringWithString:[super description]];
  [description appendFormat:@"\n\n{%@}", _path];
  return description;
}

@end
