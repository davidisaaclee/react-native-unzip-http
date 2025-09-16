import UnzipHttp, { type ZipFileInfo } from './NativeUnzipHttp';

export function downloadFileData(
  zipURL: string,
  fileInfo: ZipFileInfo
): Promise<{ data: string }> {
  return UnzipHttp.downloadFileData(zipURL, fileInfo);
}

export function listFiles(zipURL: string): Promise<ZipFileInfo[]> {
  return UnzipHttp.listFiles(zipURL);
}

export { type ZipFileInfo };
