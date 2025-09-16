import { TurboModuleRegistry, type TurboModule } from 'react-native';
import type { Int32 } from 'react-native/Libraries/Types/CodegenTypesNamespace';

export interface ZipFileInfo {
  filename: string;
  fileSize: Int32;
  compressedSize: Int32;
  headerOffset: Int32;
  compressionMethod: Int32;
  dateTime: {
    year: Int32;
    month: Int32;
    day: Int32;
    hour: Int32;
    minute: Int32;
    second: Int32;
  };
}

export interface Spec extends TurboModule {
  listFiles(zipURL: string): Promise<ZipFileInfo[]>;
  downloadFileData(
    zipURL: string,
    fileInfo: ZipFileInfo
  ): Promise<{ data: string }>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('UnzipHttp');
