import UnzipHttp, { type ZipFileInfo } from './NativeUnzipHttp';

export function downloadFileData(
  zipURL: string,
  fileInfo: ZipFileInfo
): Promise<{ data: string }>;
export function downloadFileData(
  zipURL: string,
  fileInfo: ZipFileInfo,
  targetPath: string
): Promise<void>;
export function downloadFileData(
  zipURL: string,
  fileInfo: ZipFileInfo,
  targetPath?: string
): Promise<{ data: string }> | Promise<void> {
  if (targetPath) {
    return UnzipHttp.downloadFileDataToFile(zipURL, fileInfo, targetPath);
  } else {
    return UnzipHttp.downloadFileData(zipURL, fileInfo);
  }
}

export function listFiles(zipURL: string): Promise<ZipFileInfo[]> {
  return UnzipHttp.listFiles(zipURL);
}

export { type ZipFileInfo };
