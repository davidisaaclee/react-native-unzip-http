import * as React from 'react';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import {
  Text,
  StyleSheet,
  ActivityIndicator,
  FlatList,
  Alert,
  TouchableHighlight,
  TouchableOpacity,
  Image,
} from 'react-native';
import {
  listFiles,
  downloadFileData,
  type ZipFileInfo,
} from 'react-native-unzip-http';

const ZIP_FILE_URL =
  'https://archive.org/download/astoundingstorie28617gut/28617-h.zip';

export default function App() {
  const [files, setFiles] = React.useState<ZipFileInfo[] | null>(null);
  const [selectedFile, setSelectedFile] = React.useState<{
    info: ZipFileInfo;
    data?: string;
  } | null>(null);
  const inflightRequest = React.useRef<ZipFileInfo | null>(null);

  React.useEffect(() => {
    (async () => {
      const fileList = await listFiles(ZIP_FILE_URL);
      console.log('fileList', fileList);
      setFiles(fileList);
    })().catch((err) => {
      Alert.alert('Error', err.message);
    });
  }, []);

  React.useEffect(() => {
    if (selectedFile == null) {
      return;
    }
    if (selectedFile.data != null) {
      return;
    }
    if (inflightRequest.current === selectedFile.info) {
      return;
    }
    inflightRequest.current = selectedFile.info;

    (async () => {
      const result = await downloadFileData(ZIP_FILE_URL, selectedFile.info);
      setSelectedFile({ info: selectedFile.info, data: result.data });
    })().catch((err) => {
      Alert.alert('Error', err.message);
    });
  }, [selectedFile]);

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.container}>
        <Text>URL: {ZIP_FILE_URL}</Text>
        {files == null ? (
          <ActivityIndicator />
        ) : (
          <>
            {selectedFile != null && (
              <>
                <TouchableHighlight
                  onPress={() => {
                    setSelectedFile(null);
                  }}
                >
                  <Text>Selected: {selectedFile.info.filename}</Text>
                </TouchableHighlight>
                {selectedFile.data == null ? (
                  <ActivityIndicator />
                ) : (
                  <Image
                    source={{
                      uri: `data:image/png;base64,${selectedFile.data}`,
                    }}
                    width={100}
                    height={100}
                    resizeMode="contain"
                  />
                )}
              </>
            )}
            <FlatList
              style={{ flex: 1, width: '100%' }}
              data={files}
              keyExtractor={(item) => item.filename}
              renderItem={({ item }) => (
                <TouchableOpacity
                  onPress={() => {
                    setSelectedFile({ info: item });
                  }}
                >
                  <Text>{item.filename}</Text>
                </TouchableOpacity>
              )}
            />
          </>
        )}
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
