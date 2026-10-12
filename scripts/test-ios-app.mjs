import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../', import.meta.url);
let checks = 0;
const check = (condition, label) => {
  assert.ok(condition, label);
  checks++;
};
const text = path => readFile(new URL(path, root), 'utf8');

const [
  packageJsonText, capacitor, viteIos, mobileHtml, iosMain, nativePlatform,
  attendance, operationsShared, admin, stewardUi, stewardServer, staffLogin,
  staffAccounts, spa, payrollXlsx, businessOs, infoPlist, privacyManifest,
  project, iconContentsText, rootGitignore, iosGitignore,
  packageSwift, workflow,
  sceneDelegate, privacyPage, supportPage,
] = await Promise.all([
  text('package.json'), text('capacitor.config.ts'), text('vite.config.ios.js'),
  text('mobile/index.html'), text('src/ios-main.jsx'), text('src/lib/native-platform.js'),
  text('src/lib/attendance.js'), text('src/OperationsShared.jsx'), text('src/Admin.jsx'),
  text('src/AskSteward.jsx'), text('server/ask-steward.mjs'),
  text('supabase/functions/staff-login/index.ts'), text('supabase/functions/staff-accounts/index.ts'),
  text('src/lib/spa.js'), text('src/lib/payroll-xlsx.js'), text('src/BusinessOS.jsx'),
  text('ios/App/App/Info.plist'), text('ios/App/App/PrivacyInfo.xcprivacy'),
  text('ios/App/App.xcodeproj/project.pbxproj'),
  text('ios/App/App/Assets.xcassets/AppIcon.appiconset/Contents.json'),
  text('.gitignore'), text('ios/.gitignore'),
  text('ios/App/CapApp-SPM/Package.swift'), text('.github/workflows/validate.yml'),
  text('ios/App/App/SceneDelegate.swift'), text('public/privacy/index.html'),
  text('public/support/index.html'),
]);
const packageJson = JSON.parse(packageJsonText);

check(/appId:\s*['"]tw\.rouspa\.operations['"]/.test(capacitor), 'Capacitor uses the dedicated operations bundle identifier');
check(/appName:\s*['"]柔療營運['"]/.test(capacitor), 'Capacitor uses the operations-only display name');
check(/webDir:\s*['"]dist-ios['"]/.test(capacitor), 'Capacitor packages the isolated iOS build');
check(/loggingBehavior:\s*['"]none['"]/.test(capacitor), 'release disables native bridge logging');
check(/hostname:\s*['"]localhost['"]/.test(capacitor) && /iosScheme:\s*['"]capacitor['"]/.test(capacitor), 'native origin remains exactly capacitor://localhost');
check(!/\burl\s*:\s*['"]https?:\/\//.test(capacitor), 'release does not hot-load a remote website');
check(/outDir:\s*resolve\(process\.cwd\(\),\s*['"]dist-ios['"]\)/.test(viteIos), 'iOS Vite output stays separate from the website build');

check(/viewport-fit=cover/.test(mobileHtml), 'iOS shell enables safe-area layout');
check(/noindex,\s*nofollow,\s*noarchive/.test(mobileHtml), 'iOS shell cannot become an indexed public page');
check(/src=['"]\/src\/ios-main\.jsx['"]/.test(mobileHtml), 'iOS shell loads only the native entry point');
check(/Content-Security-Policy/.test(mobileHtml) && /script-src 'self'/.test(mobileHtml) && /object-src 'none'/.test(mobileHtml) && /frame-src 'none'/.test(mobileHtml), 'iOS shell applies a restrictive content security policy');
check(!/unsafe-eval|script-src[^>]*\*/.test(mobileHtml), 'iOS shell does not allow eval or wildcard script sources');
check(/img-src[^;]*https:/.test(mobileHtml), 'iOS product previews allow reviewed HTTPS catalog image URLs');
check(/import Admin from ['"]\.\/Admin\.jsx['"]/.test(iosMain) && /return\s+<[\s\S]{0,80}<Admin\s*\/>/.test(iosMain), 'native entry renders the complete protected Admin system');
check(!/import\s+App\s+from\s+['"]\.\/App\.jsx['"]/.test(iosMain), 'customer website router is not bundled as the iOS entry');
for (const plugin of ['@capacitor/app', '@capacitor/browser', '@capacitor/splash-screen', '@capacitor/status-bar']) {
  check(iosMain.includes(plugin), `native entry integrates ${plugin}`);
}
check(/appStateChange/.test(iosMain) && /startAutoRefresh/.test(iosMain) && /stopAutoRefresh/.test(iosMain), 'foreground and background transitions control auth refresh');
check(/refreshSession/.test(iosMain) && /rou-ios-privacy-screen/.test(iosMain) && /NATIVE_CATCHUP_EVENT/.test(iosMain), 'resume revalidates the session behind a privacy cover before refreshing operations');
check(/Browser\.open/.test(iosMain) && /\^\(https\?:\)/.test(iosMain), 'external web links open through the native browser');

check(/PUBLIC_WEBSITE_ORIGIN\s*=\s*['"]https:\/\/www\.rouspa\.tw['"]/.test(nativePlatform), 'all public links use the production website');
check(/NATIVE_OPERATIONS_ORIGIN\s*=\s*['"]capacitor:\/\/localhost['"]/.test(nativePlatform), 'native origin has one shared source constant');
check(/operationsApiUrl/.test(nativePlatform) && /PUBLIC_WEBSITE_ORIGIN/.test(nativePlatform), 'native server API calls are routed to production');
check(/Filesystem\.writeFile/.test(nativePlatform) && /Directory\.Cache/.test(nativePlatform) && /Share\.share/.test(nativePlatform), 'native exports use a temporary cache file and the iOS share sheet');
check(/finally\s*{[\s\S]*Filesystem\.deleteFile/.test(nativePlatform), 'native exports attempt to delete their temporary cache file after every share outcome');
check(/publicWebsiteUrl/.test(operationsShared) && /publicWebsiteUrl/.test(admin), 'login, private and website links leave the native shell safely');
check(/operationsApiUrl\(['"]\/api\/ask-steward['"]\)/.test(stewardUi), 'Ask Steward uses the native-aware server endpoint');

check(/@capacitor\/geolocation/.test(attendance), 'native attendance uses Capacitor geolocation');
check(/enableHighAccuracy:\s*true/.test(attendance) && /timeout:\s*15000/.test(attendance) && /maximumAge:\s*0/.test(attendance), 'every punch requests a fresh high-accuracy location with a 15 second limit');
check(/navigator\.geolocation/.test(attendance), 'website attendance keeps its browser fallback');
check(/NSLocationWhenInUseUsageDescription/.test(infoPlist), 'iOS declares a clear when-in-use location purpose');
check(/NSLocationAlwaysAndWhenInUseUsageDescription/.test(infoPlist), 'iOS includes the usage key required by the installed Capacitor geolocation package');
check(/NSCameraUsageDescription/.test(infoPlist) && /NSPhotoLibraryUsageDescription/.test(infoPlist), 'iOS declares user-initiated product camera and photo purposes');
check(!/<string>location<\/string>/.test(infoPlist), 'iOS has no background location mode');
check(!/NSAllowsArbitraryLoads[\s\S]{0,80}<true\/>/.test(infoPlist), 'iOS does not enable arbitrary network loads');
check(/NSPrivacyCollectedDataTypePreciseLocation/.test(privacyManifest) && /NSPrivacyCollectedDataTypeUserID/.test(privacyManifest), 'privacy manifest declares linked location and account data');
for (const type of ['Name', 'EmailAddress', 'PhoneNumber', 'PhysicalAddress', 'PaymentInfo', 'OtherFinancialInfo', 'PhotosorVideos', 'OtherUserContent', 'PurchaseHistory', 'OtherDataTypes']) {
  check(privacyManifest.includes(`NSPrivacyCollectedDataType${type}`), `privacy manifest declares ${type}`);
}
check(/<key>NSPrivacyTracking<\/key>\s*<false\/>/.test(privacyManifest), 'privacy manifest declares no tracking');
check(/NSPrivacyAccessedAPICategoryFileTimestamp/.test(privacyManifest) && /<string>C617\.1<\/string>/.test(privacyManifest), 'privacy manifest declares the Filesystem timestamp API reason');
check(/sceneWillResignActive/.test(sceneDelegate) && /window\.addSubview\(cover\)/.test(sceneDelegate), 'native scene immediately covers protected content when leaving the foreground');
check(/sceneDidBecomeActive/.test(sceneDelegate) && /rou-ios-private/.test(sceneDelegate) && /waitForWebPrivacyRelease/.test(sceneDelegate), 'native cover waits for JavaScript session revalidation before release');

for (const source of [stewardServer, staffLogin, staffAccounts]) {
  check(source.includes('capacitor://localhost'), 'protected server surface explicitly allows the native origin');
}
check(/access-control-allow-origin/i.test(stewardServer) && /OPTIONS/.test(stewardServer), 'Ask Steward supports exact-origin CORS preflight');
check(/saveDownload/.test(spa) && /saveDownload/.test(payrollXlsx) && /saveDownload/.test(businessOs), 'CSV, XLSX and backup exports share the native export adapter');
check(/await downloadJson/.test(businessOs) && /confirm\?\.\(['"]備份分享視窗已關閉/.test(businessOs), 'backup reset waits for export and explicit saved-file confirmation');
check(businessOs.indexOf('await downloadJson') < businessOs.indexOf("await rpc('spa_reset_business_data'"), 'reset cannot execute before the awaited backup flow');
check(/publicWebsiteUrl\(['"]\/privacy\//.test(admin) && /publicWebsiteUrl\(['"]\/support\//.test(admin), 'native admin exposes production privacy and support links');
for (const [page, label] of [[privacyPage, 'privacy'], [supportPage, 'support']]) {
  check(/noindex,\s*follow/.test(page) && /rosa1232425@gmail\.com/.test(page), `public ${label} page is available with support contact and no indexing`);
}

const requiredDependencies = [
  '@capacitor/app', '@capacitor/browser', '@capacitor/core', '@capacitor/filesystem',
  '@capacitor/geolocation', '@capacitor/ios', '@capacitor/share',
  '@capacitor/splash-screen', '@capacitor/status-bar',
];
for (const dependency of requiredDependencies) check(Boolean(packageJson.dependencies?.[dependency]), `package includes ${dependency}`);
check(Boolean(packageJson.devDependencies?.['@capacitor/cli']), 'package includes the Capacitor CLI');
for (const script of ['build:ios', 'ios:sync', 'ios:open', 'ios:verify']) check(Boolean(packageJson.scripts?.[script]), `package exposes ${script}`);
check(packageJson.scripts.test.includes('node scripts/test-ios-app.mjs'), 'the iOS contract runs in the normal test suite');

check(/IPHONEOS_DEPLOYMENT_TARGET = 15\.0/.test(project), 'Xcode project supports iOS 15 and newer');
check(/platforms:\s*\[\.iOS\(\.v15\)\]/.test(packageSwift), 'Capacitor Swift package matches the iOS 15 deployment target');
check(/PRODUCT_BUNDLE_IDENTIFIER = tw\.rouspa\.operations/.test(project), 'Xcode bundle identifier matches Capacitor');
check(/<key>CFBundleIdentifier<\/key>\s*<string>\$\(PRODUCT_BUNDLE_IDENTIFIER\)<\/string>/.test(infoPlist), 'Info.plist inherits the reviewed Xcode bundle identifier');
check(/<key>CFBundleDisplayName<\/key>\s*<string>柔療營運<\/string>/.test(infoPlist), 'Info.plist display name matches Capacitor');
check(/TARGETED_DEVICE_FAMILY = ['"]1,2['"]/.test(project), 'Xcode project supports iPhone and iPad');
check(/MARKETING_VERSION = 1\.0/.test(project) && /CURRENT_PROJECT_VERSION = 1/.test(project), 'Xcode project contains explicit release and build versions');
check(/PrivacyInfo\.xcprivacy/.test(project), 'Xcode project packages the privacy manifest');

const iconContents = JSON.parse(iconContentsText);
const iconRecord = iconContents.images?.find(item => item.filename === 'AppIcon-512@2x.png');
check(iconRecord?.platform === 'ios' && iconRecord?.size === '1024x1024', 'asset catalog declares a 1024px iOS icon');
const icon = await readFile(new URL('ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png', root));
check(icon.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])), 'app icon is a valid PNG');
check(icon.readUInt32BE(16) === 1024 && icon.readUInt32BE(20) === 1024, 'app icon pixels are exactly 1024 by 1024');
check(icon[25] === 2, 'app icon is opaque RGB without an alpha channel');

check(/^dist-ios\/$/m.test(rootGitignore), 'generated iOS web build is ignored');
check(/^App\/App\/public$/m.test(iosGitignore), 'Capacitor-copied web assets are ignored');
check(/runs-on:\s*macos-26/.test(workflow) && /xcodebuild -version/.test(workflow), 'CI uses an Xcode 26 capable macOS runner required by Capacitor 8');
check(/node scripts\/test-ios-app\.mjs/.test(workflow) && /npm run build:ios/.test(workflow) && /npx cap sync ios/.test(workflow), 'CI verifies the contract, web bundle and Capacitor synchronization');
check(/xcodebuild[\s\S]*-configuration Release[\s\S]*CODE_SIGNING_ALLOWED=NO/.test(workflow), 'CI compiles a release configuration without requiring signing credentials');
const sensitiveSurface = [capacitor, viteIos, mobileHtml, iosMain, nativePlatform, infoPlist, privacyManifest].join('\n');
check(!/sk-kimi-[A-Za-z0-9_-]+|ghp_[A-Za-z0-9]+|sb_secret_[A-Za-z0-9_-]+|service_role\s*[:=]\s*['"][A-Za-z0-9._-]{16,}/i.test(sensitiveSurface), 'native package contains no privileged credential');

console.log(`PASS: ${checks} iOS operations app release-contract assertions`);
