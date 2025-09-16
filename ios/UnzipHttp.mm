#import "UnzipHttp.h"
#import "UnzipHttp-Swift.h"

@interface UnzipHttp()
@property (strong, nonatomic) HttpUnzipExtractor *impl;
@end


@implementation UnzipHttp
RCT_EXPORT_MODULE()

// MARK: Setup

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeUnzipHttpSpecJSI>(params);
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.impl = [[HttpUnzipExtractor alloc] initWithUrlSession:[NSURLSession sharedSession]];
  }
  return self;
}

// MARK: Methods

- (void)listFiles:(NSString *)zipURL
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  [self.impl listFilesAtZipURL:[NSURL URLWithString:zipURL] completionHandler:^(NSArray<FileInfo *> * _Nullable fileInfo, NSError * _Nullable error) {
    if (error != nil) {
      reject(@"unzip-http-failed-list", @"Failed to list contents of remote zip file", error);
    } else {
      NSMutableArray *outArray = [NSMutableArray new];
      for (FileInfo *info in fileInfo) {
        NSDictionary *zipInfoDict = @{
          @"filename": info.filename,
          @"fileSize": @(info.fileSize),
          @"compressedSize": @(info.compressedSize),
          @"headerOffset": @(info.headerOffset),
          @"compressionMethod": @(info.compressionMethod),
          @"dateTime": @{
            @"year": @(info.dateTime.year),
            @"month": @(info.dateTime.month),
            @"day": @(info.dateTime.day),
            @"hour": @(info.dateTime.hour),
            @"minute": @(info.dateTime.minute),
            @"second": @(info.dateTime.second)
          }
        };
        [outArray addObject:zipInfoDict];
      }

      resolve(outArray);
    }
  }];
}

- (void)downloadFileData:(NSString *)zipURL
                fileInfo:(JS::NativeUnzipHttp::ZipFileInfo &)fileInfo
                 resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject
{
  Datetime *datetime = [[Datetime alloc] initWithYear:fileInfo.dateTime().year()
                                                month:fileInfo.dateTime().month()
                                                  day:fileInfo.dateTime().day()
                                                 hour:fileInfo.dateTime().hour()
                                               minute:fileInfo.dateTime().minute()
                                               second:fileInfo.dateTime().second()];
  FileInfo *fileInfoConverted = [[FileInfo alloc] initWithFilename:fileInfo.filename()
                                                          fileSize:fileInfo.fileSize()
                                                    compressedSize:fileInfo.compressedSize()
                                                      headerOffset:fileInfo.headerOffset()
                                                 compressionMethod:fileInfo.compressionMethod()
                                                          dateTime:datetime];
  [self.impl download:fileInfoConverted inZipURL:[NSURL URLWithString:zipURL] completionHandler:^(NSData * _Nullable data, NSError * _Nullable error) {
    if (error != nil) {
      reject(@"unzip-http-failed-download", @"Failed to download zip file content", error);
    } else {
      NSString *b64 = [data base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
      resolve(@{@"data": b64});
    }
  }];
}

@end
