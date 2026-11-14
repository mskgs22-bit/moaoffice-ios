@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo ===== 포켓 스캐너 안드로이드 빌드 (테스트용 APK) =====
echo.
where node >nul 2>nul || (echo [!] Node.js가 없어요. https://nodejs.org 에서 LTS 버전을 설치한 뒤 다시 실행하세요. & pause & exit /b 1)
if not defined JAVA_HOME if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\java.exe" set "JAVA_HOME=%ProgramFiles%\Android\Android Studio\jbr"
if not defined ANDROID_HOME set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
if not exist "%ANDROID_HOME%" (echo [!] Android SDK를 찾지 못했어요. Android Studio를 한 번 실행해서 SDK 설치를 마쳐 주세요. & pause & exit /b 1)

echo [1/5] 부품 설치 중... (처음엔 몇 분 걸려요)
call npm install || goto :err
echo [2/5] 라이브러리 복사 중...
call npm run libs || goto :err
echo [3/5] 안드로이드 프로젝트 준비 중...
if not exist android (call npx cap add android || goto :err)
call node scripts\setup-android.js || goto :err
call npx capacitor-assets generate --android
call npx cap sync android || goto :err
> android\local.properties echo sdk.dir=%ANDROID_HOME:\=\\%
echo [4/5] APK 빌드 중... (처음엔 5~10분 걸려요)
pushd android
call gradlew.bat assembleDebug || (popd & goto :err)
popd
echo [5/5] 완료!
echo.
echo APK 위치: %~dp0android\app\build\outputs\apk\debug\app-debug.apk
echo 이 파일을 휴대폰으로 보내서 설치하세요.
explorer "%~dp0android\app\build\outputs\apk\debug"
pause
exit /b 0
:err
echo.
echo [!] 오류가 났어요. 이 창을 캡처해서 Claude에게 보내주세요.
pause
exit /b 1
