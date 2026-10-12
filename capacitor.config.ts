import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'tw.rouspa.operations',
  appName: '柔療營運',
  webDir: 'dist-ios',
  backgroundColor: '#c3a68c',
  loggingBehavior: 'none',
  appendUserAgent: ' ROU-SPA-Operations/1.0',
  ios: {
    contentInset: 'never',
    scrollEnabled: true,
    preferredContentMode: 'mobile',
    allowsLinkPreview: false,
    backgroundColor: '#c3a68c',
  },
  server: {
    hostname: 'localhost',
    iosScheme: 'capacitor',
  },
  plugins: {
    SplashScreen: {
      launchShowDuration: 1400,
      launchAutoHide: false,
      backgroundColor: '#c3a68c',
      showSpinner: false,
    },
    StatusBar: {
      style: 'DARK',
      backgroundColor: '#c3a68c',
    },
  },
};

export default config;
